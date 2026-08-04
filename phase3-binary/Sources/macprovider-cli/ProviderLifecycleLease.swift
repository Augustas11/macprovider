import Darwin
import Foundation
import ArgumentParser
import CryptoKit

enum ProviderLifecycleLeaseKind: String, Codable, Equatable, Sendable, ExpressibleByArgument {
    case startup
    case maintenance

    var maximumDurationMilliseconds: Int64 {
        switch self {
        case .startup:
            return 30 * 60 * 1_000
        case .maintenance:
            return 20 * 60 * 1_000
        }
    }
}

struct ProviderLifecycleLeaseOwner: Codable, Equatable, Sendable {
    let pid: Int32
    let processStartMicroseconds: Int64
    let bootSession: String

    enum CodingKeys: String, CodingKey {
        case pid
        case processStartMicroseconds = "process_start_us"
        case bootSession = "boot_session"
    }
}

struct ProviderLifecycleLeaseRecord: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let version: Int
    let leaseID: String
    let operationID: String
    let kind: ProviderLifecycleLeaseKind
    let owner: ProviderLifecycleLeaseOwner
    let issuedWallMilliseconds: Int64
    let expiresWallMilliseconds: Int64
    let issuedMonotonicNanoseconds: Int64
    let expiresMonotonicNanoseconds: Int64
    let startupHandoff: ProviderLifecycleStartupHandoff?

    enum CodingKeys: String, CodingKey {
        case version
        case leaseID = "lease_id"
        case operationID = "operation_id"
        case kind
        case owner
        case issuedWallMilliseconds = "issued_wall_ms"
        case expiresWallMilliseconds = "expires_wall_ms"
        case issuedMonotonicNanoseconds = "issued_monotonic_ns"
        case expiresMonotonicNanoseconds = "expires_monotonic_ns"
        case startupHandoff = "startup_handoff"
    }

    init(
        version: Int,
        leaseID: String,
        operationID: String,
        kind: ProviderLifecycleLeaseKind,
        owner: ProviderLifecycleLeaseOwner,
        issuedWallMilliseconds: Int64,
        expiresWallMilliseconds: Int64,
        issuedMonotonicNanoseconds: Int64,
        expiresMonotonicNanoseconds: Int64,
        startupHandoff: ProviderLifecycleStartupHandoff? = nil
    ) {
        self.version = version
        self.leaseID = leaseID
        self.operationID = operationID
        self.kind = kind
        self.owner = owner
        self.issuedWallMilliseconds = issuedWallMilliseconds
        self.expiresWallMilliseconds = expiresWallMilliseconds
        self.issuedMonotonicNanoseconds = issuedMonotonicNanoseconds
        self.expiresMonotonicNanoseconds = expiresMonotonicNanoseconds
        self.startupHandoff = startupHandoff
    }
}

struct ProviderLifecycleStartupHandoff: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    static let maximumDurationMilliseconds: Int64 = 5 * 60 * 1_000

    enum State: String, Codable, Equatable, Sendable {
        case prepared
        case adopted
    }

    let version: Int
    let handoffID: String
    let state: State
    let operationID: String
    let providerID: String
    let serviceIdentity: String
    let bootSession: String
    let targetExecutablePath: String
    let targetExecutableSHA256: String
    let issuedWallMilliseconds: Int64
    let expiresWallMilliseconds: Int64
    let issuedMonotonicNanoseconds: Int64
    let expiresMonotonicNanoseconds: Int64
    let startupLeaseDurationMilliseconds: Int64

    enum CodingKeys: String, CodingKey {
        case version
        case handoffID = "handoff_id"
        case state
        case operationID = "operation_id"
        case providerID = "provider_id"
        case serviceIdentity = "service_identity"
        case bootSession = "boot_session"
        case targetExecutablePath = "target_executable_path"
        case targetExecutableSHA256 = "target_executable_sha256"
        case issuedWallMilliseconds = "issued_wall_ms"
        case expiresWallMilliseconds = "expires_wall_ms"
        case issuedMonotonicNanoseconds = "issued_monotonic_ns"
        case expiresMonotonicNanoseconds = "expires_monotonic_ns"
        case startupLeaseDurationMilliseconds = "startup_lease_duration_ms"
    }
}

enum ProviderLifecycleLeaseInvalidReason: Equatable, Sendable {
    case malformedRecord
    case unsupportedVersion
    case invalidField(String)
    case durationOutOfRange
    case wallClockBeforeIssue
    case monotonicClockBeforeIssue
    case wallExpired
    case monotonicExpired
    case bootSessionChanged
    case ownerProcessMissingOrReused
    case unsafeStorage(String)
    case storageFailure(String)
}

enum ProviderLifecycleLeaseInspection: Equatable, Sendable {
    case missing
    case valid(ProviderLifecycleLeaseRecord)
    case invalidOrExpired(record: ProviderLifecycleLeaseRecord?, reason: ProviderLifecycleLeaseInvalidReason)
}

enum ProviderLifecycleLeaseError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case invalidDuration(kind: ProviderLifecycleLeaseKind, maximumMilliseconds: Int64)
    case invalidOperationID
    case currentOwnerUnavailable
    case alreadyHeld(ProviderLifecycleLeaseRecord)
    case compareAndSwapFailed
    case leaseNotValid(ProviderLifecycleLeaseInvalidReason)
    case unsafeStorage(path: String, reason: String)
    case malformedRecord(path: String)
    case io(path: String, operation: String, errnoCode: Int32)
    case invalidHandoffField(String)
    case invalidHandoffDuration(maximumMilliseconds: Int64)
    case handoffNotPrepared
    case handoffMismatch(String)
    case handoffExpired
    case launchdServiceOwnerMismatch
    case targetExecutableMismatch

    var description: String {
        switch self {
        case .invalidDuration(let kind, let maximumMilliseconds):
            return "\(kind.rawValue) lease duration must be positive and no greater than \(maximumMilliseconds)ms"
        case .invalidOperationID:
            return "lifecycle lease operation ID is invalid"
        case .currentOwnerUnavailable:
            return "current process lifecycle identity is unavailable"
        case .alreadyHeld(let record):
            return "lifecycle lease is already held by pid \(record.owner.pid) for operation \(record.operationID)"
        case .compareAndSwapFailed:
            return "lifecycle lease changed before the requested compare-and-swap operation"
        case .leaseNotValid(let reason):
            return "lifecycle lease is not valid: \(reason)"
        case .unsafeStorage(let path, let reason):
            return "unsafe lifecycle lease storage at \(path): \(reason)"
        case .malformedRecord(let path):
            return "malformed lifecycle lease at \(path)"
        case .io(let path, let operation, let errnoCode):
            return "lifecycle lease \(operation) failed at \(path): \(String(cString: strerror(errnoCode)))"
        case .invalidHandoffField(let field):
            return "startup handoff field is invalid: \(field)"
        case .invalidHandoffDuration(let maximumMilliseconds):
            return "startup handoff duration must be positive and no greater than \(maximumMilliseconds)ms"
        case .handoffNotPrepared:
            return "no startup handoff is prepared for adoption"
        case .handoffMismatch(let field):
            return "startup handoff does not match \(field)"
        case .handoffExpired:
            return "startup handoff expired before adoption"
        case .launchdServiceOwnerMismatch:
            return "current process is not the exact launchd service owner"
        case .targetExecutableMismatch:
            return "current process executable does not match the prepared startup target"
        }
    }

    var errorDescription: String? { description }
}

struct ProviderLifecycleLeaseEnvironment: @unchecked Sendable {
    let wallMilliseconds: @Sendable () -> Int64
    let monotonicNanoseconds: @Sendable () -> Int64
    let bootSession: @Sendable () -> String?
    let processStartMicroseconds: @Sendable (pid_t) -> Int64?
    let processID: @Sendable () -> pid_t
    let launchdServiceProcessID: @Sendable (String) -> pid_t?
    let executablePath: @Sendable (pid_t) -> String?
    let executableSHA256: @Sendable (String) -> String?

    init(
        wallMilliseconds: @escaping @Sendable () -> Int64,
        monotonicNanoseconds: @escaping @Sendable () -> Int64,
        bootSession: @escaping @Sendable () -> String?,
        processStartMicroseconds: @escaping @Sendable (pid_t) -> Int64?,
        processID: @escaping @Sendable () -> pid_t,
        launchdServiceProcessID: @escaping @Sendable (String) -> pid_t? = { _ in nil },
        executablePath: @escaping @Sendable (pid_t) -> String? = { _ in nil },
        executableSHA256: @escaping @Sendable (String) -> String? = { _ in nil }
    ) {
        self.wallMilliseconds = wallMilliseconds
        self.monotonicNanoseconds = monotonicNanoseconds
        self.bootSession = bootSession
        self.processStartMicroseconds = processStartMicroseconds
        self.processID = processID
        self.launchdServiceProcessID = launchdServiceProcessID
        self.executablePath = executablePath
        self.executableSHA256 = executableSHA256
    }

    static let live = ProviderLifecycleLeaseEnvironment(
        wallMilliseconds: {
            Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
        },
        monotonicNanoseconds: {
            let value = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
            return value > UInt64(Int64.max) ? Int64.max : Int64(value)
        },
        bootSession: {
            var size = 0
            guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else {
                return nil
            }
            var bytes = [CChar](repeating: 0, count: size)
            guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else {
                return nil
            }
            let value = String(cString: bytes).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        },
        processStartMicroseconds: { pid in
            guard pid > 0 else { return nil }
            var info = proc_bsdinfo()
            let count = proc_pidinfo(
                pid,
                PROC_PIDTBSDINFO,
                0,
                &info,
                Int32(MemoryLayout<proc_bsdinfo>.size)
            )
            guard count == Int32(MemoryLayout<proc_bsdinfo>.size) else { return nil }
            let seconds = Int64(info.pbi_start_tvsec)
            let microseconds = Int64(info.pbi_start_tvusec)
            let (scaled, overflowed) = seconds.multipliedReportingOverflow(by: 1_000_000)
            guard !overflowed else { return nil }
            let (combined, additionOverflowed) = scaled.addingReportingOverflow(microseconds)
            return additionOverflowed ? nil : combined
        },
        processID: { getpid() },
        launchdServiceProcessID: { liveLaunchdServiceProcessID($0) },
        executablePath: { liveExecutablePath($0) },
        executableSHA256: { liveExecutableSHA256($0) }
    )

    private static func liveLaunchdServiceProcessID(_ serviceIdentity: String) -> pid_t? {
        launchdServiceProcessID(serviceIdentity) { arguments in
            try SelfUpdate.runLaunchctlCommand(
                arguments: arguments,
                allowFailure: true
            )
        }
    }

    static func launchdServiceProcessID(
        _ serviceIdentity: String,
        runLaunchctl: ([String]) throws -> LaunchctlCommandResult
    ) -> pid_t? {
        let trimmed = serviceIdentity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == serviceIdentity,
              !trimmed.isEmpty,
              trimmed.utf8.count <= 256,
              !trimmed.contains("/") else {
            return nil
        }
        guard let result = try? runLaunchctl([
            "print",
            "gui/\(getuid())/\(serviceIdentity)",
        ]),
        result.terminationStatus == 0 else {
            return nil
        }
        for line in result.output.split(whereSeparator: \.isNewline) {
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.hasPrefix("pid = "),
                  let pid = Int32(value.dropFirst("pid = ".count)),
                  pid > 0 else {
                continue
            }
            return pid
        }
        return nil
    }

    private static func liveExecutablePath(_ pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard count > 0 else { return nil }
        let path = String(cString: buffer)
        return path.hasPrefix("/") && !path.isEmpty ? path : nil
    }

    private static func liveExecutableSHA256(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { return nil }
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var initial = stat()
        guard fstat(fd, &initial) == 0,
              (initial.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { return nil }
            if count == 0 { break }
            hasher.update(data: Data(buffer.prefix(count)))
        }

        var final = stat()
        var named = stat()
        guard fstat(fd, &final) == 0,
              lstat(path, &named) == 0,
              (named.st_mode & S_IFMT) == S_IFREG,
              initial.st_dev == final.st_dev,
              initial.st_ino == final.st_ino,
              initial.st_size == final.st_size,
              initial.st_mtimespec.tv_sec == final.st_mtimespec.tv_sec,
              initial.st_mtimespec.tv_nsec == final.st_mtimespec.tv_nsec,
              initial.st_ctimespec.tv_sec == final.st_ctimespec.tv_sec,
              initial.st_ctimespec.tv_nsec == final.st_ctimespec.tv_nsec,
              named.st_dev == final.st_dev,
              named.st_ino == final.st_ino else {
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// A single-writer, crash-safe lease used to fence slow provider startup and
/// bounded lifecycle maintenance from watchdog intervention. The JSON record
/// is advisory only when every filesystem and owner validation succeeds.
struct ProviderLifecycleLeaseStore: @unchecked Sendable {
    static let maximumRecordBytes: Int64 = 16 * 1_024

    let url: URL
    private let lockURL: URL
    private let expectedOwnerUID: uid_t
    private let environment: ProviderLifecycleLeaseEnvironment

    init(
        url: URL = ProviderLifecycleLeaseStore.defaultURL(),
        expectedOwnerUID: uid_t = getuid(),
        environment: ProviderLifecycleLeaseEnvironment = .live
    ) {
        self.url = url
        self.lockURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).lock")
        self.expectedOwnerUID = expectedOwnerUID
        self.environment = environment
    }

    static func defaultURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/macprovider/lifecycle", isDirectory: true)
            .appendingPathComponent("lease.json")
    }

    static func candidateURL(rootDirectory: URL) -> URL {
        rootDirectory
            .appendingPathComponent("lifecycle", isDirectory: true)
            .appendingPathComponent("lease.json")
    }

    /// A non-throwing observation surface for watchdog and status consumers.
    /// Unsafe or unreadable storage is never treated as a valid grace period.
    func inspect() -> ProviderLifecycleLeaseInspection {
        do {
            guard try validateTrustedDirectory(createIfMissing: false) else { return .missing }
            guard let record = try readRecordIfPresent() else { return .missing }
            if let reason = validationFailure(for: record) {
                return .invalidOrExpired(record: record, reason: reason)
            }
            return .valid(record)
        } catch let error as ProviderLifecycleLeaseError {
            switch error {
            case .malformedRecord:
                return .invalidOrExpired(record: nil, reason: .malformedRecord)
            case .unsafeStorage(_, let reason):
                return .invalidOrExpired(record: nil, reason: .unsafeStorage(reason))
            default:
                return .invalidOrExpired(record: nil, reason: .storageFailure(error.description))
            }
        } catch {
            return .invalidOrExpired(record: nil, reason: .storageFailure(String(describing: error)))
        }
    }

    /// Acquires a missing or stale lease. Repeating the same operation from the
    /// exact same process is idempotent; no caller may overwrite another live
    /// operation. Renewal is a separate lease-ID compare-and-swap operation.
    func acquire(
        kind: ProviderLifecycleLeaseKind,
        operationID: String,
        duration: TimeInterval
    ) throws -> ProviderLifecycleLeaseRecord {
        let durationMilliseconds = try validatedDurationMilliseconds(duration, kind: kind)
        try validateOperationID(operationID)

        return try withExclusiveLock {
            let owner = try currentOwner()
            if let current = try readRecordIfPresent() {
                guard let failure = validationFailure(for: current) else {
                    if current.kind == kind,
                       current.operationID == operationID,
                       current.owner == owner
                    {
                        return current
                    }
                    throw ProviderLifecycleLeaseError.alreadyHeld(current)
                }
                guard failure.permitsReplacement else {
                    throw ProviderLifecycleLeaseError.leaseNotValid(failure)
                }
            }

            let record = try makeRecord(
                leaseID: UUID().uuidString.lowercased(),
                operationID: operationID,
                kind: kind,
                owner: owner,
                durationMilliseconds: durationMilliseconds
            )
            try writeAtomically(record)
            return record
        }
    }

    /// Renews only the caller's currently valid lease. The lease ID is the CAS
    /// token, while the boot/PID/process-start tuple prevents PID-reuse takeover.
    func renew(leaseID: String, duration: TimeInterval) throws -> ProviderLifecycleLeaseRecord {
        return try withExclusiveLock {
            guard let current = try readRecordIfPresent(), current.leaseID == leaseID else {
                throw ProviderLifecycleLeaseError.compareAndSwapFailed
            }
            if let failure = validationFailure(for: current) {
                throw ProviderLifecycleLeaseError.leaseNotValid(failure)
            }
            guard current.owner == (try currentOwner()) else {
                throw ProviderLifecycleLeaseError.compareAndSwapFailed
            }
            let durationMilliseconds = try validatedDurationMilliseconds(duration, kind: current.kind)
            let renewed = try makeRecord(
                leaseID: current.leaseID,
                operationID: current.operationID,
                kind: current.kind,
                owner: current.owner,
                durationMilliseconds: durationMilliseconds,
                startupHandoff: current.startupHandoff
            )
            try validateRecordStructure(renewed)
            try writeAtomically(renewed)
            return renewed
        }
    }

    /// Durably authorizes one exact launchd restart to replace this maintenance
    /// lease with a startup lease. The prepared window remains valid when the
    /// maintenance process exits, but it cannot be consumed by a process that
    /// is not the named launchd service running the exact target executable.
    func prepareStartupHandoff(
        maintenanceLeaseID: String,
        operationID: String,
        providerID: String,
        serviceIdentity: String,
        targetExecutablePath: String,
        targetExecutableSHA256: String,
        handoffDuration: TimeInterval,
        startupLeaseDuration: TimeInterval
    ) throws -> ProviderLifecycleLeaseRecord {
        try validateOperationID(operationID)
        try validateHandoffIdentity(providerID, field: "provider_id")
        try validateHandoffIdentity(serviceIdentity, field: "service_identity")
        try validateTargetExecutablePath(targetExecutablePath)
        let normalizedDigest = try validatedSHA256(targetExecutableSHA256)
        let handoffDurationMilliseconds = try validatedHandoffDurationMilliseconds(handoffDuration)
        let startupDurationMilliseconds = try validatedDurationMilliseconds(
            startupLeaseDuration,
            kind: .startup
        )
        guard environment.executableSHA256(targetExecutablePath) == normalizedDigest else {
            throw ProviderLifecycleLeaseError.targetExecutableMismatch
        }

        return try withExclusiveLock {
            guard let current = try readRecordIfPresent(),
                  current.leaseID == maintenanceLeaseID else {
                throw ProviderLifecycleLeaseError.compareAndSwapFailed
            }
            if let failure = validationFailure(for: current) {
                throw ProviderLifecycleLeaseError.leaseNotValid(failure)
            }
            guard current.kind == .maintenance,
                  current.operationID == operationID,
                  current.owner == (try currentOwner()) else {
                throw ProviderLifecycleLeaseError.compareAndSwapFailed
            }

            if let existing = current.startupHandoff {
                guard existing.state == .prepared,
                      existing.operationID == operationID,
                      existing.providerID == providerID,
                      existing.serviceIdentity == serviceIdentity,
                      existing.targetExecutablePath == targetExecutablePath,
                      existing.targetExecutableSHA256 == normalizedDigest,
                      existing.startupLeaseDurationMilliseconds == startupDurationMilliseconds,
                      existing.expiresWallMilliseconds - existing.issuedWallMilliseconds
                        == handoffDurationMilliseconds else {
                    throw ProviderLifecycleLeaseError.compareAndSwapFailed
                }
                return current
            }

            let wallNow = environment.wallMilliseconds()
            let monotonicNow = environment.monotonicNanoseconds()
            let (wallExpiry, wallOverflow) = wallNow.addingReportingOverflow(handoffDurationMilliseconds)
            let (handoffNanoseconds, durationOverflow) = handoffDurationMilliseconds
                .multipliedReportingOverflow(by: 1_000_000)
            let (monotonicExpiry, monotonicOverflow) = monotonicNow
                .addingReportingOverflow(handoffNanoseconds)
            guard !wallOverflow,
                  !durationOverflow,
                  !monotonicOverflow,
                  wallExpiry <= current.expiresWallMilliseconds,
                  monotonicExpiry <= current.expiresMonotonicNanoseconds else {
                throw ProviderLifecycleLeaseError.invalidHandoffDuration(
                    maximumMilliseconds: ProviderLifecycleStartupHandoff.maximumDurationMilliseconds
                )
            }
            let handoff = ProviderLifecycleStartupHandoff(
                version: ProviderLifecycleStartupHandoff.schemaVersion,
                handoffID: UUID().uuidString.lowercased(),
                state: .prepared,
                operationID: operationID,
                providerID: providerID,
                serviceIdentity: serviceIdentity,
                bootSession: current.owner.bootSession,
                targetExecutablePath: targetExecutablePath,
                targetExecutableSHA256: normalizedDigest,
                issuedWallMilliseconds: wallNow,
                expiresWallMilliseconds: wallExpiry,
                issuedMonotonicNanoseconds: monotonicNow,
                expiresMonotonicNanoseconds: monotonicExpiry,
                startupLeaseDurationMilliseconds: startupDurationMilliseconds
            )
            let prepared = ProviderLifecycleLeaseRecord(
                version: current.version,
                leaseID: current.leaseID,
                operationID: current.operationID,
                kind: current.kind,
                owner: current.owner,
                issuedWallMilliseconds: current.issuedWallMilliseconds,
                expiresWallMilliseconds: current.expiresWallMilliseconds,
                issuedMonotonicNanoseconds: current.issuedMonotonicNanoseconds,
                expiresMonotonicNanoseconds: current.expiresMonotonicNanoseconds,
                startupHandoff: handoff
            )
            try validateRecordStructure(prepared)
            try writeAtomically(prepared)
            return prepared
        }
    }

    /// Atomically consumes a prepared maintenance handoff. A repeated call by
    /// the same adopted process returns the already-written startup lease,
    /// covering response loss without making the handoff replayable.
    func adoptStartupHandoff(
        operationID: String,
        providerID: String,
        serviceIdentity: String
    ) throws -> ProviderLifecycleLeaseRecord {
        try validateOperationID(operationID)
        try validateHandoffIdentity(providerID, field: "provider_id")
        try validateHandoffIdentity(serviceIdentity, field: "service_identity")

        return try withExclusiveLock {
            guard let current = try readRecordIfPresent(),
                  let handoff = current.startupHandoff else {
                throw ProviderLifecycleLeaseError.handoffNotPrepared
            }
            try validateRecordStructure(current)
            try validateHandoffMatch(
                handoff,
                operationID: operationID,
                providerID: providerID,
                serviceIdentity: serviceIdentity
            )
            let adopter = try currentOwner()

            if current.kind == .startup, handoff.state == .adopted {
                if let failure = validationFailure(for: current) {
                    throw ProviderLifecycleLeaseError.leaseNotValid(failure)
                }
                guard current.owner == adopter else {
                    throw ProviderLifecycleLeaseError.compareAndSwapFailed
                }
                try validateAdopter(adopter, handoff: handoff)
                return current
            }

            guard current.kind == .maintenance, handoff.state == .prepared else {
                throw ProviderLifecycleLeaseError.handoffNotPrepared
            }
            try validatePreparedHandoffWindow(record: current, handoff: handoff)
            try validateAdopter(adopter, handoff: handoff)

            let adoptedHandoff = ProviderLifecycleStartupHandoff(
                version: handoff.version,
                handoffID: handoff.handoffID,
                state: .adopted,
                operationID: handoff.operationID,
                providerID: handoff.providerID,
                serviceIdentity: handoff.serviceIdentity,
                bootSession: handoff.bootSession,
                targetExecutablePath: handoff.targetExecutablePath,
                targetExecutableSHA256: handoff.targetExecutableSHA256,
                issuedWallMilliseconds: handoff.issuedWallMilliseconds,
                expiresWallMilliseconds: handoff.expiresWallMilliseconds,
                issuedMonotonicNanoseconds: handoff.issuedMonotonicNanoseconds,
                expiresMonotonicNanoseconds: handoff.expiresMonotonicNanoseconds,
                startupLeaseDurationMilliseconds: handoff.startupLeaseDurationMilliseconds
            )
            let startup = try makeRecord(
                leaseID: UUID().uuidString.lowercased(),
                operationID: operationID,
                kind: .startup,
                owner: adopter,
                durationMilliseconds: handoff.startupLeaseDurationMilliseconds,
                startupHandoff: adoptedHandoff
            )
            try writeAtomically(startup)
            return startup
        }
    }

    /// Rebinds an already-adopted startup handoff after the exact launchd
    /// target restarted before its update transaction committed. The caller
    /// must separately prove that the matching update marker is still armed.
    /// This method only accepts a replaceable stale owner/window and still
    /// requires the current process to be the named launchd service running
    /// the exact executable bytes recorded by the original handoff.
    func recoverAdoptedStartupHandoff(
        operationID: String,
        providerID: String,
        serviceIdentity: String
    ) throws -> ProviderLifecycleLeaseRecord {
        try validateOperationID(operationID)
        try validateHandoffIdentity(providerID, field: "provider_id")
        try validateHandoffIdentity(serviceIdentity, field: "service_identity")

        return try withExclusiveLock {
            guard let current = try readRecordIfPresent(),
                  current.kind == .startup,
                  let handoff = current.startupHandoff,
                  handoff.state == .adopted else {
                throw ProviderLifecycleLeaseError.handoffNotPrepared
            }
            try validateRecordStructure(current)
            try validateHandoffMatch(
                handoff,
                operationID: operationID,
                providerID: providerID,
                serviceIdentity: serviceIdentity
            )
            guard let failure = validationFailure(for: current),
                  failure.permitsReplacement else {
                throw ProviderLifecycleLeaseError.compareAndSwapFailed
            }

            let adopter = try currentOwner()
            guard environment.launchdServiceProcessID(handoff.serviceIdentity) == adopter.pid else {
                throw ProviderLifecycleLeaseError.launchdServiceOwnerMismatch
            }
            guard environment.executablePath(adopter.pid) == handoff.targetExecutablePath,
                  environment.executableSHA256(handoff.targetExecutablePath)
                    == handoff.targetExecutableSHA256 else {
                throw ProviderLifecycleLeaseError.targetExecutableMismatch
            }

            let wallNow = environment.wallMilliseconds()
            let monotonicNow = environment.monotonicNanoseconds()
            let originalHandoffDuration = handoff.expiresWallMilliseconds
                - handoff.issuedWallMilliseconds
            guard wallNow > 0,
                  monotonicNow >= 0,
                  originalHandoffDuration > 0,
                  originalHandoffDuration
                    <= ProviderLifecycleStartupHandoff.maximumDurationMilliseconds else {
                throw ProviderLifecycleLeaseError.handoffExpired
            }
            let (wallExpiry, wallOverflow) = wallNow.addingReportingOverflow(
                originalHandoffDuration
            )
            let (durationNanoseconds, durationOverflow) = originalHandoffDuration
                .multipliedReportingOverflow(by: 1_000_000)
            let (monotonicExpiry, monotonicOverflow) = monotonicNow
                .addingReportingOverflow(durationNanoseconds)
            guard !wallOverflow, !durationOverflow, !monotonicOverflow else {
                throw ProviderLifecycleLeaseError.handoffExpired
            }
            let recoveredHandoff = ProviderLifecycleStartupHandoff(
                version: handoff.version,
                handoffID: handoff.handoffID,
                state: .adopted,
                operationID: handoff.operationID,
                providerID: handoff.providerID,
                serviceIdentity: handoff.serviceIdentity,
                bootSession: adopter.bootSession,
                targetExecutablePath: handoff.targetExecutablePath,
                targetExecutableSHA256: handoff.targetExecutableSHA256,
                issuedWallMilliseconds: wallNow,
                expiresWallMilliseconds: wallExpiry,
                issuedMonotonicNanoseconds: monotonicNow,
                expiresMonotonicNanoseconds: monotonicExpiry,
                startupLeaseDurationMilliseconds: handoff.startupLeaseDurationMilliseconds
            )
            let recovered = try makeRecord(
                leaseID: UUID().uuidString.lowercased(),
                operationID: operationID,
                kind: .startup,
                owner: adopter,
                durationMilliseconds: handoff.startupLeaseDurationMilliseconds,
                startupHandoff: recoveredHandoff
            )
            try validateRecordStructure(recovered)
            try writeAtomically(recovered)
            return recovered
        }
    }

    /// Removes a lease only if the durable lease ID still matches. Expired or
    /// owner-dead leases may be cleared, but a replacement lease cannot be.
    @discardableResult
    func clear(ifLeaseID leaseID: String) throws -> Bool {
        try withExclusiveLock {
            guard let current = try readRecordIfPresent() else { return false }
            guard current.leaseID == leaseID else { return false }
            try validateRecordStructure(current)
            try validateExistingPath(url)
            guard unlink(url.path) == 0 else {
                if errno == ENOENT { return false }
                throw ProviderLifecycleLeaseError.io(path: url.path, operation: "clear", errnoCode: errno)
            }
            try fsyncDirectory()
            return true
        }
    }

    private func currentOwner() throws -> ProviderLifecycleLeaseOwner {
        let pid = environment.processID()
        guard pid > 0,
              let processStart = environment.processStartMicroseconds(pid),
              processStart > 0,
              let bootSession = environment.bootSession()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bootSession.isEmpty,
              bootSession.utf8.count <= 256
        else {
            throw ProviderLifecycleLeaseError.currentOwnerUnavailable
        }
        return ProviderLifecycleLeaseOwner(
            pid: pid,
            processStartMicroseconds: processStart,
            bootSession: bootSession
        )
    }

    private func makeRecord(
        leaseID: String,
        operationID: String,
        kind: ProviderLifecycleLeaseKind,
        owner: ProviderLifecycleLeaseOwner,
        durationMilliseconds: Int64,
        startupHandoff: ProviderLifecycleStartupHandoff? = nil
    ) throws -> ProviderLifecycleLeaseRecord {
        let wallNow = environment.wallMilliseconds()
        let monotonicNow = environment.monotonicNanoseconds()
        guard wallNow > 0, monotonicNow >= 0 else {
            throw ProviderLifecycleLeaseError.currentOwnerUnavailable
        }
        let (wallExpiry, wallOverflow) = wallNow.addingReportingOverflow(durationMilliseconds)
        let (durationNanoseconds, durationOverflow) = durationMilliseconds.multipliedReportingOverflow(by: 1_000_000)
        let (monotonicExpiry, monotonicOverflow) = monotonicNow.addingReportingOverflow(durationNanoseconds)
        guard !wallOverflow, !durationOverflow, !monotonicOverflow else {
            throw ProviderLifecycleLeaseError.invalidDuration(
                kind: kind,
                maximumMilliseconds: kind.maximumDurationMilliseconds
            )
        }
        return ProviderLifecycleLeaseRecord(
            version: ProviderLifecycleLeaseRecord.schemaVersion,
            leaseID: leaseID,
            operationID: operationID,
            kind: kind,
            owner: owner,
            issuedWallMilliseconds: wallNow,
            expiresWallMilliseconds: wallExpiry,
            issuedMonotonicNanoseconds: monotonicNow,
            expiresMonotonicNanoseconds: monotonicExpiry,
            startupHandoff: startupHandoff
        )
    }

    private func validatedDurationMilliseconds(
        _ duration: TimeInterval,
        kind: ProviderLifecycleLeaseKind
    ) throws -> Int64 {
        let milliseconds = duration * 1_000
        guard milliseconds.isFinite,
              milliseconds >= 1,
              milliseconds <= Double(kind.maximumDurationMilliseconds)
        else {
            throw ProviderLifecycleLeaseError.invalidDuration(
                kind: kind,
                maximumMilliseconds: kind.maximumDurationMilliseconds
            )
        }
        let value = Int64(milliseconds.rounded(.down))
        guard value > 0 else {
            throw ProviderLifecycleLeaseError.invalidDuration(
                kind: kind,
                maximumMilliseconds: kind.maximumDurationMilliseconds
            )
        }
        return value
    }

    private func validatedHandoffDurationMilliseconds(_ duration: TimeInterval) throws -> Int64 {
        let milliseconds = duration * 1_000
        guard milliseconds.isFinite,
              milliseconds >= 1,
              milliseconds <= Double(ProviderLifecycleStartupHandoff.maximumDurationMilliseconds) else {
            throw ProviderLifecycleLeaseError.invalidHandoffDuration(
                maximumMilliseconds: ProviderLifecycleStartupHandoff.maximumDurationMilliseconds
            )
        }
        return Int64(milliseconds.rounded(.down))
    }

    private func validateHandoffIdentity(_ value: String, field: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value == trimmed,
              !value.isEmpty,
              value.utf8.count <= 256,
              value.unicodeScalars.allSatisfy({ scalar in
                  scalar.value >= 0x20 && !(0x7f...0x9f).contains(scalar.value)
              }),
              field != "service_identity" || !value.contains("/") else {
            throw ProviderLifecycleLeaseError.invalidHandoffField(field)
        }
    }

    private func validateTargetExecutablePath(_ path: String) throws {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard path.hasPrefix("/"),
              path == standardized,
              !path.utf8.contains(0),
              path.utf8.count <= Int(MAXPATHLEN) * 4 else {
            throw ProviderLifecycleLeaseError.invalidHandoffField("target_executable_path")
        }
    }

    private func validatedSHA256(_ digest: String) throws -> String {
        guard digest.utf8.count == 64,
              digest.unicodeScalars.allSatisfy({ scalar in
                  (0x30...0x39).contains(scalar.value) || (0x61...0x66).contains(scalar.value)
              }) else {
            throw ProviderLifecycleLeaseError.invalidHandoffField("target_executable_sha256")
        }
        return digest
    }

    private func validateHandoffMatch(
        _ handoff: ProviderLifecycleStartupHandoff,
        operationID: String,
        providerID: String,
        serviceIdentity: String
    ) throws {
        guard handoff.operationID == operationID else {
            throw ProviderLifecycleLeaseError.handoffMismatch("operation_id")
        }
        guard handoff.providerID == providerID else {
            throw ProviderLifecycleLeaseError.handoffMismatch("provider_id")
        }
        guard handoff.serviceIdentity == serviceIdentity else {
            throw ProviderLifecycleLeaseError.handoffMismatch("service_identity")
        }
    }

    private func validatePreparedHandoffWindow(
        record: ProviderLifecycleLeaseRecord,
        handoff: ProviderLifecycleStartupHandoff
    ) throws {
        guard environment.bootSession() == handoff.bootSession else {
            throw ProviderLifecycleLeaseError.handoffMismatch("boot_session")
        }
        let wallNow = environment.wallMilliseconds()
        let monotonicNow = environment.monotonicNanoseconds()
        guard wallNow >= record.issuedWallMilliseconds,
              wallNow >= handoff.issuedWallMilliseconds,
              monotonicNow >= record.issuedMonotonicNanoseconds,
              monotonicNow >= handoff.issuedMonotonicNanoseconds else {
            throw ProviderLifecycleLeaseError.handoffMismatch("clock")
        }
        guard wallNow < record.expiresWallMilliseconds,
              wallNow < handoff.expiresWallMilliseconds,
              monotonicNow < record.expiresMonotonicNanoseconds,
              monotonicNow < handoff.expiresMonotonicNanoseconds else {
            throw ProviderLifecycleLeaseError.handoffExpired
        }
    }

    private func validateAdopter(
        _ owner: ProviderLifecycleLeaseOwner,
        handoff: ProviderLifecycleStartupHandoff
    ) throws {
        guard environment.bootSession() == handoff.bootSession else {
            throw ProviderLifecycleLeaseError.handoffMismatch("boot_session")
        }
        guard environment.launchdServiceProcessID(handoff.serviceIdentity) == owner.pid else {
            throw ProviderLifecycleLeaseError.launchdServiceOwnerMismatch
        }
        guard environment.executablePath(owner.pid) == handoff.targetExecutablePath,
              environment.executableSHA256(handoff.targetExecutablePath)
                == handoff.targetExecutableSHA256 else {
            throw ProviderLifecycleLeaseError.targetExecutableMismatch
        }
    }

    private func validateOperationID(_ operationID: String) throws {
        let trimmed = operationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard operationID == trimmed,
              !operationID.isEmpty,
              operationID.utf8.count <= 128,
              operationID.unicodeScalars.allSatisfy({ scalar in
                  scalar.value >= 0x20 && !(0x7f...0x9f).contains(scalar.value)
              })
        else {
            throw ProviderLifecycleLeaseError.invalidOperationID
        }
    }

    private func validationFailure(
        for record: ProviderLifecycleLeaseRecord
    ) -> ProviderLifecycleLeaseInvalidReason? {
        do {
            try validateRecordStructure(record)
        } catch ProviderLifecycleLeaseError.leaseNotValid(let reason) {
            return reason
        } catch {
            return .invalidField("record")
        }

        guard environment.bootSession() == record.owner.bootSession else { return .bootSessionChanged }
        let wallNow = environment.wallMilliseconds()
        let monotonicNow = environment.monotonicNanoseconds()
        guard wallNow >= record.issuedWallMilliseconds else { return .wallClockBeforeIssue }
        guard monotonicNow >= record.issuedMonotonicNanoseconds else { return .monotonicClockBeforeIssue }
        guard wallNow < record.expiresWallMilliseconds else { return .wallExpired }
        guard monotonicNow < record.expiresMonotonicNanoseconds else { return .monotonicExpired }
        if let handoff = record.startupHandoff, handoff.state == .prepared {
            guard wallNow >= handoff.issuedWallMilliseconds else { return .wallClockBeforeIssue }
            guard monotonicNow >= handoff.issuedMonotonicNanoseconds else {
                return .monotonicClockBeforeIssue
            }
            guard wallNow < handoff.expiresWallMilliseconds else { return .wallExpired }
            guard monotonicNow < handoff.expiresMonotonicNanoseconds else { return .monotonicExpired }
            return nil
        }
        guard environment.processStartMicroseconds(record.owner.pid) == record.owner.processStartMicroseconds else {
            return .ownerProcessMissingOrReused
        }
        return nil
    }

    private func validateRecordStructure(_ record: ProviderLifecycleLeaseRecord) throws {
        guard record.version == ProviderLifecycleLeaseRecord.schemaVersion else {
            throw ProviderLifecycleLeaseError.leaseNotValid(.unsupportedVersion)
        }
        guard UUID(uuidString: record.leaseID) != nil else {
            throw ProviderLifecycleLeaseError.leaseNotValid(.invalidField("lease_id"))
        }
        do {
            try validateOperationID(record.operationID)
        } catch {
            throw ProviderLifecycleLeaseError.leaseNotValid(.invalidField("operation_id"))
        }
        guard record.owner.pid > 0,
              record.owner.processStartMicroseconds > 0,
              !record.owner.bootSession.isEmpty,
              record.owner.bootSession.utf8.count <= 256,
              record.issuedWallMilliseconds > 0,
              record.issuedMonotonicNanoseconds >= 0
        else {
            throw ProviderLifecycleLeaseError.leaseNotValid(.invalidField("owner_or_issue_time"))
        }
        let (wallDuration, wallOverflow) = record.expiresWallMilliseconds
            .subtractingReportingOverflow(record.issuedWallMilliseconds)
        let (monotonicDuration, monotonicOverflow) = record.expiresMonotonicNanoseconds
            .subtractingReportingOverflow(record.issuedMonotonicNanoseconds)
        let (expectedNanoseconds, expectedOverflow) = wallDuration.multipliedReportingOverflow(by: 1_000_000)
        guard !wallOverflow,
              !monotonicOverflow,
              !expectedOverflow,
              wallDuration > 0,
              wallDuration <= record.kind.maximumDurationMilliseconds,
              monotonicDuration == expectedNanoseconds
        else {
            throw ProviderLifecycleLeaseError.leaseNotValid(.durationOutOfRange)
        }
        if let handoff = record.startupHandoff {
            do {
                try validateStartupHandoffStructure(handoff, record: record)
            } catch ProviderLifecycleLeaseError.leaseNotValid(let reason) {
                throw ProviderLifecycleLeaseError.leaseNotValid(reason)
            } catch {
                throw ProviderLifecycleLeaseError.leaseNotValid(.invalidField("startup_handoff"))
            }
        }
    }

    private func validateStartupHandoffStructure(
        _ handoff: ProviderLifecycleStartupHandoff,
        record: ProviderLifecycleLeaseRecord
    ) throws {
        guard handoff.version == ProviderLifecycleStartupHandoff.schemaVersion,
              UUID(uuidString: handoff.handoffID) != nil,
              handoff.operationID == record.operationID,
              handoff.bootSession == record.owner.bootSession else {
            throw ProviderLifecycleLeaseError.leaseNotValid(.invalidField("startup_handoff_identity"))
        }
        try validateOperationID(handoff.operationID)
        try validateHandoffIdentity(handoff.providerID, field: "provider_id")
        try validateHandoffIdentity(handoff.serviceIdentity, field: "service_identity")
        try validateTargetExecutablePath(handoff.targetExecutablePath)
        _ = try validatedSHA256(handoff.targetExecutableSHA256)
        let (wallDuration, wallOverflow) = handoff.expiresWallMilliseconds
            .subtractingReportingOverflow(handoff.issuedWallMilliseconds)
        let (monotonicDuration, monotonicOverflow) = handoff.expiresMonotonicNanoseconds
            .subtractingReportingOverflow(handoff.issuedMonotonicNanoseconds)
        let (expectedNanoseconds, expectedOverflow) = wallDuration
            .multipliedReportingOverflow(by: 1_000_000)
        guard handoff.issuedWallMilliseconds > 0,
              handoff.issuedMonotonicNanoseconds >= 0,
              !wallOverflow,
              !monotonicOverflow,
              !expectedOverflow,
              wallDuration > 0,
              wallDuration <= ProviderLifecycleStartupHandoff.maximumDurationMilliseconds,
              monotonicDuration == expectedNanoseconds,
              handoff.startupLeaseDurationMilliseconds > 0,
              handoff.startupLeaseDurationMilliseconds
                <= ProviderLifecycleLeaseKind.startup.maximumDurationMilliseconds else {
            throw ProviderLifecycleLeaseError.leaseNotValid(.invalidField("startup_handoff_window"))
        }
        switch handoff.state {
        case .prepared:
            guard record.kind == .maintenance,
                  handoff.expiresWallMilliseconds <= record.expiresWallMilliseconds,
                  handoff.expiresMonotonicNanoseconds <= record.expiresMonotonicNanoseconds else {
                throw ProviderLifecycleLeaseError.leaseNotValid(.invalidField("startup_handoff_state"))
            }
        case .adopted:
            guard record.kind == .startup else {
                throw ProviderLifecycleLeaseError.leaseNotValid(.invalidField("startup_handoff_state"))
            }
        }
    }

    private func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        try ensureTrustedDirectory()
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            if errno == ELOOP {
                throw ProviderLifecycleLeaseError.unsafeStorage(path: lockURL.path, reason: "symlink")
            }
            throw ProviderLifecycleLeaseError.io(path: lockURL.path, operation: "open lock", errnoCode: errno)
        }
        defer { close(fd) }
        try validateOpenFile(fd: fd, path: lockURL.path, allowEmpty: true)
        try validatePath(lockURL, matchesOpenFile: fd)

        var result: Int32
        repeat {
            result = flock(fd, LOCK_EX)
        } while result != 0 && errno == EINTR
        guard result == 0 else {
            throw ProviderLifecycleLeaseError.io(path: lockURL.path, operation: "lock", errnoCode: errno)
        }
        defer { _ = flock(fd, LOCK_UN) }
        try validatePath(lockURL, matchesOpenFile: fd)
        return try body()
    }

    private func ensureTrustedDirectory() throws {
        _ = try validateTrustedDirectory(createIfMissing: true)
    }

    @discardableResult
    private func validateTrustedDirectory(createIfMissing: Bool) throws -> Bool {
        let directory = url.deletingLastPathComponent()
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            guard errno == ENOENT else {
                throw ProviderLifecycleLeaseError.io(path: directory.path, operation: "inspect directory", errnoCode: errno)
            }
            guard createIfMissing else { return false }
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw ProviderLifecycleLeaseError.unsafeStorage(
                    path: directory.path,
                    reason: "create failed: \(error.localizedDescription)"
                )
            }
            guard lstat(directory.path, &info) == 0 else {
                throw ProviderLifecycleLeaseError.io(path: directory.path, operation: "inspect directory", errnoCode: errno)
            }
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            throw ProviderLifecycleLeaseError.unsafeStorage(path: directory.path, reason: "not a directory")
        }
        guard info.st_uid == expectedOwnerUID else {
            throw ProviderLifecycleLeaseError.unsafeStorage(path: directory.path, reason: "wrong owner")
        }
        guard (info.st_mode & 0o777) == S_IRWXU else {
            throw ProviderLifecycleLeaseError.unsafeStorage(path: directory.path, reason: "mode is not 0700")
        }
        let fd = open(directory.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            throw ProviderLifecycleLeaseError.io(path: directory.path, operation: "open directory", errnoCode: errno)
        }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0 else {
            throw ProviderLifecycleLeaseError.io(path: directory.path, operation: "stat directory", errnoCode: errno)
        }
        guard opened.st_dev == info.st_dev, opened.st_ino == info.st_ino else {
            throw ProviderLifecycleLeaseError.unsafeStorage(path: directory.path, reason: "directory changed")
        }
        try rejectExtendedACL(fd: fd, path: directory.path)
        return true
    }

    private func readRecordIfPresent() throws -> ProviderLifecycleLeaseRecord? {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            if errno == ELOOP {
                throw ProviderLifecycleLeaseError.unsafeStorage(path: url.path, reason: "symlink")
            }
            throw ProviderLifecycleLeaseError.io(path: url.path, operation: "open", errnoCode: errno)
        }
        defer { close(fd) }
        let size = try validateOpenFile(fd: fd, path: url.path, allowEmpty: false)
        var data = Data()
        data.reserveCapacity(Int(size))
        var buffer = [UInt8](repeating: 0, count: 4 * 1_024)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw ProviderLifecycleLeaseError.io(path: url.path, operation: "read", errnoCode: errno)
            }
            if count == 0 { break }
            guard data.count + count <= Self.maximumRecordBytes else {
                throw ProviderLifecycleLeaseError.unsafeStorage(path: url.path, reason: "record too large")
            }
            data.append(buffer, count: count)
        }
        guard let record = try? JSONDecoder().decode(ProviderLifecycleLeaseRecord.self, from: data) else {
            throw ProviderLifecycleLeaseError.malformedRecord(path: url.path)
        }
        return record
    }

    @discardableResult
    private func validateOpenFile(fd: Int32, path: String, allowEmpty: Bool) throws -> Int64 {
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw ProviderLifecycleLeaseError.io(path: path, operation: "stat", errnoCode: errno)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw ProviderLifecycleLeaseError.unsafeStorage(path: path, reason: "not a regular file")
        }
        guard info.st_uid == expectedOwnerUID else {
            throw ProviderLifecycleLeaseError.unsafeStorage(path: path, reason: "wrong owner")
        }
        guard info.st_nlink == 1 else {
            throw ProviderLifecycleLeaseError.unsafeStorage(path: path, reason: "hard link")
        }
        guard (info.st_mode & 0o777) == (S_IRUSR | S_IWUSR) else {
            throw ProviderLifecycleLeaseError.unsafeStorage(path: path, reason: "mode is not 0600")
        }
        try rejectExtendedACL(fd: fd, path: path)
        guard info.st_size >= (allowEmpty ? 0 : 1), info.st_size <= Self.maximumRecordBytes else {
            throw ProviderLifecycleLeaseError.unsafeStorage(path: path, reason: "invalid size")
        }
        return info.st_size
    }

    private func validateExistingPath(_ existingURL: URL) throws {
        var info = stat()
        guard lstat(existingURL.path, &info) == 0 else {
            if errno == ENOENT { return }
            throw ProviderLifecycleLeaseError.io(path: existingURL.path, operation: "inspect", errnoCode: errno)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw ProviderLifecycleLeaseError.unsafeStorage(path: existingURL.path, reason: "symlink or non-regular file")
        }
        guard info.st_uid == expectedOwnerUID else {
            throw ProviderLifecycleLeaseError.unsafeStorage(path: existingURL.path, reason: "wrong owner")
        }
        guard info.st_nlink == 1 else {
            throw ProviderLifecycleLeaseError.unsafeStorage(path: existingURL.path, reason: "hard link")
        }
        guard (info.st_mode & 0o777) == (S_IRUSR | S_IWUSR) else {
            throw ProviderLifecycleLeaseError.unsafeStorage(path: existingURL.path, reason: "mode is not 0600")
        }
        let fd = open(existingURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            throw ProviderLifecycleLeaseError.io(path: existingURL.path, operation: "open for validation", errnoCode: errno)
        }
        defer { close(fd) }
        try validateOpenFile(fd: fd, path: existingURL.path, allowEmpty: false)
        try validatePath(existingURL, matchesOpenFile: fd)
    }

    private func writeAtomically(_ record: ProviderLifecycleLeaseRecord) throws {
        try validateExistingPath(url)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        guard data.count <= Self.maximumRecordBytes else {
            throw ProviderLifecycleLeaseError.unsafeStorage(path: url.path, reason: "record too large")
        }

        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString.lowercased())")
        let fd = open(
            temporaryURL.path,
            O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard fd >= 0 else {
            throw ProviderLifecycleLeaseError.io(path: temporaryURL.path, operation: "create temporary", errnoCode: errno)
        }
        var shouldRemoveTemporary = true
        defer {
            close(fd)
            if shouldRemoveTemporary { _ = unlink(temporaryURL.path) }
        }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw ProviderLifecycleLeaseError.io(
                        path: temporaryURL.path,
                        operation: "write temporary",
                        errnoCode: errno
                    )
                }
                offset += count
            }
        }
        guard fchmod(fd, S_IRUSR | S_IWUSR) == 0 else {
            throw ProviderLifecycleLeaseError.io(path: temporaryURL.path, operation: "chmod temporary", errnoCode: errno)
        }
        _ = try validateOpenFile(fd: fd, path: temporaryURL.path, allowEmpty: false)
        guard fsync(fd) == 0 else {
            throw ProviderLifecycleLeaseError.io(path: temporaryURL.path, operation: "sync temporary", errnoCode: errno)
        }
        try validateExistingPath(url)
        guard rename(temporaryURL.path, url.path) == 0 else {
            throw ProviderLifecycleLeaseError.io(path: url.path, operation: "rename temporary", errnoCode: errno)
        }
        shouldRemoveTemporary = false
        try validatePath(url, matchesOpenFile: fd)
        try fsyncDirectory()
    }

    private func fsyncDirectory() throws {
        let directory = url.deletingLastPathComponent()
        let fd = open(directory.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            throw ProviderLifecycleLeaseError.io(path: directory.path, operation: "open directory", errnoCode: errno)
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == expectedOwnerUID,
              (info.st_mode & 0o777) == S_IRWXU
        else {
            throw ProviderLifecycleLeaseError.unsafeStorage(path: directory.path, reason: "directory changed")
        }
        try rejectExtendedACL(fd: fd, path: directory.path)
        guard fsync(fd) == 0 else {
            throw ProviderLifecycleLeaseError.io(path: directory.path, operation: "sync directory", errnoCode: errno)
        }
    }

    private func validatePath(_ path: URL, matchesOpenFile fd: Int32) throws {
        var opened = stat()
        guard fstat(fd, &opened) == 0 else {
            throw ProviderLifecycleLeaseError.io(path: path.path, operation: "stat", errnoCode: errno)
        }
        var named = stat()
        guard lstat(path.path, &named) == 0 else {
            throw ProviderLifecycleLeaseError.io(path: path.path, operation: "inspect", errnoCode: errno)
        }
        guard (named.st_mode & S_IFMT) == S_IFREG,
              named.st_dev == opened.st_dev,
              named.st_ino == opened.st_ino
        else {
            throw ProviderLifecycleLeaseError.unsafeStorage(path: path.path, reason: "path changed")
        }
    }

    private func rejectExtendedACL(fd: Int32, path: String) throws {
        errno = 0
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
            if errno == 0 || errno == ENOENT { return }
            throw ProviderLifecycleLeaseError.io(path: path, operation: "inspect ACL", errnoCode: errno)
        }
        defer { _ = acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        let result = acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry)
        guard result == 0 else {
            throw ProviderLifecycleLeaseError.io(path: path, operation: "inspect ACL", errnoCode: errno)
        }
        guard entry == nil else {
            throw ProviderLifecycleLeaseError.unsafeStorage(path: path, reason: "extended ACL")
        }
    }
}

private extension ProviderLifecycleLeaseInvalidReason {
    var permitsReplacement: Bool {
        switch self {
        case .wallExpired, .monotonicExpired, .bootSessionChanged, .ownerProcessMissingOrReused:
            return true
        case .malformedRecord,
             .unsupportedVersion,
             .invalidField,
             .durationOutOfRange,
             .wallClockBeforeIssue,
             .monotonicClockBeforeIssue,
             .unsafeStorage,
             .storageFailure:
            return false
        }
    }
}
