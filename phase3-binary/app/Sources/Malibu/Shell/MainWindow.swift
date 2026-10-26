import AppKit
import SwiftUI

/// The sidebar sections of the main window (SPEC-025-R001). The order is the
/// order shown; `isUtility` sections sit below the divider.
enum MalibuSection: String, CaseIterable, Identifiable, Hashable {
    case chat
    case terminal
    case create
    case agents
    case tasks
    case models
    case earn
    case settings
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: return String(localized: "Chat", comment: "Sidebar section")
        case .terminal: return String(localized: "Terminal", comment: "Sidebar section")
        case .create: return "Create"
        case .agents: return "Agents"
        case .tasks: return "Tasks"
        case .models: return String(localized: "Models", comment: "Sidebar section")
        case .earn: return String(localized: "Earn", comment: "Sidebar section")
        case .settings: return String(localized: "Settings", comment: "Sidebar section")
        case .diagnostics: return String(localized: "Diagnostics", comment: "Sidebar section")
        }
    }

    var systemImage: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right"
        case .terminal: return "terminal"
        case .create: return "paintbrush.pointed"
        case .agents: return "person.crop.rectangle.stack"
        case .tasks: return "checklist"
        case .models: return "square.stack.3d.up"
        case .earn: return "dollarsign.circle"
        case .settings: return "gearshape"
        case .diagnostics: return "stethoscope"
        }
    }

    static func migrated(_ value: String) -> MalibuSection? {
        switch value {
        case "dashboard", "provider": return .earn
        case "discover": return .models
        case "connectedApps": return .terminal
        default: return Self(rawValue: value)
        }
    }

    var isUtility: Bool { self == .settings || self == .diagnostics }
    static var primary: [MalibuSection] { allCases.filter { !$0.isUtility } }
    static var utility: [MalibuSection] { allCases.filter(\.isUtility) }
}

/// One navigation owner retains model-tab destinations when restoring legacy links.
@MainActor
final class MalibuNavigation: ObservableObject {
    @Published var selection: MalibuSection? = .chat
    @Published var modelsTab: ModelsHubTab = .recommended

    init(persistedValue: String? = nil) {
        if let persistedValue { showPersistedValue(persistedValue) }
    }

    func show(_ section: MalibuSection) { selection = section }

    func showModels(_ tab: ModelsHubTab) {
        modelsTab = tab
        selection = .models
    }

    func showPersistedValue(_ value: String) {
        if value == "discover" { modelsTab = .browse }
        selection = MalibuSection.migrated(value) ?? .chat
    }
}

/// Text that came from the provider (status, logs, lifecycle) is shown as
/// one plain line: control, format (including bidi overrides) and separator
/// characters are dropped and the length is capped.
enum ShellText {
    static func display(_ text: String, maxLength: Int = 240) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned:
                if scalar == "\n" || scalar == "\t" { out.append(" ") }
            default:
                out.append(scalar)
            }
        }
        let line = String(out)
        guard line.count > maxLength else { return line }
        return String(line.prefix(maxLength - 1)) + "…"
    }
}

/// Sidebar footer: the loaded model and one health line (SPEC-025-R002).
enum ShellSidebarPresentation {
    /// Only the model the provider reports in status counts as loaded; a
    /// model merely named in the config is not shown as loaded.
    static func footerModel(_ snapshot: AgentSnapshot) -> String {
        guard let model = snapshot.currentModelID, !model.isEmpty else {
            return String(localized: "No model loaded", comment: "Sidebar footer without a model")
        }
        return ShellText.display(shortModelName(model), maxLength: 80)
    }

    /// The last path component of a model id ("mlx-community/Qwen3-8B-4bit"
    /// becomes "Qwen3-8B-4bit"); the full id stays in the help tag.
    static func shortModelName(_ id: String) -> String {
        id.split(separator: "/").last.map(String.init) ?? id
    }

    static func footerHealth(_ snapshot: AgentSnapshot) -> String? {
        var parts: [String] = []
        if let slots = snapshot.advertisedMaxConcurrency {
            parts.append(slots == 1
                ? String(localized: "1 slot", comment: "Sidebar footer slot count")
                : String(localized: "\(slots) slots", comment: "Sidebar footer slot count"))
        }
        if let thermal = snapshot.thermalState {
            switch thermal {
            case .nominal: parts.append(String(localized: "cool", comment: "Sidebar footer thermal"))
            case .fair: parts.append(String(localized: "warm", comment: "Sidebar footer thermal"))
            case .serious: parts.append(String(localized: "hot", comment: "Sidebar footer thermal"))
            case .critical: parts.append(String(localized: "throttled by heat", comment: "Sidebar footer thermal"))
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

@MainActor
enum DashboardWindow {
    static let minimumContentSize = NSSize(width: 820, height: 560)
    static let defaultContentSize = NSSize(width: 1040, height: 740)

    static func make(
        agent: MalibuAgent,
        navigation: MalibuNavigation = MalibuNavigation(),
        onExportDiagnostics: @escaping () -> Void,
        onResetProvider: @escaping () -> Void
    ) -> NSWindow {
        let hosting = NSHostingController(rootView: MainShellView(
            agent: agent,
            navigation: navigation,
            onExportDiagnostics: onExportDiagnostics,
            onResetProvider: onResetProvider
        ))
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.title = "Malibu"
        window.contentMinSize = minimumContentSize
        window.setContentSize(defaultContentSize)
        window.center()
        window.isReleasedWhenClosed = false
        return window
    }
}

struct MainShellView: View {
    @ObservedObject var agent: MalibuAgent
    @ObservedObject var navigation: MalibuNavigation
    let onExportDiagnostics: () -> Void
    let onResetProvider: () -> Void
    @ObservedObject private var modelStore = ModelManagementStore.shared
    @StateObject private var terminalWorkspace = TerminalWorkspace()
    @StateObject private var createStore = CreateStore()

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            // A minimum width keeps wrapped text from being measured at zero
            // width, which made fixed-height text columns overflow the window.
            detail
                .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        // Fill the window: without a max frame the split view takes the
        // sidebar list's ideal height and overflows the window.
        .frame(
            minWidth: DashboardWindow.minimumContentSize.width,
            maxWidth: .infinity,
            minHeight: DashboardWindow.minimumContentSize.height,
            maxHeight: .infinity
        )
        // One refresh for every screen: the model projection follows each new
        // provider status observation.
        .task(id: "\(agent.snapshot.localProviderID ?? "unknown"):\(agent.snapshot.statusObservationID ?? "unknown")") {
            if agent.snapshot.localProviderID != nil {
                await agent.refreshPayoutRegistration()
            }
            await modelStore.refresh(
                currentModelID: agent.snapshot.currentModelID,
                peer: MalibuModelPeerEvidence(snapshot: agent.snapshot),
                background: true
            )
            await modelStore.startBackgroundCheckIfEligible(thermalState: agent.snapshot.thermalState)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                MalibuBrandTile()
                    .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Malibu")
                        .font(.system(size: 14, weight: .semibold))
                    StatusPillView(pill: AgentSnapshotPresenter.statusPill(agent.snapshot))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.top, 34)
            .padding(.bottom, 10)

            List(selection: $navigation.selection) {
                Section {
                    ForEach(MalibuSection.primary) { section in
                        Label(section.title, systemImage: section.systemImage)
                            .tag(section)
                            .accessibilityIdentifier("malibu.sidebar.\(section.rawValue)")
                    }
                }
                Section {
                    ForEach(MalibuSection.utility) { section in
                        Label(section.title, systemImage: section.systemImage)
                            .tag(section)
                            .accessibilityIdentifier("malibu.sidebar.\(section.rawValue)")
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            VStack(alignment: .leading, spacing: 2) {
                Text(ShellSidebarPresentation.footerModel(agent.snapshot))
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(ShellText.display(agent.snapshot.currentModelID ?? ""))
                if let health = ShellSidebarPresentation.footerHealth(agent.snapshot) {
                    Text(health)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("malibu.sidebar.footer")
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch navigation.selection ?? .chat {
        case .earn:
            EarnScreen(
                agent: agent,
                navigate: navigation.show,
                browseModels: { navigation.showModels(.browse) },
                onThisMacModels: { navigation.showModels(.onThisMac) },
                onExportDiagnostics: onExportDiagnostics,
                onResetProvider: onResetProvider
            )
        case .chat:
            ChatScreen(agent: agent)
        case .terminal:
            TerminalScreen(workspace: terminalWorkspace)
        case .create:
            CreateScreen(store: createStore)
        case .agents:
            AgentsScreen(store: AgentTaskRuntime.shared.agents)
        case .tasks:
            TasksScreen(store: AgentTaskRuntime.shared.tasks, scheduler: AgentTaskRuntime.shared.scheduler, agents: AgentTaskRuntime.shared.agents)
        case .models:
            ModelsHubScreen(store: modelStore, agent: agent, selection: $navigation.modelsTab)
        case .settings:
            SettingsScreen(agent: agent)
        case .diagnostics:
            DiagnosticsScreen(
                agent: agent,
                onExportDiagnostics: onExportDiagnostics,
                onResetProvider: onResetProvider
            )
        }
    }
}

/// The single status pill: colour plus a text label, never colour alone.
struct StatusPillView: View {
    let pill: AgentSnapshotPresenter.StatusPill

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(pill.label)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.14)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pill.accessibilityLabel)
        .accessibilityIdentifier("malibu.dashboard.status-pill")
    }

    private var color: Color {
        switch pill.tone {
        case .positive: return .green
        case .neutral: return .secondary
        case .attention: return .red
        }
    }
}

/// A rounded panel used by every screen.
struct ShellPanel<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.gray.opacity(0.18), lineWidth: 1)
                )
        )
    }
}

/// A label/value pair used by the Provider, Diagnostics and Settings screens.
struct MetricRow: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }
}
