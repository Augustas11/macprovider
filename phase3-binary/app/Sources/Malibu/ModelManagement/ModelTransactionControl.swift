import CryptoKit
import Darwin
import Foundation
import Security

func malibuCanonicalUUID(_ value: String) -> Bool { UUID(uuidString: value)?.uuidString.lowercased() == value }
func malibuSHA256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func malibuDigest(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) } }

struct MalibuTransactionContextExpectation: Codable, Equatable, Sendable {
    var schema = "model_transaction_context_expectation.v1"
    let transactionContextSHA256: String
    let configPath: String
    let configDevice: UInt64
    let configInode: UInt64
    let configSize: UInt64
    let configSHA256: String
    let uid: UInt64
    let homeDirectory: String
    enum CodingKeys: String, CodingKey {
        case schema, transactionContextSHA256 = "transaction_context_sha256", configPath = "config_path"
        case configDevice = "config_device", configInode = "config_inode", configSize = "config_size"
        case configSHA256 = "config_sha256", uid, homeDirectory = "home_directory"
    }
}

struct MalibuTransactionCodeIdentity: Codable, Equatable, Sendable {
    let cdHash: Data
    let identifier: String
    let team: String
    static func read(_ url: URL) throws -> Self {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { throw ModelManagementError.invalidCatalog }
        var requirement: SecRequirement?
        let text = "identifier \"live.malibu.provider.cli\" and anchor apple generic and certificate leaf[subject.OU] = \"YF7XNRJUG4\""
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else { throw ModelManagementError.invalidCatalog }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let fields = info as? [String: Any],
              let hash = fields[kSecCodeInfoUnique as String] as? Data,
              let identifier = fields[kSecCodeInfoIdentifier as String] as? String,
              let team = fields[kSecCodeInfoTeamIdentifier as String] as? String,
              !hash.isEmpty else { throw ModelManagementError.invalidCatalog }
        return Self(cdHash: hash, identifier: identifier, team: team)
    }
}

struct MalibuTransactionPin: Codable, Equatable, Sendable {
    var version = 2
    let code: MalibuTransactionCodeIdentity
    let configuredPath: String
    let binaryVersion: String
    let capabilities: Set<String>
    let manifestDigest: String
    let context: MalibuTransactionContextExpectation
    var inventory: MalibuPayloadInventory = .empty
}

// These files share the existing trusted-operator-UID boundary. No path supplied
// by a pending record is used as an executable destination.
enum MalibuTransactionFiles {
    static func directory(_ paths: ProviderPaths) -> URL { paths.appSupport.appendingPathComponent("ModelTransactions") }
    static func pendingURL(_ paths: ProviderPaths) -> URL { directory(paths).appendingPathComponent("pending.json") }
    static func payload(_ paths: ProviderPaths, id: String, pin: MalibuTransactionPin) throws -> URL {
        guard malibuCanonicalUUID(id), pin.code.cdHash.count <= 64, !pin.code.cdHash.isEmpty else { throw ModelManagementError.invalidCatalog }
        return directory(paths).appendingPathComponent("executables").appendingPathComponent(id + "-" + pin.code.cdHash.map { String(format: "%02x", $0) }.joined())
    }
    static func snapshot(_ paths: ProviderPaths, id: String, pin: MalibuTransactionPin) throws -> URL {
        try payload(paths, id: id, pin: pin).appendingPathComponent("macprovider-cli")
    }
    static func retired(_ paths: ProviderPaths, id: String, pin: MalibuTransactionPin) throws -> URL {
        let active = try payload(paths, id: id, pin: pin)
        return active.deletingLastPathComponent().appendingPathComponent(".retired-" + active.lastPathComponent)
    }
    static func absentPending(_ paths: ProviderPaths) throws {
        var st = stat()
        guard lstat(pendingURL(paths).path, &st) != 0, errno == ENOENT else { throw ModelManagementError.invalidCatalog }
    }
    static func exists(_ url: URL) throws -> Bool {
        var st = stat()
        if lstat(url.path, &st) == 0 { return true }
        guard errno == ENOENT else { throw ModelManagementError.invalidCatalog }
        return false
    }
    static func noACL(_ fd: Int32) -> Bool {
        errno = 0
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else { return errno == 0 || errno == ENOENT }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        guard acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry) == 0 else { return false }
        return entry == nil
    }
    static func safeParents(_ url: URL) throws {
        var parentPath = (url.path as NSString).deletingLastPathComponent
        // Root-owned system ancestors are allowed; every user-owned component
        // must be private against other users and never a symlink.
        while parentPath != "/" {
            var st = stat()
            if parentPath == "/var" { parentPath = "/private/var" }
            if parentPath == "/tmp" { parentPath = "/private/tmp" }
            guard lstat(parentPath, &st) == 0, st.st_mode & S_IFMT == S_IFDIR,
                  st.st_uid == getuid() || st.st_uid == 0,
                  st.st_mode & 0o022 == 0 || (st.st_uid == 0 && st.st_mode & S_ISVTX != 0) else { throw ModelManagementError.invalidCatalog }
            if st.st_uid == getuid() {
                let fd = open(parentPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw ModelManagementError.invalidCatalog }
                let safe = noACL(fd) || InstalledProviderMonitor.hasSafeDirectoryACL(fd)
                close(fd)
                guard safe else { throw ModelManagementError.invalidCatalog }
            }
            parentPath = (parentPath as NSString).deletingLastPathComponent
        }
    }
    static func ensureDirectory(_ url: URL) throws {
        var st = stat()
        if lstat(url.path, &st) != 0 {
            guard errno == ENOENT else { throw ModelManagementError.invalidCatalog }
            let parent = url.deletingLastPathComponent()
            var parentInfo = stat()
            if lstat(parent.path, &parentInfo) != 0 { try ensureDirectory(parent) }
            else { try safeParents(url) }
            guard mkdir(url.path, 0o700) == 0 || errno == EEXIST else { throw ModelManagementError.invalidCatalog }
        }
        try safeParents(url.appendingPathComponent("entry"))
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ModelManagementError.invalidCatalog }
        defer { close(fd) }
        guard fstat(fd, &st) == 0, st.st_uid == getuid(), st.st_mode & 0o077 == 0, noACL(fd) else { throw ModelManagementError.invalidCatalog }
    }
    static func read(_ url: URL, limit: Int, executable: Bool = false) throws -> (Data, stat) {
        try safeParents(url)
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ModelManagementError.invalidCatalog }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == getuid(), before.st_nlink == 1, before.st_mode & 0o022 == 0,
              executable || before.st_mode & 0o077 == 0,
              before.st_size > 0, before.st_size <= limit, noACL(fd),
              !executable || before.st_mode & S_IXUSR != 0 else { throw ModelManagementError.invalidCatalog }
        var data = Data(), chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count == 0 { break }
            guard count > 0, data.count + count <= limit else { throw ModelManagementError.invalidCatalog }
            data.append(contentsOf: chunk.prefix(count))
        }
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec, data.count == before.st_size else { throw ModelManagementError.invalidCatalog }
        return (data, before)
    }
    static func write(_ data: Data, to url: URL, mode: mode_t = 0o600) throws {
        try ensureDirectory(url.deletingLastPathComponent())
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".tmp-" + UUID().uuidString.lowercased())
        let fd = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, mode)
        guard fd >= 0 else { throw ModelManagementError.invalidCatalog }
        defer { close(fd); unlink(temporary.path) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                guard count > 0 else { throw ModelManagementError.invalidCatalog }
                offset += count
            }
        }
        guard fsync(fd) == 0, rename(temporary.path, url.path) == 0 else { throw ModelManagementError.invalidCatalog }
        try syncDirectory(url.deletingLastPathComponent())
    }
    static func syncDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ModelManagementError.invalidCatalog }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw ModelManagementError.invalidCatalog }
    }
    static func context(paths: ProviderPaths, digest: String) throws -> MalibuTransactionContextExpectation {
        guard malibuDigest(digest) else { throw ModelManagementError.invalidCatalog }
        let url = paths.configFile.standardizedFileURL
        guard url.resolvingSymlinksInPath() == url else { throw ModelManagementError.invalidCatalog }
        let (data, st) = try read(url, limit: 1_048_576)
        return .init(transactionContextSHA256: digest, configPath: url.path,
                     configDevice: UInt64(UInt32(bitPattern: st.st_dev)), configInode: UInt64(st.st_ino), configSize: UInt64(st.st_size),
                     configSHA256: malibuSHA256(data), uid: UInt64(getuid()), homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
    }
    static func openControlLock(paths: ProviderPaths) throws -> Int32 {
        try ensureDirectory(directory(paths))
        let fd = open(directory(paths).appendingPathComponent("control.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ModelManagementError.invalidCatalog }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_uid == getuid(), st.st_nlink == 1, st.st_mode & S_IFMT == S_IFREG,
              st.st_mode & 0o077 == 0, noACL(fd), flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd); throw ModelManagementError.invalidCatalog
        }
        return fd
    }
    static func withMetadataLock<T>(paths: ProviderPaths, _ body: () throws -> T) throws -> T {
        try ensureDirectory(directory(paths))
        let fd = open(directory(paths).appendingPathComponent("metadata.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ModelManagementError.invalidCatalog }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_uid == getuid(), st.st_nlink == 1, st.st_mode & S_IFMT == S_IFREG,
              st.st_mode & 0o077 == 0, noACL(fd), flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw ModelManagementError.invalidCatalog }
        return try body()
    }
    static func save(_ pending: MalibuPendingCatalogTransaction?, paths: ProviderPaths) throws {
        try withMetadataLock(paths: paths) {
            if let existing = try load(paths: paths), let pending {
                guard existing.sameOperation(as: pending), existing.pin == pending.pin else { throw ModelManagementError.invalidCatalog }
            }
            try saveLocked(pending, paths: paths)
        }
    }
    static func clear(_ pending: MalibuPendingCatalogTransaction, paths: ProviderPaths, request: MalibuTransactionRequest? = nil, nativeIdentity: (URL) throws -> MalibuTransactionCodeIdentity = MalibuTransactionCodeIdentity.read, afterRetirement: () throws -> Void = {}, pendingDirectorySync: (URL) throws -> Void = syncDirectory) throws {
        try withMetadataLock(paths: paths) {
            let controlLock = try openControlLock(paths: paths)
            defer { close(controlLock) }
            guard let existing = try load(paths: paths) else {
                // A previous unlink may have succeeded without its persistence
                // barrier. Completion retries must establish that barrier.
                try durableAbsentPendingLocked(paths, sync: pendingDirectorySync)
                return
            }
            guard existing.sameOperation(as: pending), existing.pin == pending.pin,
                  let pin = pending.pin else { throw ModelManagementError.invalidCatalog }
            let active = try payload(paths, id: pending.id, pin: pin), retired = try retired(paths, id: pending.id, pin: pin)
            if try exists(active) {
                guard try !exists(retired), try MalibuTransactionPayload.scan(active, source: false, request: request).inventory == pin.inventory,
                      try nativeIdentity(active.appendingPathComponent("macprovider-cli")) == pin.code else { throw ModelManagementError.invalidCatalog }
                try request?.check()
                guard rename(active.path, retired.path) == 0 else { throw ModelManagementError.invalidCatalog }
                try syncDirectory(active.deletingLastPathComponent())
            } else if try exists(retired) {
                guard try MalibuTransactionPayload.scan(retired, source: false, request: request).inventory == pin.inventory,
                      try nativeIdentity(retired.appendingPathComponent("macprovider-cli")) == pin.code else { throw ModelManagementError.invalidCatalog }
            } else { throw ModelManagementError.invalidCatalog }
            try afterRetirement()
            try request?.check()
            do {
                try saveLocked(nil, paths: paths, pendingDirectorySync: pendingDirectorySync)
            } catch {
                // Keep the full retired payload and restore the exact record
                // where possible. Even if storage refuses restoration, every
                // disposal/completion retry requires durable absence first.
                try? saveLocked(existing, paths: paths)
                throw error
            }
            // The intact retired payload is now a no-pending orphan. Reclaim it
            // in bounded maintenance before the next capture; no slow deletion
            // can obscure already durable terminal completion.
        }
    }
    static func restoreRetired(_ pending: MalibuPendingCatalogTransaction, paths: ProviderPaths, request: MalibuTransactionRequest, nativeIdentity: (URL) throws -> MalibuTransactionCodeIdentity = MalibuTransactionCodeIdentity.read) throws {
        guard let pin = pending.pin else { throw ModelManagementError.invalidCatalog }
        let active = try payload(paths, id: pending.id, pin: pin), retired = try retired(paths, id: pending.id, pin: pin)
        if try exists(retired) {
            guard try !exists(active), try MalibuTransactionPayload.scan(retired, source: false, request: request).inventory == pin.inventory,
                  try nativeIdentity(retired.appendingPathComponent("macprovider-cli")) == pin.code else { throw ModelManagementError.invalidCatalog }
            try request.check()
            guard rename(retired.path, active.path) == 0 else { throw ModelManagementError.invalidCatalog }
            try syncDirectory(active.deletingLastPathComponent())
        }
    }
    static func durableAbsentPendingLocked(_ paths: ProviderPaths, sync: (URL) throws -> Void = syncDirectory) throws {
        try absentPending(paths)
        try sync(directory(paths))
        try absentPending(paths)
    }
    static func collectOrphans(paths: ProviderPaths, request: MalibuTransactionRequest, pendingDirectorySync: (URL) throws -> Void = syncDirectory) throws {
        try withMetadataLock(paths: paths) {
            let controlLock = try openControlLock(paths: paths)
            defer { close(controlLock) }
            try collectOrphansLocked(paths: paths, request: request, pendingDirectorySync: pendingDirectorySync)
        }
    }
    // Callers hold both fixed locks for the barrier and the entire disposal.
    static func collectOrphansLocked(paths: ProviderPaths, request: MalibuTransactionRequest, pendingDirectorySync: (URL) throws -> Void = syncDirectory) throws {
        try request.check()
        try durableAbsentPendingLocked(paths, sync: pendingDirectorySync)
        let root = directory(paths).appendingPathComponent("executables")
        try ensureDirectory(root)
        let rootFD = try MalibuTransactionPayload.directoryFD(root, privateDirectory: true)
        defer { close(rootFD) }
        let names = try MalibuTransactionPayload.names(rootFD)
        guard names.count <= 4 else { throw ModelManagementError.invalidCatalog }
        func published(_ name: String) -> Bool {
            guard name.count > 37, malibuCanonicalUUID(String(name.prefix(36))), name.dropFirst(36).first == "-" else { return false }
            let hash = name.dropFirst(37)
            return !hash.isEmpty && hash.count <= 128 && hash.count % 2 == 0 && hash.allSatisfy { "0123456789abcdef".contains($0) }
        }
        for name in names {
            try request.check(); try absentPending(paths)
            var st = stat()
            guard fstatat(rootFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { throw ModelManagementError.invalidCatalog }
            let isDirectory = st.st_mode & S_IFMT == S_IFDIR
            let knownDirectory = published(name) || (name.hasPrefix(".payload-") && malibuCanonicalUUID(String(name.dropFirst(9)))) || (name.hasPrefix(".retired-") && published(String(name.dropFirst(9))))
            let knownFile = published(name) || [".tmp-", ".snapshot-"].contains(where: { name.hasPrefix($0) && malibuCanonicalUUID(String(name.dropFirst($0.count))) })
            let url = root.appendingPathComponent(name)
            if isDirectory {
                guard knownDirectory else { throw ModelManagementError.invalidCatalog }
                try MalibuTransactionPayload.removePartial(url, request: request) { try absentPending(paths) }
            } else {
                guard knownFile, st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid(), st.st_nlink == 1,
                      st.st_mode & 0o077 == 0, st.st_size >= 0, st.st_size <= MalibuTransactionPayload.maximumBytes else { throw ModelManagementError.invalidCatalog }
                let fd = openat(rootFD, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw ModelManagementError.invalidCatalog }; defer { close(fd) }
                var opened = stat()
                guard fstat(fd, &opened) == 0, MalibuTransactionPayload.Identity(opened) == MalibuTransactionPayload.Identity(st), noACL(fd) else { throw ModelManagementError.invalidCatalog }
                try request.check(); try absentPending(paths)
                guard unlinkat(rootFD, name, 0) == 0 else { throw ModelManagementError.invalidCatalog }
            }
        }
        try syncDirectory(root)
    }
    static func saveLocked(_ pending: MalibuPendingCatalogTransaction?, paths: ProviderPaths, pendingDirectorySync: (URL) throws -> Void = syncDirectory) throws {
        if let pending { try write(JSONEncoder().encode(pending), to: pendingURL(paths)) }
        else {
            let url = pendingURL(paths)
            if unlink(url.path) != 0 && errno != ENOENT { throw ModelManagementError.invalidCatalog }
            try durableAbsentPendingLocked(paths, sync: pendingDirectorySync)
        }
    }
    static func load(paths: ProviderPaths) throws -> MalibuPendingCatalogTransaction? {
        var st = stat()
        if lstat(pendingURL(paths).path, &st) != 0 && errno == ENOENT { return nil }
        let (data, _) = try read(pendingURL(paths), limit: 65536)
        try MalibuStrictJSON.rejectDuplicateKeys(data)
        let value = try JSONDecoder().decode(MalibuPendingCatalogTransaction.self, from: data)
        guard value.validBinding, value.pin?.version == 2 else { throw ModelManagementError.invalidCatalog }
        try MalibuTransactionPayload.validate(value.pin!.inventory, complete: true)
        return value
    }
}

private final class MalibuCatalogLease: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32
    init(_ descriptor: Int32) { self.descriptor = descriptor }
    func borrow() -> Int32 { lock.lock(); defer { lock.unlock() }; return descriptor }
    func closeLease() { lock.lock(); let fd = descriptor; descriptor = -1; lock.unlock(); if fd >= 0 { close(fd) } }
    deinit { closeLease() }
}
private struct MalibuPreparedCatalogLaunch: Sendable {
    let executable: URL
    let expectation: Data
    let environment: [String: String]
    let lease: MalibuCatalogLease
}

@MainActor
extension MalibuModelCLI {
    func cancelCatalogAuthorization() { catalogAuthorization?.1.revoke() }
    func authorizeCatalog(_ pending: MalibuPendingCatalogTransaction, contextDigest: String, peer: MalibuModelPeerEvidence, paths: ProviderPaths) async throws -> MalibuTransactionPin {
        let request = MalibuTransactionRequest(timeout: 30)
        catalogAuthorization = (pending, request)
        let pin = try await MalibuTransactionWorker.shared.run(request: request) { [self] request in
            guard pending.validBinding, peer.isFresh(), MalibuModelCapabilityManifest.checkedIn.supports(MalibuModelCapabilityManifest.localActivation, peer: peer) else { throw ModelManagementError.invalidCatalog }
            return try MalibuTransactionFiles.withMetadataLock(paths: paths) {
                try request.check(); try MalibuTransactionFiles.absentPending(paths)
                let lease = try MalibuTransactionFiles.openControlLock(paths: paths); defer { close(lease) }
                let source = try self.resolveExecutable(peer: peer).standardizedFileURL
                let configured = InstalledProviderMonitor.configuredProviderProgram().standardizedFileURL
                try request.check()
                guard source == configured, source.resolvingSymlinksInPath() == source,
                      Self.isSignedProviderCLI(at: source, runningPID: peer.servicePID) else { throw ModelManagementError.invalidCatalog }
                try request.check()
                let code = try MalibuTransactionCodeIdentity.read(source)
                var pin = MalibuTransactionPin(code: code, configuredPath: configured.path, binaryVersion: peer.binaryVersion!, capabilities: peer.capabilities,
                    manifestDigest: MalibuModelCapabilityManifest.checkedIn.controlDigest, context: try MalibuTransactionFiles.context(paths: paths, digest: contextDigest))
                try request.check(); try MalibuTransactionFiles.collectOrphansLocked(paths: paths, request: request)
                let sourceDirectory = source.deletingLastPathComponent()
                let observed = try MalibuTransactionPayload.scan(sourceDirectory, source: true, request: request)
                pin.inventory = observed.inventory
                let destination = try MalibuTransactionFiles.payload(paths, id: pending.id, pin: pin)
                let temporary = destination.deletingLastPathComponent().appendingPathComponent(".payload-" + UUID().uuidString.lowercased())
                try MalibuTransactionPayload.copy(source: sourceDirectory, destination: temporary, scan: observed, request: request)
                guard try MalibuTransactionPayload.scan(temporary, source: false, request: request).inventory == pin.inventory,
                      try MalibuTransactionCodeIdentity.read(temporary.appendingPathComponent("macprovider-cli")) == code else { throw ModelManagementError.invalidCatalog }
                let finalSource = try MalibuTransactionPayload.scan(sourceDirectory, source: true, request: request)
                guard finalSource.inventory == observed.inventory, finalSource.identities == observed.identities,
                      try MalibuTransactionCodeIdentity.read(source) == code else { throw ModelManagementError.invalidCatalog }
                try request.check()
                guard rename(temporary.path, destination.path) == 0 else { throw ModelManagementError.invalidCatalog }
                try request.check(); try MalibuTransactionFiles.syncDirectory(destination.deletingLastPathComponent())
                var authorized = pending; authorized.pin = pin
                try request.check(); try MalibuTransactionFiles.saveLocked(authorized, paths: paths)
                try request.check()
                return pin
            }
        }
        try request.check()
        catalogAuthorization = (pending, request)
        return pin
    }
    func runCatalog(_ pending: MalibuPendingCatalogTransaction, control: MalibuCatalogControl?, peer: MalibuModelPeerEvidence?, paths: ProviderPaths,
                    onLine: @escaping @MainActor @Sendable (String) -> Void) async throws -> ModelCLIResult {
        let request: MalibuTransactionRequest
        if control == nil {
            guard let authorization = catalogAuthorization, authorization.0.sameOperation(as: pending) else { throw ModelManagementError.invalidCatalog }
            request = authorization.1; catalogAuthorization = nil
        } else { request = MalibuTransactionRequest(timeout: 10) }
        let prepared = try await MalibuTransactionWorker.shared.run(request: request) { [self] request -> MalibuPreparedCatalogLaunch in
            try request.check()
            let lease = MalibuCatalogLease(try MalibuTransactionFiles.openControlLock(paths: paths))
            if control == .cancel {
                try MalibuTransactionFiles.withMetadataLock(paths: paths) {
                    try request.check()
                    guard let saved = try MalibuTransactionFiles.load(paths: paths), saved.sameOperation(as: pending), saved.pin == pending.pin else { throw ModelManagementError.invalidCatalog }
                    var intent = saved; intent.cancelRequested = true
                    try request.check(); try MalibuTransactionFiles.saveLocked(intent, paths: paths); try request.check()
                }
            }
            guard pending.validBinding, let pin = pending.pin, pin.version == 2,
                  pin.manifestDigest == MalibuModelCapabilityManifest.checkedIn.controlDigest,
                  ProviderCLIVersion.strictNormalize(pin.binaryVersion) != nil,
                  [MalibuModelCapabilityManifest.catalogTransactions, MalibuModelCapabilityManifest.localActivation, MalibuModelCapabilityManifest.recommendationAdoption].allSatisfy({ capability in
                      guard let tier = MalibuModelCapabilityManifest.checkedIn.tiers[capability] else { return false }
                      return pin.capabilities.isSuperset(of: tier.localStatusCapabilities.union(tier.commandSchemas).union(tier.controlFrameSchemas))
                          && ProviderCLIVersion.compare(pin.binaryVersion, tier.firstSupportingBinaryVersion) != .ascending
                  }), pin.context == (try MalibuTransactionFiles.context(paths: paths, digest: pin.context.transactionContextSHA256)) else { throw ModelManagementError.invalidCatalog }
            try MalibuTransactionPayload.validate(pin.inventory, complete: true)
            try request.check()
            if control == nil {
                guard let peer, peer.isFresh(), let pid = peer.servicePID,
                      try self.resolveExecutable(peer: peer).standardizedFileURL.path == pin.configuredPath,
                      Self.isSignedProviderCLI(at: URL(fileURLWithPath: pin.configuredPath), runningPID: pid) else { throw ModelManagementError.invalidCatalog }
            }
            try request.check()
            let configured = InstalledProviderMonitor.configuredProviderProgram().standardizedFileURL
            guard configured.path == pin.configuredPath, InstalledProviderMonitor.isOwnerPrivateExecutable(atPath: configured.path),
                  try MalibuTransactionCodeIdentity.read(configured) == pin.code,
                  try MalibuTransactionPayload.scan(configured.deletingLastPathComponent(), source: true, request: request).inventory == pin.inventory else { throw ModelManagementError.invalidCatalog }
            try MalibuTransactionFiles.withMetadataLock(paths: paths) {
                try request.check()
                guard let saved = try MalibuTransactionFiles.load(paths: paths), saved.sameOperation(as: pending), saved.pin == pin else { throw ModelManagementError.invalidCatalog }
                try MalibuTransactionFiles.restoreRetired(pending, paths: paths, request: request)
            }
            let payload = try MalibuTransactionFiles.payload(paths, id: pending.id, pin: pin)
            guard try MalibuTransactionPayload.scan(payload, source: false, request: request).inventory == pin.inventory,
                  try MalibuTransactionCodeIdentity.read(payload.appendingPathComponent("macprovider-cli")) == pin.code else { throw ModelManagementError.invalidCatalog }
            try request.check()
            return MalibuPreparedCatalogLaunch(executable: payload.appendingPathComponent("macprovider-cli"), expectation: try JSONEncoder().encode(pin.context), environment: try ProcessEnvironmentSanitizer.sanitized(), lease: lease)
        }
        if control != nil {
            // Re-reserve the same nonce while carrying the already-held lease.
            // Busy/timeout here drops the prepared lease without starting a child.
            return try await MalibuTransactionWorker.shared.run(request: request) { request in
                try MalibuBoundedCatalogProcess.execute(executable: prepared.executable, arguments: pending.arguments(control: control, paths: paths), expectation: prepared.expectation,
                    environment: prepared.environment, lockDirectory: MalibuTransactionFiles.directory(paths), control: true, timeout: request.remaining,
                    resultDocument: control == .result, inheritedLock: prepared.lease.borrow(), request: request, onLine: { line in
                        guard (try? request.check()) != nil else { return }; onLine(line)
                    })
            }
        }
        return try await MalibuBoundedCatalogProcess.run(executable: prepared.executable, arguments: pending.arguments(control: nil, paths: paths), expectation: prepared.expectation,
            environment: prepared.environment, lockDirectory: MalibuTransactionFiles.directory(paths), control: false, timeout: Double(pending.timeoutSeconds) + 30,
            resultDocument: false, inheritedLock: nil, request: request, onSpawn: { prepared.lease.closeLease() }, onLine: onLine)
    }
}

enum MalibuCatalogControl: String, Sendable { case status, cancel, result }

// Single directly spawned child, inherited flock ownership, bounded pipes, and
// waitpid before completion. Never signals a PID restored from disk.
enum MalibuBoundedCatalogProcess {
    static let contextFD: Int32 = 198, lockFD: Int32 = 199, lifetimeFD: Int32 = 200
    @MainActor static func run(executable: URL, arguments: [String], expectation: Data, environment: [String: String], lockDirectory: URL,
                             control: Bool, timeout: TimeInterval, resultDocument: Bool,
                             inheritedLock: Int32? = nil, request: MalibuTransactionRequest? = nil, onSpawn: @escaping @Sendable () -> Void = {},
                             onLine: @escaping @MainActor @Sendable (String) -> Void) async throws -> ModelCLIResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try execute(executable: executable, arguments: arguments, expectation: expectation, environment: environment,
                                             lockDirectory: lockDirectory, control: control, timeout: timeout, resultDocument: resultDocument, inheritedLock: inheritedLock, request: request, onSpawn: onSpawn, onLine: onLine)
                    continuation.resume(returning: result)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    static func execute(executable: URL, arguments: [String], expectation: Data, environment: [String: String], lockDirectory: URL,
                                control: Bool, timeout: TimeInterval, resultDocument: Bool,
                                inheritedLock: Int32? = nil, request: MalibuTransactionRequest? = nil, onSpawn: @escaping @Sendable () -> Void = {},
                                onLine: @escaping @MainActor @Sendable (String) -> Void) throws -> ModelCLIResult {
        guard expectation.count <= 4096 else { throw ModelManagementError.invalidCatalog }
        let started = DispatchTime.now().uptimeNanoseconds
        var descriptors: [Int32] = []
        defer { for fd in descriptors { close(fd) } }
        func high(_ fd: Int32) throws -> Int32 {
            guard fd >= 0 else { throw ModelManagementError.invalidCatalog }
            let copy = fcntl(fd, F_DUPFD_CLOEXEC, 210); close(fd)
            guard copy >= 0 else { throw ModelManagementError.invalidCatalog }
            descriptors.append(copy); return copy
        }
        func makePipe() throws -> (Int32, Int32) {
            var fds: [Int32] = [0, 0]
            guard pipe(&fds) == 0 else { throw ModelManagementError.invalidCatalog }
            return (try high(fds[0]), try high(fds[1]))
        }
        let input = try makePipe(), output = try makePipe(), errors = try makePipe(), lifetime = try makePipe()
        var lockDescriptor: Int32?
        if control, let inheritedLock {
            lockDescriptor = try high(dup(inheritedLock))
        } else if control {
            try MalibuTransactionFiles.ensureDirectory(lockDirectory)
            let url = lockDirectory.appendingPathComponent("control.lock")
            let fd = try high(open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600))
            var st = stat()
            guard fstat(fd, &st) == 0, st.st_uid == getuid(), st.st_nlink == 1, st.st_mode & S_IFMT == S_IFREG,
                  st.st_mode & 0o077 == 0, MalibuTransactionFiles.noACL(fd), flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw ModelManagementError.invalidCatalog }
            lockDescriptor = fd
        }
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw ModelManagementError.invalidCatalog }
        defer { posix_spawn_file_actions_destroy(&actions) }
        var mappings: [(Int32, Int32)] = [(input.0, contextFD), (output.1, STDOUT_FILENO), (errors.1, STDERR_FILENO)]
        if let lockDescriptor { mappings += [(lockDescriptor, lockFD), (lifetime.0, lifetimeFD)] }
        for (from, to) in mappings { guard posix_spawn_file_actions_adddup2(&actions, from, to) == 0 else { throw ModelManagementError.invalidCatalog } }
        for fd in descriptors { posix_spawn_file_actions_addclose(&actions, fd) }
        var args = arguments + ["--transaction-context-fd", String(contextFD)]
        if control { args += ["--control-lock-fd", String(lockFD), "--control-parent-pid", String(getpid()), "--control-lifetime-fd", String(lifetimeFD)] }
        let argv = ([executable.path] + args).map { strdup($0) } + [nil]
        let env = environment.sorted { $0.key < $1.key }.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { for value in argv + env { if let value { free(value) } } }
        var child: pid_t = 0
        try request?.commitSpawn()
        let code = argv.withUnsafeBufferPointer { a in env.withUnsafeBufferPointer { e in posix_spawn(&child, executable.path, &actions, nil, a.baseAddress!, e.baseAddress!) } }
        guard code == 0 else { throw ModelManagementError.invalidCatalog }
        onSpawn()
        var reaped = false
        defer { if !reaped { if control { kill(child, SIGKILL) }; while waitpid(child, nil, 0) < 0 && errno == EINTR {} } }
        func closeOwned(_ fd: Int32) { close(fd); descriptors.removeAll { $0 == fd } }
        closeOwned(output.1); closeOwned(errors.1); closeOwned(input.0); closeOwned(lifetime.0)
        guard fcntl(input.1, F_SETNOSIGPIPE, 1) == 0 else { throw ModelManagementError.invalidCatalog }
        let written = expectation.withUnsafeBytes { Darwin.write(input.1, $0.baseAddress, $0.count) }
        closeOwned(input.1)
        guard written == expectation.count else { throw ModelManagementError.invalidCatalog }
        _ = fcntl(output.0, F_SETFL, O_NONBLOCK); _ = fcntl(errors.0, F_SETFL, O_NONBLOCK)
        var stdout = Data(), stderr = Data(), partial = Data(), failure = false, sentTerm = false, status: Int32 = 0
        var deliveredLines = 0
        var openStreams: Set<Int32> = [output.0, errors.0]
        let deliveries = DispatchGroup()
        func deliver(_ data: Data) {
            guard !failure, deliveredLines < 8192 else { failure = true; return }
            deliveredLines += 1
            guard let line = String(data: data, encoding: .utf8), !line.isEmpty else { if !data.isEmpty { failure = true }; return }
            deliveries.enter()
            Task { @MainActor in onLine(line); deliveries.leave() }
        }
        while !reaped || !openStreams.isEmpty {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
            let expired = request.map { (try? $0.check()) == nil } ?? false
            // Pipe EOF is not a lifetime authority: an unexpected descendant
            // can retain stdout after the exact helper has already exited.
            if control && (elapsed >= timeout || expired) && reaped { failure = true; openStreams.removeAll(); break }
            if control && !reaped && (failure || elapsed >= timeout || expired) { failure = true; kill(child, SIGKILL) }
            else if !reaped && control && elapsed >= max(0, timeout - 1) && !sentTerm { sentTerm = true; kill(child, SIGTERM) }
            var polls = openStreams.map { pollfd(fd: $0, events: Int16(POLLIN | POLLHUP), revents: 0) }
            _ = poll(&polls, nfds_t(polls.count), 20)
            for item in polls where item.revents != 0 {
                var bytes = [UInt8](repeating: 0, count: 16384)
                let count = Darwin.read(item.fd, &bytes, bytes.count)
                if count == 0 { openStreams.remove(item.fd); continue }
                if count < 0 { if errno != EAGAIN && errno != EINTR { openStreams.remove(item.fd); failure = true }; continue }
                let data = Data(bytes.prefix(count))
                if item.fd == errors.0 {
                    if stderr.count + count > 65536 { failure = true } else { stderr.append(data) }
                } else {
                    if stdout.count + count > 8 * 1024 * 1024 { failure = true; continue }
                    stdout.append(data)
                    if !failure && !resultDocument {
                        partial.append(data)
                        while let newline = partial.firstIndex(of: 10) {
                            if newline > 65536 { failure = true; break }
                            deliver(partial.prefix(upTo: newline)); partial.removeSubrange(...newline)
                        }
                        if partial.count > 65536 { failure = true }
                    }
                }
            }
            if !reaped {
                let result = waitpid(child, &status, WNOHANG)
                if result == child { reaped = true }
                else if result < 0 && errno != EINTR { throw ModelManagementError.invalidCatalog }
            }
        }
        if !partial.isEmpty && !failure { deliver(partial) }
        deliveries.wait()
        guard !failure, String(data: stdout, encoding: .utf8) != nil else { throw ModelManagementError.invalidCatalog }
        return ModelCLIResult(exitCode: status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f),
                              stdout: String(decoding: stdout, as: UTF8.self), stderr: String(decoding: stderr, as: UTF8.self))
    }
}
