// resize_lock.dart —— 拖拽等比缩放锁（C# GlassWindow.OnSizing 的逐行移植）。
//
// 窗口带 WS_THICKFRAME 可自由拖边；一旦竖向单独拉动，客户区比例就偏离
// 设计稿 1043:1586，玻璃外壳下缘会露出一条底衬带（用户实测报过两次）。
// 这里子类化窗口过程拦 WM_SIZING，把矩形改写成设计比例。
//
// ★ 主导维怎么选（C# 同款）：拖左右边 → 以宽为准；拖上下边 → **以高为准**
//  （不然上下边钉死、没法缩放——用户实测报过）；拖角 → 比「宽变化率」和
//   「高变化率」谁更大。不能比绝对像素——竖长窗口的高本来就大得多。
library;

import 'dart:async' show Future;
import 'package:ffi/ffi.dart';
import 'dart:ffi';

import 'win32.dart';

class ResizeRatioLock {
  static int _oldProc = 0;
  static NativeCallable<WndProcNative>? _proc;

  /// 客户区目标比（高/宽）。由 window_fit 贴合完成后注入。
  static double ratio = 1586.0 / 1043.0;

  /// 隐形调整边框（物理像素）：外框-客户 的横向/纵向差。贴合时量出注入。
  static int borderW = 0;
  static int borderH = 0;

  /// 客户宽的幅面夹取（物理像素）：最小 0.42 倍设计；最大 = 一屏放得下。
  static int minClientW = 438;
  static int maxClientW = 2560;

  static bool installed = false;

  /// DPI 变化（跨屏拖动）后的重贴合回调（宿主注入 → window_fit.applyWindowFit）。
  /// ★ 边框物理厚度随屏幕 DPI 变（4K@300% 16/9、175% 屏 9/5，实测）——静态值
  ///   跨屏就错，所以除了回调重贴合，每次拖动开始还会现量边框。
  static void Function()? onDpiChanged;

  static const int _wmSizing = 0x0214;
  static const int _wmEnterSizeMove = 0x0231;
  static const int _wmDpiChanged = 0x02E0;

  // 开始缩放那一刻的窗口尺寸——给拖角判「主导维」用（C# sizeStartW/H 同源）。
  static int _startW = 0, _startH = 0;

  /// 现量当前窗口的「外框-客户」边框差（物理像素）。
  static void _remeasureBorders(int hwnd) {
    final wr = malloc<RectL>(), cr = malloc<RectL>();
    try {
      getWinRectB(hwnd, wr);
      getCliRectB(hwnd, cr);
      borderW = (wr.ref.right - wr.ref.left - (cr.ref.right - cr.ref.left))
          .clamp(0, 96);
      borderH = (wr.ref.bottom - wr.ref.top - (cr.ref.bottom - cr.ref.top))
          .clamp(0, 96);
    } catch (_) {} finally {
      malloc
        ..free(wr)
        ..free(cr);
    }
  }

  /// 子类化主窗过程。重复调用幂等。
  static void install(int hwnd) {
    if (installed || hwnd == 0) return;
    _oldProc = getWindowLongPtrW(hwnd, gwlWndProc);
    if (_oldProc == 0) return;
    _proc = NativeCallable<WndProcNative>.isolateLocal(_wndProc,
        exceptionalReturn: 0);
    setWindowLongPtrW(hwnd, gwlWndProc, _proc!.nativeFunction.address);
    installed = true;
  }

  static int _wndProc(int hwnd, int msg, int wParam, int lParam) {
    try {
      if (msg == _wmEnterSizeMove && lParam != 0) {
        final r = Pointer<RectL>.fromAddress(lParam).ref;
        _startW = r.right - r.left;
        _startH = r.bottom - r.top;
        _remeasureBorders(hwnd); // 边框厚度随屏 DPI 变，拖动开始现量
      } else if (msg == _wmDpiChanged) {
        // 跨屏 → 稍后整轮重贴合（边框/最小值/幅面全按新屏算）。
        final cb = onDpiChanged;
        if (cb != null) {
          Future<void>.delayed(const Duration(milliseconds: 400), () {
            try {
              cb();
            } catch (_) {}
          });
        }
      } else if (msg == _wmSizing && lParam != 0) {
        final r = Pointer<RectL>.fromAddress(lParam).ref;
        var w = r.right - r.left;
        var h = r.bottom - r.top;
        if (w < 1) w = 1;
        if (h < 1) h = 1;

        // 外框 → 客户 → 判主导维 → 客户按比例 → 外框长回去。
        final clientW = (w - borderW).toDouble();
        final clientH = (h - borderH).toDouble();
        final aspect = ratio; // 客户 高/宽

        bool byW;
        if (wParam == 1 || wParam == 2) {
          byW = true; // LEFT / RIGHT：以宽为准
        } else if (wParam == 3 || wParam == 6) {
          byW = false; // TOP / BOTTOM：以高为准（拖上下边也能缩放）
        } else {
          // 拖角：比宽/高的**变化率**（C# 同款，不能比绝对像素）。
          final cw = _startW > 0 ? (clientW / _startW - 1).abs() : 0.0;
          final ch = _startH > 0 ? (clientH / _startH - 1).abs() : 0.0;
          byW = cw >= ch;
        }
        var newClientW = clientW;
        var newClientH = clientH;
        if (byW) {
          newClientH = clientW * aspect;
        } else {
          newClientW = clientH / aspect;
        }

        // 幅面夹取：最小 0.42 档；最大 = 一屏放得下。
        if (newClientW < minClientW) newClientW = minClientW.toDouble();
        if (newClientW > maxClientW) newClientW = maxClientW.toDouble();
        newClientH = newClientW * aspect;

        w = (newClientW + borderW).round();
        h = (newClientH + borderH).round();

        // 按用户抓的边/角把矩形「长回去」：抓左边动 Left、抓上边动 Top…
        if (wParam == 1 || wParam == 4 || wParam == 7) {
          r.left = r.right - w;
        } else {
          r.right = r.left + w;
        }
        if (wParam == 3 || wParam == 4 || wParam == 5) {
          r.top = r.bottom - h;
        } else {
          r.bottom = r.top + h;
        }
        return 1; // TRUE = 已按改好的矩形走
      }
    } catch (_) {}
    return callWindowProcW(_oldProc, hwnd, msg, wParam, lParam);
  }

  static void uninstall(int hwnd) {
    if (!installed) return;
    try {
      if (_oldProc != 0) setWindowLongPtrW(hwnd, gwlWndProc, _oldProc);
    } catch (_) {}
    _proc?.close();
    _proc = null;
    _oldProc = 0;
    installed = false;
  }
}
