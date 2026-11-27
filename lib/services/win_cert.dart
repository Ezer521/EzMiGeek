// win_cert.dart —— Windows 原生 CryptoAPI SSL 证书链校验。
//
// 背景：Dart/BoringSSL 在个别 Windows 机器上不会自动通过 AIA 拉取缺失的
// 中间 CA 证书，导致正常合法的小米官方 HTTPS 站点报 CERTIFICATE_VERIFY_FAILED。
// 本模块在 badCertificateCallback 触发时调用 Windows 原生 CryptoAPI
// （CertGetCertificateChain + CertVerifyCertificateChainPolicy(SSL)），
// 与 Edge / Chrome / WinHTTP 走同一套系统根证书库与 AIA 补链机制：
//   · 仅当系统级证书链 + 有效期 + 主机名（CN/SAN）全部验证通过才放行；
//   · 任何自签名假证书、过期证书、域名不匹配或不受信任的 MITM 证书一律拒绝。
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

final DynamicLibrary _crypt32 = DynamicLibrary.open('crypt32.dll');

const int _x509AndPkcs7Encoding = 0x00010001; // X509_ASN_ENCODING | PKCS_7_ASN_ENCODING
const int _usageMatchTypeAnd = 0;
const int _certChainPolicySsl = 4;
const int _authTypeServer = 2;
const String _oidPkixKpServerAuth = '1.3.6.1.5.5.7.3.1';

final class _CtlUsage extends Struct {
  @Uint32()
  external int cUsageIdentifier;

  external Pointer<Pointer<Utf8>> rgpszUsageIdentifier;
}

final class _CertUsageMatch extends Struct {
  @Uint32()
  external int dwType;

  external _CtlUsage usage;
}

final class _CertChainPara extends Struct {
  @Uint32()
  external int cbSize;

  external _CertUsageMatch requestedUsage;
}

final class _SslExtraCertChainPolicyPara extends Struct {
  @Uint32()
  external int cbSize;

  @Uint32()
  external int dwAuthType;

  @Uint32()
  external int fdwChecks;

  external Pointer<Utf16> pwszServerName;
}

final class _CertChainPolicyPara extends Struct {
  @Uint32()
  external int cbSize;

  @Uint32()
  external int dwFlags;

  external Pointer<Void> pvExtraPolicyPara;
}

final class _CertChainPolicyStatus extends Struct {
  @Uint32()
  external int cbSize;

  @Uint32()
  external int dwError;

  @Int32()
  external int lChainIndex;

  @Int32()
  external int lElementIndex;

  external Pointer<Void> pvExtraPolicyStatus;
}

final Pointer<Void> Function(int, Pointer<Uint8>, int)
    _certCreateCertificateContext = _crypt32.lookupFunction<
        Pointer<Void> Function(Uint32, Pointer<Uint8>, Uint32),
        Pointer<Void> Function(int, Pointer<Uint8>, int)>(
  'CertCreateCertificateContext',
);

final int Function(Pointer<Void>) _certFreeCertificateContext = _crypt32
    .lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>(
  'CertFreeCertificateContext',
);

final int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>,
        Pointer<Void>, Pointer<_CertChainPara>, int, Pointer<Void>,
        Pointer<Pointer<Void>>) _certGetCertificateChain =
    _crypt32.lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Pointer<Void>,
          Pointer<Void>,
          Pointer<Void>,
          Pointer<_CertChainPara>,
          Uint32,
          Pointer<Void>,
          Pointer<Pointer<Void>>,
        ),
        int Function(
          Pointer<Void>,
          Pointer<Void>,
          Pointer<Void>,
          Pointer<Void>,
          Pointer<_CertChainPara>,
          int,
          Pointer<Void>,
          Pointer<Pointer<Void>>,
        )>('CertGetCertificateChain');

final void Function(Pointer<Void>) _certFreeCertificateChain = _crypt32
    .lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
  'CertFreeCertificateChain',
);

final int Function(Pointer<Void>, Pointer<Void>,
        Pointer<_CertChainPolicyPara>, Pointer<_CertChainPolicyStatus>)
    _certVerifyCertificateChainPolicy = _crypt32.lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Pointer<Void>,
          Pointer<_CertChainPolicyPara>,
          Pointer<_CertChainPolicyStatus>,
        ),
        int Function(
          Pointer<Void>,
          Pointer<Void>,
          Pointer<_CertChainPolicyPara>,
          Pointer<_CertChainPolicyStatus>,
        )>('CertVerifyCertificateChainPolicy');

/// 使用 Windows 系统 CryptoAPI 验证服务器 DER 证书及其与 [host] 的 SSL 策略。
/// 返回 (是否受系统信任, 失败错误码十六进制摘要)。
(bool, String) verifyWindowsSslCertificate(Uint8List derCert, String host) {
  if (!Platform.isWindows || derCert.isEmpty || host.trim().isEmpty) {
    return (false, 'invalid-input');
  }
  final derPtr = malloc<Uint8>(derCert.length);
  final oidPtr = _oidPkixKpServerAuth.toNativeUtf8();
  final oidArrPtr = malloc<Pointer<Utf8>>(1);
  final chainPara = calloc<_CertChainPara>();
  final chainCtxPtr = calloc<Pointer<Void>>();
  final hostPtr = host.trim().toNativeUtf16();
  final sslPara = calloc<_SslExtraCertChainPolicyPara>();
  final policyPara = calloc<_CertChainPolicyPara>();
  final policyStatus = calloc<_CertChainPolicyStatus>();

  Pointer<Void> certCtx = nullptr;
  Pointer<Void> chainCtx = nullptr;
  try {
    derPtr.asTypedList(derCert.length).setAll(0, derCert);
    certCtx = _certCreateCertificateContext(
      _x509AndPkcs7Encoding,
      derPtr,
      derCert.length,
    );
    if (certCtx == nullptr) return (false, 'CertCreateCertificateContext=null');

    oidArrPtr[0] = oidPtr;
    chainPara.ref.cbSize = sizeOf<_CertChainPara>();
    chainPara.ref.requestedUsage.dwType = _usageMatchTypeAnd;
    chainPara.ref.requestedUsage.usage.cUsageIdentifier = 1;
    chainPara.ref.requestedUsage.usage.rgpszUsageIdentifier = oidArrPtr;

    final gotChain = _certGetCertificateChain(
      nullptr,
      certCtx,
      nullptr,
      nullptr,
      chainPara,
      0, // 允许 Windows 默认 AIA 补链与系统信任根校验
      nullptr,
      chainCtxPtr,
    );
    chainCtx = chainCtxPtr.value;
    if (gotChain == 0 || chainCtx == nullptr) {
      return (false, 'CertGetCertificateChain=0');
    }

    sslPara.ref.cbSize = sizeOf<_SslExtraCertChainPolicyPara>();
    sslPara.ref.dwAuthType = _authTypeServer;
    sslPara.ref.fdwChecks = 0;
    sslPara.ref.pwszServerName = hostPtr;

    policyPara.ref.cbSize = sizeOf<_CertChainPolicyPara>();
    policyPara.ref.dwFlags = 0;
    policyPara.ref.pvExtraPolicyPara = sslPara.cast<Void>();

    policyStatus.ref.cbSize = sizeOf<_CertChainPolicyStatus>();

    final verified = _certVerifyCertificateChainPolicy(
      Pointer<Void>.fromAddress(_certChainPolicySsl),
      chainCtx,
      policyPara,
      policyStatus,
    );
    if (verified == 0) {
      return (false, 'CertVerifyCertificateChainPolicy=0');
    }
    final err = policyStatus.ref.dwError;
    if (err == 0) return (true, 'ok');
    return (false, '0x${err.toRadixString(16).toUpperCase()}');
  } catch (e) {
    return (false, '$e');
  } finally {
    if (chainCtx != nullptr) _certFreeCertificateChain(chainCtx);
    if (certCtx != nullptr) _certFreeCertificateContext(certCtx);
    malloc
      ..free(derPtr)
      ..free(oidPtr)
      ..free(oidArrPtr)
      ..free(hostPtr);
    calloc
      ..free(chainPara)
      ..free(chainCtxPtr)
      ..free(sslPara)
      ..free(policyPara)
      ..free(policyStatus);
  }
}
