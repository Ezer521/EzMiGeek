// main.dart —— EzMiGeek（Flutter 版）入口。
//
//   双击            → 正常开窗；已有实例在跑则唤醒已有实例置前并退出
//   --lang zh|en    → 锁语言（出图 / 自检用）
//   --hub <ip>      → 手动指定极客版中枢 IP（优先级高于 settings.json 的 HubIp）
//   --ui-png <path> → 离屏出图（窗口摆到设计分辨率 1043×1586），出完即退
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui show ImageByteFormat, PlatformDispatcher;

import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'core/app_dirs.dart';
import 'core/i18n.dart';
import 'native/resize_lock.dart';
import 'native/win32.dart' show signalRunningInstance;
import 'services/app_log.dart';
import 'services/code_service.dart';
import 'services/dialogs.dart';
import 'services/legal.dart';
import 'services/single_instance.dart';
import 'services/tray_service.dart';
import 'services/update_checker.dart';
import 'state/app_state.dart';
import 'ui/ezshell.dart' show EzLogo, EzShellPainter;
import 'ui/window_fit.dart';

/// 应用版本号（可通过构建参数 `--dart-define=APP_VERSION=x.y.z` 覆盖，保持单一真相源）。
const String kVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: '3.1.0',
);

/// --hub 命令行参数的落点（main 里灌进 state.hubOverride）。
String hubArg = '';

void _installCrashHandlers() {
  FlutterError.onError = (FlutterErrorDetails details) {
    AppLog.writeCrash(
      details.exception,
      details.stack ?? StackTrace.current,
    );
  };
  ui.PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    AppLog.writeCrash(error, stack);
    return true;
  };
}

Future<void> main(List<String> args) async {
  runZonedGuarded(
    () => _boot(args),
    (Object error, StackTrace stack) {
      AppLog.writeCrash(error, stack);
    },
  );
}

Future<void> _boot(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  _installCrashHandlers();

  String? forcedLang;
  for (var i = 0; i < args.length - 1; i++) {
    if (args[i] == '--lang') {
      final want = args[i + 1].trim().toLowerCase();
      forcedLang = (want == 'zh' || want == 'cn' || want == 'chinese')
          ? 'zh'
          : 'en';
    }
  }

  for (var i = 0; i < args.length - 1; i++) {
    if (args[i] == '--hub') {
      hubArg = args[i + 1].trim();
    }
  }

  final pngIdx = args.indexOf('--ui-png');
  final uiPng = pngIdx >= 0 && pngIdx + 1 < args.length;

  // ── 单实例：已有实例在跑 → 唤醒已有实例弹到前台后本进程退出 ──
  SingleInstance? singleton;
  if (!uiPng) {
    singleton = SingleInstance.tryBecomeOwner();
    if (singleton == null) {
      final woken = signalRunningInstance();
      AppLog.write(
        woken ? '已有实例在跑，已发送唤起信号并退出。' : '已有实例在跑，退出。',
      );
      exit(woken ? 0 : 2);
    }
  }

  // ── 首次运行：免责声明确认（必须在任何联网/局域网探测之前）──
  if (!uiPng && !File(disclaimerAck()).existsSync()) {
    final ok = confirmDisclaimer(legalAckText());
    if (!ok) {
      AppLog.write('首次运行的免责声明没有确认，退出。');
      singleton?.dispose();
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

  await EzLogo.load();

  final state = AppState();
  state.hubOverride = hubArg;
  state.loadSettingsAtStartup();
  if (forcedLang != null) {
    Lang.set(forcedLang);
    state.settings.langZh = forcedLang == 'zh';
    state.sync();
  }

  if (uiPng) {
    state.settings.autoTrayDone = true;
    state.settings.autoStart = true;
    state.sync();
  }

  await windowManager.ensureInitialized();
  final minW = Platform.isWindows ? 1043 * 0.42 : 1043 * 0.35;
  final minH = Platform.isWindows ? 1586 * 0.42 : 1586 * 0.35;
  final windowOptions = WindowOptions(
    size: initialClientRect(),
    minimumSize: Size(minW, minH),
    center: true,
    title:
        'EzMiGeek · ${Lang.zh ? '米家自动化极客版自动登录助手' : 'Mi Geek auto sign-in helper'}',
    titleBarStyle: TitleBarStyle.hidden,
    windowButtonVisibility: Platform.isWindows ? null : false,
    backgroundColor: const Color(0x00000000),
  );
  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  Future<void> showAndFocusPanel() async {
    if (await windowManager.isMinimized()) {
      await windowManager.restore();
    }
    await windowManager.show();
    await windowManager.focus();
  }

  if (Platform.isWindows) {
    ResizeRatioLock.onActivate = () {
      AppLog.write('收到第二实例唤醒信号 → 弹出并置前主面板。');
      unawaited(showAndFocusPanel());
    };
  }

  final fitNote = await applyWindowFit();
  AppLog.write('窗口贴合：$fitNote');
  if (!uiPng) await windowManager.setPreventClose(true);

  final tray = TrayService();

  // ── 可选本地取码服务（仅 127.0.0.1，可通过 settings.json LocalCodeService=false 关闭）──
  final codeService = CodeService(
    version: kVersion,
    credsProvider: () => state.memCreds,
  );
  if (!uiPng && state.settings.localCodeService) {
    await codeService.start();
  } else if (!uiPng) {
    AppLog.write('取码服务：已按 settings.json（LocalCodeService=false）关闭。');
  }

  Future<void> hideToTray() async {
    AppLog.write('面板「收起到托盘」。');
    await windowManager.hide();
  }

  Future<void> exitApp() async {
    await state.quit();
    if (!uiPng) {
      await codeService.stop();
      await tray.dispose();
    }
    singleton?.dispose();
    AppLog.write('程序退出，托盘与本地服务已清理（本轮浏览器按约定保留）。');
    AppLog.close();
    await windowManager.destroy();
  }

  state.onShowPanel = () => unawaited(showAndFocusPanel());
  state.onHideToTray = hideToTray;
  state.onQuit = exitApp;

  if (!uiPng) {
    try {
      // 托盘图标：
      //   · Windows：把 assets/app.ico 写到数据目录后传磁盘路径；
      //   · macOS：system_tray 底层调用 rootBundle.load(iconPath)，必须传 Flutter asset key。
      final String trayIconPath;
      if (Platform.isWindows) {
        final iconBytes = await rootBundle.load('assets/app.ico');
        final iconFile = File(pJoin(dataDir(), 'tray.ico'));
        await iconFile.writeAsBytes(iconBytes.buffer.asUint8List(), flush: true);
        trayIconPath = iconFile.path;
      } else {
        trayIconPath = 'assets/logo.png';
      }
      tray.onShowPanel = () => unawaited(showAndFocusPanel());
      tray.onDoubleClick = () => unawaited(state.onTrayDoubleClicked());
      tray.onOpenGeek = () => unawaited(state.onOpenGeekClicked());
      tray.onStopBrowser = () => unawaited(state.stopBrowser());
      tray.onLogs = () => unawaited(state.openLogsFolder());
      tray.onLegal = () => unawaited(state.showLegal());
      tray.onCheckUpdate = () => unawaited(checkForUpdatesInteractive(kVersion));
      tray.onQuit = exitApp;
      await tray.init(iconPath: trayIconPath, tooltip: t('app.name'));
    } catch (e) {
      AppLog.write('托盘初始化失败：$e');
    }
    // 仅在语言真正切换时重建托盘菜单，避免每次状态刷新重复重建。
    var lastTrayLangZh = Lang.zh;
    state.addListener(() {
      if (Lang.zh == lastTrayLangZh) return;
      lastTrayLangZh = Lang.zh;
      unawaited(tray.rebuildMenu());
      unawaited(tray.setToolTip(t('app.name')));
    });
  }

  AppLog.write(
    'EzMiGeek (Flutter) v$kVersion 启动'
    '${uiPng ? ' ［--ui-png 出图模式：不抢单实例、不上托盘］' : ''}',
  );

  if (uiPng) {
    final outPath = args[pngIdx + 1];
    await windowManager.setSize(const Size(1043, 1586));
    EzShellPainter.fitWhole = true;
    final key = GlobalKey();
    runApp(EzMiGeekApp(state: state, captureKey: key));
    var tries = 0;
    Future<void> grab() async {
      tries++;
      if (tries > 150) {
        AppLog.write('--ui-png 超时未出图（150 次尝试）');
        exit(2);
      }
      try {
        if (!state.codeSettled) throw StateError('登录码还没取到，再等一拍');
        await WidgetsBinding.instance.endOfFrame;
        final ro = key.currentContext?.findRenderObject();
        if (ro is! RenderRepaintBoundary) throw StateError('boundary 尚未挂载');
        final density = (2086 / ro.size.width).clamp(1.0, 3.0);
        final image = await ro.toImage(pixelRatio: density);
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
