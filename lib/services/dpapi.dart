// dpapi.dart —— 跨平台凭据加密存储。
//
// Windows：DPAPI（CryptProtectData）——密钥绑定当前电脑与当前 Windows 用户，
// 附加熵与历史 Python/C# 版逐字节一致。
//
// macOS：系统钥匙串（Keychain）——通过 /usr/bin/security 存入 login keychain，
// 磁盘 config.json 仅保存「KC1\0」指针标记，不留明文；凭据与 token 缓存必须
// 分服务名（kcServiceCredentials vs kcServiceTokenCache），防止互相覆盖。
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io' show Platform, Process, ProcessResult;
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

Uint8List _runWinDpapi(_CryptFnDart fn, Uint8List data) {
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
    malloc
      ..free(inPtr)
      ..free(entPtr)
      ..free(inBlob)
      ..free(entBlob)
      ..free(outBlob);
  }
}

// ── macOS Keychain ────────────────────────────────────────────────────────

const int _kcTag0 = 0x4B, _kcTag1 = 0x43, _kcTag2 = 0x31, _kcTag3 = 0x00; // 'KC1\0'
const int _rawTag0 = 0x52, _rawTag1 = 0x41, _rawTag2 = 0x57, _rawTag3 = 0x31; // 'RAW1'
const String _kcAccount = 'xiaoMiCreds';
const String kcServiceCredentials = 'EzMiGeek.credentials';
const String kcServiceTokenCache = 'EzMiGeek.token-cache';

ProcessResult _runSecurity(List<String> args) => Process.runSync(
  '/usr/bin/security',
  args,
  stdoutEncoding: utf8,
  stderrEncoding: utf8,
);

/// 加密字节串。[svc] 仅在 macOS 上区分 Keychain 服务名（凭据与 token 缓存必须分开）。
Uint8List dpapiProtect(Uint8List data, {String svc = kcServiceCredentials}) {
  if (!Platform.isWindows) {
    final r = _runSecurity([
      'add-generic-password',
      '-a',
      _kcAccount,
      '-s',
      svc,
      '-w',
      utf8.decode(data, allowMalformed: false),
      '-U',
    ]);
    if (r.exitCode != 0) {
      throw StateError('钥匙串写入失败（rc=${r.exitCode}）：${r.stderr}'.trim());
    }
    return Uint8List.fromList([_kcTag0, _kcTag1, _kcTag2, _kcTag3]);
  }
  return _runWinDpapi(_cryptProtectData, data);
}

/// 解密字节串。[svc] 必须与加密时一致。
Uint8List dpapiUnprotect(Uint8List data, {String svc = kcServiceCredentials}) {
  if (!Platform.isWindows) {
    if (data.length >= 4 &&
        data[0] == _kcTag0 &&
        data[1] == _kcTag1 &&
        data[2] == _kcTag2 &&
        data[3] == _kcTag3) {
      final r = _runSecurity([
        'find-generic-password',
        '-a',
        _kcAccount,
        '-s',
        svc,
        '-w',
      ]);
      if (r.exitCode != 0) {
        throw StateError('钥匙串里读不到凭据（rc=${r.exitCode}，svc=$svc）——请重新登录一次小米账号。');
      }
      return utf8.encode('${r.stdout}'.replaceFirst(RegExp(r'\n$'), ''));
    }
    if (data.length >= 4 &&
        data[0] == _rawTag0 &&
        data[1] == _rawTag1 &&
        data[2] == _rawTag2 &&
        data[3] == _rawTag3) {
      // 兼容旧版明文指针：先读出，下次保存自动迁入 Keychain。
      return Uint8List.sublistView(data, 4);
    }
    throw StateError('这份凭据是 Windows DPAPI 加密的，macOS 版解不开——请重新登录一次小米账号。');
  }
  try {
    return _runWinDpapi(_cryptUnprotectData, data);
  } catch (_) {
    throw StateError('DPAPI 解密失败：这份凭据属于另一台电脑或另一个 Windows 用户，请重新登录一次小米账号。');
  }
}

/// 兼容早期 macOS 本地版钥匙串格式（svc=EzMiGeek.credentials, acct=primary）。
String? keychainRead(String svc, String acct) {
  if (Platform.isWindows) return null;
  final r = _runSecurity([
    'find-generic-password',
    '-a',
    acct,
    '-s',
    svc,
    '-w',
  ]);
  if (r.exitCode != 0) return null;
  final s = '${r.stdout}'.replaceFirst(RegExp(r'\n$'), '');
  return s.isEmpty ? null : s;
}
