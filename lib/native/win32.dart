// win32.dart —— Win32 API 的 dart:ffi 子集绑定（只收本程序用到的）。
//
// 用法约定（与 C# 版 HookEngine 的铁律一致）：
//   · 所有会从原生回调进入 Dart 的入口（钩子 / WndProc）都必须 try/catch 密不透风，
//     异常绝不能逃出回调 —— 否则就是 0xC000041D 级别的进程终结。
//   · 回调用的 NativeCallable 一律存字段保活，防 GC。
//   · 句柄（HHOOK / HANDLE / HWND / HMODULE）在 x64 上与指针同宽，
//     声明为 IntPtr（Dart 侧即 int）；其余定宽值参数保持原生拼写（Int32/Uint32…，
//     调用点直接传 int 字面量）。
library;

import 'dart:ffi';
import 'package:ffi/ffi.dart';

// ── 结构体 ──────────────────────────────────────────────────────────────

/// KBDLLHOOKSTRUCT / MSLLHOOKSTRUCT（布局相同，只有前两个字段含义不同）。
final class KbdllHookStruct extends Struct {
  @Uint32()
  external int vkCode; // MSLLHOOKSTRUCT 里是 pt.x/pt.y，本程序不读鼠标坐标
  @Uint32()
  external int scanCode; // MSLLHOOKSTRUCT 里是 mouseData
  @Uint32()
  external int flags;
  @Uint32()
  external int time;
  @IntPtr()
  external int dwExtraInfo;
}

/// INPUT —— 原生是「DWORD type + 偏移 8 的联合体」，x64 总长 40 字节。
/// Dart FFI 的 Union 所有字段共享偏移 0，表达不出这个布局；显式按字节偏移
/// 声明（键盘成员落在 8..31，尾部补白撑到 40）。cbSize 必须恰为 40，
/// 否则 SendInput 整批拒收 —— 这正是 C# 版 v4.0.0 首发的失效根因。
final class Input extends Struct {
  @Uint32()
  external int type; // offset 0
  @Uint32()
  external int pad0; // offset 4（对齐填充）
  @Uint16()
  external int wVk; // offset 8  ┐
  @Uint16()
  external int wScan; // offset 10 │ KBDINPUT
  @Uint32()
  external int dwFlags; // offset 12 │（键盘路径只写这段）
  @Uint32()
  external int time; // offset 16 │
  @IntPtr()
  external int dwExtraInfo; // offset 24 ┘
  @Array(8)
  external Array<Uint8> pad1; // offset 32..39（联合体尾巴，撑到 40）
}

final class WndClassW extends Struct {
  @Uint32()
  external int style;
  @IntPtr()
  external int lpfnWndProc;
  @Int32()
  external int cbClsExtra;
  @Int32()
  external int cbWndExtra;
  @IntPtr()
  external int hInstance;
  @IntPtr()
  external int hIcon;
  @IntPtr()
  external int hCursor;
  @IntPtr()
  external int hbrBackground;
  @IntPtr()
  external int lpszMenuName;
  @IntPtr()
  external int lpszClassName;
}

// ── 回调签名（原生拼写；Dart 回调实现可用 int 承接每个参数）──────────────

typedef HookProcNative = IntPtr Function(Int32 nCode, IntPtr wParam, IntPtr lParam);
typedef WndProcNative = IntPtr Function(IntPtr hwnd, Uint32 msg, IntPtr wParam, IntPtr lParam);

// ── kernel32 ────────────────────────────────────────────────────────────

final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');

/// HMODULE GetModuleHandleW(LPCWSTR)
final int Function(Pointer<Utf16>) getModuleHandleW = _kernel32
    .lookupFunction<IntPtr Function(Pointer<Utf16>), int Function(Pointer<Utf16>)>(
        'GetModuleHandleW');

/// DWORD GetCurrentThreadId()
final int Function() getCurrentThreadId =
    _kernel32.lookupFunction<Uint32 Function(), int Function()>('GetCurrentThreadId');

/// HANDLE CreateMutexW(LPSECURITY_ATTRIBUTES, BOOL, LPCWSTR)
/// HANDLE OpenMutexW(DWORD, BOOL, LPCWSTR) —— 探测已有互斥体（不依赖 lastError）。
final int Function(int, int, Pointer<Utf16>) openMutexW = _kernel32
    .lookupFunction<IntPtr Function(IntPtr, IntPtr, Pointer<Utf16>),
        int Function(int, int, Pointer<Utf16>)>('OpenMutexW');

final int Function(Pointer<Utf16>, int, Pointer<Utf16>) createMutexW = _kernel32
    .lookupFunction<IntPtr Function(Pointer<Utf16>, IntPtr, Pointer<Utf16>),
        int Function(Pointer<Utf16>, int, Pointer<Utf16>)>('CreateMutexW');

/// HANDLE CreateEventW(LPSECURITY_ATTRIBUTES, BOOL, BOOL, LPCWSTR)
final int Function(int, int, int, Pointer<Utf16>) createEventW = _kernel32
    .lookupFunction<IntPtr Function(IntPtr, IntPtr, IntPtr, Pointer<Utf16>),
        int Function(int, int, int, Pointer<Utf16>)>('CreateEventW');

/// DWORD WaitForSingleObject(HANDLE, DWORD)
final int Function(int, int) waitForSingleObject = _kernel32
    .lookupFunction<Uint32 Function(IntPtr, IntPtr), int Function(int, int)>('WaitForSingleObject');

final int Function(int) releaseMutex =
    _kernel32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('ReleaseMutex');

final int Function(int) closeHandle =
    _kernel32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');

final int Function(int) setEvent =
    _kernel32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('SetEvent');

final int Function(int) resetEvent =
    _kernel32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('ResetEvent');

final int Function() getLastError =
    _kernel32.lookupFunction<Uint32 Function(), int Function()>('GetLastError');

/// 常量。
const int errorAlreadyExists = 183;
const int waitObject0 = 0;
const int waitAbandoned = 0x80;
const int mutexModifyState = 0x00100000; // SYNCHRONIZE

// ── user32 ──────────────────────────────────────────────────────────────

final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');

const int whMouseLl = 14, whKeyboardLl = 13;
const int wmMButtonDown = 0x0207, wmMButtonUp = 0x0208;
const int wmKeyDown = 0x0100, wmKeyUp = 0x0101;
const int wmSysKeyDown = 0x0104, wmSysKeyUp = 0x0105;
const int wmHotkey = 0x0312;
const int llkhfInjected = 0x10; // LLKHF_INJECTED == LLMHF_INJECTED == 0x10
const int inputKeyboard = 1;
const int keyeventfExtendedkey = 1, keyeventfKeyup = 2;
const int mapvkVkToVscEx = 4;
const int hwndMessage = -3; // CreateWindowExW 的 parent：message-only 窗口

// ── 闪光面板用：SW_SHOWNA 亮起不抢焦点；TOPMOST 置顶 ──
const int swShowNA = 8;
const int swHide = 0;
const int hwndTopmost = -1;
const int hwndNotopmost = -2;
const int swpNoSize = 0x0001;
const int swpNoMove = 0x0002;
const int swpNoActivate = 0x0010;

/// BOOL ShowWindow(HWND, int)
final int Function(int, int) showWindowNative =
    _user32.lookupFunction<Int32 Function(IntPtr, Int32), int Function(int, int)>('ShowWindow');

/// BOOL SetWindowPos(HWND, HWND, int, int, int, int, UINT)
final int Function(int, int, int, int, int, int, int) setWindowPos = _user32.lookupFunction<
    Int32 Function(IntPtr, IntPtr, Int32, Int32, Int32, Int32, Uint32),
    int Function(int, int, int, int, int, int, int)>('SetWindowPos');

// ── 拖窗用（系统原生拖动通道，hide/收回时系统自动释放捕获，不会卡鼠标）──
const int wmNcLButtonDown = 0x00A1;
const int htCaption = 2;

/// BOOL ReleaseCapture()
final int Function() releaseCapture =
    _user32.lookupFunction<Int32 Function(), int Function()>('ReleaseCapture');

/// LRESULT SendMessageW(HWND, UINT, WPARAM, LPARAM)
final int Function(int, int, int, int) sendMessageW = _user32
    .lookupFunction<IntPtr Function(IntPtr, Uint32, IntPtr, IntPtr),
        int Function(int, int, int, int)>('SendMessageW');

/// void MessageBeep(UINT uType) —— 系统事件音（不依赖窗口，最可靠的提示）。
final void Function(int) messageBeep =
    _user32.lookupFunction<Void Function(IntPtr), void Function(int)>('MessageBeep');

/// HWND FindWindowW(LPCWSTR, LPCWSTR)
final int Function(Pointer<Utf16>, Pointer<Utf16>) findWindowW = _user32
    .lookupFunction<IntPtr Function(Pointer<Utf16>, Pointer<Utf16>),
        int Function(Pointer<Utf16>, Pointer<Utf16>)>('FindWindowW');

/// 按类名找窗口句柄。
int findWindowByClass(String className) {
  final n = className.toNativeUtf16();
  try {
    return findWindowW(n, nullptr);
  } finally {
    malloc.free(n);
  }
}

/// HHOOK SetWindowsHookExW(int, HOOKPROC, HINSTANCE, DWORD)
final int Function(int, Pointer<NativeFunction<HookProcNative>>, int, int)
    setWindowsHookExW = _user32.lookupFunction<
      IntPtr Function(IntPtr, Pointer<NativeFunction<HookProcNative>>, IntPtr, IntPtr),
      int Function(int, Pointer<NativeFunction<HookProcNative>>, int, int)
    >('SetWindowsHookExW');

final int Function(int) unhookWindowsHookEx = _user32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('UnhookWindowsHookEx');

final int Function(int, int, int, int) callNextHookEx = _user32
    .lookupFunction<IntPtr Function(IntPtr, IntPtr, IntPtr, IntPtr),
        int Function(int, int, int, int)>('CallNextHookEx');

final int Function(int, Pointer<Input>, int) sendInput = _user32
    .lookupFunction<Uint32 Function(IntPtr, Pointer<Input>, IntPtr),
        int Function(int, Pointer<Input>, int)>('SendInput');

final int Function(int, int) mapVirtualKeyW = _user32
    .lookupFunction<Uint32 Function(IntPtr, IntPtr), int Function(int, int)>('MapVirtualKeyW');

final int Function(int) getAsyncKeyState =
    _user32.lookupFunction<Int16 Function(IntPtr), int Function(int)>('GetAsyncKeyState');

final int Function(Pointer<WndClassW>) registerClassW = _user32
    .lookupFunction<Uint16 Function(Pointer<WndClassW>), int Function(Pointer<WndClassW>)>(
        'RegisterClassW');

/// HWND CreateWindowExW(DWORD, LPCWSTR, LPCWSTR, DWORD, 4×int, 4×HANDLE)
final int Function(int, Pointer<Utf16>, Pointer<Utf16>, int, int, int, int, int,
        int, int, int, int) createWindowExW =
    _user32.lookupFunction<
      IntPtr Function(IntPtr, Pointer<Utf16>, Pointer<Utf16>, IntPtr, IntPtr, IntPtr, IntPtr,
          IntPtr, IntPtr, IntPtr, IntPtr, IntPtr),
      int Function(int, Pointer<Utf16>, Pointer<Utf16>, int, int, int, int, int,
          int, int, int, int)
    >('CreateWindowExW');

final int Function(int, int, int, int) defWindowProcW = _user32
    .lookupFunction<IntPtr Function(IntPtr, IntPtr, IntPtr, IntPtr),
        int Function(int, int, int, int)>('DefWindowProcW');

final int Function(int) destroyWindow =
    _user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('DestroyWindow');

final int Function(int, int, int, int) registerHotKey = _user32
    .lookupFunction<Int32 Function(IntPtr, IntPtr, IntPtr, IntPtr),
        int Function(int, int, int, int)>('RegisterHotKey');

final int Function(int, int) unregisterHotKey = _user32
    .lookupFunction<Int32 Function(IntPtr, IntPtr), int Function(int, int)>('UnregisterHotKey');

final int Function(int, Pointer<Utf16>, Pointer<Utf16>, int) messageBoxW = _user32
    .lookupFunction<Int32 Function(IntPtr, Pointer<Utf16>, Pointer<Utf16>, IntPtr),
        int Function(int, Pointer<Utf16>, Pointer<Utf16>, int)>('MessageBoxW');

// ── shell32 ─────────────────────────────────────────────────────────────

final DynamicLibrary _shell32 = DynamicLibrary.open('shell32.dll');

/// ShellExecuteW(0, 'open', path, 0, 0, SW_SHOWNORMAL) —— 用系统默认程序打开文件。
final int Function(int, Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>, int)
    shellExecuteW = _shell32.lookupFunction<
      IntPtr Function(IntPtr, Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>, IntPtr),
      int Function(int, Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>, int)
    >('ShellExecuteW');

/// 用系统默认程序打开一个本地文件（使用说明 / 日志）。
/// 返回是否成功（>32 = 成功，ShellExecute 的老约定）。
bool openFileWithDefaultApp(String path) {
  final p = path.toNativeUtf16();
  final verb = 'open'.toNativeUtf16();
  try {
    return shellExecuteW(0, verb, p, nullptr, nullptr, 1) > 32;
  } catch (_) {
    return false;
  } finally {
    malloc.free(p);
    malloc.free(verb);
  }
}

/// 原生 MessageBox（启动项设置失败这类必须让用户看见的提示）。
void nativeMessageBox(String title, String text) {
  final t = title.toNativeUtf16();
  final m = text.toNativeUtf16();
  try {
    messageBoxW(0, m, t, 0x30 /*MB_ICONWARNING*/);
  } catch (_) {} finally {
    malloc.free(t);
    malloc.free(m);
  }
}

// ── 找本进程主窗（拖窗通道用）───────────────────────────────────────────

/// DWORD GetWindowThreadProcessId(HWND, LPDWORD)
final int Function(int, Pointer<Uint32>) getWindowThreadProcessId = _user32
    .lookupFunction<Uint32 Function(IntPtr, Pointer<Uint32>),
        int Function(int, Pointer<Uint32>)>('GetWindowThreadProcessId');

/// DWORD GetCurrentProcessId()
final int Function() getCurrentProcessId =
    _kernel32.lookupFunction<Uint32 Function(), int Function()>('GetCurrentProcessId');

/// HWND GetWindow(HWND, UINT) —— GW_HWNDNEXT = 2（Z 序下一个）
const int gwHwndNext = 2;

final int Function(int, int) getWindow = _user32
    .lookupFunction<IntPtr Function(IntPtr, Uint32), int Function(int, int)>('GetWindow');

/// 本进程的主窗句柄：EnumWindows 枚举 + 类名精确匹配 + 只认自己 PID。
/// ★ 不用 FindWindowW：实测它对本进程的 'FLUTTER_RUNNER_WIN32_WINDOW' 会
///   无解释地返回 0（EnumWindows+GetClassName 明明能看到；系统怪癖，
///   2026-10-02 EzAway 实锤——四个 Flutter 版统一走此路径）。
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
          var match = true;
          for (var i = 0; i < className.length; i++) {
            final a = nameBuf[i];
            final b = className.codeUnitAt(i);
            final la = (a >= 0x41 && a <= 0x5A) ? a + 0x20 : a;
            final lb = (b >= 0x41 && b <= 0x5A) ? b + 0x20 : b;
            if (la != lb) {
              match = false;
              break;
            }
          }
          if (match && nameBuf[className.length] == 0) {
            found.value = h;
            return 0;
          }
        } catch (_) {}
        return 1;
      },
      exceptionalReturn: 1,
    );
    enumWindows(cb.nativeFunction, 0);
    cb.close();
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

// ──────────────────────────────────────── 窗口几何 / 过程子类化（窗口贴合 + 等比锁）

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

final int Function(int, Pointer<RectL>) getWinRectB = _user32
    .lookupFunction<Int32 Function(IntPtr, Pointer<RectL>),
        int Function(int, Pointer<RectL>)>('GetWindowRect');

final int Function(int, Pointer<RectL>) getCliRectB = _user32
    .lookupFunction<Int32 Function(IntPtr, Pointer<RectL>),
        int Function(int, Pointer<RectL>)>('GetClientRect');

final int Function(int, Pointer<Uint16>, int) getClassNameW = _user32
    .lookupFunction<Int32 Function(IntPtr, Pointer<Uint16>, Int32),
        int Function(int, Pointer<Uint16>, int)>('GetClassNameW');

const int gwlWndProc = -4;
const int wmSizing = 0x0214;
const int wmEnterSizeMove = 0x0231;

final int Function(int, int) getWindowLongPtrW = _user32
    .lookupFunction<IntPtr Function(IntPtr, Int32), int Function(int, int)>(
        'GetWindowLongPtrW');

final int Function(int, int, int) setWindowLongPtrW = _user32
    .lookupFunction<IntPtr Function(IntPtr, Int32, IntPtr),
        int Function(int, int, int)>('SetWindowLongPtrW');

final int Function(int, int, int, int, int) callWindowProcW = _user32
    .lookupFunction<IntPtr Function(IntPtr, IntPtr, Uint32, IntPtr, IntPtr),
        int Function(int, int, int, int, int)>('CallWindowProcW');

typedef EnumWindowsProcNative = IntPtr Function(IntPtr, IntPtr);

final int Function(Pointer<NativeFunction<EnumWindowsProcNative>>, int)
    enumWindows = _user32.lookupFunction<
        Int32 Function(Pointer<NativeFunction<EnumWindowsProcNative>>, IntPtr),
        int Function(Pointer<NativeFunction<EnumWindowsProcNative>>, int)>(
        'EnumWindows');

/// 【窗口贴合】外框 vs 客户区实测。返回 '外框 WxH 客户 WxH'。
String windowFitProbe(int hwnd) {
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
