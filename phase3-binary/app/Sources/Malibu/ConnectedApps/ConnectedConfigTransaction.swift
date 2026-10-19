import Darwin
import Foundation

/// A snapshot never leaves private app storage. Config bodies can contain unrelated secrets.
struct ConnectedConfigSnapshot: Codable, Equatable {
    let bytes: Data?
    let mode: UInt16?
}

struct ConnectedConfigPreview {
    let target: URL
    let before: ConnectedConfigSnapshot
    let proposed: Data
}

struct ConnectedConfigReceipt: Codable {
    let path: String
    let original: ConnectedConfigSnapshot
    let installed: Data
}

/// Descriptor-relative I/O prevents ancestor and leaf symlink substitution.
/// NSFileCoordinator serializes cooperating editors; snapshots also reject external edits.
final class ConnectedConfigTransaction {
    static let maximumBytes = 1_048_576
    let receiptDirectory: URL

    init(receiptDirectory: URL) { self.receiptDirectory = receiptDirectory }

    func preview(target: URL, proposed: Data) throws -> ConnectedConfigPreview {
        guard proposed.count <= Self.maximumBytes else { throw ConnectedAppsError.unsafeFile }
        return ConnectedConfigPreview(target: target, before: try Self.read(target), proposed: proposed)
    }

    func receipt(named name: String) throws -> ConnectedConfigReceipt? {
        try Self.privateDirectory(receiptDirectory, create: false)
        let saved = try Self.read(receiptURL(name))
        guard saved.mode == nil || saved.mode == 0o600 else { throw ConnectedAppsError.unsafeFile }
        guard let data = saved.bytes else { return nil }
        guard let receipt = try? JSONDecoder().decode(ConnectedConfigReceipt.self, from: data) else {
            throw ConnectedAppsError.invalidConfiguration
        }
        return receipt
    }

    func apply(_ preview: ConnectedConfigPreview, named name: String, executable: Bool = false) throws {
        try Self.privateDirectory(receiptDirectory, create: true)
        let recordURL = receiptURL(name)
        if let prior = try receipt(named: name) {
            guard prior.path == preview.target.path,
                  try Self.read(preview.target).bytes == prior.installed,
                  preview.proposed == prior.installed else { throw ConnectedAppsError.conflict }
            return
        }
        // The durable backup is written BEFORE the target, including exact absent-file state.
        let record = ConnectedConfigReceipt(path: preview.target.path, original: preview.before, installed: preview.proposed)
        let encoded = try JSONEncoder().encode(record)
        try Self.replace(recordURL, expected: ConnectedConfigSnapshot(bytes: nil, mode: nil), bytes: encoded, mode: 0o600)
        do {
            try Self.replace(preview.target, expected: preview.before, bytes: preview.proposed, mode: executable ? 0o700 : 0o600)
        } catch {
            // Keep the backup after failure: it contains original bytes needed for recovery.
            throw error
        }
    }

    func restore(named name: String) throws {
        guard let record = try receipt(named: name) else { return }
        let target = URL(fileURLWithPath: record.path)
        let current = try Self.read(target)
        // The original's own mode, minus group/other write and special bits,
        // so restore neither revives unsafe permissions nor hides a file
        // the user had made readable.
        let restoredMode = Self.restoredMode(record.original.mode)
        if current.bytes == record.original.bytes {
            // Covers a failed write or repeated restore without reviving unsafe permissions.
            if current.bytes != nil && current.mode.map(mode_t.init) != restoredMode {
                try Self.replace(target, expected: current, bytes: current.bytes, mode: restoredMode)
            }
        } else {
            guard current.bytes == record.installed else { throw ConnectedAppsError.conflict }
            try Self.replace(target, expected: current, bytes: record.original.bytes, mode: restoredMode)
        }
        let saved = try Self.read(receiptURL(name))
        try Self.replace(receiptURL(name), expected: saved, bytes: nil, mode: 0o600)
    }

    static func restoredMode(_ original: UInt16?) -> mode_t {
        mode_t(original ?? 0o600) & 0o755
    }

    private func receiptURL(_ name: String) -> URL {
        // Callers use enum slugs, never arbitrary paths.
        receiptDirectory.appendingPathComponent(name.filter { $0.isLetter || $0.isNumber || $0 == "-" } + ".json")
    }

    static func read(_ url: URL) throws -> ConnectedConfigSnapshot {
        guard url.isFileURL, url.path.hasPrefix("/"), url.lastPathComponent != ".", url.lastPathComponent != ".." else {
            throw ConnectedAppsError.unsafeFile
        }
        guard let parent = try directory(url.deletingLastPathComponent(), create: false) else {
            return ConnectedConfigSnapshot(bytes: nil, mode: nil)
        }
        defer { close(parent) }
        return try read(parent: parent, name: url.lastPathComponent)
    }

    private static func read(parent: Int32, name: String) throws -> ConnectedConfigSnapshot {
        let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return ConnectedConfigSnapshot(bytes: nil, mode: nil) }
            throw ConnectedAppsError.unsafeFile
        }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == getuid(), status.st_nlink == 1,
              status.st_mode & 0o022 == 0, status.st_size >= 0,
              status.st_size <= maximumBytes else { throw ConnectedAppsError.unsafeFile }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count >= 0 else { throw ConnectedAppsError.unsafeFile }
            if count == 0 { break }
            guard bytes.count + count <= maximumBytes else { throw ConnectedAppsError.unsafeFile }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              after.st_size == status.st_size,
              after.st_mtimespec.tv_sec == status.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == status.st_mtimespec.tv_nsec else { throw ConnectedAppsError.conflict }
        return ConnectedConfigSnapshot(bytes: bytes, mode: UInt16(status.st_mode & 0o777))
    }

    static func replace(_ url: URL, expected: ConnectedConfigSnapshot, bytes: Data?, mode: mode_t) throws {
        var coordinationError: NSError?
        var operationError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordinationError) { coordinated in
            do { try replaceCoordinated(coordinated, expected: expected, bytes: bytes, mode: mode) }
            catch { operationError = error }
        }
        if let operationError { throw operationError }
        if coordinationError != nil { throw ConnectedAppsError.unsafeFile }
    }

    private static func replaceCoordinated(_ url: URL, expected: ConnectedConfigSnapshot, bytes: Data?, mode: mode_t) throws {
        guard bytes == nil || bytes!.count <= maximumBytes,
              let parent = try directory(url.deletingLastPathComponent(), create: true) else { throw ConnectedAppsError.unsafeFile }
        defer { close(parent) }
        guard try read(parent: parent, name: url.lastPathComponent) == expected else { throw ConnectedAppsError.conflict }
        if let bytes {
            let temporary = ".malibu-" + UUID().uuidString
            let descriptor = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
            guard descriptor >= 0 else { throw ConnectedAppsError.unsafeFile }
            var removeTemporary = true
            defer { close(descriptor); if removeTemporary { unlinkat(parent, temporary, 0) } }
            try bytes.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let count = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    guard count > 0 else { throw ConnectedAppsError.unsafeFile }
                    offset += count
                }
            }
            guard fchmod(descriptor, mode) == 0, fsync(descriptor) == 0 else { throw ConnectedAppsError.unsafeFile }
            guard try read(parent: parent, name: url.lastPathComponent) == expected else { throw ConnectedAppsError.conflict }
            if expected.bytes == nil {
                // An editor creating a file after the snapshot must never be overwritten.
                guard renameatx_np(parent, temporary, parent, url.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else {
                    throw ConnectedAppsError.conflict
                }
            } else {
                // Verify the atomically displaced inode, not just the name before rename.
                guard renameatx_np(parent, temporary, parent, url.lastPathComponent, UInt32(RENAME_SWAP)) == 0 else {
                    throw ConnectedAppsError.conflict
                }
                do {
                    guard try read(parent: parent, name: temporary) == expected else { throw ConnectedAppsError.conflict }
                } catch {
                    // Preserve both versions on conflict, including any concurrent changes
                    // to the newly installed inode. No recovery version is silently deleted.
                    removeTemporary = false
                    _ = renameatx_np(parent, temporary, parent, url.lastPathComponent, UInt32(RENAME_SWAP))
                    try protectRetainedRecovery(parent: parent, name: temporary)
                    throw ConnectedAppsError.conflict
                }
            }
        } else if expected.bytes != nil {
            let displaced = ".malibu-recovery-" + UUID().uuidString
            guard renameatx_np(parent, url.lastPathComponent, parent, displaced, UInt32(RENAME_EXCL)) == 0 else {
                throw ConnectedAppsError.conflict
            }
            do {
                guard try read(parent: parent, name: displaced) == expected else { throw ConnectedAppsError.conflict }
                guard unlinkat(parent, displaced, 0) == 0 else { throw ConnectedAppsError.unsafeFile }
            } catch {
                // EXCL preserves a new concurrent file; the displaced version stays available.
                if renameatx_np(parent, displaced, parent, url.lastPathComponent, UInt32(RENAME_EXCL)) != 0 {
                    try protectRetainedRecovery(parent: parent, name: displaced)
                }
                throw ConnectedAppsError.conflict
            }
        }
        guard fsync(parent) == 0 else { throw ConnectedAppsError.unsafeFile }
    }

    /// A failed rollback can leave the displaced config in its original directory.
    /// Protect only the retained inode, without following a substituted symlink or
    /// changing permissions on the original target after a successful rollback.
    static func protectRetainedRecovery(parent: Int32, name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw ConnectedAppsError.unsafeFile
        }
        let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw ConnectedAppsError.unsafeFile }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == getuid(), status.st_nlink == 1 else {
            throw ConnectedAppsError.unsafeFile
        }
        guard fchmod(descriptor, 0o600) == 0, fsync(descriptor) == 0 else {
            throw ConnectedAppsError.unsafeFile
        }
    }

    private static func privateDirectory(_ url: URL, create: Bool) throws {
        guard let descriptor = try directory(url, create: create) else { return }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_uid == getuid(),
              status.st_mode & 0o777 == 0o700 else { throw ConnectedAppsError.unsafeFile }
    }

    /// Existing ancestors must be owned by this user or root and not writable by others.
    /// All newly-created components are private. Never resolves a symlink.
    private static func directory(_ url: URL, create: Bool) throws -> Int32? {
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw ConnectedAppsError.unsafeFile }
        do {
            for component in url.pathComponents.dropFirst() {
                guard component != ".", component != "..", !component.contains("/") else { throw ConnectedAppsError.unsafeFile }
                var next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0 && errno == ENOENT && create {
                    guard mkdirat(descriptor, component, 0o700) == 0 || errno == EEXIST else { throw ConnectedAppsError.unsafeFile }
                    next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                if next < 0 && errno == ENOENT && !create { close(descriptor); return nil }
                guard next >= 0 else { throw ConnectedAppsError.unsafeFile }
                var status = stat()
                guard fstat(next, &status) == 0,
                      status.st_uid == getuid() || status.st_uid == 0,
                      status.st_mode & 0o022 == 0 || (status.st_uid == 0 && status.st_mode & S_ISVTX != 0) else {
                    close(next); throw ConnectedAppsError.unsafeFile
                }
                close(descriptor)
                descriptor = next
            }
            return descriptor
        } catch { close(descriptor); throw error }
    }
}
