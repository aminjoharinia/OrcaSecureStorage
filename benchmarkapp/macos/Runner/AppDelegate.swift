import Cocoa
import FlutterMacOS

/// True when the app was started by the memory benchmark to measure one
/// storage: it runs without a window, Dock icon or focus.
let isMemoryChild = ProcessInfo.processInfo.environment["MEM_PHASE"] != nil

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationWillFinishLaunching(_ notification: Notification) {
    if isMemoryChild {
      // No Dock icon or menu bar, and no activation.
      NSApp.setActivationPolicy(.accessory)
    }
    super.applicationWillFinishLaunching(notification)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // A memory child has no visible window and exits on its own.
    return !isMemoryChild
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
