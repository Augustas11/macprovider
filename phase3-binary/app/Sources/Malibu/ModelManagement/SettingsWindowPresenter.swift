import AppKit
import SwiftUI

@MainActor
final class SettingsWindowPresenter {
    static let shared = SettingsWindowPresenter()

    private var window: NSWindow?

    @discardableResult
    func present() -> NSWindow {
        let window = window ?? makeWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return window
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: ModelSettingsView()))
        window.title = "Malibu Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 560, height: 520))
        window.center()
        return window
    }
}
