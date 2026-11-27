// onboard_service.dart —— 首次登录 / 重新登录小米账号引导流程。
//
// 职责：导航至小米账号官方登录页，通过浏览器级 CDP 轮询读取凭据 Cookie，
// 严格校验 Cookie 归属域名（仅认 .xiaomi.com / .mi.com），合并并经 DPAPI
// 加密落盘；写盘失败时返回内存凭据供本会话兜底。
library;

import 'dart:convert';

import '../browser/browser_ctl.dart';
import '../cdp/cdp.dart';
import '../core/app_dirs.dart';
import '../core/i18n.dart';
import '../mijia/passcode.dart' show loadCfg, requiredCredKeys, saveCfg;
import 'dialogs.dart';

/// 判断 Cookie 域名是否归属小米官方域（防止误点第三方 OAuth 页面被同名 cookie 污染）。
bool isXiaomiCookieDomain(String domain) {
  final d = domain.trim().toLowerCase();
  if (d.isEmpty) return false;
  return d == 'xiaomi.com' ||
      d.endsWith('.xiaomi.com') ||
      d == 'mi.com' ||
      d.endsWith('.mi.com');
}

/// 从浏览器全量 Cookie 中提取小米官方域的必需凭据字段。
Map<String, Object?> extractXiaomiCredsFromCookies(
  List<Map<String, Object?>> cookies,
) {
  final got = <String, Object?>{};
  for (final c in cookies) {
    final domain = '${c['domain'] ?? ''}';
    if (!isXiaomiCookieDomain(domain)) continue;
    final name = '${c['name'] ?? ''}';
    final value = '${c['value'] ?? ''}';
    if (requiredCredKeys.contains(name) && value.isNotEmpty) {
      got[name] = value;
    }
  }
  return got;
}

/// 生成替换小米回调页空白 "ok" 的友好过渡引导页脚本（纯 DOM 构建，兼容 text/plain 与严格 CSP）。
String buildOnboardTransitionScript({
  required bool zh,
  bool isRelogin = false,
}) {
  final title = zh
      ? (isRelogin ? '小米账号重新登录成功' : '小米账号登录成功')
      : (isRelogin ? 'Mi Account Re-authenticated' : 'Mi Account Signed In');
  final subtitle = zh
      ? (isRelogin
            ? '新凭据已加密保存至本机，此窗口即将自动关闭，请返回 EzMiGeek 面板继续使用。'
            : '凭据已加密保存至本机，正在为您自动跳转到「米家自动化极客版」并填入登录码…')
      : (isRelogin
            ? 'New credentials saved locally. This window will close automatically.'
            : 'Credentials saved locally. Navigating to Mi Geek to auto-fill your login code…');
  final tip = zh
      ? (isRelogin
            ? '请稍候，无需手动操作'
            : '请保持此浏览器窗口打开，不要关闭（首次跳转可能需要数秒）')
      : (isRelogin
            ? 'Please wait — closing automatically'
            : 'Keep this browser window open — first redirect may take a few seconds');
  return '''
(() => {
  try {
    document.title = ${jsonEncode('EzMiGeek · $title')};
    const root = document.body || document.documentElement;
    if (!root) return false;
    root.innerHTML = '';
    root.style.cssText = 'margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;background:linear-gradient(135deg,#dcecff 0%,#edf5ff 48%,#efe3fb 100%);font-family:-apple-system,"PingFang SC","Microsoft YaHei UI",sans-serif;color:#0b1a3a;';
    const card = document.createElement('div');
    card.style.cssText = 'max-width:520px;width:calc(100% - 48px);padding:36px 32px;border-radius:22px;background:rgba(255,255,255,0.86);box-shadow:0 18px 48px rgba(18,48,95,0.12);border:1.5px solid rgba(255,255,255,0.95);text-align:center;';
    const badge = document.createElement('div');
    badge.textContent = '✓';
    badge.style.cssText = 'width:58px;height:58px;line-height:58px;margin:0 auto 18px;border-radius:50%;background:linear-gradient(180deg,#379cfc,#1a7af5);color:#fff;font-size:30px;font-weight:700;box-shadow:0 8px 20px rgba(26,122,245,0.28);';
    const h1 = document.createElement('div');
    h1.textContent = ${jsonEncode(title)};
    h1.style.cssText = 'font-size:24px;font-weight:700;margin-bottom:12px;color:#020c32;';
    const p = document.createElement('div');
    p.textContent = ${jsonEncode(subtitle)};
    p.style.cssText = 'font-size:15px;line-height:1.7;color:#243a5c;margin-bottom:20px;';
    const pill = document.createElement('div');
    pill.textContent = ${jsonEncode(tip)};
    pill.style.cssText = 'display:inline-block;padding:10px 16px;border-radius:12px;background:rgba(26,122,245,0.10);color:#124aa3;font-size:13.5px;font-weight:600;line-height:1.5;';
    card.appendChild(badge);
    card.appendChild(h1);
    card.appendChild(p);
    card.appendChild(pill);
    root.appendChild(card);
    return true;
  } catch (_) {
    return false;
  }
})()
''';
}

/// 执行登录引导。返回 (凭据, 是否成功写盘)；返回 null 表示登录未完成或超时。
Future<({Map<String, Object?> creds, bool saved})?> runOnboardSetup(
  CdpTab tab,
  Launched launched, {
  required void Function(Object?) log,
  void Function(String key, List<Object?> args)? onInfo,
  void Function()? onWaitingLogin,
  void Function()? onSignedIn,
  bool isRelogin = false,
  bool Function()? isQuitting,
}) async {
  log('=' * 60);
  log(' 请在弹出的浏览器窗口里用小米账号登录。');
  log(' 登录完成后页面若短暂显示空白 "ok" 属正常现象，请勿关闭窗口。');
  log(' 程序会自动保存凭据并继续，请让这个窗口一直开着。');
  log('=' * 60);
  if (!isRelogin) {
    messageInfo(t('ob.title'), t('ob.text'));
  }
  onWaitingLogin?.call();

  await tab.cmd(
    'Page.navigate',
    params: {
      'url':
          'https://account.xiaomi.com/pass/serviceLogin'
          '?sid=xiaomiio&_locale=zh_CN',
    },
  );
  log('已打开小米账号登录页，等待登录…');

  final wsUrl = await browserWsUrl(launched.port);
  final sess = BrowserSession(wsUrl);
  await sess.waitReady();

  final t0 = DateTime.now();
  var dead = 0;
  var tick = DateTime.now();
  try {
    while (true) {
      if (isQuitting?.call() == true) {
        log('★ 收到退出请求，停止等待登录。');
        return null;
      }
      await Future<void>.delayed(const Duration(milliseconds: 800));
      if (!await launched.alive()) {
        log('★ 浏览器进程已退出，停止等待登录。');
        return null;
      }
      final elapsed = DateTime.now().difference(t0);
      if (elapsed.inSeconds > 300) {
        log('★ 等待登录超时（300 秒），放弃。');
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
          log('★ 浏览器已经关闭，停止等待登录。');
          return null;
        }
        continue;
      }
      dead = 0;

      final got = extractXiaomiCredsFromCookies(cookies);
      if (got.containsKey('passToken') && !got.containsKey('deviceId')) {
        got['deviceId'] = DateTime.now()
            .microsecondsSinceEpoch
            .toRadixString(16)
            .toUpperCase();
        log('  提示：cookie 里没有 deviceId，已生成一个占位标识。');
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
        final saved = saveCfg(merged);
        if (saved) {
          log('✓ 凭据已就绪（DPAPI 加密存到 ${credsPath()}）');
        } else {
          log('× 凭据写盘失败！本轮先用内存凭据继续，请检查数据目录权限。');
          onInfo?.call('info.credsavefail', [credsPath()]);
        }
        // 立刻中止小米回调页（空白 "ok"）残留请求，并替换成清晰的中文/英文过渡提示页，
        // 避免用户在自动跳转到极客版期间对着空白 "ok" 转圈不知所措。
        try {
          await tab.cmd('Page.stopLoading');
          await tab.js(
            buildOnboardTransitionScript(zh: Lang.zh, isRelogin: isRelogin),
          );
        } catch (_) {}
        onSignedIn?.call();
        await Future<void>.delayed(
          Duration(milliseconds: isRelogin ? 900 : 120),
        );
        return (creds: merged, saved: saved);
      }
      if (DateTime.now().difference(tick).inSeconds > 10) {
        tick = DateTime.now();
        log('  …等待登录中（${elapsed.inSeconds} 秒）｜还缺 ${missing.join(", ")}');
      }
    }
  } finally {
    sess.close();
  }
}
