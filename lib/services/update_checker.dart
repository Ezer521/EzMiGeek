// update_checker.dart —— 轻量级手动版本检查（仅在用户点击托盘「检查更新」时联网）。
//
// 严格遵守隐私承诺：后台不主动请求任何非小米域名，仅在用户主动触发时
// 访问 GitHub Releases API 对比语义化版本号。
library;

import 'dart:convert';
import 'dart:io';

import '../core/i18n.dart';
import '../native/win32.dart' show openFileWithDefaultApp;
import 'app_log.dart';
import 'dialogs.dart';

const String kGitHubReleasesApi =
    'https://api.github.com/repos/Ezer521/EzMiGeek/releases/latest';
const String kGitHubReleasesPage =
    'https://github.com/Ezer521/EzMiGeek/releases/latest';

/// 语义化版本对比：若 [latest] 严格高于 [current] 返回 true。
/// 兼容前导 `v` 与 `+build` 后缀（例如 `v3.1.0` vs `3.0.6+1`）。
bool isNewerVersion(String latest, String current) {
  List<int> parse(String raw) {
    final cleaned = raw.trim().replaceFirst(RegExp(r'^[vV]'), '').split('+').first.split('-').first;
    final parts = cleaned.split('.');
    return List<int>.generate(
      3,
      (i) => i < parts.length ? (int.tryParse(parts[i]) ?? 0) : 0,
    );
  }

  final a = parse(latest);
  final b = parse(current);
  for (var i = 0; i < 3; i++) {
    if (a[i] != b[i]) return a[i] > b[i];
  }
  return false;
}

Future<void> checkForUpdatesInteractive(String currentVersion) async {
  AppLog.write('手动检查更新（当前版本 v$currentVersion）…');
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final req = await client
        .getUrl(Uri.parse(kGitHubReleasesApi))
        .timeout(const Duration(seconds: 8));
    req.headers.set('User-Agent', 'EzMiGeek/$currentVersion');
    req.headers.set('Accept', 'application/vnd.github+json');
    final resp = await req.close().timeout(const Duration(seconds: 8));
    final body = await resp
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 8));
    if (resp.statusCode != 200) {
      throw HttpException('HTTP ${resp.statusCode}');
    }
    final j = jsonDecode(body);
    if (j is! Map) throw const FormatException('返回内容不是 JSON 对象');
    final tag = '${j['tag_name'] ?? ''}'.trim();
    final url = '${j['html_url'] ?? kGitHubReleasesPage}'.trim();
    final cleanTag = tag.replaceFirst(RegExp(r'^[vV]'), '');
    if (cleanTag.isEmpty) throw const FormatException('未找到版本号');
    if (isNewerVersion(cleanTag, currentVersion)) {
      AppLog.write('检查更新：发现新版本 v$cleanTag（当前 v$currentVersion）');
      final open = confirmYesNo(
        t('upd.title'),
        t('upd.found', [cleanTag, currentVersion]),
      );
      if (open) {
        openFileWithDefaultApp(url.startsWith('https://') ? url : kGitHubReleasesPage);
      }
    } else {
      AppLog.write('检查更新：当前已是最新（当前 v$currentVersion，远程 v$cleanTag）');
      messageInfo(t('upd.title'), t('upd.latest', [currentVersion]));
    }
  } catch (e) {
    AppLog.write('检查更新失败：$e');
    messageInfo(t('upd.title'), t('upd.fail', ['$e']));
  } finally {
    client.close(force: true);
  }
}
