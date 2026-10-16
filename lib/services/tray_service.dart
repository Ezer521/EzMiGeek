// tray_service.dart —— 托盘图标 + 右键菜单（system_tray 承载，app/tray.py 同款路由）。
library;

import 'package:system_tray/system_tray.dart';

import '../core/i18n.dart';

class TrayService {
  final SystemTray _tray = SystemTray();

  void Function()? onShowPanel;
  void Function()? onOpenGeek;
  void Function()? onStopBrowser;
  void Function()? onLogs;
  void Function()? onLegal;
  void Function()? onQuit;

  Future<void> init({required String iconPath, required String tooltip}) async {
    await _tray.initSystemTray(iconPath: iconPath, toolTip: tooltip);
    await rebuildMenu();
    _tray.registerSystemTrayEventHandler((eventName) {
      if (eventName == 'click') onShowPanel?.call();
      if (eventName == 'right-click') _tray.popUpContextMenu();
    });
  }

  Future<void> rebuildMenu() async {
    final menu = Menu();
    menu.buildFrom([
      MenuItemLabel(label: t('menu.panel'), onClicked: (_) => onShowPanel?.call()),
      MenuItemLabel(label: t('menu.open'), onClicked: (_) => onOpenGeek?.call()),
      MenuItemLabel(label: t('menu.stop'), onClicked: (_) => onStopBrowser?.call()),
      MenuSeparator(),
      MenuItemLabel(label: t('menu.logs'), onClicked: (_) => onLogs?.call()),
      MenuItemLabel(label: t('menu.legal'), onClicked: (_) => onLegal?.call()),
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
    try {
      await _tray.destroy();
    } catch (_) {}
  }
}
