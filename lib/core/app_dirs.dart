// app_dirs.dart —— 跨平台路径约定。
// 铁律：运行期数据（浏览器 profile、凭据、日志）一律放用户数据目录，绝不放进程序目录。
// Windows = %LOCALAPPDATA%\EzMiGeek；macOS = ~/Library/Application Support/EzMiGeek。
library;

import 'dart:io';

const String appName = 'EzMiGeek';

/// 目录分隔符按平台（macOS 上反斜杠是合法文件名字符，绝不能硬编码 \\）。
String pSep() => Platform.isWindows ? '\\' : '/';

String pJoin(String a, String b) =>
    a.endsWith(pSep()) ? '$a$b' : '$a${pSep()}$b';

bool _usableBase(String? base) {
  if (base == null || base.isEmpty) return false;
  final b = base.trim();
  if (b.isEmpty || b == '~') return false;
  if (!Platform.isWindows) {
    return b.startsWith('/');
  }
  return File(b).parent.path.startsWith(RegExp(r'^[A-Za-z]:[/\\]')) ||
      Directory(b).parent.path.startsWith(RegExp(r'^[A-Za-z]:[/\\]'));
}

String _userDataBase() {
  if (Platform.isWindows) {
    return Platform.environment['LOCALAPPDATA'] ??
        Platform.environment['USERPROFILE'] ??
        Directory.systemTemp.path;
  }
  final home = Platform.environment['HOME'] ?? Directory.systemTemp.path;
  return '$home/Library/Application Support';
}

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

/// 小米凭据（Windows=DPAPI 加密，macOS=Keychain 指针）。
String credsPath() => pJoin(dataDir(), 'config.json');

String settingsPath() => pJoin(dataDir(), 'settings.json');

String statsPath() => pJoin(dataDir(), 'stats.json');

/// 免责声明确认标记 —— 首次运行点过「确定」就写一个标记文件。
String disclaimerAck() => pJoin(dataDir(), '.disclaimer-ack');

String logFile() => pJoin(logsDir(), 'agent.log');
