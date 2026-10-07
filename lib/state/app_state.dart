// app_state.dart —— 状态宿主（app/panel.py fill_state + __main__.Resident 合并移植）。
//
// 职责与原版一致：
//   1. 状态翻译：把「跑到哪一步/出错/设置项」翻成 UI 字段；
//      界面上所有文字都从 i18n 字表出，状态存 (key, args) 切语言重算；
//   2. 事件路由：hit → 业务回调（极客开启/托盘/说明/日志/语言/设置/重登）；
//   3. 一轮生命周期：kick → round（中枢→浏览器→CDP→取码→填码→监控）→ rc 报告。
//
// Flutter 侧与 Python 版的差异：worker 线程的「threading.Thread + 消息泵投递」
// 换成「async/await + ChangeNotifier」——都是单 UI 线程渲染、I/O 在异步通道上。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../browser/browser_ctl.dart';
import '../cdp/cdp.dart';
import '../cdp/filler.dart';
import '../core/app_dirs.dart';
import '../core/i18n.dart';
import '../mijia/hub_discovery.dart';
import '../mijia/mijia_cloud.dart' show cancelCloudRequests;
import '../mijia/passcode.dart';
import '../mijia/stale.dart';
import '../model/settings.dart';
import '../model/stats_store.dart';
import '../services/agent_js.dart';
import '../services/app_log.dart';
import '../services/autostart.dart';

import '../services/dialogs.dart';
import '../services/legal.dart';

// ── UI 渲染字段（UiState 同款，渲染层只读）──
class UiFields {
  String headerSub = '';
  String status = ''; // 胶囊 + 状态卡大标题（同一句）
  String dotColor = 'dot'; // dot / amber / warn
  String c1Sub = '';
  String c1Hint = '';
  String labL = '', labR = '';
  String numL = '', numR = '';
  String bottomLine = '';
  bool warn = false;
  String mainLabel = '';
  bool canAct = true;
  String secTitle = '';
  String infoLine = '';
  // 设置卡 5 行
  final List<String> rowT = List.filled(5, '');
  final List<String> rowS = List.filled(5, '');
  final List<bool> rowOn = List.filled(5, false);
  String row5Btn = '';
  bool row5Act = true;
  String btnTray = '', btnDoc = '', btnLog = '';
  String foot1 = '', foot2 = '';
  bool langZh = true;
}

class StatusDesc {
  StatusDesc(this.key, [this.args = const []]);
  final String key;
  final List<Object?> args;
}

class AppState extends ChangeNotifier {
  final UiFields ui = UiFields();
  AppSettings settings = AppSettings();
  Stats stats = Stats();
  bool langZh = true;

  // 状态描述（字表 key + 实参），切语言重算。
  StatusDesc? _status;
  StatusDesc? _bottom;
  StatusDesc? _info;
  bool _warn = false;
  bool _busy = false;
  bool get busy => _busy;

  // 一轮生命周期
  Launched? currentLaunched;
  bool _roundRunning = false;
  bool _autoRetried = false; // 浏览器意外退出后的自动重试（每次 kick 重置）
  bool _quitting = false;
  bool get quitting => _quitting;

  // 连续失败转人工后的暂停闸：true = 不再自动取码填码，
  // 等用户在网页里手动输码（界面消失自动恢复）或点「极客开启」恢复。
  // ★ 只是提示「转人工」却继续自动取码填码，等于没转（审查 2026-10-06）。
  bool _pausedForManual = false;
  int _failStreak = 0;

  // 写盘失败时的内存凭据兜底：登录本身成功、但没存上盘。本会话内取码
  // 优先用它，不再碰磁盘上的旧凭据；重启即失效，界面会写明（审查二轮）。
  Map<String, Object?>? memCreds;

  // 重新登录防重入
  bool _relogining = false;

  // 中枢覆盖（--hub 参数，出厂空）
  String hubOverride = '';

  // ── 回调（宿主注入）──
  void Function()? onShowPanel; // 托盘单击/菜单「显示面板」
  void Function()? onHideToTray; // 「收到托盘」按钮
  void Function()? onOpenManual; // 「使用说明」
  void Function()? onOpenLogs; // 「查看日志」
  void Function()? onShowLegal; // 「免责声明」
  Future<void> Function()? onQuit; // 托盘「退出」

  // ── 状态描述展开（_say 同款）──
  String _say(StatusDesc? d) => d == null ? '' : t(d.key, d.args);

  // ════════════════════════ 状态同步（fill_state 移植）══════════════════
  void _fillState() {
    final u = ui;
    u.langZh = Lang.zh;
    u.headerSub = t('app.name');
    u.status = _say(_status).isEmpty ? t('app.starting') : _say(_status);
    u.dotColor = _busy ? 'amber' : (_warn ? 'warn' : 'dot');

    u.c1Hint = t('c1.hint');
    u.labL = t('lab.total');
    u.labR = t('lab.today');
    u.numL = '${stats.total}';
    u.numR = '${stats.today}';
    final lastAt = stats.lastAtDateTime;
    if (lastAt != null) {
      final isToday = _isToday(lastAt);
      u.c1Sub = stats.lastSecs >= 1
          ? t('sub.last.dur', [
              Lang.fmtTime(lastAt, isToday),
              stats.lastSecs.round(),
            ])
          : t('sub.last', [Lang.fmtTime(lastAt, isToday)]);
    } else {
      u.c1Sub = t('sub.never');
    }
    u.bottomLine = _say(_bottom).isEmpty ? t('bottom.idle') : _say(_bottom);
    u.warn = _warn;

    u.mainLabel = t('btn.main');
    u.canAct = !_busy;
    u.secTitle = t('sec.general');
    u.infoLine = _say(_info).isEmpty ? t('info.idle') : _say(_info);

    u.btnTray = t('btn.tray');
    u.btnDoc = t('btn.doc');
    u.btnLog = t('btn.log');
    u.foot1 = t('app.foot');
    u.foot2 = t('app.data_dir', [dataDir()]);
  }

  /// 设置卡 5 行的字段填入（与 `panel.fill_state` 的行序/字段映射完全一致）。
  void _fillSettingsRows() {
    final u = ui;
    // 行 0：开机自动启动（副标题报注册表真值）
    u.rowT[0] = t('row.autostart');
    u.rowS[0] = autostartSubtitle();
    u.rowOn[0] = settings.autoStart;
    // 行 1：登录成功后收进托盘
    u.rowT[1] = t('row.traydone');
    u.rowS[1] = t('row.traydone.sub');
    u.rowOn[1] = settings.autoTrayDone;
    // 行 2：双击托盘图标打开网页
    u.rowT[2] = t('row.dblopen');
    u.rowS[2] = t('row.dblopen.sub');
    u.rowOn[2] = settings.autoDblOpenWeb;
    // 行 3：打开网页时全屏
    u.rowT[3] = t('row.fullscreen');
    u.rowS[3] = t('row.fullscreen.sub');
    u.rowOn[3] = settings.autoFullscreen;
    // 行 4：★ 重新登录小米账号（动作行）
    u.rowT[4] = t('row.relogin');
    u.rowS[4] = t('row.relogin.sub');
    u.rowOn[4] = false; // 动作行没有拨杆（右上是按钮，不是开关）
    u.row5Btn = t('row.relogin.btn');
    u.row5Act = !_relogining && !_busy;
  }

  static bool _isToday(DateTime d) {
    final n = DateTime.now();
    return n.year == d.year && n.month == d.month && n.day == d.day;
  }

  /// 全量重算 + 通知 UI（sync 同款）。
  void sync() {
    _fillState();
    _fillSettingsRows();
    notifyListeners();
  }

  // ══════════════════ 状态设置（set_status 移植）══════════════════
  void setStatus(
    String key, {
    List<Object?> args = const [],
    String? bottomKey,
    List<Object?> bottomArgs = const [],
    bool? warnFlag,
    bool? busyFlag,
  }) {
    _status = StatusDesc(key, args);
    if (bottomKey != null) _bottom = StatusDesc(bottomKey, bottomArgs);
    if (warnFlag != null) _warn = warnFlag;
    if (busyFlag != null) _busy = busyFlag;
    sync();
  }

  void setInfo(String key, [List<Object?> args = const []]) {
    _info = StatusDesc(key, args);
    sync();
  }

  void clearInfo() {
    _info = null;
    sync();
  }

  void setBusy(bool b) {
    _busy = b;
    sync();
  }

  // ════════════════════════ 设置卡拨动（拨动即存）══════════════════════
  void toggleRow(int row) {
    switch (row) {
      case 0:
        settings.autoStart = !settings.autoStart;
      case 1:
        settings.autoTrayDone = !settings.autoTrayDone;
      case 2:
        settings.autoDblOpenWeb = !settings.autoDblOpenWeb;
      case 3:
        settings.autoFullscreen = !settings.autoFullscreen;
      default:
        return; // 动作行没有拨杆
    }
    _saveSettingsAndSyncAutostart();
  }

  /// 拨动即存：落盘 + 自启写注册表 + 读回校验。失败钉在界面上。
  void _saveSettingsAndSyncAutostart() {
    try {
      if (!saveSettings(settings)) throw StateError('写盘失败');
    } catch (e) {
      _log('× 保存设置失败：$e');
      setInfo('info.savefail', ['$e']);
      sync();
      return;
    }
    // 开机自启：真相在注册表。写/删那一行并读回校验。
    try {
      final st = setEnabled(settings.autoStart);
      settings.autoStart = st.enabled;
      _log(
        '开机自启动 → ${settings.autoStart ? '开' : '关'}（${st.raw.isEmpty ? '无' : st.raw}）',
      );
    } catch (e) {
      _log('× 开机自启动没设成：$e');
      setInfo('info.savefail', ['$e']);
    }
    sync();
  }

  /// 启动时：把磁盘设置读回 + 以注册表真值对齐自启拨杆 + 应用语言 + 待命态。
  void loadSettingsAtStartup() {
    settings = loadSettings();
    Lang.set(settings.langZh ? 'zh' : 'en');
    // 注册表真值优先。
    final st = autostartState();
    settings.autoStart = st.enabled;
    stats = Stats.load();
    // 与 __main__.py 启动路径一致：面板亮出「待命」，不自动开网页。
    setStatus('st.ready', bottomKey: 'st.ready.bottom', warnFlag: false);
  }

  void toggleLang() {
    settings.langZh = !settings.langZh;
    Lang.set(settings.langZh ? 'zh' : 'en');
    saveSettings(settings);
    sync();
  }

  // ════════════════════════ 托盘/底部按钮路由 ═══════════════════════

  Future<void> onTrayClicked() async {
    _log('显示面板。');
    sync();
  }

  Future<void> onTrayDoubleClicked() async {
    // 设置门（AutoDblOpenWeb）关着就只把面板叫出来。
    if (!settings.autoDblOpenWeb) {
      _log('双击托盘：设置里关着「双击托盘图标打开网页」→ 只把面板叫出来。');
      sync();
      return;
    }
    await kick('托盘双击');
  }

  Future<void> onOpenGeekClicked() => kick('「极客开启」');

  Future<void> stopBrowser() async {
    if (_relogining) {
      _log('重新登录进行中，浏览器是登录流程自己的 → 不收。');
      return;
    }
    _log('请求关闭本轮浏览器。');
    final l = currentLaunched;
    if (l == null) return;
    _log('手动关闭本轮浏览器（pid=${l.proc.pid}）');
    l.stop();
  }

  Future<void> openLogsFolder() async {
    _log('打开日志文件夹。');
    try {
      await Process.run('explorer.exe', [logsDir()]);
    } catch (e) {
      _log('打开日志文件夹失败：$e');
    }
  }

  Future<void> openManual() async {
    _log('打开使用说明。');
    try {
      // ★ 手册落在数据目录 help\，**只在缺失时**才从资源解出——
      //   用户对它的编辑必须持久（旧版每次覆盖 TEMP 副本，编辑全被冲掉，
      //   2026-10-03 用户实锤）。想改随包原稿才去动 assets/使用说明.txt 并重打包。
      final f = File(pJoin(dataDir(), pJoin('help', 'EzMiGeek-使用说明.txt')));
      if (!f.existsSync()) {
        await f.parent.create(recursive: true);
        final data = await rootBundle.load('assets/使用说明.txt');
        await f.writeAsBytes(data.buffer.asUint8List(), flush: true);
      }
      final p = f.path;

      await Process.run('cmd', ['/c', 'start', '', p], runInShell: false);
    } catch (e) {
      _log('打开使用说明失败：$e');
    }
  }

  Future<void> showLegal() async {
    _log('显示免责声明全文。');
    showLegalFull('EzMiGeek · 免责声明', legalFull);
  }

  Future<void> quit() async {
    _quitting = true;
    // 卡在云接口上的请求立刻掐断（整体超时最长 45s，退出不该等它）。
    cancelCloudRequests();
    final l = currentLaunched;
    if (l != null) {
      _log('退出时不收浏览器（固定保留）→ pid=${l.proc.pid} 留着，程序先退。');
    } else {
      _log('请求退出：当前没有在跑的一轮，直接收。');
    }
    setStatus('st.quitting');
    _log('程序退出，钩子/浏览器/托盘已清理。');
  }

  // ════════════════════════ 一轮（kick → _round）══════════════════════

  /// 「极客开启」：唯一开网页入口。已在跑 → 把浏览器调到前台；
  /// 转人工暂停中 → 这一下就是「恢复自动」。
  Future<void> kick(String why) async {
    if (_relogining) {
      // 统一互斥：重登和一轮共用一个浏览器 profile，绝不能并行。
      _log('$why：重新登录还在进行 → 忽略这一次。');
      setStatus('st.busyrelogin', bottomKey: 'st.busyrelogin.bottom');
      return;
    }
    if (_roundRunning) {
      if (_pausedForManual) {
        _log('$why → 转人工暂停中，恢复自动填码。');
        _resumeAutoFill();
        final l = currentLaunched;
        if (l != null) {
          _log('本轮还在跑 → 把浏览器调到前台（pid=${l.proc.pid}）');
          await focusProcess(l.proc.pid);
        }
        return;
      }
      setStatus('st.busy_round');
      final l = currentLaunched;
      if (l != null) {
        _log('本轮还在跑 → 把浏览器调到前台（pid=${l.proc.pid}）');
        await focusProcess(l.proc.pid);
      }
      sync();
      return;
    }
    _roundRunning = true;
    _autoRetried = false; // 每次用户点「极客开启」重置自动补一轮的机会
    _log('$why → 起一轮。');
    setStatus('st.kick', bottomKey: 'st.kick.bottom', busyFlag: true);
    // worker 线程在 Dart 里 = async 函数（I/O 为主，不阻塞 UI 线程）
    unawaited(_roundWrapper());
  }

  Future<void> _roundWrapper() async {
    try {
      var rc = await _round();
      _log('本轮结束（rc=$rc）');
      if (_quitting) return;
      // ★ 分发机实测：个别机器浏览器会在导航到极客版后意外退出（exit=0）。
      //   自动补一轮（每次「极客开启」只自动补一次，绝不静默死循环）。
      if (rc == 5 && !_autoRetried) {
        _autoRetried = true;
        _log('浏览器意外退出 → 自动再起一轮。');
        rc = await _round();
        _log('重试结束（rc=$rc）');
      }
      if (_quitting) return;
      _reportRound(rc);
    } catch (e) {
      _log('× 本轮异常：$e');
      if (!_quitting) {
        setStatus(
          'st.error',
          args: [e],
          bottomKey: 'st.error.bottom',
          warnFlag: true,
        );
      }
    } finally {
      setBusy(false);
      _roundRunning = false;
      _pausedForManual = false; // 暂停态不跨轮：下一轮从「自动」起步
    }
  }

  void _enterManualPause() {
    _pausedForManual = true;
    _log('暂停自动填码（转人工）：点「极客开启」可恢复，手动登录成功也会自动恢复。');
    setStatus(
      'st.paused',
      bottomKey: 'st.paused.bottom',
      warnFlag: true,
      busyFlag: false,
    );
  }

  void _resumeAutoFill() {
    _pausedForManual = false;
    _failStreak = 0;
    setStatus(
      'st.resumed',
      bottomKey: 'st.resumed.bottom',
      warnFlag: false,
      busyFlag: false,
    );
  }

  void _reportRound(int rc) {
    final (stKey, btKey, warnFlag, _) = switch (rc) {
      0 => ('rc.0.status', 'rc.0.bottom', false, ''),
      3 => ('rc.3.status', 'rc.3.bottom', false, ''),
      5 => ('rc.5.status', 'rc.5.bottom', false, ''),
      6 => ('rc.6.status', 'rc.6.bottom', false, ''),
      8 => ('rc.8.status', 'rc.8.bottom', true, ''),
      1 => ('rc.1.status', 'rc.1.bottom', true, ''),
      4 => ('rc.4.status', 'rc.4.bottom', true, ''),
      _ => ('rc.x.status', 'rc.x.bottom', true, ''),
    };
    setStatus(stKey, bottomKey: btKey, warnFlag: warnFlag);
  }

  // ════════════════════════ 一轮主流程（run 移植）══════════════════════

  Future<int> _round() async {
    // 1) 中枢
    final (hubIp, hubWhy) = hubOverride.isNotEmpty
        ? (hubOverride, '命令行指定')
        : await discover();
    final url = 'http://$hubIp:8086/';
    _log('中枢 $hubIp（$hubWhy） → $url');

    // 2) 浏览器（系统默认）
    final (exe0, extra) = defaultBrowser();
    if (exe0 != null && !isChromiumExe(exe0)) {
      _log('默认浏览器 $exe0（非 Chromium 系，走降级轮）');
      return _manualRound(hubIp, url, exe0, extra);
    }
    String exe = exe0 ?? '';
    if (exe.isEmpty) {
      _log('解析不出系统默认浏览器，退回老找法');
      exe = findBrowser() ?? '';
      if (exe.isEmpty) {
        _log('× 找不到任何可用的浏览器');
        return 1;
      }
    }
    final profile = profileDir();
    final killed = killStale(profile);
    if (killed != 0) {
      _log('清掉上次残留的浏览器实例（pid=$killed）');
    }

    Launched? launched;
    CdpTab? tab;
    Map<String, Object?>? roundCreds; // 首登刚拿到的内存凭据（写盘失败时本轮兜底用）
    try {
      // 设置卡第 5 行「打开网页时全屏」在这里生效
      launched = await launchBrowser(
        exe,
        profile,
        fullscreen: settings.autoFullscreen,
      );
      currentLaunched = launched; // 托盘「关闭本轮浏览器」/置前全靠它
      _log('浏览器：$exe');
      _log('cdp port=${launched.port}（随机端口）');

      // 浏览器自己的报错（崩溃/策略拒绝）通常走 stderr——转发进日志，
      // 分发机上出问题才有得查（本机复现不出来的环境差异全靠它）。
      launched.proc.stderr.listen((d) {
        final s = String.fromCharCodes(d).trim();
        if (s.isNotEmpty) _log('[浏览器stderr] $s');
      });
      launched.proc.stdout.listen((d) {
        final s = String.fromCharCodes(d).trim();
        if (s.isNotEmpty) _log('[浏览器stdout] $s');
      });
      launched.onExit = (code) {
        _log('浏览器进程退出：exit=$code / 0x${code.toRadixString(16)}');
      };

      final page = await findPage(launched.port);
      if (page == null) {
        _log('★ 找不到 page target');
        return 1;
      }
      tab = CdpTab('${page['webSocketDebuggerUrl']}');
      await tab.waitReady();
      await tab.cmd('Page.enable');
      await tab.cmd('Runtime.enable');

      // 3) 首次登录引导（必须在注入 agent 之前）
      if (_existingCreds() == null) {
        _log('没有可用的凭据，需要你登录一次小米账号（只这一次）。');
        final res = await _onboardSetup(tab, launched);
        if (res == null) {
          _log('★ 登录没有完成，退出。');
          return 4;
        }
        roundCreds = res.creds;
        if (!res.saved) memCreds = res.creds; // 本会话的取码都改用这份
      } else {
        _log('已有小米凭据，跳过登录引导。');
      }

      // 4) 注入 agent（必须在导航之前）
      final src = await loadAgentJs();
      // 钉死本轮目标页：agent 只认这个 origin（用户拿这个受控标签页去逛
      // 别的 IP 网页时，agent 必须彻底安静 —— 审查 2026-10-06）。
      final ident = await tab.installAgent(
        'window.__EzMiGeekTarget=${jsonEncode(url)};\n$src',
      );
      if (ident == null || ident.isEmpty) {
        _log('★ 注册注入脚本失败（CDP 通道可能已断），退出。');
        return 5;
      }

      // 5) 导航
      final rNav = await tab.cmd('Page.navigate', params: {'url': url});
      if (rNav['error'] != null) {
        _log('★ 导航失败：${rNav['error']}');
        return 5;
      }
      _log('导航到极客版…');

      // 6) 主循环（内存凭据优先于磁盘：写盘失败过的会话里磁盘是旧的）
      return await _loop(tab, hubIp, launched, roundCreds ?? memCreds);
    } catch (e) {
      _log('× 一轮异常：$e');
      return 1;
    } finally {
      try {
        tab?.close();
      } catch (_) {}
      launched?.stop();
      if (currentLaunched == launched) currentLaunched = null;
    }
  }

  // ── 主循环（loop 移植）──
  Future<int> _loop(
    CdpTab tab,
    String hubIp,
    Launched launched,
    Map<String, Object?>? memCreds,
  ) async {
    const waitGoneMs = 9000;
    var deadStreak = 0; // CDP 心跳连续失联次数（≥3 判「窗口已关」）
    var busyPhase = false;
    var coolUntil = DateTime.now();
    _failStreak = 0;
    var filled = 0;

    while (true) {
      if (_quitting) {
        _log('托盘点了退出，本轮收工。');
        return 6;
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));

      if (!await launched.alive()) {
        final code = launched.exitCode ?? await launched.proc.exitCode;
        final hint = switch (code) {
          0 => '正常退出（窗口被关，或命令被转交给别的实例）',
          _ => '异常终止（负数十六进制是 Windows 崩溃码）',
        };
        _log(
          '★ 浏览器进程已退出（exit=$code / 0x${code.toRadixString(16)}，$hint），本轮收工。',
        );
        return 5;
      }
      final v = await tab.js(
        '(window.__EzMiGeek__ && window.__EzMiGeek__.v) || null',
      );
      if (v == null && await tab.js('1') != 1) {
        deadStreak += 1;
        if (deadStreak >= 3) {
          _log('★ 浏览器窗口已关闭（CDP 通道断开），本轮收工。');
          return 5;
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
        continue;
      }
      deadStreak = 0;
      if (v == null) continue; // 非目标 origin 的页面：agent 不在，安静待命

      final pad = '${await tab.js('window.__EzMiGeek__.pad()')}';
      if (pad != 'pin-number' && pad != 'input.pin-code-input') {
        // 转人工暂停中：输码界面消失 = 用户手动登录成功 → 自动恢复待命。
        if (_pausedForManual && pad == 'none') {
          _log('检测到输码界面消失（应是手动登录成功）→ 恢复自动填码。');
          _pausedForManual = false;
          _failStreak = 0;
          coolUntil = DateTime.now().add(const Duration(seconds: 15));
          try {
            await tab.js('window.__EzMiGeek__.hide()');
          } catch (_) {}
          setStatus(
            'st.manualok',
            bottomKey: 'st.manualok.bottom',
            warnFlag: false,
            busyFlag: false,
          );
          if (settings.autoTrayDone) {
            onHideToTray?.call();
          }
        }
        continue;
      }
      // 暂停闸：转人工之后绝不自动取码填码，等恢复。
      if (_pausedForManual) continue;
      if (busyPhase || DateTime.now().isBefore(coolUntil)) continue;

      busyPhase = true;
      try {
        _log('检测到输码界面：$pad');
        setStatus(
          'st.fetch',
          args: [filled + 1],
          bottomKey: 'st.fetch.bottom',
          bottomArgs: [filled + 1],
          warnFlag: false,
          busyFlag: true,
        );

        // ---- 取码（WaitMin 重试窗口 + 过期早退 rc=8）----
        String? code;
        final tFetch = DateTime.now();
        while (true) {
          try {
            final (c, _) = await fetchCode(hubIp, log: _log, cfg: memCreds);
            code = c;
            break;
          } on PasscodeError catch (e) {
            if (isStale(e)) {
              _log('★ 取码失败的原因是「小米登录已失效」→ 不再重试，直接收轮');
              return 8;
            }
            final waitedMin = DateTime.now().difference(tFetch).inMinutes;
            if (waitedMin >= settings.waitMin) {
              throw StateError('取码超时（已等 $waitedMin 分钟）：$e');
            }
            _log('  取码失败，${settings.retrySec} 秒后重试：$e');
            if (!await _sleepBetween(settings.retrySec)) return 6;
          }
        }
        _log('取到码 $code');
        setStatus('st.fill', busyFlag: true);

        await tab.cmd('Page.bringToFront');
        final tFill = DateTime.now();
        final fillOk = await fillCode(tab, code, pad, log: _log);
        _log('填入 ${code.length} 位 -> $fillOk');
        if (!fillOk) throw StateError('填码失败');

        var gone = false;
        final t0 = DateTime.now();
        while (DateTime.now().difference(t0).inMilliseconds < waitGoneMs) {
          final p = '${await tab.js('window.__EzMiGeek__.pad()')}';
          if (p == 'none') {
            gone = true;
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }

        if (gone) {
          filled += 1;
          final usedSecs =
              DateTime.now().difference(tFill).inMilliseconds / 1000.0;
          _log('✓ 已登录（界面消失用了 ${usedSecs.toStringAsFixed(1)}s）');
          setStatus(
            'st.ok',
            bottomKey: 'st.ok.bottom',
            bottomArgs: [filled, usedSecs.round()],
            warnFlag: false,
            busyFlag: false,
          );
          await tab.js('window.__EzMiGeek__.hide()');
          _failStreak = 0;
          coolUntil = DateTime.now().add(const Duration(seconds: 15));
          if (settings.autoTrayDone) {
            onHideToTray?.call();
          }
          try {
            stats = stats.bump(secs: usedSecs);
            sync();
          } catch (e) {
            _log('× 记登录次数失败（不影响这次登录）：$e');
          }
        } else {
          _failStreak += 1;
          _log('× 界面没消失（连续失败 $_failStreak/${settings.failMax}）');
          if (_failStreak >= settings.failMax) {
            // ★ 转人工要真转：暂停自动流程，等用户手动输码或点「极客开启」。
            //   只弹提示却继续自动取码填码，下一轮照样把人工顶掉。
            await tab.cmd(
              'Runtime.evaluate',
              params: {
                'expression':
                    'window.__EzMiGeek__.note(${jsonEncode(t('page.manual'))}, "err")',
              },
            );
            _enterManualPause();
          } else if (!await _sleepBetween(settings.retrySec)) {
            return 6;
          }
        }
      } catch (e) {
        _failStreak += 1;
        _log('× $e');
        if (_failStreak >= settings.failMax) {
          await tab.cmd(
            'Runtime.evaluate',
            params: {
              'expression':
                  'window.__EzMiGeek__.note(${jsonEncode(t('page.err', [e]))}, "err")',
            },
          );
          _enterManualPause(); // 同上：达上限就停手，不再跳过重试间隔继续跑
        } else if (!await _sleepBetween(settings.retrySec)) {
          return 6;
        }
      } finally {
        busyPhase = false;
      }
    }
  }

  Future<bool> _sleepBetween(int sec) async {
    final end = DateTime.now().add(Duration(seconds: sec));
    while (DateTime.now().isBefore(end)) {
      if (_quitting) return false;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    return true;
  }

  // ── 降级轮（非 Chromium 默认浏览器：网页照开、码进剪贴板）──
  Future<int> _manualRound(
    String hubIp,
    String url,
    String exe,
    List<String> extra,
  ) async {
    _log('★ 降级：默认浏览器不是 Chromium 系（$exe），码复制进剪贴板请手动粘贴。');
    if (_existingCreds() == null) {
      _log('× 还没有可用的登录凭据。');
      return 4;
    }
    final wantFs = settings.autoFullscreen;
    try {
      await Process.run('cmd', ['/c', 'start', '', url], runInShell: false);
    } catch (_) {}
    if (wantFs) {
      // 原版走 shape_new_window 快照差分补 F11/最大化；Flutter 版简化为
      // 只开窗口不裁形态（网页在默认浏览器里，形态由用户自己管）。
      _log('已打开 $url（降级轮不做窗口形态控制）');
    }

    final deadline = DateTime.now().add(Duration(minutes: settings.waitMin));
    while (DateTime.now().isBefore(deadline)) {
      if (_quitting) return 6;
      try {
        final (code, _) = await fetchCode(
          hubIp,
          log: _log,
          cfg: _existingCreds(),
        );
        final copied = _copyClipboard(code);
        _log('★ 登录码 $code 已取到${copied ? '，已复制到剪贴板' : ''}');
        return 7;
      } catch (e) {
        if (isStale(e)) return 8;
        _log('  取码失败，${settings.retrySec} 秒后重试：$e');
      }
      if (!await _sleepBetween(settings.retrySec)) return 6;
    }
    return 3;
  }

  bool _copyClipboard(String text) {
    try {
      Process.runSync('powershell.exe', [
        '-NoProfile',
        '-Command',
        'Set-Clipboard -Value ${jsonEncode(text)}',
      ]);
      return true;
    } catch (_) {
      return false;
    }
  }

  // ════════════════════════ 首次登录引导（onboard.setup 移植）══════════════════
  Map<String, Object?>? _existingCreds() {
    // 内存凭据优先：写盘失败过的会话里，它比磁盘上的旧凭据新鲜。
    if (memCreds != null) {
      _log('凭据在内存（此前写盘失败）→ 本会话直接用，不碰磁盘。');
      return memCreds;
    }
    try {
      final cfg = loadCfg();
      final missing = <String>[];
      for (final k in requiredCredKeys) {
        if ('${cfg[k] ?? ''}'.trim().isEmpty) missing.add(k);
      }
      if (missing.isNotEmpty) {
        _log('已有凭据缺字段 ${missing.join(', ')}（将重新登录）');
        return null;
      }
      return cfg;
    } catch (e) {
      _log('读取已有凭据失败（将重新登录）：$e');
      return null;
    }
  }

  /// 走完登录引导。返回 (凭据, 是否成功写盘)；null = 登录没完成。
  /// ★ 写盘结果必须随凭据一起交出去——重登流程拿它决定报成功还是报
  ///   「没存上」（审查二轮：保存失败仍显示成功）。
  Future<({Map<String, Object?> creds, bool saved})?> _onboardSetup(
    CdpTab tab,
    Launched launched,
  ) async {
    _log('=' * 60);
    _log(' 请在弹出的浏览器窗口里用小米账号登录。');
    _log(' 登录成功后窗口会自动跳到米家极客版并自动填入登录码。');
    _log(' 请让这个窗口一直开着，不要关它。');
    _log('=' * 60);
    messageInfo(t('ob.title'), t('ob.text'));

    await tab.cmd(
      'Page.navigate',
      params: {
        'url':
            'https://account.xiaomi.com/pass/serviceLogin'
            '?sid=xiaomiio&_locale=zh_CN',
      },
    );
    _log('已打开小米账号登录页，等待登录…');

    final wsUrl = await browserWsUrl(launched.port);
    final sess = BrowserSession(wsUrl);

    final t0 = DateTime.now();
    var dead = 0;
    var tick = DateTime.now();
    try {
      while (true) {
        await Future<void>.delayed(const Duration(seconds: 2));
        final elapsed = DateTime.now().difference(t0);
        if (elapsed.inSeconds > 300) {
          _log('★ 等待登录超时（300 秒），放弃。');
          return null;
        }
        List<Map<String, Object?>> cookies;
        try {
          cookies = await sess.allCookies();
        } catch (_) {
          cookies = [];
        }
        if (cookies.isEmpty) {
          dead += 1;
          if (dead >= 3) {
            _log('★ 浏览器已经关闭，停止等待登录。');
            return null;
          }
          continue;
        }
        dead = 0;

        final got = <String, Object?>{};
        for (final c in cookies) {
          final n = '${c['name'] ?? ''}';
          final v = '${c['value'] ?? ''}';
          if (requiredCredKeys.contains(n) && v.isNotEmpty) {
            got[n] = v; // 简化版 pick（取最后一个非空值）
          }
        }
        if (got.containsKey('passToken') && !got.containsKey('deviceId')) {
          got['deviceId'] = DateTime.now().microsecondsSinceEpoch
              .toRadixString(16)
              .toUpperCase();
          _log('  提示：cookie 里没有 deviceId，已生成一个占位标识。');
        }
        final missing = requiredCredKeys
            .where((k) => !got.containsKey(k) || '${got[k]}'.isEmpty)
            .toList();
        if (missing.isEmpty) {
          final merged = <String, Object?>{...got};
          try {
            merged.addAll(loadCfg());
          } catch (_) {}
          for (final e in got.entries) {
            merged[e.key] = e.value;
          }
          // ★ 写盘失败不许再谎报「凭据已就绪」：后续取码是从磁盘读的，
          //   旧代码保存失败也照样报成功，下一轮就用回旧凭据或报没凭据。
          //   现在：失败要明说，并把刚拿到的内存凭据原样返回给本轮兜底用。
          final saved = saveCfg(merged);
          if (saved) {
            _log('✓ 凭据已就绪（DPAPI 加密存到 ${credsPath()}）');
          } else {
            _log('× 凭据写盘失败！本轮先用内存凭据继续，请检查数据目录权限。');
            setInfo('info.credsavefail', [credsPath()]);
          }
          return (creds: merged, saved: saved);
        }
        if (DateTime.now().difference(tick).inSeconds > 10) {
          tick = DateTime.now();
          _log('  …等待登录中（${elapsed.inSeconds} 秒）｜还缺 ${missing.join(", ")}');
        }
      }
    } finally {
      sess.close();
    }
  }

  // ════════════════════════ 重新登录（动作行）══════════════════════

  Future<void> startRelogin() async {
    if (_relogining) {
      _log('重新登录：上一次还没结束 → 忽略这一次。');
      return;
    }
    if (_roundRunning) {
      // 统一互斥：一轮正在跑（含成功后的 15 秒监控冷却，那时 _busy 可能
      // 已是 false）→ 不许重登插进来跟它抢同一个浏览器 profile。
      _log('重新登录：一轮还在跑 → 等它结束再试。');
      setInfo('info.busyblock');
      sync();
      return;
    }
    _relogining = true;
    ui.row5Act = false;
    sync();
    unawaited(_reloginWorker());
  }

  Future<void> _reloginWorker() async {
    try {
      final ok = await _reloginRound();
      if (ok) {
        setStatus(
          'st.relogin_ok',
          bottomKey: 'st.relogin_ok.bottom',
          warnFlag: false,
        );
        setInfo('info.relogin_ok');
      }
    } catch (e) {
      _log('× 重新登录：异常 $e');
      setStatus(
        'st.relogin_fail',
        args: [e],
        bottomKey: 'st.relogin_fail.bottom',
        warnFlag: true,
      );
    } finally {
      _relogining = false;
      ui.row5Act = true;
      // ★ 兜底恢复忙碌态：重登路上 setStatus(busyFlag:true) 的每一条路
      //   （成功/失败/超时/异常）都必须在这里归还，否则主按钮和
      //   「重新登录」按钮会一直灰着（审查 2026-10-06 修1）。
      _busy = false;
      sync();
    }
  }

  Future<bool> _reloginRound() async {
    // 找浏览器
    final (exe0, _) = defaultBrowser();
    var exe = exe0 ?? '';
    if (exe.isEmpty || !isChromiumExe(exe)) {
      exe = findBrowser() ?? '';
    }
    if (exe.isEmpty || !isChromiumExe(exe)) {
      _log('★ 重新登录：默认浏览器不是 Chromium 系，读不到 cookie。');
      messageInfo(
        t('dlg.relogin.needchromium.title'),
        t('dlg.relogin.needchromium.text', [
          exe0 == null || exe0.isEmpty ? '未知' : exe0,
        ]),
      );
      setStatus(
        'st.relogin_nobrowser',
        bottomKey: 'st.relogin_nobrowser.bottom',
        warnFlag: true,
      );
      return false;
    }

    if (!confirmRelogin(t('dlg.relogin.title'), t('st.relogin_confirm'))) {
      _log('重新登录：用户点了取消 → 什么都没动。');
      setStatus('st.ready', bottomKey: 'st.ready.bottom', warnFlag: false);
      return false;
    }

    setStatus(
      'st.relogin_ing',
      bottomKey: 'st.relogin_ing.bottom',
      busyFlag: true,
    );
    _log('重新登录：开一个浏览器窗口去登小米账号…');

    final profile = profileDir();
    Launched? launched;
    CdpTab? tab;
    try {
      launched = await launchBrowser(exe, profile, fullscreen: false);
      final page = await findPage(launched.port);
      if (page == null) {
        setStatus(
          'st.relogin_fail',
          args: ['no page target'],
          bottomKey: 'st.relogin_fail.bottom',
          warnFlag: true,
        );
        return false;
      }
      tab = CdpTab('${page['webSocketDebuggerUrl']}');
      await tab.waitReady();
      await tab.cmd('Page.enable');
      await tab.cmd('Runtime.enable');

      final res = await _onboardSetup(tab, launched);
      if (res == null) {
        setStatus(
          'st.relogin_fail',
          args: ['timeout'],
          bottomKey: 'st.relogin_fail.bottom',
          warnFlag: true,
        );
        return false;
      }
      // 清票据缓存（不清的话新凭据命中旧票——实测坑）。
      _clearCaches();
      if (res.saved) {
        memCreds = null;
        return true; // 成功态由 _reloginWorker 统一挂
      }
      // ★ 登录本身成了，但没写上盘：不许报「重登成功」。凭据留在内存里
      //   给本会话的取码用；重启就会丢，界面把这件事写明（审查二轮）。
      memCreds = res.creds;
      _log('× 重登凭据写盘失败：本会话先用内存凭据顶上，重启后需再登一次。');
      setStatus(
        'st.relogin_savefail',
        bottomKey: 'st.relogin_savefail.bottom',
        warnFlag: true,
      );
      return false;
    } catch (e) {
      setStatus(
        'st.relogin_fail',
        args: [e],
        bottomKey: 'st.relogin_fail.bottom',
        warnFlag: true,
      );
      return false;
    } finally {
      try {
        tab?.close();
      } catch (_) {}
      launched?.stop();
    }
  }

  void _clearCaches() {
    for (final name in ['.token-cache.json', '.device-cache.json']) {
      try {
        // 数据目录里生成名为 EzMiGeek\.token-cache.json 的错位文件。
        final f = File(pJoin(dataDir(), name));
        if (f.existsSync()) f.deleteSync();
        _log('  已清 $name');
      } catch (_) {}
    }
  }

  // ════════════════════════ 诊断 ═══════════════════════
  void _log(Object? m) => AppLog.write(m);
}

String two(int v) => v.toString().padLeft(2, '0');
