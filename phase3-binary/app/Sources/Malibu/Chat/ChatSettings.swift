import Darwin
import Foundation
import SwiftUI

struct ChatPreset: Identifiable, Equatable {
    let id: String
    let name: String
    let prompt: String
    static let all: [ChatPreset] = [
        ChatPreset(id: "helpful", name: "Helpful", prompt: "You are a helpful assistant."),
        ChatPreset(id: "precise", name: "Precise", prompt: "Answer precisely. Say when you are not sure."),
        ChatPreset(id: "code", name: "Code", prompt: "You are a coding assistant. Prefer working code and short explanations."),
    ]
    static func named(_ id: String?) -> ChatPreset? { all.first { $0.id == id } }
}

struct ChatSettings: Codable, Equatable {
    var systemPrompt = ""
    var presetID: String?
    var sampling = ChatSettings.defaultSampling

    static var defaultSampling: AgentSampling {
        var sampling = AgentSampling()
        sampling.maxTokens = ChatStore.maxTokens
        return sampling
    }

    var isValid: Bool {
        systemPrompt.utf8.count <= 16_384 && !systemPrompt.contains("\0") && sampling.isValid
    }

    /// The system text sent with a request. Empty means no system message.
    func systemText(toolInstructions: String?) -> String {
        let prompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let tools = toolInstructions?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if prompt.isEmpty { return tools }
        if tools.isEmpty { return prompt }
        return prompt + "\n\n" + tools
    }
}

enum ChatSettingsFailure: Error {
    case unsafeFile, invalid
}

/// Owner-only settings file. A corrupt file is ignored and the defaults stay.
@MainActor
final class ChatSettingsStore {
    let file: URL
    static let byteLimit = 64 * 1024

    init(directory: URL? = nil) {
        let folder = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Malibu", isDirectory: true)
        file = folder.appendingPathComponent("chat-settings.json")
    }

    func load() -> ChatSettings? {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_size <= Self.byteLimit
        else { return nil }
        let data = (try? FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: Self.byteLimit + 1)) ?? Data()
        guard data.count <= Self.byteLimit, let settings = try? JSONDecoder().decode(ChatSettings.self, from: data),
              settings.isValid else { return nil }
        return settings
    }

    func save(_ settings: ChatSettings) throws {
        guard settings.isValid else { throw ChatSettingsFailure.invalid }
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), chmod(directory.path, 0o700) == 0
        else { throw ChatSettingsFailure.unsafeFile }
        let data = try JSONEncoder().encode(settings)
        guard data.count <= Self.byteLimit else { throw ChatSettingsFailure.invalid }
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).json")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ChatSettingsFailure.unsafeFile }
        defer { close(fd); unlink(temporary.path) }
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == data.count, fchmod(fd, 0o600) == 0, fsync(fd) == 0,
              rename(temporary.path, file.path) == 0 else { throw ChatSettingsFailure.unsafeFile }
    }
}

struct ChatSettingsForm: View {
    @Binding var settings: ChatSettings
    let save: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Chat settings").font(.headline)
            Picker("Preset", selection: presetSelection) {
                Text("Custom").tag(String?.none)
                ForEach(ChatPreset.all) { preset in Text(preset.name).tag(Optional(preset.id)) }
            }
            Text("System prompt").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $settings.systemPrompt)
                .font(.body).frame(minHeight: 80, maxHeight: 140)
                .accessibilityIdentifier("malibu.chat.system-prompt")
            TextField("Temperature", value: $settings.sampling.temperature, format: .number)
            TextField("Top P", value: $settings.sampling.topP, format: .number)
            Stepper("Top K: \(settings.sampling.topK)", value: $settings.sampling.topK, in: 0...100)
            TextField("Seed", value: $settings.sampling.seed, format: .number)
            TextField("Stop sequences, comma separated", text: stopText)
            Stepper("Output tokens: \(settings.sampling.maxTokens)", value: $settings.sampling.maxTokens, in: 256...ChatStore.maxTokens)
            if !settings.isValid {
                Text("Check temperature, top-p, top-k, seed and stop.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 360)
        .onChange(of: settings) { _, _ in save() }
    }

    private var presetSelection: Binding<String?> {
        Binding(get: { settings.presetID }, set: { id in
            settings.presetID = id
            if let preset = ChatPreset.named(id) { settings.systemPrompt = preset.prompt }
        })
    }

    private var stopText: Binding<String> {
        Binding(get: { settings.sampling.stop.joined(separator: ", ") },
                set: { settings.sampling.stop = AgentSampling.stops(from: $0) })
    }
}
