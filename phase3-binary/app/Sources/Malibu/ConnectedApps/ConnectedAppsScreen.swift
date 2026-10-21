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
    /// SPEC-025-R012: the model list needs a saved key; its result or error
    /// is shown beside the load action.
    @Published private(set) var hasBuyerKey: Bool
    @Published private(set) var modelsMessage: String?
    @Published private(set) var modelsLoadFailed = false
    private let keyExists: () -> Bool
    private var pending: [(ConnectedConfigPreview, String, Bool)] = []
    private var operation: Task<Void, Never>?
    private let home: URL
    private let root: URL
    private let transactions: ConnectedConfigTransaction
    private let loadGatewayModels: (String) async throws -> [ConnectedModel]
    private let readKey: () throws -> String
    private let storeKey: (String) throws -> Void
    private let loadOpenCodePlugin: () throws -> Data

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        keyExists: @escaping () -> Bool = { ConnectedBuyerKeychain.exists() },
        loadGatewayModels: @escaping (String) async throws -> [ConnectedModel] = { try await ConnectedGatewayClient().models(key: $0) },
        readKey: @escaping () throws -> String = { try ConnectedBuyerKeychain.read() },
        saveKey: @escaping (String) throws -> Void = { try ConnectedBuyerKeychain.save($0) },
        loadOpenCodePlugin: @escaping () throws -> Data = { try ConnectedAppConfiguration.openCodePlugin() }
    ) {
        self.home = home
        self.keyExists = keyExists
        self.loadGatewayModels = loadGatewayModels
        self.readKey = readKey
        self.storeKey = saveKey
        self.loadOpenCodePlugin = loadOpenCodePlugin
        hasBuyerKey = keyExists()
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
        var saved = false
        perform {
            try self.storeKey(key)
            self.models = []
            self.modelID = ""
            self.hasBuyerKey = true
            self.status = "Buyer key saved in Keychain. Loading gateway models…"
            saved = true
        }
        // SPEC-025-R012: loading follows a saved key.
        if saved { loadModels() }
    }

    func forgetKey() {
        perform {
            try ConnectedBuyerKeychain.delete()
            ConnectedApp.allCases.forEach { ConnectedBuyerKeychain.removeLaunchHandoff(self.keyHandoffURL($0)) }
            self.models = []
            self.modelID = ""
            self.hasBuyerKey = self.keyExists()
            self.modelsMessage = nil
            self.modelsLoadFailed = false
            self.status = "Buyer key removed. Connected launchers cannot authenticate until a key is saved."
        }
    }

    static let noModelsServed = "No models are being served right now. Try again later."
    static let saveKeyFirst = "Save a buyer key first."

    func loadModels() {
        guard hasBuyerKey else {
            modelsLoadFailed = true
            modelsMessage = Self.saveKeyFirst
            return
        }
        modelsMessage = nil
        modelsLoadFailed = false
        run(onError: { message in
            self.modelsLoadFailed = true
            self.modelsMessage = message
        }) {
            let key = try self.readKey()
            let models = try await self.loadGatewayModels(key)
            self.models = models
            self.modelID = models.first?.id ?? ""
            self.modelsLoadFailed = models.isEmpty
            self.modelsMessage = models.isEmpty
                ? Self.noModelsServed
                : (models.count == 1 ? "1 model available." : "\(models.count) models available.")
            self.status = models.isEmpty ? Self.noModelsServed : "Gateway model list loaded. No inference or client compatibility has been tested."
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
            var managedPlugin: URL?
            if app == .codex {
                let bytes = try ConnectedAppConfiguration.codexCatalog(model: model)
                let destination = self.root.appendingPathComponent("codex/models.json")
                entries.append((try self.transactions.preview(target: destination, proposed: bytes), "codex-catalog", false))
                managedCatalog = destination
            }
            if app == .openCode {
                let destination = self.root.appendingPathComponent("opencode/" + ConnectedAppConfiguration.openCodePluginFilename)
                let existingPlugin = try ConnectedConfigTransaction.read(destination)
                let previousPlugin = try self.transactions.receipt(named: "opencode-plugin")
                if existingPlugin.bytes != nil && previousPlugin == nil {
                    throw ConnectedAppsError.conflict
                }
                entries.append((try self.transactions.preview(target: destination, proposed: self.loadOpenCodePlugin()), "opencode-plugin", false))
                managedPlugin = destination
            }
            // Profiles are intentionally isolated. An existing unowned file is refused,
            // not treated as a vendor config that can be rewritten without parsing.
            let existing = try ConnectedConfigTransaction.read(target)
            let previous = try self.transactions.receipt(named: app.slug + "-config")
            if existing.bytes != nil && previous == nil { throw ConnectedAppsError.conflict }
            let config = try ConnectedAppConfiguration.configuration(app: app, model: model, original: nil,
                                                                    catalog: managedCatalog, plugin: managedPlugin)
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
            _ = try self.readKey()
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
            for name in [slug + "-launch", slug + "-config", slug + "-catalog", slug + "-plugin"] {
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
            if self.app == .openCode {
                try self.validateOpenCodePlugin()
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
    // Missing or edited managed code must fail before handing the buyer key to OpenCode.
    func validateOpenCodePlugin() throws {
        let target = root.appendingPathComponent("opencode/" + ConnectedAppConfiguration.openCodePluginFilename)
        guard let plugin = try transactions.receipt(named: "opencode-plugin"), plugin.path == target.path,
              try ConnectedConfigTransaction.read(target).bytes == plugin.installed else {
            throw ConnectedAppsError.conflict
        }
    }
    private func keyHandoffURL(_ app: ConnectedApp) -> URL { root.appendingPathComponent("handoff/" + app.slug + ".key") }

    private func perform(_ action: () throws -> Void) {
        do { try action() }
        catch { status = (error as? ConnectedAppsError)?.localizedDescription ?? ConnectedAppsError.invalidConfiguration.localizedDescription }
    }
    private func run(
        onError: (@MainActor (String) -> Void)? = nil,
        _ action: @escaping @MainActor () async throws -> Void
    ) {
        guard !busy else { return }
        busy = true
        operation = Task {
            defer { self.busy = false; self.operation = nil }
            do { try await action() }
            catch {
                let message = (error as? ConnectedAppsError)?.localizedDescription ?? ConnectedAppsError.network.localizedDescription
                self.status = message
                onError?(message)
            }
        }
    }

    /// Waits for the running request, for tests.
    func waitForOperation() async { await operation?.value }
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
                    Text("This is your buyer key, separate from provider earnings credentials.").font(.caption)
                    Text(ConnectedAppConfiguration.keyExposure).font(.caption).foregroundStyle(.orange)
                    DisclosureGroup("Details") {
                        Text(ConnectedAppConfiguration.setupDetails)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption)
                }
                ShellPanel("App and model") {
                    Picker("App", selection: $store.app) { ForEach(ConnectedApp.allCases) { Text($0.rawValue).tag($0) } }.disabled(store.busy)
                    HStack(alignment: .firstTextBaseline) {
                        Button("Load gateway models") { store.loadModels() }.disabled(store.busy || !store.hasBuyerKey)
                        if !store.hasBuyerKey {
                            Text(ConnectedAppsStore.saveKeyFirst).font(.caption).foregroundStyle(.secondary)
                        } else if let message = store.modelsMessage {
                            Text(message).font(.caption).foregroundStyle(store.modelsLoadFailed ? Color.red : Color.secondary)
                                .accessibilityIdentifier("connected-apps-models-message")
                        }
                    }
                    Picker("Gateway model", selection: $store.modelID) {
                        Text("Choose a gateway model").tag("")
                        ForEach(store.models) { Text($0.id).tag($0.id) }
                    }.disabled(store.busy)
                    Link("Official \(store.app.rawValue) setup documentation", destination: store.app.documentation)
                    if store.app == .cursor {
                        Text(ConnectedAppConfiguration.cursorDisclosure)
                        Text(ConnectedAppConfiguration.cursorSetup)
                        Text("Model: \(store.modelID.isEmpty ? "Choose above" : store.modelID)")
                        Text("Manual setup pending. Cursor API compatibility is unverified.").foregroundStyle(.secondary)
                    } else {
                        Text("API: \(store.app.api.rawValue) · Client compatibility not tested").font(.caption)
                        HStack {
                            Button("Select installed CLI…") { store.chooseExecutable() }
                            Text(store.executable?.lastPathComponent ?? "No CLI selected").font(.caption)
                        }.disabled(store.busy)
                        if store.app == .crush {
                            Text(ConnectedAppConfiguration.crushProjectConfigWarning).font(.caption).foregroundStyle(.orange)
                        }
                        if store.app == .openCode {
                            Text(ConnectedAppConfiguration.openCodeToolDisclosure).font(.caption).foregroundStyle(.orange)
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
                Text("Not private · Malibu has not verified any app with this gateway.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .onDisappear { store.cancel() }
    }
}
