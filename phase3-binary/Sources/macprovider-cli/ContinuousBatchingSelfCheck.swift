import Darwin
import Foundation

/// SPEC-038 FR-CB10 / FR-CB11 (v0.3.12): every Mac qualifies continuous
/// batching for its own loaded model. The load-time SPEC-039 probes already
/// prove the paged engine against stock serial decode on fixed prompts (the
/// quality gate); this check proves row isolation and measures the gain at
/// each slot count it may grant:
///
/// - isolation: every row of a k-row batch must produce the same greedy tokens
///   as that prompt run alone on the same paged engine, or first differ only
///   at a numerical near-tie (both tokens the stock serial top two within the
///   load-time probe's 1.0-logit tolerance), at every k up to the one granted
///   (kernel shapes change with the row count, e.g. MLX quantized matmul
///   switches kernels above 5 rows);
/// - throughput: the batch's aggregate tokens/s must beat stock serial decode
///   by `minimumAggregateGain`.
///
/// It runs only while the provider is idle, yields to real requests, and its
/// result is stored per (model, Metal library, kernel, hardware, macOS build) so a restart
/// does not repeat it. Until it finishes the provider serves one slot serially
/// (or a signed positive entry's provisional grant).
enum ContinuousBatchingSelfCheckState: Sendable, Equatable {
    case pending
    case granted(slots: Int)
    case refused(reason: String)
}

struct ContinuousBatchingSelfCheckKey: Sendable, Equatable, Hashable, Codable {
    let modelSHA256: String
    let metallibSHA256: String
    let kernelIdentifier: String
    let hardwareClass: String
    /// macOS version and build: an OS upgrade changes Metal compilation and
    /// scheduling, so evidence from before it is not reused.
    let osBuild: String

    enum CodingKeys: String, CodingKey {
        case modelSHA256 = "model_sha256"
        case metallibSHA256 = "metallib_sha256"
        case kernelIdentifier = "kernel_identifier"
        case hardwareClass = "hardware_class"
        case osBuild = "os_build"
    }

    static var currentOSBuild: String { ProcessInfo.processInfo.operatingSystemVersionString }
}

struct ContinuousBatchingSelfCheckTarget: Sendable, Equatable {
    let key: ContinuousBatchingSelfCheckKey
    /// Scheduler rows built at load: the most this check may grant.
    let maxRows: Int
}

struct ContinuousBatchingSelfCheckMeasurement: Sendable, Equatable, Codable {
    let slots: Int
    /// Every row equals its prompt run alone, or first differs only at a
    /// numerical near-tie (`continuousBatchingSelfCheckDivergenceIsNearTie`).
    let conformant: Bool
    /// Rows that differed only at a near-tie.
    var nearTieRows: Int = 0
    let aggregateTPS: Double

    enum CodingKeys: String, CodingKey {
        case slots
        case conformant
        case nearTieRows = "near_tie_rows"
        case aggregateTPS = "aggregate_tps"
    }
}

struct ContinuousBatchingSelfCheckDecision: Sendable, Equatable, Codable {
    /// 1 means serve serially.
    let slots: Int
    /// `granted`, `row_divergence_at_<k>`, `no_net_gain`,
    /// `serial_baseline_unavailable`, `crashed_at_<k>`, `single_row`.
    let reason: String
    /// Highest slot count whose rows all passed the isolation check (1 when
    /// none did). No served count, owner pin included, may exceed it.
    let verifiedSlots: Int

    enum CodingKeys: String, CodingKey {
        case slots
        case reason
        case verifiedSlots = "verified_slots"
    }

    var state: ContinuousBatchingSelfCheckState {
        slots > 1 ? .granted(slots: slots) : .refused(reason: reason)
    }
}

/// Operator- and canary-visible self-check state (`/v1/status`
/// `continuous_batching.self_check`, heartbeat `cb_self_check`).
public struct ContinuousBatchingSelfCheckReport: Sendable, Equatable {
    /// A decision reason, or `pending` / `deferred` before one exists.
    public let decision: String
    public let servedSlots: Int
    public let verifiedSlots: Int
    public let deferrals: Int
    public let modelSHA256: String?
    public let metallibSHA256: String?
    public let kernelIdentifier: String?
    public let hardwareClass: String?
    public let osBuild: String?

    init(
        decision: String,
        servedSlots: Int,
        verifiedSlots: Int,
        deferrals: Int = 0,
        key: ContinuousBatchingSelfCheckKey?
    ) {
        self.decision = decision
        self.servedSlots = servedSlots
        self.verifiedSlots = verifiedSlots
        self.deferrals = deferrals
        self.modelSHA256 = key?.modelSHA256
        self.metallibSHA256 = key?.metallibSHA256
        self.kernelIdentifier = key?.kernelIdentifier
        self.hardwareClass = key?.hardwareClass
        self.osBuild = key?.osBuild
    }

    var jsonObject: [String: Any] {
        func nullable(_ value: String?) -> Any { value.map { $0 as Any } ?? NSNull() }
        return [
            "decision": decision,
            "served_slots": servedSlots,
            "verified_k": verifiedSlots,
            "deferrals": deferrals,
            "model_sha256": nullable(modelSHA256),
            "metallib_sha256": nullable(metallibSHA256),
            "kernel_identifier": nullable(kernelIdentifier),
            "hardware_class": nullable(hardwareClass),
            "os_build": nullable(osBuild),
        ]
    }
}

enum ContinuousBatchingSelfCheck {
    /// SPEC-038 FR-CB14 MSB-03 bar: batching must beat serial by more than 20%.
    static let minimumAggregateGain = 1.2
    /// Lowest slot count within this fraction of the best aggregate wins, as in
    /// the SPEC-023-R009 concurrency calibration (memory-risk posture).
    static let tieBandFraction = AutotuneConcurrencyCalibrator().minAggregateGainFraction
    static let maxOutputTokens = 48
    static let serialBaselinePrompts = 4

    /// Slot counts to measure: the R009 ladder from 2 up to `maxRows`.
    static func ladder(maxRows: Int) -> [Int] {
        AutotuneConcurrencyCalibrator.sweepDepths(upperBound: maxRows).filter { $0 >= 2 }
    }

    /// `measurements` ascend by slots and stop after the first inexact one.
    /// `crashedAt` is a slot count whose step never finished (the process
    /// died, e.g. a Metal OOM); it is never measured again on this key.
    static func decide(
        serialTPS: Double,
        measurements: [ContinuousBatchingSelfCheckMeasurement],
        crashedAt: Int? = nil
    ) -> ContinuousBatchingSelfCheckDecision {
        let exactPrefix = Array(measurements.prefix { $0.conformant })
        let verified = exactPrefix.last?.slots ?? 1
        guard serialTPS > 0, serialTPS.isFinite else {
            return .init(slots: 1, reason: "serial_baseline_unavailable", verifiedSlots: verified)
        }
        guard !exactPrefix.isEmpty else {
            if let crashedAt, measurements.isEmpty {
                return .init(slots: 1, reason: "crashed_at_\(crashedAt)", verifiedSlots: 1)
            }
            let first = measurements.first?.slots ?? 2
            return .init(slots: 1, reason: "row_divergence_at_\(first)", verifiedSlots: 1)
        }
        let gaining = exactPrefix.filter {
            $0.aggregateTPS.isFinite && $0.aggregateTPS >= serialTPS * minimumAggregateGain
        }
        guard !gaining.isEmpty else {
            return .init(slots: 1, reason: "no_net_gain", verifiedSlots: verified)
        }
        let slots = AutotuneConcurrencyCalibrator.selectDepth(
            feasible: gaining.map {
                AutotuneConcurrencyCalibrationMeasurement(
                    batchDepth: $0.slots,
                    streams: $0.slots,
                    aggregateTPS: $0.aggregateTPS,
                    passed: true
                )
            },
            minAggregateGainFraction: tieBandFraction
        )
        return .init(slots: slots, reason: "granted", verifiedSlots: verified)
    }

    /// The count `serve` advertises: the decision (or the owner pin), never
    /// above the highest verified slot count or the scheduler rows.
    static func servedSlots(
        decision: ContinuousBatchingSelfCheckDecision,
        ownerPinned: Int?,
        maxRows: Int
    ) -> Int {
        max(1, min(ownerPinned ?? decision.slots, decision.verifiedSlots, maxRows))
    }

    /// Wait before the next attempt after `deferrals` consecutive yields to
    /// traffic: doubling from `base`, at most 15 minutes. Progress is kept, so
    /// a busy Mac still finishes one step per idle window.
    static func deferralBackoffSeconds(deferrals: Int, base: Double) -> Double {
        guard deferrals > 0 else { return 0 }
        return min(base * pow(2, Double(min(deferrals, 16))), 15 * 60)
    }

    /// Structurally different prompts, so rows rarely share a token at the
    /// same position and a row that read another row's state would diverge
    /// visibly (the load-time probe's "challenge distinguishing" idea).
    static func promptTexts(count: Int) -> [String] {
        let starts = [
            "Count upward in words from one to twenty.",
            "List the first twelve letters of the Greek alphabet.",
            "Write a Python function that reverses a linked list.",
            "Translate 'good morning, how are you' into French, Spanish and German.",
            "Write an HTML page skeleton with a title and one paragraph.",
            "Name the planets of the solar system from the Sun outward.",
            "Give a haiku about winter rain.",
            "Explain photosynthesis to a ten-year-old in two sentences.",
            "Write a SQL query that counts orders per customer.",
            "List five prime numbers greater than one hundred.",
            "Describe the rules of tic-tac-toe briefly.",
            "Write a limerick about a cat who learned to code.",
            "Convert 98.6 degrees Fahrenheit to Celsius and show the steps.",
            "Write a JSON object describing a book with title, author and year.",
            "Summarize the plot of Romeo and Juliet in three lines.",
            "Write a bash one-liner that counts lines in all .txt files.",
            "Give three tips for learning to play the guitar.",
            "Spell the word 'encyclopedia' backwards.",
            "Write a short dialogue between a pilot and air traffic control.",
            "List the days of the week in Italian.",
            "Write a regular expression that matches an email address.",
            "Describe the taste of a lemon to someone who never had one.",
            "Write a Swift struct for a 2D point with a distance method.",
            "Name four instruments in a string quartet.",
            "Explain what a black hole is in one paragraph.",
            "Write a shopping list for a pancake breakfast.",
            "Give the multiplication table of seven up to seventy.",
            "Write a polite email declining a meeting invitation.",
            "List the colors of the rainbow in order.",
            "Write a Go function that sums a slice of integers.",
            "Describe a sunrise over the ocean in vivid detail.",
            "Explain the difference between TCP and UDP briefly.",
        ]
        return (0..<count).map { index in
            index < starts.count ? starts[index] : "\(starts[index % starts.count]) (variant \(index / starts.count))"
        }
    }
}

/// Stored self-check state, keyed by `ContinuousBatchingSelfCheckKey`. A
/// private (0600, owner-only, no symlinks) JSON file next to the provider
/// config. Progress is written before each step, so a step that kills the
/// process (e.g. a Metal OOM at a high slot count) is found on restart and
/// never retried on the same key.
struct ContinuousBatchingSelfCheckStore: Sendable {
    static let schemaVersion = "macprovider.cb-self-check.v2"
    static let fileName = "cb-self-check.json"
    static let maxEntries = 64

    let url: URL

    struct Record: Codable, Equatable {
        let key: ContinuousBatchingSelfCheckKey
        /// Nil while the ladder is still running.
        var decision: ContinuousBatchingSelfCheckDecision?
        var serialTPS: Double
        var measurements: [ContinuousBatchingSelfCheckMeasurement]
        /// Each prompt's tokens when run alone, so a deferred ladder resumes.
        var aloneOutputs: [[Int]]
        /// Set while a step runs; found set on load means that step crashed.
        var inProgressSlots: Int?
        var decidedAt: String?

        enum CodingKeys: String, CodingKey {
            case key
            case decision
            case serialTPS = "serial_tps"
            case measurements
            case aloneOutputs = "alone_outputs"
            case inProgressSlots = "in_progress_slots"
            case decidedAt = "decided_at"
        }
    }

    private struct Document: Codable {
        let schemaVersion: String
        let records: [Record]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case records
        }
    }

    init(configPath: String) {
        let expanded = (configPath as NSString).expandingTildeInPath
        url = URL(fileURLWithPath: expanded).deletingLastPathComponent().appendingPathComponent(Self.fileName)
    }

    init(url: URL) {
        self.url = url
    }

    func record(for key: ContinuousBatchingSelfCheckKey) -> Record? {
        read().last { $0.key == key }
    }

    func decision(for key: ContinuousBatchingSelfCheckKey) -> ContinuousBatchingSelfCheckDecision? {
        record(for: key)?.decision
    }

    func store(_ record: Record) throws {
        var records = read().filter { $0.key != record.key }
        records.append(record)
        if records.count > Self.maxEntries {
            records = Array(records.suffix(Self.maxEntries))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try write(encoder.encode(Document(schemaVersion: Self.schemaVersion, records: records)))
    }

    private func read() -> [Record] {
        let fd = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW) }
        guard fd >= 0 else { return [] }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_uid == getuid(),
              (st.st_mode & 0o022) == 0,
              let data = try? handle.readToEnd(),
              let document = try? JSONDecoder().decode(Document.self, from: data),
              document.schemaVersion == Self.schemaVersion
        else { return [] }
        return document.records
    }

    private func write(_ data: Data) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        var existing = stat()
        if lstat(url.path, &existing) == 0,
           (existing.st_mode & S_IFMT) != S_IFREG || existing.st_uid != getuid() {
            throw POSIXError(.EPERM)
        }
        let temporary = parent.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = temporary.path.withCString { open($0, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600) }
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { _ = unlink(temporary.path) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        guard fsync(fd) == 0 else { throw POSIXError(.EIO) }
        try handle.close()
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(.EIO) }
    }
}

/// Runs the self-check in the background of `serve`: polls the runtime for a
/// pending target, applies a stored decision at once, and otherwise measures
/// one ladder step at a time only while no request is in flight, abandoning a
/// step the moment one arrives. Progress persists, consecutive deferrals back
/// off, and a step that crashed the process is never retried on its key.
/// Never blocks serving.
actor ContinuousBatchingSelfCheckDriver {
    private let runtime: ModelRuntime
    private let providerStatus: ProviderStatus
    private let store: ContinuousBatchingSelfCheckStore
    /// Owner-pinned served slots: the check decides batching on/off and may
    /// only lower the pin to the verified slot count.
    private let ownerPinnedSlots: Int?
    private let idleSeconds: Double
    private let pollSeconds: Double
    private let log: @Sendable (String) -> Void
    private var deferrals = 0
    private var nextAttemptAt = Date.distantPast

    init(
        runtime: ModelRuntime,
        providerStatus: ProviderStatus,
        store: ContinuousBatchingSelfCheckStore,
        ownerPinnedSlots: Int?,
        idleSeconds: Double = 10,
        pollSeconds: Double = 5,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.runtime = runtime
        self.providerStatus = providerStatus
        self.store = store
        self.ownerPinnedSlots = ownerPinnedSlots
        self.idleSeconds = idleSeconds
        self.pollSeconds = max(0.1, pollSeconds)
        self.log = log
    }

    func run() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(pollSeconds * 1_000_000_000))
            guard let target = await runtime.continuousBatchingSelfCheckTarget() else { continue }
            if let record = store.record(for: target.key) {
                if let decision = record.decision {
                    await apply(decision, target: target, source: "stored")
                    continue
                }
                if let crashed = record.inProgressSlots {
                    // The previous process died inside this step.
                    log("event=cb_self_check action=crash_recovered slots=\(crashed)")
                    await finish(record, crashedAt: crashed, target: target)
                    continue
                }
            }
            guard Date() >= nextAttemptAt, await isIdle() else { continue }
            await measure(target)
        }
    }

    private func isIdle() async -> Bool {
        let snapshot = await providerStatus.snapshot()
        guard snapshot.requestsInFlight == 0 else { return false }
        return await providerStatus.secondsSinceLastActivityOrPrewarm() >= idleSeconds
    }

    private enum StepError: Error { case yielded }

    /// Runs `body` and cancels it as soon as a request is in flight.
    private func yieldingToRequests<T: Sendable>(
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let providerStatus = providerStatus
        return try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await body() }
            group.addTask {
                while !Task.isCancelled {
                    if await providerStatus.snapshot().requestsInFlight > 0 { throw StepError.yielded }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                return nil
            }
            defer { group.cancelAll() }
            while let next = try await group.next() {
                if let value = next { return value }
            }
            throw StepError.yielded
        }
    }

    private func save(_ record: ContinuousBatchingSelfCheckStore.Record) {
        do { try store.store(record) } catch {
            log("event=cb_self_check action=store_failed error=\(error)")
        }
    }

    private func measure(_ target: ContinuousBatchingSelfCheckTarget) async {
        let runtime = runtime
        let ladder = ContinuousBatchingSelfCheck.ladder(maxRows: ownerPinnedSlots.map { min($0, target.maxRows) } ?? target.maxRows)
        var record = store.record(for: target.key) ?? .init(
            key: target.key, decision: nil, serialTPS: 0, measurements: [], aloneOutputs: [], inProgressSlots: nil, decidedAt: nil
        )
        guard let maxSlots = ladder.last else {
            record.decision = .init(slots: 1, reason: "single_row", verifiedSlots: 1)
            await finish(record, crashedAt: nil, target: target)
            return
        }
        await report(decision: deferrals > 0 ? "deferred" : "pending", target: target)
        log("event=cb_self_check action=step max_slots=\(maxSlots) resumed_at=\(record.measurements.count) model_sha256=\(target.key.modelSHA256)")
        do {
            let tokens = ContinuousBatchingSelfCheck.maxOutputTokens
            // Scheduler request ids are idempotency keys; never reuse one.
            let attempt = UUID().uuidString.prefix(8).lowercased()
            let prompts = try await runtime.continuousBatchingSelfCheckPrompts(
                ContinuousBatchingSelfCheck.promptTexts(count: maxSlots)
            )
            if record.serialTPS <= 0 {
                // Stock serial decode on the same prompts the batches use; a
                // warm-up prompt first, then the best of two passes, so a slow
                // first run cannot inflate the measured gain.
                let serialPrompts = Array(prompts.prefix(ContinuousBatchingSelfCheck.serialBaselinePrompts))
                _ = try await yieldingToRequests {
                    try await runtime.continuousBatchingSelfCheckSerialTPS(prompts: [prompts[0]], maxTokens: 8)
                }
                for _ in 0..<2 {
                    let run = try await yieldingToRequests {
                        try await runtime.continuousBatchingSelfCheckSerialTPS(prompts: serialPrompts, maxTokens: tokens)
                    }
                    record.serialTPS = max(record.serialTPS, run)
                }
                save(record)
            }
            for slots in ladder where !record.measurements.contains(where: { $0.slots == slots }) {
                while record.aloneOutputs.count < slots {
                    let index = record.aloneOutputs.count
                    let row = try await yieldingToRequests {
                        try await runtime.runContinuousBatchingSelfCheckBatch(
                            prompts: [prompts[index]], maxOutputTokens: tokens, idPrefix: "cb-self-check-\(attempt)-alone-\(index)"
                        )
                    }
                    record.aloneOutputs.append(row.outputs[0])
                }
                record.inProgressSlots = slots
                save(record)
                // Two passes: the first also compiles kernels for this row
                // count, so throughput is the faster pass; every distinct row
                // output of both passes must pass the isolation check.
                var passes: [(outputs: [[Int]], seconds: Double)] = []
                for pass in 0..<2 {
                    passes.append(try await yieldingToRequests {
                        try await runtime.runContinuousBatchingSelfCheckBatch(
                            prompts: Array(prompts.prefix(slots)), maxOutputTokens: tokens, idPrefix: "cb-self-check-\(attempt)-k\(slots)-p\(pass)"
                        )
                    })
                }
                let batch = passes.min { $0.seconds < $1.seconds }!
                let alone = record.aloneOutputs
                var conformant = true
                var nearTieRows = 0
                var divergences: [String] = []
                var rowsToCheck: [(row: Int, pair: ([Int], [Int]))] = []
                for pass in passes {
                    for (row, pair) in zip(pass.outputs, alone).enumerated()
                    where pair.0 != pair.1 && !rowsToCheck.contains(where: { $0.row == row && $0.pair.0 == pair.0 }) {
                        rowsToCheck.append((row, pair))
                    }
                }
                for (row, pair) in rowsToCheck {
                    let index = Array(zip(pair.0, pair.1)).firstIndex { $0.0 != $0.1 }
                    var verdictText = "length"
                    var marginText = "na"
                    var tokenText = "na"
                    var nearTie = false
                    if let index {
                        let prompt = prompts[row]
                        let prefix = Array(pair.1.prefix(index))
                        let aloneToken = pair.1[index]
                        let batchedToken = pair.0[index]
                        let others = alone.prefix(slots).enumerated().compactMap { other, tokens -> Int? in
                            other != row && tokens.indices.contains(index) ? tokens[index] : nil
                        }
                        let verdict = try await yieldingToRequests {
                            try await runtime.continuousBatchingSelfCheckDivergence(
                                prompt: prompt, sharedPrefix: prefix, aloneToken: aloneToken,
                                batchedToken: batchedToken, otherRowsAloneTokens: others
                            )
                        }
                        nearTie = verdict.nearTie
                        verdictText = verdict.reason
                        marginText = verdict.margin.map { String(format: "%.3f", $0) } ?? "na"
                        tokenText = "\(aloneToken)->\(batchedToken)"
                    }
                    if nearTie { nearTieRows += 1 } else { conformant = false }
                    divergences.append("\(row)@\(index.map(String.init) ?? "len")/\(pair.1.count):\(verdictText):tokens=\(tokenText):margin=\(marginText)")
                }
                let generated = batch.outputs.reduce(0) { $0 + $1.count }
                let aggregate = batch.seconds > 0 ? Double(generated) / batch.seconds : 0
                record.measurements.append(.init(slots: slots, conformant: conformant, nearTieRows: nearTieRows, aggregateTPS: aggregate))
                record.inProgressSlots = nil
                save(record)
                log("event=cb_self_check action=measured slots=\(slots) conformant=\(conformant) divergent_rows=\(divergences.isEmpty ? "none" : divergences.joined(separator: ",")) aggregate_tps=\(String(format: "%.1f", aggregate)) serial_tps=\(String(format: "%.1f", record.serialTPS))")
                if !conformant { break }
            }
            deferrals = 0
            nextAttemptAt = .distantPast
            await finish(record, crashedAt: nil, target: target)
        } catch {
            // Yielded to a real request or a transient failure: progress is kept
            // (the interrupted step was not completed, so it is not a crash) and
            // the next attempt waits longer each time.
            record.inProgressSlots = nil
            save(record)
            deferrals += 1
            let wait = ContinuousBatchingSelfCheck.deferralBackoffSeconds(deferrals: deferrals, base: pollSeconds)
            nextAttemptAt = Date().addingTimeInterval(wait)
            await report(decision: "deferred", target: target)
            log("event=cb_self_check action=deferred deferrals=\(deferrals) retry_in_s=\(Int(wait)) reason=\(error is StepError ? "request_in_flight" : "step_failed error=\(String(describing: error).prefix(200))")")
        }
    }

    private func finish(
        _ record: ContinuousBatchingSelfCheckStore.Record,
        crashedAt: Int?,
        target: ContinuousBatchingSelfCheckTarget
    ) async {
        // A swap during the measurement changes the target; drop the result.
        guard await runtime.continuousBatchingSelfCheckTarget() == target else { return }
        var final = record
        final.decision = record.decision ?? ContinuousBatchingSelfCheck.decide(
            serialTPS: record.serialTPS, measurements: record.measurements, crashedAt: crashedAt
        )
        final.inProgressSlots = nil
        final.decidedAt = ISO8601DateFormatter().string(from: Date())
        save(final)
        if let decision = final.decision {
            await apply(decision, target: target, source: crashedAt == nil ? "measured" : "crash_recovered")
        }
    }

    private func report(decision: String, target: ContinuousBatchingSelfCheckTarget) async {
        await runtime.setContinuousBatchingSelfCheckReport(.init(
            decision: decision,
            servedSlots: await providerStatus.snapshot().capacity.maxConcurrency,
            verifiedSlots: 1,
            deferrals: deferrals,
            key: target.key
        ))
    }

    private func apply(
        _ decision: ContinuousBatchingSelfCheckDecision,
        target: ContinuousBatchingSelfCheckTarget,
        source: String
    ) async {
        let slots = ContinuousBatchingSelfCheck.servedSlots(
            decision: decision, ownerPinned: ownerPinnedSlots, maxRows: target.maxRows
        )
        await runtime.applyContinuousBatchingSelfCheck(decision.state, servedSlots: slots)
        await runtime.setContinuousBatchingSelfCheckReport(.init(
            decision: decision.reason,
            servedSlots: slots,
            verifiedSlots: decision.verifiedSlots,
            deferrals: deferrals,
            key: target.key
        ))
        await providerStatus.updateServedSlots(slots)
        log("event=cb_self_check action=applied source=\(source) reason=\(decision.reason) slots=\(slots) verified_k=\(decision.verifiedSlots) model_sha256=\(target.key.modelSHA256)")
    }
}
