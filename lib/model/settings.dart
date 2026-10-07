// settings.dart —— 界面设置持久化（app/settings.py 移植）。
// SCHEMA 每个字段都有真实消费者（消费清单见 README「设置卡」一节）。
library;

import 'dart:convert';
import 'dart:io';

import '../core/app_dirs.dart';

abstract final class SettingsKeys {
  static const waitMin = 'WaitMin';
  static const retrySec = 'RetrySec';
  static const failMax = 'FailMax';
  static const autoStart = 'AutoStart';
  static const autoTrayDone = 'AutoTrayDone';
  static const autoDblOpenWeb = 'AutoDblOpenWeb';
  static const autoFullscreen = 'AutoFullscreen';
  static const langZh = 'LangZh';
}

class AppSettings {
  int waitMin = 30; // 取码上限（分钟）
  int retrySec = 3; // 重试间隔（秒）
  int failMax = 3; // 连续失败转人工
  bool autoStart = false;
  bool autoTrayDone = false;
  bool autoDblOpenWeb = false;
  bool autoFullscreen = true; // 出厂默认：开（延续当年写死全屏的行为）
  bool langZh = true;

  /// 拨动即存的快照：从 UI 状态对象抽一份出来（app/settings.snapshot 同款）。
  Map<String, Object?> toValues() => {
        SettingsKeys.waitMin: waitMin,
        SettingsKeys.retrySec: retrySec,
        SettingsKeys.failMax: failMax,
        SettingsKeys.autoStart: autoStart,
        SettingsKeys.autoTrayDone: autoTrayDone,
        SettingsKeys.autoDblOpenWeb: autoDblOpenWeb,
        SettingsKeys.autoFullscreen: autoFullscreen,
        SettingsKeys.langZh: langZh,
      };

  void applyValues(Map<String, Object?> v) {
    waitMin = _coerceInt(v[SettingsKeys.waitMin], 1, 60, 30);
    retrySec = _coerceInt(v[SettingsKeys.retrySec], 1, 60, 3);
    failMax = _coerceInt(v[SettingsKeys.failMax], 1, 9, 3);
    autoStart = v[SettingsKeys.autoStart] == true;
    autoTrayDone = v[SettingsKeys.autoTrayDone] == true;
    autoDblOpenWeb = v[SettingsKeys.autoDblOpenWeb] == true;
    autoFullscreen = v[SettingsKeys.autoFullscreen] != false;
    langZh = v[SettingsKeys.langZh] != false;
  }

  static int _coerceInt(Object? raw, int lo, int hi, int def) {
    final v = int.tryParse('$raw') ?? def;
    return v.clamp(lo, hi);
  }

  String summary() =>
      'WaitMin=$waitMin RetrySec=$retrySec FailMax=$failMax '
      'AutoStart=$autoStart AutoTrayDone=$autoTrayDone '
      'AutoDblOpenWeb=$autoDblOpenWeb AutoFullscreen=$autoFullscreen LangZh=$langZh';
}

/// 旧 JSON 里的未知字段会被丢掉（只保留白名单字段），同原版 normalize()。
AppSettings loadSettings() {
  try {
    final f = File(settingsPath());
    if (!f.existsSync()) return AppSettings();
    final raw = jsonDecode(f.readAsStringSync());
    if (raw is! Map) return AppSettings();
    final s = AppSettings();
    s.applyValues({
      for (final k in const [
        SettingsKeys.waitMin, SettingsKeys.retrySec, SettingsKeys.failMax,
        SettingsKeys.autoStart, SettingsKeys.autoTrayDone,
        SettingsKeys.autoDblOpenWeb, SettingsKeys.autoFullscreen,
        SettingsKeys.langZh,
      ])
        k: raw[k],
    });
    return s;
  } catch (_) {
    return AppSettings();
  }
}

/// 原子写（tmp → rename）。文件头带自解释说明（原版同款）。
bool saveSettings(AppSettings s) {
  try {
    final values = s.toValues();
    final obj = <String, Object?>{
      '_note': 'EzMiGeek 的界面设置。直接改这个文件也行，程序启动时会读；'
          '未知字段会被程序丢弃。',
      ...values,
    };
    final tmp = '${settingsPath()}.tmp';
    File(tmp).writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(obj), flush: true);
    final main = File(settingsPath());
    if (main.existsSync()) main.deleteSync();
    File(tmp).renameSync(settingsPath());
    return true;
  } catch (_) {
    return false;
  }
}

bool saveLanguage(bool zh) {
  final s = loadSettings();
  s.langZh = zh;
  return saveSettings(s);
}
