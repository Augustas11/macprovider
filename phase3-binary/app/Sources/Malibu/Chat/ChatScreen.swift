import AppKit
import SwiftUI

@MainActor
struct ChatScreen: View {
    @ObservedObject var agent: MalibuAgent
    /// Owned by the main window so the open chat survives switching tabs.
    @ObservedObject var store: ChatStore
    @State private var draft = ""
    @State private var showingHistory = false
    @State private var showingSettings = false
    @State private var pendingDelete: ChatSummary?
    /// The turn whose prompt is in the composer, waiting to be sent again.
    @State private var editingTurn: UUID?
    @FocusState private var composerFocused: Bool

    private var providerIdentity: ChatProviderIdentity { ChatProviderIdentity(agent.snapshot) }
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            conversation
            Divider()
            composer
        }
        .accessibilityIdentifier("malibu.chat.screen")
        .task(id: providerIdentity) {
            store.providerChanged(to: providerIdentity)
            while !Task.isCancelled {
                await store.refresh(port: ProviderConfig.readHTTPPort())
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
        .onDisappear { store.close() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Chat").font(.title2.weight(.semibold))
                    Label(store.capability?.model ?? "No local model available", systemImage: "desktopcomputer")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("malibu.chat.model")
                }
                Spacer()
                Button("Settings", systemImage: "slider.horizontal.3") { showingSettings.toggle() }
                    .popover(isPresented: $showingSettings, arrowEdge: .bottom) {
                        ChatSettingsForm(settings: $store.settings, save: store.saveSettings)
                    }
                    .accessibilityIdentifier("malibu.chat.settings")
                Button("History", systemImage: "clock.arrow.circlepath") { showingHistory.toggle() }
                    .popover(isPresented: $showingHistory, arrowEdge: .bottom) { historyList }
                    .accessibilityIdentifier("malibu.chat.history")
                Button("New chat", systemImage: "square.and.pencil") {
                    editingTurn = nil; draft = ""; store.newConversation()
                }
                    .accessibilityIdentifier("malibu.chat.new")
            }
            HStack(spacing: 14) {
                Toggle("Agent mode", isOn: $store.agentMode)
                    .toggleStyle(.switch)
                    .disabled(store.isRunning || store.capability?.guaranteedTools != true)
                    .accessibilityIdentifier("malibu.chat.agent-mode")
                if store.agentMode {
                    Button(store.folderName.map { "Folder: \($0)" } ?? "Choose folder…", systemImage: "folder") { chooseFolder() }
                        .disabled(store.isRunning)
                        .lineLimit(1)
                        .accessibilityIdentifier("malibu.chat.choose-folder")
                }
                Spacer()
            }
            if let used = store.contextUsedTokens, let limit = store.contextLimitTokens, limit > 0 {
                ProgressView(value: Double(min(used, limit)), total: Double(limit))
                    .accessibilityLabel("Context \(min(used, limit)) of \(limit) tokens")
                    .accessibilityIdentifier("malibu.chat.context-meter")
            }
            if let contextNote = store.contextNote {
                Text(contextNote).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("malibu.chat.context-note")
            }
            if store.capability != nil && store.capability?.guaranteedTools != true {
                Text("Agent mode needs a model with guaranteed tool selection.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if store.turns.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: store.agentMode ? "folder.badge.questionmark" : "bubble.left.and.bubble.right")
                            .font(.system(size: 36)).foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(store.agentMode ? "Explore a folder, safely" : "A conversation on your Mac")
                            .font(.title3.weight(.semibold))
                        Text(store.agentMode
                             ? "Choose a folder, then ask for a summary or help finding something."
                             : "Ask a question using the model already loaded by your provider.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Text("Chats are saved on this Mac only. Local usage is separate from earnings.")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: 480).padding(40)
                    .frame(maxWidth: .infinity)
                } else {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(store.turns) { turn in
                            VStack(alignment: .leading, spacing: 12) {
                                message(label: "You", text: turn.prompt, user: true)
                                if turn.complete && !store.isRunning {
                                    HStack(spacing: 12) {
                                        Button("Edit", systemImage: "pencil") {
                                            editingTurn = turn.id
                                            draft = turn.prompt
                                            composerFocused = true
                                        }
                                        .accessibilityIdentifier("malibu.chat.edit")
                                        Button("Regenerate", systemImage: "arrow.clockwise") {
                                            editingTurn = nil
                                            store.regenerate(turn.id)
                                        }
                                        .disabled(store.capability == nil || store.isChecking)
                                        .accessibilityIdentifier("malibu.chat.regenerate")
                                        if turn.versions.count > 1 {
                                            Button { store.selectVersion(turn.id, index: turn.activeVersion - 1) } label: {
                                                Image(systemName: "chevron.left")
                                            }
                                            .disabled(turn.activeVersion <= 0)
                                            .accessibilityLabel("Previous answer")
                                            .accessibilityIdentifier("malibu.chat.branch.previous")
                                            Text("\(turn.activeVersion + 1) / \(turn.versions.count)")
                                                .font(.caption.monospaced())
                                                .accessibilityIdentifier("malibu.chat.branch")
                                            Button { store.selectVersion(turn.id, index: turn.activeVersion + 1) } label: {
                                                Image(systemName: "chevron.right")
                                            }
                                            .disabled(turn.activeVersion + 1 >= turn.versions.count)
                                            .accessibilityLabel("Next answer")
                                            .accessibilityIdentifier("malibu.chat.branch.next")
                                        }
                                    }
                                    .buttonStyle(.borderless)
                                    .font(.caption)
                                }
                                if !turn.reasoning.isEmpty {
                                    DisclosureGroup("Thinking") {
                                        ChatAnswerView(text: turn.reasoning, showsCopy: false)
                                    }
                                    .accessibilityIdentifier("malibu.chat.thinking")
                                }
                                if !turn.answer.isEmpty { message(label: "Malibu", text: turn.answer, user: false) }
                                if let stats = ChatStats.line(completionTokens: turn.completionTokens, tokensPerSecond: turn.tokensPerSecond) {
                                    Text(stats).font(.caption.monospaced()).foregroundStyle(.secondary)
                                        .accessibilityIdentifier("malibu.chat.stats")
                                }
                                ForEach(Array(turn.tools.enumerated()), id: \.offset) { _, line in
                                    Label(line, systemImage: "wrench.and.screwdriver")
                                        .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                                }
                                if let note = turn.note, note != store.notice {
                                    Label(note, systemImage: "exclamationmark.circle")
                                        .font(.caption).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                if turn.truncated && turn.id == store.turns.last?.id && !store.isRunning {
                                    Button("Continue", systemImage: "arrow.down.forward") { store.continueAnswer() }
                                        .disabled(store.capability == nil || store.isChecking)
                                        .accessibilityIdentifier("malibu.chat.continue")
                                }
                            }.id(turn.id)
                        }
                        Color.clear.frame(height: 1).id("chat-bottom")
                    }.padding(24)
                }
            }
            .onChange(of: store.turns.last?.answer) { _, _ in proxy.scrollTo("chat-bottom", anchor: .bottom) }
            .onChange(of: store.turns.last?.tools.count) { _, _ in proxy.scrollTo("chat-bottom", anchor: .bottom) }
            .onChange(of: store.turns.count) { _, _ in proxy.scrollTo("chat-bottom", anchor: .bottom) }
        }
    }

    private func message(label: String, text: String, user: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if user {
                Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // Answers render as markdown. Links stay text and are not opened.
                ChatAnswerView(text: text)
            }
        }
        .padding(14)
        .background(user ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let notice = store.notice {
                Label(notice, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("malibu.chat.notice")
            }
            if let activity = store.activity {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(activity).font(.caption) }
                    .accessibilityIdentifier("malibu.chat.activity")
            }
            HStack(alignment: .bottom, spacing: 12) {
                TextField("Message the model on this Mac…", text: $draft, axis: .vertical)
                    .lineLimit(2...6).textFieldStyle(.plain).padding(12)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                    .focused($composerFocused)
                    // Typing stays possible while a reply streams (Return waits on canSend), so focus is
                    // never dropped; the composer takes focus as soon as the chat opens.
                    .onAppear { composerFocused = true }
                    // Return sends, as in every chat app; Shift-Return keeps a newline.
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) { return .ignored }
                        if canSend { send() }
                        return .handled
                    }
                    .accessibilityLabel("Message")
                    .accessibilityIdentifier("malibu.chat.composer")
                if store.isRunning {
                    Button("Stop", systemImage: "stop.fill") { store.stop() }
                        .keyboardShortcut(".", modifiers: .command)
                        .accessibilityIdentifier("malibu.chat.stop")
                } else {
                    if editingTurn != nil {
                        Button("Cancel") { editingTurn = nil; draft = "" }
                            .accessibilityIdentifier("malibu.chat.edit.cancel")
                    }
                    Button("Send", systemImage: "arrow.up") { send() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!canSend)
                        .accessibilityIdentifier("malibu.chat.send")
                }
            }
            if draft.utf8.count > ChatStore.maxPromptBytes {
                Text("Message is too long. Keep it under 8 KB.").font(.caption2).foregroundStyle(.secondary)
            } else if store.agentMode && store.folderName == nil {
                Text("Choose a folder first: Agent mode reads only the folder you pick.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(20)
    }
    private var historyList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Saved on this Mac").font(.headline).padding(12)
            Divider()
            if store.history.isEmpty {
                Text("No saved chats yet.").foregroundStyle(.secondary)
                    .frame(width: 320).padding(.vertical, 24)
            } else {
                List(store.history) { chat in
                    HStack(spacing: 8) {
                        Button {
                            store.openConversation(chat.id); showingHistory = false
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(chat.title)
                                    .fontWeight(chat.id == store.conversationID ? .semibold : .regular)
                                    .lineLimit(1)
                                Text(chat.updatedAt, format: .relative(presentation: .named))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button(role: .destructive) { pendingDelete = chat } label: { Label("Delete", systemImage: "trash") }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                            .help("Delete this chat")
                            .accessibilityIdentifier("malibu.chat.history.delete")
                    }
                }
                .frame(width: 320, height: 360)
            }
        }
        .accessibilityIdentifier("malibu.chat.history.list")
        .confirmationDialog(
            "Delete this chat?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let chat = pendingDelete { store.deleteConversation(chat.id) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("It is removed from this Mac and cannot be restored.")
        }
    }
    private var canSend: Bool {
        !store.isRunning
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.utf8.count <= ChatStore.maxPromptBytes
            && store.capability != nil && !store.isChecking
    }
    private func send() {
        if let editingTurn {
            store.editAndResend(editingTurn, prompt: draft)
            self.editingTurn = nil
        } else {
            store.send(draft)
        }
        if store.isRunning { draft = "" }
        composerFocused = true
    }
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.prompt = "Allow read-only access"
        panel.message = "Agent mode can read, list and search inside this folder during this session."
        if panel.runModal() == .OK, let url = panel.url { store.selectFolder(url) }
    }
}

/// Serving/idle/paused transitions do not change local model identity. In
/// particular, beginning inference must never cancel its own conversation.
struct ChatProviderIdentity: Equatable {
    let model: String?
    let loaded: Bool
    let service: String?
    let disconnected: Bool
    init(_ snapshot: AgentSnapshot) {
        model = snapshot.currentModelID
        loaded = snapshot.currentModelLoaded == true
        service = snapshot.serviceInstanceID
        disconnected = snapshot.state == .reconnecting || snapshot.state == .error
    }
}
