// code_service_test.dart —— 本地取码服务回归钉。
//
// 真回环 HTTP（127.0.0.1 随机端口）+ 注入 fetcher，不打真云：
//   · ipc.json 发现文件形态（port/token/pid）
//   · /ping 与未知路由、token 拒绝（403）
//   · /code 成功 / 失败（needLogin 判定）hub+did 透传
//   · stop() 关服务并清发现文件

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ezmigeek_flutter/services/code_service.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ezmg-code-svc-');
  });
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<Map<String, Object?>> httpGet(
      int port, String path, String token,
      [Map<String, String>? extra]) async {
    final uri = Uri.http('127.0.0.1:$port', path, {...?extra, 'token': token});
    final c = HttpClient();
    try {
      final req = await c.getUrl(uri);
      final resp = await req.close();
      final raw = await resp.transform(utf8.decoder).join();
      return {
        'status': resp.statusCode,
        'body': raw.isEmpty ? <String, Object?>{} : jsonDecode(raw),
      };
    } finally {
      c.close();
    }
  }

  test('ipc.json 形态：port/token/pid 齐全，ping 通', () async {
    final svc = CodeService(dirOverride: tmp.path, fetcher: (_, _) async => '123456');
    final port = await svc.start();
    expect(port, isNotNull);
    final ipc = jsonDecode(
        File('${tmp.path}\\ipc.json').readAsStringSync()) as Map;
    expect(ipc['port'], port);
    expect('${ipc['token']}'.length, 64);
    expect(ipc['pid'], isNotNull);
    final r = await httpGet(port!, '/ping', svc.token);
    expect(r['status'], 200);
    expect((r['body'] as Map)['ok'], isTrue);
    await svc.stop();
  });

  test('token 不对 → 403；未知路由 → 404', () async {
    final svc = CodeService(dirOverride: tmp.path, fetcher: (_, _) async => '123456');
    final port = (await svc.start())!;
    final r403 = await httpGet(port, '/code', 'wrong-token', {'hub': '1.2.3.4'});
    expect(r403['status'], 403);
    final c = HttpClient();
    final req = await c.getUrl(Uri.parse(
        'http://127.0.0.1:$port/nope?token=${svc.token}'));
    final resp = await req.close();
    await resp.drain();
    expect(resp.statusCode, 404);
    c.close();
    await svc.stop();
  });

  test('/code 成功：hub 与 did 透传给 fetcher，返回 6 位码', () async {
    String? gotHub, gotDid;
    final svc = CodeService(
      dirOverride: tmp.path,
      fetcher: (hub, did) async {
        gotHub = hub;
        gotDid = did;
        return '654321';
      },
    );
    final port = (await svc.start())!;
    final r = await httpGet(port, '/code', svc.token, {'hub': '192.168.31.1', 'did': '1177911635'});
    expect(r['status'], 200);
    final body = r['body'] as Map;
    expect(body['ok'], isTrue);
    expect(body['code'], '654321');
    expect(gotHub, '192.168.31.1');
    expect(gotDid, '1177911635');
    await svc.stop();
  });

  test('/code 失败：登录失效类错误 → needLogin=true', () async {
    final svc = CodeService(
      dirOverride: tmp.path,
      fetcher: (_, _) async => throw Exception('小米登录已失效或需要验证，请重新登录一次：code=401'),
    );
    final port = (await svc.start())!;
    final r = await httpGet(port, '/code', svc.token, {'hub': '192.168.31.1'});
    final body = r['body'] as Map;
    expect(body['ok'], isFalse);
    expect(body['needLogin'], isTrue);
    await svc.stop();
  });

  test('/code 缺参数 → ok=false 且不调 fetcher', () async {
    var called = 0;
    final svc = CodeService(
      dirOverride: tmp.path,
      fetcher: (_, _) async {
        called++;
        return '000000';
      },
    );
    final port = (await svc.start())!;
    final r = await httpGet(port, '/code', svc.token);
    final body = r['body'] as Map;
    expect(body['ok'], isFalse);
    expect(body['error'], contains('hub'));
    expect(called, 0);
    await svc.stop();
  });

  test('stop()：端口不再应答，ipc.json 已删', () async {
    final svc = CodeService(dirOverride: tmp.path, fetcher: (_, _) async => '123456');
    final port = (await svc.start())!;
    await svc.stop();
    expect(File('${tmp.path}\\ipc.json').existsSync(), isFalse);
    final c = HttpClient();
    try {
      final req = await c.getUrl(
          Uri.parse('http://127.0.0.1:$port/ping?token=${svc.token}'));
      await req.close();
      fail('端口应该已经关了');
    } on SocketException {
      // 预期：连接被拒
    } finally {
      c.close();
    }
  });
}
