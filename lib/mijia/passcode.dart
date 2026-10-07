// passcode.dart —— 取 6 位登录码（app/passcode.py + vendor/hub/取登录码.py 移植）。
//
// 为什么在宿主侧取码而不用页面请求：页面是 http://192.168.x.x，去请求
// https://core.api.mijia.tech 必然被 CORS 拦。宿主侧零问题。
//
// 链路：loadCfg（DPAPI 解密）→ mint sid=mijia 换票 → HMAC-SHA256 签名 →
// miIO.get_central_link_passcode。候选设备按「最可能是主中枢」排序：
//   唯一可靠判据 = 设备的 localip == 网页主机名（配置里的 did 可能是备中枢）。
library;

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;

import 'mijia_cloud.dart';
import 'stale.dart' show isStale;

export 'mijia_cloud.dart' show loadCfg, saveCfg, requiredCredKeys, MijiaError;
const String _ua =
    'Android-7.1.1-1.0.0-ONEPLUS A3010-136-ABCDEFABCDEF0 APP/xiaomi.smarthome APPV/62830';
const String _rpcBase = 'https://core.api.mijia.tech/app/home/rpc/';
const String _accessKey = 'IOS00026747c5acafc2';

class PasscodeError implements Exception {
  PasscodeError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 取一个 6 位登录码。返回 (code, info)。按候选设备逐个试。
///
/// ★ 缓存的 serviceToken 服务端可以提前作废（6 小时缓存窗内也一样）。
///   取码被拒且像鉴权问题时：清票据缓存 → 强制换一张新票 → 同一 did 立刻
///   重试一次（每轮 fetchCode 只自动续期一次）。续期还失败才走原来的
///   WaitMin 重试 / 「登录已失效」收轮路 —— 那时才是真的要人工登录。
Future<(String, Map<String, Object?>)> fetchCode(String hubIp,
    {void Function(Object?)? log, Map<String, Object?>? cfg}) async {
  final c = cfg ?? loadCfg();
  final dids = await candidateDids(c, hubIp, log: log);
  if (dids.isEmpty) {
    throw PasscodeError('没有可用的设备 did，云端设备列表也拿不到');
  }
  var cred = await _mintSafe(c);
  var refreshed = false;
  Object? last;
  for (var i = 0; i < dids.length; i++) {
    final did = dids[i];
    try {
      final code = await getPasscode(did, c, cred);
      return (
        code,
        {'did': did, 'hub_ip': hubIp, 'tried': i + 1},
      );
    } catch (e) {
      last = e;
      log?.call('  did=$did 取码失败：$e');
      if (refreshed || !authRejectedMessage('$e')) continue;
      refreshed = true;
      clearTokenCache();
      log?.call('  像是缓存票据被服务端提前作废 → 清缓存强制换新票，重试一次');
      cred = await _mintSafe(c, forceRefresh: true); // 换票失败会原样抛出（含「登录已失效」）
      try {
        final code = await getPasscode(did, c, cred);
        return (
          code,
          {'did': did, 'hub_ip': hubIp, 'tried': i + 1},
        );
      } catch (e2) {
        last = e2;
        log?.call('  did=$did 换票后重试仍失败：$e2');
      }
    }
  }
  throw PasscodeError('所有候选设备都取不到码，最后一个错误：$last');
}

Future<Map<String, Object?>> _mintSafe(Map<String, Object?> cfg,
    {bool forceRefresh = false}) async {
  try {
    return await mint(cfg, sid: 'mijia', useCache: true,
        forceRefresh: forceRefresh);
  } catch (e) {
    throw PasscodeError('$e');
  }
}

/// 取码/设备列表被拒的原因像不像「票据或授权失效」。像就值得清缓存续期一次。
bool authRejectedMessage(String msg) {
  if (msg.contains('HTTP 401')) return true;
  final m = RegExp(r'code=(\d+)').firstMatch(msg);
  final code = m == null ? null : int.tryParse(m.group(1)!);
  if (code != null && const [401, 426, 70016].contains(code)) return true;
  final low = msg.toLowerCase();
  return ['auth', 'token', '登录', '授权'].any(low.contains);
}

/// 按「最可能是主中枢」排序的设备 did 列表。
///
/// 判据：localip == hub_ip 的排最前（唯一可靠的「这台就是网页主机」判据）；
/// 其次是在线的中枢型号；云端一个都没拉到时兜底用配置里的 did。
/// ★ 登录失效（isStale 认得出的那种）原样抛出，不吞 —— 吞了之后调用方
///   只会看到一句含糊的"取不到码"，而真正该做的是重新登录。
/// ★ 云端拒了缓存票据（authFailed）时：清缓存强制换新票再试一次；
///   换了新票还被拒 = 账号维度真失效 → 按「登录已失效」抛，转人工重登。
Future<List<String>> candidateDids(Map<String, Object?> cfg, String hubIp,
    {void Function(Object?)? log}) async {
  List<Map<String, Object?>> devs = [];
  var refreshed = false;
  while (true) {
    Object? listErr;
    try {
      final cred = await mint(cfg, sid: 'xiaomiio', forceRefresh: refreshed);
      final res = await listDevicesRaw(cred);
      if (authFailed(res)) {
        final why = 'code=${res['code']} message=${res['message'] ?? res['desc'] ?? ''}';
        if (refreshed) {
          // 换了新票还是被拒：服务端认的是账号，不是缓存 —— 该人工登录了。
          throw PasscodeError('小米登录已失效或需要验证，请重新登录一次：$why');
        }
        refreshed = true;
        clearTokenCache();
        log?.call('  云端拒了缓存的票据（$why）→ 清缓存强制换新票，再试一次');
        continue;
      }
      final result = res['result'];
      if (result is Map && result['list'] is List) {
        devs = [
          for (final d in (result['list'] as List))
            if (d is Map) Map<String, Object?>.from(d)
        ];
      } else {
        listErr = 'code=${res['code']} message=${res['message'] ?? res['desc'] ?? ''}';
      }
    } catch (e) {
      if (e is PasscodeError) rethrow;
      if (isStale(e)) {
        // 换票本身就说登录失效：换票用的是 passToken，不是缓存票 —— 真失效。
        throw PasscodeError('小米登录已失效或需要验证，请重新登录一次：$e');
      }
      listErr = e;
    }
    if (listErr != null) {
      log?.call('  云端设备列表拿不到：$listErr');
      devs = [];
    }
    break;
  }

  final hit = <Map<String, Object?>>[];
  final hubs = <Map<String, Object?>>[];
  for (final d in devs) {
    final model = '${d['model'] ?? ''}';
    final online = d['isOnline'] == true || '${d['isOnline']}'.toLowerCase() == 'true';
    if ('${d['localip'] ?? ''}' == hubIp) {
      hit.add(d);
    } else if (online && hubModels.any((m) => model.startsWith(m))) {
      hubs.add(d);
    }
  }
  int onlineRank(Map<String, Object?> d) =>
      (d['isOnline'] == true || '${d['isOnline']}'.toLowerCase() == 'true') ? 0 : 1;
  hit.sort((a, b) => onlineRank(a).compareTo(onlineRank(b)));
  hubs.sort((a, b) {
    final aDot1 = '${a['localip'] ?? ''}'.endsWith('.1') ? 0 : 1;
    final bDot1 = '${b['localip'] ?? ''}'.endsWith('.1') ? 0 : 1;
    return aDot1.compareTo(bDot1);
  });

  final out = <String>[];
  for (final d in [...hit, ...hubs]) {
    final did = '${d['did'] ?? ''}';
    if (did.isNotEmpty && !out.contains(did)) out.add(did);
  }
  final cfgDid = '${cfg['did'] ?? ''}'.trim();
  if (cfgDid.isNotEmpty && !out.contains(cfgDid)) out.add(cfgDid);
  return out;
}

/// 打 miIO.get_central_link_passcode，返回 6 位字符串。
Future<String> getPasscode(String did, Map<String, Object?> creds,
    [Map<String, Object?>? credIn]) async {
  final cred = credIn ?? await _mintSafe(creds);

  final data = jsonEncode({
    'id': 2,
    'method': 'miIO.get_central_link_passcode',
    'accessKey': _accessKey,
    'params': {},
  });

  // 这一版签名走明文表单（与 vendor/hub/取登录码.py 一致：不 RC4，只 HMAC）。
  final nonce = _passcodeNonce();
  final signed = base64.encode(crypto.sha256
      .convert(base64.decode('${cred['ssecurity']}') + base64.decode(nonce))
      .bytes);
  final key = base64.decode(signed);

  final signPath = '/home/rpc/$did'; // ★ 去掉 /app
  final signStr = [signPath, signed, nonce, 'data=$data'].join('&');
  final signature = base64
      .encode(crypto.Hmac(crypto.sha256, key).convert(utf8.encode(signStr)).bytes);

  final body = '_nonce=${Uri.encodeQueryComponent(nonce)}'
      '&data=${Uri.encodeQueryComponent(data)}'
      '&signature=${Uri.encodeQueryComponent(signature)}';

  final c = cloudClient(connTimeoutSecs: 25);
  try {
    return await withCloudDeadline(c, const Duration(seconds: 40), () async {
      final req = await c.postUrl(Uri.parse('$_rpcBase$did'));
      req.headers.set('Content-Type', 'application/x-www-form-urlencoded');
      req.headers.set('User-Agent', _ua);
      req.headers.set('X-XIAOMI-PROTOCAL-FLAG-CLI', 'PROTOCAL-HTTP2');
      req.headers.set('domain-refer', 'core.api.mijia.tech');
      req.headers.set('miot-request-model', 'xiaomi.gateway.hub1');
      req.headers.set('Accept', '*/*');
      req.headers.set('Cookie',
          'serviceToken=${cred['serviceToken']}; userId=${cred['userId']}; cUserId=${cred['cUserId']}');
      req.add(utf8.encode(body));
      final resp = await req.close();
      if (resp.statusCode != 200) {
        throw PasscodeError('取码 HTTP ${resp.statusCode}');
      }
      final raw = await resp.transform(utf8.decoder).join();
      Object? j;
      try {
        j = jsonDecode(raw);
      } catch (_) {
        throw PasscodeError(
            '取码响应解析失败：${raw.length > 200 ? raw.substring(0, 200) : raw}');
      }
      if (j is! Map) {
        throw PasscodeError(
            '取码响应不是对象：${raw.length > 200 ? raw.substring(0, 200) : raw}');
      }
      if (int.tryParse('${j['code']}') != 0) {
        throw PasscodeError('取码被拒：code=${j['code']} message=${j['message']}');
      }
      final result = j['result'];
      final code = result is Map ? '${result['passcode'] ?? ''}' : '';
      if (code.isEmpty) {
        throw PasscodeError(
            '响应里没有 passcode：${raw.length > 200 ? raw.substring(0, 200) : raw}');
      }
      return code;
    });
  } on PasscodeError {
    rethrow;
  } catch (e) {
    throw PasscodeError('取码请求失败：$e');
  } finally {
    disposeCloudClient(c);
  }
}

String _passcodeNonce() {
  final ms = DateTime.now().millisecondsSinceEpoch;
  final r1 = Random.secure().nextInt(1 << 32);
  final r2 = Random.secure().nextInt(1 << 32);
  // Python: (getrandbits(64) - 2**63) 的 8 字节大端 —— 等价取 8 随机字节。
  final bytes = <int>[
    (r1 >> 24) & 0xFF, (r1 >> 16) & 0xFF, (r1 >> 8) & 0xFF, r1 & 0xFF,
    (r2 >> 24) & 0xFF, (r2 >> 16) & 0xFF, (r2 >> 8) & 0xFF, r2 & 0xFF,
  ];
  final p2 = ms ~/ 60000;
  var v = p2;
  final p2bytes = <int>[];
  while (v > 0) {
    p2bytes.insert(0, v & 0xFF);
    v >>= 8;
  }
  return base64.encode([...bytes, ...p2bytes]);
}
