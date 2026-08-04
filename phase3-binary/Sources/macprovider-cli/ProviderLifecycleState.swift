import ArgumentParser
import Darwin
import Foundation

enum ProviderLifecycleState: String, Codable, CaseIterable, Sendable, ExpressibleByArgument {
    case installing
    case importingCredentials = "importing_credentials"
    case startingProvider = "starting_provider"
    case validatingCatalog = "validating_catalog"
    case loadingModel = "loading_model"
    case locallyReadyConnecting = "locally_ready_connecting"
    case authenticationRequired = "authentication_required"
    case keychainUnavailable = "keychain_unavailable"
    case identityMigrationRequired = "identity_migration_required"
    case catalogIncompatible = "catalog_incompatible"
    case servingBuyers = "serving_buyers"
    case updateInProgress = "update_in_progress"
    case rollbackInProgress = "rollback_in_progress"
    case pausedByOperator = "paused_by_operator"
    case watchdogRecovery = "watchdog_recovery"
    case networkOffline = "network_offline"
    case coordinatorUnavailable = "coordinator_unavailable"
    case degradedServing = "degraded_serving"
    case failed
    case uninstalled
}

enum ProviderLifecycleWriter: String, Codable, CaseIterable, Sendable, ExpressibleByArgument {
    case serve
    case installer
    case updater
    case watchdog
    case credentials
    case operatorCommand = "operator_command"
}

struct ProviderLifecycleStateRecord: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    static let authority = "macprovider_cli"

    let version: Int
    let sequence: UInt64
    let transitionID: String
    let previousTransitionID: String?
    let transitionAt: String
    let state: ProviderLifecycleState
    let reasonCode: String
    let authority: String
    let writer: ProviderLifecycleWriter
    let providerID: String?
    let modelID: String?
    let compatibilitySetID: String?
    let operationID: String?
    /// Durable operator intent carried across every transitional state. Older
    /// records decode as nil/false, so adding the field is backward-compatible.
    let operatorPaused: Bool?
    /// Bounded, durable summaries keep the last operator-relevant reasons
    /// visible after the current state advances back to serving. They contain
    /// no secrets and older records decode them as nil.
    let lastRestart: SignificantEvent?
    let lastRejection: SignificantEvent?
    let lastUpdate: SignificantEvent?
    let lastWatchdog: SignificantEvent?

    struct SignificantEvent: Codable, Equatable, Sendable {
        let sequence: UInt64
        let transitionID: String
        let transitionAt: String
        let state: ProviderLifecycleState
        let reasonCode: String
        let writer: ProviderLifecycleWriter
        let compatibilitySetID: String?
        let operationID: String?

        enum CodingKeys: String, CodingKey {
            case sequence
            case transitionID = "transition_id"
            case transitionAt = "transition_at"
            case state
            case reasonCode = "reason_code"
            case writer
            case compatibilitySetID = "compatibility_set_id"
            case operationID = "operation_id"
        }
    }

    enum CodingKeys: String, CodingKey {
        case version
        case sequence
        case transitionID = "transition_id"
        case previousTransitionID = "previous_transition_id"
        case transitionAt = "transition_at"
        case state
        case reasonCode = "reason_code"
        case authority
        case writer
        case providerID = "provider_id"
        case modelID = "model_id"
        case compatibilitySetID = "compatibility_set_id"
        case operationID = "operation_id"
        case operatorPaused = "operator_paused"
        case lastRestart = "last_restart"
        case lastRejection = "last_rejection"
        case lastUpdate = "last_update"
        case lastWatchdog = "last_watchdog"
    }

    var operatorPauseRequested: Bool { operatorPaused == true }

    var transitionDate: Date? {
        ProviderLifecycleStateRecord.iso8601Formatter(fractionalSeconds: true).date(from: transitionAt)
            ?? ProviderLifecycleStateRecord.iso8601Formatter(fractionalSeconds: false).date(from: transitionAt)
    }

    func hasSameTransition(
        state: ProviderLifecycleState,
        reasonCode: String,
        writer: ProviderLifecycleWriter,
        providerID: String?,
        modelID: String?,
        compatibilitySetID: String?,
        operationID: String?,
        operatorPaused: Bool
    ) -> Bool {
        self.state == state
            && self.reasonCode == reasonCode
            && self.writer == writer
            && self.providerID == providerID
            && self.modelID == modelID
            && self.compatibilitySetID == compatibilitySetID
            && self.operationID == operationID
            && operatorPauseRequested == operatorPaused
    }

    func validate() throws {
        guard version == Self.schemaVersion else {
            throw ProviderLifecycleStateError.invalidRecord("unsupported_version")
        }
        guard sequence > 0 else {
            throw ProviderLifecycleStateError.invalidRecord("invalid_sequence")
        }
        guard Self.isLowercaseUUID(transitionID) else {
            throw ProviderLifecycleStateError.invalidRecord("invalid_transition_id")
        }
        if let previousTransitionID, !Self.isLowercaseUUID(previousTransitionID) {
            throw ProviderLifecycleStateError.invalidRecord("invalid_previous_transition_id")
        }
        guard transitionDate != nil else {
            throw ProviderLifecycleStateError.invalidRecord("invalid_transition_at")
        }
        guard authority == Self.authority else {
            throw ProviderLifecycleStateError.invalidRecord("invalid_authority")
        }
        try Self.validateReasonCode(reasonCode)
        try Self.validateContext(providerID, name: "provider_id", maximum: 256)
        try Self.validateContext(modelID, name: "model_id", maximum: 512)
        try Self.validateContext(compatibilitySetID, name: "compatibility_set_id", maximum: 256)
        try Self.validateContext(operationID, name: "operation_id", maximum: 256)
        try validateSignificantEvent(lastRestart)
        try validateSignificantEvent(lastRejection)
        try validateSignificantEvent(lastUpdate)
        try validateSignificantEvent(lastWatchdog)
    }

    static func make(
        previous: ProviderLifecycleStateRecord?,
        state: ProviderLifecycleState,
        reasonCode: String,
        writer: ProviderLifecycleWriter,
        providerID: String?,
        modelID: String?,
        compatibilitySetID: String?,
        operationID: String?,
        operatorPaused: Bool = false,
        now: Date
    ) throws -> ProviderLifecycleStateRecord {
        try validateTransition(previous: previous, state: state, writer: writer, operationID: operationID)
        try validateReasonCode(reasonCode)
        try validateContext(providerID, name: "provider_id", maximum: 256)
        try validateContext(modelID, name: "model_id", maximum: 512)
        try validateContext(compatibilitySetID, name: "compatibility_set_id", maximum: 256)
        try validateContext(operationID, name: "operation_id", maximum: 256)
        guard previous?.sequence != UInt64.max else {
            throw ProviderLifecycleStateError.sequenceExhausted
        }
        let sequence = (previous?.sequence ?? 0) + 1
        let transitionID = UUID().uuidString.lowercased()
        let transitionAt = iso8601Formatter(fractionalSeconds: true).string(from: now)
        let event = SignificantEvent(
            sequence: sequence,
            transitionID: transitionID,
            transitionAt: transitionAt,
            state: state,
            reasonCode: reasonCode,
            writer: writer,
            compatibilitySetID: normalized(compatibilitySetID),
            operationID: normalized(operationID)
        )
        return ProviderLifecycleStateRecord(
            version: schemaVersion,
            sequence: sequence,
            transitionID: transitionID,
            previousTransitionID: previous?.transitionID,
            transitionAt: transitionAt,
            state: state,
            reasonCode: reasonCode,
            authority: authority,
            writer: writer,
            providerID: normalized(providerID),
            modelID: normalized(modelID),
            compatibilitySetID: normalized(compatibilitySetID),
            operationID: normalized(operationID),
            operatorPaused: operatorPaused,
            lastRestart: state == .startingProvider ? event : previous?.lastRestart,
            lastRejection: rejectionStates.contains(state) ? event : previous?.lastRejection,
            lastUpdate: writer == .updater || updateStates.contains(state) ? event : previous?.lastUpdate,
            lastWatchdog: writer == .watchdog ? event : previous?.lastWatchdog
        )
    }

    private static let rejectionStates: [ProviderLifecycleState] = [
        .authenticationRequired,
        .identityMigrationRequired,
        .catalogIncompatible,
        .failed,
    ]

    private static let updateStates: [ProviderLifecycleState] = [
        .updateInProgress,
        .rollbackInProgress,
    ]

    private static func validateTransition(
        previous: ProviderLifecycleStateRecord?,
        state: ProviderLifecycleState,
        writer: ProviderLifecycleWriter,
        operationID: String?
    ) throws {
        let authorized: Bool = switch writer {
        case .serve:
            [
                .startingProvider, .importingCredentials, .validatingCatalog, .loadingModel,
                .locallyReadyConnecting, .authenticationRequired, .keychainUnavailable,
                .identityMigrationRequired, .catalogIncompatible, .servingBuyers,
                .networkOffline, .coordinatorUnavailable, .degradedServing, .failed,
            ].contains(state)
        case .installer:
            [.installing, .rollbackInProgress, .pausedByOperator, .uninstalled].contains(state)
        case .updater:
            [.updateInProgress, .rollbackInProgress, .servingBuyers].contains(state)
        case .watchdog:
            state == .watchdogRecovery
        case .credentials:
            [.authenticationRequired, .keychainUnavailable, .identityMigrationRequired, .failed].contains(state)
        case .operatorCommand:
            [.pausedByOperator, .locallyReadyConnecting, .degradedServing, .servingBuyers].contains(state)
        }
        guard authorized else {
            throw ProviderLifecycleStateError.writerNotAuthorized(writer: writer.rawValue, state: state.rawValue)
        }

        guard let previous else { return }
        if previous.state == .uninstalled {
            guard writer == .installer, state == .installing else {
                throw ProviderLifecycleStateError.invalidTransition(from: previous.state.rawValue, to: state.rawValue)
            }
        }

        // Maintenance writers fence an already-running serve operation. A
        // stale provider process cannot overwrite update/install/watchdog
        // state; only the replacement launchd process may begin a new startup
        // chain. Update handoff additionally carries one exact operation ID.
        if writer == .serve {
            switch previous.writer {
            case .updater where previous.state == .updateInProgress || previous.state == .rollbackInProgress:
                guard state == .startingProvider,
                      normalized(operationID) == previous.operationID else {
                    throw ProviderLifecycleStateError.operationFenced(
                        previousWriter: previous.writer.rawValue,
                        previousState: previous.state.rawValue
                    )
                }
            case .installer where previous.state == .installing || previous.state == .rollbackInProgress,
                 .watchdog:
                guard state == .startingProvider else {
                    throw ProviderLifecycleStateError.operationFenced(
                        previousWriter: previous.writer.rawValue,
                        previousState: previous.state.rawValue
                    )
                }
            default:
                break
            }
        }

        let allowedPredecessors: [ProviderLifecycleState]? = switch state {
        case .importingCredentials:
            [.startingProvider]
        case .validatingCatalog:
            [.importingCredentials, .authenticationRequired, .keychainUnavailable, .identityMigrationRequired]
        case .loadingModel:
            [.validatingCatalog]
        case .degradedServing:
            [.loadingModel, .pausedByOperator, .locallyReadyConnecting, .servingBuyers, .degradedServing]
        case .pausedByOperator:
            [.installing, .loadingModel, .locallyReadyConnecting, .servingBuyers, .degradedServing, .pausedByOperator]
        case .servingBuyers:
            [
                .locallyReadyConnecting, .networkOffline, .coordinatorUnavailable,
                .degradedServing, .pausedByOperator, .servingBuyers, .updateInProgress,
            ]
        case .authenticationRequired, .identityMigrationRequired:
            [
                .loadingModel, .locallyReadyConnecting, .networkOffline, .coordinatorUnavailable,
                .authenticationRequired, .identityMigrationRequired, .catalogIncompatible,
                .servingBuyers, .degradedServing, .pausedByOperator, .importingCredentials,
            ]
        case .locallyReadyConnecting, .networkOffline, .coordinatorUnavailable, .catalogIncompatible:
            [
                .loadingModel, .locallyReadyConnecting, .networkOffline, .coordinatorUnavailable,
                .authenticationRequired, .identityMigrationRequired, .catalogIncompatible,
                .servingBuyers, .degradedServing, .pausedByOperator,
            ]
        case .startingProvider, .installing, .updateInProgress, .rollbackInProgress, .watchdogRecovery,
             .keychainUnavailable, .failed, .uninstalled:
            nil
        }
        if let allowedPredecessors, !allowedPredecessors.contains(previous.state) {
            throw ProviderLifecycleStateError.invalidTransition(from: previous.state.rawValue, to: state.rawValue)
        }

        // Decision Entry 158 pins the writer for the two `loading_model` exits
        // introduced by v1.8.40. The predecessor list and writer authorization
        // are evaluated independently above, so a writer that is separately
        // allowed to enter the target state (operator_command → degraded_serving,
        // installer → paused_by_operator) would otherwise ride the new
        // predecessor edge. Validate (predecessor, target, writer) as a tuple so
        // ONLY the Entry-158 combinations remain legal for these two edges.
        if previous.state == .loadingModel {
            switch state {
            case .degradedServing where writer != .serve:
                throw ProviderLifecycleStateError.invalidTransition(from: previous.state.rawValue, to: state.rawValue)
            case .pausedByOperator where writer != .operatorCommand:
                throw ProviderLifecycleStateError.invalidTransition(from: previous.state.rawValue, to: state.rawValue)
            default:
                break
            }
        }
    }

    private func validateSignificantEvent(_ event: SignificantEvent?) throws {
        guard let event else { return }
        guard event.sequence > 0, event.sequence <= sequence else {
            throw ProviderLifecycleStateError.invalidRecord("invalid_significant_event_sequence")
        }
        guard Self.isLowercaseUUID(event.transitionID) else {
            throw ProviderLifecycleStateError.invalidRecord("invalid_significant_event_transition_id")
        }
        guard Self.iso8601Formatter(fractionalSeconds: true).date(from: event.transitionAt) != nil
                || Self.iso8601Formatter(fractionalSeconds: false).date(from: event.transitionAt) != nil else {
            throw ProviderLifecycleStateError.invalidRecord("invalid_significant_event_transition_at")
        }
        try Self.validateReasonCode(event.reasonCode)
        try Self.validateContext(event.compatibilitySetID, name: "significant_event_compatibility_set_id", maximum: 256)
        try Self.validateContext(event.operationID, name: "significant_event_operation_id", maximum: 256)
    }

    private static func iso8601Formatter(fractionalSeconds: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractionalSeconds
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func validateReasonCode(_ value: String) throws {
        guard !value.isEmpty, value.count <= 128,
              value.unicodeScalars.allSatisfy({ scalar in
                  ("a"..."z").contains(Character(String(scalar)))
                      || ("0"..."9").contains(Character(String(scalar)))
                      || scalar == "_" || scalar == "-" || scalar == "." || scalar == ":"
              }) else {
            throw ProviderLifecycleStateError.invalidRecord("invalid_reason_code")
        }
    }

    private static func validateContext(_ value: String?, name: String, maximum: Int) throws {
        guard let value else { return }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximum,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ProviderLifecycleStateError.invalidRecord("invalid_\(name)")
        }
    }

    private static func isLowercaseUUID(_ value: String) -> Bool {
        UUID(uuidString: value) != nil && value == value.lowercased()
    }
}

enum ProviderLifecycleStateInspection: Equatable, Sendable {
    case missing
    case valid(ProviderLifecycleStateRecord)
    case invalid(reason: String)
}

enum ProviderLifecycleStateError: Error, Equatable, LocalizedError {
    case invalidRecord(String)
    case unsafeStorage(path: String, reason: String)
    case malformedRecord(path: String)
    case io(path: String, operation: String, errnoCode: Int32)
    case sequenceExhausted
    case writerNotAuthorized(writer: String, state: String)
    case invalidTransition(from: String, to: String)
    case operationFenced(previousWriter: String, previousState: String)

    var errorDescription: String? {
        switch self {
        case .invalidRecord(let reason):
            return "invalid lifecycle state record: \(reason)"
        case .unsafeStorage(let path, let reason):
            return "unsafe lifecycle state storage at \(path): \(reason)"
        case .malformedRecord(let path):
            return "malformed lifecycle state record at \(path)"
        case .io(let path, let operation, let errnoCode):
            return "lifecycle state \(operation) failed at \(path): \(String(cString: strerror(errnoCode)))"
        case .sequenceExhausted:
            return "lifecycle state sequence is exhausted"
        case .writerNotAuthorized(let writer, let state):
            return "lifecycle writer \(writer) is not authorized to enter \(state)"
        case .invalidTransition(let from, let to):
            return "invalid lifecycle transition from \(from) to \(to)"
        case .operationFenced(let previousWriter, let previousState):
            return "lifecycle transition is fenced by \(previousWriter) state \(previousState)"
        }
    }
}

/// The only persisted lifecycle-transition authority. Other components invoke
/// the signed CLI command; they never author lifecycle JSON themselves.
struct ProviderLifecycleStateStore: @unchecked Sendable {
    private static let maximumRecordBytes = 64 * 1_024

    let url: URL
    private let lockURL: URL
    private let expectedOwnerUID: uid_t

    init(
        url: URL = ProviderLifecycleStateStore.defaultURL(),
        expectedOwnerUID: uid_t = geteuid()
    ) {
        self.url = url
        self.lockURL = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).lock")
        self.expectedOwnerUID = expectedOwnerUID
    }

    static func defaultURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/macprovider/lifecycle", isDirectory: true)
            .appendingPathComponent("state-v1.json")
    }

    /// Compatibility helper for callers that need a deterministic candidate path.
    /// The live `serve --no-join --autotune-candidate` path supplies a fresh,
    /// owner-only isolation root instead, so its lifecycle state, lock, lease,
    /// and control paths cannot collide with the installed incumbent.
    static func candidateURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/macprovider/lifecycle", isDirectory: true)
            .appendingPathComponent("candidate-state-v1.json")
    }

    static func candidateURL(rootDirectory: URL) -> URL {
        rootDirectory
            .appendingPathComponent("lifecycle", isDirectory: true)
            .appendingPathComponent("state-v1.json")
    }

    func inspect() -> ProviderLifecycleStateInspection {
        do {
            guard let record = try withExclusiveLock({ try readRecordIfPresent() }) else {
                return .missing
            }
            return .valid(record)
        } catch let error as ProviderLifecycleStateError {
            return .invalid(reason: error.localizedDescription)
        } catch {
            return .invalid(reason: String(describing: error))
        }
    }

    func current() throws -> ProviderLifecycleStateRecord? {
        try withExclusiveLock { try readRecordIfPresent() }
    }

    @discardableResult
    func transition(
        to state: ProviderLifecycleState,
        reasonCode: String,
        writer: ProviderLifecycleWriter,
        providerID: String? = nil,
        modelID: String? = nil,
        compatibilitySetID: String? = nil,
        operationID: String? = nil,
        operatorPaused: Bool? = nil,
        now: Date = Date()
    ) throws -> ProviderLifecycleStateRecord {
        try withExclusiveLock {
            let previous = try readRecordIfPresent()
            let normalizedProviderID = normalized(providerID)
            let normalizedModelID = normalized(modelID)
            let normalizedCompatibilitySetID = normalized(compatibilitySetID)
            let normalizedOperationID = normalized(operationID)
            let resolvedOperatorPaused = operatorPaused ?? previous?.operatorPauseRequested ?? false
            if let previous, previous.hasSameTransition(
                state: state,
                reasonCode: reasonCode,
                writer: writer,
                providerID: normalizedProviderID,
                modelID: normalizedModelID,
                compatibilitySetID: normalizedCompatibilitySetID,
                operationID: normalizedOperationID,
                operatorPaused: resolvedOperatorPaused
            ) {
                return previous
            }
            let record = try ProviderLifecycleStateRecord.make(
                previous: previous,
                state: state,
                reasonCode: reasonCode,
                writer: writer,
                providerID: normalizedProviderID,
                modelID: normalizedModelID,
                compatibilitySetID: normalizedCompatibilitySetID,
                operationID: normalizedOperationID,
                operatorPaused: resolvedOperatorPaused,
                now: now
            )
            try writeAtomically(record)
            return record
        }
    }

    private func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        try ensureTrustedDirectory()
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw storageOpenError(path: lockURL.path, operation: "open lock")
        }
        defer { close(fd) }
        try validateOpenFile(fd: fd, path: lockURL.path, allowEmpty: true)
        try validatePath(lockURL, matchesOpenFile: fd)
        var result: Int32
        repeat {
            result = flock(fd, LOCK_EX)
        } while result != 0 && errno == EINTR
        guard result == 0 else {
            throw ProviderLifecycleStateError.io(path: lockURL.path, operation: "lock", errnoCode: errno)
        }
        defer { _ = flock(fd, LOCK_UN) }
        try validatePath(lockURL, matchesOpenFile: fd)
        return try body()
    }

    private func ensureTrustedDirectory() throws {
        let directory = url.deletingLastPathComponent()
        var info = stat()
        var createdDirectory = false
        if lstat(directory.path, &info) != 0 {
            guard errno == ENOENT else {
                throw ProviderLifecycleStateError.io(path: directory.path, operation: "inspect directory", errnoCode: errno)
            }
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                createdDirectory = true
            } catch {
                throw ProviderLifecycleStateError.unsafeStorage(
                    path: directory.path,
                    reason: "create failed: \(error.localizedDescription)"
                )
            }
            guard lstat(directory.path, &info) == 0 else {
                throw ProviderLifecycleStateError.io(path: directory.path, operation: "inspect directory", errnoCode: errno)
            }
        }
        if createdDirectory {
            guard chmod(directory.path, S_IRWXU) == 0,
                  lstat(directory.path, &info) == 0 else {
                throw ProviderLifecycleStateError.io(
                    path: directory.path,
                    operation: "secure directory",
                    errnoCode: errno
                )
            }
        } else if (info.st_mode & 0o777) != S_IRWXU,
                  (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == expectedOwnerUID {
            // Another process may have observed the directory between mkdir
            // and the creating process's chmod. Wait only for that bounded
            // creation window; never normalize a pre-existing broad directory.
            for _ in 0 ..< 10 {
                usleep(10_000)
                guard lstat(directory.path, &info) == 0 else { break }
                if (info.st_mode & 0o777) == S_IRWXU { break }
            }
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            throw ProviderLifecycleStateError.unsafeStorage(path: directory.path, reason: "not a directory")
        }
        guard info.st_uid == expectedOwnerUID else {
            throw ProviderLifecycleStateError.unsafeStorage(path: directory.path, reason: "wrong owner")
        }
        guard (info.st_mode & 0o777) == S_IRWXU else {
            throw ProviderLifecycleStateError.unsafeStorage(path: directory.path, reason: "mode is not 0700")
        }
        let fd = open(directory.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            throw storageOpenError(path: directory.path, operation: "open directory")
        }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0,
              opened.st_dev == info.st_dev,
              opened.st_ino == info.st_ino else {
            throw ProviderLifecycleStateError.unsafeStorage(path: directory.path, reason: "directory changed")
        }
        try rejectExtendedACL(fd: fd, path: directory.path)
    }

    private func readRecordIfPresent() throws -> ProviderLifecycleStateRecord? {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw storageOpenError(path: url.path, operation: "open")
        }
        defer { close(fd) }
        let size = try validateOpenFile(fd: fd, path: url.path, allowEmpty: false)
        try validatePath(url, matchesOpenFile: fd)
        var data = Data()
        data.reserveCapacity(Int(size))
        var buffer = [UInt8](repeating: 0, count: 4 * 1_024)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw ProviderLifecycleStateError.io(path: url.path, operation: "read", errnoCode: errno)
            }
            if count == 0 { break }
            guard data.count + count <= Self.maximumRecordBytes else {
                throw ProviderLifecycleStateError.unsafeStorage(path: url.path, reason: "record too large")
            }
            data.append(buffer, count: count)
        }
        let record: ProviderLifecycleStateRecord
        do {
            record = try JSONDecoder().decode(ProviderLifecycleStateRecord.self, from: data)
        } catch {
            throw ProviderLifecycleStateError.malformedRecord(path: url.path)
        }
        try record.validate()
        return record
    }

    @discardableResult
    private func validateOpenFile(fd: Int32, path: String, allowEmpty: Bool) throws -> Int64 {
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw ProviderLifecycleStateError.io(path: path, operation: "stat", errnoCode: errno)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw ProviderLifecycleStateError.unsafeStorage(path: path, reason: "not a regular file")
        }
        guard info.st_uid == expectedOwnerUID else {
            throw ProviderLifecycleStateError.unsafeStorage(path: path, reason: "wrong owner")
        }
        guard info.st_nlink == 1 else {
            throw ProviderLifecycleStateError.unsafeStorage(path: path, reason: "hard link")
        }
        guard (info.st_mode & 0o777) == (S_IRUSR | S_IWUSR) else {
            throw ProviderLifecycleStateError.unsafeStorage(path: path, reason: "mode is not 0600")
        }
        try rejectExtendedACL(fd: fd, path: path)
        guard info.st_size >= (allowEmpty ? 0 : 1), info.st_size <= Self.maximumRecordBytes else {
            throw ProviderLifecycleStateError.unsafeStorage(path: path, reason: "invalid size")
        }
        return info.st_size
    }

    private func validateExistingPath(_ existingURL: URL) throws {
        var info = stat()
        guard lstat(existingURL.path, &info) == 0 else {
            if errno == ENOENT { return }
            throw ProviderLifecycleStateError.io(path: existingURL.path, operation: "inspect", errnoCode: errno)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw ProviderLifecycleStateError.unsafeStorage(path: existingURL.path, reason: "symlink or non-regular file")
        }
        let fd = open(existingURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            throw storageOpenError(path: existingURL.path, operation: "open for validation")
        }
        defer { close(fd) }
        _ = try validateOpenFile(fd: fd, path: existingURL.path, allowEmpty: false)
        try validatePath(existingURL, matchesOpenFile: fd)
    }

    private func writeAtomically(_ record: ProviderLifecycleStateRecord) throws {
        try validateExistingPath(url)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(record)
        data.append(0x0a)
        guard data.count <= Self.maximumRecordBytes else {
            throw ProviderLifecycleStateError.unsafeStorage(path: url.path, reason: "record too large")
        }
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString.lowercased())")
        let fd = open(
            temporaryURL.path,
            O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard fd >= 0 else {
            throw storageOpenError(path: temporaryURL.path, operation: "create temporary")
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
                    throw ProviderLifecycleStateError.io(
                        path: temporaryURL.path,
                        operation: "write temporary",
                        errnoCode: errno
                    )
                }
                offset += count
            }
        }
        guard fchmod(fd, S_IRUSR | S_IWUSR) == 0 else {
            throw ProviderLifecycleStateError.io(path: temporaryURL.path, operation: "chmod temporary", errnoCode: errno)
        }
        _ = try validateOpenFile(fd: fd, path: temporaryURL.path, allowEmpty: false)
        guard fsync(fd) == 0 else {
            throw ProviderLifecycleStateError.io(path: temporaryURL.path, operation: "sync temporary", errnoCode: errno)
        }
        try validateExistingPath(url)
        guard rename(temporaryURL.path, url.path) == 0 else {
            throw ProviderLifecycleStateError.io(path: url.path, operation: "rename temporary", errnoCode: errno)
        }
        shouldRemoveTemporary = false
        try validatePath(url, matchesOpenFile: fd)
        try fsyncDirectory()
    }

    private func fsyncDirectory() throws {
        let directory = url.deletingLastPathComponent()
        let fd = open(directory.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            throw storageOpenError(path: directory.path, operation: "open directory")
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == expectedOwnerUID,
              (info.st_mode & 0o777) == S_IRWXU else {
            throw ProviderLifecycleStateError.unsafeStorage(path: directory.path, reason: "directory changed")
        }
        try rejectExtendedACL(fd: fd, path: directory.path)
        guard fsync(fd) == 0 else {
            throw ProviderLifecycleStateError.io(path: directory.path, operation: "sync directory", errnoCode: errno)
        }
    }

    private func validatePath(_ path: URL, matchesOpenFile fd: Int32) throws {
        var opened = stat()
        guard fstat(fd, &opened) == 0 else {
            throw ProviderLifecycleStateError.io(path: path.path, operation: "stat", errnoCode: errno)
        }
        var named = stat()
        guard lstat(path.path, &named) == 0 else {
            throw ProviderLifecycleStateError.io(path: path.path, operation: "inspect", errnoCode: errno)
        }
        guard (named.st_mode & S_IFMT) == S_IFREG,
              named.st_dev == opened.st_dev,
              named.st_ino == opened.st_ino else {
            throw ProviderLifecycleStateError.unsafeStorage(path: path.path, reason: "path changed")
        }
    }

    private func rejectExtendedACL(fd: Int32, path: String) throws {
        errno = 0
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
            if errno == 0 || errno == ENOENT { return }
            throw ProviderLifecycleStateError.io(path: path, operation: "inspect ACL", errnoCode: errno)
        }
        defer { _ = acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        let result = acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry)
        guard result == 0 else {
            throw ProviderLifecycleStateError.io(path: path, operation: "inspect ACL", errnoCode: errno)
        }
        guard entry == nil else {
            throw ProviderLifecycleStateError.unsafeStorage(path: path, reason: "extended ACL")
        }
    }

    private func storageOpenError(path: String, operation: String) -> ProviderLifecycleStateError {
        if errno == ELOOP {
            return .unsafeStorage(path: path, reason: "symlink")
        }
        return .io(path: path, operation: operation, errnoCode: errno)
    }
}
