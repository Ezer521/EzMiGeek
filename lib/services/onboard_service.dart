// onboard_service.dart —— 首次登录 / 重新登录小米账号引导流程。
//
// 职责：导航至小米账号官方登录页，通过浏览器级 CDP 轮询读取凭据 Cookie，
// 严格校验 Cookie 归属域名（仅认 .xiaomi.com / .mi.com），合并并经 DPAPI
// 加密落盘；写盘失败时返回内存凭据供本会话兜底。
library;

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

/// 执行登录引导。返回 (凭据, 是否成功写盘)；返回 null 表示登录未完成或超时。
Future<({Map<String, Object?> creds, bool saved})?> runOnboardSetup(
  CdpTab tab,
  Launched launched, {
  required void Function(Object?) log,
  void Function(String key, List<Object?> args)? onInfo,
  bool Function()? isQuitting,
}) async {
  log('=' * 60);
  log(' 请在弹出的浏览器窗口里用小米账号登录。');
  log(' 登录成功后窗口会自动跳到米家极客版并自动填入登录码。');
  log(' 请让这个窗口一直开着，不要关它。');
  log('=' * 60);
  messageInfo(t('ob.title'), t('ob.text'));

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
      await Future<void>.delayed(const Duration(seconds: 2));
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
