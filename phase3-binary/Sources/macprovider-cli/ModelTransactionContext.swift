import ArgumentParser
import CryptoKit
import Darwin
import Dispatch
import Foundation
import MacProviderCore

struct ModelTransactionContextOptions: ParsableArguments {
    @Option(help: .hidden) var transactionContextFD: Int32?
    @Option(help: .hidden) var controlLockFD: Int32?
    @Option(help: .hidden) var controlParentPID: Int32?
    @Option(help: .hidden) var controlLifetimeFD: Int32?

    var hasControlOptions: Bool { controlLockFD != nil || controlParentPID != nil || controlLifetimeFD != nil }
    func rejectControlOptions() throws {
        guard !hasControlOptions else { throw ModelTransactionContextError.unavailable }
    }
}

enum ModelTransactionContextError: Error, CustomStringConvertible {
    case unavailable
    var description: String { "transaction context unavailable; refresh the provider state before retrying" }
}

fileprivate struct TransactionPathIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
    init(_ info: stat) throws {
        guard info.st_dev >= 0 else { throw ModelTransactionContextError.unavailable }
        device = UInt64(info.st_dev)
        inode = UInt64(info.st_ino)
    }
}

struct PreparedModelTransactionContext {
    let config: AppConfig
    let durableRoot: URL
    let transactionRoot: URL
    let environment: [String: String]
    let homeDirectory: URL
    fileprivate let configPath: String
    fileprivate let configIdentity: TransactionPathIdentity
    fileprivate let configMetadata: stat
    fileprivate let configSize: UInt64
    fileprivate let configDigest: String
    fileprivate let ancestors: [String: TransactionPathIdentity]

    func validateProjectionAncestors() throws {
        for (path, expected) in ancestors {
            guard try TransactionContextFiles.directoryIdentity(URL(fileURLWithPath: path)) == expected else {
                throw ModelTransactionContextError.unavailable
            }
        }
    }
}

struct BoundModelTransactionContext: @unchecked Sendable {
    let configPath: URL
    let config: AppConfig
    let durableRoot: URL
    let transactionRoot: URL
    let projectionDigest: String
    let environment: [String: String]
    let homeDirectory: URL
    fileprivate let durableIdentity: TransactionPathIdentity
    fileprivate let journalIdentity: TransactionPathIdentity
    func validateStoreRoot(journal: stat? = nil) throws {
        _ = try TransactionContextFiles.ancestors(of: transactionRoot, allowMissing: false)
        guard try TransactionContextFiles.directoryIdentity(durableRoot, requirePrivate: true) == durableIdentity,
              try TransactionContextFiles.directoryIdentity(transactionRoot, requirePrivate: true) == journalIdentity else {
            throw ModelTransactionContextError.unavailable
        }
        if let journal, try TransactionPathIdentity(journal) != journalIdentity { throw ModelTransactionContextError.unavailable }
    }
    fileprivate init(prepared: PreparedModelTransactionContext, digest: String,
                     durable: TransactionPathIdentity, journal: TransactionPathIdentity) {
        durableIdentity = durable
        journalIdentity = journal
        configPath = URL(fileURLWithPath: prepared.configPath)
        config = prepared.config
        durableRoot = prepared.durableRoot
        transactionRoot = prepared.transactionRoot
        projectionDigest = digest
        environment = prepared.environment
        homeDirectory = prepared.homeDirectory
    }
}

private struct TransactionContextExpectation: Decodable {
    let schema: String
    let transaction_context_sha256: String
    let config_path: String
    let config_device: UInt64
    let config_inode: UInt64
    let config_size: UInt64
    let config_sha256: String
    let uid: UInt64
    let home_directory: String
    static let keys: Set<String> = ["schema", "transaction_context_sha256", "config_path", "config_device", "config_inode", "config_size", "config_sha256", "uid", "home_directory"]
}

enum ModelTransactionContextLoader {
    static func projectionEnvironment(_ environment: [String: String]) throws -> [String: String] {
        guard !environment.keys.contains(where: { $0.hasPrefix("MACPROVIDER_") || $0 == "HF_HOME" || $0 == "HF_HUB_CACHE" }) else {
            throw ModelTransactionContextError.unavailable
        }
        let allowed: Set<String> = ["PATH", "HOME", "USER", "TMPDIR", "LANG", "NSUnbufferedIO"]
        return environment.filter { allowed.contains($0.key) || $0.key.hasPrefix("LC_") }
    }

    private static func canonical(_ url: URL) -> URL {
        URL(fileURLWithPath: ModelTransactionDirectory.normalized(url))
    }

    static func kernelHomeDirectory() throws -> URL {
        guard let record = getpwuid(geteuid()), let home = record.pointee.pw_dir else {
            throw ModelTransactionContextError.unavailable
        }
        return canonical(URL(fileURLWithPath: String(cString: home), isDirectory: true))
    }

    static func prepareProjection(
        configPath: String?, environment: [String: String], homeDirectory: URL
    ) throws -> PreparedModelTransactionContext {
        try capture(configPath: configPath, environment: environment, homeDirectory: homeDirectory)
    }

    static func finalizeProjection(
        context: PreparedModelTransactionContext, storeIdentity: ModelTransactionProjectionStoreIdentity
    ) throws -> BoundModelTransactionContext {
        try context.validateProjectionAncestors()
        try storeIdentity.validateCurrent(durableRoot: context.durableRoot, transactionRoot: context.transactionRoot)
        return try finalize(context, expectedStore: storeIdentity)
    }

    static func existingProjection(_ context: PreparedModelTransactionContext,
                                   expectedDigest: String) throws -> BoundModelTransactionContext {
        let bound = try finalize(context)
        guard bound.projectionDigest == expectedDigest else { throw ModelTransactionContextError.unavailable }
        return bound
    }

    static func load(
        configPath: String?, options: ModelTransactionContextOptions,
        environment: [String: String], homeDirectory: URL
    ) throws -> BoundModelTransactionContext {
        guard let descriptor = options.transactionContextFD, descriptor >= 3 else {
            throw ModelTransactionContextError.unavailable
        }
        let data = try TransactionContextFiles.readPipe(descriptor, maximum: 65_536)
        do { try AutotuneStrictJSON.rejectDuplicateKeys(data) }
        catch { throw ModelTransactionContextError.unavailable }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == TransactionContextExpectation.keys,
              let expected = try? JSONDecoder().decode(TransactionContextExpectation.self, from: data),
              expected.schema == "model_transaction_context_expectation.v1",
              validDigest(expected.transaction_context_sha256), validDigest(expected.config_sha256),
              expected.config_size > 0, expected.config_size <= 1_048_576,
              expected.uid == UInt64(geteuid()),
              expected.home_directory.hasPrefix("/"),
              canonical(URL(fileURLWithPath: expected.home_directory)).path == canonical(homeDirectory).path else {
            throw ModelTransactionContextError.unavailable
        }
        let prepared = try capture(configPath: configPath, environment: environment, homeDirectory: homeDirectory)
        guard expected.config_path.hasPrefix("/"),
              canonical(URL(fileURLWithPath: expected.config_path)).path == prepared.configPath,
              expected.config_device == prepared.configIdentity.device,
              expected.config_inode == prepared.configIdentity.inode,
              expected.config_size == prepared.configSize,
              expected.config_sha256 == prepared.configDigest else {
            throw ModelTransactionContextError.unavailable
        }
        let bound = try finalize(prepared)
        guard bound.projectionDigest == expected.transaction_context_sha256 else {
            throw ModelTransactionContextError.unavailable
        }
        return bound
    }

    private static func capture(
        configPath: String?, environment: [String: String], homeDirectory: URL
    ) throws -> PreparedModelTransactionContext {
        let home = canonical(homeDirectory)
        guard let declaredHome = environment["HOME"], declaredHome.hasPrefix("/"),
              canonical(URL(fileURLWithPath: declaredHome)).path == home.path,
              environment.allSatisfy({ key, value in
                  (Set(["PATH", "HOME", "USER", "TMPDIR", "LANG", "NSUnbufferedIO"]).contains(key) || key.hasPrefix("LC_"))
                    && !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
              }) else { throw ModelTransactionContextError.unavailable }
        let fixed = canonical(home.appendingPathComponent(".config/macprovider/config.yaml"))
        guard configPath == nil || (configPath!.hasPrefix("/") && canonical(URL(fileURLWithPath: configPath!)).path == fixed.path) else { throw ModelTransactionContextError.unavailable }
        var ancestors = try TransactionContextFiles.ancestors(of: fixed.deletingLastPathComponent(), allowMissing: false)
        let fd = open(fixed.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ModelTransactionContextError.unavailable }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG, before.st_uid == geteuid(),
              (before.st_mode & 0o077) == 0, before.st_nlink == 1,
              before.st_size > 0, before.st_size <= 1_048_576 else { throw ModelTransactionContextError.unavailable }
        try TransactionContextFiles.validateACL(fd, allowDeny: false)
        let data = try TransactionContextFiles.readRegular(fd, maximum: 1_048_576)
        var after = stat()
        guard fstat(fd, &after) == 0, sameFile(before, after), data.count == before.st_size,
              let text = String(data: data, encoding: .utf8) else { throw ModelTransactionContextError.unavailable }
        let config: AppConfig
        do {
            config = try ConfigLoader.load(cli: CLIOverrides(configPath: fixed.path), environment: environment,
                fileExists: { $0 == fixed.path }, readFile: { path in
                    guard path == fixed.path else { throw ModelTransactionContextError.unavailable }
                    return text
                })
        } catch { throw ModelTransactionContextError.unavailable }
        let resolver = CachedModelArtifactResolver.forConfig(config, environment: environment, homeDirectory: home)
        let root = canonical(resolver.durableRoot)
        let transactions = root.appendingPathComponent(".transactions", isDirectory: true)
        for (path, identity) in try TransactionContextFiles.ancestors(of: transactions, allowMissing: true) {
            if let old = ancestors[path], old != identity { throw ModelTransactionContextError.unavailable }
            ancestors[path] = identity
        }
        let context = PreparedModelTransactionContext(config: config, durableRoot: root, transactionRoot: transactions,
            environment: environment, homeDirectory: home, configPath: fixed.path,
            configIdentity: try TransactionPathIdentity(before), configMetadata: after, configSize: UInt64(data.count),
            configDigest: digest(data), ancestors: ancestors)
        try context.validateProjectionAncestors()
        return context
    }

    private static func finalize(_ prepared: PreparedModelTransactionContext, expectedStore: ModelTransactionProjectionStoreIdentity? = nil) throws -> BoundModelTransactionContext {
        try prepared.validateProjectionAncestors()
        // Validate the exact consumed observation without rereading configuration.
        let fd = open(prepared.configPath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ModelTransactionContextError.unavailable }
        defer { close(fd) }
        var before = stat(), placed = stat()
        guard fstat(fd, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
              before.st_uid == geteuid(), before.st_nlink == 1, (before.st_mode & 0o077) == 0,
              try TransactionPathIdentity(before) == prepared.configIdentity,
              before.st_size == prepared.configSize,
              sameFile(prepared.configMetadata, before), lstat(prepared.configPath, &placed) == 0,
              sameFile(before, placed) else { throw ModelTransactionContextError.unavailable }
        let durable = try TransactionContextFiles.directoryIdentity(prepared.durableRoot, requirePrivate: true)
        let journal = try TransactionContextFiles.directoryIdentity(prepared.transactionRoot, requirePrivate: true)
        if let expectedStore {
            guard durable.device == expectedStore.durableDevice, durable.inode == expectedStore.durableInode,
                  journal.device == expectedStore.journalDevice, journal.inode == expectedStore.journalInode else {
                throw ModelTransactionContextError.unavailable
            }
        }
        let object: [String: Any] = [
            "schema": "model_transaction_context.v1", "namespace": "sanitized_app_v1",
            "config_path": prepared.configPath, "resolved_config_path": prepared.configPath,
            "config_device": prepared.configIdentity.device, "config_inode": prepared.configIdentity.inode,
            "config_size": prepared.configSize, "config_sha256": prepared.configDigest,
            "uid": UInt64(geteuid()), "home_directory": prepared.homeDirectory.path,
            "durable_root": prepared.durableRoot.path, "durable_device": durable.device, "durable_inode": durable.inode,
            "transaction_root": prepared.transactionRoot.path, "transaction_device": journal.device, "transaction_inode": journal.inode
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return BoundModelTransactionContext(prepared: prepared, digest: digest(data), durable: durable, journal: journal)
    }

    private static func validDigest(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func sameFile(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size && a.st_mode == b.st_mode &&
        a.st_uid == b.st_uid && a.st_nlink == b.st_nlink &&
        a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
}

private enum TransactionContextFiles {
    static func ancestors(of url: URL, allowMissing: Bool) throws -> [String: TransactionPathIdentity] {
        var result: [String: TransactionPathIdentity] = [:]
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        result[current.path] = try directoryIdentity(current)
        for component in URL(fileURLWithPath: ModelTransactionDirectory.normalized(url)).pathComponents.dropFirst() {
            current.appendPathComponent(component, isDirectory: true)
            var info = stat()
            if lstat(current.path, &info) != 0 {
                if allowMissing && errno == ENOENT { break }
                throw ModelTransactionContextError.unavailable
            }
            result[current.path] = try directoryIdentity(current)
        }
        return result
    }

    static func directoryIdentity(_ url: URL, requirePrivate: Bool = false) throws -> TransactionPathIdentity {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ModelTransactionContextError.unavailable }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == 0 || info.st_uid == geteuid() else { throw ModelTransactionContextError.unavailable }
        let systemSticky = info.st_uid == 0 && (info.st_mode & S_ISVTX) != 0
        guard (info.st_mode & 0o022) == 0 || systemSticky,
              !requirePrivate || (info.st_uid == geteuid() && (info.st_mode & 0o077) == 0) else {
            throw ModelTransactionContextError.unavailable
        }
        try validateACL(fd, allowDeny: true)
        return try TransactionPathIdentity(info)
    }

    static func validateACL(_ fd: Int32, allowDeny: Bool) throws {
        errno = 0
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
            guard errno == ENOENT else { throw ModelTransactionContextError.unavailable }
            return
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        var next = Int32(ACL_FIRST_ENTRY.rawValue)
        while true {
            let status = acl_get_entry(acl, next, &entry)
            if status == 0, entry == nil { return }
            guard status == 0 || status == 1, let entry else { throw ModelTransactionContextError.unavailable }
            var tag = ACL_UNDEFINED_TAG
            guard allowDeny, acl_get_tag_type(entry, &tag) == 0, tag == ACL_EXTENDED_DENY else {
                throw ModelTransactionContextError.unavailable
            }
            next = Int32(ACL_NEXT_ENTRY.rawValue)
        }
    }

    static func readRegular(_ fd: Int32, maximum: Int) throws -> Data {
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0, data.count + count <= maximum else { throw ModelTransactionContextError.unavailable }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    static func readPipe(_ fd: Int32, maximum: Int) throws -> Data {
        var info = stat()
        guard fd >= 3, fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFIFO,
              fcntl(fd, F_GETFL) & O_ACCMODE == O_RDONLY else { throw ModelTransactionContextError.unavailable }
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while DispatchTime.now().uptimeNanoseconds < deadline {
            var event = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
            let ready = poll(&event, 1, 50)
            if ready < 0 && errno == EINTR { continue }
            guard ready >= 0, event.revents & Int16(POLLERR | POLLNVAL) == 0 else { throw ModelTransactionContextError.unavailable }
            if ready == 0 { continue }
            let count = read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0, data.count + count <= maximum else { throw ModelTransactionContextError.unavailable }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
        }
        throw ModelTransactionContextError.unavailable
    }
}

/// Read helpers inherit a separate lock and lifetime pipe. The monitor starts
/// before configuration or resources and can terminate only this helper.
final class ModelCatalogReadLease {
    private var timer: DispatchSourceTimer?
    private init() {}
    static func start(options: ModelCatalogReadOptions, budget: ModelCatalogReadBudget,
                      homeDirectory: () throws -> URL = ModelTransactionContextLoader.kernelHomeDirectory) throws -> ModelCatalogReadLease {
        let lease = ModelCatalogReadLease()
        guard options.isPresent else { return lease }
        guard let lock = options.readLockFD, lock == 199,
              let lifetime = options.readLifetimeFD, lifetime == 200 else {
            throw ModelCatalogReadError.contextChanged
        }
        var pipeInfo = stat(), lockInfo = stat()
        guard fstat(lifetime, &pipeInfo) == 0, (pipeInfo.st_mode & S_IFMT) == S_IFIFO,
              fcntl(lifetime, F_GETFL) & O_ACCMODE == O_RDONLY,
              fstat(lock, &lockInfo) == 0, (lockInfo.st_mode & S_IFMT) == S_IFREG,
              lockInfo.st_uid == geteuid(), lockInfo.st_nlink == 1,
              (lockInfo.st_mode & 0o777) == 0o600 else { throw ModelCatalogReadError.contextChanged }
        let parent = getppid()
        guard parent > 1 else { throw ModelCatalogReadError.contextChanged }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "macprovider.catalog-read-lifetime"))
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler {
            var event = pollfd(fd: lifetime, events: Int16(POLLIN | POLLHUP), revents: 0)
            let ready = poll(&event, 1, 0)
            if getppid() != parent || ready < 0 || event.revents != 0 { _exit(70) }
            do { try budget.check() } catch { _exit(70) }
        }
        lease.timer = timer; timer.resume()
        let home = try homeDirectory()
        let folder = home.appendingPathComponent("Library/Application Support/Malibu/ModelTransactions")
        _ = try TransactionContextFiles.ancestors(of: folder, allowMissing: false)
        _ = try TransactionContextFiles.directoryIdentity(folder, requirePrivate: true)
        let path = folder.appendingPathComponent("catalog-read.lock")
        let comparison = open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard comparison >= 0 else { throw ModelCatalogReadError.contextChanged }
        defer { close(comparison) }
        var actual = stat()
        guard fstat(comparison, &actual) == 0,
              try TransactionPathIdentity(actual) == TransactionPathIdentity(lockInfo) else {
            throw ModelCatalogReadError.contextChanged
        }
        try TransactionContextFiles.validateACL(lock, allowDeny: false)
        // First prove the lease was already held, then prove that the inherited
        // description owns it. Acquiring an initially unlocked FD is insufficient.
        if flock(comparison, LOCK_EX | LOCK_NB) == 0 {
            _ = flock(comparison, LOCK_UN); throw ModelCatalogReadError.contextChanged
        }
        guard errno == EWOULDBLOCK, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            throw ModelCatalogReadError.contextChanged
        }
        try budget.check()
        return lease
    }
    deinit { timer?.cancel() }
}

final class ModelTransactionControlLease {
    private var timer: DispatchSourceTimer?
    private init() {}
    static func start(options: ModelTransactionContextOptions) throws -> ModelTransactionControlLease {
        try start(options: options, homeDirectory: ModelTransactionContextLoader.kernelHomeDirectory)
    }

    // Internal dependency seam for isolated process tests. Production always
    // uses the kernel home and the same fixed deadline; no runtime input selects it.
    static func start(options: ModelTransactionContextOptions,
                      homeDirectory: () throws -> URL) throws -> ModelTransactionControlLease {
        let lease = ModelTransactionControlLease()
        guard options.hasControlOptions else { return lease }
        guard let lock = options.controlLockFD, let parent = options.controlParentPID,
              let lifetime = options.controlLifetimeFD, let context = options.transactionContextFD,
              lock >= 3, lifetime >= 3, context >= 3, Set([lock, lifetime, context]).count == 3,
              parent > 1, getppid() == parent else { throw ModelTransactionContextError.unavailable }
        let deadline = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "macprovider.transaction-control-lifetime"))
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler {
            var event = pollfd(fd: lifetime, events: Int16(POLLIN | POLLHUP), revents: 0)
            let ready = poll(&event, 1, 0)
            if getppid() != parent || DispatchTime.now().uptimeNanoseconds >= deadline || ready < 0 || event.revents != 0 {
                _exit(70)
            }
        }
        timer.resume()
        lease.timer = timer
        var pipeInfo = stat(), lockInfo = stat()
        guard fstat(lifetime, &pipeInfo) == 0, (pipeInfo.st_mode & S_IFMT) == S_IFIFO,
              fcntl(lifetime, F_GETFL) & O_ACCMODE == O_RDONLY,
              fstat(lock, &lockInfo) == 0, (lockInfo.st_mode & S_IFMT) == S_IFREG,
              lockInfo.st_uid == geteuid(), lockInfo.st_nlink == 1, (lockInfo.st_mode & 0o077) == 0 else {
            throw ModelTransactionContextError.unavailable
        }
        let home = try homeDirectory()
        let lockURL = home.appendingPathComponent("Library/Application Support/Malibu/ModelTransactions/control.lock")
        _ = try TransactionContextFiles.ancestors(of: lockURL.deletingLastPathComponent(), allowMissing: false)
        let comparison = open(lockURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard comparison >= 0 else { throw ModelTransactionContextError.unavailable }
        defer { close(comparison) }
        var actual = stat()
        guard fstat(comparison, &actual) == 0,
              try TransactionPathIdentity(actual) == TransactionPathIdentity(lockInfo) else {
            throw ModelTransactionContextError.unavailable
        }
        try TransactionContextFiles.validateACL(lock, allowDeny: false)
        // The inherited description itself must own the lock. This operation
        // is idempotent for the parent's shared open-file description.
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw ModelTransactionContextError.unavailable }
        // A separately opened description must see the parent's inherited lock.
        if flock(comparison, LOCK_EX | LOCK_NB) == 0 {
            _ = flock(comparison, LOCK_UN)
            throw ModelTransactionContextError.unavailable
        }
        guard errno == EWOULDBLOCK else { throw ModelTransactionContextError.unavailable }
        return lease
    }
    deinit { timer?.cancel() }
}
