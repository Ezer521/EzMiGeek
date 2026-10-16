// filler.dart —— 把 6 位码填进页面（app/filler.py 移植）。
//
// ★ 为什么不用合成事件（Python 版 2026-09-16 实测）：页面里 dispatchEvent
//   造出来的 pointer/click 序列**页面不认** —— agent 的 fill() 老老实实返回
//   true，登录界面毫无反应。所以用 CDP 发【真·鼠标事件】Input.
//   dispatchMouseEvent。这正是「宿主控制浏览器」比「油猴脚本」强的地方。
library;

import 'dart:convert';

import 'cdp.dart';

Future<Map<String, double>?> _rectInner(CdpTab tab, String expr) async {
  final raw = await tab.js('JSON.stringify($expr)');
  if (raw == null || raw == 'null' || raw is! String || raw.isEmpty) return null;
  try {
    final j = jsonDecode(raw);
    if (j is Map && j['x'] != null && j['y'] != null) {
      return {'x': double.parse('${j['x']}'), 'y': double.parse('${j['y']}')};
    }
  } catch (_) {}
  return null;
}

/// 逐个数字键发真实鼠标事件，返回成功点下去的位数。
Future<int> clickKeys(CdpTab tab, String code,
    {void Function(Object?)? log, Duration interval = const Duration(milliseconds: 250)}) async {
  var done = 0;
  for (final ch in code.split('')) {
    final p = await _rectInner(tab, 'window.__EzMiGeek__.keyRect(${jsonEncode(ch)})');
    if (p == null) {
      log?.call('  × 找不到键位 $ch 的坐标');
      break;
    }
    final x = p['x']!, y = p['y']!;
    var ok = true;
    for (final ev in [
      {'type': 'mouseMoved', 'x': x, 'y': y, 'button': 'none'},
      {'type': 'mousePressed', 'x': x, 'y': y, 'button': 'left', 'buttons': 1, 'clickCount': 1},
      {'type': 'mouseReleased', 'x': x, 'y': y, 'button': 'left', 'buttons': 0, 'clickCount': 1},
    ]) {
      final r = await tab.cmd('Input.dispatchMouseEvent', params: ev);
      if (r['error'] != null) {
        // 通道断了（浏览器被关了）：再点下去也没有意义，立刻收手。
        ok = false;
        break;
      }
      if (ev['type'] == 'mouseMoved') continue;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (!ok) break;
    done += 1;
    if (interval > Duration.zero) {
      await Future<void>.delayed(interval);
    }
  }
  return done;
}

/// 断连界面的 <input class="pin-code-input">：聚焦后插入文本（真输入，不是赋值）。
Future<bool> typeIntoInput(CdpTab tab, String code, {void Function(Object?)? log}) async {
  final focused = await tab.js('window.__EzMiGeek__.focusInput()');
  if (focused == true) {
    final r = await tab.cmd('Input.insertText', params: {'text': code});
    return r['error'] == null;
  }
  log?.call('  聚焦失败，改用 React 原生 setter 兜底');
  final v = await tab.js('window.__EzMiGeek__.setInputValueByApi(${jsonEncode(code)})');
  return v == true;
}

/// 按界面种类填码。pin-code-input 走输入框，pin-number 键盘走真鼠标点击。
Future<bool> fillCode(CdpTab tab, String code, String kind,
    {void Function(Object?)? log}) async {
  if (kind == 'input.pin-code-input') {
    return typeIntoInput(tab, code, log: log);
  }
  final n = await clickKeys(tab, code, log: log);
  return n == code.length;
}
