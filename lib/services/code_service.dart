// code_service.dart —— 可选的本地回环取码 IPC 服务。
//
// 面向本机其他工具开放已登录的取码能力，避免重复维护小米账号登录态。
// 形态：仅监听 127.0.0.1 随机端口，不触发防火墙弹窗；端口与一次性随机
// token 写入 %LOCALAPPDATA%\EzMiGeek\ipc.json（可在 settings.json 中通过
// "LocalCodeService": false 关闭）。
//
// 接口（仅限 GET，要求 Host 为本机回环；鉴权支持 Authorization: Bearer <token>
// 请求头或兼容性的 ?token=<token> 参数）：
//   GET /ping              → {"ok":true,"service":"ezmigeek-code","version":"..."}
//   GET /code?hub=…&did=…  → {"ok":true,"code":"123456"}
//                             或 {"ok":false,"error":"…","needLogin":true}
//
// ★ 日志纪律：绝不把 6 位登录码本身写进日志（agent.log 里只记成败与参数）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../core/app_dirs.dart';
import '../mijia/passcode.dart' show fetchCode;
import 'app_log.dart';

/// 取码器：返回 6 位码；失败抛异常。可注入（测试用）。
typedef CodeFetcher = Future<String> Function(String hubIp, String? preferredDid);

/// 内存凭据读取器（写盘失败兜底时同步给本地取码服务）。
typedef CredsProvider = Map<String, Object?>? Function();

String _randomToken() {
  final r = Random.secure();
  return List.generate(32, (_) => r.nextInt(256))
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
}

/// 常量时间字符串比对，降低 token 校验侧信道暴露。
bool _constantTimeEquals(String a, String b) {
  final ab = utf8.encode(a);
  final bb = utf8.encode(b);
  var diff = ab.length ^ bb.length;
  final len = ab.length < bb.length ? ab.length : bb.length;
  for (var i = 0; i < len; i++) {
    diff |= ab[i] ^ bb[i];
  }
  return diff == 0;
}

bool _isLoopbackHostHeader(String? hostHeader) {
  if (hostHeader == null || hostHeader.isEmpty) return true;
  final h = hostHeader.trim().toLowerCase();
  final bare = h.startsWith('[')
      ? h.substring(1, h.contains(']') ? h.indexOf(']') : h.length)
      : h.split(':').first;
  return bare == '127.0.0.1' || bare == 'localhost' || bare == '::1';
}

bool _looksLikeNeedLogin(String msg) =>
    msg.contains('重新登录') || msg.contains('登录已失效');

class CodeService {
  HttpServer? _server;
  String _token = '';
  String _ipcPath = '';
  final CodeFetcher? _customFetcher;
  final CredsProvider? credsProvider;
  final String? dirOverride;
  final String version;

  CodeService({
    CodeFetcher? fetcher,
    this.credsProvider,
    this.dirOverride,
    this.version = '3.1.0',
  }) : _customFetcher = fetcher;

  Future<String> _fetch(String hubIp, String? preferredDid) async {
    final custom = _customFetcher;
    if (custom != null) return custom(hubIp, preferredDid);
    final (code, _) = await fetchCode(
      hubIp,
      preferredDid: preferredDid,
      cfg: credsProvider?.call(),
      log: AppLog.write,
    );
    return code;
  }

  int? get port => _server?.port;
  String get token => _token;

  /// 启动并写发现文件。返回监听端口（失败记日志返回 null，绝不拖垮主程序）。
  Future<int?> start() async {
    try {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _token = _randomToken();
      _server = server;
      _ipcPath = pJoin(dirOverride ?? dataDir(), 'ipc.json');
      server.listen(_onReq, onError: (Object e) {
        AppLog.write('取码服务：连接异常（不影响主流程）：$e');
      });
      final payload = jsonEncode({
        'port': server.port,
        'token': _token,
        'pid': pid,
        'version': version,
        'started': DateTime.now().toIso8601String(),
      });
      final tmp = '$_ipcPath.tmp';
      File(tmp).writeAsStringSync(payload, flush: true);
      try {
        File(tmp).renameSync(_ipcPath);
      } catch (_) {
        File(_ipcPath).writeAsStringSync(payload, flush: true);
        try {
          File(tmp).deleteSync();
        } catch (_) {}
      }
      AppLog.write('取码服务：已监听 127.0.0.1:${server.port}（发现文件 $_ipcPath）');
      return server.port;
    } catch (e) {
      AppLog.write('取码服务：启动失败（不影响主流程）：$e');
      return null;
    }
  }

  Future<void> stop() async {
    try {
      await _server?.close();
    } catch (_) {}
    _server = null;
    if (_ipcPath.isNotEmpty) {
      try {
        final f = File(_ipcPath);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
    AppLog.write('取码服务：已停止，发现文件已清理。');
  }

  String _extractToken(HttpRequest req) {
    final auth = req.headers.value(HttpHeaders.authorizationHeader) ?? '';
    if (auth.toLowerCase().startsWith('bearer ')) {
      return auth.substring(7).trim();
    }
    return req.uri.queryParameters['token'] ?? '';
  }

  Future<void> _onReq(HttpRequest req) async {
    try {
      if (!_isLoopbackHostHeader(req.headers.value(HttpHeaders.hostHeader))) {
        req.response.statusCode = 403;
        await _respond(req.response, {'ok': false, 'error': '非法 Host 头'});
        return;
      }
      if (req.method.toUpperCase() != 'GET') {
        req.response.statusCode = 405;
        await _respond(req.response, {'ok': false, 'error': '仅支持 GET'});
        return;
      }
      final ok = await _route(req);
      if (!ok) {
        req.response.statusCode = 404;
        await req.response.close();
      }
    } catch (e) {
      AppLog.write('取码服务：处理请求异常：$e');
      try {
        req.response.statusCode = 500;
        await req.response.close();
      } catch (_) {}
    }
  }

  /// 分发；返回是否命中已知路由。
  Future<bool> _route(HttpRequest req) async {
    final path = req.uri.path;
    if (path != '/ping' && path != '/code') return false;
    final provided = _extractToken(req);
    if (!_constantTimeEquals(provided, _token)) {
      req.response.statusCode = 403;
      await _respond(req.response, {'ok': false, 'error': 'token 不对'});
      return true;
    }
    if (path == '/ping') {
      await _respond(
        req.response,
        {'ok': true, 'service': 'ezmigeek-code', 'version': version},
      );
      return true;
    }
    final q = req.uri.queryParameters;
    final hub = (q['hub'] ?? '').trim();
    final did = (q['did'] ?? '').trim();
    if (hub.isEmpty && did.isEmpty) {
      await _respond(
        req.response,
        {'ok': false, 'error': '缺少 hub 或 did 参数'},
      );
      return true;
    }
    try {
      final code = await _fetch(hub, did.isEmpty ? null : did);
      AppLog.write(
        '取码服务：取码成功'
        '${did.isNotEmpty ? '（did=$did）' : ''}${hub.isNotEmpty ? '（hub=$hub）' : ''}',
      );
      await _respond(req.response, {'ok': true, 'code': code});
    } catch (e) {
      final msg = '$e';
      final needLogin = _looksLikeNeedLogin(msg);
      AppLog.write('取码服务：取码失败${needLogin ? '（需重新登录）' : ''}：$msg');
      await _respond(
        req.response,
        {'ok': false, 'error': msg, 'needLogin': needLogin},
      );
    }
    return true;
  }

  Future<void> _respond(HttpResponse res, Map<String, Object?> body) async {
    res.headers.contentType = ContentType.json;
    res.headers.set('Cache-Control', 'no-store');
    res.write(jsonEncode(body));
    await res.close();
  }
}
