import AppKit
import Combine

@MainActor
final class MenuBarController {
    enum Action {
        case openDashboard
        case openOnboarding
        case pause
        case resume
        case checkForUpdates
        case updateCLI
        case repairProviderSoftware
        case exportDiagnostics
        case resetProviderService
        case openSettings
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
        self.statusItem = NSStatusBar.system.statusItem(withLength: MenuBarPresentation.statusItemLength)
        configureButton()
        subscribeToState()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        let icon = MalibuMenuBarIcon.makeTemplate()
        button.image = icon
        button.image?.size = icon.size
        button.image?.accessibilityDescription = "Malibu"
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.title = ""
        button.target = self
        button.action = #selector(statusBarButtonClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func statusBarButtonClicked(_ sender: NSStatusBarButton?) {
        guard let button = sender ?? statusItem.button else { return }
        guard let event = NSApp.currentEvent else {
            onAction(.openDashboard)
            return
        }
        let isMenuClick = event.type == .rightMouseUp
            || (event.type == .leftMouseUp && event.modifierFlags.contains(.control))
        if isMenuClick {
            let menu = buildMenu()
            updateMenu(menu, snapshot: latestSnapshot)
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 2), in: button)
        } else {
            onAction(.openDashboard)
        }
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

        let cliVersionItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        cliVersionItem.identifier = .cliVersionRow
        cliVersionItem.isEnabled = false
        cliVersionItem.isHidden = true
        menu.addItem(cliVersionItem)

        let updateItem = action("Check for Updates…", key: "") {
            if AgentSnapshotPresenter.canRepairProviderSoftware(self.latestSnapshot) {
                self.onAction(.repairProviderSoftware)
            } else {
                self.onAction(.checkForUpdates)
            }
        }
        updateItem.identifier = .updateAction
        menu.addItem(updateItem)

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
        menu.addItem(action(String(localized: "Settings…", comment: "Menu bar settings action"), key: ",") { self.onAction(.openSettings) })
        menu.addItem(action("Set up…", key: "o") { self.onAction(.openOnboarding) })
        menu.addItem(action("Reset Provider Service…", key: "") { self.onAction(.resetProviderService) })
        menu.addItem(action("Export Diagnostics…", key: "") { self.onAction(.exportDiagnostics) })
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
        // #664: menu bar stays icon-only; status/earnings/badges live in
        // tooltip + right-click menu + dashboard.
        latestSnapshot = snapshot
        PublicStatusTransitionDiagnostics.notePresentedSnapshot(snapshot)
        if let button = statusItem.button {
            button.title = MenuBarPresentation.buttonTitle(
                for: snapshot,
                dismissedThreshold: dismissedUnclaimedThreshold
            )
            button.imagePosition = .imageOnly
        }
        statusItem.button?.toolTip = menuTooltip(snapshot)
        statusItem.button?.contentTintColor = snapshot.thermalState?.isMenuBarAttention == true
            ? NSColor.systemOrange
            : nil
    }

    private func updateMenu(_ menu: NSMenu, snapshot: AgentSnapshot) {
        let rewardVerdict = AgentSnapshotPresenter.rewardVerdict(snapshot)
        let badge = AgentSnapshotPresenter.unclaimedBadge(
            snapshot,
            verdict: rewardVerdict,
            dismissedThreshold: dismissedUnclaimedThreshold
        )
        menu.item(withIdentifier: .statusRow)?.title = AgentSnapshotPresenter.stateLine(snapshot)
        menu.item(withIdentifier: .earningsRow)?.title = AgentSnapshotPresenter.earningsLine(snapshot, verdict: rewardVerdict)
        if let cliLine = AgentSnapshotPresenter.cliVersionMenuLine(snapshot),
           let item = menu.item(withIdentifier: .cliVersionRow) {
            item.title = cliLine
            item.isHidden = false
        } else {
            menu.item(withIdentifier: .cliVersionRow)?.isHidden = true
        }
        if let updateItem = menu.item(withIdentifier: .updateAction) {
            updateItem.isHidden = false
            if snapshot.providerSoftwareRepairInProgress {
                updateItem.title = "Repairing provider software…"
                updateItem.isEnabled = false
            } else if AgentSnapshotPresenter.canRepairProviderSoftware(snapshot) {
                updateItem.title = "Repair provider software…"
                updateItem.isEnabled = true
            } else if AgentSnapshotPresenter.updateAvailable(snapshot) {
                updateItem.title = snapshot.cliUpdateInProgress
                    ? "Installing latest provider software…"
                    : "Install latest provider software…"
                updateItem.isEnabled = !snapshot.cliUpdateInProgress
            } else {
                updateItem.title = "Provider software is current"
                updateItem.isEnabled = false
            }
        }
        if let backlog = AgentSnapshotPresenter.backlogLine(snapshot, verdict: rewardVerdict),
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
        let rewardVerdict = AgentSnapshotPresenter.rewardVerdict(snapshot)
        var lines = [
            AgentSnapshotPresenter.stateLine(snapshot),
            AgentSnapshotPresenter.earningsLine(snapshot, verdict: rewardVerdict),
        ]
        if let cliLine = AgentSnapshotPresenter.cliVersionMenuLine(snapshot) {
            lines.append(cliLine)
        }
        lines.append("Click to open dashboard · Right-click for menu")
        return lines.joined(separator: "\n")
    }
}

private extension NSUserInterfaceItemIdentifier {
    static let statusRow = NSUserInterfaceItemIdentifier("malibu.menubar.status")
    static let earningsRow = NSUserInterfaceItemIdentifier("malibu.menubar.earnings")
    static let cliVersionRow = NSUserInterfaceItemIdentifier("malibu.menubar.cliVersion")
    static let updateAction = NSUserInterfaceItemIdentifier("malibu.menubar.update")
    static let backlogRow = NSUserInterfaceItemIdentifier("malibu.menubar.backlog")
    static let dismissBacklogBadge = NSUserInterfaceItemIdentifier("malibu.menubar.dismissBacklogBadge")
}

private extension NSMenu {
    func item(withIdentifier id: NSUserInterfaceItemIdentifier) -> NSMenuItem? {
        items.first { $0.identifier == id }
    }
}
