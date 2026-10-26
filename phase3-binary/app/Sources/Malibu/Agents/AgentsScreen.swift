import AppKit
import SwiftUI

@MainActor
struct AgentsScreen: View {
    @ObservedObject var store: AgentStore
    @StateObject private var session = AgentSession()
    @State private var selection: UUID?
    @State private var editing: AgentDefinition?
    @State private var prompt = ""
    @State private var errorMessage: String?

    private var selected: AgentDefinition? { store.agents.first { $0.id == selection } }
    var body: some View {
        HSplitView {
            VStack(alignment: .leading) {
                HStack {
                    Text("Agents").font(.title2.weight(.semibold))
                    Spacer()
                    Button("New agent", systemImage: "plus") { editing = AgentDefinition() }
                }.padding()
                List(selection: $selection) {
                    ForEach(store.agents) { agent in
                        VStack(alignment: .leading) {
                            Text(agent.name)
                            Text(agent.target.title).font(.caption).foregroundStyle(.secondary)
                        }.tag(agent.id)
                    }
                }
                if let notice = errorMessage ?? store.notice {
                    Text(notice).font(.caption).foregroundStyle(.red).padding()
                }
            }.frame(minWidth: 190, idealWidth: 230, maxWidth: 300)
            if let selected {
                conversation(selected)
            } else {
                ContentUnavailableView("Choose an agent", systemImage: "person.crop.rectangle.stack",
                                       description: Text("Create an agent with instructions, a model and the tools it can use."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(item: $editing) { agent in
            AgentEditor(agent: agent) { value in
                do { try store.save(value); selection = value.id; editing = nil }
                catch { errorMessage = error.localizedDescription }
            }
        }
        .onChange(of: selection) { _, _ in session.reset(); prompt = "" }
        .onDisappear { session.reset() }
        .accessibilityIdentifier("malibu.agents.screen")
    }

    private func conversation(_ agent: AgentDefinition) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading) {
                    Text(agent.name).font(.title2.weight(.semibold))
                    Text(agent.target == .thisMac ? "This Mac · customer work has priority · never earnings" : "Malibu network · uses your saved buyer key")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Edit") { session.cancel(); editing = agent }
                Button("Delete", role: .destructive) {
                    session.cancel()
                    do { try store.remove(agent) } catch { errorMessage = error.localizedDescription }
                }
            }
            Divider()
            ScrollView {
                Text(session.transcript.isEmpty ? "Send a message to start a conversation." : session.transcript)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let approval = session.pendingApproval {
                AgentToolApprovalView(server: approval.server, tool: approval.tool, arguments: approval.arguments,
                                      decide: session.resolveApproval)
            }
            if let notice = session.notice { Text(notice).foregroundStyle(.secondary) }
            HStack(alignment: .bottom) {
                TextField("Message your agent…", text: $prompt, axis: .vertical)
                    .lineLimit(2...6).textFieldStyle(.roundedBorder).disabled(session.isRunning)
                if session.isRunning {
                    Button("Stop", systemImage: "stop.fill") { session.cancel() }
                } else {
                    Button("Send") { session.send(agent: agent, prompt: prompt); prompt = "" }
                        .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || prompt.utf8.count > 8192)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
            Text("Conversations stay in memory for this screen.").font(.caption2).foregroundStyle(.secondary)
        }.padding(20).frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AgentToolApprovalView: View {
    let server: String
    let tool: String
    let arguments: String
    let decide: (MCPApprovalDecision) -> Void
    var body: some View {
        ShellPanel("Tool approval") {
            Text("\(server) · \(tool)").font(.headline)
            ScrollView { Text(arguments).font(.caption.monospaced()).textSelection(.enabled) }.frame(maxHeight: 120)
            HStack {
                Button("Allow once") { decide(.allowOnce) }
                Button("Allow for this session") { decide(.allowSession) }
                Button("Deny", role: .destructive) { decide(.deny) }
            }
        }
    }
}

@MainActor
private struct AgentEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var agent: AgentDefinition
    let save: (AgentDefinition) -> Void
    @State private var models: [ConnectedModel] = []
    @State private var localCapability: ChatCapability?
    @State private var status: String?
    @State private var loading = false
    @State private var serverName = ""
    @State private var serverCommand = ""
    @State private var serverArguments = ""
    @State private var serverEnvironment = ""

    private var canSave: Bool {
        !agent.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && agent.sampling.isValid
            && (agent.target == .thisMac ? localCapability?.guaranteedTools == true : models.contains { $0.id == agent.model })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Agent").font(.title2.weight(.semibold))
            ScrollView {
                Form {
                    TextField("Name", text: $agent.name)
                    VStack(alignment: .leading) {
                        Text("Instructions")
                        TextEditor(text: $agent.instructions).frame(minHeight: 90)
                    }
                    Picker("Model target", selection: $agent.target) {
                        ForEach(AgentModelTarget.allCases) { Text($0.title).tag($0) }
                    }
                    if agent.target == .network {
                        Picker("Model", selection: $agent.model) {
                            Text("Choose a model").tag("")
                            ForEach(models) { Text($0.id).tag($0.id) }
                        }
                        Text("Network requests use the buyer key saved in Settings → Connected apps.").font(.caption)
                    } else {
                        Text(localCapability?.model ?? "No eligible model loaded")
                        Text("This Mac needs guaranteed tool selection. Customer work has priority; local work is never earnings.").font(.caption)
                    }
                    Button(loading ? "Checking models…" : "Refresh models") { Task { await refreshModels() } }.disabled(loading)
                    if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
                    Toggle("Read-only workspace tools", isOn: $agent.workspaceTools)
                    HStack {
                        Text(agent.workspacePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "No workspace folder")
                        Button("Choose folder…") { chooseFolder() }
                        if agent.workspacePath != nil { Button("Remove") { agent.workspacePath = nil } }
                    }
                    Text("Workspace tools can read, list and search the selected folder.").font(.caption)
                    Section("Sampling defaults") {
                        TextField("Temperature", value: $agent.sampling.temperature, format: .number)
                        TextField("Top P", value: $agent.sampling.topP, format: .number)
                        Stepper("Output tokens: \(agent.sampling.maxTokens)", value: $agent.sampling.maxTokens, in: 1...2048)
                    }
                    Section("MCP servers") {
                        ForEach(agent.servers) { server in
                            HStack {
                                VStack(alignment: .leading) { Text(server.name); Text(server.command).font(.caption) }
                                Spacer()
                                Button("Remove") { agent.servers.removeAll { $0.id == server.id } }
                            }
                        }
                        TextField("Server name", text: $serverName)
                        TextField("Command (absolute path)", text: $serverCommand)
                        VStack(alignment: .leading) {
                            Text("Arguments · one per line").font(.caption)
                            TextEditor(text: $serverArguments).frame(height: 55)
                            Text("Environment · NAME=value, one per line").font(.caption)
                            TextEditor(text: $serverEnvironment).frame(height: 55)
                        }
                        Button("Add server") { addServer() }
                            .disabled(serverName.isEmpty || !serverCommand.hasPrefix("/") || agent.servers.count >= 8)
                        Text("Each MCP tool call needs approval. Tool results cannot grant permission.").font(.caption)
                    }
                }.formStyle(.grouped)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save(agent) }.buttonStyle(.borderedProminent).disabled(!canSave)
            }
        }.padding(20).frame(width: 620, height: 730)
        .task { await refreshModels() }
        .onChange(of: agent.target) { _, _ in Task { await refreshModels() } }
    }

    private func refreshModels() async {
        loading = true; status = nil
        defer { loading = false }
        do {
            if agent.target == .network {
                models = try await ConnectedGatewayClient().models(key: ConnectedBuyerKeychain.read())
                if models.isEmpty { status = ConnectedAppsStore.noModelsServed }
            } else {
                guard let port = ProviderConfig.readHTTPPort() else { throw ChatFailure.unavailable }
                localCapability = try await LocalChatTransport().capability(at: ChatEndpoint(port: port))
                if localCapability?.guaranteedTools != true { status = ChatFailure.unsupportedTools.localizedDescription }
                agent.model = localCapability?.model ?? ""
            }
        } catch { status = error.localizedDescription }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "Choose workspace"
        if panel.runModal() == .OK, let url = panel.url { agent.workspacePath = url.path }
    }

    private func addServer() {
        var environment: [String: String] = [:]
        for line in serverEnvironment.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty else { status = "Use NAME=value for each environment variable."; return }
            environment[String(parts[0])] = String(parts[1])
        }
        do { _ = try ProcessEnvironmentSanitizer.sanitized(extraEnvironment: environment) }
        catch { status = "Check the server environment values."; return }
        agent.servers.append(MCPServerConfiguration(id: UUID(), name: serverName, command: serverCommand,
                                                   arguments: serverArguments.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { !$0.isEmpty },
                                                   environment: environment))
        serverName = ""; serverCommand = ""; serverArguments = ""; serverEnvironment = ""; status = nil
    }
}
