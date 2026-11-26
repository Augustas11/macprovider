import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
    @StateObject private var dictation = ChatDictation()
    @StateObject private var speaker = ChatSpeaker()
    @State private var shareHold = ChatShareHold()
    @State private var announcedAnswer = ""

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
            await store.refreshNetworkModels()
            while !Task.isCancelled {
                await store.refresh(port: ProviderConfig.readHTTPPort())
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
        .onDisappear {
            dictation.stop()
            speaker.stop()
            store.close()
        }
        .onChange(of: store.isRunning) { was, now in
            guard was, !now, let turn = store.turns.last, turn.complete, !turn.answer.isEmpty else { return }
            let announcement = "Answer. " + String(turn.answer.prefix(400))
            guard announcement != announcedAnswer else { return }
            announcedAnswer = announcement
            AccessibilityNotification.Announcement(announcement).post()
        }
        .task(id: speaker.speakingID) {
            guard speaker.speakingID != nil else { return }
            while !Task.isCancelled && speaker.speakingID != nil {
                try? await Task.sleep(for: .milliseconds(200))
                speaker.noteIfFinished()
            }
        }
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
                    Picker("Model", selection: $store.route) {
                        Text(store.capability?.model ?? "This Mac").tag(ChatRoute.thisMac)
                        ForEach(store.networkModels) { model in
                            Text(model.id).tag(ChatRoute.network(model.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(store.isRunning)
                    .accessibilityIdentifier("malibu.chat.model-picker")
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
                    dictation.stop()
                    speaker.stop()
                    announcedAnswer = ""
                    editingTurn = nil
                    draft = ""
                    store.newConversation()
                }
                    .keyboardShortcut("n", modifiers: .command)
                    .accessibilityIdentifier("malibu.chat.new")
                Button("Export", systemImage: "square.and.arrow.down") { exportChat() }
                    .disabled(store.isRunning || store.turns.isEmpty)
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .accessibilityIdentifier("malibu.chat.export")
                Button("Share", systemImage: "square.and.arrow.up") { shareChat() }
                    .disabled(store.isRunning || store.turns.isEmpty)
                    .accessibilityIdentifier("malibu.chat.share")
            }
            HStack(spacing: 14) {
                Toggle("Agent mode", isOn: $store.agentMode)
                    .toggleStyle(.switch)
                    .disabled(store.isRunning || !store.agentToolsAvailable)
                    .accessibilityIdentifier("malibu.chat.agent-mode")
                if store.agentMode {
                    Button(store.folderName.map { "Folder: \($0)" } ?? "Choose folder…", systemImage: "folder") { chooseFolder() }
                        .disabled(store.isRunning)
                        .lineLimit(1)
                        .accessibilityIdentifier("malibu.chat.choose-folder")
                    if store.canUndo {
                        Button("Undo") { store.undoLastChange() }
                            .disabled(store.isRunning)
                            .keyboardShortcut("z", modifiers: .command)
                            .accessibilityIdentifier("malibu.chat.undo")
                    }
                }
                Button(store.knowledgeName.map { "Knowledge: \($0)" } ?? "Knowledge", systemImage: "text.book.closed") {
                    chooseKnowledge()
                }
                .disabled(store.isRunning)
                .lineLimit(1)
                .accessibilityIdentifier("malibu.chat.knowledge")
                Spacer()
            }
            Toggle("Web search — queries leave this Mac. Inference stays local.", isOn: Binding(
                get: { store.webSearch },
                set: { store.setWebSearch($0) }
            ))
            .toggleStyle(.switch)
            .disabled(store.isRunning)
            .accessibilityIdentifier("malibu.chat.web-search")
            if let used = store.contextUsedTokens, let limit = store.contextLimitTokens, limit > 0 {
                ProgressView(value: Double(min(used, limit)), total: Double(limit))
                    .accessibilityLabel("Context \(min(used, limit)) of \(limit) tokens")
                    .accessibilityIdentifier("malibu.chat.context-meter")
            }
            if let contextNote = store.contextNote {
                Text(contextNote).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("malibu.chat.context-note")
            }
            if case .thisMac = store.route, store.capability != nil, store.capability?.guaranteedTools != true {
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
                                if !turn.prompt.isEmpty { message(label: "You", text: turn.prompt, user: true) }
                                ForEach(turn.attachments) { item in
                                    Label(item.name, systemImage: item.imageDataURL == nil ? "doc" : "photo")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        .accessibilityIdentifier("malibu.chat.attachment")
                                }
                                if turn.complete && !store.isRunning {
                                    HStack(spacing: 12) {
                                        Button("Edit", systemImage: "pencil") {
                                            editingTurn = turn.id
                                            draft = turn.prompt
                                            store.stageForEdit(turn.attachments)
                                            composerFocused = true
                                        }
                                        .accessibilityIdentifier("malibu.chat.edit")
                                        Button("Regenerate", systemImage: "arrow.clockwise") {
                                            editingTurn = nil
                                            store.regenerate(turn.id)
                                        }
                                        .disabled(!store.canAddressModel)
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
                                if !turn.answer.isEmpty {
                                    message(label: "Malibu", text: turn.answer, user: false, streaming: !turn.complete)
                                }
                                readAloud(turn)
                                ForEach(Array(turn.citations.enumerated()), id: \.offset) { _, name in
                                    Text(name)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .accessibilityIdentifier("malibu.chat.citation")
                                }
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
                                        .disabled(!store.canAddressModel)
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

    private func message(label: String, text: String, user: Bool, streaming: Bool = false) -> some View {
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
        .modifier(ChatStreamingTrait(enabled: streaming))
    }

    @ViewBuilder
    private func readAloud(_ turn: ChatTurn) -> some View {
        if turn.complete && !turn.answer.isEmpty {
            if turn.id == store.turns.last?.id {
                speakControl(turn).keyboardShortcut("r", modifiers: [.command, .shift])
            } else {
                speakControl(turn)
            }
        }
    }

    private func speakControl(_ turn: ChatTurn) -> some View {
        Button(speaker.speakingID == turn.id ? "Stop reading" : "Read aloud",
               systemImage: speaker.speakingID == turn.id ? "speaker.slash" : "speaker.wave.2") {
            speaker.toggle(turn.answer, id: turn.id)
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .accessibilityIdentifier("malibu.chat.speak")
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let approval = store.pendingApproval {
                AgentToolApprovalView(server: approval.server, tool: approval.tool, arguments: approval.arguments,
                                      diff: approval.diff, allowsSession: approval.allowsSession,
                                      decide: store.resolveApproval)
                    .accessibilityIdentifier("malibu.chat.mcp-approval")
            }
            if let notice = store.notice {
                Label(notice, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("malibu.chat.notice")
            }
            if let activity = store.activity {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(activity).font(.caption) }
                    .accessibilityIdentifier("malibu.chat.activity")
            }
            if !store.pendingAttachments.isEmpty {
                HStack(spacing: 8) {
                    ForEach(store.pendingAttachments) { item in
                        HStack(spacing: 4) {
                            Label(item.name, systemImage: item.imageDataURL == nil ? "doc" : "photo")
                                .lineLimit(1)
                            Button { store.removePending(item.id) } label: { Image(systemName: "xmark") }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Remove \(item.name)")
                        }
                        .font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                        .accessibilityIdentifier("malibu.chat.attachment")
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 12) {
                Button("Focus message") { composerFocused = true }
                    .keyboardShortcut("l", modifiers: .command)
                    .accessibilityIdentifier("malibu.chat.focus")
                    .accessibilityHidden(true)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                Button(dictation.isListening ? "Stop dictation" : "Dictate",
                       systemImage: dictation.isListening ? "mic.fill" : "mic") {
                    dictation.toggle(base: draft, onText: { draft = $0 }, onFailure: { store.showNotice($0) })
                }
                    .labelStyle(.iconOnly)
                    .disabled(store.isRunning)
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .accessibilityIdentifier("malibu.chat.dictate")
                Button("Attach", systemImage: "paperclip") { attachFiles() }
                    .labelStyle(.iconOnly)
                    .disabled(store.isRunning)
                    .accessibilityIdentifier("malibu.chat.attach")
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
                    .onDrop(of: [.fileURL, .image, .pdf, .plainText], isTargeted: nil) { providers in
                        store.take(providers)
                        return true
                    }
                    .onPasteCommand(of: [.fileURL, .image, .png, .jpeg, .pdf]) { providers in
                        store.take(providers)
                    }
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
                Text("Choose a folder first.")
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
                            dictation.stop()
                            speaker.stop()
                            store.openConversation(chat.id)
                            showingHistory = false
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
            && hasDraft
            && draft.utf8.count <= ChatStore.maxPromptBytes
            && store.canAddressModel
    }
    private var hasDraft: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.pendingAttachments.isEmpty
    }
    private func send() {
        dictation.stop()
        speaker.stop()
        if let editingTurn {
            store.editAndResend(editingTurn, prompt: draft)
            self.editingTurn = nil
        } else {
            store.send(draft)
        }
        if store.isRunning { draft = "" }
        composerFocused = true
    }
    private func exportChat() {
        guard let markdown = transcriptText() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "chat.md"
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try ChatTranscript.write(markdown, to: url) }
        catch { store.showNotice(ChatTranscript.exportFailed) }
    }
    private func shareChat() {
        guard let markdown = transcriptText() else { return }
        guard let view = NSApp.keyWindow?.contentView else {
            store.showNotice(ChatTranscript.exportFailed)
            return
        }
        let picker = NSSharingServicePicker(items: [markdown])
        shareHold.picker = picker
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }
    private func transcriptText() -> String? {
        let prompt = store.turns.first(where: { !$0.prompt.isEmpty })?.prompt ?? ""
        let markdown = ChatTranscript.markdown(title: SavedChat.title(from: prompt), turns: store.turns)
        guard markdown.utf8.count <= ChatTranscript.byteLimit else {
            store.showNotice(ChatTranscript.exportFailed)
            return nil
        }
        return markdown
    }
    private func attachFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .pdf, .plainText, .utf8PlainText]
        panel.prompt = "Attach"
        if panel.runModal() == .OK { store.take(panel.urls) }
    }
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.prompt = "Choose folder"
        if panel.runModal() == .OK { store.selectFolders(panel.urls) }
    }
    private func chooseKnowledge() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose folder"
        if panel.runModal() == .OK, let url = panel.url { store.selectKnowledge(url) }
    }
}

private final class ChatShareHold: @unchecked Sendable {
    var picker: NSSharingServicePicker?
}

private struct ChatStreamingTrait: ViewModifier {
    var enabled: Bool
    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled { content.accessibilityAddTraits(.updatesFrequently) }
        else { content }
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
