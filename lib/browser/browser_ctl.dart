// browser_ctl.dart —— 找浏览器、拉起、CDP 端口、窗口形态（app/browser.py 移植）。
//
// 关键决定（Python 版写进方案 §1 的那几条，原样继承）：
//   · --remote-debugging-port=0（随机端口）+ 读 <profile>\DevToolsActivePort
//   · 专用 --user-data-dir，绝不碰用户真实 profile
//   · 不启用 --disable-web-security（EDR 高危特征，且过不了 SameSite）
//   · 永远开【系统默认浏览器】：Chromium 系 → CDP 全自动填码；
//     不是 → 降级轮（开网页 + 取码复制剪贴板）
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../native/win32.dart'
    show hkeyClassesRoot, hkeyCurrentUser, regReadSz;

/// Windows 上按序找的知名浏览器路径。
final List<String> windowsCandidates = [
  r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
  r'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
  r'C:\Program Files\Google\Chrome\Application\chrome.exe',
  r'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
  r'%LOCALAPPDATA%\Google\Chrome\Application\chrome.exe',
  r'%LOCALAPPDATA%\Microsoft\Edge\Application\msedge.exe',
];

/// macOS 上按序查找的知名 Chromium 系浏览器可执行文件（直启二进制才能传入 CDP flags）。
final List<String> macCandidates = [
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
  '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser',
  '/Applications/Chromium.app/Contents/MacOS/Chromium',
  '/Applications/Vivaldi.app/Contents/MacOS/Vivaldi',
  '/Applications/Arc.app/Contents/MacOS/Arc',
  '/Applications/Opera.app/Contents/MacOS/Opera',
  '~/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '~/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
  '~/Applications/Brave Browser.app/Contents/MacOS/Brave Browser',
];

/// macOS 默认浏览器 Bundle ID 到可执行文件路径的常见映射。
const Map<String, List<String>> _macBundleToBins = {
  'com.google.chrome': [
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    '~/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  ],
  'com.microsoft.edgemac': [
    '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
    '~/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
  ],
  'com.brave.browser': [
    '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser',
    '~/Applications/Brave Browser.app/Contents/MacOS/Brave Browser',
  ],
  'org.chromium.chromium': [
    '/Applications/Chromium.app/Contents/MacOS/Chromium',
    '~/Applications/Chromium.app/Contents/MacOS/Chromium',
  ],
  'com.vivaldi.vivaldi': [
    '/Applications/Vivaldi.app/Contents/MacOS/Vivaldi',
    '~/Applications/Vivaldi.app/Contents/MacOS/Vivaldi',
  ],
  'company.thebrowser.browser': [
    '/Applications/Arc.app/Contents/MacOS/Arc',
    '~/Applications/Arc.app/Contents/MacOS/Arc',
  ],
  'com.operasoftware.opera': [
    '/Applications/Opera.app/Contents/MacOS/Opera',
    '~/Applications/Opera.app/Contents/MacOS/Opera',
  ],
  'com.apple.safari': [
    '/Applications/Safari.app/Contents/MacOS/Safari',
  ],
  'org.mozilla.firefox': [
    '/Applications/Firefox.app/Contents/MacOS/firefox',
    '~/Applications/Firefox.app/Contents/MacOS/firefox',
  ],
};

/// 判「默认浏览器能不能走 CDP」用的名单。
const Set<String> chromiumExeNames = {
  'msedge.exe',
  'chrome.exe',
  'chromium.exe',
  'brave.exe',
  'vivaldi.exe',
  'opera.exe',
  'yandex.exe',
  '360se.exe',
  '360chrome.exe',
  'qqbrowser.exe',
  'sogou_explorer.exe',
  'baidubrowser.exe',
  'google chrome',
  'microsoft edge',
  'brave browser',
  'chromium',
  'vivaldi',
  'opera',
  'arc',
};

const String _pidFile = '.launcher-pid';

extension StringLines on String {
  List<String> splitLines() =>
      split('\n')
          .map((l) => l.endsWith('\r') ? l.substring(0, l.length - 1) : l)
          .toList();
}

String expandEnv(String p) {
  var out = p;
  if (out.startsWith('~/')) {
    final home = Platform.environment['HOME'] ?? '';
    if (home.isNotEmpty) out = '$home${out.substring(1)}';
  }
  if (out.contains('%')) {
    out = out.replaceAllMapped(
      RegExp('%([^%]+)%'),
      (m) => Platform.environment[m.group(1)] ?? m.group(1)!,
    );
  }
  return out;
}

String? findBrowser() {
  final candidates = Platform.isWindows ? windowsCandidates : macCandidates;
  for (final p in candidates) {
    final exe = expandEnv(p);
    if (File(exe).existsSync()) return exe;
  }
  return null;
}

bool isChromiumExe(String? exe) {
  final name = (exe ?? '').replaceAll('\\', '/').split('/').last.toLowerCase();
  if (name.isEmpty) return false;
  return chromiumExeNames.contains(name) ||
      name.contains('chrom') ||
      name.contains('edge') ||
      name.contains('brave') ||
      name.contains('vivaldi') ||
      name.contains('opera');
}

(String?, List<String>) _macDefaultBrowser() {
  try {
    final home = Platform.environment['HOME'] ?? '';
    final plist =
        '$home/Library/Preferences/com.apple.LaunchServices/com.apple.launchservices.secure.plist';
    if (File(plist).existsSync()) {
      final r = Process.runSync(
        '/usr/bin/plutil',
        ['-convert', 'json', '-o', '-', plist],
        stdoutEncoding: utf8,
      );
      if (r.exitCode == 0) {
        final raw = jsonDecode(r.stdout.toString());
        if (raw is Map && raw['LSHandlers'] is List) {
          for (final scheme in ['https', 'http']) {
            for (final item in raw['LSHandlers'] as List) {
              if (item is Map &&
                  '${item['LSHandlerURLScheme'] ?? ''}'.toLowerCase() ==
                      scheme) {
                final bid = '${item['LSHandlerRoleAll'] ?? ''}'.toLowerCase();
                final bins = _macBundleToBins[bid];
                if (bins != null) {
                  for (final b in bins) {
                    final p = expandEnv(b);
                    if (File(p).existsSync()) return (p, const []);
                  }
                }
              }
            }
          }
        }
      }
    }
  } catch (_) {}
  return (null, const []);
}

/// 解析系统默认浏览器（http/https 关联）。
/// Windows 走原生 advapi32 注册表；macOS 解析 LaunchServices 默认协议处理器。
(String?, List<String>) defaultBrowser() {
  if (!Platform.isWindows) return _macDefaultBrowser();
  final (progId, _) = regReadSz(
    hkeyCurrentUser,
    r'Software\Microsoft\Windows\Shell\Associations\UrlAssociations\http\UserChoice',
    'ProgId',
  );
  if (progId == null || progId.trim().isEmpty) return (null, const []);
  final (cmd, _) = regReadSz(
    hkeyClassesRoot,
    '${progId.trim()}\\shell\\open\\command',
    '',
  );
  if (cmd == null || cmd.trim().isEmpty) return (null, const []);
  final (exe, args) = splitCommandLine(cmd);
  if (exe != null && !File(exe).existsSync()) return (null, const []);
  return (exe, args);
}

(String?, List<String>) splitCommandLine(String cmdRaw) {
  final cmd = cmdRaw.trim();
  if (cmd.isEmpty) return (null, const []);
  if (cmd.startsWith('"')) {
    final end = cmd.indexOf('"', 1);
    if (end < 0) return (null, const []);
    final exe = cmd.substring(1, end);
    final rest = cmd.substring(end + 1).trim();
    return (exe, _tokens(rest));
  }
  final sp = cmd.indexOf(' ');
  if (sp <= 0) return (cmd, const []);
  return (cmd.substring(0, sp), _tokens(cmd.substring(sp + 1).trim()));
}

List<String> _tokens(String rest) => rest
    .split(RegExp(r'\s+'))
    .map((t) => t.replaceAll('"', '').trim())
    .where((t) => t.isNotEmpty && t.toUpperCase() != '%1')
    .toList();

// ══════════════════ 进程查询 / 强杀（Windows FFI 惰性初始化）══════════════════

final DynamicLibrary _k32 = DynamicLibrary.open('kernel32.dll');

final int Function(int, int, int) _openProcess = _k32
    .lookupFunction<
      IntPtr Function(Uint32, Uint32, Uint32),
      int Function(int, int, int)
    >('OpenProcess');
final int Function(int, int) _terminateProcess = _k32
    .lookupFunction<Int32 Function(IntPtr, Uint32), int Function(int, int)>(
      'TerminateProcess',
    );
final int Function(int) _closeHandleK32 = _k32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
final int Function(int, int, Pointer<Uint16>, Pointer<Uint32>) _queryImageName =
    _k32.lookupFunction<
      Int32 Function(IntPtr, Uint32, Pointer<Uint16>, Pointer<Uint32>),
      int Function(int, int, Pointer<Uint16>, Pointer<Uint32>)
    >('QueryFullProcessImageNameW');

const int _processQueryLimitedInformation = 0x1000;
const int _processTerminate = 0x0001;

/// PID 活着就返回它的 exe 完整路径，否则返回空串。
String queryImage(int pid) {
  if (!Platform.isWindows) {
    try {
      final r = Process.runSync('/bin/ps', ['-p', '$pid', '-o', 'comm=']);
      return r.exitCode == 0 ? r.stdout.toString().trim() : '';
    } catch (_) {
      return '';
    }
  }
  final h = _openProcess(_processQueryLimitedInformation, 0, pid);
  if (h == 0) return '';
  final buf = malloc<Uint16>(1024);
  final size = malloc<Uint32>();
  try {
    size.value = 1024;
    if (_queryImageName(h, 0, buf, size) == 0) return '';
    return buf.cast<Utf16>().toDartString();
  } catch (_) {
    return '';
  } finally {
    malloc.free(buf);
    malloc.free(size);
    _closeHandleK32(h);
  }
}

/// 按 PID 强杀（不杀进程树，主进程死了 Chromium 子进程会自己退）。
bool killPid(int pid) {
  if (!Platform.isWindows) {
    return Process.killPid(pid, ProcessSignal.sigkill);
  }
  final h = _openProcess(_processTerminate, 0, pid);
  if (h == 0) return false;
  try {
    return _terminateProcess(h, 1) != 0;
  } finally {
    _closeHandleK32(h);
  }
}

int lastPid(String profileDir) =>
    int.tryParse(_readSmallFile('$profileDir/$_pidFile').trim()) ?? 0;

String _readSmallFile(String path) {
  try {
    return File(path).readAsStringSync();
  } catch (_) {
    return '';
  }
}

bool forgetFile(String path) {
  try {
    File(path).writeAsStringSync('', flush: true);
    return true;
  } catch (_) {
    return false;
  }
}

Future<int> killStale(String profileDir) async {
  final pid = lastPid(profileDir);
  if (pid == 0) return 0;
  final img = queryImage(pid);
  if (img.isEmpty) return 0;
  if (!isChromiumExe(img)) {
    return 0;
  }
  final ok = killPid(pid);
  if (ok) {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      if (queryImage(pid).isEmpty) break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
  forgetFile('$profileDir/$_pidFile');
  return ok ? pid : 0;
}

/// 兜底清场：优先通过 CDP 发送优雅 Browser.close；macOS 上失败时再按本专用
/// profile 精确匹配 `pkill -f` 兜底（绝不碰用户日常浏览器）。
Future<int> killProfileHolders(String profileDir) async {
  try {
    final f = File('$profileDir/DevToolsActivePort');
    if (f.existsSync()) {
      final lines = f.readAsStringSync().splitLines();
      if (lines.isNotEmpty) {
        final port = int.tryParse(lines.first.trim());
        if (port != null && await probePort(port)) {
          final j = await httpJson(
            port,
            '/json/version',
            timeout: const Duration(seconds: 2),
          );
          final wsUrl = '${j?['webSocketDebuggerUrl'] ?? ''}';
          if (wsUrl.isNotEmpty) {
            final ws = await WebSocket.connect(wsUrl)
                .timeout(const Duration(seconds: 2));
            try {
              ws.add(jsonEncode({'id': 1, 'method': 'Browser.close', 'params': {}}));
              await Future<void>.delayed(const Duration(milliseconds: 500));
            } finally {
              await ws.close();
            }
            return 1;
          }
        }
      }
    }
  } catch (_) {}
  if (!Platform.isWindows) {
    try {
      final needle = '--user-data-dir=${File(profileDir).absolute.path}';
      final r = await Process.run('/usr/bin/pkill', ['-9', '-f', needle]);
      return r.exitCode == 0 ? 1 : 0;
    } catch (_) {}
  }
  return 0;
}

Future<bool> probePort(
  int port, {
  String host = '127.0.0.1',
  Duration timeout = const Duration(milliseconds: 800),
}) async {
  try {
    final s = await Socket.connect(host, port, timeout: timeout);
    s.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

// ══════════════════ DevToolsActivePort / page target ══════════════════

/// --remote-debugging-port=0 → 真实端口写在 DevToolsActivePort 第一行。
Future<int?> devtoolsPort(String profileDir, DateTime deadline) async {
  final f = '$profileDir/DevToolsActivePort';
  while (DateTime.now().isBefore(deadline)) {
    try {
      final file = File(f);
      if (file.existsSync()) {
        final lines = file.readAsStringSync().splitLines();
        if (lines.isNotEmpty) {
          final port = int.tryParse(lines.first.trim());
          if (port != null && await probePort(port)) {
            return port;
          }
        }
      }
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return null;
}

const Utf8Decoder _utf8 = Utf8Decoder(allowMalformed: true);

Future<Map<String, Object?>?> httpJson(
  int port,
  String path, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final c = HttpClient()..findProxy = null; // 绕开宿主 http_proxy
  c.connectionTimeout = timeout;
  try {
    final req = await c.getUrl(Uri.parse('http://127.0.0.1:$port$path'));
    final resp = await req.close();
    final text = await resp.transform(_utf8).join();
    final j = jsonDecode(text);
    if (j is Map) return Map<String, Object?>.from(j);
  } catch (_) {
  } finally {
    c.close(force: true);
  }
  return null;
}

Future<String> browserWsUrl(int port) async {
  final j = await httpJson(port, '/json/version');
  final url = '${j?['webSocketDebuggerUrl'] ?? ''}';
  if (url.isEmpty) {
    throw StateError('浏览器没暴露 webSocketDebuggerUrl（CDP 端口 $port）');
  }
  return url;
}

/// 找一个 page target 的 webSocketDebuggerUrl（轮询到 deadline）。
Future<Map<String, Object?>?> findPage(
  int port, {
  Duration within = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(within);
  while (DateTime.now().isBefore(deadline)) {
    final c = HttpClient()..findProxy = null;
    c.connectionTimeout = const Duration(seconds: 3);
    try {
      final req = await c.getUrl(Uri.parse('http://127.0.0.1:$port/json/list'));
      final resp = await req.close();
      final text = await resp.transform(_utf8).join();
      final j = jsonDecode(text);
      if (j is List) {
        for (final t in j) {
          if (t is Map &&
              t['type'] == 'page' &&
              '${t['webSocketDebuggerUrl'] ?? ''}'.isNotEmpty) {
            return Map<String, Object?>.from(t);
          }
        }
      }
    } catch (_) {
    } finally {
      c.close(force: true);
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  return null;
}

// ══════════════════ 窗口操作（Windows user32 惰性初始化 + macOS 置前）══════════════════

final DynamicLibrary _u32 = DynamicLibrary.open('user32.dll');

typedef _EnumWindowsProcNative = Int32 Function(IntPtr hwnd, IntPtr lparam);

final int Function(Pointer<NativeFunction<_EnumWindowsProcNative>>, int)
_enumWindows = _u32
    .lookupFunction<
      Int32 Function(Pointer<NativeFunction<_EnumWindowsProcNative>>, IntPtr),
      int Function(Pointer<NativeFunction<_EnumWindowsProcNative>>, int)
    >('EnumWindows');

final int Function(int) _isVisible = _u32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
      'IsWindowVisible',
    );
final int Function(int, Pointer<Uint32>) _getWindowThreadProcessId = _u32
    .lookupFunction<
      Uint32 Function(IntPtr, Pointer<Uint32>),
      int Function(int, Pointer<Uint32>)
    >('GetWindowThreadProcessId');
final int Function(int) _isIconic = _u32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('IsIconic');
final int Function(int) _isZoomed = _u32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('IsZoomed');
final int Function(int, int) _showWindow = _u32
    .lookupFunction<Int32 Function(IntPtr, Int32), int Function(int, int)>(
      'ShowWindow',
    );
final int Function(int) _setForeground = _u32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
      'SetForegroundWindow',
    );
final int Function(int) _bringToTop = _u32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
      'BringWindowToTop',
    );
final int Function() _getForeground = _u32
    .lookupFunction<IntPtr Function(), int Function()>('GetForegroundWindow');
final int Function(int, int, int) _attachThreadInput = _u32
    .lookupFunction<
      Int32 Function(Uint32, Uint32, Int32),
      int Function(int, int, int)
    >('AttachThreadInput');
final void Function(int, int) _switchToThisWindow = _u32
    .lookupFunction<Void Function(IntPtr, Int32), void Function(int, int)>(
      'SwitchToThisWindow',
    );

final class _Rect extends Struct {
  @Int32()
  external int left;
  @Int32()
  external int top;
  @Int32()
  external int right;
  @Int32()
  external int bottom;
}

final int Function(int, Pointer<_Rect>) _getWindowRect = _u32
    .lookupFunction<
      Int32 Function(IntPtr, Pointer<_Rect>),
      int Function(int, Pointer<_Rect>)
    >('GetWindowRect');

({int hwnd, int area})? biggestVisibleWindowOf(int pid) {
  if (!Platform.isWindows) return null;
  var best = 0, bestArea = 0;
  final pidPtr = malloc<Uint32>();
  final rc = malloc<_Rect>();
  final cb = NativeCallable<_EnumWindowsProcNative>.isolateLocal((
    int hwnd,
    int lparam,
  ) {
    pidPtr.value = 0;
    _getWindowThreadProcessId(hwnd, pidPtr);
    if (pidPtr.value != pid || _isVisible(hwnd) == 0) return 1;
    if (_getWindowRect(hwnd, rc) == 0) return 1;
    final area = (rc.ref.right - rc.ref.left) * (rc.ref.bottom - rc.ref.top);
    if (area > bestArea) {
      bestArea = area;
      best = hwnd;
    }
    return 1;
  }, exceptionalReturn: 0);
  try {
    _enumWindows(cb.nativeFunction, 0);
  } finally {
    cb.close();
    malloc.free(pidPtr);
    malloc.free(rc);
  }
  if (best == 0 || bestArea <= 0) return null;
  return (hwnd: best, area: bestArea);
}

/// 把 pid 对应的浏览器主窗口带到前台。
Future<void> focusProcess(int pid) async {
  if (!Platform.isWindows) {
    try {
      await Process.run('/usr/bin/osascript', [
        '-e',
        'tell application "System Events" to set frontmost of first process whose unix id is $pid to true',
      ]);
    } catch (_) {}
    return;
  }
  final found = biggestVisibleWindowOf(pid);
  if (found == null) return;
  final hwnd = found.hwnd;
  if (_isIconic(hwnd) != 0) _showWindow(hwnd, 9);
  final ourTid = _k32.lookupFunction<Uint32 Function(), int Function()>(
    'GetCurrentThreadId',
  )();
  for (var i = 0; i < 12; i++) {
    if (_getForeground() == hwnd) return;
    final attached = <int>[];
    final fg = _getForeground();
    final fgTid = fg != 0 ? _getWindowThreadProcessId(fg, nullptr) : 0;
    final targetTid = _getWindowThreadProcessId(hwnd, nullptr);
    for (final tid in {fgTid, targetTid}) {
      if (tid != 0 &&
          tid != ourTid &&
          _attachThreadInput(ourTid, tid, 1) != 0) {
        attached.add(tid);
      }
    }
    try {
      _setForeground(hwnd);
      _bringToTop(hwnd);
    } finally {
      for (final tid in attached) {
        _attachThreadInput(ourTid, tid, 0);
      }
    }
    if (_getForeground() == hwnd) return;
    await Future<void>.delayed(const Duration(milliseconds: 150));
  }
  _switchToThisWindow(hwnd, 1);
}

/// 把 pid 的主窗口最大化（Windows 补 SW_MAXIMIZE；macOS 直接放行）。
Future<bool> maximizeWindowOfPid(
  int pid, {
  Duration timeout = const Duration(seconds: 6),
}) async {
  if (!Platform.isWindows) return true;
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final found = biggestVisibleWindowOf(pid);
    if (found != null) {
      if (_isZoomed(found.hwnd) != 0) return true;
      _showWindow(found.hwnd, 3);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (_isZoomed(found.hwnd) != 0) return true;
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  return false;
}

// ══════════════════ Launched / launch ══════════════════

class Launched {
  Launched(this.proc, this.port, this.exe, this.profileDir) {
    // 记住退出事件：alive() 靠它（Process 没有同步 poll）。
    unawaited(
      proc.exitCode.then((code) {
        _exited = true;
        exitCode = code;
        onExit?.call(code);
      }),
    );
  }

  final Process proc;
  final int port;
  final String exe;
  final String profileDir;
  bool _exited = false;

  /// 浏览器进程退出码（退出后有值；分发机诊断用——0=正常关窗/命令转交，
  /// 负数=Windows 崩溃码如 0xC0000005）。
  int? exitCode;

  /// 浏览器进程退出回调（宿主接去记日志）。
  void Function(int exitCode)? onExit;

  Future<bool> alive() async {
    if (_exited) return false;
    try {
      await proc.exitCode.timeout(Duration.zero);
      _exited = true;
      return false;
    } on TimeoutException {
      return true;
    }
  }

  /// terminate → wait（12 秒）→ kill 兜底；最后让 PID 记号文件失效。
  Future<void> stop() async {
    try {
      proc.kill();
      await proc.exitCode.timeout(const Duration(seconds: 12));
    } on TimeoutException {
      try {
        proc.kill(ProcessSignal.sigkill);
      } catch (_) {}
    } catch (_) {}
    forgetFile('$profileDir/$_pidFile');
  }
}

/// 起浏览器并返回 Launched（已带好真实端口）。
///
/// fullscreen：设置卡「打开网页时全屏」。
///   True  → --start-fullscreen（F11 效果，铺满整屏）
///   False → --start-maximized + 补真最大化
///
/// ★ 托盘版经常出现"上一轮刚收工、用户立刻再开"的节奏。Edge 退场慢时
///   profile 可能还被占着，新进程会把命令转交给旧实例然后退出 ——
///   表现就是等不到 CDP 端口。给【两次机会】：第一次失败后 killStale
///   清场再来一次，还失败才真的报错。
Future<Launched> launchBrowser(
  String exe,
  String profileDir, {
  bool fullscreen = true,
  Duration wait = const Duration(seconds: 25),
}) async {
  Object? lastErr;
  await Directory(profileDir).create(recursive: true);
  for (var attempt = 1; attempt <= 2; attempt++) {
    // ★★ 必须让上一次留下的 DevToolsActivePort 失效：程序被强杀后浏览器
    //   残留，旧端口文件还能连上（正在死去的进程），于是连上一个空壳。
    //   ★ 截断而不是删除 —— 受管环境下删除会走"安全删除"通道，实测卡过
    //     51.9 秒（Python 版逐段计时的血账），截断零阻塞、行为等价。
    forgetFile('$profileDir/DevToolsActivePort');

    final args = <String>[
      '--remote-debugging-port=0',
      '--user-data-dir=$profileDir',
      '--no-first-run',
      '--no-default-browser-check',
      '--disable-sync',
      '--window-size=1400,900',
    ];
    if (fullscreen) {
      args.add('--start-fullscreen');
    } else {
      // flag 只能给出伪最大化；真正话事的是 launch 成功后那刀 SW_MAXIMIZE。
      args.add('--start-maximized');
    }
    args.add('about:blank');

    Process proc;
    try {
      proc = await Process.start(exe, args);
    } catch (e) {
      lastErr = e;
      continue;
    }
    // 记下 PID：程序被强杀时 finally 不会执行，浏览器会残留占着 profile，
    // 下次 killStale() 才能精确清场。
    try {
      File('$profileDir/$_pidFile').writeAsStringSync('${proc.pid}');
    } catch (_) {}

    final port = await devtoolsPort(profileDir, DateTime.now().add(wait));
    if (port != null) {
      final launched = Launched(proc, port, exe, profileDir);
      if (!fullscreen) {
        await maximizeWindowOfPid(proc.pid);
      }
      return launched;
    }

    lastErr = StateError('浏览器起来了但没暴露 CDP 端口（profile=$profileDir）');
    try {
      proc.kill();
    } catch (_) {}
    if (attempt == 1) {
      await Future<void>.delayed(const Duration(seconds: 1));
      await killStale(profileDir);
      await killProfileHolders(profileDir);
    }
  }
  throw StateError('$lastErr');
}
