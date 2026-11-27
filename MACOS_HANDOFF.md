# macOS 端 Antigravity 接力测试与发布指南

本文档用于 Windows 端完成跨平台改造后，在 macOS 电脑上直接接力编译、真机实测并合入发版。

## 一、Windows 端已完成的 macOS 适配清单

- **Xcode 工程与权限**（`macos/` 已恢复并入库）：
  - `AppInfo.xcconfig`、`project.pbxproj`、`Runner.xcscheme` 全部统一为 `EzMiGeek.app`、`com.ezer.ezmigeek`，免证书 ad-hoc 签名（`CODE_SIGN_IDENTITY = "-"`），部署目标 `macOS 12.0+`。
  - `Release.entitlements` & `DebugProfile.entitlements` 已关闭 App Sandbox（否则无法拉起外部 Chromium、读写 Keychain 与 LaunchAgent），开启 `network.client` / `network.server`。
  - `Info.plist` 已补充 macOS 15 Sequoia 必需的 `NSLocalNetworkUsageDescription`。
  - `AppDelegate.swift` 已改为托盘常驻（`applicationShouldTerminateAfterLastWindowClosed = false`），并实现 `applicationShouldHandleReopen`（点 Dock 图标重新弹出主面板）。
- **跨平台 Dart 核心层**：
  - 路径与目录（`lib/core/app_dirs.dart` 等）：全库已消除硬编码 `\\`，macOS 数据目录落 `~/Library/Application Support/EzMiGeek`。
  - 凭据与缓存加密（`lib/services/dpapi.dart` + `lib/mijia/mijia_cloud.dart`）：走 `/usr/bin/security` 系统登录钥匙串，**凭据与 token 缓存分服务名（`EzMiGeek.credentials` vs `EzMiGeek.token-cache`）**，兼容旧 Mac 分发版读取；TLS 走 macOS 原生系统根证书库。
  - 开机自启（`lib/services/autostart.dart`）：读写标准 `~/Library/LaunchAgents/com.ezer.ezmigeek.plist`。
  - 浏览器与中枢（`lib/browser/browser_ctl.dart` + `lib/mijia/hub_discovery.dart`）：支持 LaunchServices 解析默认浏览器、macOS Chromium 路径候选、`/sbin/route -n get default` 网关识别、AppleScript 窗口置前与弹窗、`/usr/bin/open` 打开文件/目录/降级 URL。
  - 窗口、字体与托盘（`lib/ui/window_fit.dart`、`lib/ui/ezshell.dart`、`lib/main.dart`）：使用 `PingFang SC` 字体、`windowManager.startDragging()` 拖窗、`setAspectRatio` 等比锁与 PNG 托盘图标。
  - 所有 Win32 FFI 绑定均为 `late final` 惰性初始化，macOS 上不会触发任何 Windows DLL 加载。

---

## 二、Mac 端 Antigravity 接手步骤

1. 拉取当前分支并执行基础编译测试：
   ```bash
   flutter pub get
   flutter analyze
   flutter test
   flutter build macos --release --dart-define=APP_VERSION=3.1.0
   ```
2. 若 Xcode/CocoaPods 报插件依赖或 Swift 版本告警，在 `macos/` 下优先执行 `pod install --repo-update` 排查；确认不把个人 `DEVELOPMENT_TEAM` 提交到 `project.pbxproj`（保持 `CODE_SIGN_IDENTITY = "-"` 以便 GitHub Actions 免证书构建）。
3. 打开生成的 `build/macos/Build/Products/Release/EzMiGeek.app` 逐项真机实测：
   - [ ] 首次免责声明原生 `osascript` 弹窗显示清晰，点取消退出、点确定进入主窗；
   - [ ] 主界面玻璃画布比例无露边、空白处拖动顺畅、等比缩放正常、苹方字体清晰；
   - [ ] 顶部菜单栏托盘图标清晰，单击唤面板、双击按设置开关生效、右键菜单齐全；关窗隐藏后点 Dock 图标可重新唤出主面板；
   - [ ] 首次登录小米账号后，Keychain 写入 `EzMiGeek.credentials` 成功，重启后免重登且设置卡行 0 正常显示 6 位登录码；
   - [ ] 局域网中枢发现正常（如遇 macOS 15 本地网络弹窗点击允许），Chrome / Edge 独立 profile 启动并自动 CDP 填码成功；
   - [ ] 如选 Safari / Firefox 为默认浏览器，降级轮能打开网页并把 6 位码复制到剪贴板；
   - [ ] 拨动「开机自动启动」开关，检查 `~/Library/LaunchAgents/com.ezer.ezmigeek.plist` 创建与删除正常；
   - [ ] 如首次启动 Chrome/Edge 独立 profile 时 macOS 弹「Chromium Safe Storage」钥匙串提示且影响体验，再按需评估在 macOS 启动参数中增加 `--use-mock-keychain`。

---

## 三、测通后统一发版

1. 在 Mac 端提交并推送所有 macOS 实测微调：
   ```bash
   git add -A
   git commit -m "feat(macos): 完成 Mac 端真机验证与适配微调"
   git push origin feat/macos
   ```
2. 在 GitHub 上将 `feat/macos` 合并到 `main`（先看 `CI` 中 `windows-latest` 与 `macos-latest` 两个勾全绿）。
3. 推送发版 Tag，自动触发双平台并行编译与统一 Release 发布：
   ```bash
   git checkout main && git pull
   git tag v3.1.0
   git push origin v3.1.0
   ```
   数分钟后 GitHub Release 会自动上架 `EzMiGeek-win64-v3.1.0.zip`、`EzMiGeek-macos-arm64-v3.1.0.zip`、`EzMiGeek-script.user.js` 与统一的 `SHA256SUMS.txt`。
