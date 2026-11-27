// dialogs.dart —— 跨平台原生系统弹窗。
//   · Windows：user32.dll MessageBoxW；
//   · macOS：osascript display dialog（参数走 argv 传入，零脚本注入风险）。
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../core/i18n.dart';

final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');
final int Function(Pointer<Void>, Pointer<Utf16>, Pointer<Utf16>, int)
    _messageBoxW = _user32.lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Utf16>, Pointer<Utf16>, Uint32),
        int Function(Pointer<Void>, Pointer<Utf16>, Pointer<Utf16>, int)>(
  'MessageBoxW',
);

int _winMessageBox(String title, String text, int flags) {
  final p = text.toNativeUtf16();
  final t = title.toNativeUtf16();
  try {
    return _messageBoxW(nullptr, p, t, flags);
  } finally {
    malloc
      ..free(p)
      ..free(t);
  }
}

const int _mbOk = 0x0;
const int _mbOkCancel = 0x1;
const int _mbYesNo = 0x4;
const int _mbIconInfo = 0x40;
const int _mbIconQuestion = 0x20;
const int _mbSetFg = 0x10000;
const int _mbTop = 0x40000;

/// macOS 原生弹窗：通过 `on run argv` 传参避免引号/换行注入。
/// 返回 true 表示点击了确认按钮，false 表示取消或调用失败。
bool _macDialog({
  required String title,
  required String text,
  required String okLabel,
  String? cancelLabel,
}) {
  final script = cancelLabel == null
      ? 'on run argv\n'
          '  display dialog (item 2 of argv) with title (item 1 of argv) '
          'buttons {item 3 of argv} default button (item 3 of argv) with icon note\n'
          'end run'
      : 'on run argv\n'
          '  display dialog (item 2 of argv) with title (item 1 of argv) '
          'buttons {item 4 of argv, item 3 of argv} default button (item 3 of argv) '
          'cancel button (item 4 of argv) with icon note\n'
          'end run';
  try {
    final args = <String>[
      '-e',
      script,
      '--',
      title,
      text,
      okLabel,
      ?cancelLabel,
    ];
    final r = Process.runSync(
      '/usr/bin/osascript',
      args,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}

void messageInfo(String title, String text) {
  if (!Platform.isWindows) {
    _macDialog(title: title, text: text, okLabel: Lang.zh ? '确定' : 'OK');
    return;
  }
  _winMessageBox(title, text, _mbOk | _mbIconInfo | _mbSetFg | _mbTop);
}

/// 首次运行的免责声明确认框。返回 true = 用户点了「确定」。
bool confirmDisclaimer(String text) {
  const title = 'EzMiGeek · 免责声明（首次运行需确认）';
  if (!Platform.isWindows) {
    return _macDialog(
      title: title,
      text: text,
      okLabel: '确定',
      cancelLabel: '取消',
    );
  }
  return _winMessageBox(
        title,
        text,
        _mbOkCancel | _mbIconInfo | _mbSetFg | _mbTop,
      ) ==
      1;
}

/// 「重新登录」确认框。
bool confirmRelogin(String title, String text) {
  if (!Platform.isWindows) {
    return _macDialog(
      title: title,
      text: text,
      okLabel: Lang.zh ? '确定' : 'OK',
      cancelLabel: Lang.zh ? '取消' : 'Cancel',
    );
  }
  return _winMessageBox(
        title,
        text,
        _mbOkCancel | _mbIconQuestion | _mbSetFg | _mbTop,
      ) ==
      1;
}

/// 通用「是 / 否」确认框（如检查更新打开下载页）。
bool confirmYesNo(String title, String text) {
  if (!Platform.isWindows) {
    return _macDialog(
      title: title,
      text: text,
      okLabel: Lang.zh ? '是' : 'Yes',
      cancelLabel: Lang.zh ? '否' : 'No',
    );
  }
  return _winMessageBox(
        title,
        text,
        _mbYesNo | _mbIconQuestion | _mbSetFg | _mbTop,
      ) ==
      6;
}

/// 免责声明全文阅读。
void showLegalFull(String title, String text) {
  if (!Platform.isWindows) {
    _macDialog(title: title, text: text, okLabel: Lang.zh ? '关闭' : 'Close');
    return;
  }
  _winMessageBox(title, text, _mbOk | _mbIconInfo | _mbSetFg | _mbTop);
}
