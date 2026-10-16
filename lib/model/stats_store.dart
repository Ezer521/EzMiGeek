// stats_store.dart —— 登录次数统计（app/stats.py 移植）。
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

  static Stats normalize(Object? raw) {
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
    // 跨天归零：读的时候比对日期（程序可能连开好几天）。
    final today = _todayStr(DateTime.now());
    if (s.day != today) {
      s.today = 0;
      s.day = today;
    }
    return s;
  }

  static Stats load() {
    try {
      final f = File(statsPath());
      if (!f.existsSync()) return Stats();
      return Stats.normalize(jsonDecode(f.readAsStringSync()));
    } catch (_) {
      return Stats();
    }
  }

  Stats bump({double? secs}) {
    total += 1;
    today += 1;
    day = _todayStr(DateTime.now());
    lastAt = DateTime.now().toIso8601String();
    if (secs != null && secs >= 0) lastSecs = secs;
    save();
    return this;
  }

  void save() {
    File(statsPath()).writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'Total': total,
          'Day': day,
          'Today': today,
          'LastAt': lastAt,
          'LastSecs': lastSecs,
        }),
        flush: true);
  }

  DateTime? get lastAtDateTime => DateTime.tryParse(lastAt);
}
