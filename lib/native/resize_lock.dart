// resize_lock.dart —— 拖拽等比缩放锁 + 单实例唤醒消息拦截。
//
// 窗口带 WS_THICKFRAME 可自由拖边；一旦竖向单独拉动，客户区比例就偏离
// 设计稿 1043:1586，玻璃外壳下缘会露出一条底衬带。
// 这里子类化窗口过程拦 WM_SIZING，把矩形改写成设计比例；同时接收
// wmEzMiGeekActivate 消息，把第二实例的双击唤起转成「显示并置前主面板」。
library;

import 'dart:async' show Future, scheduleMicrotask;
import 'dart:ffi';

import 'package:ffi/ffi.dart';

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
  static void Function()? onDpiChanged;

  /// 第二实例启动发来唤醒消息时的回调（宿主注入 → 弹出并置前主面板）。
  static void Function()? onActivate;

  static const int _wmSizing = 0x0214;
  static const int _wmEnterSizeMove = 0x0231;
  static const int _wmDpiChanged = 0x02E0;

  // 开始缩放那一刻的客户区尺寸 —— 给拖角判「主导维」用。
  static int _startW = 0, _startH = 0;

  /// 现量当前窗口的「外框-客户」边框差与客户区尺寸（物理像素）。
  static void _remeasureBorders(int hwnd, {bool captureStartSize = false}) {
    final wr = malloc<RectL>(), cr = malloc<RectL>();
    try {
      if (getWinRectB(hwnd, wr) == 0 || getCliRectB(hwnd, cr) == 0) return;
      final cliW = cr.ref.right - cr.ref.left;
      final cliH = cr.ref.bottom - cr.ref.top;
      borderW = (wr.ref.right - wr.ref.left - cliW).clamp(0, 96);
      borderH = (wr.ref.bottom - wr.ref.top - cliH).clamp(0, 96);
      if (captureStartSize && cliW > 0 && cliH > 0) {
        _startW = cliW;
        _startH = cliH;
      }
    } catch (_) {
    } finally {
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
    _proc = NativeCallable<WndProcNative>.isolateLocal(
      _wndProc,
      exceptionalReturn: 0,
    );
    setWindowLongPtrW(hwnd, gwlWndProc, _proc!.nativeFunction.address);
    installed = true;
  }

  static int _wndProc(int hwnd, int msg, int wParam, int lParam) {
    try {
      if (wmEzMiGeekActivate != 0 && msg == wmEzMiGeekActivate) {
        final cb = onActivate;
        if (cb != null) {
          scheduleMicrotask(() {
            try {
              cb();
            } catch (_) {}
          });
        }
        return 0;
      }
      if (msg == _wmEnterSizeMove) {
        // WM_ENTERSIZEMOVE 的 wParam/lParam 恒为 0，绝不可把 lParam 当 RECT* 解引用。
        // 正确做法是用 GetWindowRect / GetClientRect 现量边框厚度与拖动起始尺寸。
        _remeasureBorders(hwnd, captureStartSize: true);
      } else if (msg == _wmDpiChanged) {
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

        final clientW = (w - borderW).toDouble();
        final clientH = (h - borderH).toDouble();
        final aspect = ratio;

        bool byW;
        if (wParam == 1 || wParam == 2) {
          byW = true; // LEFT / RIGHT：以宽为准
        } else if (wParam == 3 || wParam == 6) {
          byW = false; // TOP / BOTTOM：以高为准
        } else {
          // 拖角：比客户区宽/高的变化率。
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

        if (newClientW < minClientW) newClientW = minClientW.toDouble();
        if (newClientW > maxClientW) newClientW = maxClientW.toDouble();
        newClientH = newClientW * aspect;

        w = (newClientW + borderW).round();
        h = (newClientH + borderH).round();

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
        return 1;
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
