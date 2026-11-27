// i18n.dart —— 界面文案中英双份字表（本文件即字表正身，直接在此维护）。
//
// 约定：界面上所有文字都从这张表出；状态文案存 (key, args) 切语言时重算；
// 缺 key 返回 ⟦key⟧ 占位符让漏译一眼可见；中英两条必须 1:1 成对增删。
library;

String _lang = 'zh';

const Map<String, String> _zhTable = {
  'app.name': '米家自动化极客版自动登录助手',
  'app.foot': 'EzMiGeek · 米家自动化极客版自动登录助手',
  'app.data_dir': '数据目录：%s',
  'app.starting': '正在启动…',
  'btn.main': '极客开启',
  'btn.tray': '收到托盘',
  'btn.doc': '使用说明',
  'btn.log': '查看日志',
  'c1.hint': '请阅读使用说明',
  'info.busyblock': '正在跑一轮，结束后再试',
  'lab.total': '总共登录次数',
  'lab.today': '今天登录次数',
  'sub.last': '最近成功：%s',
  'sub.last.dur': '最近成功：%s · 用时 %.0f 秒',
  'sub.never': '还没有成功记录',
  'bottom.idle': '点上面的按钮打开极客版，登录码会自动填好。',
  'row.autostart': '开机自动启动',
  'as.on': '随 Windows 一起启动',
  'as.on.mac': '随 macOS 登录一起启动',
  'as.elsewhere': '自启配置指向别的路径，拨一下就能修正',
  'as.readfail': '读不到自启状态（%s）',
  'as.unknown': '未知原因',
  'row.relogin': '重新登录小米账号',
  'row.relogin.sub': '登录过期后点这里重新登一次',
  'row.relogin.btn': '重新登录',
  'row.traydone': '登录成功后收进托盘',
  'row.traydone.sub': '填码成功后自动把面板收起',
  'row.dblopen': '双击托盘图标打开网页',
  'row.dblopen.sub': '单击叫面板，双击开极客版',
  'row.code': '当前登录码',
  'row.code.loading': '正在取码…',
  'row.code.tap': '点击复制 · %s 取到',
  'row.code.fail': '取码失败 · 点击重试',
  'row.code.needlogin': '未登录小米账号 · 点「极客开启」登录',
  'row.code.copied': '已复制到剪贴板',
  'info.idle': '提示：登录码默认 5 分钟失效，超时会自动重试。',
  'info.savefail': '保存失败：%s',
  'info.credsavefail': '凭据写盘失败（%s）—— 本轮先用刚登录拿到的凭据继续',
  'info.relogin_ok': '已重新登录，凭据已更新',
  'st.busy_round': '已经在跑一轮了…',
  'st.kick': '正在跑一轮…',
  'st.kick.bottom': '本轮已开始：正在打开极客版…',
  'st.ready': '待命',
  'st.ready.bottom': '点「极客开启」开始',
  'st.quitting': '正在退出…',
  'st.error': '出错了：%s',
  'st.error.bottom': '本轮因异常结束',
  'st.fetch': '正在取登录码…',
  'st.fetch.bottom': '检测到输码界面 · 本轮第 %d 次',
  'st.fill': '正在填入登录码…',
  'st.ok': '✓ 已登录',
  'st.ok.bottom': '本轮已成功 %d 次 · 本次用时 %.0f 秒',
  'st.paused': '已转人工，自动填码暂停',
  'st.paused.bottom': '可在网页里手动输码；点「极客开启」恢复自动',
  'st.manualok': '✓ 已登录（手动输入）',
  'st.manualok.bottom': '检测到输码界面消失，自动填码恢复待命',
  'st.resumed': '自动填码已恢复',
  'st.resumed.bottom': '继续监控输码界面',
  'st.busyrelogin': '正在重新登录…',
  'st.busyrelogin.bottom': '重新登录结束后再试',
  'rc.0.status': '空闲',
  'rc.0.bottom': '本轮结束：已完成，仍在待命',
  'rc.1.status': '出错了：没跑起来',
  'rc.1.bottom': '本轮结束：环境异常，请点「查看日志」查看具体原因',
  'rc.1.info': '常见原因：未连上极客版中枢、未装 Edge/Chrome 或浏览器被拦截',
  'rc.1.nohub.status': '未找到极客版中枢',
  'rc.1.nohub.bottom': '请确认极客版中枢已开机，且与本机在同一局域网段',
  'rc.1.nohub.bottom.mac': '请确认与中枢同网段，并在「系统设置→本地网络」允许本程序',
  'rc.1.nohub.info': '可在 settings.json 填 "HubIp":"中枢IP" 指定，或点「查看日志」排查',
  'rc.1.manualhub.status': '指定中枢连不上',
  'rc.1.manualhub.bottom': '指定中枢 %s 无法连接，请确认 IP/端口正确且中枢已开机',
  'rc.1.nobrowser.status': '未找到可用浏览器',
  'rc.1.nobrowser.bottom': '未检测到 Edge / Chrome，请先安装其中之一后重试',
  'rc.1.nobrowser.info': '安装 Edge 或 Chrome 后，再点「极客开启」即可自动填码',
  'rc.1.browser.status': '浏览器启动失败',
  'rc.1.browser.bottom': '未能连上浏览器调试通道，请关闭旧窗口后再点「极客开启」',
  'rc.1.browser.info': '若被安全软件拦截或残留进程占用，可点「查看日志」查看详情',
  'rc.3.status': '空闲（没输码界面）',
  'rc.3.bottom': '本轮结束：页面里没有输码界面',
  'rc.4.status': '没登上去',
  'rc.4.bottom': '本轮结束：还没有登录凭据，需要你手动登一次',
  'rc.5.status': '空闲（浏览器已关闭）',
  'rc.5.bottom': '本轮结束：浏览器已关闭',
  'rc.6.status': '已退出',
  'rc.6.bottom': '本轮结束：程序已退出',
  'rc.7.status': '已用默认浏览器打开',
  'rc.7.bottom': '登录码 %s 已复制到剪贴板，请在网页里粘贴输入',
  'rc.8.status': '小米登录已过期',
  'rc.8.bottom': '本轮结束：登录过期 —— 点面板「重新登录」即可修好',
  'rc.x.status': '空闲',
  'rc.x.bottom': '本轮结束：未知结果（rc=%s）',
  'st.relogin_confirm':
      '现在会打开小米账号登录页，请你在浏览器里\n用小米账号登录一次。\n\n登录成功后新凭据会替换旧的，程序自动接着用；\n这个过程不会动你的设置和登录次数统计。\n\n确定现在重新登录吗？',
  'st.relogin_ing': '正在等你登录…',
  'st.relogin_ing.bottom': '请在浏览器窗口里登录，登录成功后自动继续',
  'st.relogin_ok': '✓ 已重新登录',
  'st.relogin_ok.bottom': '凭据已更新，再点「极客开启」就能用了',
  'st.relogin_fail': '重登没完成：%s',
  'st.relogin_fail.bottom': '没登成，可以再点一次「重新登录」',
  'st.relogin_savefail': '重登成功，但凭据没能写盘',
  'st.relogin_savefail.bottom': '本会话先用新凭据自动顶上；重启后需再登一次（查数据目录权限）',
  'st.relogin_nobrowser': '重新登录需要浏览器',
  'st.relogin_nobrowser.bottom': '找不到可用的浏览器，登录页打不开',
  'dlg.relogin.title': 'EzMiGeek · 重新登录小米账号',
  'dlg.relogin.needchromium.title': 'EzMiGeek · 重新登录',
  'dlg.relogin.needchromium.text':
      '重新登录需要读浏览器的登录信息，只有 Edge / Chrome 这类浏览器支持。\n\n你当前的默认浏览器是：\n%s\n\n请安装或将系统默认浏览器设为 Edge / Chrome，再点一次「重新登录」。',
  'page.manual': '自动补码连续失败，请手动输入登录码',
  'page.err': '自动补码失败：%s',
  'ob.title': 'EzMiGeek · 首次使用',
  'ob.text':
      '接下来会打开小米账号登录页。\n\n请在弹出的浏览器窗口里用你的小米账号登录一次。\n登录成功后程序会自动继续，以后不用再登录。\n\n（浏览器窗口请保持打开，不要关掉）',
  'menu.panel': '显示面板',
  'menu.open': '打开极客版',
  'menu.stop': '关闭本轮浏览器',
  'menu.logs': '打开日志文件夹',
  'menu.legal': '免责声明',
  'menu.update': '检查更新',
  'menu.quit': '退出',
  'upd.title': 'EzMiGeek · 检查更新',
  'upd.latest': '当前已是最新版本（v%s）。',
  'upd.found': '发现新版本 v%s（当前 v%s）。\n\n是否打开 GitHub 发布页查看并下载？',
  'upd.fail': '检查更新失败：%s\n\n可手动前往 GitHub Releases 页面查看最新版本。',
};

const Map<String, String> _enTable = {
  'app.name': 'Mi Geek auto-login helper',
  'app.foot': 'EzMiGeek · Mi Geek auto-login helper',
  'app.data_dir': 'Data folder: %s',
  'app.starting': 'Starting…',
  'btn.main': 'Open Geek',
  'btn.tray': 'Send to tray',
  'btn.doc': 'User guide',
  'btn.log': 'View log',
  'c1.hint': 'See the user guide',
  'info.busyblock': 'A round is running - try again after',
  'lab.total': 'Total logins',
  'lab.today': 'Logins today',
  'sub.last': 'Last success: %s',
  'sub.last.dur': 'Last success: %s · took %.0f s',
  'sub.never': 'No success yet',
  'bottom.idle': 'Click the button above to open Mi Geek; the code fills in itself.',
  'row.autostart': 'Start at login',
  'as.on': 'Starts with Windows',
  'as.on.mac': 'Starts at macOS login',
  'as.elsewhere': 'Autostart points elsewhere — toggle to fix',
  'as.readfail': 'Cannot read autostart (%s)',
  'as.unknown': 'unknown reason',
  'row.relogin': 'Sign in to Mi account again',
  'row.relogin.sub': 'Use this when your sign-in has expired',
  'row.relogin.btn': 'Sign in',
  'row.traydone': 'Tuck away after sign-in',
  'row.traydone.sub': 'Hide the panel once the code is accepted',
  'row.dblopen': 'Open page on double click',
  'row.dblopen.sub': 'Single click shows panel, double click opens Geek',
  'row.code': 'Current login code',
  'row.code.loading': 'Fetching code…',
  'row.code.tap': 'Tap to copy · fetched %s',
  'row.code.fail': 'Fetch failed · tap to retry',
  'row.code.needlogin': 'Not signed in · click Open Geek first',
  'row.code.copied': 'Copied to clipboard',
  'info.idle': 'Tip: the code lasts 5 min, then retries.',
  'info.savefail': 'Save failed: %s',
  'info.credsavefail':
      'Could not save the credential to disk (%s) — this round uses the in-memory copy',
  'info.relogin_ok': 'Signed in again — credential updated',
  'st.busy_round': 'Already running…',
  'st.kick': 'Starting a round…',
  'st.kick.bottom': 'Round started: opening Mi Geek…',
  'st.ready': 'Ready',
  'st.ready.bottom': 'Click Open Geek to start',
  'st.quitting': 'Quitting…',
  'st.error': 'Error: %s',
  'st.error.bottom': 'The round ended with an error',
  'st.fetch': 'Fetching the code…',
  'st.fetch.bottom': 'Passcode page detected · attempt %d this round',
  'st.fill': 'Filling in the code…',
  'st.ok': '✓ Logged in',
  'st.ok.bottom': 'Succeeded %d time(s) · took %.0f s',
  'st.paused': 'Handed to you — auto-fill paused',
  'st.paused.bottom': 'Type the code yourself, or click "Open Geek" to resume',
  'st.manualok': '✓ Signed in (typed by hand)',
  'st.manualok.bottom': 'Code page is gone — auto-fill is standing by again',
  'st.resumed': 'Auto-fill resumed',
  'st.resumed.bottom': 'Watching for the code page again',
  'st.busyrelogin': 'Signing in again…',
  'st.busyrelogin.bottom': 'Try again after it finishes',
  'rc.0.status': 'Idle',
  'rc.0.bottom': 'Round over: done, standing by',
  'rc.1.status': 'Error: could not start',
  'rc.1.bottom': 'Round over: environment error — click "View log" for details',
  'rc.1.info': 'Common causes: Mi Geek hub unreachable, no Edge/Chrome, or browser blocked',
  'rc.1.nohub.status': 'No Mi Geek hub found',
  'rc.1.nohub.bottom': 'Make sure the Mi Geek hub is on and on the same LAN',
  'rc.1.nohub.bottom.mac': 'Verify same LAN and allow Local Network in macOS Settings',
  'rc.1.nohub.info': 'Set "HubIp" in settings.json manually, or click "View log" to diagnose',
  'rc.1.manualhub.status': 'Manual hub unreachable',
  'rc.1.manualhub.bottom': 'Cannot reach %s — check IP/port and make sure the hub is on',
  'rc.1.nobrowser.status': 'No browser found',
  'rc.1.nobrowser.bottom': 'Edge / Chrome not detected — install one and try again',
  'rc.1.nobrowser.info': 'Install Edge or Chrome, then click "Open Geek" to auto sign in',
  'rc.1.browser.status': 'Browser failed to start',
  'rc.1.browser.bottom': 'Could not reach browser debug port — close old windows and retry',
  'rc.1.browser.info': 'Click "View log" if blocked by security software or a stale browser',
  'rc.3.status': 'Idle (no code page)',
  'rc.3.bottom': 'Round over: no passcode page found',
  'rc.4.status': 'Not signed in',
  'rc.4.bottom': 'Round over: no credential yet — sign in once by hand',
  'rc.5.status': 'Idle (browser closed)',
  'rc.5.bottom': 'Round over: browser closed',
  'rc.6.status': 'Exited',
  'rc.6.bottom': 'Round over: the app exited',
  'rc.7.status': 'Opened in browser',
  'rc.7.bottom': 'Code %s copied to the clipboard — paste it into the page',
  'rc.8.status': 'Mi sign-in expired',
  'rc.8.bottom': 'Round over: sign-in expired - click "Sign in" on the panel',
  'rc.x.status': 'Idle',
  'rc.x.bottom': 'Round over: unknown result (rc=%s)',
  'st.relogin_confirm':
      'The Xiaomi account sign-in page will open now — please\nsign in with your Xiaomi account in the browser.\n\nThe new credential replaces the old one and the app carries\non by itself. Your settings and login count are untouched.\n\nSign in again now?',
  'st.relogin_ing': 'Waiting for sign-in…',
  'st.relogin_ing.bottom': 'Please sign in in the browser; it continues by itself',
  'st.relogin_ok': '✓ Signed in again',
  'st.relogin_ok.bottom': 'Credential updated — click "Open Geek" to use it',
  'st.relogin_fail': 'Login failed: %s',
  'st.relogin_fail.bottom': 'Not signed in — you can click "Sign in" again',
  'st.relogin_savefail': 'Signed in, but the credential could not be saved',
  'st.relogin_savefail.bottom':
      'This session keeps using it; after a restart sign in once more (check folder permissions)',
  'st.relogin_nobrowser': 'Needs a browser',
  'st.relogin_nobrowser.bottom': 'No usable browser found — the page cannot open',
  'dlg.relogin.title': 'EzMiGeek · Sign in to Mi account again',
  'dlg.relogin.needchromium.title': 'EzMiGeek · Sign in again',
  'dlg.relogin.needchromium.text':
      'Signing in again needs to read the browser\'s login data, which only Edge / Chrome support.\n\nYour current default browser is:\n%s\n\nPlease install or set Edge / Chrome as default, then click "Sign in" again.',
  'page.manual': 'Auto-fill failed repeatedly — please type the code yourself',
  'page.err': 'Auto-fill failed: %s',
  'ob.title': 'EzMiGeek · First run',
  'ob.text':
      'The Xiaomi account sign-in page will open next.\n\nPlease sign in with your Xiaomi account in the browser window.\nThe app continues by itself once you are in — only this once.\n\n(Keep that browser window open — do not close it)',
  'menu.panel': 'Show panel',
  'menu.open': 'Open Mi Geek',
  'menu.stop': 'Close this browser',
  'menu.logs': 'Open log folder',
  'menu.legal': 'Disclaimer',
  'menu.update': 'Check for updates',
  'menu.quit': 'Quit',
  'upd.title': 'EzMiGeek · Check for updates',
  'upd.latest': 'You are already on the latest version (v%s).',
  'upd.found':
      'New version v%s is available (current: v%s).\n\nOpen the GitHub release page to download?',
  'upd.fail':
      'Update check failed: %s\n\nYou can visit the GitHub Releases page manually.',
};

/// 导出给单测锁定中英字表 1:1 键对称。
Iterable<String> get i18nZhKeys => _zhTable.keys;
Iterable<String> get i18nEnKeys => _enTable.keys;

abstract final class Lang {
  static String get current => _lang;
  static bool get zh => _lang == 'zh';

  static void set(String v) => _lang = (v == 'en') ? 'en' : 'zh';

  /// Python `template % args` 的等价物：按顺序消费 %s / %d / %.0f，`%%` 转义成字面 %。
  static String fmt(String template, List<Object?> args) {
    final out = StringBuffer();
    var i = 0;
    for (var p = 0; p < template.length; p++) {
      final ch = template[p];
      if (ch != '%') {
        out.write(ch);
        continue;
      }
      if (p + 1 < template.length && template[p + 1] == '%') {
        out.write('%');
        p++;
        continue;
      }
      final m = RegExp(r'^%(\.\d+)?[sdf]').firstMatch(template.substring(p));
      if (m == null) {
        out.write(ch);
        continue;
      }
      final spec = m.group(0)!;
      final a = i < args.length ? args[i++] : '';
      if (spec.endsWith('f')) {
        final prec = m.group(1);
        final digits =
            prec == null ? 6 : (int.tryParse(prec.substring(1)) ?? 0);
        final v = double.tryParse('$a') ?? 0.0;
        out.write(v.toStringAsFixed(digits));
      } else if (spec.endsWith('d')) {
        out.write(int.tryParse('$a') ?? 0);
      } else {
        out.write('$a');
      }
      p += spec.length - 1;
    }
    return out.toString();
  }

  /// 中文「今天 HH:MM」/ 别的日子「MM月dd日 HH:MM」；英文 Today / Mon dd。
  static String fmtTime(DateTime dt, bool isToday) {
    String two(int v) => v.toString().padLeft(2, '0');
    final hm = '${two(dt.hour)}:${two(dt.minute)}';
    if (zh) {
      return isToday ? '今天 $hm' : '${two(dt.month)}月${two(dt.day)}日 $hm';
    }
    const mon = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return isToday ? 'Today $hm' : '${mon[dt.month - 1]} ${two(dt.day)}, $hm';
  }
}

String t(String key, [List<Object?> args = const []]) {
  final table = _lang == 'en' ? _enTable : _zhTable;
  final v = table[key] ?? '⟦$key⟧';
  return Lang.fmt(v, args);
}
