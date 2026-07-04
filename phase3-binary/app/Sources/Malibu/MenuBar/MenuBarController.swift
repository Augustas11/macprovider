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
    private var dismissalStore: UnclaimedBadgeDismissalStore
    private var cancellables: Set<AnyCancellable> = []
    private var latestSnapshot: AgentSnapshot = .empty
    private var dismissedUnclaimedThreshold: Double?

    init(
        agent: MalibuAgent,
        dismissalStore: UnclaimedBadgeDismissalStore = UnclaimedBadgeDismissalStore(),
        onAction: @escaping (Action) -> Void
    ) {
        self.agent = agent
        self.dismissalStore = dismissalStore
        self.dismissedUnclaimedThreshold = dismissalStore.dismissedThreshold
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

        let dismissBadgeItem = action("Dismiss Unclaimed Badge", key: "") { self.dismissUnclaimedBadge() }
        dismissBadgeItem.identifier = .dismissBacklogBadge
        dismissBadgeItem.isHidden = true
        menu.addItem(dismissBadgeItem)

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
        latestSnapshot = snapshot
        let badge = AgentSnapshotPresenter.unclaimedBadge(snapshot, dismissedThreshold: dismissedUnclaimedThreshold)
        let queueDot = (snapshot.queueDepth ?? 0) > 0 ? "•" : nil
        statusItem.button?.title = [AgentSnapshotPresenter.short(snapshot), badge, queueDot].compactMap { $0 }.joined(separator: " ")
        statusItem.button?.toolTip = menuTooltip(snapshot)
        statusItem.button?.contentTintColor = snapshot.thermalState?.isMenuBarAttention == true
            ? NSColor.systemOrange
            : nil
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
        menu.item(withIdentifier: .dismissBacklogBadge)?.isHidden = badge == nil
    }

    private func dismissUnclaimedBadge() {
        guard let total = AgentSnapshotPresenter.unclaimedBacklogTotal(latestSnapshot),
              let threshold = UnclaimedBadgePolicy.nextDismissedThreshold(totalBacklog: total) else {
            return
        }
        dismissedUnclaimedThreshold = threshold
        dismissalStore.dismissedThreshold = threshold
        render(latestSnapshot)
    }

    private func menuTooltip(_ snapshot: AgentSnapshot) -> String {
        [
            AgentSnapshotPresenter.stateLine(snapshot),
            AgentSnapshotPresenter.earningsLine(snapshot),
            AgentSnapshotPresenter.queueChip(snapshot),
            AgentSnapshotPresenter.thermalChip(snapshot)
        ].joined(separator: "\n")
    }
}

private extension NSUserInterfaceItemIdentifier {
    static let statusRow = NSUserInterfaceItemIdentifier("malibu.menubar.status")
    static let earningsRow = NSUserInterfaceItemIdentifier("malibu.menubar.earnings")
    static let backlogRow = NSUserInterfaceItemIdentifier("malibu.menubar.backlog")
    static let dismissBacklogBadge = NSUserInterfaceItemIdentifier("malibu.menubar.dismissBacklogBadge")
}

private extension NSMenu {
    func item(withIdentifier id: NSUserInterfaceItemIdentifier) -> NSMenuItem? {
        items.first { $0.identifier == id }
    }
}
