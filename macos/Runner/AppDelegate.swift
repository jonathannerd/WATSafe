import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    if let bridge = MacOSSystemLifecycleBridge.shared, bridge.isProtectionArmed {
      return false
    }
    return true
  }

  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if let bridge = MacOSSystemLifecycleBridge.shared, bridge.isProtectionArmed {
      return bridge.handleApplicationShouldTerminate()
    }
    return .terminateNow
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
