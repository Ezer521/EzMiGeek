// code_service.dart —— 本地取码服务：把 EzMiGeek 已登录的取码能力开放给
// 本机其它 Ez 系软件（首个消费方 = EzVibe 微软商店版——其云端取码链被
// 编译期封印，改为向本服务要码，商店包里保持零小米云代码）。
//
// 形态：127.0.0.1 随机端口 HTTP + 发现文件 %LOCALAPPDATA%\EzMiGeek\ipc.json
// （端口 + token + pid）。仅回环可达，不触发防火墙弹窗；token 防同机其它
// 进程顺手探测（发现文件与请求方同用户上下文，威胁模型到此为止）。
//
//   GET /ping?token=…            → {"ok":true,"version":"3.0.6"}
//   GET /code?token=…&hub=…&did=… → {"ok":true,"code":"123456"}
//                                  或 {"ok":false,"error":"…","needLogin":true}
//
// ★ 日志纪律：绝不把 6 位码本身写进日志（agent.log 里只记成败与参数）。
// ★ 崩溃残留：ipc.json 在退出时删除；异常退出会留陈旧文件——消费方必须
//   以「连得上 + 应答对」为准，不能只看文件存在。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../core/app_dirs.dart';
import '../mijia/passcode.dart' show fetchCode;
import 'app_log.dart';

/// 取码器：返回 6 位码；失败抛异常。可注入（测试用）。
typedef CodeFetcher = Future<String> Function(String hubIp, String? preferredDid);

Future<String> _defaultFetch(String hubIp, String? preferredDid) async {
  final (code, _) =
      await fetchCode(hubIp, preferredDid: preferredDid, log: AppLog.write);
  return code;
}

String _randomToken() {
  final r = Random.secure();
  return List.generate(32, (_) => r.nextInt(256))
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
}

bool _looksLikeNeedLogin(String msg) =>
    msg.contains('重新登录') || msg.contains('登录已失效');

class CodeService {
  HttpServer? _server;
  String _token = '';
  String _ipcPath = '';
  final CodeFetcher fetcher;
  final String? dirOverride;

  CodeService({this.fetcher = _defaultFetch, this.dirOverride});

  int? get port => _server?.port;
  String get token => _token;

  /// 启动并写发现文件。返回监听端口（失败记日志返回 null，绝不拖垮主程序）。
  Future<int?> start() async {
    try {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _token = _randomToken();
      _server = server;
      _ipcPath = '${dirOverride ?? dataDir()}\\ipc.json';
      server.listen(_onReq, onError: (Object e) {
        AppLog.write('取码服务：连接异常（不影响主流程）：$e');
      });
      File(_ipcPath).writeAsStringSync(jsonEncode({
            'port': server.port,
            'token': _token,
            'pid': pid,
            'started': DateTime.now().toIso8601String(),
          }), flush: true);
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

  Future<void> _onReq(HttpRequest req) async {
    try {
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
    final q = req.uri.queryParameters;
    if (q['token'] != _token) {
      req.response.statusCode = 403;
      await _respond(req.response, {'ok': false, 'error': 'token 不对'});
      return true;
    }
    if (path == '/ping') {
      await _respond(req.response, {'ok': true, 'service': 'ezmigeek-code'});
      return true;
    }
    final hub = (q['hub'] ?? '').trim();
    final did = (q['did'] ?? '').trim();
    if (hub.isEmpty && did.isEmpty) {
      await _respond(
          req.response, {'ok': false, 'error': '缺少 hub 或 did 参数'});
      return true;
    }
    try {
      final code = await fetcher(hub, did.isEmpty ? null : did);
      AppLog.write('取码服务：取码成功'
          '${did.isNotEmpty ? '（did=$did）' : ''}${hub.isNotEmpty ? '（hub=$hub）' : ''}');
      await _respond(req.response, {'ok': true, 'code': code});
    } catch (e) {
      final msg = '$e';
      final needLogin = _looksLikeNeedLogin(msg);
      AppLog.write('取码服务：取码失败${needLogin ? '（需重新登录）' : ''}：$msg');
      await _respond(req.response,
          {'ok': false, 'error': msg, 'needLogin': needLogin});
    }
    return true;
  }

  Future<void> _respond(HttpResponse res, Map<String, Object?> body) async {
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode(body));
    await res.close();
  }
}
