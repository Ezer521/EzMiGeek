# 更新日志 (Changelog)

本项目遵循语义化版本号规范，记录面向用户的核心变更。

## [3.1.0] - 2026-11-27

### 新增
- **完整 macOS 桌面版支持（Apple Silicon / macOS 12+）**：接入原生左上红绿灯与镜像头部排布（支持窗口失焦灰化）、菜单栏托盘常驻与 Dock 唤起、Keychain 分服务加密存储、LaunchAgent 开机自启、原生 `osascript` 弹窗、默认浏览器与路由网关识别、苹方字体与原生等比锁，并补齐 macOS 15 本地网络权限说明。
- **设置卡「当前登录码」行与本地取码服务**：启动自动显示最新 6 位码，支持整行一键复制与左侧 ↻ 图标随时取新码；新增可选本机回环取码 IPC 服务 `CodeService`（默认仅监听 `127.0.0.1`，可在 `settings.json` 通过 `"LocalCodeService": false` 关闭）。
- **单实例二次启动唤起主窗口** & **托盘右键「检查更新」**（仅手动触发，后台绝不静默联网）。
- **登录过渡体验升级**：首次/重新登录小米账号后将空白 `ok` 页替换为清晰过渡指引，并同步面板状态。
- **全局崩溃日志 `crash.log` 与自动日志轮转**：`agent.log` 超过 2 MB 自动滚动归档，未捕获异常自动落盘至 `crash.log`。
- **GitHub Actions 双平台 CI 与自动 Release 构建**：`windows-latest` + `macos-latest` 并行静态检查、单元测试与正式打包（附带统一 `SHA256SUMS.txt` 与构建溯源证明）。

### 安全与稳定性加固
- **TLS 证书校验升级**：Windows 端移除全局无条件放行坏证书，改为小米官方域名白名单 + 原生 CryptoAPI（`CertGetCertificateChain` / `CertVerifyCertificateChainPolicy`）系统级 SSL 链校验，同时校验换票重定向域名；macOS 直接走系统严格 TLS 校验。
- **降低杀软误报**：清理 `win32.dart` 中未使用的全局键盘/鼠标钩子与 `SendInput` 绑定；全面移除运行期 `powershell.exe`、`reg.exe`、`cmd.exe` 子进程调用，改用原生 API 与优雅 CDP 关闭。
- **局域网与 CDP 强制直连绕过系统代理**：修复开启系统代理/Clash 时连不上局域网中枢或本机 CDP 的隐患，并细分环境失败原因与指引。
- **Cookie 采集域隔离 & 日志脱敏统一**：严格按 `.xiaomi.com` / `.mi.com` 过滤 Cookie；彻底移除主循环与降级轮向 `agent.log` 打印 6 位明文登录码的行为。
- **文件原子写**：凭据、设置、统计与缓存改用临时文件直接原子覆盖，消除「先删后改名」的丢数据窗口。

### 修复与优化
- 修复「双击托盘图标打开网页」开关未接线、托盘菜单高频重建与竞态问题。
- 修复 `WM_ENTERSIZEMOVE` 错误解引用 `lParam` 隐患并清理 C++ 侧重复 `WM_SIZING` 逻辑。
- 修复非 Chromium 默认浏览器降级成功（`rc=7`）被误报为「未知结果」警告的问题。
- 修复手动指定 `HubIp` 省略端口时未回退 80 端口、长期常驻跨天后今日登录次数不清零、启动未登录盲扫全网段等问题。
- 迁移至纯 `flutter/widgets.dart` 的 `WidgetsApp` 消除 Flutter 3.50+ 警告；修正 Windows/macOS 产物元数据、压缩 `logo.png` 并移除未使用字体依赖。
- 升级油猴脚本至 `3.1.0`：补齐 `@downloadURL`/`@updateURL`、移除全局 `window.MGG.cfg` 敏感凭据暴露、修复虚拟键盘双击、收窄内网非极客版页面扫描。

## [3.0.6] - 2026-10-16

- 自动发现同时支持 `8086`（路由器内置中枢）与 `80`（独立中枢网关）端口并校验极客版页面标题。
- 支持 `--hub` 启动参数与 `settings.json` 的 `HubIp` 手动指定中枢 IP。
- 新增小米云 `localip` 中枢 IP 提示兜底。
- 解决部分 Windows 机器缺失中间 CA 导致无法连接小米云的问题。
