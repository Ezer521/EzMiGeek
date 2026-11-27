// app.dart —— 应用壳：无 Material 装饰的纯玻璃画布 + 关窗拦截。
library;

import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

import 'state/app_state.dart';
import 'ui/main_page.dart';

/// 从 BuildContext 里拿 AppState 的轻量注册表。
class AppStateScope extends InheritedWidget {
  const AppStateScope({super.key, required this.state, required super.child});

  final AppState state;

  static AppState? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppStateScope>()?.state;

  @override
  bool updateShouldNotify(AppStateScope oldWidget) => false;
}

class EzMiGeekApp extends StatefulWidget {
  const EzMiGeekApp({super.key, required this.state, this.captureKey});

  final AppState state;

  /// --ui-png 出图边界（离屏渲染整窗画面）。
  final GlobalKey? captureKey;

  @override
  State<EzMiGeekApp> createState() => _EzMiGeekAppState();
}

class _EzMiGeekAppState extends State<EzMiGeekApp> with WindowListener {
  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowClose() async {
    // 原版行为：关窗一律收托盘（程序继续在托盘待命），彻底退出走托盘菜单。
    widget.state.onHideToTray?.call();
  }

  @override
  void onWindowFocus() {
    widget.state.setWindowFocused(true);
  }

  @override
  void onWindowBlur() {
    widget.state.setWindowFocused(false);
  }

  @override
  Widget build(BuildContext context) {
    return WidgetsApp(
      debugShowCheckedModeBanner: false,
      color: const Color(0xFF1A7AF5),
      textStyle: TextStyle(
        fontFamily: Platform.isWindows ? 'Microsoft YaHei UI' : 'PingFang SC',
      ),
      pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) =>
          PageRouteBuilder<T>(
            settings: settings,
            pageBuilder: (context, animation, secondaryAnimation) =>
                builder(context),
          ),
      builder: (context, child) {
        // 固定画布版式：屏蔽系统文字缩放，避免可访问性缩放破坏像素级对位。
        return MediaQuery.withClampedTextScaling(maxScaleFactor: 1.0, child: child!);
      },
      home: RepaintBoundary(
        key: widget.captureKey,
        child: AppStateScope(
          state: widget.state,
          child: MainPage(state: widget.state),
        ),
      ),
    );
  }
}
