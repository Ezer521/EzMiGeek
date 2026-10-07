// ezshell.dart —— 外壳渲染器（glass/renderer.py 的逐行移植）。
// 设计坐标系 1043×1586；底衬 = 假毛玻璃（烤进窗口的极光，替代真实桌面透视），
// 上面白纱玻璃罩 + 全部控件，绘制顺序 / 材质 / 字号 / 命中与 Python 版逐值一致。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../core/ezui.dart';
import '../native/win32.dart'
    show findOwnWindowByClass, releaseCapture, sendMessageW, wmNcLButtonDown, htCaption;
import '../state/app_state.dart';

/// 头部 logo（真实应用图标 png）。main() 里 load 一次；读不到走矢量兜底。
class EzLogo {
  static ui.Image? image;
  static Future<void> load() async {
    try {
      final data = await rootBundle.load('assets/logo.png');
      final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
      image = (await codec.getNextFrame()).image;
    } catch (_) {}
  }
}

class EzShell extends StatefulWidget {
  const EzShell({super.key, required this.state});

  final AppState state;

  @override
  State<EzShell> createState() => _EzShellState();
}

class _EzShellState extends State<EzShell> {
  EzHit _hover = EzHit.none;

  double get _scale => _size.width / Geo.dw;
  Size _size = Size.zero;

  Offset _toDesign(Offset local) {
    if (_size == Size.zero) return local;
    final xOff = (_size.width - Geo.dw * _scale) / 2;
    final yOff = (_size.height - Geo.dh * _scale) / 2;
    return Offset((local.dx - xOff) / _scale, (local.dy - yOff) / _scale);
  }

  void _dispatchTap(EzHit hit) {
    final s = widget.state;
    switch (hit) {
      case EzHit.main: s.onOpenGeekClicked();
      case EzHit.tray: s.onHideToTray?.call();
      case EzHit.doc: s.openManual();
      case EzHit.log: s.openLogsFolder();
      case EzHit.toggle0: s.toggleRow(0);
      case EzHit.toggle1: s.toggleRow(1);
      case EzHit.toggle2: s.toggleRow(2);
      case EzHit.toggle3: s.toggleRow(3);
      case EzHit.relogin: s.startRelogin();
      case EzHit.lang: s.toggleLang();
      case EzHit.min: windowMin();
      case EzHit.max: windowMaxToggle();
      case EzHit.close: windowClose();
      case EzHit.none: break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onHover: (e) {
        final d = _toDesign(e.localPosition);
        final h = ezHit(d.dx, d.dy);
        if (h != _hover) setState(() => _hover = h);
      },
      onExit: (_) {
        if (_hover != EzHit.none) setState(() => _hover = EzHit.none);
      },
      cursor: _hover == EzHit.none ? MouseCursor.defer : SystemMouseCursors.click,
      child: Listener(
        onPointerDown: (e) {
          // 非控件区按下左键 ⇒ 开始拖窗口。走 Win32 原生通道
          //（ReleaseCapture + WM_NCLBUTTONDOWN/HTCAPTION）：拖动循环由系统接管，
          // 窗口 hide/收回时系统强制退出循环并释放捕获 —— 结构上不可能卡死鼠标。
          if (e.buttons != kPrimaryButton) return;
          final hit = ezHit(_toDesign(e.localPosition).dx, _toDesign(e.localPosition).dy);
          if (hit != EzHit.none) return;
          final hwnd = findMainWindow();
          if (hwnd == 0) return;
          releaseCapture();
          sendMessageW(hwnd, wmNcLButtonDown, htCaption, 0);
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) =>
              _dispatchTap(ezHit(_toDesign(d.localPosition).dx, _toDesign(d.localPosition).dy)),
          child: LayoutBuilder(builder: (context, cons) {
            _size = Size(cons.maxWidth, cons.maxHeight);
            return CustomPaint(
              size: Size.infinite,
              painter: EzShellPainter(state: widget.state, hover: _hover),
            );
          }),
        ),
      ),
    );
  }
}

/// 本进程主窗句柄（FLUTTER_RUNNER_WIN32_WINDOW 类名唯一）。
int? _mainHwnd;
int findMainWindow() {
  final cached = _mainHwnd;
  if (cached != null) return cached;
  final h = findOwnWindowByClass('FLUTTER_RUNNER_WIN32_WINDOW');
  _mainHwnd = h;
  return h;
}

// ── 窗口动作（由宿主注入，避免 UI 层直接 import window_manager 的耦合分散）──
void Function() windowMin = () {};
void Function() windowMaxToggle = () {};
void Function() windowClose = () {};

class EzShellPainter extends CustomPainter {
  /// 出图用：窗口放不下整幅时按高度缩放居中（--ui-png 置 true）。
  static bool fitWhole = false;

  EzShellPainter({required this.state, required this.hover});

  final AppState state;
  final EzHit hover;

  @override
  void paint(Canvas c, Size size) {
    _backdrop(c, size);

    var scale = size.width / Geo.dw;
    var yOff = (size.height - Geo.dh * scale) / 2;
    if (fitWhole && yOff < 0) {
      scale = size.height / Geo.dh;
      yOff = 0;
    }
    c.save();
    c.translate(0, yOff);
    c.scale(scale);
    _glassCover(c);
    _titleBar(c);
    _header(c);
    _card1(c);
    _buttonRow(c);
    ezTxt(c, state.ui.secTitle, EzFont.fSec(Pal.ink), Geo.secX, Geo.secCy, EzAlign.left);
    _infoLine(c);
    _card3(c);
    _bottomRow(c);
    _footer(c);
    _shellEdge(c);
    c.restore();
  }

  // ── 底衬：假毛玻璃（烤进窗口的极光，替代真实桌面透视）──
  void _backdrop(Canvas c, Size size) {
    final full = Offset.zero & size;
    c.drawRect(
        full,
        Paint()
          ..shader = ui.Gradient.linear(full.topCenter, full.bottomCenter,
              const [Color(0xFFC3DCFD), Color(0xFFB2D6FF)]));
    _glow(c, size, const Offset(-0.26, 0.38), 0.94, const Color(0xFFE0D6C8), 170); // 左下暖光
    _glow(c, size, const Offset(0.60, 0.05), 0.86, const Color(0xFFD0E6FF), 130); // 右上蓝光
    _glow(c, size, const Offset(0.16, -0.06), 0.62, const Color(0xFFB3DBFC), 200); // 左上浅蓝
    _glow(c, size, const Offset(0.50, -0.08), 0.58, const Color(0xFF96AAFC), 170); // 顶中莓紫
    _glow(c, size, const Offset(1.02, 0.40), 0.62, const Color(0xFFA7A6FC), 170); // 右中薰衣草
    _glow(c, size, const Offset(-0.02, 0.98), 0.64, const Color(0xFFE6C6F2), 190); // 左下粉
    _glow(c, size, const Offset(0.50, 1.04), 0.66, const Color(0xFFD9CFFC), 180); // 底中薰衣草
    _glow(c, size, const Offset(1.04, 0.98), 0.60, const Color(0xFF7FAFFD), 180); // 右下蓝
    _glow(c, size, const Offset(0.10, 0.30), 0.72, const Color(0xFF9CC2FC), 150); // 中左蓝团
    _glow(c, size, const Offset(1.02, 0.22), 0.58, const Color(0xFFEFD3EE), 150); // 右中粉团
    _glow(c, size, const Offset(0.55, 0.62), 0.66, const Color(0xFFB9D2FD), 130); // 中下蓝团
  }

  void _glow(Canvas c, Size size, Offset center, double radiusFactor, Color color, int alpha) {
    final r = size.shortestSide * radiusFactor;
    c.drawCircle(
      Offset(center.dx * size.width, center.dy * size.height),
      r,
      Paint()
        ..shader = ui.Gradient.radial(
          Offset(center.dx * size.width, center.dy * size.height),
          r,
          [color.withValues(alpha: alpha / 255), color.withValues(alpha: 0)],
        ),
    );
  }

  void _glassCover(Canvas c) {
    c.drawRect(
        Offset.zero & const Size(Geo.dw, Geo.dh),
        Paint()..color = Colors.white.withValues(alpha: 88 / 255));
  }

  void _shellEdge(Canvas c) {
    final p = rrPath(Offset.zero & const Size(Geo.dw, Geo.dh), Geo.sRad);
    c.drawPath(p,
        ezStroke..color = Colors.white.withValues(alpha: 185 / 255)..strokeWidth = 2.4);
    c.drawPath(p,
        ezStroke..color = Colors.white.withValues(alpha: 64 / 255)..strokeWidth = 5.5);
  }

  void _titleBar(Canvas c) {
    const color = Pal.iconTb;
    icoMin(c, Geo.tbCx[0], Geo.tbCy, 15, color, 2.2);
    icoMax(c, Geo.tbCx[1], Geo.tbCy, 14, color, 2.2);
    icoClose(c, Geo.tbCx[2], Geo.tbCy, 14, color, 2.2);
  }

  void _header(Canvas c) {
    final img = EzLogo.image;
    if (img != null) {
      c.drawImageRect(
        img,
        Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
        Rect.fromLTWH(Geo.logoX, Geo.logoY, Geo.logoW, Geo.logoW),
        Paint()..filterQuality = FilterQuality.high);
    } else {
      icoAppLogo(c, Rect.fromLTWH(Geo.logoX, Geo.logoY, Geo.logoW, Geo.logoW));
    }
    const brand = 'EzMiGeek'; // 品牌名，不进语言表（中英切换不变）
    ezTxt(c, brand, EzFont.fTtl(Pal.ink), Geo.titleX, Geo.titleCy, EzAlign.left);
    final sigX = Geo.titleX + ezTextWidth(brand, EzFont.fTtl(Pal.ink)) + Geo.signGap;
    ezTxt(c, 'by Ezer', EzFont.fSig(Pal.ink2), sigX, Geo.signCy, EzAlign.left);
    ezTxt(c, state.ui.headerSub, EzFont.fSub(Pal.ink2), Geo.subX, Geo.subCy, EzAlign.left);

    // ── 状态胶囊：按文案自动变宽（右沿钉死 CR，左沿不许压上头部文字）──
    final safeLeft = _pillSafeLeft(sigX);
    final pillStyle = EzFont.fPill(Pal.ink);
    final text = _fit(state.ui.status, pillStyle, Geo.pillMaxTextW(safeLeft));
    final (px, pw, dotCx, txX) = Geo.pillGeom(ezTextWidth(text, pillStyle), safeLeft);
    final pill = Rect.fromLTWH(px, Geo.pillCy - Geo.pillH / 2, pw, Geo.pillH);
    glass(c, pill, Geo.pillH / 2, Pal.aPill, 170, 2);
    c.drawCircle(Offset(dotCx, Geo.pillCy), Geo.pillDotD / 2, Paint()..color = _dotColor());
    ezTxt(c, text, pillStyle, txX, Geo.pillCy + 1, EzAlign.left);
  }

  double _pillSafeLeft(double sigX) {
    final bySig = sigX + ezTextWidth('by Ezer', EzFont.fSig(Pal.ink2));
    final bySub = Geo.subX + ezTextWidth(state.ui.headerSub, EzFont.fSub(Pal.ink2));
    return math.max(bySig, bySub) + Geo.pillSafeGap;
  }

  Color _dotColor() => switch (state.ui.dotColor) {
        'amber' => Pal.amber,
        'warn' => Pal.warn,
        _ => Pal.dot,
      };

  String _fit(String s, TextStyle style, double maxW) {
    if (ezTextWidth(s, style) <= maxW) return s;
    var lo = 1, hi = s.length, best = 1;
    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
      final t = '${s.substring(0, mid)}…';
      if (ezTextWidth(t, style) <= maxW) {
        best = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return '${s.substring(0, best)}…';
  }

  void _card1(Canvas c) {
    glass(c, Rect.fromLTWH(Geo.cl, Geo.c1y, Geo.cw, Geo.c1h), Geo.cardRad, Pal.aCard, 205, 2.2);

    icoMonitor(c, Rect.fromLTWH(Geo.c1IcoX, Geo.c1IcoY, Geo.c1IcoW, Geo.c1IcoH),
        Pal.iconBlue, 5.4);
    // 标题/副标题要截断：它们装的是真实状态文字（"出错了：…"会很长）。
    final maxw = Geo.cr - 30 - Geo.c1TxX; // 到卡片右内边留 30 的呼吸位
    ezTxt(c, _fit(state.ui.status, EzFont.fC1t(Pal.ink), maxw), EzFont.fC1t(Pal.ink),
        Geo.c1TxX, Geo.c1TxCy, EzAlign.left);
    ezTxt(c, _fit(state.ui.c1Sub, EzFont.fC1s(Pal.ink2), maxw), EzFont.fC1s(Pal.ink2),
        Geo.c1SubX, Geo.c1SubCy, EzAlign.left);
    // 状态卡右上的浅灰指引：固定短句、右对齐，与四家姊妹工具同句同位置。
    ezTxt(c, state.ui.c1Hint, EzFont.fC1hint(Pal.hintGrey), Geo.c1HintRx, Geo.c1HintCy,
        EzAlign.right);

    gLine(c, Geo.c1DivL, Geo.c1DivY, Geo.c1DivR, Geo.c1DivY,
        Pal.div.withValues(alpha: 70 / 255), 1.6);
    // 中竖分隔：一道暗线 + 一道白线（内凹效果）
    gLine(c, Geo.c1SepX, Geo.c1SepT, Geo.c1SepX, Geo.c1SepB,
        const Color(0xFFA8B8D0).withValues(alpha: 78 / 255), 2.0);
    gLine(c, Geo.c1SepX + 1.6, Geo.c1SepT, Geo.c1SepX + 1.6, Geo.c1SepB,
        Colors.white.withValues(alpha: 150 / 255), 1.4);

    ezTxt(c, state.ui.labL, EzFont.fLab(Pal.ink2), Geo.c1Lcx, Geo.c1LabCy, EzAlign.center);
    ezTxt(c, state.ui.labR, EzFont.fLab(Pal.ink2), Geo.c1Rcx, Geo.c1LabCy, EzAlign.center);
    ezTxt(c, state.ui.numL, EzFont.fNum(Pal.ink), Geo.c1Lcx, Geo.c1NumCy, EzAlign.center);
    ezTxt(c, state.ui.numR, EzFont.fNum(Pal.ink), Geo.c1Rcx, Geo.c1NumCy, EzAlign.center);
    ezTxt(
        c,
        _fit(state.ui.bottomLine, EzFont.fLast(Pal.ink3), Geo.cw - 110),
        EzFont.fLast(state.ui.warn ? Pal.warn : Pal.ink3),
        Geo.c1LastX,
        Geo.c1LastCy,
        EzAlign.center);
  }

  void _buttonRow(Canvas c) {
    _btn(c, Rect.fromLTWH(Geo.cl, Geo.btnY, Geo.cw, Geo.btnH), true, _IcoKind.play,
        state.ui.mainLabel, state.ui.canAct, hover == EzHit.main);
  }

  void _bottomRow(Canvas c) {
    final y = Geo.btn2Y;
    _btn(c, Rect.fromLTWH(Geo.btnX(0), y, Geo.btnW, Geo.btnH), false, _IcoKind.tray,
        state.ui.btnTray, true, hover == EzHit.tray);
    _btn(c, Rect.fromLTWH(Geo.btnX(1), y, Geo.btnW, Geo.btnH), false, _IcoKind.info,
        state.ui.btnDoc, true, hover == EzHit.doc);
    _btn(c, Rect.fromLTWH(Geo.btnX(2), y, Geo.btnW, Geo.btnH), false, _IcoKind.listDoc,
        state.ui.btnLog, true, hover == EzHit.log);
  }

  void _btn(Canvas c, Rect r, bool primary, _IcoKind ik, String label, bool enabled, bool hov) {
    if (primary) {
      // 通宽按钮用纯竖直渐变（两端色 = 参考图按钮上下沿实测色）。
      final ca = hov ? Pal.mix(Pal.btnTop, Colors.white, 0.16) : Pal.btnTop;
      final cb = hov ? Pal.mix(Pal.btnBot, Colors.white, 0.16) : Pal.btnBot;
      vGrad(c, r, Geo.btnRad, ca, cb);
      c.drawPath(rrPath(r, Geo.btnRad),
          ezStroke..color = Colors.white.withValues(alpha: 104 / 255)..strokeWidth = 1.8);
    } else {
      glass(c, r, Geo.btnRad, hov ? Pal.aBtn2 + 34 : Pal.aBtn2, 175, 2);
    }

    var fg = primary ? const Color(0xFFFCFFFF) : Pal.ink;
    if (!enabled) fg = fg.withValues(alpha: 150 / 255);
    final (iw, ih) = switch (ik) {
      _IcoKind.play => (24.0, 28.0),
      _IcoKind.tray => (30.0, 30.0),
      _IcoKind.listDoc => (28.0, 28.0),
      _IcoKind.info => (28.0, 28.0),
      _IcoKind.power => (26.0, 26.0),
      _IcoKind.monitor => (26.0, 26.0),
      _IcoKind.refresh => (26.0, 26.0),
    };
    final tw = ezTextWidth(label, EzFont.fBtn(Pal.ink));
    final total = iw + Geo.btnIcoGap + tw;
    final x0 = r.left + (r.width - total) / 2;
    final cy = r.top + r.height / 2 + 1;
    _icon(c, ik, Rect.fromLTWH(x0, cy - ih / 2, iw, ih), fg);
    ezTxt(c, label, EzFont.fBtn(fg), x0 + iw + Geo.btnIcoGap, cy, EzAlign.left);
  }

  // ── 设置卡（5 行：4 拨杆 + 1 动作行）──
  void _card3(Canvas c) {
    glass(c, Rect.fromLTWH(Geo.cl, Geo.c3y, Geo.cw, Geo.c3h), Geo.cardRad, Pal.aCard, 205, 2.2);

    final u = state.ui;
    for (var i = 0; i < 5; i++) {
      final cy = Geo.c3RowCy(i);
      switch (i) {
        case 0:
          _row(c, cy, _IcoKind.power, u.rowT[0], u.rowS[0], u.rowOn[0]);
        case 1:
          _row(c, cy, _IcoKind.tray, u.rowT[1], u.rowS[1], u.rowOn[1]);
        case 2:
          _row(c, cy, _IcoKind.monitor, u.rowT[2], u.rowS[2], u.rowOn[2]);
        case 3:
          _row(c, cy, _IcoKind.monitor, u.rowT[3], u.rowS[3], u.rowOn[3]);
        case 4:
          // ★ 动作行挪在最后一行：四个开关一组、一颗动作按钮收尾。
          _rowBtn(c, cy, _IcoKind.refresh, u.rowT[4], u.rowS[4], u.row5Act, u.row5Btn,
              hover == EzHit.relogin);
      }
      if (i < 4) {
        gLine(c, Geo.cl + 40, Geo.c3DivY(i), Geo.cr - 40, Geo.c3DivY(i),
            Pal.div.withValues(alpha: 64 / 255), 1.6);
      }
    }
  }

  /// ⓘ说明行 —— 在卡片**外面**、「一般设置」标题右侧（用户钦定的位置）。
  void _infoLine(Canvas c) {
    final dd = Geo.c3InfoIcoD;
    icoInfo(c, Rect.fromLTWH(Geo.c3InfoX, Geo.secCy - dd / 2, dd, dd), Pal.info);
    ezTxt(c, state.ui.infoLine, EzFont.fInfo(Pal.ink2), Geo.c3InfoX + dd + 15, Geo.secCy,
        EzAlign.left);
  }

  Rect _rowIconBox(double cy) =>
      Rect.fromLTWH(Geo.c3IcoX, cy - Geo.c3IcoH / 2, Geo.c3IcoW, Geo.c3IcoH);

  void _row(Canvas c, double cy, _IcoKind ik, String title, String sub, bool on) {
    _icon(c, ik, _rowIconBox(cy), Pal.iconNavy);
    final maxw = Geo.cr - 160 - Geo.c3TxX;
    ezTxt(c, title, EzFont.fC3t(Pal.ink), Geo.c3TxX, cy - 13, EzAlign.left, maxW: maxw);
    ezTxt(c, sub, EzFont.fC3s(Pal.ink2), Geo.c3TxX, cy + 13.5, EzAlign.left, maxW: maxw);
    _toggle(c, Geo.togX, cy + 2, on);
  }

  void _rowBtn(Canvas c, double cy, _IcoKind ik, String title, String sub, bool enabled,
      String label, bool hov) {
    _icon(c, ik, _rowIconBox(cy), Pal.iconNavy);
    // 文字可用宽度从红方块左沿退 26 气口反算 —— 两边共用同一几何真身，
    // 方块将来再改宽，这里自动跟着走。
    final maxw = (Geo.rowBtnX - 26) - Geo.c3TxX;
    ezTxt(c, title, EzFont.fC3t(Pal.ink), Geo.c3TxX, cy - 13, EzAlign.left, maxW: maxw);
    ezTxt(c, sub, EzFont.fC3s(Pal.ink2), Geo.c3TxX, cy + 13.5, EzAlign.left, maxW: maxw);
    _rowAction(c, cy, enabled, label, hov);
  }

  /// 动作行右边的家族式红色方块（重新登录）：母本 EzMMB WideSlot 同款几何，
  /// 配色 = Pal.Warn 纯色填充（上下同色，没有渐变 —— 与母本 danger 分支一致）。
  void _rowAction(Canvas c, double cy, bool enabled, String label, bool hov) {
    final r = Rect.fromLTWH(
        Geo.rowBtnX, cy + 2 - Geo.rowBtnH / 2, Geo.rowBtnW, Geo.rowBtnH);
    final base = Pal.mix(Pal.warn, Colors.white, enabled && hov ? 0.16 : 0.0);
    fillRR(c, r, Geo.rowBtnRad, base);
    c.drawPath(rrPath(r, Geo.rowBtnRad),
        ezStroke..color = Colors.white.withValues(alpha: 104 / 255)..strokeWidth = 1.8);

    var fg = const Color(0xFFFCFFFF);
    if (!enabled) fg = fg.withValues(alpha: 150 / 255);
    const ik = _IcoKind.refresh;
    const iw = 26.0, ih = 26.0;
    final tw = ezTextWidth(label, EzFont.fBtn(Pal.ink));
    final total = iw + Geo.btnIcoGap + tw;
    final x0 = r.left + (r.width - total) / 2;
    final bx = r.top + r.height / 2 + 1;
    _icon(c, ik, Rect.fromLTWH(x0, bx - ih / 2, iw, ih), fg);
    ezTxt(c, label, EzFont.fBtn(fg), x0 + iw + Geo.btnIcoGap, bx, EzAlign.left);
  }

  void _toggle(Canvas c, double x, double cy, bool on) {
    final r = Rect.fromLTWH(x, cy - Geo.togH / 2, Geo.togW, Geo.togH);
    final p = rrPath(r, Geo.togH / 2);
    c.drawPath(
        p,
        Paint()
          ..color = (on ? Pal.iconBlue : Pal.togOff).withValues(alpha: 228 / 255));
    c.drawPath(p,
        ezStroke..color = Colors.white.withValues(alpha: 80 / 255)..strokeWidth = 1.5);
    // 与原版 Toggle 逐值一致：d = TogH−8；FillEllipse(kx, Y+4, d, d) 里 kx/Y+4
    // 是**左/上边缘**，drawCircle 要圆心 ⇒ x/y 各补 d/2（x 漏补 = 圆钮缩到轨道
    // 中间，EzMMB 实测摔过）。
    final d = Geo.togH - 8;
    final kx = on ? r.right - 4 - d : r.left + 4;
    c.drawCircle(
        Offset(kx + 1 + d / 2, r.top + 5 + d / 2),
        d / 2,
        Paint()..color = const Color(0xFF142850).withValues(alpha: 40 / 255));
    c.drawCircle(
        Offset(kx + d / 2, r.top + 4 + d / 2),
        d / 2,
        Paint()..color = Colors.white.withValues(alpha: 252 / 255));
  }

  void _footer(Canvas c) {
    ezTxt(c, state.ui.foot1, EzFont.fFoot(Pal.ink3), Geo.footX, Geo.foot1Cy, EzAlign.left);
    ezTxt(c, state.ui.foot2, EzFont.fFoot(Pal.ink3), Geo.footX, Geo.foot2Cy, EzAlign.left);
    // 右侧「中 / EN」语言胶囊（与 EzGlow 同款几何）。
    final r = Rect.fromLTWH(Geo.langX, Geo.foot2Cy - Geo.langH / 2, Geo.langW, Geo.langH);
    glass(c, r, Geo.langH / 2, hover == EzHit.lang ? Pal.aPill + 40 : Pal.aPill, 170, 2);
    final cOn = Pal.ink;
    final cOff = Pal.ink3.withValues(alpha: 150 / 255);
    final zh = state.ui.langZh;
    ezTxt(c, '中', EzFont.fLang(zh ? cOn : cOff), Geo.langX + Geo.langW * 0.30,
        Geo.foot2Cy + 1, EzAlign.center);
    ezTxt(c, 'EN', EzFont.fLang(zh ? cOff : cOn), Geo.langX + Geo.langW * 0.72,
        Geo.foot2Cy + 1, EzAlign.center);
  }

  // ── 图标分发（renderer._icon 同款；线宽都是设计稿实测量）──
  void _icon(Canvas c, _IcoKind ik, Rect b, Color color) {
    switch (ik) {
      case _IcoKind.play: icoPlay(c, b, color);
      case _IcoKind.tray: icoTray(c, b, color, 5.6);
      case _IcoKind.listDoc: icoListDoc(c, b, color, 5.4);
      case _IcoKind.info: icoInfo(c, b, color);
      case _IcoKind.power: icoPower(c, b, color, 5.0);
      case _IcoKind.monitor: icoMonitor(c, b, color, 5.0);
      case _IcoKind.refresh: icoRefresh(c, b, color, 4.6);
    }
  }

  @override
  bool shouldRepaint(EzShellPainter old) => true; // 悬停/状态都走重绘（帧率足够）
}

enum _IcoKind { play, tray, listDoc, info, power, monitor, refresh }
