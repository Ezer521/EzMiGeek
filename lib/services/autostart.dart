// autostart.dart —— 跨平台开机自动启动。
//   · Windows：原生 Win32 advapi32 读写 HKCU\...\Run 键（零 reg.exe 子进程）；
//   · macOS：读写标准 ~/Library/LaunchAgents/com.ezer.ezmigeek.plist。
library;

import 'dart:io';

import '../core/i18n.dart';
import '../native/win32.dart'
    show hkeyCurrentUser, regDeleteValue, regReadSz, regWriteSz;

const String _valueName = 'EzMiGeek';
const String _runKey = r'Software\Microsoft\Windows\CurrentVersion\Run';
const String _macAgentLabel = 'com.ezer.ezmigeek';

class AutostartState {
  const AutostartState({
    required this.enabled,
    required this.raw,
    required this.reason,
    this.detail = '',
  });
  final bool enabled;
  final String raw;
  final String reason; // set / unset / elsewhere / read_failed
  final String detail;
}

String _targetCommandWin() => '"${Platform.resolvedExecutable}"';

String _norm(String cmd) => cmd
    .replaceAll('"', ' ')
    .trim()
    .toLowerCase()
    .replaceAll(RegExp(r'\s+'), ' ');

// ── macOS LaunchAgent ─────────────────────────────────────────────────────

String _macPlistPath() {
  final home = Platform.environment['HOME'] ?? '';
  return '$home/Library/LaunchAgents/$_macAgentLabel.plist';
}

String _xmlEscape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

String _xmlUnescape(String s) => s
    .replaceAll('&apos;', "'")
    .replaceAll('&quot;', '"')
    .replaceAll('&gt;', '>')
    .replaceAll('&lt;', '<')
    .replaceAll('&amp;', '&');

/// 生成标准 macOS LaunchAgent plist 内容（导出方便单元测试校验格式）。
String buildMacLaunchAgentPlist(String executablePath) {
  final escExe = _xmlEscape(executablePath);
  return '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$_macAgentLabel</string>
  <key>ProgramArguments</key>
  <array>
    <string>$escExe</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
</dict>
</plist>
''';
}

/// 从 LaunchAgent plist 文本中提取 ProgramArguments 的第一个可执行路径。
String? parseMacLaunchAgentExecutable(String plistXml) {
  final m = RegExp(
    r'<key>\s*ProgramArguments\s*</key>\s*<array>\s*<string>([^<]+)</string>',
    dotAll: true,
  ).firstMatch(plistXml);
  if (m == null) return null;
  return _xmlUnescape(m.group(1)!.trim());
}

AutostartState _macAutostartState() {
  try {
    final f = File(_macPlistPath());
    if (!f.existsSync()) {
      return const AutostartState(enabled: false, raw: '', reason: 'unset');
    }
    final text = f.readAsStringSync();
    final exe = parseMacLaunchAgentExecutable(text) ?? '';
    if (exe.isEmpty) {
      return const AutostartState(enabled: false, raw: '', reason: 'unset');
    }
    if (exe == Platform.resolvedExecutable) {
      return AutostartState(enabled: true, raw: exe, reason: 'set');
    }
    return AutostartState(
      enabled: false,
      raw: exe,
      reason: 'elsewhere',
      detail: exe,
    );
  } catch (e) {
    return AutostartState(
      enabled: false,
      raw: '',
      reason: 'read_failed',
      detail: '$e',
    );
  }
}

AutostartState _macSetEnabled(bool on) {
  final f = File(_macPlistPath());
  if (on) {
    f.parent.createSync(recursive: true);
    final tmp = File('${f.path}.tmp');
    tmp.writeAsStringSync(
      buildMacLaunchAgentPlist(Platform.resolvedExecutable),
      flush: true,
    );
    tmp.renameSync(f.path);
  } else {
    if (f.existsSync()) f.deleteSync();
  }
  final st = _macAutostartState();
  if (st.enabled != on) {
    throw StateError('LaunchAgent 写入后校验不一致（reason=${st.reason}）');
  }
  return st;
}

// ── 统一入口 ──────────────────────────────────────────────────────────────

(String?, String) readReg() {
  if (!Platform.isWindows) return (null, '');
  return regReadSz(hkeyCurrentUser, _runKey, _valueName);
}

AutostartState autostartState() {
  if (!Platform.isWindows) return _macAutostartState();
  final (raw0, err) = readReg();
  final raw = raw0 ?? '';
  if (err.isNotEmpty) {
    return AutostartState(
      enabled: false,
      raw: '',
      reason: 'read_failed',
      detail: err,
    );
  }
  if (raw.isEmpty) {
    return const AutostartState(enabled: false, raw: '', reason: 'unset');
  }
  if (_norm(raw) == _norm(_targetCommandWin())) {
    return AutostartState(enabled: true, raw: raw, reason: 'set');
  }
  return AutostartState(
    enabled: false,
    raw: raw,
    reason: 'elsewhere',
    detail: raw,
  );
}

AutostartState setEnabled(bool on) {
  if (!Platform.isWindows) return _macSetEnabled(on);
  final rc = on
      ? regWriteSz(hkeyCurrentUser, _runKey, _valueName, _targetCommandWin())
      : regDeleteValue(hkeyCurrentUser, _runKey, _valueName);
  if (rc != 0) {
    throw StateError('注册表写入失败（Win32 error=$rc）');
  }
  final st = autostartState();
  if (st.enabled != on) {
    throw StateError('写入后校验不一致（reason=${st.reason}）');
  }
  return st;
}

String autostartSubtitleFrom(AutostartState st) {
  if (st.reason == 'elsewhere') return t('as.elsewhere');
  if (st.reason == 'read_failed') {
    return t('as.readfail', [st.detail.isEmpty ? t('as.unknown') : st.detail]);
  }
  return Platform.isWindows ? t('as.on') : t('as.on.mac');
}

String autostartSubtitle() => autostartSubtitleFrom(autostartState());
