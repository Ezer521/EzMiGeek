// stale.dart —— 「小米登录已失效」判据（app/relogin.py 的 is_stale 移植）。
//
// 判据取自实机证据（Python 版模块头）：小米云在登录态失效时的那句话
// 「小米登录已失效或需要验证」同时出现在两个母本模块里（取登录码.py 与
// mijia_cloud.py）。这里按子串匹配，不改写、不翻译。
//
// ★ 只认**确定的信号**：网络不通、DNS 失败、中枢离线都会在取码链路上冒
//   出来，把它们误报成"登录过期"会让用户白白重登一次（重登是要人动手的，
//   代价远高于等 10 秒重试）。分不清的，一律当"这一轮失败"处理。
library;

const String _staleMark = '小米登录已失效或需要验证';

/// 换票结果里可能出现的「账号维度」错误码：401 未授权 / 426 需要升级或验证
/// / 70016 需要验证（与 mijia_cloud 的 AUTH_CODES 同源）。
const List<int> _authCodes = [401, 426, 70016];

bool isStale(Object? exc, [String text = '']) {
  var blob = exc == null ? '' : '$exc';
  blob = '$blob $text';
  if (blob.contains(_staleMark)) return true;
  // `result=error` 是换票失败的另一种写法（带不带中文都算）。
  final low = blob.toLowerCase();
  if (low.contains('result=error') &&
      (low.contains('passcodeerror') || low.contains('mijiaerror'))) {
    return true;
  }
  for (final c in _authCodes) {
    if (low.contains('code=$c') || low.contains('"$c"')) return true;
  }
  return false;
}
