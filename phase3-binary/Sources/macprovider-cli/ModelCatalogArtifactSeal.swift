import CryptoKit
import Darwin
import Foundation

/// Evidence of a past full verification, never a substitute for fresh readiness
/// or adoption verification. Metadata observations have a finite time window.
struct ModelCatalogArtifactSeal: Codable, Sendable {
    let schema: String
    let selector: ModelCatalogTransactionSelector
    let modelKey: String
    let signerKeyID: String
    let revision: String
    let sha256: String
    let candidateDigest: String
    let artifactDigest: String
    let snapshot: ModelCatalogArtifactSnapshot

    init(record: ModelCatalogTransactionRecord, snapshot: ModelCatalogArtifactSnapshot) throws {
        guard let selector = record.selector else { throw ModelCatalogTransactionError.invalidTransaction }
        schema = "model_catalog_artifact_seal.v1"
        self.selector = selector; modelKey = record.modelKey; signerKeyID = record.signerKeyID
        revision = record.revision; sha256 = record.sha256
        candidateDigest = record.candidateDigest; artifactDigest = record.artifactDigest; self.snapshot = snapshot
    }
    func validate(record: ModelCatalogTransactionRecord) throws {
        guard schema == "model_catalog_artifact_seal.v1", record.selector == selector,
              record.modelKey == modelKey, record.signerKeyID == signerKeyID,
              record.revision == revision, record.sha256 == sha256,
              record.candidateDigest == candidateDigest, record.artifactDigest == artifactDigest else {
            throw ModelCatalogTransactionError.invalidTransaction
        }
    }
}

struct ModelCatalogArtifactSnapshot: Codable, Equatable, Sendable {
    struct Identity: Codable, Equatable, Sendable {
        let device: Int32
        let inode: UInt64
        let mode: UInt16
        let uid: UInt32
        init(_ value: stat) { device = value.st_dev; inode = value.st_ino; mode = value.st_mode; uid = value.st_uid }
    }
    struct Entry: Codable, Equatable, Sendable {
        let path: String
        let identity: Identity
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanos: Int64
        let changedSeconds: Int64
        let changedNanos: Int64
        init(path: String, info: stat) {
            self.path = path; identity = Identity(info); size = info.st_size
            modifiedSeconds = Int64(info.st_mtimespec.tv_sec); modifiedNanos = Int64(info.st_mtimespec.tv_nsec)
            changedSeconds = Int64(info.st_ctimespec.tv_sec); changedNanos = Int64(info.st_ctimespec.tv_nsec)
        }
    }
    let root: Identity
    let entries: [Entry]

    /// Root/parent descriptors remain open across the final short journal write.
    /// The final check proves this directory's placement, not unchanged descendants.
    final class Observation {
        let parentFD: Int32
        let rootFD: Int32
        let name: String
        let identity: Identity
        init(directory: URL) throws {
            let normalized = URL(fileURLWithPath: ModelTransactionDirectory.normalized(directory))
            parentFD = try ModelCatalogArtifactSnapshot.openDirectory(normalized.deletingLastPathComponent())
            name = normalized.lastPathComponent
            rootFD = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard rootFD >= 0 else { close(parentFD); throw ModelCatalogTransactionError.invalidTransaction }
            var value = stat()
            guard fstat(rootFD, &value) == 0, value.st_uid == getuid() else {
                close(rootFD); close(parentFD); throw ModelCatalogTransactionError.invalidTransaction
            }
            identity = Identity(value)
        }
        deinit { close(rootFD); close(parentFD) }
        func validatePlacement() throws {
            var value = stat()
            guard fstatat(parentFD, name, &value, AT_SYMLINK_NOFOLLOW) == 0,
                  Identity(value) == identity else { throw ModelCatalogTransactionError.invalidTransaction }
        }
    }

    static func verified(directory: URL, sha256: String, deadline: Date?, check: () throws -> Void) throws -> Self {
        let captured = try capture(directory: directory, hashing: true, deadline: deadline, check: check)
        guard captured.hash == sha256 else { throw ModelCatalogTransactionError.authorityUnavailable }
        // Catch changes to previously visited files while later files were hashed.
        let after = try capture(directory: directory, hashing: false, deadline: deadline, check: check)
        guard after.snapshot == captured.snapshot else { throw ModelCatalogTransactionError.invalidTransaction }
        return captured.snapshot
    }

    func observe(directory: URL, deadline: Date?, check: () throws -> Void = {}) throws -> Observation {
        guard entries.count <= 10_000 else { throw ModelCatalogTransactionError.invalidTransaction }
        let captured = try Self.capture(directory: directory, hashing: false, deadline: deadline, check: check)
        guard captured.snapshot == self else { throw ModelCatalogTransactionError.invalidTransaction }
        let observation = try Observation(directory: directory)
        guard observation.identity == root else { throw ModelCatalogTransactionError.invalidTransaction }
        return observation
    }

    private static func capture(directory: URL, hashing: Bool, deadline: Date?, check: () throws -> Void)
        throws -> (snapshot: Self, hash: String) {
        func active() throws { try check(); try HuggingFaceSnapshotDownloader.assertDeadlineActive(deadline) }
        try active()
        let fd = try openDirectory(directory)
        defer { close(fd) }
        var rootInfo = stat()
        guard fstat(fd, &rootInfo) == 0, rootInfo.st_uid == getuid() else { throw ModelCatalogTransactionError.invalidTransaction }
        var entries: [Entry] = []
        var entryBytes = 0
        var manifest: [(path: String, size: UInt64, sha: String)] = []
        func walk(_ directoryFD: Int32, prefix: String, depth: Int) throws {
            try active()
            guard depth <= 64 else { throw ModelCatalogTransactionError.invalidTransaction }
            var before = stat()
            guard fstat(directoryFD, &before) == 0 else { throw ModelCatalogTransactionError.invalidTransaction }
            let copy = openat(directoryFD, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard copy >= 0, let stream = fdopendir(copy) else {
                if copy >= 0 { close(copy) }; throw ModelCatalogTransactionError.invalidTransaction
            }
            defer { closedir(stream) }
            while true {
                try active(); errno = 0
                guard let item = readdir(stream) else {
                    guard errno == 0 else { throw ModelCatalogTransactionError.invalidTransaction }; break
                }
                let name = withUnsafeBytes(of: item.pointee.d_name) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
                if name == "." || name == ".." { continue }
                let relative = prefix.isEmpty ? name : prefix + "/" + name
                try ModelArtifactRelativePathPolicy.validate(relative)
                guard entries.count < 10_000, relative.utf8.count <= 4_096 else { throw ModelCatalogTransactionError.invalidTransaction }
                var info = stat()
                guard fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_uid == getuid(),
                      info.st_mode & 0o022 == 0 else { throw ModelCatalogTransactionError.invalidTransaction }
                let isDirectory = info.st_mode & S_IFMT == S_IFDIR
                guard isDirectory || (info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1) else {
                    throw ModelCatalogTransactionError.invalidTransaction
                }
                let child = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (isDirectory ? O_DIRECTORY : 0))
                guard child >= 0 else { throw ModelCatalogTransactionError.invalidTransaction }
                defer { close(child) }
                var opened = stat()
                guard fstat(child, &opened) == 0, Entry(path: relative, info: opened) == Entry(path: relative, info: info) else {
                    throw ModelCatalogTransactionError.invalidTransaction
                }
                let recordedEntry = Entry(path: relative, info: info)
                entryBytes += try JSONEncoder().encode(recordedEntry).count
                guard entryBytes <= 4_000_000 else { throw ModelCatalogTransactionError.invalidTransaction }
                entries.append(recordedEntry)
                if isDirectory { try walk(child, prefix: relative, depth: depth + 1) }
                else if hashing {
                    var hasher = SHA256(), total: UInt64 = 0
                    var bytes = [UInt8](repeating: 0, count: 1_048_576)
                    while true {
                        try active()
                        let count = Darwin.read(child, &bytes, bytes.count)
                        if count < 0, errno == EINTR { continue }
                        guard count >= 0 else { throw ModelCatalogTransactionError.invalidTransaction }
                        if count == 0 { break }
                        hasher.update(data: Data(bytes.prefix(count))); total += UInt64(count)
                    }
                    guard total == UInt64(info.st_size) else { throw ModelCatalogTransactionError.invalidTransaction }
                    manifest.append((relative, total, hasher.finalize().map { String(format: "%02x", $0) }.joined()))
                }
                var after = stat(), placed = stat()
                guard fstat(child, &after) == 0, fstatat(directoryFD, name, &placed, AT_SYMLINK_NOFOLLOW) == 0,
                      Entry(path: relative, info: after) == Entry(path: relative, info: info),
                      Entry(path: relative, info: placed) == Entry(path: relative, info: info) else {
                    throw ModelCatalogTransactionError.invalidTransaction
                }
            }
            var after = stat()
            guard fstat(directoryFD, &after) == 0,
                  Entry(path: prefix, info: before) == Entry(path: prefix, info: after) else { throw ModelCatalogTransactionError.invalidTransaction }
        }
        try walk(fd, prefix: "", depth: 0)
        try active()
        let snapshot = Self(root: Identity(rootInfo), entries: entries.sorted { $0.path < $1.path })
        guard try JSONEncoder().encode(snapshot).count <= 4_194_304 else { throw ModelCatalogTransactionError.invalidTransaction }
        let text = manifest.sorted { $0.path < $1.path }.map { "\($0.path)\n\($0.size)\n\($0.sha)\n" }.joined()
        let hash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        let observation = try Observation(directory: directory)
        guard observation.identity == snapshot.root else { throw ModelCatalogTransactionError.invalidTransaction }
        try observation.validatePlacement()
        return (snapshot, hash)
    }
    static func openDirectory(_ url: URL) throws -> Int32 {
        var current = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw ModelCatalogTransactionError.invalidTransaction }
        do {
            for name in ModelTransactionDirectory.normalized(url).split(separator: "/").map(String.init) {
                let next = openat(current, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw ModelCatalogTransactionError.invalidTransaction }
                var value = stat()
                guard fstat(next, &value) == 0, value.st_uid == getuid() || value.st_uid == 0,
                      value.st_mode & 0o022 == 0 || (value.st_uid == 0 && value.st_mode & S_ISVTX != 0) else {
                    close(next); throw ModelCatalogTransactionError.invalidTransaction
                }
                close(current); current = next
            }
            return current
        } catch { close(current); throw error }
    }
}
