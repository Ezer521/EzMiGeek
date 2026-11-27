// win32.dart —— Win32 API 的最小化 dart:ffi 绑定（仅保留本程序实际调用）。
//
// 安全原则：
//   · 绝不引入键盘/鼠标全局钩子（SetWindowsHookEx）或按键注入（SendInput），
//     避免杀毒软件静态/启发式误报；
//   · 窗口回调（WndProc / EnumWindows）必须完整 try/catch，异常绝不可逃逸到原生层；
//   · 句柄在 x64 上声明为 IntPtr，NativeCallable 必须存字段保活或同步调用后立即 close。
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

// ── 结构体与回调签名 ──────────────────────────────────────────────────────

final class RectL extends Struct {
  @Int32()
  external int left;
  @Int32()
  external int top;
  @Int32()
  external int right;
  @Int32()
  external int bottom;
}

typedef WndProcNative = IntPtr Function(
  IntPtr hwnd,
  Uint32 msg,
  IntPtr wParam,
  IntPtr lParam,
);
typedef EnumWindowsProcNative = Int32 Function(IntPtr hwnd, IntPtr lparam);

// ── kernel32（惰性初始化，macOS 上不触碰）───────────────────────────────────

final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');

final int Function() getCurrentProcessId = _kernel32
    .lookupFunction<Uint32 Function(), int Function()>('GetCurrentProcessId');

final int Function(int, int, int) _openProcess = _kernel32.lookupFunction<
    IntPtr Function(Uint32, Int32, Uint32),
    int Function(int, int, int)>('OpenProcess');

final int Function(int) _closeHandle = _kernel32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');

final int Function(int, int, Pointer<Uint16>, Pointer<Uint32>)
    _queryFullProcessImageNameW = _kernel32.lookupFunction<
        Int32 Function(IntPtr, Uint32, Pointer<Uint16>, Pointer<Uint32>),
        int Function(int, int, Pointer<Uint16>, Pointer<Uint32>)>(
  'QueryFullProcessImageNameW',
);

const int _processQueryLimitedInformation = 0x1000;

/// 按 PID 查询进程完整映像路径，查询失败或进程已退出返回空串。
String queryProcessImagePath(int pid) {
  if (!Platform.isWindows) return '';
  final h = _openProcess(_processQueryLimitedInformation, 0, pid);
  if (h == 0) return '';
  final buf = malloc<Uint16>(1024);
  final size = malloc<Uint32>();
  try {
    size.value = 1024;
    if (_queryFullProcessImageNameW(h, 0, buf, size) == 0) return '';
    return buf.cast<Utf16>().toDartString();
  } catch (_) {
    return '';
  } finally {
    malloc
      ..free(buf)
      ..free(size);
    _closeHandle(h);
  }
}

// ── user32（惰性初始化，macOS 上不触碰）─────────────────────────────────────

final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');

const int wmNcLButtonDown = 0x00A1;
const int htCaption = 2;
const int gwlWndProc = -4;

final int Function() releaseCapture = _user32
    .lookupFunction<Int32 Function(), int Function()>('ReleaseCapture');

final int Function(int, int, int, int) sendMessageW = _user32.lookupFunction<
    IntPtr Function(IntPtr, Uint32, IntPtr, IntPtr),
    int Function(int, int, int, int)>('SendMessageW');

final int Function(int, int, int, int) postMessageW = _user32.lookupFunction<
    Int32 Function(IntPtr, Uint32, IntPtr, IntPtr),
    int Function(int, int, int, int)>('PostMessageW');

final int Function(Pointer<Utf16>) _registerWindowMessageW = _user32
    .lookupFunction<Uint32 Function(Pointer<Utf16>),
        int Function(Pointer<Utf16>)>('RegisterWindowMessageW');

final int Function(int) _allowSetForegroundWindow = _user32
    .lookupFunction<Int32 Function(Uint32), int Function(int)>(
        'AllowSetForegroundWindow');

final int Function(int, Pointer<Uint32>) getWindowThreadProcessId = _user32
    .lookupFunction<Uint32 Function(IntPtr, Pointer<Uint32>),
        int Function(int, Pointer<Uint32>)>('GetWindowThreadProcessId');

final int Function(int, Pointer<RectL>) getWinRectB = _user32.lookupFunction<
    Int32 Function(IntPtr, Pointer<RectL>),
    int Function(int, Pointer<RectL>)>('GetWindowRect');

final int Function(int, Pointer<RectL>) getCliRectB = _user32.lookupFunction<
    Int32 Function(IntPtr, Pointer<RectL>),
    int Function(int, Pointer<RectL>)>('GetClientRect');

final int Function(int, Pointer<Uint16>, int) getClassNameW = _user32
    .lookupFunction<Int32 Function(IntPtr, Pointer<Uint16>, Int32),
        int Function(int, Pointer<Uint16>, int)>('GetClassNameW');

final int Function(int, int) getWindowLongPtrW = _user32
    .lookupFunction<IntPtr Function(IntPtr, Int32), int Function(int, int)>(
        'GetWindowLongPtrW');

final int Function(int, int, int) setWindowLongPtrW = _user32.lookupFunction<
    IntPtr Function(IntPtr, Int32, IntPtr),
    int Function(int, int, int)>('SetWindowLongPtrW');

final int Function(int, int, int, int, int) callWindowProcW = _user32
    .lookupFunction<IntPtr Function(IntPtr, IntPtr, Uint32, IntPtr, IntPtr),
        int Function(int, int, int, int, int)>('CallWindowProcW');

final int Function(Pointer<NativeFunction<EnumWindowsProcNative>>, int)
    enumWindows = _user32.lookupFunction<
        Int32 Function(Pointer<NativeFunction<EnumWindowsProcNative>>, IntPtr),
        int Function(Pointer<NativeFunction<EnumWindowsProcNative>>, int)>(
  'EnumWindows',
);

/// 注册自定义跨进程窗口消息。
int registerWindowMessage(String name) {
  if (!Platform.isWindows) return 0;
  final p = name.toNativeUtf16();
  try {
    return _registerWindowMessageW(p);
  } finally {
    malloc.free(p);
  }
}

/// 单实例二次启动唤起消息 ID（仅 Windows 使用，惰性初始化）。
final int wmEzMiGeekActivate = registerWindowMessage('EzMiGeek.Activate.v1');

bool _classMatches(Pointer<Uint16> nameBuf, String className) {
  for (var i = 0; i < className.length; i++) {
    final a = nameBuf[i];
    final b = className.codeUnitAt(i);
    final la = (a >= 0x41 && a <= 0x5A) ? a + 0x20 : a;
    final lb = (b >= 0x41 && b <= 0x5A) ? b + 0x20 : b;
    if (la != lb) return false;
  }
  return nameBuf[className.length] == 0;
}

/// 本进程主窗句柄：EnumWindows 枚举 + 类名精确匹配 + 只认自己 PID。
int findOwnWindowByClass(String className) {
  final me = getCurrentProcessId();
  final pidBuf = malloc<Uint32>();
  final nameBuf = malloc<Uint16>(128);
  final found = malloc<IntPtr>();
  try {
    found.value = 0;
    final cb = NativeCallable<EnumWindowsProcNative>.isolateLocal(
      (int h, int _) {
        try {
          getWindowThreadProcessId(h, pidBuf);
          if (pidBuf.value != me) return 1;
          for (var i = 0; i < 128; i++) {
            nameBuf[i] = 0;
          }
          getClassNameW(h, nameBuf, 128);
          if (_classMatches(nameBuf, className)) {
            found.value = h;
            return 0;
          }
        } catch (_) {}
        return 1;
      },
      exceptionalReturn: 1,
    );
    try {
      enumWindows(cb.nativeFunction, 0);
    } finally {
      cb.close();
    }
    return found.value;
  } catch (_) {
    return 0;
  } finally {
    malloc
      ..free(pidBuf)
      ..free(nameBuf)
      ..free(found);
  }
}

/// 通知已在运行的 EzMiGeek 实例把主面板弹到前台。
/// Windows 走跨进程窗口消息；macOS 优先按 Bundle ID 唤起（兼容任意运行目录）。
bool signalRunningInstance() {
  if (!Platform.isWindows) {
    try {
      if (Process.runSync('/usr/bin/open', ['-b', 'com.ezer.ezmigeek']).exitCode == 0) {
        return true;
      }
      return Process.runSync('/usr/bin/open', ['-a', 'EzMiGeek']).exitCode == 0;
    } catch (_) {
      return false;
    }
  }
  if (wmEzMiGeekActivate == 0) return false;
  final me = getCurrentProcessId();
  final selfPath = Platform.resolvedExecutable.toLowerCase();
  final selfName = selfPath.replaceAll('\\', '/').split('/').last;
  final pidBuf = malloc<Uint32>();
  final nameBuf = malloc<Uint16>(128);
  var targetHwnd = 0;
  var targetPid = 0;
  try {
    final cb = NativeCallable<EnumWindowsProcNative>.isolateLocal(
      (int h, int _) {
        try {
          getWindowThreadProcessId(h, pidBuf);
          final pid = pidBuf.value;
          if (pid == 0 || pid == me) return 1;
          for (var i = 0; i < 128; i++) {
            nameBuf[i] = 0;
          }
          getClassNameW(h, nameBuf, 128);
          if (!_classMatches(nameBuf, 'FLUTTER_RUNNER_WIN32_WINDOW')) return 1;
          final img = queryProcessImagePath(pid).toLowerCase();
          if (img.isEmpty) return 1;
          final imgName = img.replaceAll('\\', '/').split('/').last;
          if (img == selfPath ||
              imgName == selfName ||
              imgName == 'ezmigeek.exe') {
            targetHwnd = h;
            targetPid = pid;
            return 0;
          }
        } catch (_) {}
        return 1;
      },
      exceptionalReturn: 1,
    );
    try {
      enumWindows(cb.nativeFunction, 0);
    } finally {
      cb.close();
    }
    if (targetHwnd == 0) return false;
    _allowSetForegroundWindow(targetPid);
    return postMessageW(targetHwnd, wmEzMiGeekActivate, 0, 0) != 0;
  } catch (_) {
    return false;
  } finally {
    malloc
      ..free(pidBuf)
      ..free(nameBuf);
  }
}

/// 【窗口贴合】外框 vs 客户区实测。返回 '外框 WxH 客户 WxH'。
String windowFitProbe(int hwnd) {
  if (!Platform.isWindows) return '';
  final wr = malloc<RectL>(), cr = malloc<RectL>();
  try {
    getWinRectB(hwnd, wr);
    getCliRectB(hwnd, cr);
    final winW = wr.ref.right - wr.ref.left;
    final winH = wr.ref.bottom - wr.ref.top;
    final cliW = cr.ref.right - cr.ref.left;
    final cliH = cr.ref.bottom - cr.ref.top;
    return '外框 ${winW}x$winH 客户 ${cliW}x$cliH';
  } finally {
    malloc
      ..free(wr)
      ..free(cr);
  }
}

// ── shell32 / 跨平台系统默认打开 ───────────────────────────────────────────

final DynamicLibrary _shell32 = DynamicLibrary.open('shell32.dll');

final int Function(int, Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>,
        Pointer<Utf16>, int) shellExecuteW =
    _shell32.lookupFunction<
        IntPtr Function(IntPtr, Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>,
            Pointer<Utf16>, Int32),
        int Function(int, Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>,
            Pointer<Utf16>, int)>('ShellExecuteW');

/// 用系统默认程序打开本地文件、目录或 URL（Windows 走 ShellExecuteW，macOS 走 open）。
bool openFileWithDefaultApp(String pathOrUrl) {
  if (!Platform.isWindows) {
    try {
      return Process.runSync('/usr/bin/open', [pathOrUrl]).exitCode == 0;
    } catch (_) {
      return false;
    }
  }
  final p = pathOrUrl.toNativeUtf16();
  final verb = 'open'.toNativeUtf16();
  try {
    return shellExecuteW(0, verb, p, nullptr, nullptr, 1) > 32;
  } catch (_) {
    return false;
  } finally {
    malloc
      ..free(p)
      ..free(verb);
  }
}

// ── advapi32（原生注册表读写，惰性初始化）───────────────────────────────────

final DynamicLibrary _advapi32 = DynamicLibrary.open('advapi32.dll');

const int hkeyClassesRoot = -0x80000000;
const int hkeyCurrentUser = -0x7FFFFFFF;
const int hkeyLocalMachine = -0x7FFFFFFE;

const int _keyRead = 0x20019;
const int _keySetValue = 0x0002;
const int _regSz = 1;
const int _regExpandSz = 2;
const int _errSuccess = 0;
const int _errFileNotFound = 2;

final int Function(int, Pointer<Utf16>, int, int, Pointer<IntPtr>)
    _regOpenKeyExW = _advapi32.lookupFunction<
        Int32 Function(IntPtr, Pointer<Utf16>, Uint32, Uint32, Pointer<IntPtr>),
        int Function(int, Pointer<Utf16>, int, int, Pointer<IntPtr>)>(
  'RegOpenKeyExW',
);

final int Function(int, Pointer<Utf16>, int, Pointer<Utf16>, int, int,
        Pointer<Void>, Pointer<IntPtr>, Pointer<Uint32>) _regCreateKeyExW =
    _advapi32.lookupFunction<
        Int32 Function(IntPtr, Pointer<Utf16>, Uint32, Pointer<Utf16>, Uint32,
            Uint32, Pointer<Void>, Pointer<IntPtr>, Pointer<Uint32>),
        int Function(int, Pointer<Utf16>, int, Pointer<Utf16>, int, int,
            Pointer<Void>, Pointer<IntPtr>, Pointer<Uint32>)>(
  'RegCreateKeyExW',
);

final int Function(int, Pointer<Utf16>, Pointer<Uint32>, Pointer<Uint32>,
        Pointer<Uint8>, Pointer<Uint32>) _regQueryValueExW =
    _advapi32.lookupFunction<
        Int32 Function(IntPtr, Pointer<Utf16>, Pointer<Uint32>, Pointer<Uint32>,
            Pointer<Uint8>, Pointer<Uint32>),
        int Function(int, Pointer<Utf16>, Pointer<Uint32>, Pointer<Uint32>,
            Pointer<Uint8>, Pointer<Uint32>)>(
  'RegQueryValueExW',
);

final int Function(int, Pointer<Utf16>, int, int, Pointer<Uint8>, int)
    _regSetValueExW = _advapi32.lookupFunction<
        Int32 Function(
            IntPtr, Pointer<Utf16>, Uint32, Uint32, Pointer<Uint8>, Uint32),
        int Function(int, Pointer<Utf16>, int, int, Pointer<Uint8>, int)>(
  'RegSetValueExW',
);

final int Function(int, Pointer<Utf16>) _regDeleteValueW = _advapi32
    .lookupFunction<Int32 Function(IntPtr, Pointer<Utf16>),
        int Function(int, Pointer<Utf16>)>('RegDeleteValueW');

final int Function(int) _regCloseKey = _advapi32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('RegCloseKey');

/// 读取字符串注册表值（支持 REG_SZ / REG_EXPAND_SZ；valueName 传空串读默认值）。
/// 返回 (value, errorMsg)：不存在返回 (null, '')；失败返回 (null, 错误描述)。
(String?, String) regReadSz(int rootKey, String subKey, String valueName) {
  final subPtr = subKey.toNativeUtf16();
  final valPtr = valueName.isEmpty ? nullptr : valueName.toNativeUtf16();
  final hKeyPtr = malloc<IntPtr>();
  final typePtr = malloc<Uint32>();
  final sizePtr = malloc<Uint32>();
  Pointer<Uint8>? buf;
  var opened = 0;
  try {
    final rcOpen = _regOpenKeyExW(rootKey, subPtr, 0, _keyRead, hKeyPtr);
    if (rcOpen == _errFileNotFound) return (null, '');
    if (rcOpen != _errSuccess) return (null, 'RegOpenKeyExW=$rcOpen');
    opened = hKeyPtr.value;

    sizePtr.value = 0;
    final rcSize = _regQueryValueExW(
      opened,
      valPtr,
      nullptr,
      typePtr,
      nullptr,
      sizePtr,
    );
    if (rcSize == _errFileNotFound) return (null, '');
    if (rcSize != _errSuccess) return (null, 'RegQueryValueExW(size)=$rcSize');
    if (typePtr.value != _regSz && typePtr.value != _regExpandSz) {
      return (null, '');
    }
    final byteLen = sizePtr.value;
    if (byteLen == 0) return ('', '');

    buf = malloc<Uint8>(byteLen + 2);
    sizePtr.value = byteLen;
    final rcData = _regQueryValueExW(
      opened,
      valPtr,
      nullptr,
      typePtr,
      buf,
      sizePtr,
    );
    if (rcData != _errSuccess) return (null, 'RegQueryValueExW(data)=$rcData');
    final actualBytes = sizePtr.value;
    final unitCount = actualBytes ~/ 2;
    final units = buf.cast<Uint16>().asTypedList(unitCount);
    var len = unitCount;
    for (var i = 0; i < unitCount; i++) {
      if (units[i] == 0) {
        len = i;
        break;
      }
    }
    return (String.fromCharCodes(units.sublist(0, len)), '');
  } catch (e) {
    return (null, '$e');
  } finally {
    if (opened != 0) _regCloseKey(opened);
    if (buf != null) malloc.free(buf);
    malloc
      ..free(subPtr)
      ..free(hKeyPtr)
      ..free(typePtr)
      ..free(sizePtr);
    if (valPtr != nullptr) malloc.free(valPtr);
  }
}

/// 写入 REG_SZ 注册表值（键不存在会自动创建）。返回 Win32 错误码（0 = 成功）。
int regWriteSz(int rootKey, String subKey, String valueName, String data) {
  final subPtr = subKey.toNativeUtf16();
  final valPtr = valueName.toNativeUtf16();
  final dataPtr = data.toNativeUtf16();
  final hKeyPtr = malloc<IntPtr>();
  var opened = 0;
  try {
    final rcCreate = _regCreateKeyExW(
      rootKey,
      subPtr,
      0,
      nullptr,
      0,
      _keySetValue,
      nullptr,
      hKeyPtr,
      nullptr,
    );
    if (rcCreate != _errSuccess) return rcCreate;
    opened = hKeyPtr.value;
    final cbData = (data.length + 1) * 2;
    return _regSetValueExW(
      opened,
      valPtr,
      0,
      _regSz,
      dataPtr.cast<Uint8>(),
      cbData,
    );
  } finally {
    if (opened != 0) _regCloseKey(opened);
    malloc
      ..free(subPtr)
      ..free(valPtr)
      ..free(dataPtr)
      ..free(hKeyPtr);
  }
}

/// 删除指定注册表值（不存在视作成功）。返回 Win32 错误码（0 = 成功）。
int regDeleteValue(int rootKey, String subKey, String valueName) {
  final subPtr = subKey.toNativeUtf16();
  final valPtr = valueName.toNativeUtf16();
  final hKeyPtr = malloc<IntPtr>();
  var opened = 0;
  try {
    final rcOpen = _regOpenKeyExW(rootKey, subPtr, 0, _keySetValue, hKeyPtr);
    if (rcOpen == _errFileNotFound) return _errSuccess;
    if (rcOpen != _errSuccess) return rcOpen;
    opened = hKeyPtr.value;
    final rcDel = _regDeleteValueW(opened, valPtr);
    return rcDel == _errFileNotFound ? _errSuccess : rcDel;
  } finally {
    if (opened != 0) _regCloseKey(opened);
    malloc
      ..free(subPtr)
      ..free(valPtr)
      ..free(hKeyPtr);
  }
}
