// app_dirs.dart —— 路径约定（app/paths.py 移植）。
// 铁律：运行期数据（浏览器 profile、凭据、日志）一律放用户数据目录，
// 绝不放进程序目录 —— profile 里存着小米账号的 cookie。
library;

import 'dart:io';

const String appName = 'EzMiGeek';

String pSep() => '\\';

String pJoin(String a, String b) =>
    a.endsWith(pSep()) ? '$a$b' : '$a${pSep()}$b';

bool _usableBase(String? base) {
  if (base == null || base.isEmpty) return false;
  final b = base.trim();
  if (b.isEmpty || b == '~') return false;

  return File(b).parent.path.startsWith(RegExp(r'^[A-Za-z]:[/\\]')) ||
      Directory(b).parent.path.startsWith(RegExp(r'^[A-Za-z]:[/\\]'));
}

String _userDataBase() =>
    Platform.environment['LOCALAPPDATA'] ??
    Platform.environment['USERPROFILE'] ??
    Directory.systemTemp.path;

String _dataDir = '';

/// 运行期数据目录（自动创建）。
String dataDir() {
  if (_dataDir.isNotEmpty) return _dataDir;
  String? base;
  for (final cand in [_userDataBase(), Directory.systemTemp.path]) {
    if (_usableBase(cand)) {
      base = cand;
      break;
    }
  }
  base ??= Directory.systemTemp.path;
  final d = pJoin(base, appName);
  Directory(d).createSync(recursive: true);
  _dataDir = d;
  return d;
}

String profileDir() {
  final d = pJoin(dataDir(), 'profile');
  Directory(d).createSync(recursive: true);
  return d;
}

String logsDir() {
  final d = pJoin(dataDir(), 'logs');
  Directory(d).createSync(recursive: true);
  return d;
}

/// 小米凭据（Windows 上 DPAPI 加密）。与 C#/Python 版 config.json 同格式同位置。
String credsPath() => pJoin(dataDir(), 'config.json');

String settingsPath() => pJoin(dataDir(), 'settings.json');

String statsPath() => pJoin(dataDir(), 'stats.json');

/// 免责声明确认标记 —— 首次运行点过「确定」就写一个空文件。
String disclaimerAck() => pJoin(dataDir(), '.disclaimer-ack');

String logFile() => pJoin(logsDir(), 'agent.log');
