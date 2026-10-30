import AppKit
import SwiftUI

@MainActor
struct ChatScreen: View {
    @ObservedObject var agent: MalibuAgent
    @StateObject private var store = ChatStore()
    @State private var draft = ""
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
            store.providerChanged()
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
                Button("New chat", systemImage: "square.and.pencil") { store.newConversation() }
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
            if store.capability != nil && store.capability?.guaranteedTools != true {
                Text("Agent mode needs a model with guaranteed tool selection.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if store.agentMode {
                Text("Read, list and search only in your chosen folder. No commands, changes or network tools. Limited to 6 rounds, 12 calls and 90 seconds.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Label("On this Mac only · no cloud fallback · paying customers have priority", systemImage: "lock.shield")
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("malibu.chat.privacy")
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
                        Text("Chats stay in memory and are cleared when this screen closes. Local usage is separate from earnings.")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: 480).padding(40)
                    .frame(maxWidth: .infinity)
                } else {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(store.turns) { turn in
                            VStack(alignment: .leading, spacing: 12) {
                                message(label: "You", text: turn.prompt, user: true)
                                if !turn.answer.isEmpty { message(label: "Malibu", text: turn.answer, user: false) }
                            }.id(turn.id)
                        }
                        Color.clear.frame(height: 1).id("chat-bottom")
                    }.padding(24)
                }
            }
            .onChange(of: store.turns.last?.answer) { _, _ in proxy.scrollTo("chat-bottom", anchor: .bottom) }
            .onChange(of: store.turns.count) { _, _ in proxy.scrollTo("chat-bottom", anchor: .bottom) }
        }
    }

    private func message(label: String, text: String, user: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            // Plain text avoids actionable links or remote attachments from
            // untrusted model/file content while keeping code copyable.
            Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
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
                    .disabled(store.isRunning)
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
                    Button("Send", systemImage: "arrow.up") { send() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!canSend)
                        .accessibilityIdentifier("malibu.chat.send")
                }
            }
            Text(draft.utf8.count > ChatStore.maxPromptBytes ? "Message is too long. Keep it under 8 KB." : "Return to send · Shift-Return for a new line · Ephemeral conversation")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(20)
    }
    private var canSend: Bool {
        !store.isRunning
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.utf8.count <= ChatStore.maxPromptBytes
            && store.capability != nil && !store.isChecking
            && !(store.agentMode && store.folderName == nil)
    }
    private func send() { store.send(draft); if store.isRunning { draft = "" }; composerFocused = true }
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
