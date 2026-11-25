import Combine
import Darwin
import Foundation

enum AgentModelTarget: String, Codable, CaseIterable, Identifiable {
    case thisMac, network
    var id: String { rawValue }
    var title: String { self == .thisMac ? "This Mac" : "Malibu network" }
}

struct AgentSampling: Equatable {
    var temperature: Double = 0.7
    var topP: Double = 0.9
    /// 0 omits `top_k` so the provider keeps its own default.
    var topK: Int = 0
    var seed: Int?
    var stop: [String] = []
    var maxTokens: Int = 1024
    var isValid: Bool {
        temperature.isFinite && (0...2).contains(temperature)
            && topP.isFinite && (0.01...1).contains(topP)
            && (0...100).contains(topK)
            && (seed.map { (0...Int(Int32.max)).contains($0) } ?? true)
            && stop.count <= 4
            && stop.allSatisfy { !$0.isEmpty && $0.utf8.count <= 64 && !$0.contains("\0") }
            && (1...8192).contains(maxTokens)
    }

    /// Fields both Chat and Agents send. `maxOutput` is the context cap.
    func requestFields(maxOutput: Int) -> [String: Any] {
        var fields: [String: Any] = [
            "temperature": min(2, max(0, temperature)),
            "top_p": min(1, max(0.01, topP)),
            "max_tokens": min(max(1, maxOutput), max(1, maxTokens)),
        ]
        if (1...100).contains(topK) { fields["top_k"] = topK }
        if let seed, (0...Int(Int32.max)).contains(seed) { fields["seed"] = seed }
        let stops = stop.filter { !$0.isEmpty }.prefix(4)
        if !stops.isEmpty { fields["stop"] = Array(stops) }
        return fields
    }

    static func stops(from text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.prefix(4).map { String($0.prefix(64)) }
    }
}

extension AgentSampling: Codable {
    enum CodingKeys: String, CodingKey {
        case temperature, topP, topK, seed, stop, maxTokens
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? 0.7
        topP = try container.decodeIfPresent(Double.self, forKey: .topP) ?? 0.9
        topK = try container.decodeIfPresent(Int.self, forKey: .topK) ?? 0
        seed = try container.decodeIfPresent(Int.self, forKey: .seed)
        stop = try container.decodeIfPresent([String].self, forKey: .stop) ?? []
        maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens) ?? 1024
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(temperature, forKey: .temperature)
        try container.encode(topP, forKey: .topP)
        try container.encode(topK, forKey: .topK)
        try container.encodeIfPresent(seed, forKey: .seed)
        try container.encode(stop, forKey: .stop)
        try container.encode(maxTokens, forKey: .maxTokens)
    }
}

struct AgentDefinition: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = "New agent"
    var instructions = "You are a helpful assistant."
    var target: AgentModelTarget = .thisMac
    var model = ""
    var workspacePath: String?
    var workspaceTools = false
    var servers: [MCPServerConfiguration] = []
    var sampling = AgentSampling()

    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf8.count <= 200, instructions.utf8.count <= 16_384,
              model.utf8.count <= 512, sampling.isValid, servers.count <= 8,
              Set(servers.map(\.id)).count == servers.count,
              workspacePath.map({ $0.utf8.count <= 4096 && !$0.contains("\0") }) ?? true
        else { throw AgentStoreFailure.invalid }
    }
}

enum AgentStoreFailure: Error, LocalizedError {
    case unsafeFile, invalid, limit
    var errorDescription: String? {
        switch self {
        case .unsafeFile: return "Agents could not be read or saved in Application Support."
        case .invalid: return "Check the agent name, instructions and sampling settings."
        case .limit: return "The agent collection reached its storage limit."
        }
    }
}

@MainActor
final class AgentStore: ObservableObject {
    @Published private(set) var agents: [AgentDefinition] = []
    @Published private(set) var notice: String?
    let directory: URL
    private var file: URL { directory.appendingPathComponent("agents.json") }
    private static let byteLimit = 1_048_576

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Malibu/Agents", isDirectory: true)
        do { try prepareDirectory(); try load() }
        catch { notice = "Agents could not be loaded. Check Application Support permissions." }
    }

    func save(_ agent: AgentDefinition) throws {
        try agent.validate()
        var next = agents
        if let index = next.firstIndex(where: { $0.id == agent.id }) { next[index] = agent }
        else { next.append(agent) }
        guard next.count <= 100 else { throw AgentStoreFailure.limit }
        try persist(next)
        agents = next; notice = nil
    }

    func remove(_ agent: AgentDefinition) throws {
        let next = agents.filter { $0.id != agent.id }
        try persist(next); agents = next; notice = nil
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), chmod(directory.path, 0o700) == 0
        else { throw AgentStoreFailure.unsafeFile }
    }

    private func load() throws {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return }
            throw AgentStoreFailure.unsafeFile
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1,
              info.st_size <= Self.byteLimit, fchmod(fd, 0o600) == 0
        else { throw AgentStoreFailure.unsafeFile }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.read(upToCount: Self.byteLimit + 1) ?? Data()
        guard data.count <= Self.byteLimit else { throw AgentStoreFailure.limit }
        try MalibuStrictJSON.rejectDuplicateKeys(data)
        let loaded = try JSONDecoder().decode([AgentDefinition].self, from: data)
        guard loaded.count <= 100, Set(loaded.map(\.id)).count == loaded.count else { throw AgentStoreFailure.invalid }
        try loaded.forEach { try $0.validate() }
        agents = loaded
    }

    private func persist(_ next: [AgentDefinition]) throws {
        try prepareDirectory()
        let data = try JSONEncoder().encode(next)
        guard data.count <= Self.byteLimit else { throw AgentStoreFailure.limit }
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).json")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AgentStoreFailure.unsafeFile }
        defer { close(fd); unlink(temporary.path) }
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == data.count, fchmod(fd, 0o600) == 0, fsync(fd) == 0,
              rename(temporary.path, file.path) == 0 else { throw AgentStoreFailure.unsafeFile }
    }
}
