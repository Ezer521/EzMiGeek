// mijia_cloud.dart —— 小米云直连（vendor/hub/mijia_cloud.py + 凭据存储.py 移植）。
//
//   · 凭据：整份 JSON 经 DPAPI 加密落 %LOCALAPPDATA%\EzMiGeek\config.json，
//     与 Python/C# 版同格式同熵，三代实现读写同一份文件。
//   · 换票：serviceLogin?sid=… 拿 serviceToken（缓存 6 小时，同样加密落盘）。
//   · 设备列表：RC4 加签的 /app/home/device_list。
//
// 只发小米官方接口；日志只打字段名与原因，绝不打 cookie / token 的值。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../core/app_dirs.dart';
import '../services/dpapi.dart';

class MijiaError implements Exception {
  MijiaError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 登录凭据的四个必需字段（cookie 里能拿到的全集）。
const List<String> requiredCredKeys = [
  'userId',
  'passToken',
  'cUserId',
  'deviceId',
];

/// 有「虚拟服务 / 中枢链接」能力的设备型号前缀（mijia_cloud.HUB_MODELS）。
const List<String> hubModels = [
  'xiaomi.gateway.hub',
  'xiaomi.router.',
  'xiaomi.gateway.',
];

const String _ua =
    'Android-7.1.1-1.0.0-ONEPLUS A3010-136-ABCDEFABCDEF0 APP/xiaomi.smarthome APPV/62830';

const String _api = 'https://api.io.mi.com';
const String _listPath = '/app/home/device_list';
const String _listSign = '/home/device_list';
const String _listData =
    '{"getVirtualModel":true,"getHuamiDevices":1,'
    '"get_split_device":false,"support_smart_home":true}';

/// serviceToken 缓存时长（秒）。
const int _tokenMaxAge = 6 * 3600;

String _tokenCachePath() => pJoin(dataDir(), '.token-cache.json');
String _deviceCachePath() => pJoin(dataDir(), '.device-cache.json');

// ══════════════════ 凭据存取（DPAPI，同 Python 凭据存储.py）══════════════════

Map<String, Object?> loadCfg([String? path]) {
  final p = path ?? credsPath();
  final f = File(p);
  if (!f.existsSync()) {
    throw MijiaError('还没有小米凭据：$p');
  }
  Map<String, Object?> raw;
  try {
    raw = Map<String, Object?>.from(jsonDecode(f.readAsStringSync()) as Map);
  } catch (e) {
    throw MijiaError('凭据文件读取失败：$e');
  }
  if (raw['_encrypted'] == true) {
    try {
      final plain = utf8.decode(
        dpapiUnprotect(base64.decode('${raw['blob']}')),
      );
      return Map<String, Object?>.from(jsonDecode(plain) as Map);
    } on StateError {
      rethrow;
    } catch (e) {
      throw MijiaError('凭据解密失败：$e');
    }
  }
  // 旧明文格式：读出来顺手转成加密存储（透明迁移，同 Python 版）。
  if ('${raw['passToken'] ?? ''}'.isNotEmpty) {
    try {
      saveCfg(raw, p);
    } catch (_) {}
  }
  return raw;
}

bool saveCfg(Map<String, Object?> cfg, [String? path]) {
  final p = path ?? credsPath();
  try {
    final data = utf8.encode(const JsonEncoder.withIndent('  ').convert(cfg));
    final obj = <String, Object?>{
      '_说明': '小米账号凭据使用 Windows DPAPI 加密，仅当前电脑当前用户可解。',
      '_encrypted': true,
      'blob': base64.encode(dpapiProtect(data)),
    };
    final tmp = '$p.tmp';
    File(tmp).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(obj),
      flush: true,
    );
    final main = File(p);
    if (main.existsSync()) main.deleteSync();
    File(tmp).renameSync(p);
    return true;
  } catch (_) {
    return false;
  }
}

// ══════════════════ 本地缓存（票据 / 设备，都加密落盘）══════════════════

Map<String, Object?> _readJson(String path) {
  try {
    final raw = jsonDecode(File(path).readAsStringSync());
    if (raw is Map && raw['_encrypted'] == true) {
      return Map<String, Object?>.from(
        jsonDecode(utf8.decode(dpapiUnprotect(base64.decode('${raw['blob']}'))))
            as Map,
      );
    }
    if (raw is Map) return Map<String, Object?>.from(raw);
  } catch (_) {}
  return {};
}

bool _writeJson(String path, Map<String, Object?> obj) {
  try {
    Map<String, Object?> toWrite = obj;
    if (path == _tokenCachePath()) {
      // serviceToken / ssecurity 也是敏感令牌，缓存同样加密落盘。
      final data = utf8.encode(jsonEncode(obj));
      toWrite = {'_encrypted': true, 'blob': base64.encode(dpapiProtect(data))};
    }
    final tmp = '$path.tmp';
    File(tmp).writeAsStringSync(jsonEncode(toWrite), flush: true);
    final main = File(path);
    if (main.existsSync()) main.deleteSync();
    File(tmp).renameSync(path);
    return true;
  } catch (_) {
    return false;
  }
}

String _accountKey(Map<String, Object?> cfg) => crypto.sha256
    .convert(utf8.encode('${cfg['userId']}:${cfg['passToken']}'))
    .toString();

void clearTokenCache() {
  try {
    final f = File(_tokenCachePath());
    if (f.existsSync()) f.deleteSync();
  } catch (_) {}
}

void clearDeviceCache() {
  try {
    final f = File(_deviceCachePath());
    if (f.existsSync()) f.deleteSync();
  } catch (_) {}
}

// ══════════════════ 请求通道（整体超时 + 退出可取消）══════════════════
//
// ★ connectionTimeout 只管「连上」；连上之后服务端不吐正文，请求会永远挂着
//   （审查 2026-10-06 修4）。所以：
//   · 每个请求整体给一个 deadline（发出 → 收完正文），到点 force close，
//     挂着的读立刻报错，上层重试/超时逻辑照常接管；
//   · 所有在途客户端都登记在册，quit() 调 cancelCloudRequests() 一刀全掐，
//     退出不再被一个僵死请求拖住（WaitMin 也终于管得到它）。

final List<HttpClient> _liveClients = [];

HttpClient cloudClient({int connTimeoutSecs = 20}) {
  final c = HttpClient()..findProxy = null; // 绕开宿主环境的 http_proxy
  c.connectionTimeout = Duration(seconds: connTimeoutSecs);
  _liveClients.add(c);
  return c;
}

void disposeCloudClient(HttpClient c) {
  _liveClients.remove(c);
  try {
    c.close(force: true);
  } catch (_) {}
}

/// 掐断所有在途云接口请求（AppState.quit 调用）。
void cancelCloudRequests() {
  for (final c in List<HttpClient>.of(_liveClients)) {
    disposeCloudClient(c);
  }
}

/// 给整个请求（发出去 → 收完正文）设一个整体截止时间。
Future<T> withCloudDeadline<T>(
  HttpClient c,
  Duration total,
  Future<T> Function() body,
) {
  return body().timeout(
    total,
    onTimeout: () {
      c.close(force: true); // 掐断底层 socket：还挂着的读立刻炸掉
      throw TimeoutException('云接口整体超时（${total.inSeconds}s）');
    },
  );
}

// ══════════════════ 换票（mint）══════════════════

String _nonce() {
  final ms = DateTime.now().millisecondsSinceEpoch;
  final bb = BytesBuilder();
  final r1 = Random.secure().nextInt(1 << 32);
  final r2 = Random.secure().nextInt(1 << 32);
  // Python: (getrandbits(64) - 2**63) 的 8 字节大端 —— 这里等价取 8 随机字节。
  bb.add([
    (r1 >> 24) & 0xFF,
    (r1 >> 16) & 0xFF,
    (r1 >> 8) & 0xFF,
    r1 & 0xFF,
    (r2 >> 24) & 0xFF,
    (r2 >> 16) & 0xFF,
    (r2 >> 8) & 0xFF,
    r2 & 0xFF,
  ]);
  final p2 = ms ~/ 60000;
  final p2bytes = <int>[];
  var v = p2;
  while (v > 0) {
    p2bytes.insert(0, v & 0xFF);
    v >>= 8;
  }
  bb.add(p2bytes);
  return base64.encode(bb.toBytes());
}

Future<Map<String, Object?>> _mintViaSession(
  HttpClient c,
  Map<String, Object?> cfg,
  String sid,
) async {
  final cookie =
      'userId=${cfg['userId']}; passToken=${cfg['passToken']}; '
      'cUserId=${cfg['cUserId']}; deviceId=${cfg['deviceId']}';
  final req = await c.getUrl(
    Uri.parse(
      'https://account.xiaomi.com/pass/serviceLogin?sid=$sid&_json=true&_locale=zh_CN',
    ),
  );
  req.headers.set('User-Agent', _ua);
  req.headers.set('Cookie', cookie);
  final resp = await req.close();
  final body = (await resp.transform(utf8.decoder).join())
      .replaceFirst('&&&START&&&', '')
      .trim();
  final j = jsonDecode(body);
  if (j is! Map || j['result'] != 'ok' || '${j['location'] ?? ''}'.isEmpty) {
    throw MijiaError(
      '小米登录已失效或需要验证（result=${j is Map ? j['result'] : '?'}），请重新登录一次',
    );
  }
  // 跟 30x 去 sts 域拿 serviceToken。★ 手动跟重定向：自动跟随只给最终响应，
  // 中间跳转的 Set-Cookie 会被丢掉 —— serviceToken 正是跳转链里发的。
  var tok = '';
  var url = Uri.parse('${j['location']}');
  for (var hop = 0; hop < 6 && tok.isEmpty; hop++) {
    final req2 = await c.openUrl('GET', url);
    req2.headers.set('User-Agent', _ua);
    req2.followRedirects = false;
    final resp2 = await req2.close();
    await resp2.drain<void>();
    for (final v in resp2.headers['set-cookie'] ?? const <String>[]) {
      if (v.startsWith('serviceToken=')) {
        tok = v.substring('serviceToken='.length).split(';').first;
      }
    }
    final loc = resp2.headers.value(HttpHeaders.locationHeader);
    if (loc != null && loc.isNotEmpty) {
      url = Uri.parse(loc);
      continue;
    }
    break;
  }
  if (tok.isEmpty) {
    throw MijiaError('换票成功但没拿到 serviceToken');
  }
  return {
    'serviceToken': tok,
    'ssecurity': '${j['ssecurity']}',
    'userId': '${j['userId']}',
    'cUserId': '${j['cUserId'] ?? cfg['cUserId']}',
  };
}

/// mint：拿一张 sid 对应的 serviceToken（带缓存，过期或强制时重新换）。
Future<Map<String, Object?>> mint(
  Map<String, Object?> cfg, {
  String sid = 'xiaomiio',
  bool useCache = true,
  bool forceRefresh = false,
}) async {
  if (useCache && !forceRefresh) {
    final e = (_readJson(_tokenCachePath())[sid] as Map?) ?? {};
    if (e['serviceToken'] != null &&
        e['ssecurity'] != null &&
        e['account'] == _accountKey(cfg)) {
      final ts = double.tryParse('${e['ts'] ?? 0}') ?? 0;
      if (DateTime.now().millisecondsSinceEpoch / 1000 - ts < _tokenMaxAge) {
        return Map<String, Object?>.from(e);
      }
    }
  }
  final c = cloudClient(connTimeoutSecs: 20);
  try {
    final cred = await withCloudDeadline(
      c,
      const Duration(seconds: 45),
      () async {
        return await _mintViaSession(c, cfg, sid);
      },
    );
    cred['ts'] = DateTime.now().millisecondsSinceEpoch / 1000;
    cred['account'] = _accountKey(cfg);
    if (useCache) {
      final all = _readJson(_tokenCachePath());
      all[sid] = cred;
      _writeJson(_tokenCachePath(), all);
    }
    return cred;
  } on MijiaError {
    rethrow;
  } catch (e) {
    throw MijiaError('换票请求失败：$e');
  } finally {
    disposeCloudClient(c);
  }
}

// ══════════════════ RC4 + 签名 ══════════════════

/// RC4（跳过前 1024 字节的密钥流）—— 与小米云 App 协议一致。
Uint8List rc4(Uint8List key, Uint8List data, {int skip = 1024}) {
  final s = List<int>.generate(256, (i) => i);
  var j = 0;
  for (var i = 0; i < 256; i++) {
    j = (j + s[i] + key[i % key.length]) & 255;
    final t = s[i];
    s[i] = s[j];
    s[j] = t;
  }
  final out = Uint8List(data.length);
  var i = 0;
  j = 0;
  for (var c = 0; c < skip + data.length; c++) {
    i = (i + 1) & 255;
    j = (j + s[i]) & 255;
    final t = s[i];
    s[i] = s[j];
    s[j] = t;
    final k = s[(s[i] + s[j]) & 255];
    if (c >= skip) {
      out[c - skip] = data[c - skip] ^ k;
    }
  }
  return out;
}

String _signNonce(Map<String, Object?> cred, String nonce) => base64.encode(
  crypto.sha256
      .convert(base64.decode('${cred['ssecurity']}') + base64.decode(nonce))
      .bytes,
);

String _cookie(Map<String, Object?> cred) =>
    'userId=${cred['userId']}; yetAnotherServiceToken=${cred['serviceToken']}; '
    'serviceToken=${cred['serviceToken']}; locale=zh_CN; timezone=GMT+8:00; '
    'is_daylight=0; dst_offset=0; channel=MI_APP_STORE';

Future<Map<String, Object?>> _callRc4(
  Map<String, Object?> cred,
  String path,
  String signPath,
  String data,
) async {
  final nonce = _nonce();
  final sn = _signNonce(cred, nonce);
  final key = base64.decode(sn);

  final encData = base64.encode(rc4(key, utf8.encode(data)));
  final h1 = base64.encode(
    crypto.sha1
        .convert(utf8.encode(['POST', signPath, 'data=$data', sn].join('&')))
        .bytes,
  );
  final encHash = base64.encode(rc4(key, utf8.encode(h1)));
  final sig = base64.encode(
    crypto.sha1
        .convert(
          utf8.encode(
            [
              'POST',
              signPath,
              'data=$encData',
              'rc4_hash__=$encHash',
              sn,
            ].join('&'),
          ),
        )
        .bytes,
  );

  final body =
      'data=${Uri.encodeQueryComponent(encData)}'
      '&rc4_hash__=${Uri.encodeQueryComponent(encHash)}'
      '&signature=${Uri.encodeQueryComponent(sig)}'
      '&ssecurity=${Uri.encodeQueryComponent('${cred['ssecurity']}')}'
      '&_nonce=${Uri.encodeQueryComponent(nonce)}';

  final c = cloudClient(connTimeoutSecs: 30);
  try {
    return await withCloudDeadline(c, const Duration(seconds: 45), () async {
      final req = await c.postUrl(Uri.parse(_api + path));
      req.headers.set('Content-Type', 'application/x-www-form-urlencoded');
      req.headers.set('Accept-Encoding', 'identity');
      req.headers.set('x-xiaomi-protocal-flag-cli', 'PROTOCAL-HTTP2');
      req.headers.set('MIOT-ENCRYPT-ALGORITHM', 'ENCRYPT-RC4');
      req.headers.set('User-Agent', _ua);
      req.headers.set('Cookie', _cookie(cred));
      req.add(utf8.encode(body));
      final resp = await req.close();
      final raw = (await resp.transform(utf8.decoder).join()).trim();
      if (raw.isEmpty) return <String, Object?>{};
      try {
        final plain = utf8.decode(
          rc4(key, base64.decode(raw)),
          allowMalformed: true,
        );
        final j = jsonDecode(plain);
        if (j is Map) return Map<String, Object?>.from(j);
        return {'raw': plain};
      } catch (_) {
        return {'raw': raw};
      }
    });
  } catch (e) {
    throw MijiaError('云接口请求失败：$e');
  } finally {
    disposeCloudClient(c);
  }
}

// ══════════════════ 业务 ══════════════════

Future<List<Map<String, Object?>>> listDevices(
  Map<String, Object?> cred,
) async {
  final r = await listDevicesRaw(cred);
  final result = r['result'];
  if (result is Map) {
    final list = result['list'];
    if (list is List) {
      return [
        for (final d in list)
          if (d is Map) Map<String, Object?>.from(d),
      ];
    }
  }
  return [];
}

/// 设备列表的【原始答复】（含 code/message）——鉴权被拒时上层要靠它
/// 判断该不该清票据缓存自动续期（listDevices 旧版会把被拒吞成空列表）。
Future<Map<String, Object?>> listDevicesRaw(Map<String, Object?> cred) =>
    _callRc4(cred, _listPath, _listSign, _listData);

/// 云端的答复像不像「凭据不对」，像就值得清缓存重试一次。
bool authFailed(Map<String, Object?> res) {
  final code = int.tryParse('${res['code']}');
  if (code != null && const [401, 426, 70016].contains(code)) return true;
  final msg = '${res['message'] ?? res['desc'] ?? ''}'.toLowerCase();
  return ['auth', 'login', 'token', '登录', '授权'].any(msg.contains);
}
