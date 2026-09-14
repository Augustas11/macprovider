import CryptoKit
import Darwin
import Foundation

/// A receipt can only be minted by the authorized store-setup boundary.
struct ModelTransactionProjectionStoreIdentity: Sendable {
    let durableDevice: UInt64
    let durableInode: UInt64
    let journalDevice: UInt64
    let journalInode: UInt64
    fileprivate init(durable: stat, journal: stat) {
        durableDevice = UInt64(durable.st_dev); durableInode = UInt64(durable.st_ino)
        journalDevice = UInt64(journal.st_dev); journalInode = UInt64(journal.st_ino)
    }
    func validateCurrent(durableRoot: URL, transactionRoot: URL) throws {
        let durable = try ModelTransactionDirectory(durableRoot)
        let journal = try ModelTransactionDirectory(transactionRoot)
        let d = try durable.info(), j = try journal.info()
        guard UInt64(d.st_dev) == durableDevice, UInt64(d.st_ino) == durableInode,
              UInt64(j.st_dev) == journalDevice, UInt64(j.st_ino) == journalInode else {
            throw ModelCatalogRetentionError.changed
        }
    }
}

enum ModelCatalogRetentionError: Error, CustomStringConvertible {
    case unsafe, changed, capacity, migration, storage, corruptIndex
    var description: String {
        switch self {
        case .unsafe: return "transaction evidence is unsafe; review the retained record before continuing"
        case .changed: return "transaction storage changed; refresh before continuing"
        case .capacity: return "active transaction capacity is full; use status, cancel or cleanup to resolve existing work"
        case .migration: return "transaction history requires review before bounded index migration can continue"
        case .storage: return "transaction evidence could not be persisted; check available storage and retry"
        case .corruptIndex: return "transaction index is invalid; retained evidence requires review before mutation"
        }
    }
}

enum ModelTransactionAtomicWriteStage: Equatable {
    case prepared
    case renamed
    case durable
}

enum ModelTransactionAtomicPublicationTruth: Equatable {
    case notPublished
    case mayOrDidPublish
}

struct ModelTransactionAtomicPublicationError: Error {
    let truth: ModelTransactionAtomicPublicationTruth
    let underlying: Error
}

/// Descriptor-relative I/O. A journal-lock scope pins the same root descriptor
/// across all synchronous calls, preventing a root replacement from redirecting
/// a later write into a different journal.
final class ModelTransactionDirectory {
    let fd: Int32
    let url: URL
    private let initial: stat
    private static let scopeKey = "macprovider.transaction.directory.scope.v1"

    init(_ url: URL, create: Bool = false) throws {
        self.url = URL(fileURLWithPath: Self.normalized(url))
        var current = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw ModelCatalogRetentionError.storage }
        do {
            let parts = self.url.path.split(separator: "/").map(String.init)
            guard !parts.isEmpty else { throw ModelCatalogRetentionError.unsafe }
            for (position, name) in parts.enumerated() {
                var next = openat(current, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0, errno == ENOENT, create {
                    guard mkdirat(current, name, 0o700) == 0 || errno == EEXIST else { throw ModelCatalogRetentionError.storage }
                    guard fsync(current) == 0 else { throw ModelCatalogRetentionError.storage }
                    next = openat(current, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw ModelCatalogRetentionError.unsafe }
                var value = stat()
                guard fstat(next, &value) == 0, value.st_uid == getuid() || value.st_uid == 0,
                      (value.st_mode & 0o022 == 0 || (value.st_uid == 0 && value.st_mode & S_ISVTX != 0)),
                      position != parts.count - 1 || (value.st_uid == getuid() && value.st_mode & 0o077 == 0) else {
                    close(next); throw ModelCatalogRetentionError.unsafe
                }
                do { try Self.rejectACL(next, allowDeny: true) } catch { close(next); throw error }
                close(current); current = next
            }
            var value = stat()
            guard fstat(current, &value) == 0, value.st_dev >= 0 else { throw ModelCatalogRetentionError.storage }
            initial = value; fd = current
        } catch { close(current); throw error }
    }
    deinit { close(fd) }
    static func normalized(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        for alias in ["/var", "/tmp", "/etc"] where path == alias || path.hasPrefix(alias + "/") {
            path = "/private" + path; break
        }
        return path
    }
    static var hasScopedDirectory: Bool { Thread.current.threadDictionary[scopeKey] != nil }
    static func current(_ root: URL) throws -> ModelTransactionDirectory {
        if let scope = Thread.current.threadDictionary[scopeKey] as? ModelTransactionDirectory {
            guard normalized(root) == scope.url.path else { throw ModelCatalogRetentionError.changed }
            try scope.validateCurrent(); return scope
        }
        return try ModelTransactionDirectory(root)
    }
    static func scoped<T>(_ root: URL, body: () throws -> T) throws -> T {
        guard Thread.current.threadDictionary[scopeKey] == nil else { throw ModelCatalogTransactionError.busy }
        let directory = try ModelTransactionDirectory(root)
        Thread.current.threadDictionary[scopeKey] = directory
        defer { Thread.current.threadDictionary.removeObject(forKey: scopeKey) }
        return try body()
    }
    func info() throws -> stat {
        var value = stat(); guard fstat(fd, &value) == 0 else { throw ModelCatalogRetentionError.storage }
        return value
    }
    func validateCurrent() throws {
        let observed = try ModelTransactionDirectory(url).info()
        guard observed.st_dev == initial.st_dev, observed.st_ino == initial.st_ino else { throw ModelCatalogRetentionError.changed }
    }
    func child(_ name: String, create: Bool = false) throws -> ModelTransactionDirectory {
        try validateName(name); try validateCurrent()
        return try ModelTransactionDirectory(url.appendingPathComponent(name), create: create)
    }
    func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw ModelCatalogRetentionError.unsafe
        }
    }
    func metadata(_ name: String) throws -> stat? {
        try validateName(name)
        var value = stat()
        guard fstatat(fd, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }; throw ModelCatalogRetentionError.unsafe
        }
        return value
    }
    func openFile(_ name: String, flags: Int32, afterOpen: () throws -> Void = {}) throws -> Int32 {
        try validateName(name)
        let descriptor = openat(fd, name, flags | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw ModelCatalogRetentionError.storage }
        do {
            try afterOpen()
            var value = stat()
            guard fstat(descriptor, &value) == 0, value.st_uid == getuid(),
                  value.st_mode & S_IFMT == S_IFREG, value.st_mode & 0o077 == 0 else { throw ModelCatalogRetentionError.unsafe }
            try Self.rejectACL(descriptor)
            if value.st_nlink != 1 {
                if value.st_nlink == 0 {
                    let current = try metadata(name)
                    if current == nil || current?.st_dev != value.st_dev || current?.st_ino != value.st_ino {
                        throw ModelCatalogRetentionError.changed
                    }
                }
                throw ModelCatalogRetentionError.unsafe
            }
            return descriptor
        } catch { close(descriptor); throw error }
    }
    private static func rejectACL(_ descriptor: Int32, allowDeny: Bool = false) throws {
        errno = 0
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            if errno == 0 || errno == ENOENT { return }
            throw ModelCatalogRetentionError.unsafe
        }
        defer { _ = acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        var next = Int32(ACL_FIRST_ENTRY.rawValue)
        for _ in 0..<1_024 {
            let status = acl_get_entry(acl, next, &entry)
            if status == 0, entry == nil { return }
            guard status == 0 || status == 1, let entry else { throw ModelCatalogRetentionError.unsafe }
            var tag = ACL_UNDEFINED_TAG
            guard allowDeny, acl_get_tag_type(entry, &tag) == 0, tag == ACL_EXTENDED_DENY else {
                throw ModelCatalogRetentionError.unsafe
            }
            next = Int32(ACL_NEXT_ENTRY.rawValue)
        }
        throw ModelCatalogRetentionError.unsafe
    }
    func read(_ name: String, maxBytes: Int = 4_194_304) throws -> Data {
        let descriptor = try openFile(name, flags: O_RDONLY)
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_size > 0, before.st_size <= maxBytes else { throw ModelCatalogRetentionError.unsafe }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw ModelCatalogRetentionError.storage }
            if count == 0 { break }
            bytes.append(contentsOf: buffer.prefix(count))
            guard bytes.count <= maxBytes else { throw ModelCatalogRetentionError.unsafe }
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, ModelTransactionFileEvidence.same(before, after),
              bytes.count == after.st_size else { throw ModelCatalogRetentionError.changed }
        return bytes
    }
    func write(_ data: Data, name: String, exclusive: Bool = false, maxBytes: Int = 4_194_304) throws {
        do {
            _ = try writeWithPublicationOutcome(data, name: name, exclusive: exclusive, maxBytes: maxBytes)
        } catch let failure as ModelTransactionAtomicPublicationError {
            throw failure.underlying
        }
    }
    /// The pointer publisher needs to preserve durable truth when a failure
    /// occurs after rename. Other journal writes continue using `write` and
    /// retain their existing error surface.
    @discardableResult
    func writeWithPublicationOutcome(_ data: Data, name: String, exclusive: Bool = false,
                                     maxBytes: Int = 4_194_304,
                                     boundary: (ModelTransactionAtomicWriteStage) throws -> Void = { _ in }) throws
        -> ModelTransactionAtomicWriteStage {
        var stage = ModelTransactionAtomicWriteStage.prepared
        do {
            return try writeTrackingPublication(data, name: name, exclusive: exclusive,
                                                maxBytes: maxBytes, stage: &stage, boundary: boundary)
        } catch {
            throw ModelTransactionAtomicPublicationError(
                truth: stage == .prepared ? .notPublished : .mayOrDidPublish,
                underlying: error)
        }
    }
    private func writeTrackingPublication(_ data: Data, name: String, exclusive: Bool,
                                          maxBytes: Int, stage: inout ModelTransactionAtomicWriteStage,
                                          boundary: (ModelTransactionAtomicWriteStage) throws -> Void) throws
        -> ModelTransactionAtomicWriteStage {
        try validateName(name); try validateCurrent()
        guard !data.isEmpty, data.count <= maxBytes else { throw ModelCatalogRetentionError.unsafe }
        let previous = try metadata(name)
        if previous != nil {
            guard !exclusive else { throw ModelCatalogRetentionError.changed }
            let checked = try openFile(name, flags: O_RDONLY); close(checked)
        }
        let temporary = ".tmp-" + UUID().uuidString.lowercased()
        let output = try openFile(temporary, flags: O_WRONLY | O_CREAT | O_EXCL)
        var temporaryIdentity = stat()
        guard fstat(output, &temporaryIdentity) == 0 else { close(output); throw ModelCatalogRetentionError.storage }
        defer {
            if let current = try? metadata(temporary), current.st_dev == temporaryIdentity.st_dev,
               current.st_ino == temporaryIdentity.st_ino { unlinkat(fd, temporary, 0) }
            close(output)
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(output, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw ModelCatalogRetentionError.storage }
                offset += count
            }
        }
        guard fsync(output) == 0 else { throw ModelCatalogRetentionError.storage }
        try validateCurrent()
        let current = try metadata(name)
        guard previous?.st_dev == current?.st_dev, previous?.st_ino == current?.st_ino else { throw ModelCatalogRetentionError.changed }
        guard renameat(fd, temporary, fd, name) == 0 else { throw ModelCatalogRetentionError.storage }
        stage = .renamed
        try boundary(.renamed)
        guard fsync(fd) == 0 else { throw ModelCatalogRetentionError.storage }
        stage = .durable
        try boundary(.durable)
        return stage
    }
    func entries(limit: Int, check: () throws -> Void = {}) throws -> [String] {
        let duplicate = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard duplicate >= 0, let stream = fdopendir(duplicate) else {
            if duplicate >= 0 { close(duplicate) }; throw ModelCatalogRetentionError.storage
        }
        defer { closedir(stream) }
        var result: [String] = []
        errno = 0
        while true {
            try check()
            guard let entry = readdir(stream) else { break }
            try check()
            let name = withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
            if name != ".", name != ".." { result.append(name) }
            guard result.count <= limit else { throw ModelCatalogRetentionError.migration }
            errno = 0
        }
        guard errno == 0 else { throw ModelCatalogRetentionError.storage }
        try check()
        return result
    }
}

extension ModelCatalogTransactionStore {
    static func prepareProjectionStore(_ context: PreparedModelTransactionContext) throws -> (store: Self, identity: ModelTransactionProjectionStoreIdentity) {
        try context.validateProjectionAncestors()
        let durable = try ModelTransactionDirectory(context.durableRoot, create: true)
        try context.validateProjectionAncestors()
        let journal = try ModelTransactionDirectory(context.transactionRoot, create: true)
        try durable.validateCurrent(); try journal.validateCurrent()
        try context.validateProjectionAncestors()
        let identity = ModelTransactionProjectionStoreIdentity(durable: try durable.info(), journal: try journal.info())
        return (Self(root: context.transactionRoot, projectionIdentity: identity), identity)
    }
}
