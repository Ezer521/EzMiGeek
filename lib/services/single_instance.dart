// single_instance.dart —— 单实例文件锁（__main__.SingleInstance 同款）。
//
// 与 C#/Python 版共用同一个锁文件 %LOCALAPPDATA%\EzMiGeek\.agent.lock。
// 锁 = CreateFileW 独占打开（dwShareMode=0），第二实例打不开 = 已有实例。
// 进程退出时内核自动关句柄放锁，无需显式清理。
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../core/app_dirs.dart';

final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');

typedef _CreateFileWNative = Pointer<Uint8> Function(
  Pointer<Utf16>,
  Uint32,
  Uint32,
  Pointer<Uint8>,
  Uint32,
  Uint32,
  Pointer<Uint8>,
);
typedef _CreateFileWDart = Pointer<Uint8> Function(
  Pointer<Utf16>,
  int,
  int,
  Pointer<Uint8>,
  int,
  int,
  Pointer<Uint8>,
);

final _CreateFileWDart _createFileW = _kernel32
    .lookupFunction<_CreateFileWNative, _CreateFileWDart>('CreateFileW');

final int Function(int) _closeHandle = _kernel32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');

const int _genericWrite = 0x40000000;
const int _openAlways = 4;
const int _fileFlagNormal = 0x80;

class SingleInstance {
  SingleInstance._win(this._handle);

  final int _handle; // Windows：CreateFileW 句柄

  /// 尝试成为唯一实例。返回实例 = 拿到了锁；null = 已有实例在跑。
  ///
  /// 锁 = 独占打开数据目录里的 .agent.lock——与 Python/C# 版共用同一文件。
  /// 第二实例的宿主见 main()：写一行日志后退出（Python 版 rc=2 同款）。
  static SingleInstance? tryBecomeOwner() {
    final path = '${dataDir()}\\.agent.lock';
    final p = path.toNativeUtf16();
    try {
      final handle = _createFileW(
        p,
        _genericWrite,
        0,
        nullptr,
        _openAlways,
        _fileFlagNormal,
        nullptr,
      );
      // INVALID_HANDLE_VALUE 的 address 是 0xFFFFFFFFFFFFFFFF（-1）。
      if (handle == nullptr || handle.address == 0xFFFFFFFFFFFFFFFF) {
        return null; // 已有实例
      }
      return SingleInstance._win(handle.address);
    } finally {
      malloc.free(p);
    }
  }

  /// 干净退出时放锁（进程退出内核也会放，这里只是把语义写明）。
  void dispose() {
    if (_handle != 0) _closeHandle(_handle);
  }
}
