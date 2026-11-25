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

struct ChatSummary: Identifiable, Equatable {
    let id: UUID
    var title: String
    var model: String
    var updatedAt: Date
}

enum ChatHistoryFailure: Error {
    case unsafeFile, invalid
}

/// One owner-only JSON file per conversation under
/// ~/Library/Application Support/Malibu/chats. Unreadable or corrupt files
/// are skipped; they never stop the list from loading.
@MainActor
final class ChatHistoryStore {
    static let limit = 200
    static let byteLimit = 16 * 1_048_576
    let directory: URL
    private(set) var summaries: [ChatSummary] = []

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Malibu/chats", isDirectory: true)
        summaries = loadSummaries()
    }

    func load(_ id: UUID) -> SavedChat? {
        guard let chat = try? decodeFile(fileURL(id)), chat.id == id else {
            summaries.removeAll { $0.id == id }
            return nil
        }
        return chat
    }

    func save(_ chat: SavedChat) throws {
        guard !chat.turns.isEmpty else { return }
        try prepareDirectory()
        let data = try JSONEncoder().encode(chat)
        guard data.count <= Self.byteLimit else { throw ChatHistoryFailure.invalid }
        let target = fileURL(chat.id)
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).json")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ChatHistoryFailure.unsafeFile }
        defer { close(fd); unlink(temporary.path) }
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == data.count, fchmod(fd, 0o600) == 0, fsync(fd) == 0,
              rename(temporary.path, target.path) == 0 else { throw ChatHistoryFailure.unsafeFile }
        summaries.removeAll { $0.id == chat.id }
        summaries.append(ChatSummary(id: chat.id, title: chat.title, model: chat.model, updatedAt: chat.updatedAt))
        sortAndPrune()
    }

    func delete(_ id: UUID) throws {
        summaries.removeAll { $0.id == id }
        if unlink(fileURL(id).path) != 0 && errno != ENOENT { throw ChatHistoryFailure.unsafeFile }
    }

    private func fileURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private func sortAndPrune() {
        summaries.sort { $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.id.uuidString < $1.id.uuidString }
        while summaries.count > Self.limit {
            let oldest = summaries.removeLast()
            unlink(fileURL(oldest.id).path)
        }
    }

    private func loadSummaries() -> [ChatSummary] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        var loaded: [ChatSummary] = []
        for name in names where name.hasSuffix(".json") && !name.hasPrefix(".") {
            guard let id = UUID(uuidString: String(name.dropLast(5))),
                  let chat = try? decodeFile(fileURL(id)), chat.id == id, !chat.turns.isEmpty else { continue }
            loaded.append(ChatSummary(id: chat.id, title: chat.title, model: chat.model, updatedAt: chat.updatedAt))
        }
        summaries = loaded
        sortAndPrune()
        return summaries
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), chmod(directory.path, 0o700) == 0
        else { throw ChatHistoryFailure.unsafeFile }
    }

    private func decodeFile(_ url: URL) throws -> SavedChat {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ChatHistoryFailure.unsafeFile }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_size <= Self.byteLimit
        else { throw ChatHistoryFailure.unsafeFile }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.read(upToCount: Self.byteLimit + 1) ?? Data()
        guard data.count <= Self.byteLimit else { throw ChatHistoryFailure.invalid }
        return try JSONDecoder().decode(SavedChat.self, from: data)
    }
}
