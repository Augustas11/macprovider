import AppKit
import Combine

@MainActor
final class MenuBarController {
    enum Action {
        case openDashboard
        case openOnboarding
        case pause
        case resume
        case quitAndUninstall
    }

    private let statusItem: NSStatusItem
    private let agent: MalibuAgent
    private let onAction: (Action) -> Void
    private var cancellables: Set<AnyCancellable> = []

    init(agent: MalibuAgent, onAction: @escaping (Action) -> Void) {
        self.agent = agent
        self.onAction = onAction
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureButton()
        subscribeToState()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = MalibuMenuBarIcon.makeTemplate(pointSize: 18)
        button.image?.accessibilityDescription = "Malibu"
        button.imagePosition = .imageLeft
        button.title = ""
        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let statusItem = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
        statusItem.identifier = .statusRow
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        let earningsItem = NSMenuItem(title: "Today: $0.00", action: nil, keyEquivalent: "")
        earningsItem.identifier = .earningsRow
        earningsItem.isEnabled = false
        menu.addItem(earningsItem)

        let backlogItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        backlogItem.identifier = .backlogRow
        backlogItem.isEnabled = false
        backlogItem.isHidden = true
        menu.addItem(backlogItem)

        menu.addItem(.separator())
        menu.addItem(action("Open Dashboard", key: "d") { self.onAction(.openDashboard) })
        menu.addItem(action("Set up…", key: "o") { self.onAction(.openOnboarding) })
        menu.addItem(.separator())
        menu.addItem(action("Pause", key: "") { self.onAction(.pause) })
        menu.addItem(action("Resume", key: "") { self.onAction(.resume) })
        menu.addItem(.separator())
        menu.addItem(action("Quit and Uninstall…", key: "") { self.onAction(.quitAndUninstall) })
        menu.addItem(action("Quit", key: "q") { NSApp.terminate(nil) })
        return menu
    }

    private func action(_ title: String, key: String, handler: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(dispatch(_:)), keyEquivalent: key)
        item.target = self
        item.representedObject = handler
        return item
    }

    @objc private func dispatch(_ sender: NSMenuItem) {
        (sender.representedObject as? () -> Void)?()
    }

    private func subscribeToState() {
        agent.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in
                self?.render(snapshot)
            }
            .store(in: &cancellables)
    }

    private func render(_ snapshot: AgentSnapshot) {
        // AUDIT R1 ARCHITECT A5: view strings live in the presenter, not the
        // snapshot data type. This lets locale/currency work touch one place.
        statusItem.button?.title = AgentSnapshotPresenter.short(snapshot)
        guard let menu = statusItem.menu else { return }
        menu.item(withIdentifier: .statusRow)?.title = AgentSnapshotPresenter.stateLine(snapshot)
        menu.item(withIdentifier: .earningsRow)?.title = AgentSnapshotPresenter.earningsLine(snapshot)
        if let backlog = AgentSnapshotPresenter.backlogLine(snapshot),
           let item = menu.item(withIdentifier: .backlogRow) {
            item.title = backlog
            item.isHidden = false
        } else {
            menu.item(withIdentifier: .backlogRow)?.isHidden = true
        }
    }
}

private extension NSUserInterfaceItemIdentifier {
    static let statusRow = NSUserInterfaceItemIdentifier("malibu.menubar.status")
    static let earningsRow = NSUserInterfaceItemIdentifier("malibu.menubar.earnings")
    static let backlogRow = NSUserInterfaceItemIdentifier("malibu.menubar.backlog")
}

private extension NSMenu {
    func item(withIdentifier id: NSUserInterfaceItemIdentifier) -> NSMenuItem? {
        items.first { $0.identifier == id }
    }
}
