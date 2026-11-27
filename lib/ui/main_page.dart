// main_page.dart —— 主页面：窗口 = 玻璃外壳（1043×1586 设计画布）。
library;

import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../state/app_state.dart';
import 'ezshell.dart' show EzShell, windowClose, windowMaxToggle, windowMin;
import 'window_fit.dart' show resetWindowSize;

class MainPage extends StatefulWidget {
  const MainPage({super.key, required this.state});

  final AppState state;

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  @override
  void initState() {
    super.initState();
    windowMin = windowManager.minimize;
    // 窗口已锁定最佳等比上限，中钮作为「复位到最佳贴合尺寸」使用。
    windowMaxToggle = resetWindowSize;
    // macOS 隐藏系统关闭按钮后，performClose(nil) 会被 AppKit 拦截失效；
    // 直接路由到收起托盘回调，确保点击红灯稳定收起并记录日志。
    windowClose = Platform.isWindows
        ? windowManager.close
        : () {
            final hide = widget.state.onHideToTray;
            if (hide != null) {
              hide();
            } else {
              windowManager.hide();
            }
          };
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) => EzShell(state: widget.state),
    );
  }
}
