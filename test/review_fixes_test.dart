// review_fixes_test.dart —— 2026-10-06 审查修复轮的回归钉。
//
// 覆盖：agent.js 的 origin 绑定与去双击、字表新词条、取码被拒判据、
// 云接口整体超时与退出取消。AppState 的暂停闸（转人工）依赖真浏览器/CDP，
// 单测环境搭不起来，靠日志口径 + 这几张纯函数钉守住外围。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ezmigeek_flutter/core/i18n.dart';
import 'package:ezmigeek_flutter/mijia/mijia_cloud.dart'
    show
        authFailed,
        cancelCloudRequests,
        cloudClient,
        disposeCloudClient,
        withCloudDeadline;
import 'package:ezmigeek_flutter/mijia/passcode.dart' show authRejectedMessage;
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
}
