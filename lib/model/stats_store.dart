// stats_store.dart —— 登录次数统计。
// 「一次成功」= 登录码被页面接受、输码界面消失的那一刻。
library;

import 'dart:convert';
import 'dart:io';

import '../core/app_dirs.dart';

class Stats {
  int total = 0;
  String day = '';
  int today = 0;
  String lastAt = ''; // ISO 时间；'' = 无记录
  double lastSecs = 0;

  static String _todayStr(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// 跨天归零：程序长期常驻托盘时，次日展示和计数前自动清零今日计数。
  void rolloverIfNeeded([DateTime? now]) {
    final todayStr = _todayStr(now ?? DateTime.now());
    if (day != todayStr) {
      today = 0;
      day = todayStr;
    }
  }

  static Stats normalize(Object? raw, {DateTime? now}) {
    final s = Stats();
    if (raw is Map) {
      s.total = int.tryParse('${raw['Total']}') ?? 0;
      if (s.total < 0) s.total = 0;
      s.today = int.tryParse('${raw['Today']}') ?? 0;
      if (s.today < 0) s.today = 0;
      s.day = '${raw['Day'] ?? ''}';
      s.lastAt = '${raw['LastAt'] ?? ''}';
      s.lastSecs = double.tryParse('${raw['LastSecs']}') ?? 0;
      if (s.lastSecs < 0) s.lastSecs = 0;
    }
    s.rolloverIfNeeded(now);
    return s;
  }

  static Stats load() {
    try {
      final f = File(statsPath());
      if (!f.existsSync()) return Stats()..rolloverIfNeeded();
      return Stats.normalize(jsonDecode(f.readAsStringSync()));
    } catch (_) {
      return Stats()..rolloverIfNeeded();
    }
  }

  Stats bump({double? secs, DateTime? now, bool persist = true}) {
    final ts = now ?? DateTime.now();
    rolloverIfNeeded(ts);
    total += 1;
    today += 1;
    lastAt = ts.toIso8601String();
    if (secs != null && secs >= 0) lastSecs = secs;
    if (persist) save();
    return this;
  }

  void save() {
    final p = statsPath();
    final tmp = '$p.tmp';
    final content = const JsonEncoder.withIndent('  ').convert({
      'Total': total,
      'Day': day,
      'Today': today,
      'LastAt': lastAt,
      'LastSecs': lastSecs,
    });
    File(tmp).writeAsStringSync(content, flush: true);
    try {
      File(tmp).renameSync(p);
    } catch (_) {
      final main = File(p);
      if (main.existsSync()) main.deleteSync();
      File(tmp).renameSync(p);
    }
  }

  DateTime? get lastAtDateTime => DateTime.tryParse(lastAt);
}
