// single_instance.dart —— 跨平台单实例文件锁。
//
// Windows：CreateFileW 独占打开（dwShareMode=0）；
// macOS：RandomAccessFile.lockSync(FileLock.exclusive)。
// 进程退出时内核自动释放锁。
library;

import 'dart:ffi';
import 'dart:io';

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
  SingleInstance._win(this._handle) : _raf = null;
  SingleInstance._posix(this._raf) : _handle = 0;

  final int _handle;
  final RandomAccessFile? _raf;

  static SingleInstance? tryBecomeOwner() {
    final path = pJoin(dataDir(), '.agent.lock');
    if (!Platform.isWindows) {
      final f = File(path)..createSync(recursive: true);
      final raf = f.openSync(mode: FileMode.append);
      try {
        raf.lockSync(FileLock.exclusive);
      } catch (_) {
        raf.closeSync();
        return null;
      }
      return SingleInstance._posix(raf);
    }
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
      if (handle == nullptr || handle.address == 0xFFFFFFFFFFFFFFFF) {
        return null;
      }
      return SingleInstance._win(handle.address);
    } finally {
      malloc.free(p);
    }
  }

  void dispose() {
    if (_raf != null) {
      try {
        _raf.unlockSync();
        _raf.closeSync();
      } catch (_) {}
      return;
    }
    if (_handle != 0) _closeHandle(_handle);
  }
}
