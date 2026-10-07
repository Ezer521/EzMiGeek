// ezui.dart —— Python 版 glass/ui.py + renderer.py + icons.py 的逐行 Flutter 移植。
//
// 设计单位 = 参考图像素；基准外壳 1043×1586（原点 = 外壳左上角），
// 全部绘制都在设计坐标系完成（与原版同一套坐标），一次缩放整体呈现。
// 调色板 / 字号 / 卡片材质 / 命中逻辑与 ui.py / renderer.py / icons.py 逐值一致。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

// ============================================================ 调色板（Pal，逐值一致）
abstract final class Pal {
  static const Color ink = Color(0xFF020C32); // 主文字 近黑藏蓝 (2,12,50)
  static const Color ink2 = Color(0xFF243A5C); // 次级文字 (36,58,92)
  static const Color ink3 = Color(0xFF4E5D7A); // 说明 / 页脚 (78,93,122)
  static const Color div = Color(0xFF96A8C4); // 分隔线 (150,168,196)
  static const Color btnTop = Color(0xFF379CFC); // 主按钮渐变上 (55,156,252)
  static const Color btnBot = Color(0xFF1A7AF5); // 主按钮渐变下 (26,122,245)
  static const Color iconBlue = Color(0xFF1470E8); // 线描图标-蓝（显示器）(20,112,232)
  static const Color iconNavy = Color(0xFF12305F); // 线描图标-深藏蓝（其余）(18,48,95)
  static const Color iconTb = Color(0xFF223553); // 标题栏三钮 (34,53,83)
  static const Color togOff = Color(0xFFB4BECE); // 拨杆关-轨道 (180,190,206)
  static const Color dot = Color(0xFF96A0B2); // 状态圆点 (150,160,178)
  static const Color info = Color(0xFF96A3BB); // ⓘ (150,163,187)
  static const Color warn = Color(0xFFB74D24); // 警告/动作行红块 (183,77,36)
  static const Color amber = Color(0xFFBE7E18); // 取码/填码中（琥珀）(190,126,24)
  static const Color hintGrey = Color(0xFFA3ADBE); // 卡片浅灰提示 (163,173,190)

  /// 卡片/按钮的白色填充强度（renderer.py 的 ACard/ABtn2/APill）。
  static const int aCard = 90, aBtn2 = 150, aPill = 118;

  static Color a(int alpha, Color c) => c.withValues(alpha: alpha / 255);

  static Color mix(Color a, Color b, double t) => Color.fromARGB(
      ((a.a + (b.a - a.a) * t) * 255).round(),
      ((a.r + (b.r - a.r) * t) * 255).round(),
      ((a.g + (b.g - a.g) * t) * 255).round(),
      ((a.b + (b.b - a.b) * t) * 255).round());
}

// ============================================================ 几何网格（Geo，逐值一致）
abstract final class Geo {
  static const double dw = 1043; // 外壳宽（设计单位）
  static const double dh = 1586; // 外壳高（SetRows=5）
  static const double sRad = 21; // 外壳圆角
  static const double cl = 33, cr = 1010; // 内容左右边界
  static const double cw = cr - cl; // 977
  static const double cardRad = 24, btnRad = 18;

  // ---- 标题栏
  static const double tbCy = 29;
  static const double tbDragH = 58;
  static const List<double> tbCx = [849.5, 926.5, 1003];

  // ---- 头部
  static const double logoX = 41, logoY = 54, logoW = 112;
  static const double titleX = 183, titleCy = 93;
  static const double signGap = 15, signCy = 102.4;
  static const double subX = 185, subCy = 151;

  // ---- 状态胶囊（2026-09-25 起按文案自动变宽）
  static const double pillW = 189, pillH = 64, pillCy = 118;
  static const double pillDotCx = 862, pillDotD = 27, pillTxX = 899;
  // 设计稿那颗 189 宽的胶囊横向拆开：左内边距 27.5 ＋ 圆点 27 ＋ 间隙 23.5
  // ＋ 文字 ＋ 右内边距 27.5 ⇒ 文字只有 83.5 的位子。文字没超 83.5 就
  // 一个像素都不动；超了就往左长（右沿钉死 CR），左右内边距永远相等。
  static const double pillPad = 27.5, pillGap = 23.5, pillHeadW = 78;
  static const double pillSafeGap = 20; // 胶囊左沿与头部文字之间的最小间隙

  static double get pillX => cr - pillW;
  static double get pillTextW => pillW - pillHeadW - pillPad; // 83.5

  /// 胶囊几何，返回 (x, w, dot_cx, tx_x)。
  /// 文字比设计宽度宽多少，胶囊就往左长多少；左沿不许越过 `safeLeft`。
  static (double, double, double, double) pillGeom(double textW, double? safeLeft) {
    var w = pillW + math.max(0.0, textW - pillTextW);
    if (safeLeft != null) {
      w = math.min(w, math.max(pillW, cr - safeLeft));
    }
    final d = w - pillW;
    return (cr - w, w, pillDotCx - d, pillTxX - d);
  }

  /// 左沿被 `safeLeft` 钳住之后，文字最多还能有多宽（超出必须截断）。
  static double pillMaxTextW(double safeLeft) => (cr - safeLeft) - pillHeadW - pillPad;

  // ---- 卡片1（状态卡）
  static const double c1y = 198, c1h = 317;
  static const double c1IcoX = 85, c1IcoY = 240, c1IcoW = 78, c1IcoH = 70;
  static const double c1TxX = 204, c1TxCy = 262;
  static const double c1SubX = 205, c1SubCy = 305;
  static const double c1DivY = 343, c1DivL = 66, c1DivR = 977;
  static const double c1LabCy = 380, c1NumCy = 429, c1LastCy = 484;
  static const double c1Lcx = 382, c1Rcx = 684;
  static const double c1SepX = 522, c1SepT = 348, c1SepB = 440;
  static const double c1LastX = 521;
  // 右上浅灰指引：本机口径补到 915/283（TxtR 测量盒与 C# 的已知差 ——
  // ui.py 注释里的那一轮校准），让墨迹盒与四家姊妹工具落在同一像素上。
  static const double c1HintRx = 915, c1HintCy = 283;

  // ---- 主按钮行（通宽一颗「极客开启」）
  static const double btnY = 532, btnH = 71, btnGap = 24, btnIcoGap = 29;
  static double get btnW => (cw - 2 * btnGap) / 3;
  static double btnX(int i) => cl + i * (btnW + btnGap);

  // ---- 分组标题 + 设置卡（2026-09-18 定稿：动作卡带撤掉，设置卡上移拉长）
  static const double secX = 37, secCy = 651;
  static const double c3y = 675, c3Row1Cy = 726, c3RowStep = 141;
  static const double c3IcoX = 70, c3IcoW = 37, c3IcoH = 40;
  static const double c3TxX = 141;
  static const double c3InfoIcoD = 23;
  static const double togW = 78, togH = 42, togInset = 41;
  static double get togX => cr - togInset - togW;

  // 设置卡动作行红方块（2026-09-21 晚：母本 EzMMB WideSlot 同款几何）
  static const double rowBtnW = 437.5, rowBtnH = 84, rowBtnRad = 24;
  static double get rowBtnX => cr - togInset - rowBtnW; // 右沿与拨杆同一条边

  /// ⓘ说明行的左沿 —— 现在在卡片**外面**、「一般设置」标题右侧
  /// （用户指定：那行"重新登录成功"的小字移到上面箭头指的地方）。
  /// 固定位移 130：中英文标题几乎同宽，一个常数对两种语言都成立。
  static double get c3InfoX => secX + 130;

  // ---- 行中线 / 设置卡高 / 底部钮 / 页脚（SetRows=5 定稿值）
  static double c3RowCy(int i) => c3Row1Cy + i * c3RowStep; // 726/867/1008/1149/1290
  static double c3DivY(int i) => c3RowCy(i) + 48;
  static double get c3h => (c3RowCy(4) + 48 + 59) - c3y; // 722
  static double get btn2Y => c3y + c3h + 19; // 1416
  static double get foot1Cy => btn2Y + 108; // 1524
  static double get foot2Cy => btn2Y + 137; // 1553

  // ---- 页脚
  static const double footX = 37;
  static const double langW = 124, langH = 50;
  static double get langX => cr - langW;
}

// ============================================================ 字号（renderer.py 字体表，像素）
abstract final class EzFont {
  static const String family = 'Microsoft YaHei UI';

  /// YaHei 缺 Dingbat 字形（✓ 等）时落 Segoe UI Symbol。
  /// 真机 DirectWrite 本来就会系统级兜底，显式声明同效，且让金样
  /// 出图（无系统 fallback 的测试环境）也能出对勾。
  static const List<String> fallback = ['Segoe UI Symbol'];

  static TextStyle f(double px, {bool bold = false, Color? color}) => TextStyle(
      fontFamily: family,
      fontFamilyFallback: fallback,
      fontSize: px,
      fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
      color: color,
      height: 1.0,
      letterSpacing: 0);

  static TextStyle fTtl(Color c) => f(56, bold: true, color: c);
  static TextStyle fSig(Color c) => f(26, color: c);
  static TextStyle fSub(Color c) => f(25, color: c);
  static TextStyle fC1t(Color c) => f(36, bold: true, color: c);
  static TextStyle fC1s(Color c) => f(25, color: c);
  static TextStyle fC1hint(Color c) => f(28, color: c);
  static TextStyle fLab(Color c) => f(23, color: c);
  static TextStyle fNum(Color c) => f(46, bold: true, color: c);
  static TextStyle fLast(Color c) => f(21, color: c);
  static TextStyle fBtn(Color c) => f(26, color: c);
  static TextStyle fSec(Color c) => f(27, bold: true, color: c);
  static TextStyle fC3t(Color c) => f(23, bold: true, color: c);
  static TextStyle fC3s(Color c) => f(20, color: c);
  static TextStyle fInfo(Color c) => f(20.4, color: c);
  static TextStyle fFoot(Color c) => f(19, color: c);
  static TextStyle fPill(Color c) => f(25, color: c);
  static TextStyle fLang(Color c) => f(21, bold: true, color: c);
}

// ============================================================ 绘制原语（G，逐行移植）

final Paint ezStroke = Paint()
  ..style = PaintingStyle.stroke
  ..strokeCap = StrokeCap.round
  ..strokeJoin = StrokeJoin.round;

Path rrPath(Rect r, double rad) {
  rad = math.min(rad, math.min(r.width / 2, r.height / 2));
  return Path()..addRRect(RRect.fromRectAndRadius(r, Radius.circular(rad)));
}

/// G.Glass：白纱填充 + 顶部高光渐变（裁剪在圆角内）+ 白描边。
void glass(Canvas c, Rect r, double rad, int fillA, int edgeA, double edgeW) {
  final p = rrPath(r, rad);
  c.drawPath(p, Paint()..color = Colors.white.withValues(alpha: fillA / 255));
  c.save();
  c.clipPath(p);
  final hh = math.min(r.height * 0.45, 100.0);
  final hi = Rect.fromLTWH(r.left, r.top - 0.5, r.width, hh + 1);
  c.drawRect(
    hi,
    Paint()
      ..shader = ui.Gradient.linear(hi.topCenter, hi.bottomCenter,
          [Colors.white.withValues(alpha: 66 / 255), Colors.white.withValues(alpha: 0)]),
  );
  c.restore();
  c.drawPath(
      p,
      ezStroke
        ..color = Colors.white.withValues(alpha: edgeA / 255)
        ..strokeWidth = edgeW);
}

/// G.VGrad：圆角垂直渐变。
void vGrad(Canvas c, Rect r, double rad, Color top, Color bot) {
  c.drawPath(
      rrPath(r, rad),
      Paint()
        ..shader = ui.Gradient.linear(r.topCenter, r.bottomCenter, [top, bot]));
}

/// G.Fill：圆角纯色。
void fillRR(Canvas c, Rect r, double rad, Color color) {
  c.drawPath(rrPath(r, rad), Paint()..color = color);
}

/// G.Line：圆帽线。
void gLine(Canvas c, double x1, double y1, double x2, double y2, Color color, double w) {
  c.drawLine(Offset(x1, y1), Offset(x2, y2),
      ezStroke..color = color..strokeWidth = w);
}

enum EzAlign { left, center, right }

/// G.Txt：按「视觉中线 cy」排版（TextPainter 实测高居中，与 GDI boxH 居中同义）。
Size ezTxt(Canvas c, String s, TextStyle style, double x, double cy, EzAlign al,
    {double? maxW}) {
  var text = s;
  final tp = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();
  if (maxW != null && tp.width > maxW) {
    // _fit：超宽按字符截断加省略号（与 Python 版 _fit 同语义）。
    var lo = 1, hi = s.length, best = 1;
    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
      final t = '${s.substring(0, mid)}…';
      final t2 = TextPainter(
          text: TextSpan(text: t, style: style),
          textDirection: TextDirection.ltr,
          maxLines: 1)
        ..layout();
      if (t2.width <= maxW) {
        best = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    text = '${s.substring(0, best)}…';
    final tp2 = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,
        maxLines: 1)
      ..layout();
    tp2.paint(c, Offset(_bx(tp2.width, x, al), cy - tp2.height / 2));
    return tp2.size;
  }
  tp.paint(c, Offset(_bx(tp.width, x, al), cy - tp.height / 2));
  return tp.size;
}

double _bx(double w, double x, EzAlign al) =>
    al == EzAlign.left ? x : (al == EzAlign.center ? x - w / 2 : x - w);

double ezTextWidth(String s, TextStyle style) {
  final tp = TextPainter(
      text: TextSpan(text: s, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1)
    ..layout();
  return tp.width;
}

// ============================================================ 图标（icons.py，0..100 归一化移植）

/// 0..100 归一化图标画布：X/Y 独立缩放到框。
class IBox {
  IBox(Canvas c, Rect b, double designW)
      : _c = c,
        sw = designW * 100 / b.width {
    _c.save();
    _c.translate(b.left, b.top);
    _c.scale(b.width / 100, b.height / 100);
  }

  final Canvas _c;
  final double sw; // 100 空间线宽
  double get k => sw / 2;

  Paint pen(Color color) => Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = sw
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  Paint brush(Color color) => Paint()..color = color;

  void line(double x1, double y1, double x2, double y2, Paint p) =>
      _c.drawLine(Offset(x1, y1), Offset(x2, y2), p);

  void rrect(double x, double y, double w, double h, double r, Paint p) {
    final d = math.min(r * 2, math.min(w, h));
    _c.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(x, y, w, h), Radius.circular(d / 2)),
        p);
  }

  /// 椭圆弧（GDI draw_arc 的 (x,y,w,h,start,sweep) 口径）。
  void earc(double x, double y, double w, double h, double startDeg,
      double sweepDeg, Paint p) {
    _c.drawArc(Rect.fromLTWH(x, y, w, h), startDeg * math.pi / 180,
        sweepDeg * math.pi / 180, false, p);
  }

  void oval(double x, double y, double w, double h, Paint p) =>
      _c.drawOval(Rect.fromLTWH(x, y, w, h), p);

  void poly(List<Offset> pts, Paint p) =>
      _c.drawPath(Path()..addPolygon(pts, true), p);

  void release() => _c.restore();
}

/// Ico.monitor：显示器（屏幕 + 支柱 + 底座）。框 = 78×70 量级。
void icoMonitor(Canvas c, Rect b, Color color, double w) {
  final box = IBox(c, b, w);
  final p = box.pen(color);
  box.rrect(box.k, box.k, 100 - 2 * box.k, 68 - box.k, 11, p);
  box.line(50, 68, 50, 100 - 2 * box.k, p);
  box.line(24, 100 - box.k, 76, 100 - box.k, p);
  box.release();
}

/// Ico.refresh：循环刷新（单弧 + 箭头）。
void icoRefresh(Canvas c, Rect b, Color color, double w) {
  final box = IBox(c, b, w);
  final p = box.pen(color);
  box.earc(box.k, box.k + 4, 100 - 2 * box.k, 100 - 2 * box.k - 4, -66, 288, p);
  box.poly(
      [Offset(66, box.k), const Offset(96, 26), const Offset(64, 40)],
      box.brush(color));
  box.release();
}

/// Ico.power：电源（开口弧 + 竖棒）。
void icoPower(Canvas c, Rect b, Color color, double w) {
  final box = IBox(c, b, w);
  final p = box.pen(color);
  box.earc(box.k, box.k + 7, 100 - 2 * box.k, 100 - 2 * box.k - 7, -58, 296, p);
  box.line(50, box.k, 50, 46, p);
  box.release();
}

/// Ico.tray：下载进托盘。
void icoTray(Canvas c, Rect b, Color color, double w) {
  final box = IBox(c, b, w);
  final p = box.pen(color);
  box.line(50, box.k, 50, 56, p);
  box.line(27, 32, 50, 58, p);
  box.line(73, 32, 50, 58, p);
  box.line(box.k, 68, box.k, 100 - box.k, p);
  box.line(box.k, 100 - box.k, 100 - box.k, 100 - box.k, p);
  box.line(100 - box.k, 100 - box.k, 100 - box.k, 68, p);
  box.release();
}

/// Ico.list_doc：文档列表。
void icoListDoc(Canvas c, Rect b, Color color, double w) {
  final box = IBox(c, b, w);
  final p = box.pen(color);
  box.rrect(box.k, box.k, 100 - 2 * box.k, 100 - 2 * box.k, 13, p);
  box.line(30, 32, 70, 32, p);
  box.line(30, 52, 70, 52, p);
  box.line(30, 72, 58, 72, p);
  box.release();
}

/// Ico.info：实心圆 + 白 i。
void icoInfo(Canvas c, Rect b, Color color) {
  final box = IBox(c, b, 100 * b.width / 100);
  box.oval(0, 0, 100, 100, box.brush(color));
  box.oval(44.5, 20, 11, 11, box.brush(Colors.white));
  box.rrect(44.5, 37, 11, 41, 5.5, box.brush(Colors.white));
  box.release();
}

/// Ico.play：实心圆角三角（主按钮「极客开启」）。
void icoPlay(Canvas c, Rect b, Color color) {
  final box = IBox(c, b, 100 * b.width / 100);
  final path = Path()
    ..addPolygon([const Offset(7, 5), const Offset(95, 50), const Offset(7, 95)],
        true);
  c.drawPath(path, box.brush(color));
  c.drawPath(path, box.pen(color)..strokeWidth = 9);
  box.release();
}

// ---- 应用 logo 矢量兜底（icons.py app_logo_vector；主路径用 assets/logo.png）
const List<double> _tgPos = [0, 0.15, 0.30, 0.45, 0.60, 0.75, 0.90, 1.0];
const List<Color> _tgCol = [
  Color(0xFF81E9FD), Color(0xFF68CDFC), Color(0xFF52B3FB), Color(0xFF3D9CFA),
  Color(0xFF2B87F9), Color(0xFF1A74F8), Color(0xFF0C63F7), Color(0xFF0359F7),
];

/// 应用图标（矢量兜底）：蓝渐变方块 + 白显示器 + 电源符号 + 徽章挖空。
void icoAppLogo(Canvas c, Rect b) {
  final rad = b.width * 0.215;
  // ① 方块底下那圈柔和的蓝光（同心圆堆叠近似径向渐变）
  for (var i = 14; i >= 1; i--) {
    final t = i / 14.0;
    final rr = b.width * 0.67 * t;
    final a = (120 * t).round();
    if (a <= 0) continue;
    c.drawCircle(
        Offset(b.left + b.width * 0.50, b.top + b.height * 0.51),
        rr,
        Paint()..color = const Color(0xFF3A8CFF).withValues(alpha: a / 255));
  }
  void tile(Rect r) {
    // ② 8 段实测渐变（icons.py 的 _TG_POS/_TG_COL），63.3° 斜向。
    final dx = math.cos(63.3 * math.pi / 180), dy = math.sin(63.3 * math.pi / 180);
    final len = r.width * dx + r.height * dy;
    c.drawPath(
        rrPath(r, rad),
        Paint()
          ..shader = ui.Gradient.linear(
              Offset(
                  r.center.dx - dx * len / 2, r.center.dy - dy * len / 2),
              Offset(r.center.dx + dx * len / 2, r.center.dy + dy * len / 2),
              _tgCol,
              _tgPos));
  }

  tile(b);
  // ③ 徽章「挖空」：用同份渐变在圆盘里重画一遍，把被徽章盖住的描边切断。
  final disc = Rect.fromCircle(
      center: Offset(b.left + b.width * 0.734, b.top + b.height * 0.639),
      radius: b.width * 0.179);
  c.save();
  c.clipPath(Path()..addOval(disc));
  tile(b);
  c.restore();
  // ④ 白显示器 + 电源符号（0..100 空间）
  final box = IBox(c, b, 100 * b.width / 100);

  final pScr = Paint()
    ..color = const Color(0xFFFCFFFF)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 5.0
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  box.rrect(22, 22.8, 52.8, 42.2, 4.0, pScr);
  box.line(46, 65, 46, 77.5, pScr);
  box.line(34.5, 77.5, 57.5, 77.5, pScr);
  final pPwr = Paint()
    ..color = const Color(0xFFFCFFFF)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 3.1
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  box.earc(73.6 - 11.4, 66.8 - 11.4, 22.8, 22.8, -53, 287, pPwr);
  box.line(73.6, 51.8, 73.6, 63.8, pPwr);
  box.release();

}

// ---- 标题栏三钮
void icoMin(Canvas c, double cx, double cy, double s, Color color, double w) =>
    gLine(c, cx - s / 2, cy, cx + s / 2, cy, color, w);

void icoMax(Canvas c, double cx, double cy, double s, Color color, double w) {
  c.drawRect(Rect.fromLTWH(cx - s / 2, cy - s / 2, s, s),
      ezStroke..color = color..strokeWidth = w);
}

void icoClose(Canvas c, double cx, double cy, double s, Color color, double w) {
  gLine(c, cx - s / 2, cy - s / 2, cx + s / 2, cy + s / 2, color, w);
  gLine(c, cx + s / 2, cy - s / 2, cx - s / 2, cy + s / 2, color, w);
}

// ============================================================ 命中（renderer.Hit，逐行移植）

enum EzHit {
  none,
  main,
  tray,
  doc,
  log,
  toggle0,
  toggle1,
  toggle2,
  toggle3,
  relogin,
  lang,
  min,
  max,
  close,
}

/// 行号 → 拨杆 Hit；`null` = 动作行（重新登录），那一行没有拨杆。
/// ★ 顺序必须与设置卡的行序一致（改行序 = 三处同步：这里、_card3、fill_state）。
const List<EzHit?> kRowToggles = [
  EzHit.toggle0,
  EzHit.toggle1,
  EzHit.toggle2,
  EzHit.toggle3,
  null, // 动作行（重新登录）
];

EzHit ezHit(double x, double y) {
  // 标题栏三钮（口径比字形大一圈，好点）。
  if (y >= Geo.tbCy - 26 && y <= Geo.tbCy + 26) {
    for (var i = 0; i < 3; i++) {
      if ((x - Geo.tbCx[i]).abs() <= 26) {
        return i == 0 ? EzHit.min : (i == 1 ? EzHit.max : EzHit.close);
      }
    }
  }
  if (y >= Geo.btnY && y <= Geo.btnY + Geo.btnH && x >= Geo.cl && x <= Geo.cr) {
    return EzHit.main;
  }
  if (y >= Geo.btn2Y && y <= Geo.btn2Y + Geo.btnH) {
    final bw = Geo.btnW;
    if (x >= Geo.btnX(0) && x <= Geo.btnX(0) + bw) return EzHit.tray;
    if (x >= Geo.btnX(1) && x <= Geo.btnX(1) + bw) return EzHit.doc;
    if (x >= Geo.btnX(2) && x <= Geo.btnX(2) + bw) return EzHit.log;
  }
  // 页脚右侧「中 / EN」语言胶囊。
  if (x >= Geo.langX &&
      x <= Geo.cr &&
      y >= Geo.foot2Cy - Geo.langH / 2 &&
      y <= Geo.foot2Cy + Geo.langH / 2) {
    return EzHit.lang;
  }
  // 设置卡 5 行：4 行拨杆（x >= C3TxX 整行可点）+ 1 行动作（红方块本身）。
  for (var i = 0; i < 5; i++) {
    final cy = Geo.c3RowCy(i);
    if (y < cy - 48 || y > cy + 48) continue;
    if (x < Geo.c3TxX) continue;
    final hit = kRowToggles[i];
    if (hit == null) {
      // 动作行：命中区是红方块**本身**（不是整行 —— 会弹确认框，收窄误触面）。
      if (x >= Geo.rowBtnX &&
          x <= Geo.rowBtnX + Geo.rowBtnW &&
          y >= cy - Geo.rowBtnH / 2 &&
          y <= cy + Geo.rowBtnH / 2) {
        return EzHit.relogin;
      }
      continue;
    }
    return hit;
  }
  return EzHit.none;
}
