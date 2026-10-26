import SwiftUI

@MainActor
struct TasksScreen: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var scheduler: TaskScheduler
    @ObservedObject var agents: AgentStore
    @State private var selectedID: UUID?
    @State private var editing: ScheduledTask?
    @State private var error: String?

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Tasks").font(.title2.weight(.semibold))
                    Spacer()
                    Button("New task", systemImage: "plus") {
                        if let agent = agents.agents.first { editing = ScheduledTask(agentID: agent.id) }
                        else { error = "Create an agent before adding a task." }
                    }
                }
                List(selection: $selectedID) {
                    ForEach(store.tasks) { task in
                        VStack(alignment: .leading) {
                            Text(task.name)
                            Text(task.enabled ? "Enabled" : "Disabled").font(.caption).foregroundStyle(.secondary)
                        }.tag(task.id)
                    }
                }
                Text("Tasks run while Malibu is open. A missed schedule runs once when Malibu next opens.")
                    .font(.caption).foregroundStyle(.secondary)
                if let notice = error ?? store.notice { Text(notice).foregroundStyle(.red).font(.caption) }
            }.padding(20).frame(minWidth: 220, idealWidth: 280)
            if let task = store.tasks.first(where: { $0.id == selectedID }) {
                detail(task)
            } else {
                ContentUnavailableView("Choose a task", systemImage: "checklist",
                                       description: Text("Schedule an agent or run it when you need it."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(item: $editing) { task in
            TaskEditor(task: task, agents: agents.agents, error: error) { updated in
                do { try store.save(updated, original: task); selectedID = updated.id; editing = nil; error = nil }
                catch { self.error = "The task could not be saved. Check its name and prompt." }
            }
        }
        .accessibilityIdentifier("malibu.tasks.screen")
    }

    private func detail(_ task: ScheduledTask) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(task.name).font(.title2)
                    Spacer()
                    Button("Edit") { editing = task }
                    Button("Run now") { scheduler.runNow(task) }.disabled(scheduler.runningTaskID != nil)
                    Button("Delete", role: .destructive) {
                        do { try store.remove(task.id); selectedID = nil }
                        catch { self.error = "The task could not be deleted." }
                    }.disabled(scheduler.runningTaskID == task.id)
                }
                Text(task.prompt).textSelection(.enabled)
                if scheduler.runningTaskID == task.id { ProgressView("Running…") }
                if let next = task.nextFire, task.enabled { Text("Next run: \(next.formatted())").font(.caption) }
                Divider()
                Text("Run history").font(.headline)
                ForEach(store.history(taskID: task.id)) { run in
                    DisclosureGroup {
                        Text("Started: \(run.startedAt.formatted()) · Ended: \(run.endedAt.formatted())").font(.caption)
                        if let reason = run.reason { Text(reason).foregroundStyle(.secondary) }
                        Text(run.transcript).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Text("\(run.startedAt.formatted()) · \(run.status.rawValue.capitalized)")
                    }
                }
            }.padding(24)
        }.frame(minWidth: 420)
    }
}

@MainActor
private struct TaskEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var task: ScheduledTask
    let agents: [AgentDefinition]
    let error: String?
    let save: (ScheduledTask) -> Void
    @State private var tools: [MCPTool] = []
    @State private var discoveryClients: [MCPClient] = []
    @State private var discovery: Task<Void, Never>?
    @State private var discoveryID = UUID()
    @State private var discovering = false
    @State private var toolError: String?
    private var selectedAgent: AgentDefinition? { agents.first { $0.id == task.agentID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Task").font(.title2)
            Form {
                TextField("Name", text: $task.name)
                Picker("Agent", selection: $task.agentID) {
                    ForEach(agents) { agent in Text(agent.name).tag(agent.id) }
                }.onChange(of: task.agentID) { _, _ in
                    stopDiscovery(); tools = []; task.preapprovedTools = []; toolError = nil
                }
                Text("Prompt")
                TextEditor(text: $task.prompt).frame(height: 90)
                Picker("Schedule", selection: $task.schedule.kind) {
                    Text("Once").tag(TaskSchedule.Kind.once)
                    Text("Hourly").tag(TaskSchedule.Kind.hourly)
                    Text("Daily").tag(TaskSchedule.Kind.daily)
                    Text("Weekdays").tag(TaskSchedule.Kind.weekdays)
                }
                if task.schedule.kind == .once {
                    DatePicker("Date and time", selection: $task.schedule.date)
                } else if task.schedule.kind != .hourly {
                    HStack {
                        Stepper("Hour: \(task.schedule.hour)", value: $task.schedule.hour, in: 0...23)
                        Stepper("Minute: \(task.schedule.minute)", value: $task.schedule.minute, in: 0...59)
                    }
                }
                Text("Times use this device's timezone (\(TimeZone.current.identifier)).").font(.caption)
                Toggle("Enabled", isOn: $task.enabled)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pre-approved MCP tools").font(.headline)
                    Text("Choose each tool this task may call unattended. Tools outside this list fail the run.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(discovering ? "Loading tools…" : "Load MCP tools") { discoverTools() }
                        .disabled(discovering || selectedAgent?.servers.isEmpty != false)
                    if let toolError { Text(toolError).font(.caption).foregroundStyle(.red) }
                    ForEach(tools, id: \.name) { tool in
                        Toggle(isOn: Binding(get: { task.preapprovedTools.contains(tool.name) }, set: { approved in
                            if approved { task.preapprovedTools.insert(tool.name) }
                            else { task.preapprovedTools.remove(tool.name) }
                        })) {
                            VStack(alignment: .leading) {
                                Text("\(tool.serverName) · \(tool.originalName)")
                                Text(tool.name).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                    ForEach(task.preapprovedTools.filter { name in !tools.contains(where: { $0.name == name }) }.sorted(), id: \.self) { name in
                        HStack { Text(name).font(.caption); Spacer(); Button("Remove approval") { task.preapprovedTools.remove(name) } }
                    }
                }
                Text(selectedAgent?.target == .network
                     ? "Malibu network runs are billed to your saved buyer key."
                     : "This Mac runs are local work and never earnings.")
                    .font(.caption)
                Text("Each run is limited to 6 rounds, 90 seconds and 8,192 output tokens.").font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save(task) }.keyboardShortcut(.defaultAction)
                    .disabled(task.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || task.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 590)
        .onDisappear { stopDiscovery() }
    }

    private func stopDiscovery() {
        discoveryID = UUID(); discovery?.cancel(); discovery = nil
        discoveryClients.forEach { $0.stop() }; discoveryClients = []; discovering = false
    }

    private func discoverTools() {
        stopDiscovery()
        guard let selectedAgent else { return }
        let token = discoveryID
        discovering = true; toolError = nil
        discovery = Task {
            var found: [MCPTool] = []
            do {
                for configuration in selectedAgent.servers {
                    try Task.checkCancellation()
                    let client = MCPClient(configuration: configuration)
                    discoveryClients.append(client)
                    found += try await client.start()
                    client.stop()
                }
                try Task.checkCancellation()
                guard discoveryID == token else { return }
                tools = found
            } catch {
                guard discoveryID == token else { return }
                toolError = "The MCP tools could not be loaded. Check the agent's server settings."
            }
            guard discoveryID == token else { return }
            discoveryClients.forEach { $0.stop() }; discoveryClients = []; discovering = false; discovery = nil
        }
    }
}
