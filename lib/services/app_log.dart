// app_log.dart —— 日志：%LOCALAPPDATA%\EzMiGeek\logs\agent.log。
library;

import 'dart:io';

import '../core/app_dirs.dart';

class AppLog {
  static IOSink? _sink;

  static void write(Object? message) {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final line =
        '${two(now.hour)}:${two(now.minute)}:${two(now.second)} $message';
    try {
      stdout.writeln(line);
    } catch (_) {}
    try {
      _sink ??= File('${logsDir()}\\agent.log')
          .openWrite(mode: FileMode.append);
      _sink!.writeln(line);
      _sink!.flush();
    } catch (_) {}
  }

  static void close() {
    _sink?.close();
    _sink = null;
  }
}
