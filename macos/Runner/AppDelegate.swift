import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  // 托盘常驻模式：关闭/隐藏窗口时应用继续驻留菜单栏，彻底退出走托盘菜单。
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  // 窗口隐藏到托盘或最小化到 Dock 后，点击 Dock 图标或再次打开应用时把主窗口重新唤回前台。
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag, let window = mainFlutterWindow {
      if window.isMiniaturized {
        window.deminiaturize(nil)
      }
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
    }
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
