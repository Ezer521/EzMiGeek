// autostart.dart —— 开机自动启动：写 HKCU Run 键（reg.exe 命令行，零依赖）。
library;

import 'dart:io';

import '../core/i18n.dart';

const String _valueName = 'EzMiGeek';
const String _runKey = r'Software\Microsoft\Windows\CurrentVersion\Run';

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

String _quoteSelf() => '"${Platform.resolvedExecutable}"';

String _targetCommand() => _quoteSelf();

String _norm(String cmd) => cmd
    .replaceAll('"', ' ')
    .trim()
    .toLowerCase()
    .replaceAll(RegExp(r'\s+'), ' ');

(String?, String) readReg() {
  try {
    final r = Process.runSync(
      'reg',
      ['query', 'HKCU\\$_runKey', '/v', _valueName],
      stdoutEncoding: const SystemEncoding(),
      stderrEncoding: const SystemEncoding(),
    );
    if (r.exitCode != 0) return (null, '');
    for (final line in r.stdout.toString().split('\n')) {
      if (line.contains(_valueName) && line.contains('REG_SZ')) {
        return (line.split('REG_SZ').last.trim(), '');
      }
    }
    return (null, '');
  } catch (e) {
    return (null, '$e');
  }
}

AutostartState autostartState() {
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
  if (_norm(raw) == _norm(_targetCommand())) {
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
  if (on) {
    final data = _targetCommand().replaceAll('"', r'\"');
    Process.runSync('reg', [
      'add',
      'HKCU\\$_runKey',
      '/v',
      _valueName,
      '/t',
      'REG_SZ',
      '/d',
      data,
      '/f',
    ], stdoutEncoding: const SystemEncoding());
  } else {
    Process.runSync('reg', [
      'delete',
      'HKCU\\$_runKey',
      '/v',
      _valueName,
      '/f',
    ], stdoutEncoding: const SystemEncoding());
  }
  final st = autostartState();
  if (st.enabled != on) {
    throw StateError('写入后校验不一致（reason=${st.reason}）');
  }
  return st;
}

String autostartSubtitle() {
  final st = autostartState();
  if (st.reason == 'elsewhere') return t('as.elsewhere');
  if (st.reason == 'read_failed') {
    return t('as.readfail', [st.detail.isEmpty ? t('as.unknown') : st.detail]);
  }
  return t('as.on');
}
