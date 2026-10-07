// window_fit.dart —— 窗口尺寸「客户区贴合」（全物理像素计算）。
//
// 玻璃外壳画布是 1043×1586（客户区），而 window_manager.setSize 设的是**窗口
// 外框**——系统扣掉隐形调整边框（实测左右 16 / 底 9 物理像素 @175%）后客户区
// 比例被破坏（1.5380 ≠ 设计 1.5206），外壳按宽缩放后下缘露一条底衬带。
//
// ★ 两个坑（都实测过）：
//   ① 边框差是**物理像素**，与逻辑值之间差 dpr；
//   ② WindowOptions 的 minimumSize 钳的是**外框逻辑值**——补偿算出的外框若比
//      它小会被静默钳到最小值（首版 306×457 被钳到 438×666×dpr 就是它）。
//      ⇒ 贴合期间先解除最小值，贴合完成后再按「最小客户+边框」设回正确外框。
library;

import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart' show PlatformDispatcher;
import 'package:window_manager/window_manager.dart';

import '../native/resize_lock.dart';
import '../native/win32.dart' show findOwnWindowByClass, windowFitProbe;

const double designW = 1043;
const double designH = 1586;

/// 解析 '外框 WxH 客户 WxH'。失败返回 null。
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

/// 工作区高度占用上限（用户钦定 2026-10-06：他的 4K 大屏原来正好、别人电脑
/// 上显得巨大——根因是"能放多大开多大"在小屏上会撑满整屏高度。改成窗口
/// 最高占工作区 85%：大屏 k 仍顶格不变，小屏不再满屏）。可调。
const double workHeightFraction = 0.85;

/// 打开尺寸即最大尺寸（不能更大）——不再额外缩小。
const double openShrink = 1.0;

/// 粗调尺寸（逻辑）：WindowOptions 用；精调以 applyWindowFit 为准。
Size initialClientRect() {
  try {
    final view = PlatformDispatcher.instance.views.first;
    final dpr = view.devicePixelRatio;
    final monitor = view.display.size;
    final availW = monitor.width - 32 * dpr;
    final availH = monitor.height * workHeightFraction - 32 * dpr;
    var k = math.min(availW / designW, availH / designH);
    if (k > 1) k = 1;
    if (k < 0.42) k = 0.42;
    k *= openShrink;
    final cw = (designW * k).floorToDouble();
    return Size(cw, cw * designH / designW);
  } catch (_) {
    return const Size(660, 1003.2);
  }
}

/// 客户区贴合（全物理）。返回诊断串。
Future<String> applyWindowFit() async {
  final view = PlatformDispatcher.instance.views.first;
  final dpr = view.devicePixelRatio;
  final monitor = view.display.size; // 物理像素

  // 目标客户（物理）：等比、高不超过工作区高度的 85%，宽取整、高钉死设计比例，
  // 打开尺寸即最大尺寸（用户钦定，不能更大）。
  final availW = monitor.width - 32 * dpr;
  final availH = monitor.height * workHeightFraction - 32 * dpr;
  var k = math.min(availW / designW, availH / designH);
  if (k > 1) k = 1;
  if (k < 0.42) k = 0.42;
  k *= openShrink;
  final clientW = (designW * k).floorToDouble();
  final clientH = clientW * designH / designW;

  // ★ 主窗查找加重试：与旧实例 --quit 交接的空窗期会瞬时找不到（实测摔过）。
  var hwnd = 0;
  for (var i = 0; i < 15 && hwnd == 0; i++) {
    hwnd = findOwnWindowByClass('FLUTTER_RUNNER_WIN32_WINDOW');
    if (hwnd == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
  if (hwnd == 0) return '找不到主窗';

  // ① 先设一版（此刻外框=逻辑目标，客户被边框吃掉一圈）——只为了量边框。
  await windowManager.setSize(Size(clientW / dpr, clientH / dpr));
  await Future<void>.delayed(const Duration(milliseconds: 120));
  final p1 = _parseProbe(windowFitProbe(hwnd));
  if (p1 == null) return '探针失败';
  final (winW, winH, cliW1, cliH1) = p1;
  final borderW = (winW - cliW1).clamp(0, 96).toDouble();
  final borderH = (winH - cliH1).clamp(0, 96).toDouble();

  // ② 解除最小值钳制（外框逻辑），补上边框差设到目标。
  await windowManager.setMinimumSize(Size(0, 0));
  await windowManager
      .setSize(Size((clientW + borderW) / dpr, (clientH + borderH) / dpr));
  await Future<void>.delayed(const Duration(milliseconds: 120));

  // ③ 最小值按「最小客户(0.42 倍设计) + 边框」设回外框口径。
  await windowManager.setMinimumSize(
      Size((designW * 0.42 + borderW) / dpr, (designH * 0.42 + borderH) / dpr));
  await windowManager.center();

  // ④ 拖拽等比锁（C# OnSizing 逐行移植）：边框差、目标比、幅面夹取全注入，
  //    之后左右/上下/角落怎么拖都等比，客户区比例不会再被拖坏。
  ResizeRatioLock.borderW = borderW.round();
  ResizeRatioLock.borderH = borderH.round();
  ResizeRatioLock.ratio = clientH / clientW;
  ResizeRatioLock.minClientW = (designW * 0.42).round();
  // ★ 打开尺寸 = 最大尺寸（用户钦定：不能比打开时更大）。
  ResizeRatioLock.maxClientW = clientW.round();
  // ★ 跨屏 DPI 变化 → 自动重贴合（边框厚度/幅面全按新屏算）。
  ResizeRatioLock.onDpiChanged = () {
    if (_fitBusy) return;
    _fitBusy = true;
    applyWindowFit().whenComplete(() => _fitBusy = false);
  };
  ResizeRatioLock.install(hwnd);

  // ⑤ 系统级上限（外框逻辑值）：Win+Up / 拖到屏幕边缘的系统最大化也越不过去。
  await windowManager.setMaximumSize(
      Size((clientW + borderW) / dpr, (clientH + borderH) / dpr));

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

/// 中钮「复位窗口大小」（EzAway 特有：不是最大化）。
Future<void> resetWindowSize() => applyWindowFit();
