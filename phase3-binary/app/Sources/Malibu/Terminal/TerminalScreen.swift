import SwiftUI
import SwiftTerm

struct TerminalScreen: View {
    @ObservedObject private var tabs: TerminalTabs
    @ObservedObject private var catalog: HarnessCatalog
    @ObservedObject private var models: ConnectedAppsStore

    init(workspace: TerminalWorkspace) {
        tabs = workspace.tabs
        catalog = workspace.catalog
        models = workspace.models
    }
    @State private var otherApps = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Terminal").font(.title2.weight(.semibold))
                Spacer()
                Button(otherApps ? "Terminal tabs" : "Other apps") { otherApps.toggle() }
            }
            if otherApps {
                ConnectedAppsScreen()
            } else {
                Text(ConnectedAppConfiguration.keyExposure).font(.caption).foregroundStyle(.orange)
                HStack {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(tabs.sessions) { session in
                                Button(session.harness.title) { tabs.selection = session.id }
                                    .tint(tabs.selection == session.id ? .accentColor : .secondary)
                                Button { tabs.close(session) } label: { Image(systemName: "xmark") }
                                    .help("Close \(session.harness.title)")
                            }
                        }
                    }
                    Menu {
                        ForEach(TerminalHarness.allCases) { harness in
                            Button(catalog.isInstalled(harness) ? harness.title : "\(harness.title) — Not installed") {
                                _ = tabs.add(harness)
                            }
                            .disabled(!catalog.isInstalled(harness) || tabs.sessions.count >= TerminalTabs.limit)
                        }
                    } label: { Image(systemName: "plus") }
                    .help("New terminal tab (up to 8)")
                }
                if let session = tabs.sessions.first(where: { $0.id == tabs.selection }) {
                    TerminalTabView(session: session, executable: catalog.executables[session.harness], models: models) {
                        otherApps = true
                    }
                    .id(session.id)
                } else {
                    Text("Open a Shell or coding harness with +.").foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .padding(20)
        .task { await catalog.detect() }
    }
}

private struct TerminalTabView: View {
    @ObservedObject var session: TerminalSession
    let executable: URL?
    @ObservedObject var models: ConnectedAppsStore
    let showOtherApps: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(ShellText.display(session.workingDirectory.path)).font(.caption).lineLimit(1)
                Button("Working folder…") { session.chooseFolder() }.disabled(session.started)
            }
            if session.harness == .claudeCode && !session.started {
                HStack {
                    Button("Load gateway models") { models.loadModels() }
                    Picker("Gateway model", selection: $models.modelID) {
                        Text("Choose a gateway model").tag("")
                        ForEach(models.models) { Text($0.id).tag($0.id) }
                    }
                }
                if let message = models.modelsMessage { Text(message).font(.caption) }
            }
            if session.harness == .crush {
                Text(ConnectedAppConfiguration.crushProjectConfigWarning).font(.caption).foregroundStyle(.orange)
            }
            if let message = session.message { Text(message).font(.callout) }
            if let view = session.terminalView {
                EmbeddedTerminal(view: view)
            } else {
                HStack {
                    Button("Start \(session.harness.title)") {
                        session.start(executable: executable, model: models.selectedModel)
                    }
                    if session.harness != .shell { Button("Other apps", action: showOtherApps) }
                }
                if session.harness != .shell && !ConnectedBuyerKeychain.exists() {
                    Text("Add a buyer key in Other apps")
                }
                Spacer()
            }
        }
    }
}

private struct EmbeddedTerminal: NSViewRepresentable {
    let view: LocalProcessTerminalView
    func makeNSView(context: Context) -> LocalProcessTerminalView { view }
    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}
