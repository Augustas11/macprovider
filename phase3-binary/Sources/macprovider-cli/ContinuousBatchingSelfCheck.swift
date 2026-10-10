import Darwin
import Foundation

/// SPEC-038 FR-CB10 / FR-CB11 (v0.3.15): every Mac qualifies continuous
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
/// result is stored per (model, Metal library, kernel, hardware, macOS build,
/// MLX pin, decode window) so a restart
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
    /// The pinned MLX fork identity (mlx-swift-lm revision and mlx-swift
    /// version+revision): a runtime pin change re-runs the check even when the
    /// packaged Metal library hash happens not to change.
    var runtimeBuild: String = ContinuousBatchingSelfCheckKey.currentRuntimeBuild
    /// The scheduler's decode lockstep window the check ran at (SPEC-038
    /// FR-CB2): a result measured at another window (hybrid models moved from
    /// 1 to 16 in v0.3.16) does not qualify this one. Records written before
    /// the field decode as 0, which matches no live window, so they re-run.
    var decodeWindow: Int = ContinuousBatchSchedulerConfiguration.defaultDecodeLockstepWindow

    enum CodingKeys: String, CodingKey {
        case modelSHA256 = "model_sha256"
        case metallibSHA256 = "metallib_sha256"
        case kernelIdentifier = "kernel_identifier"
        case hardwareClass = "hardware_class"
        case osBuild = "os_build"
        case runtimeBuild = "runtime_build"
        case decodeWindow = "decode_window"
    }

    static var currentRuntimeBuild: String {
        "\(KVBuildIdentity.mlxSwiftLMRevision)/\(KVBuildIdentity.mlxVersion)"
    }

    static var currentOSBuild: String { ProcessInfo.processInfo.operatingSystemVersionString }
}

extension ContinuousBatchingSelfCheckKey {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelSHA256 = try container.decode(String.self, forKey: .modelSHA256)
        metallibSHA256 = try container.decode(String.self, forKey: .metallibSHA256)
        kernelIdentifier = try container.decode(String.self, forKey: .kernelIdentifier)
        hardwareClass = try container.decode(String.self, forKey: .hardwareClass)
        osBuild = try container.decode(String.self, forKey: .osBuild)
        runtimeBuild = try container.decode(String.self, forKey: .runtimeBuild)
        decodeWindow = try container.decodeIfPresent(Int.self, forKey: .decodeWindow) ?? 0
    }
}

struct ContinuousBatchingSelfCheckTarget: Sendable, Equatable {
    let key: ContinuousBatchingSelfCheckKey
    /// Scheduler rows built at load: the most this check may grant.
    let maxRows: Int
    /// The runtime's swap generation: a result measured before a swap never
    /// applies after it, even to the same model.
    var generation: Int = 0
}

struct ContinuousBatchingSelfCheckMeasurement: Sendable, Equatable, Codable {
    let slots: Int
    /// Every row equals its prompt run alone, or first differs only at a
    /// numerical near-tie (`continuousBatchingSelfCheckDivergenceIsNearTie`).
    let conformant: Bool
    /// Rows that differed only at a near-tie.
    var nearTieRows: Int = 0
    let aggregateTPS: Double
    /// Median over repeats of batched aggregate / stock serial tokens/s,
    /// each repeat measured back to back on the same prompts. 0 means "use
    /// aggregateTPS over the record's serial baseline".
    var gain: Double = 0
    /// False for a slot count checked for isolation only (between ladder
    /// rungs); such a count is verified but never picked by throughput.
    var throughputMeasured: Bool = true

    enum CodingKeys: String, CodingKey {
        case slots
        case conformant
        case nearTieRows = "near_tie_rows"
        case aggregateTPS = "aggregate_tps"
        case gain
        case throughputMeasured = "throughput_measured"
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
    public let runtimeBuild: String?

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
        self.runtimeBuild = key?.runtimeBuild
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
            "runtime_build": nullable(runtimeBuild),
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
            $0.throughputMeasured && gain(of: $0, serialTPS: serialTPS) >= minimumAggregateGain
        }
        guard !gaining.isEmpty else {
            return .init(slots: 1, reason: "no_net_gain", verifiedSlots: verified)
        }
        let slots = AutotuneConcurrencyCalibrator.selectDepth(
            feasible: gaining.map {
                // Rank by the noise-corrected gain (median serial/batch ratio).
                AutotuneConcurrencyCalibrationMeasurement(
                    batchDepth: $0.slots,
                    streams: $0.slots,
                    aggregateTPS: gain(of: $0, serialTPS: serialTPS),
                    passed: true
                )
            },
            minAggregateGainFraction: tieBandFraction
        )
        return .init(slots: slots, reason: "granted", verifiedSlots: verified)
    }

    static func gain(of measurement: ContinuousBatchingSelfCheckMeasurement, serialTPS: Double) -> Double {
        let value = measurement.gain > 0 ? measurement.gain : measurement.aggregateTPS / serialTPS
        return value.isFinite ? value : 0
    }

    /// Consecutive clear losses (best exact batch slower than serial) are
    /// counted and logged and stretch the re-measure interval; throughput
    /// alone never lowers or removes a prior grant.
    static let confirmedNoGainStreak = 3
    static let remeasureBaseSeconds = 3_600.0

    /// SPEC-038 FR-CB10 (v0.3.15): throughput noise never switches batching
    /// off or lowers a Mac that already batches. Only a correctness result
    /// (row divergence or leak beyond the probe rule, or a crash) lowers or
    /// revokes `priorGrant`; a fresh Mac keeps the 1.2x rule. Returns the
    /// decision to apply, the new no-gain streak, and when to re-measure.
    static func reconcile(
        fresh: ContinuousBatchingSelfCheckDecision,
        priorGrant: Int?,
        serialTPS: Double,
        measurements: [ContinuousBatchingSelfCheckMeasurement],
        previousStreak: Int
    ) -> (decision: ContinuousBatchingSelfCheckDecision, streak: Int, remeasureAfterSeconds: Double?) {
        guard let prior = priorGrant, prior > 1 else { return (fresh, 0, nil) }
        switch fresh.reason {
        case "granted":
            let kept = min(prior, fresh.verifiedSlots)
            return (.init(slots: max(fresh.slots, kept), reason: "granted", verifiedSlots: fresh.verifiedSlots), 0, nil)
        case "no_net_gain", "serial_baseline_unavailable":
            let exact = measurements.prefix { $0.conformant }
            let best = exact.map { gain(of: $0, serialTPS: serialTPS) }.max() ?? 0
            let clearLoss = fresh.reason == "no_net_gain" && best > 0 && best < 1.0
            let streak = clearLoss ? previousStreak + 1 : 0
            let keep = min(prior, max(fresh.verifiedSlots, 1))
            return (
                .init(slots: keep, reason: "kept_prior_grant_\(fresh.reason)", verifiedSlots: fresh.verifiedSlots),
                streak,
                remeasureBaseSeconds * pow(2, Double(min(streak, 6)))
            )
        default:
            // Row divergence, leak, or crash: correctness rules.
            return (fresh, 0, nil)
        }
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
        // Rows of unequal prompt length: batched decode pads keys to the
        // longest row, which can change a neighbour's attention kernel route,
        // so a ladder of equal-length rows would miss that case.
        let contextParagraphs = [0, 2, 8, 14]
        return (0..<count).map { index in
            let task = index < starts.count ? starts[index] : "\(starts[index % starts.count]) (variant \(index / starts.count))"
            let paragraphs = contextParagraphs[index % contextParagraphs.count]
            guard paragraphs > 0 else { return task }
            let context = (0..<paragraphs).map { contextParagraph($0 + index) }.joined(separator: "\n\n")
            return "Background notes:\n\(context)\n\nIgnoring the notes above, answer this: \(task)"
        }
    }

    private static func contextParagraph(_ seed: Int) -> String {
        let subjects = ["the harbor", "the orchard", "the observatory", "the railway yard", "the mill", "the library", "the market", "the glacier"]
        let subject = subjects[seed % subjects.count]
        return "Paragraph \(seed): Visitors to \(subject) often arrive early, before the light settles, and spend a long hour "
            + "walking its edges while noting small details: the sound of distant machinery, the color of the stone, the "
            + "names painted on old signs, and the way the wind changes direction near noon. Records kept at \(subject) "
            + "describe seasons of plenty and seasons of repair, careful inventories, and letters exchanged with neighbors."
    }
}

/// What a freshly loaded model serves before its own self-check runs: its
/// stored decision, else an older-runtime or signed provisional grant for the
/// same model, else nil (one slot, or the owner pin). Used at startup and on
/// every warm swap or adoption, before readiness is published.
struct ContinuousBatchingSelfCheckResolution: Sendable, Equatable {
    let state: ContinuousBatchingSelfCheckState
    let servedSlots: Int
    let report: ContinuousBatchingSelfCheckReport

    static func resolve(
        store: ContinuousBatchingSelfCheckStore,
        target: ContinuousBatchingSelfCheckTarget,
        ownerPinned: Int?,
        provisional: ContinuousBatchingSelfCheckDriver.Provisional?
    ) -> ContinuousBatchingSelfCheckResolution? {
        let record = store.record(for: target.key)
        if let decision = record?.decision, record?.inProgressSlots == nil {
            let slots = ContinuousBatchingSelfCheck.servedSlots(
                decision: decision, ownerPinned: ownerPinned, maxRows: target.maxRows
            )
            return .init(
                state: decision.state,
                servedSlots: slots,
                report: .init(decision: decision.reason, servedSlots: slots, verifiedSlots: decision.verifiedSlots, key: target.key)
            )
        }
        // A signed provisional grant carries the configured (or pinned) count;
        // an older-runtime grant never carries more than it verified.
        let provisionalSlots = provisional?.slots(for: target.key.modelSHA256).map { ownerPinned ?? $0 }
        let storedSlots = store.priorGrant(for: target.key).map { min(ownerPinned ?? $0, $0) }
        guard let prior = [provisionalSlots, storedSlots].compactMap({ $0 }).filter({ $0 > 1 }).max() else {
            return nil
        }
        let slots = min(prior, target.maxRows)
        return .init(
            state: .granted(slots: slots),
            servedSlots: slots,
            report: .init(decision: "prior_grant_pending_recheck", servedSlots: slots, verifiedSlots: 1, key: target.key)
        )
    }
}

/// Stored self-check state, keyed by `ContinuousBatchingSelfCheckKey`. A
/// private (0600, owner-only, no symlinks) JSON file next to the provider
/// config. Progress is written before each step, so a step that kills the
/// process (e.g. a Metal OOM at a high slot count) is found on restart and
/// never retried on the same key.
struct ContinuousBatchingSelfCheckStore: Sendable {
    static let schemaVersion = "macprovider.cb-self-check.v6"
    static let fileName = "cb-self-check.json"
    static let maxEntries = 64
    static let maxFileBytes: off_t = 8 << 20
    /// v5 (an earlier candidate) decodes as v6: v6 only adds the optional
    /// crash boundary, and an unfinished v5 step is still recovered as a crash.
    static let readableSchemaVersions: Set<String> = [schemaVersion, "macprovider.cb-self-check.v5"]

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
        /// Consecutive clear no-gain results while keeping a prior grant.
        var noGainStreak: Int = 0
        /// Kept prior grant: re-measure after this time (RFC 3339).
        var remeasureAfter: String?
        /// Lowest width that crashed the process on this key; it and every
        /// wider count are never measured again on this key.
        var crashedSlots: Int?
        /// A re-measurement of a kept grant is under way (resumable).
        var remeasureInProgress: Bool?

        enum CodingKeys: String, CodingKey {
            case key
            case decision
            case serialTPS = "serial_tps"
            case measurements
            case aloneOutputs = "alone_outputs"
            case inProgressSlots = "in_progress_slots"
            case decidedAt = "decided_at"
            case noGainStreak = "no_gain_streak"
            case remeasureAfter = "remeasure_after"
            case crashedSlots = "crashed_slots"
            case remeasureInProgress = "remeasure_in_progress"
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

    /// The largest stored grant for this model on this hardware under any
    /// other runtime identity (older Metal library, kernel or macOS build):
    /// a Mac that already batched this model keeps batching through an update.
    func priorGrant(for key: ContinuousBatchingSelfCheckKey) -> Int? {
        read().filter {
            $0.key != key && $0.key.modelSHA256 == key.modelSHA256 && $0.key.hardwareClass == key.hardwareClass
        }.compactMap { $0.decision?.slots }.filter { $0 > 1 }.max()
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
        // Non-blocking so a FIFO planted at the path cannot hang the open;
        // the descriptor is then checked to be a small owner-only file.
        let fd = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) }
        guard fd >= 0 else { return [] }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_uid == getuid(),
              (st.st_mode & 0o022) == 0,
              st.st_size <= Self.maxFileBytes,
              let data = try? handle.readToEnd(),
              let document = try? JSONDecoder().decode(Document.self, from: data),
              Self.readableSchemaVersions.contains(document.schemaVersion)
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

/// Runs the self-check in the background of `serve`: applies a stored
/// decision at once, and otherwise measures one slot count at a time only
/// while no request is in flight, abandoning a step the moment one arrives.
/// Every slot count from 2 up is checked for row isolation (a grant covers
/// every row count below it); throughput repeats run on the R009 ladder
/// rungs. Progress persists, a step is journaled before any inference runs
/// and is never retried after it crashed the process, deferrals back off, and
/// throughput noise never takes a grant from a Mac that already batches
/// (`ContinuousBatchingSelfCheck.reconcile`). Never blocks serving.
actor ContinuousBatchingSelfCheckDriver {
    struct Provisional: Sendable, Equatable {
        /// Model artifacts with a signed positive policy entry (the served
        /// model and any warm-swap target).
        let modelSHA256s: Set<String>
        let slots: Int

        init(modelSHA256s: Set<String>, slots: Int) {
            self.modelSHA256s = modelSHA256s
            self.slots = slots
        }

        init(modelSHA256: String, slots: Int) {
            self.init(modelSHA256s: [modelSHA256], slots: slots)
        }

        func slots(for modelSHA256: String) -> Int? {
            modelSHA256s.contains(modelSHA256) ? slots : nil
        }
    }

    private let runtime: ModelRuntime
    private let providerStatus: ProviderStatus
    private let store: ContinuousBatchingSelfCheckStore
    /// Owner-pinned served slots: the check decides batching on/off and may
    /// only lower the pin to the verified slot count.
    private let ownerPinnedSlots: Int?
    /// A signed provisional grant, bound to its model artifact.
    private let provisional: Provisional?
    private let idleSeconds: Double
    private let pollSeconds: Double
    private let log: @Sendable (String) -> Void
    private var deferrals = 0
    private var nextAttemptAt = Date.distantPast

    static let repeats = 3

    init(
        runtime: ModelRuntime,
        providerStatus: ProviderStatus,
        store: ContinuousBatchingSelfCheckStore,
        ownerPinnedSlots: Int?,
        provisional: Provisional? = nil,
        idleSeconds: Double = 10,
        pollSeconds: Double = 5,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.runtime = runtime
        self.providerStatus = providerStatus
        self.store = store
        self.ownerPinnedSlots = ownerPinnedSlots
        self.provisional = provisional
        self.idleSeconds = idleSeconds
        self.pollSeconds = max(0.1, pollSeconds)
        self.log = log
    }

    /// The grant this Mac already serves for `key`'s model: a signed
    /// provisional grant for the same artifact, or a stored grant under an
    /// older runtime identity on the same hardware.
    private func priorGrant(for key: ContinuousBatchingSelfCheckKey) -> Int? {
        let provisionalSlots = provisional?.slots(for: key.modelSHA256)
        return [provisionalSlots, store.priorGrant(for: key)].compactMap { $0 }.filter { $0 > 1 }.max()
    }

    func run() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(pollSeconds * 1_000_000_000))
            guard let target = await runtime.continuousBatchingSelfCheckTarget(includeDecided: true) else { continue }
            let pending = await runtime.continuousBatchingSelfCheckState() == .pending
            let record = store.record(for: target.key)
            if let record, let crashed = record.inProgressSlots {
                // The previous process died inside this step (including a
                // re-measurement of a kept grant): never retry that width.
                log("event=cb_self_check action=crash_recovered slots=\(crashed)")
                await finish(record, crashedAt: crashed, target: target)
                continue
            }
            if let record, let decision = record.decision {
                if pending { await apply(decision, target: target, source: "stored") }
                if let due = record.remeasureAfter.flatMap(Self.parseDate), Date() >= due,
                   Date() >= nextAttemptAt, await isIdle() {
                    await measure(target, remeasureOf: record)
                }
                continue
            }
            if pending, let prior = priorGrant(for: target.key) {
                // Keep batching at the prior grant while this runtime
                // identity is qualified; correctness can still lower it.
                await apply(
                    .init(slots: prior, reason: "prior_grant_pending_recheck", verifiedSlots: prior),
                    target: target,
                    source: "prior_grant"
                )
            }
            guard Date() >= nextAttemptAt, await isIdle() else { continue }
            await measure(target, remeasureOf: nil)
        }
    }

    private static func parseDate(_ value: String) -> Date? { ISO8601DateFormatter().date(from: value) }

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

    /// Persists progress; a step never runs unless its journal entry is durable.
    private func save(_ record: ContinuousBatchingSelfCheckStore.Record) throws {
        do { try store.store(record) } catch {
            log("event=cb_self_check action=store_failed error=\(error)")
            throw error
        }
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted.count % 2 == 1
            ? sorted[sorted.count / 2]
            : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }

    private func measure(
        _ target: ContinuousBatchingSelfCheckTarget,
        remeasureOf previous: ContinuousBatchingSelfCheckStore.Record?
    ) async {
        let runtime = runtime
        let crashBound = (previous ?? store.record(for: target.key))?.crashedSlots.map { $0 - 1 } ?? Int.max
        let maxSlots = min(ownerPinnedSlots.map { min($0, target.maxRows) } ?? target.maxRows, crashBound)
        let rungs = Set(ContinuousBatchingSelfCheck.ladder(maxRows: maxSlots))
        var record: ContinuousBatchingSelfCheckStore.Record
        if let previous {
            // A kept grant is re-measured; its decision and no-gain streak
            // carry until the new result is reconciled. A re-measurement that
            // yielded to traffic resumes where it stopped.
            record = previous
            if previous.remeasureInProgress != true {
                record.measurements = []
                record.serialTPS = 0
                record.remeasureInProgress = true
            }
        } else {
            record = store.record(for: target.key) ?? .init(
                key: target.key, decision: nil, serialTPS: 0, measurements: [], aloneOutputs: [], inProgressSlots: nil, decidedAt: nil
            )
        }
        guard maxSlots >= 2 else {
            record.decision = .init(slots: 1, reason: "single_row", verifiedSlots: 1)
            try? save(record)
            await apply(record.decision!, target: target, source: "measured")
            return
        }
        if previous == nil, await runtime.continuousBatchingSelfCheckState() == .pending {
            await report(decision: deferrals > 0 ? "deferred" : "pending", target: target)
        }
        log("event=cb_self_check action=step max_slots=\(maxSlots) resumed_at=\(record.measurements.count) remeasure=\(previous != nil) model_sha256=\(target.key.modelSHA256)")
        do {
            let tokens = ContinuousBatchingSelfCheck.maxOutputTokens
            // Scheduler request ids are idempotency keys; never reuse one.
            let attempt = UUID().uuidString.prefix(8).lowercased()
            let prompts = try await runtime.continuousBatchingSelfCheckPrompts(
                ContinuousBatchingSelfCheck.promptTexts(count: maxSlots)
            )
            // Warm the stock serial path once so its first run is not counted.
            // Journaled like any width, so a process-killing warm-up is not
            // repeated on every restart.
            if let first = (2...maxSlots).first(where: { width in !record.measurements.contains { $0.slots == width } }) {
                record.inProgressSlots = first
                try save(record)
            }
            _ = try await yieldingToRequests {
                try await runtime.continuousBatchingSelfCheckSerialTPS(prompts: [prompts[0]], maxTokens: 8)
            }
            for slots in 2...maxSlots where !record.measurements.contains(where: { $0.slots == slots }) {
                // Journal before any inference for this width, alone runs included.
                record.inProgressSlots = slots
                try save(record)
                while record.aloneOutputs.count < slots {
                    let index = record.aloneOutputs.count
                    let row = try await yieldingToRequests {
                        try await runtime.runContinuousBatchingSelfCheckBatch(
                            prompts: [prompts[index]], maxOutputTokens: tokens, idPrefix: "cb-self-check-\(attempt)-alone-\(index)"
                        )
                    }
                    record.aloneOutputs.append(row.outputs[0])
                }
                // Rungs: repeats of stock serial then batched, back to back on
                // the same prompts; the gain is the median ratio. Other widths:
                // one batch for isolation only.
                let isRung = rungs.contains(slots)
                let batchPrompts = Array(prompts.prefix(slots))
                let serialPrompts = Array(batchPrompts.prefix(ContinuousBatchingSelfCheck.serialBaselinePrompts))
                var passes: [(outputs: [[Int]], seconds: Double)] = []
                var ratios: [Double] = []
                var aggregates: [Double] = []
                var serials: [Double] = []
                for pass in 0..<(isRung ? Self.repeats : 1) {
                    let serial: Double
                    if isRung {
                        serial = try await yieldingToRequests {
                            try await runtime.continuousBatchingSelfCheckSerialTPS(prompts: serialPrompts, maxTokens: tokens)
                        }
                    } else {
                        serial = 0
                    }
                    let batch = try await yieldingToRequests {
                        try await runtime.runContinuousBatchingSelfCheckBatch(
                            prompts: batchPrompts, maxOutputTokens: tokens, idPrefix: "cb-self-check-\(attempt)-k\(slots)-p\(pass)"
                        )
                    }
                    passes.append(batch)
                    let generated = batch.outputs.reduce(0) { $0 + $1.count }
                    let aggregate = batch.seconds > 0 ? Double(generated) / batch.seconds : 0
                    aggregates.append(aggregate)
                    if serial > 0 {
                        serials.append(serial)
                        ratios.append(aggregate / serial)
                    }
                }
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
                let gain = Self.median(ratios)
                let aggregate = Self.median(aggregates)
                if isRung { record.serialTPS = max(record.serialTPS, Self.median(serials)) }
                record.measurements.append(.init(
                    slots: slots, conformant: conformant, nearTieRows: nearTieRows, aggregateTPS: aggregate,
                    gain: gain, throughputMeasured: isRung
                ))
                record.inProgressSlots = nil
                try save(record)
                log("event=cb_self_check action=measured slots=\(slots) rung=\(isRung) conformant=\(conformant) divergent_rows=\(divergences.isEmpty ? "none" : divergences.joined(separator: ",")) aggregate_tps=\(String(format: "%.1f", aggregate)) serial_tps=\(String(format: "%.1f", Self.median(serials))) gain=\(String(format: "%.2f", gain))")
                if !conformant { break }
            }
            deferrals = 0
            nextAttemptAt = .distantPast
            await finish(record, crashedAt: nil, target: target)
        } catch {
            // Yielded to a real request, a transient failure, or a journal
            // write failure: completed widths are kept, the interrupted one
            // was not completed (not a crash), and the next attempt waits
            // longer each time. A kept or prior grant stays applied.
            record.inProgressSlots = nil
            try? save(record)
            deferrals += 1
            let wait = ContinuousBatchingSelfCheck.deferralBackoffSeconds(deferrals: deferrals, base: pollSeconds)
            nextAttemptAt = Date().addingTimeInterval(wait)
            if previous == nil, await runtime.continuousBatchingSelfCheckState() == .pending {
                await report(decision: "deferred", target: target)
            }
            log("event=cb_self_check action=deferred deferrals=\(deferrals) retry_in_s=\(Int(wait)) reason=\(error is StepError ? "request_in_flight" : "step_failed error=\(String(describing: error).prefix(200))")")
        }
    }

    private func finish(
        _ record: ContinuousBatchingSelfCheckStore.Record,
        crashedAt: Int?,
        target: ContinuousBatchingSelfCheckTarget
    ) async {
        // A swap during the measurement changes the target; drop the result.
        guard await runtime.continuousBatchingSelfCheckTarget(includeDecided: true) == target else { return }
        let fresh = ContinuousBatchingSelfCheck.decide(
            serialTPS: record.serialTPS, measurements: record.measurements, crashedAt: crashedAt
        )
        let priorGrant = [record.decision?.slots, priorGrant(for: target.key)]
            .compactMap { $0 }.filter { $0 > 1 }.max()
        let reconciled = ContinuousBatchingSelfCheck.reconcile(
            fresh: fresh,
            priorGrant: priorGrant,
            serialTPS: record.serialTPS,
            measurements: record.measurements,
            previousStreak: record.noGainStreak
        )
        var final = record
        final.decision = reconciled.decision
        final.noGainStreak = reconciled.streak
        final.remeasureAfter = reconciled.remeasureAfterSeconds.map {
            ISO8601DateFormatter().string(from: Date().addingTimeInterval($0))
        }
        if let crashedAt {
            final.crashedSlots = min(record.crashedSlots ?? crashedAt, crashedAt)
        }
        final.inProgressSlots = nil
        final.remeasureInProgress = nil
        final.decidedAt = ISO8601DateFormatter().string(from: Date())
        try? save(final)
        if reconciled.decision != fresh {
            log("event=cb_self_check action=kept_prior_grant fresh_reason=\(fresh.reason) fresh_slots=\(fresh.slots) prior_slots=\(priorGrant ?? 0) kept_slots=\(reconciled.decision.slots) no_gain_streak=\(reconciled.streak)")
        }
        await apply(reconciled.decision, target: target, source: crashedAt == nil ? "measured" : "crash_recovered")
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
        // Fenced on the swap generation: state, report, gates and advertised
        // capacity move together or not at all.
        let report = ContinuousBatchingSelfCheckReport(
            decision: decision.reason,
            servedSlots: slots,
            verifiedSlots: decision.verifiedSlots,
            deferrals: deferrals,
            key: target.key
        )
        guard await runtime.applyContinuousBatchingSelfCheck(
            decision.state, servedSlots: slots, expected: target, report: report, publishCapacity: true
        ) else {
            log("event=cb_self_check action=apply_skipped reason=target_changed")
            return
        }
        log("event=cb_self_check action=applied source=\(source) reason=\(decision.reason) slots=\(slots) verified_k=\(decision.verifiedSlots) model_sha256=\(target.key.modelSHA256)")
    }
}
