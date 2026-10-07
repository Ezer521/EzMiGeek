// dialogs.dart —— 原生 MessageBox 包装（app/panel.py confirm_* 移植）。
// 破坏性操作的默认焦点必须在"什么都不做"那档（MB_DEFBUTTON2/3）。
library;

import 'dart:ffi';


import 'package:ffi/ffi.dart';

int _messageBox(String title, String text, int flags) {
  final p = text.toNativeUtf16();
  final t = title.toNativeUtf16();
  try {
    final user32 = DynamicLibrary.open('user32.dll');
    final mb = user32.lookupFunction<
        IntPtr Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>, Uint32),
        int Function(
            Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>, int)>('MessageBoxW');
    return mb(nullptr, p, t, flags);
  } finally {
    malloc.free(p);
    malloc.free(t);
  }
}

const int _mbOk = 0x0;
const int _mbOkCancel = 0x1;
const int _mbYesNoCancel = 0x3;
const int _mbIconInfo = 0x40;
const int _mbIconQuestion = 0x20;
const int _mbIconWarning = 0x30;
const int _mbDefButton2 = 0x100;
const int _mbDefButton3 = 0x200;
const int _mbSetFg = 0x10000;
const int _mbTop = 0x40000;

void messageInfo(String title, String text) {
  _messageBox(title, text, _mbOk | _mbIconInfo | _mbSetFg | _mbTop);
}

/// 首次运行的免责声明确认框。返回 True = 用户点了「确定」。
bool confirmDisclaimer(String text) {
  return _messageBox('EzMiGeek · 免责声明（首次运行需确认）', text,
          _mbOkCancel | _mbIconInfo | _mbSetFg | _mbTop) ==
      1; // IDOK
}

/// 「清除数据」三档确认。返回 'yes' / 'no' / 'cancel'（默认焦点在「取消」）。
String confirmClearData(String title, String text) {
  final r = _messageBox(title, text,
      _mbYesNoCancel | _mbIconWarning | _mbDefButton3 | _mbSetFg | _mbTop);
  return switch (r) { 6 => 'yes', 7 => 'no', _ => 'cancel' };
}

/// 「重新配置」两档确认（默认焦点在「取消」）。
bool confirmResetConfig(String title, String text) {
  return _messageBox(title, text,
          _mbOkCancel | _mbIconQuestion | _mbDefButton2 | _mbSetFg | _mbTop) ==
      1;
}

/// 「重新登录」确认框（默认焦点在「确定」——不破坏任何东西）。
bool confirmRelogin(String title, String text) {
  return _messageBox(title, text, _mbOkCancel | _mbIconQuestion | _mbSetFg | _mbTop) ==
      1;
}

/// 免责声明全文阅读。
void showLegalFull(String title, String text) {
  _messageBox(title, text, _mbOk | _mbIconInfo | _mbSetFg | _mbTop);
}

/// 通用提示框。
void messageBox(String title, String text) {
  _messageBox(title, text, _mbOk | _mbSetFg | _mbTop);
}
