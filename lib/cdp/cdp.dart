// cdp.dart —— 裸 CDP 客户端（app/cdp.py 移植；dart:io WebSocket 承载）。
//
// Tab 的做法与 Python 版一致：发一条、等回那条（cmd 同步语义）。
// BrowserSession 是浏览器级会话（不是某个标签页）——用来读整个 profile 的
// cookie。实测（Edge 153）：浏览器级 target 上 Network 域不存在，能用的
// 是 Storage.getCookies（不需要 enable）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

class CdpError implements Exception {
  CdpError(this.message);
  final String message;
  @override
  String toString() => message;
}

class CdpTab {
  CdpTab(String wsUrl) {
    _connect(wsUrl);
  }

  WebSocket? _ws;
  final Map<int, Completer<Map<String, Object?>>> _pending = {};
  int _n = 0;
  bool _ready = false;
  final _readyCompleter = Completer<void>();
  Duration timeout = const Duration(seconds: 30);

  Future<void> _connect(String wsUrl) async {
    try {
      final ws = await WebSocket.connect(wsUrl);
      _ws = ws;
      ws.listen((data) {
        try {
          final msg = jsonDecode(data as String);
          if (msg is Map) {
            final id = int.tryParse('${msg['id']}');
            if (id != null && _pending.containsKey(id)) {
              _pending.remove(id)!.complete(Map<String, Object?>.from(msg));
            }
          }
        } catch (_) {}
      }, onError: (Object e) => _failAll(e), onDone: () => _failAll('closed'));
      _ready = true;
      _readyCompleter.complete();
    } catch (e) {
      _readyCompleter.completeError(CdpError('CDP 连接失败：$e'));
    }
  }

  void _failAll(Object reason) {
    _ready = false;
    for (final c in _pending.values) {
      if (!c.isCompleted) c.complete({'error': '连接已断开：$reason'});
    }
    _pending.clear();
  }

  Future<void> waitReady() => _readyCompleter.future;

  bool get isOpen => _ready && _ws != null;

  /// 发一条命令、等回那条。连接断了返回 {'error': …}（不抛 —— 浏览器被关
  /// 之后连接是被硬掐断的，异常一路穿到顶层会把程序打死）。
  Future<Map<String, Object?>> cmd(String method, {Map<String, Object?>? params}) async {
    final ws = _ws;
    if (ws == null || !_ready) return {'error': '连接未就绪'};
    _n += 1;
    final mid = _n;
    final completer = Completer<Map<String, Object?>>();
    _pending[mid] = completer;
    try {
      ws.add(jsonEncode({
        'id': mid,
        'method': method,
        'params': params ?? const {},
      }));
    } catch (e) {
      _pending.remove(mid);
      return {'error': '$e'};
    }
    try {
      return await completer.future.timeout(timeout, onTimeout: () => {'error': 'timeout'});
    } finally {
      _pending.remove(mid);
    }
  }

  /// 在页面主世界执行表达式，返回 JS 值。失败返回 null。
  Future<Object?> js(String expr, {bool awaitPromise = false}) async {
    final r = await cmd('Runtime.evaluate', params: {
      'expression': expr,
      'returnByValue': true,
      'awaitPromise': awaitPromise,
    });
    try {
      final result = r['result'];
      if (result is Map) {
        final inner = result['result'];
        if (inner is Map) return inner['value'];
      }
    } catch (_) {}
    return null;
  }

  /// 在导航【之前】注册注入脚本，返回 CDP 给的 identifier。
  Future<String?> installAgent(String source) async {
    final r = await cmd('Page.addScriptToEvaluateOnNewDocument', params: {'source': source});
    final result = r['result'];
    if (result is Map) return '${result['identifier'] ?? ''}';
    return null;
  }

  void close() {
    _ready = false;
    try {
      _ws?.close();
    } catch (_) {}
    _failAll('closed');
  }
}

/// 浏览器级 CDP 会话 —— 读整个 profile 的 cookie（首次登录引导用）。
class BrowserSession {
  BrowserSession(String wsUrl) : _tab = CdpTab(wsUrl);

  final CdpTab _tab;

  Future<void> waitReady() => _tab.waitReady();

  /// 整个 profile 的 cookie 列表。浏览器级 target 没有 Network 域，
  /// Network.getAllCookies 会报 wasn't found —— 跳过它用 Storage.getCookies。
  Future<List<Map<String, Object?>>> allCookies() async {
    for (final method in ['Storage.getCookies', 'Network.getAllCookies']) {
      final r = await _tab.cmd(method);
      final err = '${r['error'] ?? ''}';
      if (err.contains("wasn't found")) continue;
      final result = r['result'];
      if (result is Map) {
        final cs = result['cookies'];
        if (cs is List) {
          return [for (final c in cs) if (c is Map) Map<String, Object?>.from(c)];
        }
      }
    }
    return [];
  }

  void close() => _tab.close();
}
