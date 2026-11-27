# 安全政策 (Security Policy)

## 支持的版本

目前仅对最新发布的版本提供安全维护：

| 版本 | 是否支持 |
| --- | --- |
| 3.1.x | ✅ 支持 |
| < 3.1.0 | ❌ 不再维护，请升级至最新版 |

## 安全设计边界

- **凭据加密**：桌面版小米登录凭据使用 Windows DPAPI（`CryptProtectData`）加密并绑定当前 Windows 用户，存放在 `%LOCALAPPDATA%\EzMiGeek\config.json`。
- **传输安全**：小米官方接口仅走 HTTPS，且在 BoringSSL 缺中间 CA 时仅针对小米官方白名单域调用 Windows 原生 CryptoAPI 做系统级证书链与主机名校验，不会放行自签名或不可信证书；换票重定向同样严格限制在小米官方域内。
- **本地 IPC 边界**：`CodeService` 默认仅监听回环地址 `127.0.0.1` 随机端口，校验回环 `Host` 头与 64 位随机 `token`，并可在 `settings.json` 中通过 `"LocalCodeService": false` 关闭。
- **日志脱敏**：运行日志不记录 6 位登录码明文、Cookie、Token 或 `ssecurity`。

## 报告安全漏洞

如果你发现安全隐患（例如凭据泄露、证书校验绕过、本地 IPC 越权等），请**不要**直接在公开 Issue 中披露利用细节，请通过以下方式私下联系：

- 使用 GitHub 仓库的 **Security → Advisories → Report a vulnerability**（若已启用）；
- 或通过 Issue 留言说明「需私下反馈安全问题」，维护者会尽快联系确认并在修复后统一披露致谢。
