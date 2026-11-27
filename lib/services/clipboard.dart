// clipboard.dart —— 剪贴板写入（Flutter 原生通道，零 PowerShell 子进程）。
library;

import 'package:flutter/services.dart';

Future<bool> copyToClipboard(String text) async {
  try {
    await Clipboard.setData(ClipboardData(text: text));
    return true;
  } catch (_) {
    return false;
  }
}
