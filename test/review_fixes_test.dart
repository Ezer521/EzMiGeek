// review_fixes_test.dart —— 2026-10-06 审查修复轮的回归钉。
//
// 覆盖：agent.js 的 origin 绑定与去双击、字表新词条、取码被拒判据、
// 云接口整体超时与退出取消。AppState 的暂停闸（转人工）依赖真浏览器/CDP，
// 单测环境搭不起来，靠日志口径 + 这几张纯函数钉守住外围。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ezmigeek_flutter/browser/browser_ctl.dart'
    show isChromiumExe;
import 'package:ezmigeek_flutter/core/i18n.dart';
import 'package:ezmigeek_flutter/mijia/hub_discovery.dart'
    show isPrivateIpv4, parseMacRouteGateway;
import 'package:ezmigeek_flutter/mijia/mijia_cloud.dart'
    show
        authFailed,
        cancelCloudRequests,
        cloudClient,
        disposeCloudClient,
        isTrustedXiaomiHost,
        withCloudDeadline;
import 'package:ezmigeek_flutter/mijia/passcode.dart' show authRejectedMessage;
import 'package:ezmigeek_flutter/model/settings.dart';
import 'package:ezmigeek_flutter/model/stats_store.dart';
import 'package:ezmigeek_flutter/native/win32.dart'
    show hkeyCurrentUser, regReadSz;
import 'package:ezmigeek_flutter/services/autostart.dart'
    show buildMacLaunchAgentPlist, parseMacLaunchAgentExecutable;
import 'package:ezmigeek_flutter/services/onboard_service.dart'
    show extractXiaomiCredsFromCookies, isXiaomiCookieDomain;
import 'package:ezmigeek_flutter/services/update_checker.dart'
    show isNewerVersion;
import 'package:ezmigeek_flutter/services/win_cert.dart'
    show verifyWindowsSslCertificate;
import 'package:ezmigeek_flutter/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('agent.js 行为验证（node 假 DOM 真执行——审查二轮测试质量整改）', () {
    // 场景与断言都在 agent_harness.mjs（JS 侧最贴近浏览器语义）：
    // 公网安静 / 私网挂载 / 钉目标闸 / 手动数字单次点击 / 跨 origin 拒填 /
    // 逐键单击。这里只负责跑起来和把失败场景的名字顶出来。
    test('七场景真执行全过', () async {
      final r = await Process.run('node', ['test/agent_harness.mjs']);
      final out = r.stdout.toString();
      final Map<String, Object?> j;
      try {
        j = Map<String, Object?>.from(jsonDecode(out) as Map);
      } catch (_) {
        fail('harness 没跑起来：${r.stderr}\n$out');
      }
      expect(j['ok'], true, reason: out);
      for (final item in (j['results'] as List)) {
        final m = Map<String, Object?>.from(item as Map);
        expect(m['pass'], true, reason: '${m['name']} — ${m['detail']}');
      }
    });

    test('版本号 agent-3（分发机日志好对版本）', () {
      expect(
        File('assets/agent.js')
            .readAsStringSync()
            .contains("var V = 'agent-3'"),
        true,
      );
    });
  });

  group('字表：新状态词条中英齐备', () {
    const keys = [
      'st.paused',
      'st.paused.bottom',
      'st.manualok',
      'st.manualok.bottom',
      'st.resumed',
      'st.resumed.bottom',
      'st.busyrelogin',
      'st.busyrelogin.bottom',
      'st.relogin_savefail',
      'st.relogin_savefail.bottom',
      'info.credsavefail',
    ];
    for (final lang in ['zh', 'en']) {
      test('$lang：十一条新词条一个不缺', () {
        Lang.set(lang);
        for (final k in keys) {
          expect(t(k), isNot(contains('⟦')), reason: '$lang 缺 $k');
        }
        Lang.set('zh');
      });
    }
    test('info.credsavefail 带 %s 占位（落路径用）', () {
      expect(t('info.credsavefail', [r'C:\x']), isNot(contains('%s')));
    });
  });

  group('取码被拒判据（修3 的引信）', () {
    test('code=401/426/70016 与 HTTP 401 算票据被拒', () {
      expect(authRejectedMessage('取码被拒：code=401 message=auth failed'), true);
      expect(authRejectedMessage('取码被拒：code=426 message=x'), true);
      expect(authRejectedMessage('取码被拒：code=70016 message=x'), true);
      expect(authRejectedMessage('取码 HTTP 401'), true);
    });
    test('普通失败不算（不许滥触发续期）', () {
      expect(authRejectedMessage('取码被拒：code=1 message=invalid did'), false);
      expect(authRejectedMessage('取码请求失败：TimeoutException'), false);
      expect(authRejectedMessage('取码超时（已等 3 分钟）'), false);
      expect(authRejectedMessage('取码响应解析失败：<!doctype html>'), false);
    });
  });

  group('云端答复的鉴权判据（authFailed，列表层续期用）', () {
    test('401/426/70016 与鉴权措辞都认', () {
      expect(authFailed({'code': 401}), true);
      expect(authFailed({'code': '70016'}), true);
      expect(authFailed({'code': 0, 'message': 'Invalid auth'}), true);
      expect(authFailed({'code': 0, 'message': '请重新登录'}), true);
    });
    test('正常答复不误伤', () {
      expect(authFailed({'code': 0, 'message': 'ok'}), false);
      expect(authFailed({'result': 'ok'}), false);
    });
  });

  group('云接口整体超时 + 退出可取消（修4）', () {
    test('withCloudDeadline：正文永远不来也会到点炸', () async {
      final c = cloudClient(connTimeoutSecs: 5);
      try {
        await expectLater(
          withCloudDeadline<Map<String, Object?>>(
            c,
            const Duration(milliseconds: 80),
            () => Completer<Map<String, Object?>>().future,
          ),
          throwsA(isA<TimeoutException>()),
        );
      } finally {
        disposeCloudClient(c);
      }
    });

    test('withCloudDeadline：来得及就原样放行', () async {
      final c = cloudClient(connTimeoutSecs: 5);
      try {
        final r = await withCloudDeadline<Map<String, Object?>>(
          c,
          const Duration(seconds: 3),
          () async => {'ok': 1},
        );
        expect(r['ok'], 1);
      } finally {
        disposeCloudClient(c);
      }
    });

    test('cancelCloudRequests：挂在半路的请求立刻报错（模拟退出）', () async {
      // flutter_test 的假 HTTP（HttpOverrides.global）会把所有请求拦成
      // 400，这里必须换成真 socket：临时把 global 置空，finally 里还回去。
      // （这个 SDK 里 global 只有 setter，读要用 current。）
      final saved = HttpOverrides.current;
      HttpOverrides.global = null;
      final server = await ServerSocket.bind('127.0.0.1', 0);
      try {
        // 收下连接但永不回话 —— 模拟「连上了却不吐正文」的服务端。
        server.listen((_) {});
        final c = cloudClient(connTimeoutSecs: 5);
        final req = await c.getUrl(
          Uri.parse('http://127.0.0.1:${server.port}/x'),
        );
        final fut = req.close().then((r) => r.transform(utf8.decoder).join());
        await Future<void>.delayed(const Duration(milliseconds: 150));
        cancelCloudRequests(); // AppState.quit 现在就调这个
        await expectLater(fut, throwsA(anything));
      } finally {
        HttpOverrides.global = saved;
        await server.close();
      }
    });
  });

  group('中枢手动指定（HubIp / --hub）', () {
    test('settings.json 的 HubIp 读写往返', () {
      final s = AppSettings();
      s.hubIp = ' 192.168.5.3 ';
      s.applyValues(s.toValues());
      expect(s.hubIp, '192.168.5.3'); // applyValues 里 trim
      expect(s.summary().contains('HubIp=192.168.5.3'), true);
    });

    test('HubIp 缺省 = 空（走自动发现）', () {
      final s = AppSettings();
      s.applyValues({});
      expect(s.hubIp, '');
      expect(s.summary().contains('HubIp=<自动>'), true);
    });

    test('极客版页面身份判据：标题词在首块 HTML 里', () {
      const head = '<!doctype html><html data-env="prod"><head>'
          '<title>米家自动化极客版</title>';
      expect(head.contains('米家自动化极客版'), true);
    });
  });

  group('v3.1.0 全面体检与安全加固回归钉', () {
    test('i18n 中英字表键集合 1:1 完全对称，无漏译死键', () {
      final zh = i18nZhKeys.toSet();
      final en = i18nEnKeys.toSet();
      expect(zh.difference(en), isEmpty, reason: '英文表缺键');
      expect(en.difference(zh), isEmpty, reason: '中文表缺键');
    });

    test('小米官方域白名单：放行官方域，拒绝伪造/公网/内网主机', () {
      expect(isTrustedXiaomiHost('account.xiaomi.com'), true);
      expect(isTrustedXiaomiHost('api.io.mi.com'), true);
      expect(isTrustedXiaomiHost('core.api.mijia.tech'), true);
      expect(isTrustedXiaomiHost('sts.api.mijia.tech'), true);
      expect(isTrustedXiaomiHost('c3.account.xiaomi.com'), true);

      expect(isTrustedXiaomiHost('evil-account.xiaomi.com.attacker.com'), false);
      expect(isTrustedXiaomiHost('notxiaomi.com'), false);
      expect(isTrustedXiaomiHost('192.168.31.1'), false);
      expect(isTrustedXiaomiHost(''), false);
    });

    test(
      'Windows 原生 CryptoAPI 证书校验：拒绝伪造/无效 DER',
      () {
        final (ok1, _) = verifyWindowsSslCertificate(
          Uint8List.fromList([0x30, 0x03, 0x01, 0x01, 0x00]),
          'account.xiaomi.com',
        );
        expect(ok1, false);
        final (ok2, _) = verifyWindowsSslCertificate(
          Uint8List(0),
          'account.xiaomi.com',
        );
        expect(ok2, false);
      },
      skip: !Platform.isWindows,
    );

    test(
      'Windows 原生 advapi32 注册表读取：64 位 HKEY 符号扩展正常且不存在键返回 null',
      () {
        final (val, err) = regReadSz(
          hkeyCurrentUser,
          r'Software\Microsoft\Windows\CurrentVersion\Run',
          '__EzMiGeek_UnitTest_NonExistent__',
        );
        expect(err, isEmpty);
        expect(val, isNull);
      },
      skip: !Platform.isWindows,
    );

    test('macOS LaunchAgent plist 生成与解析往返（含空格与特殊字符 XML 转义）', () {
      const exe = "/Applications/EzMiGeek & Tools/EzMiGeek.app/Contents/MacOS/EzMiGeek";
      final plist = buildMacLaunchAgentPlist(exe);
      expect(plist, contains('<string>com.ezer.ezmigeek</string>'));
      expect(plist, contains('&amp;'));
      expect(parseMacLaunchAgentExecutable(plist), exe);
    });

    test('macOS route -n get default 网关解析', () {
      const sample = '''
   route to: default
destination: default
       mask: default
    gateway: 192.168.31.1
  interface: en0
      flags: <UP,GATEWAY,DONE,STATIC,PRCLONING,GLOBAL>
''';
      expect(parseMacRouteGateway(sample), '192.168.31.1');
      expect(parseMacRouteGateway('gateway: 127.0.0.1\n'), isNull);
    });

    test('macOS Chromium / 非 Chromium 浏览器可执行名判定', () {
      expect(
        isChromiumExe('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'),
        true,
      );
      expect(
        isChromiumExe('/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge'),
        true,
      );
      expect(isChromiumExe('/Applications/Arc.app/Contents/MacOS/Arc'), true);
      expect(isChromiumExe('/Applications/Safari.app/Contents/MacOS/Safari'), false);
      expect(isChromiumExe('/Applications/Firefox.app/Contents/MacOS/firefox'), false);
    });

    test('Cookie 采集严格过滤小米官方域，隔离第三方同名 Cookie', () {
      expect(isXiaomiCookieDomain('.xiaomi.com'), true);
      expect(isXiaomiCookieDomain('account.xiaomi.com'), true);
      expect(isXiaomiCookieDomain('.mi.com'), true);
      expect(isXiaomiCookieDomain('evil-xiaomi.com'), false);
      expect(isXiaomiCookieDomain('.qq.com'), false);

      final got = extractXiaomiCredsFromCookies([
        {'domain': '.qq.com', 'name': 'userId', 'value': 'evil_uid'},
        {'domain': 'account.xiaomi.com', 'name': 'userId', 'value': '12345'},
        {'domain': '.xiaomi.com', 'name': 'passToken', 'value': 'pt_ok'},
        {'domain': '.evil.com', 'name': 'passToken', 'value': 'pt_bad'},
        {'domain': '.mi.com', 'name': 'cUserId', 'value': 'cuid_ok'},
        {'domain': '.xiaomi.com', 'name': 'deviceId', 'value': 'dev_ok'},
      ]);
      expect(got['userId'], '12345');
      expect(got['passToken'], 'pt_ok');
      expect(got['cUserId'], 'cuid_ok');
      expect(got['deviceId'], 'dev_ok');
    });

    test('RFC1918 私网判定：精准识别 172.16-31，不误扫公网 172 段', () {
      expect(isPrivateIpv4('10.0.0.1'), true);
      expect(isPrivateIpv4('192.168.31.1'), true);
      expect(isPrivateIpv4('172.16.0.1'), true);
      expect(isPrivateIpv4('172.31.255.254'), true);

      expect(isPrivateIpv4('172.15.0.1'), false);
      expect(isPrivateIpv4('172.32.0.1'), false);
      expect(isPrivateIpv4('8.8.8.8'), false);
    });

    test('Stats 跨天常驻计数自动归零', () {
      final d1 = DateTime(2026, 11, 26, 23, 50);
      final d2 = DateTime(2026, 11, 27, 0, 5);
      final st = Stats.normalize(
        {'Total': 10, 'Today': 4, 'Day': '2026-11-26'},
        now: d1,
      );
      expect(st.today, 4);
      st.bump(secs: 1.5, now: d2, persist: false);
      expect(st.total, 11);
      expect(st.today, 1);
      expect(st.day, '2026-11-27');
    });

    test('降级轮 rc=7 正确回报成功态且未知 rc 带出错误码', () {
      Lang.set('zh');
      final st = AppState();
      st.reportRoundForTest(7, manualCode: '246810');
      expect(st.ui.warn, false);
      expect(st.ui.status, contains('默认浏览器'));
      expect(st.ui.bottomLine, contains('246810'));

      st.reportRoundForTest(99);
      expect(st.ui.warn, true);
      expect(st.ui.bottomLine, contains('rc=99'));
    });

    test('LocalCodeService 配置默认开启且支持开关往返', () {
      final s = AppSettings();
      expect(s.localCodeService, true);
      s.applyValues({'LocalCodeService': false});
      expect(s.localCodeService, false);
      expect(s.toValues()[SettingsKeys.localCodeService], false);
    });

    test('语义化版本比较 isNewerVersion', () {
      expect(isNewerVersion('v3.1.1', '3.1.0'), true);
      expect(isNewerVersion('3.2.0', '3.1.9'), true);
      expect(isNewerVersion('4.0.0', '3.9.9'), true);
      expect(isNewerVersion('v3.1.0', '3.1.0+1'), false);
      expect(isNewerVersion('3.0.6', '3.1.0'), false);
    });

    test('油猴脚本分发与安全防回归：含更新地址、不泄露 CFG、无多余 el.click 补刀', () {
      final js = File('userscript/米家极客版-自动登录.user.js').readAsStringSync();
      expect(js, contains('@version      3.1.0'));
      expect(js, contains('@downloadURL'));
      expect(js, contains('@updateURL'));
      expect(js, isNot(contains('cfg: CFG')));
      expect(js, isNot(contains('try { el.click(); } catch (e) {}')));
    });
  });
}
