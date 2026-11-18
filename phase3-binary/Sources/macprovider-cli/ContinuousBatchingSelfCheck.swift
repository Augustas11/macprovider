import CryptoKit
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
///   at an exact tie (both tokens the stock serial top two within
///   `nearTieLogitTolerance`), at every k up to the one granted (kernel
///   shapes change with the row count, e.g. MLX quantized matmul switches
///   from `qmv` to `qmm` at the device's vector limit). The exactness probe
///   (v0.3.19) submits rows of unequal key lengths on both sides of the
///   device's vector-attention route boundary, holds them until all of them
///   decode together, and requires every row to have decoded at least
///   `minimumCohortDecodeTokens` tokens beside the whole cohort. On the stock
///   order small-row route a width from three rows compares each row with
///   its prompt run three times together instead of alone
///   (`usesSameOrderReference`);
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
    /// The scheduler's waiting-queue limit. A probe submits all of its rows
    /// at once, so a width above it is refused with backpressure before any
    /// row runs; the ladder stops at it.
    var queueLimit: Int = .max
    /// The runtime's swap generation: a result measured before a swap never
    /// applies after it, even to the same model.
    var generation: Int = 0
    /// Key length at which a decode row leaves the device's one-pass vector
    /// attention kernel (`ContinuousBatchingSelfCheck.routeKeyBoundary`).
    var probeKeyBoundary: Int = 1024
    /// The scheduler's per-request token cap (the served context) and its
    /// paged-KV pool: the exactness probe's rows must fit both, all at once.
    var maxRequestTokens: Int = .max
    var poolTokens: Int = .max
    /// The pool's block size: each probe row reserves whole blocks.
    var blockSizeTokens: Int = 16
    /// SPEC-038 FR-CB10 v0.3.21, `glm5_next` only: the throughput gain
    /// compares decode rates (cohort decode span vs stock serial tokens after
    /// the first), because its slow prefill dominates the short-prompt
    /// passes. False keeps the end-to-end measurement every other family has.
    var decodeOnlyGain: Bool = false
    /// SPEC-038 FR-CB11 (v0.3.22): the signed policy's `max_served_slots` for
    /// this model artifact. Nil: no policy ceiling.
    var policyCeiling: Int? = nil
    /// SPEC-038 FR-CB9: the small-row route of the process that checks. On
    /// stock order, widths from three rows compare with same-order
    /// references (`ContinuousBatchingSelfCheck.usesSameOrderReference`).
    var smallMRoute: SmallMRoute = .rowInvariant

    /// The most slots any grant may serve on this target: the scheduler rows,
    /// queue limit and signed policy ceiling, capped by the widest
    /// exactness-probe shape they hold
    /// (`ContinuousBatchingSelfCheck.exactnessProbeBound`). A stored, prior or
    /// provisional grant above it is served only up to it.
    var grantableRows: Int {
        let configured = max(1, min(maxRows, queueLimit, policyCeiling ?? .max))
        return min(configured, ContinuousBatchingSelfCheck.exactnessProbeBound(target: self, maxCount: configured))
    }
}

/// One self-check batch through the scheduler: each row's tokens, the wall
/// time from submission to the last row's end, and for a cohort run each
/// row's decode tokens beside the whole cohort and those steps' seconds.
struct ContinuousBatchingSelfCheckBatchRun: Sendable, Equatable, Codable {
    let outputs: [[Int]]
    let seconds: Double
    let cohortDecodeTokens: [Int]
    var cohortDecodeSeconds: [Double] = []
}

/// The stock serial baseline over the self-check prompts: end-to-end
/// tokens/s (the gain denominator) and decode-only tokens/s (the denominator
/// for a `decodeOnlyGain` target, SPEC-038 v0.3.21).
struct ContinuousBatchingSelfCheckSerialRate: Sendable, Equatable, Codable {
    let decodeTPS: Double
    let endToEndTPS: Double
}

struct ContinuousBatchingSelfCheckMeasurement: Sendable, Equatable, Codable {
    let slots: Int
    /// Every row equals its prompt run alone, or first differs only at a
    /// numerical near-tie (`continuousBatchingSelfCheckDivergenceIsNearTie`).
    let conformant: Bool
    /// Rows that differed only at a near-tie.
    var nearTieRows: Int = 0
    /// Batched aggregate tokens/s (for a `decodeOnlyGain` target, v0.3.21:
    /// the cohort's decode tokens over the common span all rows decoded in).
    let aggregateTPS: Double
    /// Median over repeats of batched aggregate / stock serial tokens/s,
    /// each repeat measured back to back on the same prompts. 0
    /// means "use aggregateTPS over the record's serial baseline".
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
    /// `serial_baseline_unavailable`, `crashed_at_<k>`, `single_row`,
    /// `probe_shape_unavailable`, `probe_shape_unmet_at_<k>`.
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
    public let decodeWindow: Int?

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
        self.decodeWindow = key?.decodeWindow
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
            "decode_window": decodeWindow.map { $0 as Any } ?? NSNull(),
        ]
    }
}

enum ContinuousBatchingSelfCheck {
    /// SPEC-038 FR-CB14 MSB-03 bar: batching must beat serial by more than 20%.
    static let minimumAggregateGain = 1.2
    /// Lowest slot count within this fraction of the best aggregate wins. Widths
    /// reaching selection are already memory-bounded (AutoServedSlots) and verified
    /// exact, so the band only absorbs measurement noise (~0.3% same-window); the
    /// calibrator's own 0.15 tie band is unchanged for its other uses.
    static let widthSelectionNoiseBand = 0.03
    static let maxOutputTokens = 48
    static let serialBaselinePrompts = 4

    /// SPEC-038 FR-CB10 (v0.3.19): the widest logit gap at which a batched
    /// row may first differ from its lone run. Batched and lone rows of the
    /// same paged engine are bit-identical under the FR-CB2 row bound (Studio,
    /// 256/256 rows and steps), so a flip means their logits differ; the
    /// pre-bound flips the old 1.0 rule accepted sat at 0.125, one bfloat16
    /// step at logits of 16-32. 1/1024 is below one bfloat16 step at any
    /// logit of magnitude 0.25 or more, so only an exact tie (in float32, a
    /// rounding-level one) passes, and it is counted.
    static let nearTieLogitTolerance: Float = 1.0 / 1024
    /// Probe definition stamped into the stored key
    /// (`ModelRuntime.continuousBatchingSelfCheckRuntimeBuild`): a result
    /// measured by an older probe re-runs, and its grant carries the Mac
    /// through the re-run.
    static let probeVersion = "cb-probe-v2"
    /// `glm5_next` targets only (SPEC-038 v0.3.21, `decodeOnlyGain`): their
    /// gain compares decode rates, so their key carries this version instead.
    /// Every other family keeps `probeVersion` and its stored results.
    static let glm5NextProbeVersion = "cb-probe-v3"
    /// Decode tokens every exactness-probe row must generate while its whole
    /// cohort decodes (at least one serve window).
    static let minimumCohortDecodeTokens = 16

    /// max(16, serve window), the window counted up to 4096.
    /// SPEC-038 FR-CB10 (v0.3.21) batched aggregate decode tokens/s: every
    /// row's decode tokens beside the whole cohort over the common wall-clock
    /// span those steps took (rows of one cohort share it; the longest row's
    /// span is taken), so prefill and admission are not in the timed span,
    /// as in the stock serial denominator. 0 when no row decoded beside the
    /// whole cohort.
    static func cohortDecodeTPS(tokens: [Int], seconds: [Double]) -> Double {
        let total = tokens.reduce(0) { $0 + max(0, $1) }
        let span = seconds.filter(\.isFinite).max() ?? 0
        guard total > 0, span > 0 else { return 0 }
        return Double(total) / span
    }

    static func requiredCohortDecodeTokens(decodeWindow: Int) -> Int {
        max(minimumCohortDecodeTokens, min(decodeWindow, 4_096))
    }

    /// Exactness-probe completion length: the first token comes from
    /// prefill, so one more than the required cohort decode tokens.
    static func exactnessOutputTokens(decodeWindow: Int) -> Int {
        max(maxOutputTokens, requiredCohortDecodeTokens(decodeWindow: decodeWindow) + 1)
    }

    /// The smallest key length at which a GQA decode row takes the two-pass
    /// vector attention kernel on `architecture`, from the FR-CB2 route table
    /// (1024 on Max/Ultra-class GPUs, 4096 on the others).
    static func routeKeyBoundary(architecture: String) -> Int {
        (1 ... 65_536).first { keys in
            PagedKVVectorAttentionRoute.route(
                keyTokens: keys, queryTokens: 1, queryHeads: 16, kvHeads: 2, headDim: 128, valueDim: 128,
                hasArrayMask: false, architecture: architecture, partitionOverride: nil
            )?.twoPass == true
        } ?? 1024
    }

    static let deviceRouteKeyBoundary = routeKeyBoundary(architecture: PagedKVVectorAttentionRoute.deviceArchitecture)

    /// Prompt length of exactness-probe row `index`, in tokens. Rows repeat
    /// short, long (past the route boundary), crossing (starts below it and
    /// crosses it mid-completion) and mid, each a little longer than the last
    /// of its kind, so every k from 2 has rows on both sides of the boundary
    /// and no two rows of a kind share a length. Above 1024, long and crossing
    /// rows after the first of each become short or mid rows, so 8 GB Macs
    /// stay within their pool. The 16384-key partition boundary is not
    /// crossed: the qmv/qmm switch depends on the row count, not the key
    /// length; per-row attention already gives every row its own route
    /// (Studio: 256/256 bitwise at 300-16,380 keys with the row bound), and
    /// a 16k prompt per row is more KV and prefill than an 8 GB Mac's pool
    /// holds at its row count.
    static func exactnessPromptLength(index: Int, keyBoundary: Int, outputTokens: Int) -> Int {
        let round = index / 4
        let firstRound = round == 0 || keyBoundary <= 1024
        let half = max(1, outputTokens / 2)
        switch index % 4 {
        case 1 where firstRound:
            return keyBoundary + keyBoundary / 8 + 8 * index
        case 2 where firstRound:
            return keyBoundary - half + round % half
        case 0, 2:
            return 160 + 8 * index
        default:
            return keyBoundary / 4 + 8 * index
        }
    }

    static func exactnessPromptLengths(count: Int, keyBoundary: Int, outputTokens: Int) -> [Int] {
        (0 ..< max(0, count)).map {
            exactnessPromptLength(index: $0, keyBoundary: keyBoundary, outputTokens: outputTokens)
        }
    }

    /// Pool tokens one probe row may take: its prompt, completion and the
    /// scheduler's decode headroom, rounded up to whole blocks. Nil on
    /// overflow.
    static func exactnessRowCost(promptTokens: Int, outputTokens: Int, blockSizeTokens: Int = 16) -> Int? {
        let block = max(1, blockSizeTokens)
        let (withOutput, outputOverflow) = promptTokens.addingReportingOverflow(outputTokens)
        let (tokens, headroomOverflow) = withOutput.addingReportingOverflow(
            ContinuousBatchSchedulerConfiguration.defaultDecodeHeadroomTokens
        )
        guard !outputOverflow, !headroomOverflow, tokens >= 0 else { return nil }
        let (blocks, blocksOverflow) = (tokens / block + (tokens % block == 0 ? 0 : 1)).multipliedReportingOverflow(by: block)
        return blocksOverflow ? nil : blocks
    }

    /// The widest k (at most `maxCount`) whose full exactness-probe shape fits
    /// the target: every row within the per-request cap and all rows at once
    /// within the pool. 1 when not even two rows fit. Fail closed: no width
    /// above it is probed, so none is verified or granted.
    static func exactnessProbeBound(target: ContinuousBatchingSelfCheckTarget, maxCount: Int) -> Int {
        let outputTokens = exactnessOutputTokens(decodeWindow: target.key.decodeWindow)
        var total = 0
        var bound = 0
        for length in exactnessPromptLengths(
            count: maxCount, keyBoundary: target.probeKeyBoundary, outputTokens: outputTokens
        ) {
            let (rowTokens, rowOverflow) = length.addingReportingOverflow(outputTokens)
            guard !rowOverflow, rowTokens <= target.maxRequestTokens,
                  let cost = exactnessRowCost(
                      promptTokens: length, outputTokens: outputTokens, blockSizeTokens: target.blockSizeTokens
                  )
            else { break }
            let (sum, sumOverflow) = total.addingReportingOverflow(cost)
            guard !sumOverflow, sum <= target.poolTokens else { break }
            total = sum
            bound += 1
        }
        return max(1, bound)
    }

    /// SPEC-038 FR-CB10 (stock order): the widest k at most
    /// `exactnessProbeBound` whose same-order references all fit: for every
    /// row i < k, `sameOrderReferenceRows` copies of probe prompt i together
    /// within the pool. Widths 1 and 2 need no reference, so the result is
    /// at least min(2, the probe bound). The ladder on stock order stops
    /// here; the grant bound (`exactnessProbeBound`) does not change.
    static func stockOrderReferenceBound(target: ContinuousBatchingSelfCheckTarget, maxCount: Int) -> Int {
        let bound = exactnessProbeBound(target: target, maxCount: maxCount)
        guard bound >= sameOrderReferenceRows else { return bound }
        let outputTokens = exactnessOutputTokens(decodeWindow: target.key.decodeWindow)
        var fit = 0
        for length in exactnessPromptLengths(
            count: maxCount, keyBoundary: target.probeKeyBoundary, outputTokens: outputTokens
        ).prefix(bound) {
            guard let cost = exactnessRowCost(
                promptTokens: length, outputTokens: outputTokens, blockSizeTokens: target.blockSizeTokens
            ) else { break }
            let (copies, overflow) = cost.multipliedReportingOverflow(by: sameOrderReferenceRows)
            guard !overflow, copies <= target.poolTokens else { break }
            fit += 1
        }
        return fit >= sameOrderReferenceRows ? fit : min(2, bound)
    }

    /// Exactness-probe texts: the task first, then background notes long
    /// enough to cut to `lengths` tokens (`fitPrompt`).
    static func exactnessTexts(lengths: [Int]) -> [String] {
        let tasks = promptTexts(count: lengths.count).map { text -> String in
            guard let range = text.range(of: "answer this: ") else { return text }
            return String(text[range.upperBound...])
        }
        return zip(tasks, lengths).enumerated().map { index, pair in
            let paragraphs = pair.1 / 50 + 4
            let notes = (0 ..< paragraphs).map { contextParagraph($0 + 7 * index) }.joined(separator: "\n\n")
            return "Answer this: \(pair.0)\n\nBackground notes, to be ignored:\n\n\(notes)"
        }
    }

    /// Tokens two chat-templated prompts share at their end (the template's
    /// closing tokens), at most `limit`.
    static func commonSuffixLength(_ lhs: [Int], _ rhs: [Int], limit: Int = 64) -> Int {
        var count = 0
        while count < min(limit, lhs.count, rhs.count), lhs[lhs.count - 1 - count] == rhs[rhs.count - 1 - count] {
            count += 1
        }
        return count
    }

    /// `tokens` cut to exactly `length`: its head, then its last `tail`
    /// tokens (the template's close), or nil when it is too short.
    static func fitPrompt(_ tokens: [Int], tail: Int, length: Int) -> [Int]? {
        guard tail >= 0, length > tail, tokens.count >= length else { return nil }
        return Array(tokens.prefix(length - tail)) + Array(tokens.suffix(tail))
    }

    static func promptSHA256(_ tokens: [Int]) -> String {
        let bytes = tokens.flatMap { token -> [UInt8] in
            withUnsafeBytes(of: Int64(token).littleEndian) { Array($0) }
        }
        return SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    /// The prefix of stored lone outputs that still belongs to `prompts`:
    /// each generated from the prompt with the same SHA-256, of exactly
    /// `outputTokens` non-negative tokens.
    static func reusableLoneOutputs(
        _ outputs: [[Int]],
        digests: [String],
        prompts: [[Int]],
        outputTokens: Int
    ) -> [[Int]] {
        var reusable: [[Int]] = []
        for (index, output) in outputs.enumerated() {
            guard index < digests.count, index < prompts.count,
                  digests[index] == promptSHA256(prompts[index]),
                  output.count == outputTokens, output.allSatisfy({ $0 >= 0 })
            else { break }
            reusable.append(output)
        }
        return reusable
    }

    /// SPEC-038 FR-CB10: whether a batched row's first divergence from its
    /// lone run is excused, judged against the stock serial logits of the
    /// shared prefix with the load-time isolation probe's rule
    /// (`PagedKVRuntimeParityProbe.batchedTokenIsConformant`, other-row leak
    /// guard) at `tolerance`: both tokens the serial top two and their gap at
    /// most `tolerance`. Returns the gap for the evidence log.
    static func divergenceVerdict(
        reference: PagedKVRuntimeParityProbe.SerialReference,
        aloneToken: Int,
        batchedToken: Int,
        otherRowsAloneTokens: [Int],
        tolerance: Float = nearTieLogitTolerance
    ) -> (nearTie: Bool, margin: Float?, reason: String) {
        let logits = reference.logits
        let margin: Float? = logits.indices.contains(aloneToken) && logits.indices.contains(batchedToken)
            ? abs(logits[aloneToken] - logits[batchedToken])
            : nil
        let leaked = batchedToken != reference.top1 && otherRowsAloneTokens.contains(batchedToken)
        let batchedConformant = !leaked && PagedKVRuntimeParityProbe.batchedTokenIsConformant(
            decoded: batchedToken, own: reference, otherRowSerialTop1: nil, tolerance: tolerance
        )
        let aloneConformant = PagedKVRuntimeParityProbe.batchedTokenIsConformant(
            decoded: aloneToken, own: reference, otherRowSerialTop1: nil, tolerance: tolerance
        )
        if leaked { return (false, margin, "other_row_token") }
        if !batchedConformant { return (false, margin, "batched_outside_serial_top2") }
        if !aloneConformant { return (false, margin, "alone_outside_serial_top2") }
        guard let margin, margin <= tolerance else { return (false, margin, "margin_above_tolerance") }
        return (true, margin, "near_tie")
    }

    /// SPEC-038 FR-CB10 (stock order): identical rows run together to make
    /// one prompt's same-order reference.
    static let sameOrderReferenceRows = 3

    /// Whether width `slots` compares each row with its prompt's same-order
    /// reference instead of its lone run. On stock order a lone row and a
    /// two-row forward share one reduction order and forwards of 3-16 rows
    /// share another (the batch kernel), so from three rows the lone run is
    /// not the row's reference. The row-invariant route keeps one order for
    /// 1-16 rows and always compares with lone runs.
    static func usesSameOrderReference(route: SmallMRoute, slots: Int) -> Bool {
        route == .stockOrder && slots >= sameOrderReferenceRows
    }

    /// Row 0 of a same-order reference run (`sameOrderReferenceRows`
    /// identical rows decoded together), or nil when the run has another row
    /// count or its rows differ: rows of one batch-kernel forward must be
    /// bit-identical, so a difference fails the width on its own.
    static func sameOrderReference(_ outputs: [[Int]]) -> [Int]? {
        guard outputs.count == sameOrderReferenceRows, let first = outputs.first,
              outputs.allSatisfy({ $0 == first })
        else { return nil }
        return first
    }

    /// The reference each row of width `slots` is compared with: the
    /// same-order references where `usesSameOrderReference`, else the lone
    /// runs.
    static func rowReferences(route: SmallMRoute, slots: Int, lone: [[Int]], sameOrder: [[Int]]) -> [[Int]] {
        Array((usesSameOrderReference(route: route, slots: slots) ? sameOrder : lone).prefix(slots))
    }

    /// SPEC-038 FR-CB10 (stock order, from three rows): whether every row of
    /// a cohort run decoded each of its tokens in a step that held the whole
    /// cohort and nothing else (`cohortDecodeTokens` equals the row's tokens
    /// after the prefill token). Only then is each row's forward, and so its
    /// kernel order, fixed for its whole run: the cohort's row set, its
    /// admission order and the positional row-bound split are all constant.
    /// A run where any row also decoded in a narrower step (the cohort hold
    /// released early) may mix orders mid-run; it is judged neither way and
    /// its width is a shape not met.
    static func cohortRowsRanInOneOrder(outputs: [[Int]], cohortDecodeTokens: [Int]) -> Bool {
        !outputs.isEmpty && outputs.count == cohortDecodeTokens.count
            && zip(outputs, cohortDecodeTokens).allSatisfy { !$0.isEmpty && $1 == $0.count - 1 }
    }

    /// Each distinct (row, output) of `passes` that differs from the row's
    /// reference and, when one is given, from the row's exact alternate. On
    /// stock order the alternate of a width from three rows is the lone run:
    /// a row the FR-CB2 decode row bound split into a forward of one or two
    /// rows decodes in the lone row's order. `countMismatch`: a pass with
    /// another row count than `references`.
    static func rowsDifferingFromReference(
        passes: [[[Int]]],
        references: [[Int]],
        exactAlternates: [[Int]] = []
    ) -> (rows: [(row: Int, pair: ([Int], [Int]))], countMismatch: Bool) {
        var rows: [(row: Int, pair: ([Int], [Int]))] = []
        var countMismatch = false
        for pass in passes {
            for (row, pair) in zip(pass, references).enumerated()
            where pair.0 != pair.1
                && !(exactAlternates.indices.contains(row) && pair.0 == exactAlternates[row])
                && !rows.contains(where: { $0.row == row && $0.pair.0 == pair.0 }) {
                rows.append((row, pair))
            }
            if pass.count != references.count { countMismatch = true }
        }
        return (rows, countMismatch)
    }

    /// Slot counts to measure: the R009 ladder from 2 up to `maxRows`.
    static func ladder(maxRows: Int) -> [Int] {
        AutotuneConcurrencyCalibrator.sweepDepths(upperBound: maxRows).filter { $0 >= 2 }
    }

    /// The widest count the ladder probes: the scheduler rows (the memory-fit
    /// plan), an owner pin, the width below a crashed one, the scheduler
    /// queue limit (wider probes are refused with backpressure), and the
    /// signed policy ceiling (SPEC-038 FR-CB11 v0.3.22).
    static func ladderUpperBound(
        maxRows: Int,
        ownerPinned: Int?,
        crashedSlots: Int?,
        queueLimit: Int,
        policyCeiling: Int? = nil
    ) -> Int {
        min(
            ownerPinned.map { min($0, maxRows) } ?? maxRows,
            crashedSlots.map { $0 - 1 } ?? .max,
            queueLimit,
            policyCeiling ?? .max
        )
    }

    /// The ladder bound for `target`, including the widest exactness-probe
    /// shape it can hold (`exactnessProbeBound`).
    static func ladderUpperBound(
        target: ContinuousBatchingSelfCheckTarget,
        ownerPinned: Int?,
        crashedSlots: Int?
    ) -> Int {
        let configured = ladderUpperBound(
            maxRows: target.maxRows,
            ownerPinned: ownerPinned,
            crashedSlots: crashedSlots,
            queueLimit: target.queueLimit,
            policyCeiling: target.policyCeiling
        )
        return min(configured, exactnessProbeBound(target: target, maxCount: configured))
    }

    enum BackpressureOutcome: Equatable {
        /// Nothing verified yet: an ordinary deferral.
        case deferStep
        /// Retry the same width once after the poll interval, without
        /// growing the deferral backoff (a native-MTP integrity probe can
        /// refuse a probe for a moment).
        case retrySoon
        /// Refused twice in a row, and the Mac already serves a grant wider
        /// than the verified prefix: keep that grant and resume the ladder
        /// at this width after `backpressureResumeSeconds`.
        case pause
        /// Refused twice in a row: decide on the verified prefix now and
        /// re-measure the full ladder after `backpressureResumeSeconds`.
        case endLadder
    }

    /// When a ladder stopped by backpressure is completed.
    static let backpressureResumeSeconds = remeasureBaseSeconds

    /// SPEC-038 FR-CB10: what a backpressure refusal of the check's own probe
    /// at width `slots` does, with no buyer request during the step.
    /// `verifiedPrefix` is the widest exact width so far (1 when none). It
    /// never counts as a divergence or a crash, never lowers a prior grant,
    /// and never grows the deferral backoff once a width is verified.
    static func backpressureOutcome(
        verifiedPrefix: Int,
        slots: Int,
        previousRefusalAt: Int?,
        priorGrant: Int?
    ) -> BackpressureOutcome {
        guard verifiedPrefix >= 2 else { return .deferStep }
        guard previousRefusalAt == slots else { return .retrySoon }
        if let priorGrant, priorGrant > verifiedPrefix { return .pause }
        return .endLadder
    }

    /// A decided ladder that reached its bound (every width up to it passed)
    /// runs again when the bound has grown since, e.g. a raised queue limit,
    /// more scheduler rows or a raised owner pin. A ladder stopped by a
    /// divergence, crash or backpressure below its bound does not.
    static func ladderBoundGrew(
        record: ContinuousBatchingSelfCheckStore.Record,
        currentBound: Int
    ) -> Bool {
        guard let decision = record.decision, let bound = record.ladderBound else { return false }
        return currentBound > bound && decision.verifiedSlots >= bound
    }

    /// `measurements` ascend by slots and stop after the first inexact one.
    /// `crashedAt` is a slot count whose step never finished (the process
    /// died, e.g. a Metal OOM); it is never measured again on this key.
    /// `probeShapeUnmetAt` is a width whose exactness probe could not run its
    /// full shape (its rows never all decoded together for the required
    /// tokens); it and every wider count stay unverified.
    static func decide(
        serialTPS: Double,
        measurements: [ContinuousBatchingSelfCheckMeasurement],
        crashedAt: Int? = nil,
        probeShapeUnmetAt: Int? = nil
    ) -> ContinuousBatchingSelfCheckDecision {
        let exactPrefix = Array(measurements.prefix { $0.conformant })
        let verified = exactPrefix.last?.slots ?? 1
        // With nothing verified, a divergence, a crash or an unmet probe
        // shape is the result even before a serial baseline exists, so it is
        // never read as a throughput result that keeps a prior grant.
        if exactPrefix.isEmpty {
            if let first = measurements.first {
                return .init(slots: 1, reason: "row_divergence_at_\(first.slots)", verifiedSlots: 1)
            }
            if let crashedAt {
                return .init(slots: 1, reason: "crashed_at_\(crashedAt)", verifiedSlots: 1)
            }
            if let probeShapeUnmetAt {
                return .init(slots: 1, reason: "probe_shape_unmet_at_\(probeShapeUnmetAt)", verifiedSlots: 1)
            }
        }
        guard serialTPS > 0, serialTPS.isFinite else {
            return .init(slots: 1, reason: "serial_baseline_unavailable", verifiedSlots: verified)
        }
        guard !exactPrefix.isEmpty else {
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
            minAggregateGainFraction: widthSelectionNoiseBand
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
    /// above the highest verified slot count or `maxRows` (callers pass the
    /// target's `grantableRows`, which carries the signed policy ceiling).
    static func servedSlots(
        decision: ContinuousBatchingSelfCheckDecision,
        ownerPinned: Int?,
        maxRows: Int
    ) -> Int {
        max(1, min(ownerPinned ?? decision.slots, decision.verifiedSlots, maxRows))
    }

    /// SPEC-038 FR-CB10 item 3 (v0.3.22): a check with no stored decision on
    /// its key that has been due this long without an idle window runs under
    /// an admission hold. Holds are also at least this far apart, counted
    /// from the end of the previous one.
    static let admissionHoldAfterSeconds: Double = 120
    /// Each Mac adds a random 0..15 min to the first due time so Macs that
    /// re-key together (a release) spread their holds instead of all
    /// withdrawing capacity at once.
    static let admissionHoldJitterSeconds: Double = 900
    /// The longest the check itself runs under one hold (the drain before it
    /// is bounded separately); an unfinished ladder resumes at the next idle
    /// window or hold.
    static let admissionHoldCheckSeconds: Double = 300
    /// SPEC-038 FR-CB10 item 3 (v0.3.37): a buyer admitted during a hold
    /// waits behind the check's probe; the hold yields once the oldest such
    /// buyer has waited this long behind it. About twice the ~11 s hold seen on CLI
    /// 1.8.281, so a short check finishes, and below the 30 s default
    /// scheduler queue wait.
    static let selfCheckBuyerWaitYieldSeconds: Double = 20

    /// The drain bound for a hold: the configured drain timeout, doubled after
    /// each consecutive drain timeout up to 4x, so long-running requests
    /// cannot starve the check forever while each hold stays bounded.
    static func admissionHoldDrainSeconds(base: Int, consecutiveDrainTimeouts: Int) -> Int {
        max(0, base) << min(max(0, consecutiveDrainTimeouts), 2)
    }

    /// Only a buyer drain timeout escalates the next hold's drain bound; a
    /// timeout on local work alone (SPEC-001-R011) leaves the count as is.
    static func nextConsecutiveDrainTimeouts(_ current: Int, after outcome: AdmissionHoldOutcome) -> Int {
        switch outcome {
        case .drainTimeout: return current + 1
        case .localDrainTimeout: return current
        default: return 0
        }
    }

    /// The check bound for a hold: `admissionHoldCheckSeconds`, doubled after
    /// each consecutive hold that reached it without deciding, up to 4x.
    /// Completed units persist; an individual unit must still fit the bound.
    static func admissionHoldCheckBound(base: Double, consecutiveBoundYields: Int) -> Double {
        base * Double(1 << min(max(0, consecutiveBoundYields), 2))
    }

    static func admissionHoldDue(dueSince: Date, notBefore: Date, after: Double, now: Date) -> Bool {
        now >= notBefore && now.timeIntervalSince(dueSince) >= after
    }

    enum AdmissionHoldOutcome: Equatable, Sendable {
        /// The hold did not start: a lifecycle lease, a pause, a drain, or a
        /// provider that is not serving.
        case skipped(reason: String)
        /// In-flight requests did not finish within the drain timeout, before
        /// the check or while its probe queued for residency behind them; none
        /// was cancelled and the unfinished step did not run.
        case drainTimeout
        /// SPEC-001-R011: only preempted local work was still unwinding at
        /// the drain bound. The check did not run, and the drain bound does
        /// not escalate (no buyer request caused the timeout).
        case localDrainTimeout
        /// The check stored a decision.
        case completed
        /// The check ran but yielded (a pause, drain, lease or target change)
        /// or failed; completed widths persist and the ladder resumes later.
        case yielded
        /// The check reached its bound without deciding.
        case checkBound

        var label: String {
            switch self {
            case .skipped: return "skipped"
            case .drainTimeout: return "drain_timeout"
            case .localDrainTimeout: return "local_drain_timeout"
            case .completed: return "completed"
            case .yielded: return "yielded"
            case .checkBound: return "check_bound"
            }
        }
    }

    /// SPEC-038 FR-CB10 item 3 (v0.3.22): hold admission (routing sees no free
    /// slot; a buyer that still arrives is admitted and queues behind the
    /// check, which yields once `buyerWaitSeconds` reaches
    /// `buyerWaitYieldSeconds`, v0.3.36), let the in-flight ones finish (bounded by `drainSeconds`; none is cancelled
    /// or dropped), run `check` for at most `checkSeconds`, then re-open
    /// admission. Time the probe spends queued behind buyers holding permits
    /// (`probeAwaitingResidency`) is not check time: it has its own budget of
    /// `drainSeconds` and ends as a drain timeout (v0.3.37). Never starts under a lifecycle lease, an operator pause or a
    /// drain. The hold ends early, as a yield, the moment a lease appears, the
    /// provider stops serving (a pause or drain, whose state it keeps), or
    /// `stillValid` fails (the self-check target changed); admission re-opens
    /// at the bound even if `check` has not returned yet (it is cancelled and
    /// awaited, and yields to the first buyer request). `check` returns
    /// whether it stored a decision.
    static func runUnderAdmissionHold(
        providerStatus: ProviderStatus,
        drainSeconds: Int,
        checkSeconds: Double = admissionHoldCheckSeconds,
        lifecycleLease: @escaping @Sendable () -> String?,
        stillValid: @escaping @Sendable () async -> Bool = { true },
        buyerWaitSeconds: @escaping @Sendable () async -> Double? = { nil },
        buyerWaitYieldSeconds: Double = selfCheckBuyerWaitYieldSeconds,
        probeAwaitingResidency: @escaping @Sendable () async -> Bool = { false },
        context: String,
        log: @escaping @Sendable (String) -> Void,
        check: @escaping @Sendable () async -> Bool
    ) async -> AdmissionHoldOutcome {
        await runUnderSelfCheckHold(
            scope: ProcessSelfCheckAdmissionHold(providerStatus: providerStatus),
            drainSeconds: drainSeconds, checkSeconds: checkSeconds, lifecycleLease: lifecycleLease,
            stillValid: stillValid, buyerWaitSeconds: buyerWaitSeconds, buyerWaitYieldSeconds: buyerWaitYieldSeconds,
            probeAwaitingResidency: probeAwaitingResidency, context: context, log: log, check: check)
    }

    /// The same hold over `scope`: the whole provider (the primary's check,
    /// `ProcessSelfCheckAdmissionHold`) or one further warm member
    /// (SPEC-001-R019, `WarmMemberSelfCheckAdmissionHold`).
    static func runUnderSelfCheckHold(
        scope hold: any SelfCheckAdmissionHoldScope,
        drainSeconds: Int,
        checkSeconds: Double = admissionHoldCheckSeconds,
        lifecycleLease: @escaping @Sendable () -> String?,
        stillValid: @escaping @Sendable () async -> Bool = { true },
        buyerWaitSeconds: @escaping @Sendable () async -> Double? = { nil },
        buyerWaitYieldSeconds: Double = selfCheckBuyerWaitYieldSeconds,
        probeAwaitingResidency: @escaping @Sendable () async -> Bool = { false },
        context: String,
        log: @escaping @Sendable (String) -> Void,
        check: @escaping @Sendable () async -> Bool
    ) async -> AdmissionHoldOutcome {
        let drainBound = TimeInterval(max(0, drainSeconds))
        var refusal = lifecycleLease().map { "lifecycle_lease_\($0)" }
        if refusal == nil {
            refusal = await hold.beginHold(
                expectedEndAt: Date().addingTimeInterval(drainBound * 2 + checkSeconds)
            )
        }
        if let refusal {
            await hold.noteHoldSkipped(reason: refusal)
            log("event=cb_self_check action=admission_hold_skipped reason=\(refusal) \(context)")
            return .skipped(reason: refusal)
        }
        let startedAt = Date()
        log("event=cb_self_check action=admission_hold_start in_flight=\(await hold.heldRequestsInFlight()) drain_timeout_s=\(drainSeconds) \(context)")
        let buyerWait = AdmissionHoldBuyerWait()
        /// Why the hold must end now, or nil while it may continue.
        @Sendable func interruption() async -> String? {
            if Task.isCancelled { return "cancelled" }
            // v0.3.37: a buyer waiting behind the check's residency yields
            // the hold once the oldest one has waited the bound.
            if let wait = await buyerWaitSeconds() {
                let bound = wait >= buyerWaitYieldSeconds
                if buyerWait.begin() || bound {
                    log("event=cb_self_check action=hold_buyer_waiting wait_s=\(String(format: "%.1f", wait)) bound_s=\(Int(buyerWaitYieldSeconds)) decision=\(bound ? "yield" : "wait")")
                }
                if bound { return "buyer_wait_bound" }
            } else {
                buyerWait.end()
            }
            if let lease = lifecycleLease() { return "lifecycle_lease_\(lease)" }
            if await !hold.isServingForHold() { return "provider_not_serving" }
            if await !stillValid() { return "target_changed" }
            return nil
        }
        func end(_ outcome: AdmissionHoldOutcome, reason: String? = nil) async -> AdmissionHoldOutcome {
            await hold.endHold(outcome: outcome.label)
            log("event=cb_self_check action=admission_hold_end outcome=\(outcome.label)\(reason.map { " reason=\($0)" } ?? "") held_s=\(Int(Date().timeIntervalSince(startedAt))) \(context)")
            return outcome
        }
        let drainDeadline = startedAt.addingTimeInterval(drainBound)
        let neededDrain = await hold.hasHeldWork()
        // The hold preempted admitted local work when it began; only buyer
        // work predating the hold makes a timeout a buyer drain timeout.
        var sawBuyerWork = await hold.hasBuyerWorkPredatingHold()
        // Buyers admitted during the hold are not drained: they queue behind
        // the check's probe (v0.3.36).
        while await hold.hasWorkPredatingHold(), Date() < drainDeadline {
            if let reason = await interruption() { return await end(.yielded, reason: reason) }
            try? await Task.sleep(nanoseconds: 50_000_000)
            if await hold.hasBuyerWorkPredatingHold() { sawBuyerWork = true }
        }
        if await hold.hasBuyerWorkPredatingHold() { sawBuyerWork = true }
        let timeoutOutcome: AdmissionHoldOutcome = sawBuyerWork ? .drainTimeout : .localDrainTimeout
        if await hold.hasWorkPredatingHold() { return await end(timeoutOutcome) }
        if neededDrain, Date() >= drainDeadline { return await end(timeoutOutcome) }
        // Re-validate after the drain, immediately before any check work.
        if let reason = await interruption() { return await end(.yielded, reason: reason) }
        log("event=cb_self_check action=admission_hold_drained drain_s=\(String(format: "%.1f", Date().timeIntervalSince(startedAt)))")
        let finished = AdmissionHoldCheckCompletion()
        let task = Task {
            let decided = await check()
            finished.markDone()
            return decided
        }
        var checkDeadline = Date().addingTimeInterval(checkSeconds)
        var residencyWait: TimeInterval = 0
        var lastTick = Date()
        while !finished.isDone {
            // A buyer admitted during the drain may hold a permit when the
            // probe queues; that wait is a drain, not check time (v0.3.37).
            let now = Date()
            if await probeAwaitingResidency() {
                residencyWait += now.timeIntervalSince(lastTick)
                checkDeadline.addTimeInterval(now.timeIntervalSince(lastTick))
            }
            lastTick = now
            let reason = residencyWait > drainBound ? "residency_wait_bound"
                : now >= checkDeadline ? "check_bound" : await interruption()
            if let reason {
                task.cancel()
                // Admission re-opens now; the cancelled check is still awaited
                // so the driver never runs two checks at once.
                let outcome = await end(
                    reason == "check_bound" ? .checkBound : reason == "residency_wait_bound" ? .drainTimeout : .yielded,
                    reason: reason
                )
                _ = await task.value
                return outcome
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let decided = await task.value
        if let reason = await interruption() { return await end(.yielded, reason: reason) }
        return await end(decided ? .completed : .yielded)
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
                decision: decision, ownerPinned: ownerPinned, maxRows: target.grantableRows
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
        let slots = min(prior, target.grantableRows)
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

    /// Completed inference units within the current width survive a hold
    /// ending. A cancelled unit is never checkpointed. The prompts bind the
    /// checkpoint as well as the enclosing record's model/runtime key.
    struct WidthProgress: Codable, Equatable {
        let slots: Int
        let promptSHA256s: [String]
        let probePromptSHA256s: [String]
        var probe: ContinuousBatchingSelfCheckBatchRun?
        var passes: [Pass] = []

        struct Pass: Codable, Equatable {
            let serial: ContinuousBatchingSelfCheckSerialRate
            let batch: ContinuousBatchingSelfCheckBatchRun
        }
    }

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
        /// The ladder bound the decision was measured under
        /// (`ContinuousBatchingSelfCheck.ladderUpperBound`).
        var ladderBound: Int?
        /// Each exactness-probe prompt's tokens when run alone (v0.3.19), and
        /// the SHA-256 of the prompt each was generated from: a stored lone
        /// output is reused only for the same prompt.
        var probeAloneOutputs: [[Int]]?
        var probePromptSHA256s: [String]?
        var widthProgress: WidthProgress?
        /// SPEC-038 AC-26 leg (a) (v0.3.41): keyed cached turns resumed in a
        /// CB row matched the same turns sent cold. Nil until it runs.
        var cachedTurnsParity: Bool?
        /// SPEC-038 FR-CB10 (stock order): each prompt's same-order reference
        /// (`ContinuousBatchingSelfCheck.sameOrderReference`) and the SHA-256
        /// of the prompt each was generated from, for the throughput prompts
        /// and the exactness-probe prompts; reused only for the same prompt
        /// and completion length.
        var sameOrderOutputs: [[Int]]?
        var sameOrderPromptSHA256s: [String]?
        var probeSameOrderOutputs: [[Int]]?
        var probeSameOrderPromptSHA256s: [String]?

        mutating func prepareWidth(slots: Int, prompts: [[Int]], probePrompts: [[Int]]) {
            let promptDigests = prompts.prefix(slots).map(ContinuousBatchingSelfCheck.promptSHA256)
            let probeDigests = probePrompts.prefix(slots).map(ContinuousBatchingSelfCheck.promptSHA256)
            if widthProgress?.slots != slots
                || widthProgress?.promptSHA256s != promptDigests
                || widthProgress?.probePromptSHA256s != probeDigests {
                widthProgress = .init(
                    slots: slots, promptSHA256s: promptDigests, probePromptSHA256s: probeDigests
                )
            }
        }

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
            case ladderBound = "ladder_bound"
            case probeAloneOutputs = "probe_alone_outputs"
            case probePromptSHA256s = "probe_prompt_sha256s"
            case widthProgress = "width_progress"
            case cachedTurnsParity = "cached_turns_parity"
            case sameOrderOutputs = "same_order_outputs"
            case sameOrderPromptSHA256s = "same_order_prompt_sha256s"
            case probeSameOrderOutputs = "probe_same_order_outputs"
            case probeSameOrderPromptSHA256s = "probe_same_order_prompt_sha256s"
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
              (st.st_mode & 0o077) == 0,
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
    /// Wait for qualification cancellation and its journal write before exit.
    /// Scheduler work has separate ownership; this is not its drain fence.
    nonisolated static func cancelAndWait(_ task: Task<Void, Never>?) async {
        task?.cancel()
        await task?.value
    }

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
    /// SPEC-038 FR-CB9: records the startup model's applied decision so the
    /// next start can take the serial small-row route.
    private let verdictRecorder: SmallMRouteVerdictRecorder?
    /// SPEC-038 FR-CB10 item 3 (v0.3.22): a check due this long without an
    /// idle window runs under an admission hold.
    private let admissionHoldAfterSeconds: Double
    /// Bounds a hold's drain; the provider's configured drain timeout.
    private let admissionHoldDrainSeconds: Int
    /// Bounds the check under one hold; an unfinished ladder resumes later.
    private let admissionHoldCheckSeconds: Double
    /// A valid lifecycle (maintenance or startup) lease, if one is held.
    private let lifecycleLease: @Sendable () -> String?
    /// This Mac's 0..`admissionHoldJitterSeconds` offset on the first due time.
    private let admissionHoldJitter: Double
    /// SPEC-001-R019: the drivers of one process measure one at a time.
    private let turn: ContinuousBatchingSelfCheckTurn?
    /// Whether this driver may act now; a further warm member waits while
    /// it is not `warm` or while a warm-set load, eviction or swap runs.
    private let stepAllowed: @Sendable () async -> Bool
    /// Called after the runtime's self-check state or report changed, so a
    /// further warm member's wire entry follows it.
    private let published: @Sendable () async -> Void
    /// SPEC-001-R019: the hold this runtime's check takes while it is a
    /// further warm member: that member alone, never the primary. While the
    /// runtime is the primary its check takes the provider-wide hold.
    private let memberAdmissionHold: (any SelfCheckAdmissionHoldScope)?
    private var consecutiveDrainTimeouts = 0
    private var consecutiveCheckBounds = 0
    /// SPEC-038 FR-CB10 (stock order): the key whose same-order references
    /// do not fit; this process neither measures it nor holds admission for it.
    private var stockOrderReferenceUnfitKey: ContinuousBatchingSelfCheckKey?
    private var deferrals = 0
    private var nextAttemptAt = Date.distantPast
    /// When the check for this key first found no stored decision.
    private var checkDueSince: (key: ContinuousBatchingSelfCheckKey, at: Date)?
    private var admissionHoldNotBefore = Date.distantPast
    /// Set while a step runs under an admission hold: past it the step yields.
    private var admissionHoldDeadline: Date?
    /// The width whose probe the previous attempt saw refused with
    /// backpressure, for that target only; any other outcome clears it.
    private var backpressureRefusal: (target: ContinuousBatchingSelfCheckTarget, slots: Int)?

    static let repeats = 3

    init(
        runtime: ModelRuntime,
        providerStatus: ProviderStatus,
        store: ContinuousBatchingSelfCheckStore,
        ownerPinnedSlots: Int?,
        provisional: Provisional? = nil,
        idleSeconds: Double = 10,
        pollSeconds: Double = 5,
        admissionHoldAfterSeconds: Double = ContinuousBatchingSelfCheck.admissionHoldAfterSeconds,
        admissionHoldDrainSeconds: Int = 30,
        admissionHoldCheckSeconds: Double = ContinuousBatchingSelfCheck.admissionHoldCheckSeconds,
        lifecycleLease: @escaping @Sendable () -> String? = { nil },
        admissionHoldJitter: Double = Double.random(in: 0...ContinuousBatchingSelfCheck.admissionHoldJitterSeconds),
        verdictRecorder: SmallMRouteVerdictRecorder? = nil,
        turn: ContinuousBatchingSelfCheckTurn? = nil,
        stepAllowed: @escaping @Sendable () async -> Bool = { true },
        published: @escaping @Sendable () async -> Void = {},
        memberAdmissionHold: (any SelfCheckAdmissionHoldScope)? = nil,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.memberAdmissionHold = memberAdmissionHold
        self.turn = turn
        self.stepAllowed = stepAllowed
        self.published = published
        self.runtime = runtime
        self.providerStatus = providerStatus
        self.store = store
        self.ownerPinnedSlots = ownerPinnedSlots
        self.provisional = provisional
        self.idleSeconds = idleSeconds
        self.pollSeconds = max(0.1, pollSeconds)
        self.admissionHoldAfterSeconds = max(0, admissionHoldAfterSeconds)
        self.admissionHoldDrainSeconds = max(0, admissionHoldDrainSeconds)
        self.admissionHoldCheckSeconds = max(1, admissionHoldCheckSeconds)
        self.lifecycleLease = lifecycleLease
        self.admissionHoldJitter = max(0, admissionHoldJitter)
        self.verdictRecorder = verdictRecorder
        self.log = log
    }

    /// The grant this Mac already serves for `key`'s model: a signed
    /// provisional grant for the same artifact, or a stored grant under an
    /// older runtime identity on the same hardware.
    private func priorGrant(for key: ContinuousBatchingSelfCheckKey) -> Int? {
        let provisionalSlots = provisional?.slots(for: key.modelSHA256)
        return [provisionalSlots, store.priorGrant(for: key)].compactMap { $0 }.filter { $0 > 1 }.max()
    }

    /// Runs `body` holding the process's self-check turn, when there is one.
    private func inTurn(_ body: () async -> Void) async {
        guard let turn else { return await body() }
        guard await turn.acquire() else { return }
        await body()
        await turn.release()
    }

    func run() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(pollSeconds * 1_000_000_000))
            guard await stepAllowed() else { continue }
            guard let target = await runtime.continuousBatchingSelfCheckTarget(includeDecided: true) else {
                checkDueSince = nil
                continue
            }
            let pending = await runtime.continuousBatchingSelfCheckState() == .pending
            let record = store.record(for: target.key)
            if let record, let crashed = record.inProgressSlots {
                // The previous process died inside this step (including a
                // re-measurement of a kept grant): never retry that width.
                log("event=cb_self_check action=crash_recovered slots=\(crashed)")
                await inTurn { await finish(record, crashedAt: crashed, target: target) }
                continue
            }
            if let record, let decision = record.decision {
                checkDueSince = nil
                if pending { await apply(decision, target: target, source: "stored") }
                if case .granted = decision.state {
                    if let parity = record.cachedTurnsParity {
                        if await runtime.continuousBatchingCachedTurnsSelfCheckResult() != parity {
                            await runtime.applyContinuousBatchingCachedTurnsSelfCheck(parity, expected: target)
                        }
                    } else if Date() >= nextAttemptAt, await isIdle() {
                        var ran = false
                        await inTurn { ran = await measureCachedTurns(target) }
                        if ran { continue }
                    }
                }
                let bound = ContinuousBatchingSelfCheck.ladderUpperBound(
                    target: target, ownerPinned: ownerPinnedSlots, crashedSlots: record.crashedSlots
                )
                let due = record.remeasureAfter.flatMap(Self.parseDate).map { Date() >= $0 } ?? false
                if due || ContinuousBatchingSelfCheck.ladderBoundGrew(record: record, currentBound: bound),
                   Date() >= nextAttemptAt, await isIdle() {
                    await inTurn { await measure(target, remeasureOf: record) }
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
            if checkDueSince?.key != target.key {
                checkDueSince = (target.key, Date())
                consecutiveDrainTimeouts = 0
                consecutiveCheckBounds = 0
            }
            let idle = await isIdle()
            if idle {
                if Date() >= nextAttemptAt { await inTurn { await measure(target, remeasureOf: nil) } }
                continue
            }
            // A busy Mac never finds an idle window under steady traffic: once
            // the check has been due long enough, hold admission and run it.
            if let due = checkDueSince, Date() >= nextAttemptAt, stockOrderReferenceUnfitKey != target.key,
               ContinuousBatchingSelfCheck.admissionHoldDue(
                dueSince: due.at, notBefore: admissionHoldNotBefore,
                after: admissionHoldAfterSeconds + admissionHoldJitter, now: Date()
               ) {
                await inTurn { await measureUnderAdmissionHold(target, dueSeconds: Date().timeIntervalSince(due.at)) }
            }
        }
    }

    /// SPEC-038 FR-CB10 item 3 (v0.3.22): the check under an admission hold
    /// (`ContinuousBatchingSelfCheck.runUnderSelfCheckHold`). A prior grant
    /// keeps serving until the check decides; holds are at least
    /// `admissionHoldAfterSeconds` apart.
    private func measureUnderAdmissionHold(_ target: ContinuousBatchingSelfCheckTarget, dueSeconds: Double) async {
        let runtime = runtime
        let outcome = await ContinuousBatchingSelfCheck.runUnderSelfCheckHold(
            scope: await admissionHoldScope(),
            drainSeconds: ContinuousBatchingSelfCheck.admissionHoldDrainSeconds(
                base: admissionHoldDrainSeconds, consecutiveDrainTimeouts: consecutiveDrainTimeouts
            ),
            checkSeconds: ContinuousBatchingSelfCheck.admissionHoldCheckBound(
                base: admissionHoldCheckSeconds, consecutiveBoundYields: consecutiveCheckBounds
            ),
            lifecycleLease: lifecycleLease,
            stillValid: { await runtime.continuousBatchingSelfCheckTarget(includeDecided: true) == target },
            buyerWaitSeconds: { await runtime.selfCheckBuyerWaitSeconds() },
            probeAwaitingResidency: { await runtime.selfCheckProbeAwaitingResidency() },
            context: "due_s=\(Int(dueSeconds)) model_sha256=\(target.key.modelSHA256)",
            log: log
        ) {
            await self.measureWithinAdmissionHold(target)
        }
        consecutiveDrainTimeouts = ContinuousBatchingSelfCheck.nextConsecutiveDrainTimeouts(
            consecutiveDrainTimeouts, after: outcome
        )
        consecutiveCheckBounds = outcome == .checkBound ? consecutiveCheckBounds + 1 : 0
        // Spaced from the end of this hold, not its start.
        admissionHoldNotBefore = Date().addingTimeInterval(admissionHoldAfterSeconds)
    }

    /// The provider-wide hold while this runtime is the primary (the one
    /// holding the provider status), else its own member's hold.
    private func admissionHoldScope() async -> any SelfCheckAdmissionHoldScope {
        Self.admissionHoldScope(
            isPrimary: await runtime.hasProviderStatus(), member: memberAdmissionHold, providerStatus: providerStatus)
    }

    static func admissionHoldScope(
        isPrimary: Bool, member: (any SelfCheckAdmissionHoldScope)?, providerStatus: ProviderStatus
    ) -> any SelfCheckAdmissionHoldScope {
        if !isPrimary, let member { return member }
        return ProcessSelfCheckAdmissionHold(providerStatus: providerStatus)
    }

    /// The check under a hold: bounded by `admissionHoldCheckSeconds`, after
    /// which the step yields and the ladder resumes at the next hold.
    private func measureWithinAdmissionHold(_ target: ContinuousBatchingSelfCheckTarget) async -> Bool {
        admissionHoldDeadline = Date().addingTimeInterval(ContinuousBatchingSelfCheck.admissionHoldCheckBound(
            base: admissionHoldCheckSeconds, consecutiveBoundYields: consecutiveCheckBounds
        ))
        await measure(target, remeasureOf: nil)
        admissionHoldDeadline = nil
        let record = store.record(for: target.key)
        return record?.decision != nil && record?.inProgressSlots == nil
    }

    /// SPEC-038 AC-26 leg (a) (v0.3.41): runs once per self-check key after a
    /// granted decision, only while idle, and yields to the first request.
    /// The result is stored with the decision and applied at every load.
    /// Returns whether a probe ran (decided or deferred).
    private func measureCachedTurns(_ target: ContinuousBatchingSelfCheckTarget) async -> Bool {
        let runtime = runtime
        do {
            guard let passed = try await yieldingToRequests({ try await runtime.runContinuousBatchingCachedTurnsProbe() })
            else { return false }
            guard var record = store.record(for: target.key), record.decision != nil else { return true }
            record.cachedTurnsParity = passed
            try save(record)
            deferrals = 0
            await runtime.applyContinuousBatchingCachedTurnsSelfCheck(passed, expected: target)
            log("event=cb_self_check action=cached_turns_decided result=\(passed ? "passed" : "failed") model_sha256=\(target.key.modelSHA256)")
            return true
        } catch {
            deferrals += 1
            nextAttemptAt = Date().addingTimeInterval(
                ContinuousBatchingSelfCheck.deferralBackoffSeconds(deferrals: deferrals, base: pollSeconds)
            )
            log("event=cb_self_check action=cached_turns_deferred reason=\(Self.deferralReason(error))")
            return true
        }
    }

    private static func deferralReason(_ error: Error) -> String {
        switch error {
        case StepError.admissionHoldEnded: return "admission_hold_ended"
        case is StepError: return "request_in_flight"
        case is CancellationError: return "cancelled"
        default: return "step_failed error=\(String(describing: error).prefix(200))"
        }
    }

    private static func parseDate(_ value: String) -> Date? { ISO8601DateFormatter().date(from: value) }

    private func isIdle() async -> Bool {
        guard await !providerStatus.hasInferenceWork() else { return false }
        return await providerStatus.secondsSinceLastActivityOrPrewarm() >= idleSeconds
    }

    private enum StepError: Error {
        case yielded
        /// An admission hold ran out, or a pause or drain began during it.
        case admissionHoldEnded
        /// The exactness probe at this width could not run its full shape.
        case probeShapeUnmet(slots: Int)
    }

    /// Runs `body` and cancels it as soon as a request is in flight, or, under
    /// an admission hold, the provider leaves ready/busy. The outer hold
    /// watchdog alone owns the timeout, so every expiry increments its bound
    /// escalation counter instead of racing an inner generic yield.
    private func yieldingToRequests<T: Sendable>(
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let providerStatus = providerStatus
        let holdDeadline = admissionHoldDeadline
        return try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await body() }
            group.addTask {
                while !Task.isCancelled {
                    // Under a hold a buyer queues behind the step; the hold's
                    // buyer-wait bound owns that yield (v0.3.36).
                    if holdDeadline == nil, await providerStatus.hasInferenceWork() { throw StepError.yielded }
                    let snapshot = await providerStatus.snapshot()
                    if holdDeadline != nil,
                       !(snapshot.status == .ready || snapshot.status == .busy) {
                        throw StepError.admissionHoldEnded
                    }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                throw CancellationError()
            }
            defer { group.cancelAll() }
            while let next = try await group.next() {
                // A cancelled step (an admission hold that ended) may return a
                // truncated run: never record it as a measurement.
                try Task.checkCancellation()
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
        guard !Task.isCancelled else { return }
        let runtime = runtime
        let crashedSlots = (previous ?? store.record(for: target.key))?.crashedSlots
        let configuredSlots = ContinuousBatchingSelfCheck.ladderUpperBound(
            maxRows: target.maxRows,
            ownerPinned: ownerPinnedSlots,
            crashedSlots: crashedSlots,
            queueLimit: target.queueLimit,
            policyCeiling: target.policyCeiling
        )
        let ladderBound = ContinuousBatchingSelfCheck.ladderUpperBound(
            target: target, ownerPinned: ownerPinnedSlots, crashedSlots: crashedSlots
        )
        // SPEC-038 FR-CB10 (stock order): a width from three rows needs each
        // prompt's same-order reference, three copies at once. When a width
        // the ladder would probe has references that cannot fit the pool,
        // this process measures nothing on stock order: the next start takes
        // the row-invariant route (`stock_order_reference_unfit`) and
        // measures there. A shorter ladder here could lower a kept or prior
        // grant (`reconcile` keeps only verified widths) or decide one row,
        // so an unfit reference never does either.
        if target.smallMRoute == .stockOrder,
           ContinuousBatchingSelfCheck.stockOrderReferenceBound(target: target, maxCount: ladderBound) < ladderBound {
            if stockOrderReferenceUnfitKey != target.key {
                stockOrderReferenceUnfitKey = target.key
                let referenceBound = ContinuousBatchingSelfCheck.stockOrderReferenceBound(target: target, maxCount: ladderBound)
                log("event=cb_self_check action=stock_order_reference_unfit ladder_bound=\(ladderBound) reference_bound=\(referenceBound) model_sha256=\(target.key.modelSHA256)")
                verdictRecorder?.stockOrderFailed(reason: SmallMRoute.stockOrderReferenceUnfit, modelSHA256: target.key.modelSHA256)
            }
            return
        }
        let maxSlots = ladderBound
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
                record.widthProgress = nil
                record.remeasureInProgress = true
            }
        } else {
            record = store.record(for: target.key) ?? .init(
                key: target.key, decision: nil, serialTPS: 0, measurements: [], aloneOutputs: [], inProgressSlots: nil, decidedAt: nil
            )
        }
        guard maxSlots >= 2 else {
            // Fail closed: a Mac that cannot hold two exactness-probe rows
            // verifies no width.
            let reason = configuredSlots >= 2 ? "probe_shape_unavailable" : "single_row"
            record.decision = .init(slots: 1, reason: reason, verifiedSlots: 1)
            record.ladderBound = ladderBound
            // Decided: it re-runs when the bound grows, not on a timer.
            record.inProgressSlots = nil
            record.remeasureInProgress = nil
            record.remeasureAfter = nil
            record.decidedAt = ISO8601DateFormatter().string(from: Date())
            try? save(record)
            await apply(record.decision!, target: target, source: "measured")
            return
        }
        if previous == nil, await runtime.continuousBatchingSelfCheckState() == .pending {
            await report(decision: deferrals > 0 ? "deferred" : "pending", target: target)
        }
        log("event=cb_self_check action=step max_slots=\(maxSlots) rows=\(target.maxRows) queue_limit=\(target.queueLimit) probe_key_boundary=\(target.probeKeyBoundary) resumed_at=\(record.measurements.count) remeasure=\(previous != nil) model_sha256=\(target.key.modelSHA256)")
        let stepStartedAt = Date()
        do {
            try Task.checkCancellation()
            let tokens = ContinuousBatchingSelfCheck.maxOutputTokens
            // Scheduler request ids are idempotency keys; never reuse one.
            let attempt = UUID().uuidString.prefix(8).lowercased()
            let prompts = try await yieldingToRequests {
                try await runtime.continuousBatchingSelfCheckPrompts(
                    ContinuousBatchingSelfCheck.promptTexts(count: maxSlots)
                )
            }
            let probeTokens = ContinuousBatchingSelfCheck.exactnessOutputTokens(decodeWindow: target.key.decodeWindow)
            let requiredCohortTokens = ContinuousBatchingSelfCheck.requiredCohortDecodeTokens(
                decodeWindow: target.key.decodeWindow
            )
            let probePrompts = try await exactnessPrompts(count: maxSlots, target: target, outputTokens: probeTokens)
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
                try Task.checkCancellation()
                record.prepareWidth(slots: slots, prompts: prompts, probePrompts: probePrompts)
                // Journal before any inference for this width, alone runs included.
                record.inProgressSlots = slots
                try save(record)
                // Exactness probe: rows of unequal key lengths across the route
                // boundary, all decoding together for the required tokens.
                // Stored lone outputs are reused only for the same prompt and
                // completion length.
                var probeAlone = ContinuousBatchingSelfCheck.reusableLoneOutputs(
                    record.probeAloneOutputs ?? [], digests: record.probePromptSHA256s ?? [],
                    prompts: probePrompts, outputTokens: probeTokens
                )
                while probeAlone.count < slots {
                    let index = probeAlone.count
                    let row = try await yieldingToRequests {
                        try await runtime.runContinuousBatchingSelfCheckBatch(
                            prompts: [probePrompts[index]], maxOutputTokens: probeTokens,
                            idPrefix: "cb-self-check-\(attempt)-probe-alone-\(index)"
                        )
                    }
                    probeAlone.append(row.outputs[0])
                    record.probeAloneOutputs = probeAlone
                    record.probePromptSHA256s = probePrompts.prefix(probeAlone.count).map(ContinuousBatchingSelfCheck.promptSHA256)
                    try save(record)
                }
                // Stock order from three rows: each row's reference is its
                // prompt's same-order run; its lone run stays an exact
                // alternate (`rowsDifferingFromReference`).
                let sameOrder = ContinuousBatchingSelfCheck.usesSameOrderReference(route: target.smallMRoute, slots: slots)
                var probeSameOrder: [[Int]] = []
                if sameOrder {
                    let references = try await sameOrderReferences(
                        &record, probe: true, prompts: probePrompts, slots: slots, outputTokens: probeTokens,
                        idPrefix: "cb-self-check-\(attempt)-probe-same-order"
                    )
                    if let failure = references.failure {
                        try failWidth(&record, slots: slots, divergence: failure)
                        break
                    }
                    probeSameOrder = references.outputs
                }
                let probeReferences = ContinuousBatchingSelfCheck.rowReferences(
                    route: target.smallMRoute, slots: slots, lone: probeAlone, sameOrder: probeSameOrder
                )
                let probe: ContinuousBatchingSelfCheckBatchRun
                do {
                    if let completed = record.widthProgress?.probe {
                        probe = completed
                    } else {
                        probe = try await yieldingToRequests {
                            try await runtime.runContinuousBatchingSelfCheckBatch(
                                prompts: Array(probePrompts.prefix(slots)), maxOutputTokens: probeTokens,
                                idPrefix: "cb-self-check-\(attempt)-probe-k\(slots)", cohort: true
                            )
                        }
                        record.widthProgress?.probe = probe
                        try save(record)
                    }
                } catch where (error as? ContinuousBatchSchedulerError) == .queueWaitTimedOut {
                    // The cohort never all reached a row: its shape was not met.
                    throw StepError.probeShapeUnmet(slots: slots)
                }
                if sameOrder, !ContinuousBatchingSelfCheck.cohortRowsRanInOneOrder(
                    outputs: probe.outputs, cohortDecodeTokens: probe.cohortDecodeTokens
                ) {
                    // Checked before any row is judged: a run that may mix
                    // orders gives no correctness result either way.
                    record.widthProgress?.probe = nil
                    log("event=cb_self_check action=probe_shape_unmet slots=\(slots) reason=probe_mixed_order cohort_decode_tokens=\(probe.cohortDecodeTokens.map(String.init).joined(separator: ","))")
                    throw StepError.probeShapeUnmet(slots: slots)
                }
                let probeCheck = try await checkRows(
                    passes: [probe.outputs], alone: probeReferences, prompts: probePrompts, label: "probe",
                    exactAlternates: sameOrder ? Array(probeAlone.prefix(slots)) : []
                )
                var conformant = probeCheck.conformant
                var nearTieRows = probeCheck.nearTieRows
                var divergences = probeCheck.divergences
                let cohortTokens = probe.cohortDecodeTokens.min() ?? 0
                if conformant, cohortTokens < requiredCohortTokens {
                    // A shape failure is retried, never reused as a successful unit.
                    record.widthProgress?.probe = nil
                    log("event=cb_self_check action=probe_shape_unmet slots=\(slots) cohort_decode_tokens=\(cohortTokens) required=\(requiredCohortTokens)")
                    throw StepError.probeShapeUnmet(slots: slots)
                }
                if record.aloneOutputs.contains(where: { $0.count != tokens }) { record.aloneOutputs = [] }
                while conformant, record.aloneOutputs.count < slots {
                    let index = record.aloneOutputs.count
                    let row = try await yieldingToRequests {
                        try await runtime.runContinuousBatchingSelfCheckBatch(
                            prompts: [prompts[index]], maxOutputTokens: tokens, idPrefix: "cb-self-check-\(attempt)-alone-\(index)"
                        )
                    }
                    record.aloneOutputs.append(row.outputs[0])
                    try save(record)
                }
                var batchSameOrder: [[Int]] = []
                if conformant, sameOrder {
                    let references = try await sameOrderReferences(
                        &record, probe: false, prompts: prompts, slots: slots, outputTokens: tokens,
                        idPrefix: "cb-self-check-\(attempt)-same-order"
                    )
                    if let failure = references.failure {
                        try failWidth(&record, slots: slots, divergence: failure)
                        break
                    }
                    batchSameOrder = references.outputs
                }
                let batchReferences = ContinuousBatchingSelfCheck.rowReferences(
                    route: target.smallMRoute, slots: slots, lone: record.aloneOutputs, sameOrder: batchSameOrder
                )
                // Rungs: repeats of stock serial then batched, back to back on
                // the same prompts; the gain is the median ratio. For a
                // `decodeOnlyGain` target (glm5_next, v0.3.21) both are decode
                // rates: serial tokens after each first token over their time,
                // batched cohort decode tokens over the span all rows decoded
                // together (the batch runs as a cohort, so no row decodes while
                // another prefills). On stock order from three rows every
                // batch also runs as a cohort, so each row keeps one forward
                // and one kernel order (`cohortRowsRanInOneOrder`); its gain
                // stays end-to-end but no longer credits prefill overlapping
                // another row's decode. Other widths: one batch for isolation
                // only. A width whose probe already diverged runs neither.
                let isRung = rungs.contains(slots)
                let batchPrompts = Array(prompts.prefix(slots))
                let serialPrompts = Array(batchPrompts.prefix(ContinuousBatchingSelfCheck.serialBaselinePrompts))
                var passes: [[[Int]]] = []
                var ratios: [Double] = []
                var aggregates: [Double] = []
                var serials: [Double] = []
                for pass in 0..<(conformant ? (isRung ? Self.repeats : 1) : 0) {
                    var serialRate = ContinuousBatchingSelfCheckSerialRate(decodeTPS: 0, endToEndTPS: 0)
                    let batch: ContinuousBatchingSelfCheckBatchRun
                    if let completed = record.widthProgress?.passes, pass < completed.count {
                        serialRate = completed[pass].serial
                        batch = completed[pass].batch
                    } else {
                        if isRung {
                            serialRate = try await yieldingToRequests {
                                try await runtime.continuousBatchingSelfCheckSerialTPS(prompts: serialPrompts, maxTokens: tokens)
                            }
                        }
                        let decodeOnly = target.decodeOnlyGain
                        do {
                            batch = try await yieldingToRequests {
                                try await runtime.runContinuousBatchingSelfCheckBatch(
                                    prompts: batchPrompts, maxOutputTokens: tokens, idPrefix: "cb-self-check-\(attempt)-k\(slots)-p\(pass)",
                                    cohort: decodeOnly || sameOrder
                                )
                            }
                        } catch where sameOrder && (error as? ContinuousBatchSchedulerError) == .queueWaitTimedOut {
                            throw StepError.probeShapeUnmet(slots: slots)
                        }
                        if !sameOrder || ContinuousBatchingSelfCheck.cohortRowsRanInOneOrder(
                            outputs: batch.outputs, cohortDecodeTokens: batch.cohortDecodeTokens
                        ) {
                            record.widthProgress?.passes.append(.init(serial: serialRate, batch: batch))
                            try save(record)
                        }
                    }
                    if sameOrder, !ContinuousBatchingSelfCheck.cohortRowsRanInOneOrder(
                        outputs: batch.outputs, cohortDecodeTokens: batch.cohortDecodeTokens
                    ) {
                        // Stock order from three rows: every pass runs as a
                        // cohort and is judged only if each row kept one
                        // forward for its whole run; a pass that may mix
                        // orders is not stored and gives no result either way.
                        if let stored = record.widthProgress?.passes, stored.count > pass {
                            record.widthProgress?.passes = Array(stored.prefix(pass))
                        }
                        log("event=cb_self_check action=probe_shape_unmet slots=\(slots) reason=pass_mixed_order pass=\(pass) cohort_decode_tokens=\(batch.cohortDecodeTokens.map(String.init).joined(separator: ","))")
                        throw StepError.probeShapeUnmet(slots: slots)
                    }
                    let decodeOnly = target.decodeOnlyGain
                    let serial = decodeOnly ? serialRate.decodeTPS : serialRate.endToEndTPS
                    passes.append(batch.outputs)
                    let generated = batch.outputs.reduce(0) { $0 + $1.count }
                    let endToEnd = batch.seconds > 0 ? Double(generated) / batch.seconds : 0
                    let aggregate = decodeOnly
                        ? ContinuousBatchingSelfCheck.cohortDecodeTPS(
                            tokens: batch.cohortDecodeTokens, seconds: batch.cohortDecodeSeconds
                        )
                        : endToEnd
                    aggregates.append(aggregate)
                    if serial > 0, !decodeOnly || aggregate > 0 {
                        serials.append(serial)
                        ratios.append(aggregate / serial)
                    }
                    if decodeOnly {
                        log("event=cb_self_check action=pass slots=\(slots) pass=\(pass) serial_decode_tps=\(String(format: "%.1f", serial)) serial_e2e_tps=\(String(format: "%.1f", serialRate.endToEndTPS)) batch_decode_tps=\(String(format: "%.1f", aggregate)) batch_e2e_tps=\(String(format: "%.1f", endToEnd)) batch_wall_s=\(String(format: "%.3f", batch.seconds)) cohort_decode_s=\(String(format: "%.3f", batch.cohortDecodeSeconds.max() ?? 0)) cohort_decode_tokens=\(batch.cohortDecodeTokens.reduce(0, +))")
                    }
                }
                if !passes.isEmpty {
                    let passCheck = try await checkRows(
                        passes: passes, alone: batchReferences, prompts: prompts, label: "batch",
                        exactAlternates: sameOrder ? Array(record.aloneOutputs.prefix(slots)) : []
                    )
                    conformant = passCheck.conformant
                    nearTieRows += passCheck.nearTieRows
                    divergences += passCheck.divergences
                }
                let gain = Self.median(ratios)
                let aggregate = Self.median(aggregates)
                try Task.checkCancellation()
                if isRung { record.serialTPS = max(record.serialTPS, Self.median(serials)) }
                record.measurements.append(.init(
                    slots: slots, conformant: conformant, nearTieRows: nearTieRows, aggregateTPS: aggregate,
                    gain: gain, throughputMeasured: isRung && !passes.isEmpty
                ))
                record.inProgressSlots = nil
                record.widthProgress = nil
                try save(record)
                log("event=cb_self_check action=measured slots=\(slots) rung=\(isRung) conformant=\(conformant) cohort_decode_tokens=\(cohortTokens) divergent_rows=\(divergences.isEmpty ? "none" : divergences.joined(separator: ",")) aggregate_tps=\(String(format: "%.1f", aggregate)) serial_tps=\(String(format: "%.1f", Self.median(serials))) gain=\(String(format: "%.2f", gain))")
                if !conformant { break }
            }
            try Task.checkCancellation()
            deferrals = 0
            nextAttemptAt = .distantPast
            backpressureRefusal = nil
            record.ladderBound = ladderBound
            await finish(record, crashedAt: nil, target: target)
        } catch {
            // Yielded to a real request, a transient failure, or a journal
            // write failure: completed widths are kept, the interrupted one
            // was not completed (not a crash), and the next attempt waits
            // longer each time. A kept or prior grant stays applied.
            let refusedAt = record.inProgressSlots
            record.inProgressSlots = nil
            try? save(record)
            let previousRefusal = backpressureRefusal.flatMap { $0.target == target ? $0.slots : nil }
            backpressureRefusal = nil
            // A buyer request during the step can take rows from the cohort;
            // that is a yield, not a probe result.
            if !Task.isCancelled, case StepError.probeShapeUnmet(let slots) = error,
               await !providerStatus.hasInferenceWork(),
               await providerStatus.secondsSinceLastRealActivity() >= Date().timeIntervalSince(stepStartedAt) {
                // Fail closed: decide on the widths verified below it, and
                // run the full ladder again later.
                let resume = ContinuousBatchingSelfCheck.backpressureResumeSeconds
                log("event=cb_self_check action=ladder_ended reason=probe_shape_unmet slots=\(slots) verified_k=\(record.measurements.last?.slots ?? 1) remeasure_in_s=\(Int(resume))")
                deferrals = 0
                nextAttemptAt = .distantPast
                record.ladderBound = ladderBound
                await finish(record, crashedAt: nil, target: target, incompleteRemeasureSeconds: resume, probeShapeUnmetAt: slots)
                return
            }
            // Backpressure with no buyer request during the step is the
            // scheduler refusing the probe itself (its queue or token budget,
            // or a native-MTP integrity probe holding it).
            if !Task.isCancelled, (error as? ContinuousBatchSchedulerError) == .backpressure, let refusedAt,
               await !providerStatus.hasInferenceWork(),
               await providerStatus.secondsSinceLastRealActivity() >= Date().timeIntervalSince(stepStartedAt) {
                let verifiedPrefix = record.measurements.last?.slots ?? 1
                // The count this Mac serves now (an owner pin can serve above
                // the decision's own slots, up to its verified width), or a
                // stored or provisional grant.
                let served = await servedSlotsNow()
                let prior = [served, record.decision?.slots, priorGrant(for: target.key)]
                    .compactMap { $0 }.filter { $0 > 1 }.max()
                let resume = ContinuousBatchingSelfCheck.backpressureResumeSeconds
                switch ContinuousBatchingSelfCheck.backpressureOutcome(
                    verifiedPrefix: verifiedPrefix, slots: refusedAt, previousRefusalAt: previousRefusal, priorGrant: prior
                ) {
                case .retrySoon:
                    backpressureRefusal = (target, refusedAt)
                    nextAttemptAt = Date().addingTimeInterval(pollSeconds)
                    log("event=cb_self_check action=backpressure_retry slots=\(refusedAt) retry_in_s=\(Int(pollSeconds))")
                    return
                case .pause:
                    // Not a correctness result: the wider grant this Mac
                    // already serves stays, and the ladder resumes here.
                    nextAttemptAt = Date().addingTimeInterval(resume)
                    log("event=cb_self_check action=ladder_paused reason=backpressure refused_slots=\(refusedAt) verified_k=\(verifiedPrefix) prior_grant=\(prior ?? 1) resume_in_s=\(Int(resume))")
                    return
                case .endLadder:
                    log("event=cb_self_check action=ladder_ended reason=backpressure refused_slots=\(refusedAt) verified_k=\(verifiedPrefix) remeasure_in_s=\(Int(resume))")
                    deferrals = 0
                    nextAttemptAt = .distantPast
                    record.ladderBound = ladderBound
                    await finish(record, crashedAt: nil, target: target, incompleteRemeasureSeconds: resume)
                    return
                case .deferStep:
                    break
                }
            }
            // A step ended by its own admission hold (its bound, a pause, a
            // lease or a target change) is spaced by the hold interval, not
            // the deferral backoff.
            if admissionHoldDeadline == nil {
                deferrals += 1
                let wait = ContinuousBatchingSelfCheck.deferralBackoffSeconds(deferrals: deferrals, base: pollSeconds)
                nextAttemptAt = Date().addingTimeInterval(wait)
            }
            if previous == nil, await runtime.continuousBatchingSelfCheckState() == .pending {
                await report(decision: "deferred", target: target)
            }
            log("event=cb_self_check action=deferred deferrals=\(deferrals) retry_in_s=\(Int(max(0, nextAttemptAt.timeIntervalSinceNow))) reason=\(Self.deferralReason(error))")
        }
    }

    /// SPEC-038 FR-CB10 (stock order): the same-order references of the
    /// first `slots` prompts, each row 0 of its prompt run
    /// `sameOrderReferenceRows` times as one cohort through the production
    /// scheduler, so every decode forward of it takes the batch kernel.
    /// Stored references are reused only for the same prompt and completion
    /// length. `failure` names the first prompt whose rows differed; no
    /// reference is stored for it.
    private func sameOrderReferences(
        _ record: inout ContinuousBatchingSelfCheckStore.Record,
        probe: Bool,
        prompts: [[Int]],
        slots: Int,
        outputTokens: Int,
        idPrefix: String
    ) async throws -> (outputs: [[Int]], failure: String?) {
        let runtime = runtime
        typealias Record = ContinuousBatchingSelfCheckStore.Record
        let outputsPath: WritableKeyPath<Record, [[Int]]?> =
            probe ? \Record.probeSameOrderOutputs : \Record.sameOrderOutputs
        let digestsPath: WritableKeyPath<Record, [String]?> =
            probe ? \Record.probeSameOrderPromptSHA256s : \Record.sameOrderPromptSHA256s
        var references = ContinuousBatchingSelfCheck.reusableLoneOutputs(
            record[keyPath: outputsPath] ?? [], digests: record[keyPath: digestsPath] ?? [],
            prompts: prompts, outputTokens: outputTokens
        )
        while references.count < slots {
            let index = references.count
            let rows = Array(repeating: prompts[index], count: ContinuousBatchingSelfCheck.sameOrderReferenceRows)
            let id = "\(idPrefix)-\(index)"
            let run: ContinuousBatchingSelfCheckBatchRun
            do {
                run = try await yieldingToRequests {
                    try await runtime.runContinuousBatchingSelfCheckBatch(
                        prompts: rows, maxOutputTokens: outputTokens, idPrefix: id, cohort: true
                    )
                }
            } catch where (error as? ContinuousBatchSchedulerError) == .queueWaitTimedOut {
                // The reference cohort never all reached a row: its shape was not met.
                throw StepError.probeShapeUnmet(slots: slots)
            }
            guard ContinuousBatchingSelfCheck.cohortRowsRanInOneOrder(
                outputs: run.outputs, cohortDecodeTokens: run.cohortDecodeTokens
            ) else {
                // A row also decoded in a narrower step, so the rows may not
                // share one order: judged neither way.
                log("event=cb_self_check action=probe_shape_unmet slots=\(slots) reason=same_order_reference_mixed_order index=\(index)")
                throw StepError.probeShapeUnmet(slots: slots)
            }
            guard let reference = ContinuousBatchingSelfCheck.sameOrderReference(run.outputs) else {
                return (references, "\(probe ? "probe" : "batch")_same_order_reference:\(index):rows_differ")
            }
            references.append(reference)
            record[keyPath: outputsPath] = references
            record[keyPath: digestsPath] = prompts.prefix(references.count).map(ContinuousBatchingSelfCheck.promptSHA256)
            try save(record)
        }
        return (references, nil)
    }

    /// Records width `slots` as failed for a correctness reason found before
    /// its rows were compared (a same-order reference whose rows differ).
    private func failWidth(
        _ record: inout ContinuousBatchingSelfCheckStore.Record,
        slots: Int,
        divergence: String
    ) throws {
        record.measurements.append(.init(slots: slots, conformant: false, aggregateTPS: 0, throughputMeasured: false))
        record.inProgressSlots = nil
        record.widthProgress = nil
        try save(record)
        log("event=cb_self_check action=measured slots=\(slots) conformant=false divergent_rows=\(divergence)")
    }

    /// The exactness-probe prompts for `count` rows, each cut to its
    /// `exactnessPromptLength` in tokens. A prompt that cannot be cut to its
    /// length ends the ladder below it (`probeShapeUnmet`).
    private func exactnessPrompts(
        count: Int,
        target: ContinuousBatchingSelfCheckTarget,
        outputTokens: Int
    ) async throws -> [[Int]] {
        let lengths = ContinuousBatchingSelfCheck.exactnessPromptLengths(
            count: count, keyBoundary: target.probeKeyBoundary, outputTokens: outputTokens
        )
        let runtime = runtime
        let full = try await yieldingToRequests {
            try await runtime.continuousBatchingSelfCheckPrompts(ContinuousBatchingSelfCheck.exactnessTexts(lengths: lengths))
        }
        guard full.count == lengths.count, full.count >= 2 else {
            throw StepError.probeShapeUnmet(slots: max(2, min(full.count, lengths.count) + 1))
        }
        let tail = ContinuousBatchingSelfCheck.commonSuffixLength(full[0], full[1])
        return try zip(full, lengths).enumerated().map { index, pair in
            guard let prompt = ContinuousBatchingSelfCheck.fitPrompt(pair.0, tail: tail, length: pair.1) else {
                throw StepError.probeShapeUnmet(slots: max(2, index + 1))
            }
            return prompt
        }
    }

    /// Compares every batched row with its reference (its prompt run alone,
    /// or on stock order from three rows its same-order run) and judges each
    /// first divergence (`ContinuousBatchingSelfCheck.divergenceVerdict`). A
    /// row equal to its exact alternate passes.
    private func checkRows(
        passes: [[[Int]]],
        alone: [[Int]],
        prompts: [[Int]],
        label: String,
        exactAlternates: [[Int]] = []
    ) async throws -> (conformant: Bool, nearTieRows: Int, divergences: [String]) {
        let runtime = runtime
        var nearTieRows = 0
        var divergences: [String] = []
        let differing = ContinuousBatchingSelfCheck.rowsDifferingFromReference(
            passes: passes, references: alone, exactAlternates: exactAlternates
        )
        var conformant = !differing.countMismatch
        for (row, pair) in differing.rows {
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
                let others = alone.enumerated().compactMap { other, tokens -> Int? in
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
                marginText = verdict.margin.map { String(format: "%.4f", $0) } ?? "na"
                tokenText = "\(aloneToken)->\(batchedToken)"
            }
            if nearTie { nearTieRows += 1 } else { conformant = false }
            divergences.append("\(label):\(row)@\(index.map(String.init) ?? "len")/\(pair.1.count):\(verdictText):tokens=\(tokenText):margin=\(marginText)")
        }
        return (conformant, nearTieRows, divergences)
    }

    /// `incompleteRemeasureSeconds`: the ladder stopped below its bound for a
    /// reason other than correctness; re-measure it after this long.
    private func finish(
        _ record: ContinuousBatchingSelfCheckStore.Record,
        crashedAt: Int?,
        target: ContinuousBatchingSelfCheckTarget,
        incompleteRemeasureSeconds: Double? = nil,
        probeShapeUnmetAt: Int? = nil
    ) async {
        // A swap during the measurement changes the target; drop the result.
        guard !Task.isCancelled,
              await runtime.continuousBatchingSelfCheckTarget(includeDecided: true) == target,
              !Task.isCancelled else { return }
        let fresh = ContinuousBatchingSelfCheck.decide(
            serialTPS: record.serialTPS, measurements: record.measurements, crashedAt: crashedAt,
            probeShapeUnmetAt: probeShapeUnmetAt
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
        let remeasureAfterSeconds = [reconciled.remeasureAfterSeconds, incompleteRemeasureSeconds].compactMap { $0 }.min()
        final.remeasureAfter = remeasureAfterSeconds.map {
            ISO8601DateFormatter().string(from: Date().addingTimeInterval($0))
        }
        if let crashedAt {
            final.crashedSlots = min(record.crashedSlots ?? crashedAt, crashedAt)
        }
        final.inProgressSlots = nil
        final.widthProgress = nil
        final.remeasureInProgress = nil
        final.decidedAt = ISO8601DateFormatter().string(from: Date())
        try? save(final)
        if reconciled.decision != fresh {
            log("event=cb_self_check action=kept_prior_grant fresh_reason=\(fresh.reason) fresh_slots=\(fresh.slots) prior_slots=\(priorGrant ?? 0) kept_slots=\(reconciled.decision.slots) no_gain_streak=\(reconciled.streak)")
        }
        await apply(reconciled.decision, target: target, source: crashedAt == nil ? "measured" : "crash_recovered")
    }

    /// The slots this runtime serves now: the provider status while it is
    /// the primary (it alone writes it), else its own served count
    /// (SPEC-001-R019: a further warm member reports its own).
    private func servedSlotsNow() async -> Int {
        if await runtime.hasProviderStatus() {
            return await providerStatus.snapshot().capacity.maxConcurrency
        }
        return await runtime.warmSetRowReservation().rows
    }

    private func report(decision: String, target: ContinuousBatchingSelfCheckTarget) async {
        await runtime.setContinuousBatchingSelfCheckReport(.init(
            decision: decision,
            servedSlots: await servedSlotsNow(),
            verifiedSlots: 1,
            deferrals: deferrals,
            key: target.key
        ))
        await published()
    }

    private func apply(
        _ decision: ContinuousBatchingSelfCheckDecision,
        target: ContinuousBatchingSelfCheckTarget,
        source: String
    ) async {
        let slots = ContinuousBatchingSelfCheck.servedSlots(
            decision: decision, ownerPinned: ownerPinnedSlots, maxRows: target.grantableRows
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
        verdictRecorder?.applied(key: target.key, decision: decision)
        await published()
    }
}

/// SPEC-001-R019: the continuous-batching self-checks of one process (one
/// per warm-set runtime) measure one at a time, so no check shares the GPU
/// with another check or writes the shared journal beside it. FIFO; an
/// uncontended `acquire` returns at once. A waiter that is cancelled leaves
/// the queue and returns false without the turn.
actor ContinuousBatchingSelfCheckTurn {
    private var busy = false
    private var waiters: [(id: UInt64, continuation: CheckedContinuation<Bool, Never>)] = []
    private var nextID: UInt64 = 0

    /// True holding the turn; false only when cancelled while waiting.
    @discardableResult
    func acquire() async -> Bool {
        guard busy else {
            busy = true
            return true
        }
        nextID &+= 1
        let id = nextID
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// The turn passes straight to the next waiter.
    func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().continuation.resume(returning: true) }
    }

    var isHeld: Bool { busy }
    var waiterCount: Int { waiters.count }

    private func cancelWaiter(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}

/// Set once by the admission-hold check task when it returns.
final class AdmissionHoldCheckCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func markDone() { lock.lock(); done = true; lock.unlock() }
    var isDone: Bool { lock.lock(); defer { lock.unlock() }; return done }
}

/// Whether a buyer is currently seen waiting behind a held check, so each
/// waiting episode is logged once when it starts.
private final class AdmissionHoldBuyerWait: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting = false

    /// Marks a buyer waiting; true when none was waiting before.
    func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        defer { waiting = true }
        return !waiting
    }

    func end() { lock.lock(); waiting = false; lock.unlock() }
}

/// What a self-check admission hold (SPEC-038 FR-CB10 item 3) closes,
/// drains and re-opens: the whole provider for the primary's check, one
/// further warm member for that member's (SPEC-001-R019).
protocol SelfCheckAdmissionHoldScope: Sendable {
    /// Closes admission; returns why it was refused, or nil once held.
    func beginHold(expectedEndAt: Date) async -> String?
    func endHold(outcome: String) async
    func noteHoldSkipped(reason: String) async
    /// The held check may keep running.
    func isServingForHold() async -> Bool
    /// Requests in flight on what the hold closes, for the log.
    func heldRequestsInFlight() async -> Int
    func hasHeldWork() async -> Bool
    func hasBuyerWorkPredatingHold() async -> Bool
    /// What the drain waits for: work admitted before the hold.
    func hasWorkPredatingHold() async -> Bool
}

/// The primary's hold: the provider-wide admission hold, exactly as
/// `ProviderStatus` runs it.
struct ProcessSelfCheckAdmissionHold: SelfCheckAdmissionHoldScope {
    let providerStatus: ProviderStatus

    func beginHold(expectedEndAt: Date) async -> String? {
        await providerStatus.beginSelfCheckAdmissionHold(expectedEndAt: expectedEndAt)
    }

    func endHold(outcome: String) async { await providerStatus.endSelfCheckAdmissionHold(outcome: outcome) }
    func noteHoldSkipped(reason: String) async { await providerStatus.noteSelfCheckAdmissionHoldSkipped(reason: reason) }
    func isServingForHold() async -> Bool { await providerStatus.isServingForSelfCheckAdmissionHold() }
    func heldRequestsInFlight() async -> Int { await providerStatus.requestsInFlightCount() }
    func hasHeldWork() async -> Bool { await providerStatus.hasInferenceWork() }
    func hasBuyerWorkPredatingHold() async -> Bool { await providerStatus.hasBuyerWorkPredatingSelfCheckAdmissionHold() }
    func hasWorkPredatingHold() async -> Bool { await providerStatus.hasInferenceWorkPredatingSelfCheckAdmissionHold() }
}
