// app_state.dart —— 状态宿主与一轮自动登录生命周期编排。
//
// 职责：
//   1. 状态翻译：把「跑到哪一步/出错/设置项」翻成 UI 只读字段（UiFields）；
//      界面文案统一走 i18n 字表，切语言实时重算；
//   2. 事件路由：命中区与托盘动作路由到具体业务；
//   3. 一轮生命周期：kick → round（热读配置→中枢→浏览器→CDP→取码→填码→监控）→ 汇报。
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
import '../native/win32.dart' show openFileWithDefaultApp;
import '../services/agent_js.dart';
import '../services/app_log.dart';
import '../services/autostart.dart';
import '../services/clipboard.dart';
import '../services/dialogs.dart';
import '../services/legal.dart';
import '../services/onboard_service.dart';

// ── UI 渲染字段（渲染层只读）──
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
  String infoLine = '';
  // 设置卡 5 行
  final List<String> rowT = List.filled(5, '');
  final List<String> rowS = List.filled(5, '');
  final List<bool> rowOn = List.filled(5, false);
  String codeText = '······'; // 行 0 右侧大字：6 位码（未取到时占位）
  bool codeReady = false; // 码可用（点行=复制）还是占位/失败（点行=重取/登录）
  String row5Btn = '';
  bool row5Act = true;
  String btnTray = '', btnDoc = '', btnLog = '';
  String foot1 = '', foot2 = '';
  bool langZh = true;
}

/// rc=1 环境类失败细分原因：让界面直接指出卡在哪一步及怎么修，不再只显示笼统的「环境有问题」。
enum EnvFailKind { none, noHub, manualHub, noBrowser, browserStart }

class StatusDesc {
  StatusDesc(this.key, [this.args = const []]);
  final String key;
  final List<Object?> args;
}

class AppState extends ChangeNotifier {
  final UiFields ui = UiFields();
  AppSettings settings = AppSettings();
  Stats stats = Stats();
  AutostartState _autostartCache = const AutostartState(
    enabled: false,
    raw: '',
    reason: 'unset',
  );

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

  // 降级轮（非 Chromium）最近一次取到的登录码，仅用于面板底部提示，不写日志。
  String _lastManualCode = '';

  // rc=1 环境类失败的细分类型与附带信息（每次 kick 重置）。
  EnvFailKind _envFailKind = EnvFailKind.none;
  String _envFailDetail = '';

  // 连续失败转人工后的暂停闸：true = 不再自动取码填码，
  // 等用户在网页里手动输码（界面消失自动恢复）或点「极客开启」恢复。
  bool _pausedForManual = false;
  int _failStreak = 0;

  // 写盘失败时的内存凭据兜底：登录本身成功、但没存上盘。本会话内取码
  // 优先用它，不再碰磁盘上的旧凭据；重启即失效，界面会写明。
  Map<String, Object?>? memCreds;

  // 重新登录防重入
  bool _relogining = false;

  // 中枢覆盖（--hub 参数，出厂空）
  String hubOverride = '';

  // ── 回调（宿主注入）──
  void Function()? onShowPanel; // 托盘单击/双击(开关关)/菜单「显示面板」
  void Function()? onHideToTray; // 「收到托盘」按钮
  Future<void> Function()? onQuit; // 托盘「退出」

  String _say(StatusDesc? d) => d == null ? '' : t(d.key, d.args);

  // ════════════════════════ 状态同步 ══════════════════
  void _fillState() {
    stats.rolloverIfNeeded();
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
    u.infoLine = _say(_info).isEmpty ? t('info.idle') : _say(_info);

    u.btnTray = t('btn.tray');
    u.btnDoc = t('btn.doc');
    u.btnLog = t('btn.log');
    u.foot1 = t('app.foot');
    u.foot2 = t('app.data_dir', [dataDir()]);
  }

  /// 设置卡 5 行字段填入：
  ///   0 登录码显示 → 1 收进托盘 → 2 双击开网页 → 3 开机自启 → 4 重新登录。
  void _fillSettingsRows() {
    final u = ui;
    u.rowT[0] = t('row.code');
    u.rowS[0] = _codeSubtitle();
    u.rowOn[0] = false;
    u.codeText = _displayCode.isEmpty ? '······' : _displayCode;
    u.codeReady = _codeState == 'ok' || _codeState == 'copied';

    u.rowT[1] = t('row.traydone');
    u.rowS[1] = t('row.traydone.sub');
    u.rowOn[1] = settings.autoTrayDone;

    u.rowT[2] = t('row.dblopen');
    u.rowS[2] = t('row.dblopen.sub');
    u.rowOn[2] = settings.autoDblOpenWeb;

    // 副标题使用缓存的注册表状态，避免每次 UI 刷新都读注册表。
    u.rowT[3] = t('row.autostart');
    u.rowS[3] = autostartSubtitleFrom(_autostartCache);
    u.rowOn[3] = settings.autoStart;

    u.rowT[4] = t('row.relogin');
    u.rowS[4] = t('row.relogin.sub');
    u.rowOn[4] = false;
    u.row5Btn = t('row.relogin.btn');
    u.row5Act = !_relogining && !_busy;
  }

  static bool _isToday(DateTime d) {
    final n = DateTime.now();
    return n.year == d.year && n.month == d.month && n.day == d.day;
  }

  void sync() {
    _fillState();
    _fillSettingsRows();
    notifyListeners();
  }

  // ══════════════════ 状态设置 ══════════════════
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
      case 1:
        settings.autoTrayDone = !settings.autoTrayDone;
      case 2:
        settings.autoDblOpenWeb = !settings.autoDblOpenWeb;
      case 3:
        settings.autoStart = !settings.autoStart;
      default:
        return;
    }
    _saveSettingsAndSyncAutostart();
  }

  void _saveSettingsAndSyncAutostart() {
    try {
      if (!saveSettings(settings)) throw StateError('写盘失败');
    } catch (e) {
      _log('× 保存设置失败：$e');
      setInfo('info.savefail', ['$e']);
      sync();
      return;
    }
    try {
      final st = setEnabled(settings.autoStart);
      _autostartCache = st;
      settings.autoStart = st.enabled;
      _log(
        '开机自启动 → ${settings.autoStart ? '开' : '关'}（${st.raw.isEmpty ? '无' : st.raw}）',
      );
    } catch (e) {
      _autostartCache = autostartState();
      _log('× 开机自启动没设成：$e');
      setInfo('info.savefail', ['$e']);
    }
    sync();
  }

  /// 每轮开跑前从磁盘热加载非界面直接控制的运行参数，兑现「改完 settings.json 下一轮即生效」。
  void _reloadRuntimeSettings() {
    final disk = loadSettings();
    settings.waitMin = disk.waitMin;
    settings.retrySec = disk.retrySec;
    settings.failMax = disk.failMax;
    settings.hubIp = disk.hubIp;
    settings.autoFullscreen = disk.autoFullscreen;
  }

  /// 启动时读取配置与统计，按注册表对齐自启状态；[fetchInitialCode] 为 true 时自动取一次登录码。
  void loadSettingsAtStartup({bool fetchInitialCode = true}) {
    settings = loadSettings();
    Lang.set(settings.langZh ? 'zh' : 'en');
    _autostartCache = autostartState();
    settings.autoStart = _autostartCache.enabled;
    stats = Stats.load();
    setStatus('st.ready', bottomKey: 'st.ready.bottom', warnFlag: false);
    if (fetchInitialCode) {
      unawaited(refreshDisplayedCode());
    }
  }

  // ════════════════ 设置卡行 0：登录码显示（取/复制）════════════════
  String _displayCode = '';
  DateTime? _displayCodeAt;
  String _codeState = 'loading'; // loading|ok|copied|fail|needlogin
  bool _codeFetching = false;
  Timer? _copiedTimer;

  /// 出图模式（--ui-png）用：登录码行是否已落定。
  bool get codeSettled =>
      _codeState == 'ok' ||
      _codeState == 'copied' ||
      _codeState == 'fail' ||
      _codeState == 'needlogin';

  String _codeSubtitle() {
    switch (_codeState) {
      case 'ok':
      case 'copied':
        if (_displayCodeAt != null) {
          return _codeState == 'copied'
              ? t('row.code.copied')
              : t('row.code.tap', [Lang.fmtTime(_displayCodeAt!, true)]);
        }
        return t('row.code.loading');
      case 'needlogin':
        return t('row.code.needlogin');
      case 'fail':
        return t('row.code.fail');
      default:
        return t('row.code.loading');
    }
  }

  /// 点登录码行：有码 → 复制；未登录 → 引导开启；失败 → 重取。
  void onCodeRowTapped() {
    if (_codeState == 'ok' && _displayCode.isNotEmpty) {
      unawaited(copyToClipboard(_displayCode));
      _log('登录码已复制到剪贴板（设置卡行 0）。');
      _codeState = 'copied';
      sync();
      _copiedTimer?.cancel();
      _copiedTimer = Timer(const Duration(seconds: 3), () {
        if (_codeState == 'copied') {
          _codeState = 'ok';
          sync();
        }
      });
      return;
    }
    if (_codeState == 'needlogin') {
      unawaited(kick('设置卡登录码行'));
      return;
    }
    unawaited(refreshDisplayedCode());
  }

  void onCodeRefreshTapped() {
    unawaited(refreshDisplayedCode());
  }

  /// 取一次登录码给设置卡显示。无凭据时直接提示未登录，不白扫局域网。
  Future<void> refreshDisplayedCode() async {
    if (_codeFetching) return;
    final creds = _existingCreds(silent: true);
    if (creds == null) {
      _displayCode = '';
      _codeState = 'needlogin';
      sync();
      return;
    }
    _codeFetching = true;
    _codeState = 'loading';
    sync();
    try {
      final hub = await _hubIpForCode(creds);
      final (code, _) = await fetchCode(hub, cfg: creds, log: _log);
      _displayCode = code;
      _displayCodeAt = DateTime.now();
      _codeState = 'ok';
      _log('登录码已取到（设置卡显示用，未落盘）。');
    } catch (e) {
      _codeState = 'fail';
      _log('× 设置卡取登录码失败：$e');
    } finally {
      _codeFetching = false;
      sync();
    }
  }

  Future<String> _hubIpForCode(Map<String, Object?> creds) async {
    final manual = hubOverride.isNotEmpty ? hubOverride : settings.hubIp;
    if (manual.isNotEmpty) {
      final idx = manual.lastIndexOf(':');
      return idx > 0 ? manual.substring(0, idx) : manual;
    }
    final (hubIp, _, _) = await discover();
    if (hubIp.isNotEmpty) return hubIp;
    final hints = await hubIpHints(cfg: creds, log: _log);
    return hints.isEmpty ? '' : hints.first;
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
    onShowPanel?.call();
    sync();
  }

  Future<void> onTrayDoubleClicked() async {
    if (!settings.autoDblOpenWeb) {
      _log('双击托盘：设置里关着「双击托盘图标打开网页」→ 只把面板叫出来。');
      onShowPanel?.call();
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
    await l.stop();
  }

  Future<void> openLogsFolder() async {
    _log('打开日志文件夹。');
    if (!openFileWithDefaultApp(logsDir())) {
      _log('× 打开日志文件夹失败。');
    }
  }

  Future<void> openManual() async {
    _log('打开使用说明。');
    try {
      final f = File(pJoin(dataDir(), pJoin('help', 'EzMiGeek-使用说明.txt')));
      if (!f.existsSync()) {
        await f.parent.create(recursive: true);
        final data = await rootBundle.load('assets/使用说明.txt');
        await f.writeAsBytes(data.buffer.asUint8List(), flush: true);
      }
      if (!openFileWithDefaultApp(f.path)) {
        _log('× ShellExecuteW 打开使用说明失败：${f.path}');
      }
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
    _copiedTimer?.cancel();
    cancelCloudRequests();
    final l = currentLaunched;
    if (l != null) {
      _log('退出时不收浏览器（固定保留）→ pid=${l.proc.pid} 留着，程序先退。');
    } else {
      _log('请求退出：当前没有在跑的一轮，直接收。');
    }
    setStatus('st.quitting');
  }

  // ════════════════════════ 一轮（kick → _round）══════════════════════

  Future<void> kick(String why) async {
    if (_relogining) {
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
    _autoRetried = false;
    _envFailKind = EnvFailKind.none;
    _envFailDetail = '';
    _info = null;
    _log('$why → 起一轮。');
    setStatus('st.kick', bottomKey: 'st.kick.bottom', busyFlag: true);
    unawaited(_roundWrapper());
  }

  Future<void> _roundWrapper() async {
    try {
      var rc = await _round();
      _log('本轮结束（rc=$rc）');
      if (_quitting) return;
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
      _pausedForManual = false;
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

  @visibleForTesting
  void reportRoundForTest(
    int rc, {
    String manualCode = '',
    EnvFailKind envFail = EnvFailKind.none,
    String detail = '',
  }) {
    _lastManualCode = manualCode;
    _envFailKind = envFail;
    _envFailDetail = detail;
    _reportRound(rc);
  }

  void _reportEnvFail() {
    switch (_envFailKind) {
      case EnvFailKind.manualHub:
        _info = StatusDesc('rc.1.nohub.info');
        setStatus(
          'rc.1.manualhub.status',
          bottomKey: 'rc.1.manualhub.bottom',
          bottomArgs: [_envFailDetail],
          warnFlag: true,
        );
      case EnvFailKind.noHub:
        _info = StatusDesc('rc.1.nohub.info');
        setStatus(
          'rc.1.nohub.status',
          bottomKey:
              Platform.isMacOS ? 'rc.1.nohub.bottom.mac' : 'rc.1.nohub.bottom',
          warnFlag: true,
        );
      case EnvFailKind.noBrowser:
        _info = StatusDesc('rc.1.nobrowser.info');
        setStatus(
          'rc.1.nobrowser.status',
          bottomKey: 'rc.1.nobrowser.bottom',
          warnFlag: true,
        );
      case EnvFailKind.browserStart:
        _info = StatusDesc('rc.1.browser.info');
        setStatus(
          'rc.1.browser.status',
          bottomKey: 'rc.1.browser.bottom',
          warnFlag: true,
        );
      case EnvFailKind.none:
        _info = StatusDesc('rc.1.info');
        setStatus('rc.1.status', bottomKey: 'rc.1.bottom', warnFlag: true);
    }
  }

  void _reportRound(int rc) {
    switch (rc) {
      case 0:
        setStatus('rc.0.status', bottomKey: 'rc.0.bottom', warnFlag: false);
      case 1:
        _reportEnvFail();
      case 3:
        setStatus('rc.3.status', bottomKey: 'rc.3.bottom', warnFlag: false);
      case 4:
        setStatus('rc.4.status', bottomKey: 'rc.4.bottom', warnFlag: true);
      case 5:
        setStatus('rc.5.status', bottomKey: 'rc.5.bottom', warnFlag: false);
      case 6:
        setStatus('rc.6.status', bottomKey: 'rc.6.bottom', warnFlag: false);
      case 7:
        setStatus(
          'rc.7.status',
          bottomKey: 'rc.7.bottom',
          bottomArgs: [_lastManualCode.isEmpty ? '******' : _lastManualCode],
          warnFlag: false,
        );
      case 8:
        setStatus('rc.8.status', bottomKey: 'rc.8.bottom', warnFlag: true);
      default:
        setStatus(
          'rc.x.status',
          bottomKey: 'rc.x.bottom',
          bottomArgs: [rc],
          warnFlag: true,
        );
    }
  }

  // ════════════════════════ 一轮主流程 ══════════════════════

  /// 解析手动中枢地址：
  ///   · 明确写端口（如 `192.168.5.3:80`）→ 仅探该端口；
  ///   · 省略端口（如 `192.168.5.3`）→ 按 8086 → 80 顺序探测并校验极客版页面身份。
  Future<(String, int, String)?> _resolveManualHub(String manual) async {
    final idx = manual.lastIndexOf(':');
    final explicitPort = idx > 0 ? int.tryParse(manual.substring(idx + 1)) : null;
    final host = explicitPort != null ? manual.substring(0, idx).trim() : manual.trim();
    if (host.isEmpty) return null;
    final src = hubOverride.isNotEmpty ? '命令行指定' : '设置文件指定';
    if (explicitPort != null) {
      if (await probeWs(host, port: explicitPort)) {
        return (host, explicitPort, src);
      }
      return null;
    }
    final foundPort = await findGeekPort(host);
    if (foundPort != null) {
      return (host, foundPort, src);
    }
    // 兜底：若极客版页面首包慢或被反代，仅 TCP 试 8086/80 一次。
    for (final p in geekPorts) {
      if (await probeWs(host, port: p)) {
        return (host, p, '$src（端口可达）');
      }
    }
    return null;
  }

  Future<int> _round() async {
    _reloadRuntimeSettings();

    // 1) 中枢发现：--hub > settings.HubIp > 局域网自动发现 > 云端 localip 提示。
    String hubIp;
    var hubPort = geekPort;
    String hubWhy;
    final manual = hubOverride.isNotEmpty ? hubOverride : settings.hubIp;
    if (manual.isNotEmpty) {
      final resolved = await _resolveManualHub(manual);
      if (resolved != null) {
        (hubIp, hubPort, hubWhy) = resolved;
      } else {
        _log('手动指定的中枢 $manual 探不通，转自动发现');
        (hubIp, hubPort, hubWhy) = await discover();
      }
    } else {
      (hubIp, hubPort, hubWhy) = await discover();
    }

    if (hubIp.isEmpty) {
      final hints = await hubIpHints(cfg: _existingCreds(silent: true), log: _log);
      if (hints.isNotEmpty) {
        _log('云端提示中枢可能在：${hints.join('、')}');
        for (final ip in hints) {
          final port = await findGeekPort(ip);
          if (port != null) {
            hubIp = ip;
            hubPort = port;
            hubWhy = '云端提示';
            saveCache({
              'hub_ip': ip,
              'port': port,
              'ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
            });
            break;
          }
        }
      }
    }
    if (hubIp.isEmpty) {
      _envFailKind = manual.isNotEmpty
          ? EnvFailKind.manualHub
          : EnvFailKind.noHub;
      _envFailDetail = manual.isNotEmpty ? manual : hubWhy;
      _log('× 局域网里没找到极客版中枢，本轮取消。诊断：$hubWhy');
      _log(
        '· 可以在设置文件 settings.json 里加 "HubIp": "中枢IP[:端口]" 手动指定，'
        '或确认极客版主机已开机、和这台电脑在同一网段。',
      );
      if (Platform.isMacOS) {
        _log('· macOS 15+ 请同时确认「系统设置 → 隐私与安全性 → 本地网络」中已允许 EzMiGeek。');
      }
      return 1;
    }
    final url = 'http://$hubIp${hubPort == 80 ? '' : ':$hubPort'}/';
    _log('中枢 $hubIp:$hubPort（$hubWhy） → $url');

    // 2) 浏览器（系统默认）
    final (exe0, extra) = defaultBrowser();
    if (exe0 != null && !isChromiumExe(exe0)) {
      _log('默认浏览器 $exe0（非 Chromium 系，走降级轮）');
      return _manualRound(hubIp, url, exe0, extra);
    }
    var exe = exe0 ?? '';
    if (exe.isEmpty) {
      _log('解析不出系统默认浏览器，退回候选路径查找');
      exe = findBrowser() ?? '';
      if (exe.isEmpty) {
        _envFailKind = EnvFailKind.noBrowser;
        _log('× 找不到任何可用的浏览器');
        return 1;
      }
    }
    final profile = profileDir();
    final killed = await killStale(profile);
    if (killed != 0) {
      _log('清掉上次残留的浏览器实例（pid=$killed）');
    }

    Launched? launched;
    CdpTab? tab;
    Map<String, Object?>? roundCreds;
    try {
      launched = await launchBrowser(
        exe,
        profile,
        fullscreen: settings.autoFullscreen,
      );
      currentLaunched = launched;
      _log('浏览器：$exe');
      _log('cdp port=${launched.port}（随机端口）');

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
        _envFailKind = EnvFailKind.browserStart;
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
        final res = await runOnboardSetup(
          tab,
          launched,
          log: _log,
          onInfo: setInfo,
          onWaitingLogin: () {
            _info = StatusDesc('st.onboard_wait.info');
            setStatus(
              'st.onboard_wait',
              bottomKey: 'st.onboard_wait.bottom',
              busyFlag: true,
            );
          },
          onSignedIn: () {
            _info = StatusDesc('st.onboard_nav.info');
            setStatus(
              'st.onboard_nav',
              bottomKey: 'st.onboard_nav.bottom',
              busyFlag: true,
            );
          },
          isQuitting: () => _quitting,
        );
        if (res == null) {
          _log('★ 登录没有完成，退出。');
          return 4;
        }
        roundCreds = res.creds;
        if (!res.saved) memCreds = res.creds;
        // 首次登录成功后同步刷新设置卡登录码显示。
        unawaited(refreshDisplayedCode());
      } else {
        _log('已有小米凭据，跳过登录引导。');
      }

      // 4) 注入 agent（必须在导航之前）
      final src = await loadAgentJs();
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

      // 6) 主循环
      return await _loop(tab, hubIp, launched, roundCreds ?? memCreds);
    } catch (e) {
      if (launched == null || tab == null || !tab.isOpen) {
        _envFailKind = EnvFailKind.browserStart;
      }
      _log('× 一轮异常：$e');
      return 1;
    } finally {
      try {
        tab?.close();
      } catch (_) {}
      await launched?.stop();
      if (currentLaunched == launched) currentLaunched = null;
    }
  }

  // ── 主循环 ──
  Future<int> _loop(
    CdpTab tab,
    String hubIp,
    Launched launched,
    Map<String, Object?>? sessionCreds,
  ) async {
    const waitGoneMs = 9000;
    var deadStreak = 0;
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
      if (v == null) continue;

      final pad = '${await tab.js('window.__EzMiGeek__.pad()')}';
      if (pad != 'pin-number' && pad != 'input.pin-code-input') {
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

        String? code;
        final tFetch = DateTime.now();
        while (true) {
          try {
            final (c, _) = await fetchCode(hubIp, log: _log, cfg: sessionCreds);
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
        // 日志纪律：绝不向 agent.log 输出 6 位明文登录码。
        _log('取到登录码（${code.length} 位）');
        _displayCode = code;
        _displayCodeAt = DateTime.now();
        _codeState = 'ok';
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
          _enterManualPause();
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
    final creds = _existingCreds();
    if (creds == null) {
      _log('× 还没有可用的登录凭据。');
      return 4;
    }
    if (!openFileWithDefaultApp(url)) {
      _log('× 打开默认浏览器失败：$url');
    }
    if (settings.autoFullscreen) {
      _log('已打开 $url（降级轮不做窗口形态控制）');
    }

    final deadline = DateTime.now().add(Duration(minutes: settings.waitMin));
    while (DateTime.now().isBefore(deadline)) {
      if (_quitting) return 6;
      try {
        final (code, _) = await fetchCode(hubIp, log: _log, cfg: creds);
        final copied = await copyToClipboard(code);
        _lastManualCode = code;
        _displayCode = code;
        _displayCodeAt = DateTime.now();
        _codeState = copied ? 'copied' : 'ok';
        // 日志纪律：不向磁盘日志写入 6 位明文码。
        _log('★ 降级取码成功（${code.length} 位）${copied ? '，已复制到剪贴板' : ''}');
        return 7;
      } catch (e) {
        if (isStale(e)) return 8;
        _log('  取码失败，${settings.retrySec} 秒后重试：$e');
      }
      if (!await _sleepBetween(settings.retrySec)) return 6;
    }
    return 3;
  }

  // ════════════════════════ 凭据检查与重新登录 ══════════════════════

  Map<String, Object?>? _existingCreds({bool silent = false}) {
    if (memCreds != null) {
      if (!silent) _log('凭据在内存（此前写盘失败）→ 本会话直接用，不碰磁盘。');
      return memCreds;
    }
    try {
      final cfg = loadCfg();
      final missing = <String>[];
      for (final k in requiredCredKeys) {
        if ('${cfg[k] ?? ''}'.trim().isEmpty) missing.add(k);
      }
      if (missing.isNotEmpty) {
        if (!silent) _log('已有凭据缺字段 ${missing.join(', ')}（将重新登录）');
        return null;
      }
      return cfg;
    } catch (e) {
      if (!silent) _log('读取已有凭据失败（将重新登录）：$e');
      return null;
    }
  }

  Future<void> startRelogin() async {
    if (_relogining) {
      _log('重新登录：上一次还没结束 → 忽略这一次。');
      return;
    }
    if (_roundRunning) {
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
        unawaited(refreshDisplayedCode());
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
      _busy = false;
      sync();
    }
  }

  Future<bool> _reloginRound() async {
    final (exe0, _) = defaultBrowser();
    var exe = exe0 ?? '';
    if (exe.isEmpty || !isChromiumExe(exe)) {
      exe = findBrowser() ?? '';
    }
    if (exe.isEmpty || !isChromiumExe(exe)) {
      _log('★ 重新登录：找不到可用的 Chromium 系浏览器，读不到 cookie。');
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

      final res = await runOnboardSetup(
        tab,
        launched,
        log: _log,
        onInfo: setInfo,
        isRelogin: true,
        isQuitting: () => _quitting,
      );
      if (res == null) {
        setStatus(
          'st.relogin_fail',
          args: ['timeout'],
          bottomKey: 'st.relogin_fail.bottom',
          warnFlag: true,
        );
        return false;
      }
      _clearCaches();
      if (res.saved) {
        memCreds = null;
        return true;
      }
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
      await launched?.stop();
    }
  }

  void _clearCaches() {
    for (final name in ['.token-cache.json', '.device-cache.json']) {
      try {
        final f = File(pJoin(dataDir(), name));
        if (f.existsSync()) f.deleteSync();
        _log('  已清 $name');
      } catch (_) {}
    }
  }

  void _log(Object? m) => AppLog.write(m);
}
