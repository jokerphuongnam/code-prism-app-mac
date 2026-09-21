import AppKit

/// Keeps the app alive when duplicate windows are collapsed (avoids SIGTERM-on-quit).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
