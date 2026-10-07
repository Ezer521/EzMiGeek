// clipboard.dart —— 剪贴板写入（Windows=PowerShell Set-Clipboard，
library;

import 'dart:convert';
import 'dart:io';

bool copyToClipboard(String text) {
  try {
    final encoded = base64Encode(utf8.encode(text));
    Process.runSync('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      'Set-Clipboard -Value ([Text.Encoding]::UTF8.GetString('
          '[Convert]::FromBase64String(\'$encoded\')))',
    ]);
    return true;
  } catch (_) {
    return false;
  }
}
