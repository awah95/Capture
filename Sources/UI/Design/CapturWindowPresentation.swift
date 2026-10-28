import AppKit

/// Keeps Captur's ordinary windows focusable without turning the menu-bar app into a
/// permanent Dock app. Every window follows the same activation order and restores
/// accessory mode only after its last focusable window leaves the screen.
@MainActor
enum CapturWindowPresentation {
    static func present(_ controller: NSWindowController) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.orderFrontRegardless()
    }

    /// AppKit calls `windowWillClose` while the closing window is still visible. The
    /// explicit exclusion prevents that window from keeping Captur in `.regular` mode.
    static func restoreAccessoryPolicy(excluding closingWindow: NSWindow?) {
        guard !windowsWantRegularPolicy(in: NSApp.windows, excluding: closingWindow) else {
            return
        }
        NSApp.setActivationPolicy(.accessory)
    }

    /// Pure classification seam used by tests. A HUD is an `NSPanel`, never a reason
    /// to keep a Dock tile or application focus alive.
    static func windowsWantRegularPolicy(
        in windows: [NSWindow],
        excluding closingWindow: NSWindow? = nil
    ) -> Bool {
        windows.contains { window in
            guard window !== closingWindow,
                  window.isVisible,
                  window.canBecomeKey,
                  !(window is NSPanel) else {
                return false
            }
            return true
        }
    }
}
