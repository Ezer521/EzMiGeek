// app_log.dart —— 日志：%LOCALAPPDATA%\EzMiGeek\logs\agent.log 与 crash.log。
//
// 采用同步追加写并带自动大小轮转（超过 2 MB 滚动到 agent.log.1），避免
// IOSink 未 await flush() 引发的并发 StateError 与长期挂机磁盘无限膨胀。
library;

import 'dart:io';

import '../core/app_dirs.dart';

class AppLog {
  static const int _maxBytes = 2 * 1024 * 1024; // 2 MB
  static int _writesSinceRotateCheck = 0;

  static String _stamp() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
  }

  static void _rotateIfNeeded(File f) {
    try {
      if (!f.existsSync()) return;
      if (f.lengthSync() < _maxBytes) return;
      final bak = File('${f.path}.1');
      if (bak.existsSync()) {
        try {
          bak.deleteSync();
        } catch (_) {}
      }
      f.renameSync(bak.path);
    } catch (_) {}
  }

  static void write(Object? message) {
    final line = '${_stamp()} $message';
    try {
      stdout.writeln(line);
    } catch (_) {}
    try {
      final f = File(pJoin(logsDir(), 'agent.log'));
      if (_writesSinceRotateCheck++ % 64 == 0) {
        _rotateIfNeeded(f);
      }
      f.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  /// 写入未捕获异常崩溃记录（logs/crash.log）。
  static void writeCrash(Object error, StackTrace stack) {
    final ts = DateTime.now().toIso8601String();
    final block = '=== CRASH $ts ===\n$error\n$stack\n\n';
    try {
      final f = File(pJoin(logsDir(), 'crash.log'));
      _rotateIfNeeded(f);
      f.writeAsStringSync(block, mode: FileMode.append, flush: true);
    } catch (_) {}
    write('× 未捕获异常（详见 crash.log）：$error');
  }

  static void close() {
    // 同步追加写每次即落盘并关闭句柄，无常驻 IOSink 泄漏风险。
  }
}
