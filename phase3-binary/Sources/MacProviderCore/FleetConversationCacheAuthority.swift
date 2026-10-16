import Darwin
import Foundation

/// A coordinator-authenticated, provider-local fleet cache eligibility grant.
/// The account identity never crosses this boundary; `conversationKey` is the
/// coordinator-issued opaque scope identifier used by the existing cache.
public final class FleetConversationCacheGrant: @unchecked Sendable {
    public let conversationKey: String
    public let generation: UInt64

    private let authority: FleetConversationCacheAuthority

    fileprivate init(
        conversationKey: String,
        generation: UInt64,
        authority: FleetConversationCacheAuthority
    ) {
        self.conversationKey = conversationKey
        self.generation = generation
        self.authority = authority
    }

    /// Synchronous so cache begin/commit fences can recheck immediately around
    /// suspension points. A purge raises the in-memory floor before durable I/O,
    /// invalidating every older token before any cache teardown begins.
    public var isValid: Bool {
        authority.isGrantValid(conversationKey: conversationKey, generation: generation)
    }
}

/// SPEC-037-R014 provider-side revocation authority.
///
/// Revocation floors are persisted before hot/disk purge starts. The file holds
/// only opaque conversation identifiers and generations; it never contains an
/// account id, prompt, token sequence, or caller-provided cache key.
public final class FleetConversationCacheAuthority: @unchecked Sendable {
    public enum AuthorityError: Error, Equatable {
        case invalidConversationKey
        case invalidGeneration
        case revoked
        case capacityExceeded
        case metadataUnavailable
        case persistenceFailed
    }

    private struct Record: Codable {
        let conversationKey: String
        let generation: UInt64

        enum CodingKeys: String, CodingKey {
            case conversationKey = "conversation_key"
            case generation
        }
    }

    private struct FilePayload: Codable {
        let schema: String
        let floors: [Record]
    }

    public static let schema = "macprovider.fleet-cache-revocations.v1"
    public static let maxConversationKeyBytes = 256
    /// Matches the coordinator's maximum durable fleet-cache scope count so a
    /// provider can always record every purge it is required to acknowledge.
    public static let maxRevocationScopes = 100_000
    /// Covers 100,000 maximum-length keys even when every permitted byte needs
    /// JSON's two-byte quote/backslash escaping, plus record framing.
    public static let maxMetadataBytes = 64 * 1024 * 1024

    public static func defaultStorageURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home
            .appendingPathComponent("Library/Application Support/macprovider", isDirectory: true)
            .appendingPathComponent("fleet-cache-revocations-v1.json", isDirectory: false)
    }

    private let lock = NSLock()
    private let storageURL: URL
    private let lifetimeLockFD: Int32
    private var floors: [String: UInt64]
    private var metadataAvailable: Bool

    public init(storageURL: URL = FleetConversationCacheAuthority.defaultStorageURL()) {
        self.storageURL = storageURL.standardizedFileURL
        let lockFD = Self.acquireLifetimeLock(for: self.storageURL)
        self.lifetimeLockFD = lockFD
        guard lockFD >= 0 else {
            self.floors = [:]
            self.metadataAvailable = false
            return
        }
        do {
            self.floors = try Self.load(from: self.storageURL)
            self.metadataAvailable = true
        } catch {
            // A missing file is handled by load(). Any present-but-untrusted or
            // malformed record fails closed until a successful operator repair.
            self.floors = [:]
            self.metadataAvailable = false
        }
    }

    deinit {
        if lifetimeLockFD >= 0 {
            _ = flock(lifetimeLockFD, LOCK_UN)
            close(lifetimeLockFD)
        }
    }

    public var isAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return metadataAvailable
    }

    /// Converts a wire grant into the only request object that can confer fleet
    /// cache eligibility. Call this solely for an authenticated coordinator
    /// relay envelope; chat-completions JSON must never invoke it.
    public func authorize(
        conversationKey: String,
        generation: UInt64
    ) throws -> FleetConversationCacheGrant {
        guard let normalized = Self.normalizedConversationKey(conversationKey) else {
            throw AuthorityError.invalidConversationKey
        }
        guard generation > 0 else { throw AuthorityError.invalidGeneration }

        lock.lock()
        defer { lock.unlock() }
        guard metadataAvailable else { throw AuthorityError.metadataUnavailable }
        guard generation > (floors[normalized] ?? 0) else { throw AuthorityError.revoked }
        return FleetConversationCacheGrant(
            conversationKey: normalized,
            generation: generation,
            authority: self
        )
    }

    /// Raises and durably records the revocation floor before invoking cache
    /// teardown. `purge` must report true only after both hot and disk state are
    /// fenced/revoked. Callers acknowledge `purged=true` only for a true result.
    public func revokeAndPurge(
        conversationKey: String,
        through generation: UInt64,
        purge: @escaping @Sendable (_ conversationKey: String) async -> Bool
    ) async throws -> Bool {
        guard let normalized = Self.normalizedConversationKey(conversationKey) else {
            throw AuthorityError.invalidConversationKey
        }
        guard generation > 0 else { throw AuthorityError.invalidGeneration }

        try raiseDurableFloor(conversationKey: normalized, generation: generation)
        return await purge(normalized)
    }

    public func isGrantValid(conversationKey: String, generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return metadataAvailable && generation > (floors[conversationKey] ?? 0)
    }

    public func revocationFloor(for conversationKey: String) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard metadataAvailable else { return nil }
        return floors[conversationKey]
    }

    private func raiseDurableFloor(conversationKey: String, generation: UInt64) throws {
        lock.lock()
        defer { lock.unlock() }
        guard metadataAvailable else { throw AuthorityError.metadataUnavailable }

        let current = floors[conversationKey] ?? 0
        guard generation > current else { return }
        guard floors[conversationKey] != nil || floors.count < Self.maxRevocationScopes else {
            throw AuthorityError.capacityExceeded
        }

        // Invalidate issued tokens before touching storage. If persistence
        // fails, keep the authority unavailable so no cache use can race ahead.
        floors[conversationKey] = generation
        do {
            try Self.persist(floors: floors, to: storageURL)
        } catch {
            metadataAvailable = false
            throw AuthorityError.persistenceFailed
        }
    }

    private static func normalizedConversationKey(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value == raw,
              value.hasPrefix("conv:"),
              value.utf8.count > "conv:".utf8.count,
              value.utf8.count <= maxConversationKeyBytes,
              value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f })
        else { return nil }
        return value
    }

    private static func load(from url: URL) throws -> [String: UInt64] {
        var st = stat()
        if lstat(url.path, &st) != 0 {
            if errno == ENOENT { return [:] }
            throw AuthorityError.metadataUnavailable
        }
        guard (st.st_mode & S_IFMT) == S_IFREG,
              st.st_uid == getuid(),
              st.st_nlink == 1,
              (st.st_mode & 0o077) == 0,
              st.st_size >= 0,
              st.st_size <= maxMetadataBytes
        else { throw AuthorityError.metadataUnavailable }

        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= maxMetadataBytes else { throw AuthorityError.metadataUnavailable }
        let payload = try JSONDecoder().decode(FilePayload.self, from: data)
        guard payload.schema == schema, payload.floors.count <= maxRevocationScopes else {
            throw AuthorityError.metadataUnavailable
        }

        var result: [String: UInt64] = [:]
        result.reserveCapacity(payload.floors.count)
        for record in payload.floors {
            guard let key = normalizedConversationKey(record.conversationKey),
                  key == record.conversationKey,
                  record.generation > 0,
                  result.updateValue(record.generation, forKey: key) == nil
            else { throw AuthorityError.metadataUnavailable }
        }
        return result
    }

    private static func persist(floors: [String: UInt64], to url: URL) throws {
        let records = floors.keys.sorted().map { Record(conversationKey: $0, generation: floors[$0]!) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(FilePayload(schema: schema, floors: records))
        guard data.count <= maxMetadataBytes else { throw AuthorityError.capacityExceeded }

        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)

        let temporary = parent.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = temporary.path.withCString { open($0, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600) }
        guard fd >= 0 else { throw AuthorityError.persistenceFailed }
        var closed = false
        defer {
            if !closed { close(fd) }
            _ = unlink(temporary.path)
        }
        guard fchmod(fd, 0o600) == 0 else { throw AuthorityError.persistenceFailed }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw AuthorityError.persistenceFailed
                }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw AuthorityError.persistenceFailed }
        let closeResult = close(fd)
        closed = true
        guard closeResult == 0 else { throw AuthorityError.persistenceFailed }
        guard rename(temporary.path, url.path) == 0 else { throw AuthorityError.persistenceFailed }

        let directoryFD = parent.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
        guard directoryFD >= 0 else { throw AuthorityError.persistenceFailed }
        defer { close(directoryFD) }
        guard fsync(directoryFD) == 0 else { throw AuthorityError.persistenceFailed }
    }

    /// One live provider process owns one revocation journal. Holding this lock
    /// for the authority lifetime prevents two processes (or accidental duplicate
    /// owners) from overwriting a newer floor with a stale in-memory dictionary.
    private static func acquireLifetimeLock(for storageURL: URL) -> Int32 {
        let parent = storageURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        } catch {
            return -1
        }
        let lockURL = parent.appendingPathComponent(".\(storageURL.lastPathComponent).lock")
        let fd = lockURL.path.withCString { open($0, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600) }
        guard fd >= 0 else { return -1 }
        var st = stat()
        guard fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_uid == getuid(),
              st.st_nlink == 1,
              fchmod(fd, 0o600) == 0,
              flock(fd, LOCK_EX | LOCK_NB) == 0
        else {
            close(fd)
            return -1
        }
        return fd
    }
}
