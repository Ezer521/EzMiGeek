// tray_service.dart —— 托盘图标 + 右键菜单 + 单/双击路由。
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:system_tray/system_tray.dart';

import '../core/i18n.dart';

class TrayService {
  final SystemTray _tray = SystemTray();
  Timer? _macClickTimer;

  void Function()? onShowPanel;
  void Function()? onDoubleClick;
  void Function()? onOpenGeek;
  void Function()? onStopBrowser;
  void Function()? onLogs;
  void Function()? onLegal;
  void Function()? onCheckUpdate;
  void Function()? onQuit;

  Future<void> init({required String iconPath, required String tooltip}) async {
    await _tray.initSystemTray(iconPath: iconPath, toolTip: tooltip);
    await rebuildMenu();
    _tray.registerSystemTrayEventHandler(_handleTrayEvent);
  }

  void _handleTrayEvent(String eventName) {
    if (eventName == kSystemTrayEventClick) {
      if (Platform.isMacOS) {
        // system_tray 2.x 在 macOS 原生侧仅派发 click / right-click，不派发 double-click；
        // 用短窗合并判定双击，使「双击托盘图标打开网页」在 macOS 上同样生效。
        if (_macClickTimer?.isActive ?? false) {
          _macClickTimer!.cancel();
          _macClickTimer = null;
          onDoubleClick?.call();
          return;
        }
        _macClickTimer = Timer(const Duration(milliseconds: 280), () {
          _macClickTimer = null;
          onShowPanel?.call();
        });
        return;
      }
      onShowPanel?.call();
    } else if (eventName == kSystemTrayEventDoubleClick) {
      onDoubleClick?.call();
    } else if (eventName == kSystemTrayEventRightClick) {
      _macClickTimer?.cancel();
      _macClickTimer = null;
      _tray.popUpContextMenu();
    }
  }

  Future<void> rebuildMenu() async {
    final menu = Menu();
    await menu.buildFrom([
      MenuItemLabel(label: t('menu.panel'), onClicked: (_) => onShowPanel?.call()),
      MenuItemLabel(label: t('menu.open'), onClicked: (_) => onOpenGeek?.call()),
      MenuItemLabel(label: t('menu.stop'), onClicked: (_) => onStopBrowser?.call()),
      MenuSeparator(),
      MenuItemLabel(label: t('menu.logs'), onClicked: (_) => onLogs?.call()),
      MenuItemLabel(label: t('menu.legal'), onClicked: (_) => onLegal?.call()),
      MenuItemLabel(
        label: t('menu.update'),
        onClicked: (_) => onCheckUpdate?.call(),
      ),
      MenuSeparator(),
      MenuItemLabel(label: t('menu.quit'), onClicked: (_) => onQuit?.call()),
    ]);
    await _tray.setContextMenu(menu);
  }

  Future<void> setToolTip(String text) async {
    try {
      await _tray.setToolTip(text);
    } catch (_) {}
  }

  Future<void> dispose() async {
    _macClickTimer?.cancel();
    _macClickTimer = null;
    try {
      await _tray.destroy();
    } catch (_) {}
  }
}
