import AppKit
import SwiftUI

@MainActor
final class SettingsWindowPresenter {
    static let shared = SettingsWindowPresenter()

    private var window: NSWindow?
    /// Set by the app delegate so Settings can show the payout wallet.
    weak var agent: MalibuAgent?

    @discardableResult
    func present() -> NSWindow {
        let window = window ?? makeWindow()
        self.window = window
        DockPresenceController.shared.present(window)
        return window
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: MalibuSettingsView(agent: agent)))
        window.title = "Malibu Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 560, height: 680))
        window.center()
        return window
    }
}
