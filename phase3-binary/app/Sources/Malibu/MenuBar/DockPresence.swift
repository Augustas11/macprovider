import AppKit

/// Dock and Cmd-Tab presence while a Malibu window is open (#2029 P1-21,
/// SPEC-025 §3.1). The app launches as a menu-bar agent (`LSUIElement`);
/// presenting a window switches it to `.regular`, and closing the last one
/// returns it to `.accessory`, so login launch stays Dock-less.
@MainActor
final class DockPresenceController {
    static let shared = DockPresenceController()

    /// Test seam; production applies the policy to NSApp.
    var applyPolicy: (NSApplication.ActivationPolicy) -> Void = { policy in
        _ = NSApp.setActivationPolicy(policy)
    }
    var activate: () -> Void = { NSApp.activate(ignoringOtherApps: true) }

    private var tracked: [ObjectIdentifier: (window: NSWindow, token: NSObjectProtocol)] = [:]
    private(set) var keepsDockIcon = false

    /// Keeps Malibu in the Dock even with no open windows. Windows still use
    /// regular activation while open so their main menu and Cmd-Tab presence
    /// remain predictable when this preference is off.
    func setKeepsDockIcon(_ enabled: Bool) {
        keepsDockIcon = enabled
        if enabled || hasOpenWindow {
            applyPolicy(.regular)
        } else {
            applyPolicy(.accessory)
        }
    }

    /// Shows `window` with the app in the Dock and the Cmd-Tab switcher.
    func present(_ window: NSWindow) {
        track(window)
        applyPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        activate()
    }

    var trackedWindowCount: Int { tracked.count }

    private func track(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        guard tracked[id] == nil else { return }
        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] note in
            guard let closing = note.object as? NSWindow else { return }
            MainActor.assumeIsolated { self?.windowWillClose(closing) }
        }
        tracked[id] = (window, token)
    }

    func windowWillClose(_ window: NSWindow) {
        if let entry = tracked.removeValue(forKey: ObjectIdentifier(window)) {
            NotificationCenter.default.removeObserver(entry.token)
        }
        if !hasOpenWindow && !keepsDockIcon {
            applyPolicy(.accessory)
        }
    }

    private var hasOpenWindow: Bool {
        tracked.values.contains { $0.window.isVisible || $0.window.isMiniaturized }
    }
}
