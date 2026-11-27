// settings.dart —— 界面设置持久化。
// SCHEMA 每个字段都有真实消费者（消费说明见 README 与使用说明）。
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
  static const hubIp = 'HubIp';
  static const localCodeService = 'LocalCodeService';
}

class AppSettings {
  int waitMin = 30; // 取码上限（分钟）
  int retrySec = 3; // 重试间隔（秒）
  int failMax = 3; // 连续失败转人工
  bool autoStart = false;
  bool autoTrayDone = false;
  bool autoDblOpenWeb = false;
  bool autoFullscreen = true; // 打开极客版网页时是否全屏（可在 settings.json 改 false）
  bool langZh = true;

  /// 中枢 IP 手动指定（空 = 自动发现）。支持 IP 或 IP:端口（省略端口先试 8086 再试 80）。
  String hubIp = '';

  /// 是否启用本地回环取码服务（127.0.0.1，供本机其他工具调用）。
  bool localCodeService = true;

  /// 拨动即存的快照。
  Map<String, Object?> toValues() => {
        SettingsKeys.waitMin: waitMin,
        SettingsKeys.retrySec: retrySec,
        SettingsKeys.failMax: failMax,
        SettingsKeys.autoStart: autoStart,
        SettingsKeys.autoTrayDone: autoTrayDone,
        SettingsKeys.autoDblOpenWeb: autoDblOpenWeb,
        SettingsKeys.autoFullscreen: autoFullscreen,
        SettingsKeys.langZh: langZh,
        SettingsKeys.hubIp: hubIp,
        SettingsKeys.localCodeService: localCodeService,
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
    hubIp = '${v[SettingsKeys.hubIp] ?? ''}'.trim();
    localCodeService = v[SettingsKeys.localCodeService] != false;
  }

  static int _coerceInt(Object? raw, int lo, int hi, int def) {
    final v = int.tryParse('$raw') ?? def;
    return v.clamp(lo, hi);
  }

  String summary() =>
      'WaitMin=$waitMin RetrySec=$retrySec FailMax=$failMax '
      'AutoStart=$autoStart AutoTrayDone=$autoTrayDone '
      'AutoDblOpenWeb=$autoDblOpenWeb AutoFullscreen=$autoFullscreen '
      'LocalCodeService=$localCodeService '
      'LangZh=$langZh HubIp=${hubIp.isEmpty ? '<自动>' : hubIp}';
}

/// 未知字段会被丢弃（白名单字段读取）。
AppSettings loadSettings() {
  try {
    final f = File(settingsPath());
    if (!f.existsSync()) return AppSettings();
    final raw = jsonDecode(f.readAsStringSync());
    if (raw is! Map) return AppSettings();
    final s = AppSettings();
    s.applyValues({
      for (final k in const [
        SettingsKeys.waitMin,
        SettingsKeys.retrySec,
        SettingsKeys.failMax,
        SettingsKeys.autoStart,
        SettingsKeys.autoTrayDone,
        SettingsKeys.autoDblOpenWeb,
        SettingsKeys.autoFullscreen,
        SettingsKeys.langZh,
        SettingsKeys.hubIp,
        SettingsKeys.localCodeService,
      ])
        k: raw[k],
    });
    return s;
  } catch (_) {
    return AppSettings();
  }
}

/// 原子写（tmp 直接 rename 覆盖，避免先删后改名的丢失窗口）。
bool saveSettings(AppSettings s) {
  try {
    final values = s.toValues();
    final obj = <String, Object?>{
      '_note': 'EzMiGeek 的界面设置。直接改这个文件也行，WaitMin/RetrySec/FailMax/HubIp/'
          'AutoFullscreen 会在每轮开跑时热重载；LocalCodeService 改完需重启生效。'
          'HubIp 填极客版中枢 IP（如 192.168.5.3 或 192.168.5.3:80），留空 = 自动发现。',
      ...values,
    };
    final p = settingsPath();
    final tmp = '$p.tmp';
    File(tmp).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(obj),
      flush: true,
    );
    try {
      File(tmp).renameSync(p);
    } catch (_) {
      final main = File(p);
      if (main.existsSync()) main.deleteSync();
      File(tmp).renameSync(p);
    }
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
