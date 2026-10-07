// main.dart —— EzMiGeek（Flutter 版）入口。
//
//   双击            → 正常开窗；已有实例在跑则本进程退出（.agent.lock 同款）
//   --lang zh|en    → 锁语言（出图 / 自检用）
//   --ui-png <path> → 离屏出图（窗口摆到设计分辨率 1043×1586），出完即退
//
// 与 Python 版共用：%LOCALAPPDATA%\EzMiGeek\ 下全部数据（config.json 凭据
// DPAPI 同熵、settings.json、stats.json、.agent.lock、浏览器 profile、日志）。
library;

import 'dart:io';
import 'dart:ui' as ui show ImageByteFormat;

import 'package:flutter/material.dart' show Colors;
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'core/app_dirs.dart';
import 'core/i18n.dart';
import 'services/app_log.dart';
import 'services/dialogs.dart';
import 'services/legal.dart';
import 'services/single_instance.dart';
import 'services/tray_service.dart';
import 'state/app_state.dart';
import 'ui/window_fit.dart';
import 'ui/ezshell.dart' show EzLogo, EzShellPainter;

const String kVersion = '1.0.0';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // --lang zh|en：只给自检 / 出图锁语言用（压过磁盘设置里的 LangZh）。
  String? forcedLang;
  for (var i = 0; i < args.length - 1; i++) {
    if (args[i] == '--lang') {
      final want = args[i + 1].trim().toLowerCase();
      forcedLang = (want == 'zh' || want == 'cn' || want == 'chinese')
          ? 'zh'
          : 'en';
    }
  }

  // ── --ui-png：出图模式 —— 不抢单实例、不弹免责声明、不上托盘，
  //    窗口摆到设计分辨率，截完边界即退。
  final pngIdx = args.indexOf('--ui-png');
  final uiPng = pngIdx >= 0 && pngIdx + 1 < args.length;

  // ── 单实例：已有实例在跑 → 记日志退出（Python 版 rc=2 同款）。
  SingleInstance? singleton;
  if (!uiPng) {
    singleton = SingleInstance.tryBecomeOwner();
    if (singleton == null) {
      AppLog.write('已有实例在跑，退出。');
      exit(2);
    }
  }

  // 头部 logo（真实应用图标）先解码好再进 UI。
  await EzLogo.load();

  final state = AppState();
  state.loadSettingsAtStartup(); // 读设置 + 应用语言 + 注册表对齐自启 + 统计
  if (forcedLang != null) {
    Lang.set(forcedLang);
    state.settings.langZh = forcedLang == 'zh';
    state.sync();
  }

  // ── 首次运行：免责声明确认（出图模式跳过）。用户点「取消」就退出。
  if (!uiPng && !File(disclaimerAck()).existsSync()) {
    final ok = confirmDisclaimer(legalAckText());
    if (!ok) {
      AppLog.write('首次运行的免责声明没有确认，退出。');
      exit(0);
    }
    try {
      File(disclaimerAck()).writeAsStringSync(
        'ack ${DateTime.now().toIso8601String()}',
        flush: true,
      );
    } catch (e) {
      AppLog.write('免责声明确认标记写不进去：$e');
    }
  }

  // ── 窗口：隐藏标题栏（三钮画在壳内），尺寸按工作区等比适配 ──
  // ★ 粗调 + 客户区贴合（window_fit）：setSize 设的是外框，隐形调整边框会压坏
  //   客户区比例 → 玻璃下缘露底衬带（EzAway 同款修法，四家族统一）。
  await windowManager.ensureInitialized();
  final windowOptions = WindowOptions(
    size: initialClientRect(),
    minimumSize: const Size(1043 * 0.42, 1586 * 0.42),
    center: true,
    title:
        'EzMiGeek · ${Lang.zh ? '米家自动化极客版自动登录助手' : 'Mi Geek auto sign-in helper'}',
    titleBarStyle: TitleBarStyle.hidden,
    backgroundColor: Colors.transparent,
  );
  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });
  final fitNote = await applyWindowFit();
  AppLog.write('窗口贴合：$fitNote');
  // 正式模式拦 ✕：关窗一律收托盘（程序继续待命），彻底退出走托盘菜单。
  if (!uiPng) await windowManager.setPreventClose(true);

  // ── 业务回调 + 托盘 ──
  final tray = TrayService();

  Future<void> hideToTray() async {
    AppLog.write('面板「收起到托盘」。');
    await windowManager.hide();
  }

  Future<void> exitApp() async {
    await state.quit();
    if (!uiPng) await tray.dispose();
    singleton?.dispose();
    AppLog.close();
    AppLog.write('程序退出，托盘已清理（本轮浏览器按原版约定保留）。');
    await windowManager.destroy();
  }

  state
    ..onHideToTray = hideToTray
    ..onQuit = exitApp;

  if (!uiPng) {
    try {
      const trayAsset = 'assets/app.ico';
      const trayName = 'tray.ico';
      final iconBytes = await rootBundle.load(trayAsset);
      final iconFile = File('${dataDir()}/$trayName');
      await iconFile.writeAsBytes(iconBytes.buffer.asUint8List(), flush: true);
      tray.onShowPanel = () async {
        await windowManager.show();
        await windowManager.focus();
      };
      tray.onOpenGeek = () => state.onOpenGeekClicked();
      tray.onStopBrowser = () => state.stopBrowser();
      tray.onLogs = () => state.openLogsFolder();
      tray.onLegal = () => state.showLegal();
      tray.onQuit = exitApp;
      await tray.init(iconPath: iconFile.path, tooltip: t('app.name'));
    } catch (e) {
      AppLog.write('托盘初始化失败：$e');
    }
    // 切语言时托盘菜单跟着重建（字表即菜单）。
    state.addListener(() {
      if (state.ui.langZh != Lang.zh) return; // 只在真的翻面时动
      tray.rebuildMenu();
      tray.setToolTip(t('app.name'));
    });
  }

  AppLog.write(
    'EzMiGeek (Flutter) v$kVersion 启动'
    '${uiPng ? ' ［--ui-png 出图模式：不抢单实例、不上托盘］' : ''}',
  );

  if (uiPng) {
    final outPath = args[pngIdx + 1];
    await windowManager.setSize(const Size(1043, 1586));
    EzShellPainter.fitWhole = true; // 屏幕放不下整幅时按高度缩放，出图可核对全布局
    final key = GlobalKey();
    runApp(EzMiGeekApp(state: state, captureKey: key));
    // 等两帧 + 一拍，保证首帧栅格化完成再抓边界。15 秒兜底退出（防卡死）。
    var tries = 0;
    Future<void> grab() async {
      tries++;
      if (tries > 150) {
        AppLog.write('--ui-png 超时未出图（150 次尝试）');
        exit(2);
      }
      try {
        final ctx = key.currentContext;
        if (ctx == null) throw StateError('boundary 尚未挂载');
        final boundary = ctx.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1.0);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        if (data == null) throw StateError('PNG 编码返回空');
        File(outPath).writeAsBytesSync(data.buffer.asUint8List(), flush: true);
        AppLog.write('--ui-png 已出图：$outPath');
        exit(0);
      } catch (e) {
        if (tries <= 3) AppLog.write('--ui-png 第 $tries 次尝试失败：$e');
        await Future<void>.delayed(const Duration(milliseconds: 100));
        return grab();
      }
    }

    Future<void>.delayed(const Duration(milliseconds: 1200), grab);
    return;
  }

  runApp(EzMiGeekApp(state: state));
}
