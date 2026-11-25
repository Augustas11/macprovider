import Darwin
import Foundation

/// What a saved turn keeps: the visible prompt, answer, reasoning and note.
/// Agent workspace bookmarks and raw tool output are never stored.
struct SavedChatTurn: Codable, Equatable {
    var prompt: String
    var answer: String
    var complete: Bool
    var reasoning: String?
    var truncated: Bool?
    var note: String?
    var tools: [String]?
}

struct SavedChat: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var model: String
    var createdAt: Date
    var updatedAt: Date
    var turns: [SavedChatTurn]

    static let titleLimit = 60
    /// The first user message on one line, cut to about 60 characters.
    static func title(from prompt: String) -> String {
        let line = prompt.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !line.isEmpty else { return "Untitled chat" }
        guard line.count > titleLimit else { return line }
        return String(line.prefix(titleLimit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

struct ChatSummary: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var model: String
    var updatedAt: Date
}

enum ChatHistoryFailure: Error {
    case unsafeFile, invalid
}

/// One owner-only JSON file per conversation under
/// ~/Library/Application Support/Malibu/chats, plus a small index.json of
/// summaries. Launch reads only the index; a chat is decoded when opened.
/// A missing or corrupt index is rebuilt off the main actor. Unreadable or
/// corrupt chat files are skipped; they never stop the list from loading.
@MainActor
final class ChatHistoryStore {
    static let limit = 200
    nonisolated static let byteLimit = 16 * 1_048_576
    nonisolated static let indexName = "index.json"
    let directory: URL
    private(set) var summaries: [ChatSummary] = []
    /// Set while a missing or corrupt index is being rebuilt.
    private(set) var rebuild: Task<Void, Never>?
    /// Called when a rebuild changes the list outside a save or delete.
    var onChange: (@MainActor () -> Void)?
    /// Deleted or pruned while a rebuild ran; its stale scan must not restore them.
    private var removedDuringRebuild: Set<UUID> = []

    init(directory: URL? = nil) {
        let root = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Malibu/chats", isDirectory: true)
        self.directory = root
        if let index = Self.readIndex(root) {
            summaries = index
            sortAndPrune()
        } else if Self.directoryIsSafe(root) {
            rebuild = Task { [weak self] in
                let found = await Task.detached(priority: .utility) { Self.scan(root) }.value
                self?.finishRebuild(found)
            }
        }
    }

    func load(_ id: UUID) -> SavedChat? {
        guard let chat = try? Self.readJSON(fileURL(id), as: SavedChat.self), chat.id == id else {
            summaries.removeAll { $0.id == id }
            try? writeIndex()
            return nil
        }
        return chat
    }

    func save(_ chat: SavedChat) throws {
        guard !chat.turns.isEmpty else { return }
        try prepareDirectory()
        let data = try JSONEncoder().encode(chat)
        guard data.count <= Self.byteLimit else { throw ChatHistoryFailure.invalid }
        try writeAtomically(data, to: fileURL(chat.id))
        summaries.removeAll { $0.id == chat.id }
        summaries.append(ChatSummary(id: chat.id, title: chat.title, model: chat.model, updatedAt: chat.updatedAt))
        sortAndPrune()
        try writeIndex()
    }

    func delete(_ id: UUID) throws {
        summaries.removeAll { $0.id == id }
        if rebuild != nil { removedDuringRebuild.insert(id) }
        if unlink(fileURL(id).path) != 0 && errno != ENOENT { throw ChatHistoryFailure.unsafeFile }
        try writeIndex()
    }

    private func fileURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private func finishRebuild(_ found: [ChatSummary]) {
        rebuild = nil
        // Chats saved while the scan ran are newer than what it read.
        let saved = Set(summaries.map(\.id))
        summaries += found.filter { !saved.contains($0.id) && !removedDuringRebuild.contains($0.id) }
        removedDuringRebuild = []
        sortAndPrune()
        if !found.isEmpty { try? writeIndex() }
        onChange?()
    }

    private func sortAndPrune() {
        summaries.sort { $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.id.uuidString < $1.id.uuidString }
        while summaries.count > Self.limit {
            let oldest = summaries.removeLast()
            if rebuild != nil { removedDuringRebuild.insert(oldest.id) }
            unlink(fileURL(oldest.id).path)
        }
    }

    private func writeIndex() throws {
        try prepareDirectory()
        try writeAtomically(try JSONEncoder().encode(summaries), to: directory.appendingPathComponent(Self.indexName))
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard Self.directoryIsSafe(directory), chmod(directory.path, 0o700) == 0
        else { throw ChatHistoryFailure.unsafeFile }
    }

    /// Temporary file, every byte written (EINTR retried), fsync, rename.
    private func writeAtomically(_ data: Data, to target: URL) throws {
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).json")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ChatHistoryFailure.unsafeFile }
        defer { close(fd); unlink(temporary.path) }
        let complete = data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return true }
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, base + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += written
            }
            return true
        }
        guard complete, fchmod(fd, 0o600) == 0, fsync(fd) == 0,
              rename(temporary.path, target.path) == 0 else { throw ChatHistoryFailure.unsafeFile }
    }

    /// The chats folder itself must be a real directory owned by this user.
    nonisolated static func directoryIsSafe(_ directory: URL) -> Bool {
        var info = stat()
        return lstat(directory.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid()
    }

    nonisolated static func readIndex(_ directory: URL) -> [ChatSummary]? {
        guard directoryIsSafe(directory),
              let index = try? readJSON(directory.appendingPathComponent(indexName), as: [ChatSummary].self),
              Set(index.map(\.id)).count == index.count else { return nil }
        return index
    }

    /// Decodes every chat file; runs off the main actor.
    nonisolated static func scan(_ directory: URL) -> [ChatSummary] {
        guard directoryIsSafe(directory),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        var found: [ChatSummary] = []
        for name in names where name.hasSuffix(".json") && !name.hasPrefix(".") {
            guard let id = UUID(uuidString: String(name.dropLast(5))),
                  let chat = try? readJSON(directory.appendingPathComponent(name), as: SavedChat.self),
                  chat.id == id, !chat.turns.isEmpty else { continue }
            found.append(ChatSummary(id: chat.id, title: chat.title, model: chat.model, updatedAt: chat.updatedAt))
        }
        return found
    }

    nonisolated static func readJSON<T: Decodable>(_ url: URL, as type: T.Type) throws -> T {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ChatHistoryFailure.unsafeFile }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_size <= byteLimit
        else { throw ChatHistoryFailure.unsafeFile }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.read(upToCount: byteLimit + 1) ?? Data()
        guard data.count <= byteLimit else { throw ChatHistoryFailure.invalid }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
