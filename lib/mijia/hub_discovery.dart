// hub_discovery.dart —— 米家极客版中枢自动发现（vendor/hub/发现中枢.py 移植）。
//
// 候选顺序（从最可靠到最宽松）：
//   1. 读本机路由表 → 默认网关 IP（极客版网页通常就挂在主中枢上）
//   2. 探该网段 .1 的 8086 端口
//   3. 兜底：探该网段 .1..10
// ★ 每个候选（含缓存里那条）都要过身份校验（verifyHub：网页标题必须含
//   「米家自动化极客版」）才算命中——很多路由器管理页也占 8086，只看端口
//   通不通会认错（实测踩过）。
// 命中后写进缓存（%LOCALAPPDATA%\EzMiGeek\.lan-hub-cache.json），以后缓存
// 命中且端口仍通就直接用。不依赖任何云接口。
library;

import 'dart:convert';
import 'dart:io';

import '../core/app_dirs.dart';

const int geekPort = 8086;

/// 极客版网页可能挂的端口（按优先级）。8086 是惯例端口；80 是部分机器的
/// 实际端口（实测踩过：有人的中枢开在 80，8086 上什么都没有——他自己
/// 浏览器地址栏不带端口能打开，装了软件反而找不到）。
const List<int> geekPorts = [8086, 80];

String _cachePath() => '${dataDir()}\\.lan-hub-cache.json';

/// 读本机默认网关（route print 的 0.0.0.0 行最稳，不受系统语言影响；
/// 失败退回 ipconfig 的默认网关行，中英双匹配）。
String? defaultGateway() {
  String run(String exe, List<String> args) {
    try {
      final r = Process.runSync(exe, args,
          stdoutEncoding: const SystemEncoding(),
          stderrEncoding: const SystemEncoding());
      return r.exitCode == 0 ? r.stdout.toString() : '';
    } catch (_) {
      return '';
    }
  }

  // 方法 1：route print
  final out = run('route', ['print', '0.0.0.0']);
  for (final line in out.split('\n')) {
    final parts =
        line.trim().split(RegExp(r'\s+'));
    if (parts.length >= 3 &&
        parts[0] == '0.0.0.0' &&
        parts[1] == '0.0.0.0') {
      final ip = parts[2];
      if (ip.isNotEmpty && RegExp(r'^\d').hasMatch(ip) && ip != '127.0.0.1') {
        return ip;
      }
    }
  }

  // 方法 2：ipconfig
  final text = run('ipconfig', []);
  final gws = <String>[];
  for (final line in text.split('\n')) {
    final low = line.toLowerCase();
    if (low.contains('default gateway') || line.contains('默认网关')) {
      final idx = line.indexOf(':');
      if (idx >= 0) {
        final ip = line.substring(idx + 1).trim();
        if (ip.isNotEmpty && RegExp(r'^\d').hasMatch(ip)) gws.add(ip);
      }
    }
  }
  for (final ip in gws) {
    if (ip.startsWith('192.168.') || ip.startsWith('10.')) return ip;
  }
  return gws.isEmpty ? null : gws.first;
}

/// 列出本机所在网段（如 192.168.31）。
Future<List<String>> localNetworks() async {
  final nets = <String>{};
  try {
    for (final it in await NetworkInterface.list(includeLoopback: false)) {
      for (final addr in it.addresses) {
        if (addr.type == InternetAddressType.IPv4) {
          final ip = addr.address;
          if (ip.startsWith('192.168.') ||
              ip.startsWith('10.') ||
              ip.startsWith('172.')) {
            nets.add(ip.substring(0, ip.lastIndexOf('.')));
          }
        }
      }
    }
  } catch (_) {}
  return nets.toList()..sort();
}

/// 只做 TCP 连接探测，判断端口是否在监听。
Future<bool> probeWs(String host, {int port = geekPort, Duration timeout = const Duration(milliseconds: 1500)}) async {
  try {
    final s = await Socket.connect(host, port, timeout: timeout);
    s.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

/// 身份校验：端口通之外，还要确认 8086 上挂的真是极客版页面。
/// 判据 = 响应里含页面标题「米家自动化极客版」（限读前 64KB，够覆盖整个
/// 首屏 HTML）。路由器管理页过不了这一关。
/// 中枢偶尔忙、首包慢（实测 2.5s 会偶发超时误杀真中枢），所以一次不过
/// 再补试两次；路由器 400 秒回不受影响。
/// 返回 (是否极客版, 拒绝原因摘要)——原因进诊断日志，远程就能看清对方是什么。
Future<(bool, String)> verifyHubDetail(String host, {int port = geekPort}) async {
  var lastReason = '3 次请求都没有应答';
  for (var attempt = 0; attempt < 3; attempt++) {
    final (ok, why) = await _verifyOnce(host, port);
    if (ok) return (true, '');
    lastReason = why;
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  return (false, lastReason);
}

Future<bool> verifyHub(String host, {int port = geekPort}) async =>
    (await verifyHubDetail(host, port: port)).$1;

Future<(bool, String)> _verifyOnce(String host, int port) async {
  final client = HttpClient();
  client.connectionTimeout = const Duration(milliseconds: 1500);
  String snippet(String s) {
    final oneLine = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return oneLine.length > 80 ? '${oneLine.substring(0, 80)}…' : oneLine;
  }

  try {
    final req = await client
        .getUrl(Uri.parse('http://$host:$port/'))
        .timeout(const Duration(milliseconds: 2500));
    final resp = await req.close().timeout(const Duration(milliseconds: 2500));
    // 不看状态码（有的固件对 / 回 30x/40x），只认页面里的标题词——
    // 路由器的 400/管理页里不会有「米家自动化极客版」，拦得住。
    final body = await resp
        .transform(const Utf8Decoder(allowMalformed: true))
        .fold<StringBuffer>(
            StringBuffer(), (sb, chunk) => sb..write(chunk))
        .timeout(const Duration(milliseconds: 3000));
    final text = body.toString();
    if (text.contains('米家自动化极客版')) return (true, '');
    return (false,
        'HTTP ${resp.statusCode} 但页面没有标题词，开头「${snippet(text)}」');
  } catch (e) {
    return (false, '请求失败：${snippet('$e')}');
  } finally {
    client.close(force: true);
  }
}

Map<String, Object?> loadCache() {
  try {
    final raw = jsonDecode(File(_cachePath()).readAsStringSync());
    if (raw is Map) return Map<String, Object?>.from(raw);
  } catch (_) {}
  return {};
}

void saveCache(Map<String, Object?> d) {
  try {
    File(_cachePath())
        .writeAsStringSync(const JsonEncoder.withIndent(' ').convert(d));
  } catch (_) {}
}

/// 发现中枢 IP。返回 (ip, 依据说明)；找不到返回 ('', 带诊断的原因)。
///
/// 候选顺序：缓存 → 默认网关 → 网段 .1 → 网段 .1..10 → 全网段并行兜底。
/// 每个候选把 geekPorts 里的端口都试一遍，过身份校验才算命中。
/// 找不到时，原因里带每类候选的结果（哪个端口开着但不是极客页的逐个列出），
/// 让下一份日志能看清局域网里有什么。
/// 返回 (ip, port, 依据)；找不到返回 ('', geekPort, 原因)。
Future<(String, int, String)> discover({bool useCache = true}) async {
  final diag = <String>[]; // 诊断碎片（拼进「未找到」的原因）
  final tried = <String>{};
  var deadCount = 0; // 两个候选端口全不通的地址数
  final identityFail = <String>[]; // 端口开着但不是极客页

  Future<(String, int)?> tryOne(String ip) async {
    if (!tried.add(ip)) return null;
    var anyOpen = false;
    for (final port in geekPorts) {
      if (!await probeWs(ip, port: port)) continue;
      anyOpen = true;
      final (ok, why) = await verifyHubDetail(ip, port: port);
      if (ok) return (ip, port);
      identityFail.add('$ip:$port（$why）');
    }
    if (!anyOpen) deadCount++;
    return null;
  }

  Future<(String, int, String)> hit(String ip, int port, String why) async {
    saveCache({
      'hub_ip': ip,
      'port': port,
      'ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    });
    return (ip, port, why);
  }

  // 0) 缓存（同样要过身份校验：v3.0.1 之前只认端口，路由器 8086 上的别的
  //    服务可能被当命中存进缓存；实测踩过：升级后仍「缓存命中」跳 5.1）。
  //    缓存里存的端口只作参考，命中判定仍按候选端口全试。
  if (useCache) {
    final ip = '${loadCache()['hub_ip'] ?? ''}'.trim();
    if (ip.isNotEmpty) {
      final r = await tryOne(ip);
      if (r != null) return await hit(r.$1, r.$2, '缓存命中');
    }
  }

  final gw = defaultGateway();
  final nets = await localNetworks();
  final near = <String>[
    ?gw,
    for (final net in nets) '$net.1',
    for (final net in nets)
      for (var i = 1; i <= 10; i++) '$net.$i',
  ];
  for (final ip in near) {
    final r = await tryOne(ip);
    if (r != null) {
      return await hit(r.$1, r.$2, ip == gw ? '默认网关' : '网段扫描');
    }
  }

  // 最后兜底：整个网段并行扫（中枢不在 .1..10 时也能自己找到）。
  // 并发 64、每批等完再下一批；扫中取下标最靠前的。
  final far = <String>[
    for (final net in nets)
      for (var i = 1; i <= 254; i++) '$net.$i',
  ].where((ip) => !tried.contains(ip)).toList();
  for (var i = 0; i < far.length; i += 64) {
    final batch = far.sublist(i, (i + 64).clamp(0, far.length));
    final results = await Future.wait(batch.map(tryOne));
    for (final r in results) {
      if (r != null) return await hit(r.$1, r.$2, '全网段扫描');
    }
  }

  if (identityFail.isNotEmpty) {
    diag.add('开着候选端口但不是极客页：${identityFail.join('、')}');
  }
  if (deadCount > 0) diag.add('其余 $deadCount 个地址候选端口都不通');
  return ('', geekPort, '未找到（${diag.isEmpty ? '局域网里没扫到任何极客版页面' : diag.join('；')}）');
}

/// 在[ip]上按候选端口逐个找极客版页面。找到返回端口，找不到返回 null
/// （云端提示兜底用：拿到 IP 后靠它确认端口）。
Future<int?> findGeekPort(String ip) async {
  for (final port in geekPorts) {
    if (!await probeWs(ip, port: port)) continue;
    if (await verifyHub(ip, port: port)) return port;
  }
  return null;
}
