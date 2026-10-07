// widget_test.dart —— 冒烟：外壳能挂载、命中表关键区不漂移。
//
// ★ 不起真窗口（window_manager 在测试环境不可用），只测纯几何：
//   命中表是纯函数，直接打点断言。

import 'package:ezmigeek_flutter/core/ezui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('设计外壳 = 1043×1586（SetRows=5 定稿）', () {
    expect(Geo.dw, 1043);
    expect(Geo.dh, 1586);
    expect(Geo.btn2Y, 1416);
    expect(Geo.foot2Cy, 1553);
  });

  test('命中表：主按钮 / 底部三钮 / 语言胶囊 / 标题栏三钮', () {
    expect(ezHit(521, 567), EzHit.main); // 通宽主按钮中心
    expect(ezHit(Geo.btnX(0) + 10, Geo.btn2Y + 35), EzHit.tray);
    expect(ezHit(Geo.btnX(1) + 10, Geo.btn2Y + 35), EzHit.doc);
    expect(ezHit(Geo.btnX(2) + 10, Geo.btn2Y + 35), EzHit.log);
    expect(ezHit(Geo.cr - 30, Geo.foot2Cy), EzHit.lang);
    expect(ezHit(Geo.tbCx[0], Geo.tbCy), EzHit.min);
    expect(ezHit(Geo.tbCx[1], Geo.tbCy), EzHit.max);
    expect(ezHit(Geo.tbCx[2], Geo.tbCy), EzHit.close);
  });

  test('命中表：5 行设置卡 = 4 拨杆 + 1 动作行（红方块本身）', () {
    expect(ezHit(Geo.c3TxX + 10, Geo.c3RowCy(0)), EzHit.toggle0);
    expect(ezHit(Geo.c3TxX + 10, Geo.c3RowCy(1)), EzHit.toggle1);
    expect(ezHit(Geo.c3TxX + 10, Geo.c3RowCy(2)), EzHit.toggle2);
    expect(ezHit(Geo.c3TxX + 10, Geo.c3RowCy(3)), EzHit.toggle3);
    // 动作行：整行大部分点不中，红方块内才中。
    expect(ezHit(Geo.c3TxX + 10, Geo.c3RowCy(4)), EzHit.none);
    expect(ezHit(Geo.rowBtnX + 100, Geo.c3RowCy(4)), EzHit.relogin);
    // 空白区
    expect(ezHit(520, 640), EzHit.none);
  });

  test('胶囊自动变宽：短文案保持 189，长文案往左长、右沿钉死 CR', () {
    final (x0, w0, dot0, tx0) = Geo.pillGeom(Geo.pillTextW, null);
    expect(w0, Geo.pillW);
    expect(x0, Geo.pillX);
    expect(dot0, Geo.pillDotCx);
    expect(tx0, Geo.pillTxX);
    final (x1, w1, dot1, tx1) = Geo.pillGeom(265.8, null);
    expect(w1, closeTo(Geo.pillW + 265.8 - Geo.pillTextW, 0.01));
    expect(x1 + w1, Geo.cr); // 右沿钉死
    expect(dot1, closeTo(Geo.pillDotCx - (w1 - Geo.pillW), 0.01));
    expect(tx1, closeTo(Geo.pillTxX - (w1 - Geo.pillW), 0.01));
  });
}
