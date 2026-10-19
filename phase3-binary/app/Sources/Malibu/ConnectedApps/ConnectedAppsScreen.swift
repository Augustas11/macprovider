import AppKit
import SwiftUI

@MainActor
final class ConnectedAppsStore: ObservableObject {
    @Published var app: ConnectedApp = .openCode { didSet { executable = nil; invalidatePreview() } }
    @Published var modelID = "" { didSet { invalidatePreview() } }
    @Published var models: [ConnectedModel] = []
    @Published var executable: URL? { didSet { invalidatePreview() } }
    @Published var previewText: String?
    @Published var status = "Not configured. Client compatibility has not been tested."
    @Published var busy = false
    @Published var endpointTested: String?
    private var pending: [(ConnectedConfigPreview, String, Bool)] = []
    private var operation: Task<Void, Never>?
    private let home: URL
    private let root: URL
    private let transactions: ConnectedConfigTransaction

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
        root = home.appendingPathComponent("Library/Application Support/Malibu/ConnectedApps", isDirectory: true)
        transactions = ConnectedConfigTransaction(receiptDirectory: root.appendingPathComponent("backups"))
    }

    var selectedModel: ConnectedModel? { models.first { $0.id == modelID } }
    var canSetup: Bool { !pending.isEmpty && !busy }

    private func invalidatePreview() {
        pending = []
        previewText = nil
        endpointTested = nil
        status = "Client compatibility has not been tested. Use Preview to inspect setup status."
    }

    func saveKey(_ key: String) {
        perform {
            try ConnectedBuyerKeychain.save(key)
            self.models = []
            self.modelID = ""
            self.status = "Buyer key saved in Keychain. Load available gateway models to continue."
        }
    }

    func forgetKey() {
        perform {
            try ConnectedBuyerKeychain.delete()
            ConnectedApp.allCases.forEach { ConnectedBuyerKeychain.removeLaunchHandoff(self.keyHandoffURL($0)) }
            self.models = []
            self.modelID = ""
            self.status = "Buyer key removed. Connected launchers cannot authenticate until a key is saved."
        }
    }

    func loadModels() {
        run {
            let key = try ConnectedBuyerKeychain.read()
            let models = try await ConnectedGatewayClient().models(key: key)
            self.models = models
            self.modelID = models.first?.id ?? ""
            self.status = models.isEmpty ? "No gateway models are currently available." : "Gateway model list loaded. No inference or client compatibility has been tested."
        }
    }

    func testEndpoint() {
        guard let model = selectedModel, app != .cursor else { return }
        let selectedApp = app
        run {
            let key = try ConnectedBuyerKeychain.read()
            try await ConnectedGatewayClient().test(api: selectedApp.api, model: model.id, key: key)
            self.endpointTested = "Endpoint tested: \(selectedApp.api.rawValue) · \(model.id). Client streaming, tools and conversation compatibility are not tested."
            self.status = "A bounded buyer-funded inference completed."
        }
    }

    func cancel() { operation?.cancel() }

    func preview() {
        perform {
            guard let model = self.selectedModel, let executable = self.executable, self.app != .cursor else {
                throw ConnectedAppsError.invalidConfiguration
            }
            let app = self.app
            let target = self.configurationURL(app)
            var entries: [(ConnectedConfigPreview, String, Bool)] = []
            var managedCatalog: URL?
            if app == .codex {
                let bytes = try ConnectedAppConfiguration.codexCatalog(model: model)
                let destination = self.root.appendingPathComponent("codex/models.json")
                entries.append((try self.transactions.preview(target: destination, proposed: bytes), "codex-catalog", false))
                managedCatalog = destination
            }
            // Profiles are intentionally isolated. An existing unowned file is refused,
            // not treated as a vendor config that can be rewritten without parsing.
            let existing = try ConnectedConfigTransaction.read(target)
            let previous = try self.transactions.receipt(named: app.slug + "-config")
            if existing.bytes != nil && previous == nil { throw ConnectedAppsError.conflict }
            let config = try ConnectedAppConfiguration.configuration(app: app, model: model, original: nil, catalog: managedCatalog)
            entries.append((try self.transactions.preview(target: target, proposed: config), app.slug + "-config", false))
            let launcher = try ConnectedAppConfiguration.launcher(app: app, executable: executable, config: target, model: model,
                                                                  keyHandoff: self.keyHandoffURL(app))
            entries.append((try self.transactions.preview(target: self.launcherURL(app), proposed: launcher), app.slug + "-launch", true))
            self.pending = entries
            self.previewText = "App: \(app.rawValue)\nModel: \(model.id)\nAPI: \(app.api.rawValue)\nConfiguration: \(target.path)\nLauncher: \(self.launcherURL(app).path)\nCredential: Keychain, handed to each Launch through a private one-time file. \(ConnectedAppConfiguration.keyExposure)\(app == .crush ? "\n" + ConnectedAppConfiguration.crushProjectConfigWarning : "")\nBackups: private app storage; exact original bytes retained.\n\n" + String(decoding: config, as: UTF8.self)
            self.status = previous == nil ? "Preview ready. Set up explicitly to write these files." : "Existing setup found. Identical setup is safe to repeat; restore before changing the model or executable."
        }
    }

    func setup() {
        perform {
            guard !self.pending.isEmpty else { throw ConnectedAppsError.invalidConfiguration }
            _ = try ConnectedBuyerKeychain.read()
            var applied: [String] = []
            do {
                for (preview, name, executable) in self.pending {
                    let existed = try self.transactions.receipt(named: name) != nil
                    try self.transactions.apply(preview, named: name, executable: executable)
                    if !existed { applied.append(name) }
                }
            } catch {
                // Keep failed/conflicting receipts available for guarded Restore.
                for name in applied.reversed() { try? self.transactions.restore(named: name) }
                throw error
            }
            self.pending = []
            self.previewText = nil
            self.status = "Configured. Use Launch for Keychain authentication. The client itself has not been tested."
        }
    }

    func restore() {
        perform {
            let slug = self.app.slug
            for name in [slug + "-launch", slug + "-config", slug + "-catalog"] {
                try self.transactions.restore(named: name)
            }
            self.invalidatePreview()
            self.status = "Managed setup restored where unchanged. Buyer key remains in Keychain; Forget buyer key removes it."
        }
    }

    func launch() {
        perform {
            guard let launcher = try self.transactions.receipt(named: self.app.slug + "-launch"),
                  let config = try self.transactions.receipt(named: self.app.slug + "-config"),
                  try ConnectedConfigTransaction.read(URL(fileURLWithPath: launcher.path)).bytes == launcher.installed,
                  try ConnectedConfigTransaction.read(URL(fileURLWithPath: config.path)).bytes == config.installed else {
                throw ConnectedAppsError.conflict
            }
            if let catalog = try self.transactions.receipt(named: self.app.slug + "-catalog") {
                guard try ConnectedConfigTransaction.read(URL(fileURLWithPath: catalog.path)).bytes == catalog.installed else { throw ConnectedAppsError.conflict }
            }
            try ConnectedBuyerKeychain.writeLaunchHandoff(try ConnectedBuyerKeychain.read(), to: self.keyHandoffURL(self.app))
            NSWorkspace.shared.open([URL(fileURLWithPath: launcher.path)],
                                    withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                    configuration: NSWorkspace.OpenConfiguration())
            self.status = "Launch requested. Confirm the selected provider/model in the client. Launching does not verify compatibility."
        }
    }

    func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Select the installed \(app.rawValue) CLI executable. Malibu will launch it only when you choose Launch."
        if panel.runModal() == .OK, let url = panel.url {
            let resolved = url.resolvingSymlinksInPath()
            guard FileManager.default.isExecutableFile(atPath: resolved.path) else {
                status = "Select an executable CLI file."
                return
            }
            executable = resolved
        }
    }

    private func configurationURL(_ app: ConnectedApp) -> URL {
        switch app {
        case .codex: root.appendingPathComponent("codex/config.toml")
        case .openCode: root.appendingPathComponent("opencode/opencode.json")
        case .goose: home.appendingPathComponent(".config/goose/custom_providers/malibu.json")
        case .crush: root.appendingPathComponent("crush/config/crush/crushrc")
        case .cursor: root.appendingPathComponent("unused")
        }
    }
    private func launcherURL(_ app: ConnectedApp) -> URL { root.appendingPathComponent(app.slug + "/Launch.command") }
    private func keyHandoffURL(_ app: ConnectedApp) -> URL { root.appendingPathComponent("handoff/" + app.slug + ".key") }

    private func perform(_ action: () throws -> Void) {
        do { try action() }
        catch { status = (error as? ConnectedAppsError)?.localizedDescription ?? ConnectedAppsError.invalidConfiguration.localizedDescription }
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        operation = Task {
            defer { self.busy = false; self.operation = nil }
            do { try await action() }
            catch { self.status = (error as? ConnectedAppsError)?.localizedDescription ?? ConnectedAppsError.network.localizedDescription }
        }
    }
}

struct ConnectedAppsScreen: View {
    @StateObject private var store = ConnectedAppsStore()
    @State private var buyerKey = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Connected apps").font(.title2.weight(.semibold))
                Text(ConnectedAppConfiguration.privacy).foregroundStyle(.orange)
                Text("Gateway: \(ConnectedAppConfiguration.gateway.absoluteString)").font(.caption)
                ShellPanel("Buyer credential") {
                    SecureField("Buyer API key", text: $buyerKey)
                    HStack {
                        Button("Save in Keychain") { store.saveKey(buyerKey); buyerKey = "" }.disabled(buyerKey.isEmpty || store.busy)
                        Button("Forget buyer key") { store.forgetKey() }.disabled(store.busy)
                        Link("Get a buyer key", destination: URL(string: "https://www.malibu.tech/console/")!)
                    }
                    Text("This is your buyer key, separate from provider earnings credentials. Malibu keeps it in Keychain and hands it to each Launch through a private one-time file.").font(.caption)
                    Text(ConnectedAppConfiguration.keyExposure).font(.caption).foregroundStyle(.orange)
                }
                ShellPanel("App and model") {
                    Picker("App", selection: $store.app) { ForEach(ConnectedApp.allCases) { Text($0.rawValue).tag($0) } }.disabled(store.busy)
                    Button("Load gateway models") { store.loadModels() }.disabled(store.busy)
                    Picker("Gateway model", selection: $store.modelID) {
                        Text("Choose a gateway model").tag("")
                        ForEach(store.models) { Text($0.id).tag($0.id) }
                    }.disabled(store.busy)
                    Link("Official \(store.app.rawValue) setup documentation", destination: store.app.documentation)
                    if store.app == .cursor {
                        Text(ConnectedAppConfiguration.cursorDisclosure)
                        Text("Open Cursor Settings → Models → API Keys. Verify that your installed version supports this gateway and the selected model, then enter your buyer key in Cursor. Malibu does not edit Cursor's internal settings. Remove the key and custom settings in Cursor to undo setup.")
                        Text("Model: \(store.modelID.isEmpty ? "Choose above" : store.modelID)")
                        Text("Manual setup pending. Cursor API compatibility is unverified.").foregroundStyle(.secondary)
                    } else {
                        Text("API: \(store.app.api.rawValue) · Client compatibility not tested").font(.caption)
                        Text("Setup creates a managed CLI profile and a Terminal launcher. Always launch here to deliver the buyer key. Project settings or managed policy can override the profile; verify the provider and model inside your client. Desktop app integration is not claimed.").font(.caption)
                        HStack {
                            Button("Select installed CLI…") { store.chooseExecutable() }
                            Text(store.executable?.lastPathComponent ?? "No CLI selected").font(.caption)
                        }.disabled(store.busy)
                        if store.app == .crush {
                            Text(ConnectedAppConfiguration.crushProjectConfigWarning).font(.caption).foregroundStyle(.orange)
                        }
                        if store.app == .codex {
                            Text("Codex CLI 0.163.0: Malibu generates a text-only catalog from the gateway model and published context size. Other CLI versions require format validation before setup. Responses, tools and streaming still require client acceptance testing.").font(.caption)
                        }
                        HStack {
                            Button("Preview setup") { store.preview() }.disabled(store.selectedModel == nil || store.executable == nil || store.busy)
                            Button("Set up") { store.setup() }.disabled(!store.canSetup)
                            Button("Launch") { store.launch() }.disabled(store.busy)
                            Button("Restore setup") { store.restore() }.disabled(store.busy)
                        }
                        Button("Test endpoint (uses buyer credit)") { store.testEndpoint() }.disabled(store.selectedModel == nil || store.busy)
                    }
                }
                if let preview = store.previewText {
                    ShellPanel("Setup preview — no key included") { Text(preview).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                }
                if let tested = store.endpointTested { Text(tested).font(.caption) }
                Text(store.status).font(.callout).accessibilityIdentifier("connected-apps-status")
                if store.busy { HStack { ProgressView().controlSize(.small); Button("Cancel request") { store.cancel() } } }
                Text("Not private · No client has been marked verified by this setup screen.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .onDisappear { store.cancel() }
    }
}
