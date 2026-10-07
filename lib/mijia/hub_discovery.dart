// hub_discovery.dart —— 米家极客版中枢自动发现（vendor/hub/发现中枢.py 移植）。
//
// 三层，从最可靠到最宽松：
//   1. 读本机路由表 → 默认网关 IP（极客版网页就挂在主中枢上）
//   2. 探该网段 .1 的 8086 端口
//   3. 一次握手成功 → 写进缓存（%LOCALAPPDATA%\EzMiGeek\.lan-hub-cache.json），
//      以后缓存命中且端口仍通就直接用
// 不依赖任何云接口。
library;

import 'dart:convert';
import 'dart:io';

import '../core/app_dirs.dart';

const int geekPort = 8086;

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

/// 发现中枢 IP。返回 (ip, 依据说明)；找不到返回 ('', 原因)。
Future<(String, String)> discover({bool useCache = true}) async {
  if (useCache) {
    final ip = '${loadCache()['hub_ip'] ?? ''}'.trim();
    if (ip.isNotEmpty && await probeWs(ip)) {
      return (ip, '缓存命中');
    }
  }

  final gw = defaultGateway();
  final cands = <String>[];
  if (gw != null) cands.add(gw);
  for (final net in await localNetworks()) {
    cands.add('$net.1');
  }
  // 兜底：网段里 1..10
  for (final net in await localNetworks()) {
    for (var i = 1; i <= 10; i++) {
      cands.add('$net.$i');
    }
  }

  final seen = <String>{};
  for (final ip in cands) {
    if (seen.contains(ip)) continue;
    seen.add(ip);
    if (await probeWs(ip)) {
      saveCache({'hub_ip': ip, 'ts': DateTime.now().millisecondsSinceEpoch ~/ 1000});
      return (ip, ip == gw ? '默认网关' : '网段扫描');
    }
  }
  return ('', '未找到');
}
