// dpapi.dart —— 凭据加密（vendor/hub/凭据存储.py 移植）。
//
// Windows：DPAPI（CryptProtectData）——密钥绑定当前 Windows 用户，拷到别的
// 电脑 / 别的用户名下都解不开；附加熵（entropy）防同用户其它软件蹭解。
// 与 Python/C# 版同格式同熵 ⇒ 三代实现读写同一份 config.json。
//
library;

import 'dart:ffi';

import 'dart:typed_data';

import 'package:ffi/ffi.dart';

final DynamicLibrary _crypt32 = DynamicLibrary.open('crypt32.dll');

typedef _CryptFnNative = Int32 Function(
  Pointer<_Blob> inBlob,
  Pointer<Uint8> desc,
  Pointer<_Blob> entropy,
  Pointer<Uint8> reserved,
  Pointer<Uint8> prompt,
  Uint32 flags,
  Pointer<_Blob> outBlob,
);
typedef _CryptFnDart = int Function(
  Pointer<_Blob>,
  Pointer<Uint8>,
  Pointer<_Blob>,
  Pointer<Uint8>,
  Pointer<Uint8>,
  int,
  Pointer<_Blob>,
);

final _CryptFnDart _cryptProtectData = _crypt32
    .lookupFunction<_CryptFnNative, _CryptFnDart>('CryptProtectData');
final _CryptFnDart _cryptUnprotectData = _crypt32
    .lookupFunction<_CryptFnNative, _CryptFnDart>('CryptUnprotectData');

final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');

final Pointer<Uint8> Function(Pointer<Uint8>) _localFree = _kernel32
    .lookupFunction<
      Pointer<Uint8> Function(Pointer<Uint8>),
      Pointer<Uint8> Function(Pointer<Uint8>)
    >('LocalFree');

/// DATA_BLOB { DWORD cbData; BYTE* pbData; } —— Pointer 字段按 C 规则
/// 8 字节对齐，落在 offset 8（前面的 Uint32 + 填充由 FFI 自动排）。
final class _Blob extends Struct {
  @Uint32()
  external int cbData;

  external Pointer<Uint8> pbData;
}

/// 附加熵：与 Python/C# 版逐字节一致 —— 三代实现互换同一份密文的前提。
final Uint8List _entropy = Uint8List.fromList(
  'LinkBridge/hub-credentials/v1'.codeUnits,
);

const int _cryptprotectUiForbidden = 0x01;

Pointer<Uint8> _bytesPtr(Uint8List data) {
  final p = malloc<Uint8>(data.length);
  p.asTypedList(data.length).setAll(0, data);
  return p;
}

Uint8List _run(_CryptFnDart fn, Uint8List data) {
  final inPtr = _bytesPtr(data);
  final entPtr = _bytesPtr(_entropy);
  final inBlob = malloc<_Blob>();
  final entBlob = malloc<_Blob>();
  final outBlob = malloc<_Blob>();
  try {
    inBlob.ref.cbData = data.length;
    inBlob.ref.pbData = inPtr;
    entBlob.ref.cbData = _entropy.length;
    entBlob.ref.pbData = entPtr;
    final ok = fn(
      inBlob,
      nullptr,
      entBlob,
      nullptr,
      nullptr,
      _cryptprotectUiForbidden,
      outBlob,
    );
    if (ok == 0) {
      throw StateError('DPAPI 调用失败（返回 0）');
    }
    final len = outBlob.ref.cbData;
    final out = Uint8List.fromList(outBlob.ref.pbData.asTypedList(len));
    _localFree(outBlob.ref.pbData);
    return out;
  } finally {
    malloc.free(inPtr);
    malloc.free(entPtr);
    malloc.free(inBlob);
    malloc.free(entBlob);
    malloc.free(outBlob);
  }
}

Uint8List dpapiProtect(Uint8List data) => _run(_cryptProtectData, data);
Uint8List dpapiUnprotect(Uint8List data) => _run(_cryptUnprotectData, data);
