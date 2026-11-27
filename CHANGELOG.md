# 更新日志 (Changelog)

本项目遵循语义化版本号规范，记录面向用户的核心变更。

## [3.1.0] - 2026-11-27

### 新增
- **完整 macOS 桌面版支持**：恢复并规范化 `macos/` Xcode 工程（`EzMiGeek.app`、`com.ezer.ezmigeek`、关闭沙盒、补充 macOS 15 局域网权限说明、菜单栏常驻与 Dock 唤醒），实现 macOS Keychain 分服务加密存储、LaunchAgent 开机自启、原生 `osascript` 弹窗、默认浏览器与路由网关识别、苹方字体与原生窗口等比锁。
- **设置卡「当前登录码」行与本地取码服务**：启动自动显示最新登录码，支持整行一键复制与左侧 ↻ 图标随时取新码；新增可选本地回环取码 IPC 服务 `CodeService`（默认仅监听 `127.0.0.1`，可在 `settings.json` 通过 `"LocalCodeService": false` 关闭）。
- **单实例二次启动唤起主窗口**：程序收进系统托盘/菜单栏后再次打开应用，自动唤醒已有实例弹出到前台，不再静默无反应。
- **托盘手动「检查更新」**：右键托盘菜单新增「检查更新」（仅手动触发，后台绝不静默联网）。
- **全局崩溃日志 `crash.log` 与自动日志轮转**：`agent.log` 超过 2 MB 自动滚动归档，未捕获异常自动落盘至 `crash.log`。
- **GitHub Actions 双平台 CI 与自动 Release 构建**：新增 `windows-latest` + `macos-latest` 并行静态检查、单元测试与正式打包（Windows zip + macOS `ditto` 压缩包 + 油猴脚本 + 统一 `SHA256SUMS.txt` 与构建溯源证明）。

### 安全与稳定性加固
- **TLS 证书校验升级**：移除全局无条件 `badCertificateCallback => true`，改为小米官方域名白名单 + Windows 原生 CryptoAPI（`CertGetCertificateChain` / `CertVerifyCertificateChainPolicy`）系统级 SSL 链校验，同时校验换票重定向域名，既兼容缺中间 CA 的机器又杜绝 MITM 风险。
- **降低杀软误报**：清理 `win32.dart` 中未使用的全局键盘/鼠标钩子与 `SendInput` 绑定；全面移除运行期 `powershell.exe`、`reg.exe`、`cmd.exe` 子进程调用，改用 Flutter 原生剪贴板、Win32 `advapi32` 注册表 API、`ShellExecuteW` 与优雅 CDP 关闭。
- **Cookie 采集域隔离**：首次登录与重登时严格按 `.xiaomi.com` / `.mi.com` 过滤 Cookie，防止第三方页面污染。
- **日志脱敏统一**：彻底移除主循环与降级轮向 `agent.log` 打印 6 位明文登录码的行为。
- **文件原子写**：凭据、设置、统计与缓存改用临时文件直接原子覆盖，消除「先删后改名」的丢数据窗口。

### 修复
- 修复「双击托盘图标打开网页」开关未绑定双击事件的问题。
- 修复 `WM_ENTERSIZEMOVE` 错误解引用 `lParam` 导致跨屏重测边框与拖角主导维判定失效的隐患，并清理 C++ 侧重复的 `WM_SIZING` 逻辑。
- 修复非 Chromium 默认浏览器降级成功（`rc=7`）被界面误报为「未知结果」警告的问题。
- 修复每次界面刷新同步拉起 `reg.exe` 查注册表以及频繁重建托盘菜单导致的卡顿。
- 修复手动指定 `HubIp` 省略端口时未按文档回退尝试 80 端口的问题。
- 修复长期常驻托盘跨天后「今天登录次数」未自动归零的问题。
- 修复启动时未登录账号仍盲扫全网段、以及免责声明确认顺序问题。
- 修复 Windows 可执行文件元数据（`Runner.rc`）与窗口初始标题仍显示占位名 `ezmigeek_flutter` 的问题。
- 优化中枢扫描过滤常见虚拟网卡并真正限制验证页面最多读取 64 KB；压缩 `logo.png` 并移除未使用的图标字体依赖。
- 升级油猴脚本至 `3.1.0`：补齐 `@downloadURL`/`@updateURL`、移除全局 `window.MGG.cfg` 敏感凭据暴露、修复虚拟键盘双击、收窄内网非极客版页面的 DOM 扫描。

## [3.0.6] - 2026-10-16

- 自动发现同时支持 `8086`（路由器内置中枢）与 `80`（独立中枢网关）端口并校验极客版页面标题。
- 支持 `--hub` 启动参数与 `settings.json` 的 `HubIp` 手动指定中枢 IP。
- 新增小米云 `localip` 中枢 IP 提示兜底。
- 解决部分 Windows 机器缺失中间 CA 导致无法连接小米云的问题。
