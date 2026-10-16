// main_page.dart —— 主页面：窗口 = 玻璃外壳（1043×1586 设计画布，逐值移植）。
// 交互走 Hit 同款命中表；拖拽/三钮/悬停与原版一致；
// 背景为假毛玻璃（烤进窗口的极光，替代真实桌面透视）。
library;

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../state/app_state.dart';
import 'ezshell.dart' show EzShell, windowClose, windowMaxToggle, windowMin;

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
    windowMaxToggle = () async {
      if (await windowManager.isMaximized()) {
        await windowManager.unmaximize();
      } else {
        await windowManager.maximize();
      }
    };
    windowClose = windowManager.close;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) => EzShell(state: widget.state),
    );
  }
}
