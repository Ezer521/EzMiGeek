// window_fit.dart —— 跨平台窗口尺寸贴合与等比锁。
//   · Windows：扣除隐形调整边框（物理像素测量）+ Win32 WM_SIZING 等比锁；
//   · macOS：按逻辑屏幕尺寸直接设置尺寸、上下限与 NSWindow 原生等比锁（setAspectRatio）。
library;

import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart' show PlatformDispatcher;
import 'package:window_manager/window_manager.dart';

import '../native/resize_lock.dart';
import '../native/win32.dart' show findOwnWindowByClass, windowFitProbe;

const double designW = 1043;
const double designH = 1586;

typedef RectLWin = (int winW, int winH, int cliW, int cliH);

RectLWin? _parseProbe(String probe) {
  final m = RegExp(r'外框 (\d+)x(\d+) 客户 (\d+)x(\d+)').firstMatch(probe);
  if (m == null) return null;
  return (
    int.parse(m.group(1)!),
    int.parse(m.group(2)!),
    int.parse(m.group(3)!),
    int.parse(m.group(4)!),
  );
}

const double workHeightFraction = 0.85;
const double openShrink = 1.0;

/// 粗调尺寸（逻辑）：WindowOptions 用；精调以 applyWindowFit 为准。
Size initialClientRect() {
  try {
    final view = PlatformDispatcher.instance.views.first;
    final dpr = view.devicePixelRatio;
    final monitor = view.display.size;
    if (!Platform.isWindows) {
      final logW = monitor.width / dpr;
      final logH = monitor.height / dpr;
      final availW = logW - 32;
      final availH = logH * workHeightFraction - 32;
      final k = math.min(availW / designW, availH / designH).clamp(0.35, 0.72);
      final cw = (designW * k).floorToDouble();
      return Size(cw, cw * designH / designW);
    }
    final availW = monitor.width - 32 * dpr;
    final availH = monitor.height * workHeightFraction - 32 * dpr;
    var k = math.min(availW / designW, availH / designH);
    if (k > 1) k = 1;
    if (k < 0.42) k = 0.42;
    k *= openShrink;
    final cw = (designW * k).floorToDouble();
    return Size(cw / dpr, (cw * designH / designW) / dpr);
  } catch (_) {
    return const Size(480, 730);
  }
}

/// 窗口贴合（Windows 全物理边框补偿；macOS 纯逻辑 + 原生等比锁）。
Future<String> applyWindowFit() async {
  final view = PlatformDispatcher.instance.views.first;
  final dpr = view.devicePixelRatio;
  final monitor = view.display.size;

  if (!Platform.isWindows) {
    final target = initialClientRect();
    final minSize = Size(
      math.min(target.width, designW * 0.35),
      math.min(target.height, designH * 0.35),
    );
    await windowManager.setMinimumSize(minSize);
    await windowManager.setMaximumSize(target);
    await windowManager.setSize(target);
    try {
      await windowManager.setAspectRatio(designW / designH);
    } catch (_) {}
    await windowManager.center();
    return 'macOS dpr=$dpr 逻辑窗口 ${target.width.round()}x${target.height.round()}';
  }

  final availW = monitor.width - 32 * dpr;
  final availH = monitor.height * workHeightFraction - 32 * dpr;
  var k = math.min(availW / designW, availH / designH);
  if (k > 1) k = 1;
  if (k < 0.42) k = 0.42;
  k *= openShrink;
  final clientW = (designW * k).floorToDouble();
  final clientH = clientW * designH / designW;

  var hwnd = 0;
  for (var i = 0; i < 15 && hwnd == 0; i++) {
    hwnd = findOwnWindowByClass('FLUTTER_RUNNER_WIN32_WINDOW');
    if (hwnd == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
  if (hwnd == 0) return '找不到主窗';

  await windowManager.setSize(Size(clientW / dpr, clientH / dpr));
  await Future<void>.delayed(const Duration(milliseconds: 120));
  final p1 = _parseProbe(windowFitProbe(hwnd));
  if (p1 == null) return '探针失败';
  final (winW, winH, cliW1, cliH1) = p1;
  final borderW = (winW - cliW1).clamp(0, 96).toDouble();
  final borderH = (winH - cliH1).clamp(0, 96).toDouble();

  await windowManager.setMinimumSize(Size.zero);
  await windowManager.setSize(
    Size((clientW + borderW) / dpr, (clientH + borderH) / dpr),
  );
  await Future<void>.delayed(const Duration(milliseconds: 120));

  await windowManager.setMinimumSize(
    Size((designW * 0.42 + borderW) / dpr, (designH * 0.42 + borderH) / dpr),
  );
  await windowManager.center();

  ResizeRatioLock.borderW = borderW.round();
  ResizeRatioLock.borderH = borderH.round();
  ResizeRatioLock.ratio = clientH / clientW;
  ResizeRatioLock.minClientW = (designW * 0.42).round();
  ResizeRatioLock.maxClientW = clientW.round();
  ResizeRatioLock.onDpiChanged = () {
    if (_fitBusy) return;
    _fitBusy = true;
    applyWindowFit().whenComplete(() => _fitBusy = false);
  };
  ResizeRatioLock.install(hwnd);

  await windowManager.setMaximumSize(
    Size((clientW + borderW) / dpr, (clientH + borderH) / dpr),
  );

  _fitBusy = false;
  final finalProbe = windowFitProbe(hwnd);
  final p2 = _parseProbe(finalProbe);
  final note = p2 == null
      ? finalProbe
      : '客户 ${p2.$3}x${p2.$4} 比 ${(p2.$4 / p2.$3).toStringAsFixed(4)}'
          '（设计 ${(designH / designW).toStringAsFixed(4)}）';
  return 'dpr=$dpr 边框 ${borderW.round()}x${borderH.round()} 目标客户 '
      '${clientW.round()}x${clientH.round()}（≤工作区高85%，即最大） ｜ $note';
}

bool _fitBusy = false;

Future<void> resetWindowSize() => applyWindowFit();
