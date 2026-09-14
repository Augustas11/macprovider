import CryptoKit
import Darwin
import Foundation

/// Private replay material only. The signed envelope is never admission
/// authority; the coordinator still checks the exact current pending tuple.
enum BYOMPendingOfferJournal {
    static let maxBytes = 64 * 1024
    static let maxRecords = 128

    struct Record: Codable, Sendable {
        let schema: String
        let generation: String
        let envelope: BYOMOfferSubmitRequestWire
    }

    enum JournalError: Error, CustomStringConvertible {
        case unavailable, busy, full, invalid, corruptJSON, changed, unresolved
        var description: String {
            switch self {
            case .busy: return "another model offer operation is in progress; retry after it completes"
            case .full: return "pending model offer journal is full; reconcile existing offers before submitting another"
            case .changed: return "pending offer journal changed during the operation; read current admission status before continuing"
            case .unresolved: return "an earlier different offer is unresolved; explicitly withdraw or reconcile its terminal coordinator state before replacing it"
            case .invalid: return "pending offer journal is unsafe or has mismatched identity; review the original signed envelope before continuing"
            case .corruptJSON: return "pending offer journal JSON is unrecoverable; retry and new offers remain blocked pending review/recovery of the original signed envelope"
            case .unavailable: return "cannot persist the private pending offer journal; check the discovery namespace directory and available storage"
            }
        }
    }

    /// A lock is held across the caller's async status/send/reconciliation.
    /// Locks are striped by digest prefix to bound lock-file count, and never
    /// unlinked (which could split two processes onto different lock inodes).
    final class Operation: @unchecked Sendable {
        private let directory: Int32
        private let lock: Int32
        private let filename: String
        private let providerID: String
        private let candidateID: String

        init(namespaceURL: URL, providerID: String, candidateID: String) throws {
            self.providerID = providerID
            self.candidateID = candidateID
            guard BYOMWithdrawalBuilder.isStableCandidateID(candidateID) else { throw JournalError.invalid }
            let digest = SHA256.hash(data: Data((providerID + "\0" + candidateID).utf8))
                .map { String(format: "%02x", $0) }.joined()
            filename = digest + ".json"
            let fd = try Self.openDirectory(namespaceURL.deletingLastPathComponent())
            do {
                let lockFD = try Self.openPrivateFile(fd, name: "lock-" + String(digest.prefix(2)), flags: O_RDWR | O_CREAT)
                guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
                    close(lockFD)
                    throw JournalError.busy
                }
                directory = fd
                lock = lockFD
            } catch {
                close(fd)
                throw error
            }
        }

        deinit {
            flock(lock, LOCK_UN)
            close(lock)
            close(directory)
        }

        func load() throws -> Record? {
            var info = stat()
            guard fstatat(directory, filename, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { return nil }
                throw JournalError.unavailable
            }
            let fd = try Self.openPrivateFile(directory, name: filename, flags: O_RDONLY)
            defer { close(fd) }
            guard fstat(fd, &info) == 0, info.st_size >= 0, info.st_size <= Self.maxRecordBytes else {
                throw JournalError.invalid
            }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(fd, &buffer, buffer.count)
                guard count >= 0 else { throw JournalError.unavailable }
                if count == 0 { break }
                data.append(contentsOf: buffer.prefix(count))
                guard data.count <= Self.maxRecordBytes else { throw JournalError.invalid }
            }
            let record: Record
            do {
                record = try JSONDecoder().decode(Record.self, from: data)
            } catch is DecodingError {
                // This distinct error is reachable only after safe, bounded
                // private-file reading. Explicit withdrawal may preserve these
                // unrecoverable bytes; security/filesystem errors never qualify.
                throw JournalError.corruptJSON
            }
            guard record.schema == "byom_pending_offer.v1", UUID(uuidString: record.generation) != nil,
                  record.envelope.providerID == providerID, record.envelope.candidateID == candidateID,
                  record.envelope.schema == "model_admission_offer_submit.v1",
                  record.envelope.signatureDomain == "macprovider.model_admission.offer.v1",
                  record.envelope.signatureAlgorithm == "ed25519",
                  BYOMDiscoveryPrivacy.isSafeModelReference(record.envelope.servedModelRef) else {
                throw JournalError.invalid
            }
            // Reject unknown fields rather than silently discarding unvalidated
            // material in a record that will later be re-signed.
            let decodedObject = try JSONSerialization.jsonObject(with: data) as? NSDictionary
            let canonicalObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? NSDictionary
            guard decodedObject == canonicalObject else { throw JournalError.invalid }
            return record
        }

        @discardableResult
        func persist(_ envelope: BYOMOfferSubmitRequestWire, replacing generation: String?) throws -> Record {
            guard try load()?.generation == generation else { throw JournalError.changed }
            guard envelope.providerID == providerID, envelope.candidateID == candidateID else { throw JournalError.invalid }
            let record = Record(schema: "byom_pending_offer.v1", generation: UUID().uuidString, envelope: envelope)
            let data = try JSONEncoder().encode(record)
            guard data.count <= Self.maxRecordBytes else { throw JournalError.invalid }
            let indexFD = try Self.openPrivateFile(directory, name: "index.lock", flags: O_RDWR | O_CREAT)
            defer { close(indexFD) }
            guard flock(indexFD, LOCK_EX | LOCK_NB) == 0 else { throw JournalError.busy }
            defer { flock(indexFD, LOCK_UN) }
            if generation == nil, try recordCount() >= BYOMPendingOfferJournal.maxRecords { throw JournalError.full }
            let temporary = ".pending-" + UUID().uuidString
            let output = try Self.openPrivateFile(directory, name: temporary, flags: O_WRONLY | O_CREAT | O_EXCL)
            defer { close(output); unlinkat(directory, temporary, 0) }
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(output, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    guard count > 0 else { throw JournalError.unavailable }
                    offset += count
                }
            }
            guard fsync(output) == 0,
                  renameat(directory, temporary, directory, filename) == 0,
                  fsync(directory) == 0 else { throw JournalError.unavailable }
            return record
        }

        func reconcile(generation: String, terminal: Bool) throws {
            guard try load()?.generation == generation else { throw JournalError.changed }
            if terminal {
                guard unlinkat(directory, filename, 0) == 0, fsync(directory) == 0 else { throw JournalError.unavailable }
            }
        }

        private static let maxRecordBytes = BYOMPendingOfferJournal.maxBytes

        private func recordCount() throws -> Int {
            let fd = openat(directory, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard fd >= 0, let entries = fdopendir(fd) else {
                if fd >= 0 { close(fd) }
                throw JournalError.unavailable
            }
            defer { closedir(entries) }
            var count = 0
            var inspected = 0
            errno = 0
            while let entry = readdir(entries) {
                inspected += 1
                guard inspected <= 512 else { throw JournalError.full }
                let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                    String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
                }
                if name.hasSuffix(".json") { count += 1 }
                errno = 0
            }
            guard errno == 0 else { throw JournalError.unavailable }
            return count
        }

        private static func openPrivateFile(_ directory: Int32, name: String, flags: Int32) throws -> Int32 {
            let fd = openat(directory, name, flags | O_NOFOLLOW | O_NONBLOCK, 0o600)
            guard fd >= 0 else { throw JournalError.unavailable }
            var info = stat()
            guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_uid == getuid(), (info.st_mode & 0o777) == 0o600, info.st_nlink == 1 else {
                close(fd)
                throw JournalError.invalid
            }
            return fd
        }

        private static func openDirectory(_ parent: URL) throws -> Int32 {
            var path = parent.standardizedFileURL.path
            // Only the immutable macOS aliases are resolved; operator-controlled
            // links in any other component are rejected with openat/O_NOFOLLOW.
            if path == "/var" || path.hasPrefix("/var/") { path = "/private" + path }
            if path == "/tmp" || path.hasPrefix("/tmp/") { path = "/private" + path }
            let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath()
            var ancestor = cwd
            var excludedRoot = cwd.path
            while ancestor.path != "/" {
                if FileManager.default.fileExists(atPath: ancestor.appendingPathComponent(".git").path) {
                    excludedRoot = ancestor.path
                    break
                }
                ancestor.deleteLastPathComponent()
            }
            guard path != excludedRoot, !path.hasPrefix(excludedRoot + "/") else { throw JournalError.invalid }
            var targetAncestor = URL(fileURLWithPath: path)
            while targetAncestor.path != "/" {
                guard !FileManager.default.fileExists(atPath: targetAncestor.appendingPathComponent(".git").path) else {
                    throw JournalError.invalid
                }
                targetAncestor.deleteLastPathComponent()
            }
            var current = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard current >= 0 else { throw JournalError.unavailable }
            var success = false
            defer { if !success { close(current) } }
            for component in path.split(separator: "/") {
                let next = openat(current, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard next >= 0 else { throw JournalError.invalid }
                close(current)
                current = next
            }
            var parentInfo = stat()
            guard fstat(current, &parentInfo) == 0, parentInfo.st_uid == getuid(),
                  (parentInfo.st_mode & 0o077) == 0 else { throw JournalError.invalid }
            if mkdirat(current, "pending-offers", 0o700) != 0 {
                guard errno == EEXIST else { throw JournalError.unavailable }
            } else if fsync(current) != 0 {
                throw JournalError.unavailable
            }
            let leaf = openat(current, "pending-offers", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard leaf >= 0 else { throw JournalError.invalid }
            var info = stat()
            guard fstat(leaf, &info) == 0, info.st_uid == getuid(), (info.st_mode & 0o777) == 0o700 else {
                close(leaf)
                throw JournalError.invalid
            }
            close(current)
            current = leaf
            success = true
            return current
        }
    }

    static func protectedTupleDigest(_ envelope: BYOMOfferSubmitRequestWire) throws -> String {
        guard case .object(var fields) = envelope.canonicalValue() else { throw JournalError.invalid }
        for field in ["timestamp", "nonce", "idempotency_key", "cli_version"] { fields.removeValue(forKey: field) }
        return try RFC8785JCS.sha256Hex(of: .object(fields))
    }

    static let terminalStates: Set<String> = ["withdrawn", "revoked", "offer_rejected"]
}
