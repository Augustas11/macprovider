import ArgumentParser
import Dispatch
import Foundation

enum ModelCatalogReadMode: String, ExpressibleByArgument { case quick, verify, result }

enum ModelCatalogReadError: String, Error, CustomStringConvertible {
    case verificationIncomplete = "verification_incomplete"
    case artifactInvalid = "artifact_invalid"
    case authorityChanged = "authority_changed"
    case contextChanged = "context_changed"
    case readLimitExceeded = "read_limit_exceeded"
    var description: String { rawValue }
}

struct ModelCatalogReadOptions: ParsableArguments {
    @Option(help: .hidden) var appReadRequest: String?
    @Option(help: .hidden) var appReadMode: ModelCatalogReadMode?
    @Option(help: .hidden) var readLockFD: Int32?
    @Option(help: .hidden) var readLifetimeFD: Int32?
    @Option(help: .hidden) var expectedContextSHA256: String?

    var isPresent: Bool {
        appReadRequest != nil || appReadMode != nil || readLockFD != nil ||
        readLifetimeFD != nil || expectedContextSHA256 != nil
    }

    func validate(mode allowed: Set<ModelCatalogReadMode>, target: String? = nil) throws {
        guard isPresent else { return }
        guard let id = appReadRequest, UUID(uuidString: id)?.uuidString.lowercased() == id,
              let mode = appReadMode, allowed.contains(mode), readLockFD == 199,
              readLifetimeFD == 200 else { throw ModelCatalogReadError.contextChanged }
        if mode == .quick {
            guard target == nil, expectedContextSHA256 == nil else { throw ModelCatalogReadError.contextChanged }
        } else {
            guard let digest = expectedContextSHA256, digest.count == 64,
                  digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  mode == .result || (target != nil && !target!.isEmpty) else {
                throw ModelCatalogReadError.contextChanged
            }
        }
    }
}

/// One monotonic budget is shared by hashing and every projection consumer.
/// Helper ceilings may shorten it; no consumer can renew the request deadline.
final class ModelCatalogReadBudget: @unchecked Sendable {
    private let lock = NSLock()
    private let clock: () -> UInt64
    private let absoluteDeadline: UInt64
    private var phaseDeadline: UInt64?
    private var hashLastAdvance: UInt64?
    private var bytes: UInt64 = 0
    private var cancelled = false
    init(mode: ModelCatalogReadMode, clock: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.clock = clock
        let now = clock()
        absoluteDeadline = now &+ (mode == .verify ? 1_800_000_000_000 : 10_000_000_000)
        phaseDeadline = now &+ 10_000_000_000
    }
    var bytesCompleted: UInt64 { lock.lock(); defer { lock.unlock() }; return bytes }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    private func checkLocked() throws {
        let now = clock()
        guard !cancelled, now < absoluteDeadline,
              phaseDeadline.map({ now < $0 }) ?? true,
              hashLastAdvance.map({ now >= $0 && now - $0 < 60_000_000_000 }) ?? true else {
            throw ModelCatalogReadError.verificationIncomplete
        }
    }
    func check() throws { lock.lock(); defer { lock.unlock() }; try checkLocked() }
    func beginHashing() throws {
        lock.lock(); defer { lock.unlock() }; try checkLocked()
        phaseDeadline = nil; hashLastAdvance = clock()
    }
    func beginFinalization() throws {
        lock.lock(); defer { lock.unlock() }; try checkLocked()
        hashLastAdvance = nil; phaseDeadline = clock() &+ 10_000_000_000
    }
    func reportBytes(_ delta: UInt64) throws {
        lock.lock(); defer { lock.unlock() }; try checkLocked()
        guard hashLastAdvance != nil else { throw ModelCatalogReadError.verificationIncomplete }
        let next = bytes.addingReportingOverflow(delta)
        guard !next.overflow else { throw ModelCatalogReadError.readLimitExceeded }
        bytes = next.partialValue
        if delta > 0 { hashLastAdvance = clock() }
    }
    func transactionBudget(maximumSeconds: TimeInterval = 8) throws -> ModelTransactionWorkBudget {
        try check()
        return ModelTransactionWorkBudget(seconds: min(8, maximumSeconds), sharedCheck: { try self.check() })
    }
}

/// Serializes measured progress with terminal output so timer callbacks cannot
/// append bytes after a completed document or fabricate hash advancement.
final class ModelCatalogReadEvents: @unchecked Sendable {
    struct Event: Encodable {
        let schema = "model_catalog_read_event.v1"
        let requestID: String
        let eventSequence: UInt64
        let targetModelID: String
        let modelKey: String
        let kind: String
        let bytesCompleted: UInt64
        let errorCode: String?
        let projection: ModelCatalogEconomicsWire?
        enum CodingKeys: String, CodingKey {
            case schema, kind, projection
            case requestID = "request_id", eventSequence = "event_sequence"
            case targetModelID = "target_model_id", modelKey = "model_key"
            case bytesCompleted = "bytes_completed", errorCode = "error_code"
        }
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(schema, forKey: .schema); try values.encode(requestID, forKey: .requestID)
            try values.encode(eventSequence, forKey: .eventSequence); try values.encode(targetModelID, forKey: .targetModelID)
            try values.encode(modelKey, forKey: .modelKey); try values.encode(kind, forKey: .kind)
            try values.encode(bytesCompleted, forKey: .bytesCompleted)
            try values.encode(errorCode, forKey: .errorCode); try values.encode(projection, forKey: .projection)
        }
    }
    static func encodedLine(requestID: String, eventSequence: UInt64, targetModelID: String,
                            modelKey: String, kind: String, bytesCompleted: UInt64,
                            errorCode: String?, projection: ModelCatalogEconomicsWire?) throws -> Data {
        let event = Event(requestID: requestID, eventSequence: eventSequence, targetModelID: targetModelID,
                          modelKey: modelKey, kind: kind, bytesCompleted: bytesCompleted,
                          errorCode: errorCode, projection: projection)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(event); data.append(10)
        return data
    }
    private let lock = NSLock()
    private let requestID: String, target: String, key: String
    private let budget: ModelCatalogReadBudget
    private let write: (Data) throws -> Void
    private var sequence: UInt64 = 0
    private var outputBytes = 0
    private var terminal = false
    private var timer: DispatchSourceTimer?
    init(requestID: String, target: String, key: String, budget: ModelCatalogReadBudget,
         write: @escaping (Data) throws -> Void = { try FileHandle.standardOutput.write(contentsOf: $0) }) {
        self.requestID = requestID; self.target = target; self.key = key; self.budget = budget; self.write = write
    }
    func start() throws {
        try emit(kind: "accepted")
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "macprovider.catalog-read-progress"))
        timer.schedule(deadline: .now() + .seconds(4), repeating: .seconds(4))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            do { try self.budget.check(); try self.emit(kind: "progress") }
            catch { self.budget.cancel() }
        }
        self.timer = timer; timer.resume()
    }
    func complete(_ projection: ModelCatalogEconomicsWire, maximumLineBytes: Int = 1_048_576) throws {
        try budget.check(); try emit(kind: "completed", projection: projection, maximumLineBytes: maximumLineBytes)
    }
    func fail(_ error: ModelCatalogReadError) { try? emit(kind: "failed", error: error) }
    private func emit(kind: String, error: ModelCatalogReadError? = nil,
                      projection: ModelCatalogEconomicsWire? = nil,
                      maximumLineBytes: Int = 1_048_576) throws {
        lock.lock(); defer { lock.unlock() }
        guard !terminal else { return }
        try budget.check()
        guard sequence < 4_096 else { throw ModelCatalogReadError.readLimitExceeded }
        let data = try Self.encodedLine(requestID: requestID, eventSequence: sequence + 1,
                                        targetModelID: target, modelKey: key, kind: kind,
                                        bytesCompleted: budget.bytesCompleted,
                                        errorCode: error?.rawValue, projection: projection)
        try budget.check()
        guard maximumLineBytes >= 0, data.count <= maximumLineBytes,
              data.count <= 1_048_576, outputBytes <= 8_388_608,
              data.count <= 8_388_608 - outputBytes else {
            throw ModelCatalogReadError.readLimitExceeded
        }
        try write(data)
        sequence += 1; outputBytes += data.count
        if kind == "completed" || kind == "failed" {
            // Once the terminal bytes are written, a later expiry must not append
            // a contradictory second terminal. Nonzero process exit still makes
            // the just-written line unusable to the owned reader.
            terminal = true; timer?.cancel()
        }
        try budget.check()
    }
    deinit { timer?.cancel() }
}
