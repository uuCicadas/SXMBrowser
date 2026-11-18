import AppKit

/// Terminates the application immediately when its last window closes so the
/// Dock icon does not linger after closing the browser window.
@MainActor
public final class AppTerminationDelegate: NSObject, NSApplicationDelegate {
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
