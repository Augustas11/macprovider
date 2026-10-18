import ArgumentParser
import Foundation
import MacProviderCore
import MLXLMCommon

// Lab-only: compiled out of plain release builds, command type and
// registration included.
#if DEBUG || MACPROVIDER_LAB_HARNESS
/// JOURNEY-NATIVE-MTP-SERVING hardware steps for one exact tuple, run in one
/// isolated process (no coordinator, no network). Every native-path result is
/// compared with an ordinary runtime over the same target container, at the
/// tuple's qualified slots, active-row bound, and prompt cap. Prints one JSON
/// result document; nonzero exit when any executed step fails.
struct NativeMTPJourneyE2ECommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "native-mtp-journey-e2e",
        abstract: "Run the hidden JOURNEY-NATIVE-MTP-SERVING hardware steps.",
        shouldDisplay: false
    )

    @Option(name: .customLong("root"), help: "Fixture root containing target/ and mtp/ snapshot directories.")
    var root: String

    @Option(name: .customLong("model-id"), help: "Model ID bound into requests/runtime.")
    var modelID: String = nativeMTPHardwareDefaultModelID

    @Option(name: .customLong("qualified-slots"), help: "Tuple qualified_slots.")
    var qualifiedSlots: Int = 8

    @Option(name: .customLong("max-native-active-rows"), help: "Tuple max_native_active_rows.")
    var maxNativeActiveRows: Int = 1

    @Option(name: .customLong("max-prompt-tokens"), help: "Tuple max_prompt_tokens.")
    var maxPromptTokens: Int = 4096

    @Flag(name: .customLong("selftest-only"), help: "Run only step 12 (the challenge-bank record), one model load.")
    var selfTestOnly = false

    @Option(
        name: .customLong("selftest-prompt"),
        help: "Step-12 challenge text, encoded with special tokens; repeat to record one step 12 per text in one load."
    )
    var selfTestPrompts: [String] = []

    @Option(name: .customLong("selftest-challenge-id"), help: "Step-12 challenge_id; unique within one bank.")
    var selfTestChallengeID: String = NativeMTPJourneyRunner.defaultSelfTestChallengeID

    func run() async throws {
        guard ProcessInfo.processInfo.environment["MACPROVIDER_NATIVE_MTP_E2E"] == "1" else {
            FileHandle.standardError.write(Data("native-mtp-journey-e2e: set MACPROVIDER_NATIVE_MTP_E2E=1 on the Mac Studio\n".utf8))
            throw ExitCode(2)
        }
        // Before any MLX device use (the host check samples the GPU).
        NativeMTPHardwareE2ERunner.applyServeProcessSetup(rootPath: root)
        try NativeMTPHardwareE2ERunner.requireStudioHost()
        guard (2...8).contains(qualifiedSlots),
              (1...qualifiedSlots).contains(maxNativeActiveRows),
              (512...1_048_576).contains(maxPromptTokens) else {
            throw ValidationError("invalid tuple shape")
        }
        let journey = NativeMTPJourneyRunner(
            root: root,
            modelID: modelID,
            qualifiedSlots: qualifiedSlots,
            maxNativeActiveRows: maxNativeActiveRows,
            maxPromptTokens: maxPromptTokens,
            selfTestOnly: selfTestOnly,
            selfTestPrompts: selfTestPrompts.isEmpty ? [NativeMTPJourneyRunner.defaultSelfTestPrompt] : selfTestPrompts,
            selfTestChallengeID: selfTestChallengeID
        )
        let result = try await journey.run()
        let data = try JSONSerialization.data(withJSONObject: result.document, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        if !result.passed { throw ExitCode(1) }
    }
}

private struct NativeMTPJourneyStep {
    let id: String
    var checks: [(String, Bool)] = []
    var details: [String: Any] = [:]
    /// Journey-contract subclauses this harness does not exercise; a step
    /// with any is at most `partial`, never `pass`.
    var uncovered: [String] = []

    var passed: Bool { !checks.isEmpty && checks.allSatisfy(\.1) }

    mutating func check(_ name: String, _ ok: Bool) {
        checks.append((name, ok))
    }

    var document: [String: Any] {
        [
            "step_id": id,
            "status": !passed ? "fail" : (uncovered.isEmpty ? "pass" : "partial"),
            "uncovered_contract": uncovered,
            "checks": Dictionary(uniqueKeysWithValues: checks.map { ($0.0, $0.1) }),
            "details": details,
        ]
    }
}

final class NativeMTPJourneyRunner {
    private let root: String
    private let modelID: String
    private let qualifiedSlots: Int
    private let maxNativeActiveRows: Int
    private let maxPromptTokens: Int
    private let selfTestOnly: Bool
    private let selfTestPrompts: [String]
    private let selfTestChallengeID: String
    static let defaultSelfTestPrompt =
        "native_mtp_selftest_v1 synthetic challenge: continue the sequence alpha beta gamma delta"
    static let defaultSelfTestChallengeID = "native-mtp-selftest-journey-0001"
    /// The tuple's request profile admits sampled rows (Qwen3.5). A
    /// greedy-only tuple (glm5_next) must route them to ordinary decode with
    /// reason `sampling` (SPEC-048 R004).
    private var admitsSampledRows = true
    /// step-05 forces rejections at the fixture's real paged-KV block
    /// boundaries: the family block (Qwen3.5 32, glm5_next 256).
    static func boundaryBlockTokens(family: NativeMTPHardwareE2EFamily) -> Int {
        family.blockSizeTokens
    }

    /// step-05 boundary row length: at least four blocks, so a large block
    /// still has several boundaries (Qwen3.5 keeps 256).
    /// step-05: the backend recomputes a native row's drafter independently
    /// on its first committed round and then each time its prefix crosses
    /// another recompute interval. Holds when the first after-finalize record
    /// carries a recompute and every later one is within one interval (plus
    /// one round's commit) of the latest recompute at or before it.
    static func drafterRecomputeCoverageHolds(
        finalizeTokenCounts: [Int],
        recomputedTokenCounts: [Int],
        intervalTokens: Int = PagedKVSharedForwardBackend.labDrafterRecomputeIntervalTokens,
        roundSlackTokens: Int = 8
    ) -> Bool {
        guard let first = finalizeTokenCounts.first,
              recomputedTokenCounts.first == first
        else { return false }
        return finalizeTokenCounts.allSatisfy { tokens in
            guard let latest = recomputedTokenCounts.filter({ $0 <= tokens }).max() else { return false }
            return tokens - latest <= intervalTokens + roundSlackTokens
        }
    }

    /// One committed native round of a row, as step 05 compares it.
    struct NativeRoundRecord {
        /// The bridge's per-row committed-round sequence number (nil when the
        /// record carries none, which fails the comparison).
        var round: Int?
        var tokens: Int
        var digest: String
        var proposedTokens: Int
        var committedProposals: Int?

        /// The round proposed at least one token and committed fewer than it
        /// proposed (at depth 1: its proposal was rejected).
        var rejectedAProposal: Bool {
            guard let committedProposals else { return false }
            return proposedTokens > 0 && committedProposals < proposedTokens
        }
    }

    /// The production record path: one row's after-finalize observer records,
    /// in the order the observer received them.
    static func nativeRoundRecords(_ records: [NativeMTPStateDigestRecord], requestID: String) -> [NativeRoundRecord] {
        records.filter { $0.requestID == requestID && $0.phase == .afterFinalize }.map {
            NativeRoundRecord(
                round: $0.nativeRound,
                tokens: $0.committedKVTokenCount,
                digest: $0.cacheDigestSHA256,
                proposedTokens: $0.proposedTokens,
                committedProposals: $0.committedProposalTokens
            )
        }
    }

    /// step-05 target-state oracle (SPEC-048 MTP-6). Ordinary decode records
    /// its row state once per lockstep window, so the comparable token counts
    /// are the ordinary records inside the native row's range. `native` is one
    /// row's after-finalize records; each carries the bridge's committed-round
    /// sequence number. The sequence must be exactly 0, 1, 2, ... in record
    /// order with strictly increasing token counts: a missing, duplicated or
    /// reordered record fails closed. A compared record follows a rejection
    /// when the round numbered one less rejected a proposal, so its own verify
    /// ran on rolled-back state. Holds when the sequence is intact, every
    /// native record at a comparable count has the ordinary digest, at least
    /// a quarter of those counts (and one) are compared, and at least one
    /// compared record follows a rejection.
    struct AlignedCacheComparison {
        let roundsOrdered: Bool
        let pairs: Int
        let equalPairs: Int
        let pairsFollowingRejection: Int
        let comparableOrdinaryCounts: Int
        let mismatchTokenCounts: [Int]

        var holds: Bool {
            roundsOrdered
                && pairs >= 1
                && equalPairs == pairs
                && pairs * 4 >= comparableOrdinaryCounts
                && pairsFollowingRejection >= 1
        }
    }

    static func alignedCacheComparison(
        native: [NativeRoundRecord],
        ordinary: [(tokens: Int, digest: String)]
    ) -> AlignedCacheComparison {
        let roundsOrdered = native.indices.allSatisfy { index in
            native[index].round == index && (index == 0 || native[index].tokens > native[index - 1].tokens)
        }
        let ordinaryByTokens = Dictionary(ordinary.map { ($0.tokens, $0.digest) }, uniquingKeysWith: { _, latest in latest })
        let pairs = native.indices.compactMap { index in
            ordinaryByTokens[native[index].tokens].map { (index: index, ordinary: $0) }
        }
        let lowest = native.map(\.tokens).min()
        let highest = native.map(\.tokens).max()
        let comparable = ordinaryByTokens.keys.filter { tokens in
            guard let lowest, let highest else { return false }
            return tokens >= lowest && tokens <= highest
        }
        let mismatches = pairs.filter { native[$0.index].digest != $0.ordinary }.map { native[$0.index].tokens }
        // Only meaningful on an intact sequence, where index - 1 is round - 1.
        let followingRejection = roundsOrdered ? pairs.filter { pair in
            pair.index > 0 && native[pair.index - 1].rejectedAProposal
        } : []
        return AlignedCacheComparison(
            roundsOrdered: roundsOrdered,
            pairs: pairs.count,
            equalPairs: pairs.count - mismatches.count,
            pairsFollowingRejection: followingRejection.count,
            comparableOrdinaryCounts: comparable.count,
            mismatchTokenCounts: Array(mismatches.prefix(16))
        )
    }

    static func boundaryRowTokens(blockTokens: Int) -> Int {
        max(256, 4 * blockTokens)
    }

    /// The step-05 override for `family`. Qwen3.5 keeps the crossing-only
    /// rule it always had; a larger block also forces the round that starts
    /// on a boundary an accepted round stepped over.
    static func boundaryMode(family: NativeMTPHardwareE2EFamily) -> NativeMTPLabProposalOverride.Mode {
        .blockBoundary(blockTokens: boundaryBlockTokens(family: family), includeBlockStart: family != .qwen35)
    }

    init(
        root: String,
        modelID: String,
        qualifiedSlots: Int,
        maxNativeActiveRows: Int,
        maxPromptTokens: Int,
        selfTestOnly: Bool = false,
        selfTestPrompts: [String] = [NativeMTPJourneyRunner.defaultSelfTestPrompt],
        selfTestChallengeID: String = NativeMTPJourneyRunner.defaultSelfTestChallengeID
    ) {
        self.root = root
        self.modelID = modelID
        self.qualifiedSlots = qualifiedSlots
        self.maxNativeActiveRows = maxNativeActiveRows
        self.maxPromptTokens = maxPromptTokens
        self.selfTestOnly = selfTestOnly
        self.selfTestPrompts = selfTestPrompts
        self.selfTestChallengeID = selfTestChallengeID
    }

    func run() async throws -> (document: [String: Any], passed: Bool) {
        let family = NativeMTPHardwareE2ERunner(rootPath: root).family
        admitsSampledRows = family.admitsSampledRows
        let boundaryTokens = Self.boundaryRowTokens(blockTokens: Self.boundaryBlockTokens(family: family))
        let outputBudget = max(512, boundaryTokens)
        let runner = NativeMTPHardwareE2ERunner(
            rootPath: root,
            modelID: modelID,
            maxBatch: qualifiedSlots,
            maxNativeActiveRows: maxNativeActiveRows,
            maxPromptTokens: maxPromptTokens,
            maxPhysicalBlocks: NativeMTPHardwareE2ERunner.sizedMaxPhysicalBlocks(
                slots: qualifiedSlots,
                promptTokens: maxPromptTokens + 256,
                outputTokens: outputBudget
            )
        )
        let recorder = NativeMTPHardwareAdmissionRecorder()
        let fixture = try await runner.loadRuntimeFixture(
            maxContextTokens: maxPromptTokens + outputBudget + 512,
            ordinaryAdmissionRecorder: nil,
            nativeAdmissionRecorder: recorder
        )
        let ordinary = fixture.runtimes.ordinary
        let native = fixture.runtimes.native
        let override = NativeMTPLabProposalOverride(rules: [
            (prefix: "journey-reject-all-", mode: .everyRound),
            (prefix: "journey-boundary-", mode: Self.boundaryMode(family: family)),
        ])
        guard await native.installLabNativeMTPProposalOverride(override) else {
            throw NativeMTPHardwareE2EError.assertionFailed("native runtime has no continuous-batch scheduler")
        }
        let gateRecorder = NativeMTPLoadGateRecorder()
        _ = await native.installLabNativeMTPLoadGateRecorder(gateRecorder)
        // A throwing step is a failed step, recorded with its error; the run
        // continues so one failure does not hide the others.
        var steps: [NativeMTPJourneyStep] = []
        func run(_ id: String, _ body: () async throws -> NativeMTPJourneyStep) async {
            let started = Date()
            do {
                steps.append(try await body())
            } catch {
                var failed = NativeMTPJourneyStep(id: id)
                failed.check("completed_without_error", false)
                failed.details["error"] = String(describing: error)
                steps.append(failed)
            }
            // The result document prints only at the end; a run killed at its
            // time limit still shows which steps finished, how, and how long.
            if let step = steps.last {
                let status = step.document["status"] as? String ?? "fail"
                let failing = step.checks.filter { !$0.1 }.map(\.0).prefix(8).joined(separator: ",")
                FileHandle.standardError.write(Data(
                    "native-mtp-journey-e2e: step=\(step.id) status=\(status) elapsed_s=\(Int(Date().timeIntervalSince(started))) failing=\(failing.isEmpty ? "-" : failing)\n".utf8
                ))
            }
        }
        // --selftest-only: step 12 alone, for a challenge-bank record.
        if !selfTestOnly {
            await run("step-04-serial-token-oracle") {
                try await serialOracle(ordinary: ordinary, native: native, recorder: recorder, proposalDepth: fixture.admission.maxProposalDepth)
            }
            await run("step-05-cache-state-boundary") {
                try await cacheStateBoundary(
                    ordinary: ordinary, native: native, recorder: recorder, override: override,
                    boundaryTokens: boundaryTokens
                )
            }
            await run("step-06-streaming-stop") {
                try await streamingStop(ordinary: ordinary, native: native, recorder: recorder)
            }
            await run("step-07-08-mixed-multirow-capacity") {
                try await mixedMultirowAndCapacity(
                    ordinary: ordinary,
                    native: native,
                    recorder: recorder,
                    gateRecorder: gateRecorder,
                    container: fixture.runtimes.targetContainer
                )
            }
            await run("step-09-cancellation") {
                try await cancellation(ordinary: ordinary, native: native, recorder: recorder)
            }
        }
        for (index, prompt) in selfTestPrompts.enumerated() {
            await run("step-12-native-selftest") {
                try await selfTest(ordinary: ordinary, native: native, fixture: fixture, prompt: prompt, promptIndex: index)
            }
        }
        if !selfTestOnly {
            await run("step-10-warm-swap") {
                try await warmSwapBoundary(ordinary: ordinary, native: native, recorder: recorder, fixture: fixture)
            }
        }
        let reportSteps = steps.sorted { stepOrder($0.id) < stepOrder($1.id) }
        let passed = reportSteps.allSatisfy(\.passed)
        // pass only when every executed step is complete; partial when any
        // passing step leaves journey clauses uncovered.
        let executedStatus = !passed ? "fail" : (reportSteps.allSatisfy { $0.uncovered.isEmpty } ? "pass" : "partial")
        let document: [String: Any] = [
            "schema": "macprovider.native-mtp-journey-hardware-result.v1",
            // Covers only the hardware steps below; never a journey verdict.
            "journey_complete": false,
            "executed_steps_status": executedStatus,
            "covered_steps": selfTestOnly ? ["step-12-native-canary (provider-local self-test half)"] : [
                "step-04-serial-token-oracle",
                "step-05-cache-state-boundary",
                "step-06-streaming-stop",
                "step-07-mixed-multirow",
                "step-08-capacity-and-depth-zero",
                "step-09-cancellation",
                "step-10-warm-swap",
                "step-12-native-canary (provider-local self-test half)",
            ],
            "pending_steps": [
                "step-01-bind-tuple",
                "step-02-capability-negatives",
                "step-03-artifact-security-negatives",
                "step-11-accounting",
                "step-12-native-canary (coordinator SPEC-031-R033 half)",
                "step-14-studio-and-tier-benchmark",
                "step-15-redaction-review",
            ],
            "evidence_class": "lab_isolated_no_join",
            "model_id": modelID,
            "target_sha256": fixture.targetIdentity.digest,
            "mtp_sha256": fixture.mtpIdentity.digest,
            "tokenizer_sha256": fixture.tokenizerSHA256,
            "mtp_manifest_sha256": fixture.manifestSHA256,
            "qualified_slots": qualifiedSlots,
            "max_native_active_rows": maxNativeActiveRows,
            "max_prompt_tokens": maxPromptTokens,
            "request_feature_profile": family.requestFeatureProfile,
            "machine": [
                "chip": fixture.machine.chip,
                "ram_gb": fixture.machine.ramGB,
                "os_version": fixture.machine.osVersion,
            ],
            "steps": reportSteps.map(\.document),
        ]
        return (document, passed)
    }

    private func stepOrder(_ id: String) -> Int {
        switch id {
        case "step-04-serial-token-oracle": return 4
        case "step-05-cache-state-boundary": return 5
        case "step-06-streaming-stop": return 6
        case "step-07-08-mixed-multirow-capacity": return 7
        case "step-09-cancellation": return 9
        case "step-10-warm-swap": return 10
        case "step-12-native-selftest": return 12
        default: return Int.max
        }
    }

    // MARK: steps

    /// step-04: native output equals isolated ordinary output (tokens, text,
    /// usage, terminal) for greedy and seeded sampled rows, streaming off.
    private func serialOracle(ordinary: ModelRuntime, native: ModelRuntime, recorder: NativeMTPHardwareAdmissionRecorder, proposalDepth: Int) async throws -> NativeMTPJourneyStep {
        var step = NativeMTPJourneyStep(id: "step-04-serial-token-oracle")
        let cases: [(String, String, Double, Double)] = [
            ("journey-serial-greedy-0", "Explain in three sentences why the sky appears blue.", 0, 1),
            ("journey-serial-greedy-1", "Write a short Python function that reverses a linked list.", 0, 1),
            ("journey-serial-greedy-2", "List five prime numbers greater than one hundred and say why each is prime.", 0, 1),
            ("journey-serial-sampled-0", "Describe a quiet harbor town at dawn.", 0.7, 0.9),
            ("journey-serial-sampled-1", "Give three tips for learning a new language.", 1.0, 1.0),
        ]
        var compared = 0
        var accepted: UInt64 = 0
        var rejected: UInt64 = 0
        for (id, prompt, temperature, topP) in cases {
            let request = try makeRequest(id: id, prompt: prompt, maxTokens: 192, temperature: temperature, topP: topP)
            let expected = try await ordinary.complete(request)
            let before = await native.currentSnapshot().nativeMTPStatus
            let actual = try await native.complete(request)
            let delta = NativeMTPStatusDelta(before: before, after: await native.currentSnapshot().nativeMTPStatus)
            step.check("\(id).parity", same(expected, actual))
            if temperature != 0 || topP != 1, !admitsSampledRows {
                // Greedy-only tuple: the sampled row is served by ordinary
                // decode, refused at admission with reason `sampling`.
                step.check("\(id).routed_ordinary_sampling", routedOrdinaryForSampling(recorder, id))
                step.check("\(id).no_native_proposals", delta.proposedTokens == 0)
                compared += 1
                continue
            }
            step.check("\(id).native_admitted", lastPath(recorder, id) == .nativeMTP)
            step.check("\(id).proposed", delta.proposedTokens > 0)
            accepted += delta.acceptedTokens
            rejected += delta.rejectedTokens
            compared += 1
        }
        // Token-ID oracle: decoded text and counts can hide a different token
        // sequence, so compare generated token IDs on the probe path for the
        // same templated greedy prompts (depth fixed at the tuple maximum).
        for (index, (_, prompt, temperature, _)) in cases.enumerated() where temperature == 0 {
            let promptTokenIDs = try await servedPromptTokens(prompt, runtime: ordinary)
            let oracle = try await ordinary.labTokenProbe(
                id: "journey-serial-tokens-ordinary-\(index)",
                promptTokenIDs: promptTokenIDs,
                maxCompletionTokens: 64,
                nativeDepth: nil
            )
            let probe = try await native.labTokenProbe(
                id: "journey-serial-tokens-native-\(index)",
                promptTokenIDs: promptTokenIDs,
                maxCompletionTokens: 64,
                nativeDepth: 1
            )
            step.check("greedy-\(index).token_ids_equal", !oracle.generatedTokens.isEmpty && oracle.generatedTokens == probe.generatedTokens)
        }
        // At depth one each round is all-accepted or none-accepted; both must
        // occur (partial acceptance needs depth >= 2, which this tuple lacks).
        step.check("acceptance_all_and_none_observed", accepted > 0 && rejected > 0)
        step.check("partial_acceptance_tuple_inapplicable", proposalDepth == 1)
        step.details["requests"] = compared
        step.details["accepted"] = accepted
        step.details["rejected"] = rejected
        step.details["proposal_depth"] = proposalDepth
        step.details["partial_acceptance_inapplicability"] = "partial acceptance within one round requires proposal depth >= 2; this exact tuple signs depth 1"
        return step
    }

    /// step-05: forced rejection on every round and on every round whose
    /// staged positions cross a paged-KV block boundary; output and state
    /// stay exact (later tokens of the same row still match ordinary).
    private func cacheStateBoundary(
        ordinary: ModelRuntime,
        native: ModelRuntime,
        recorder: NativeMTPHardwareAdmissionRecorder,
        override: NativeMTPLabProposalOverride,
        boundaryTokens: Int
    ) async throws -> NativeMTPJourneyStep {
        var step = NativeMTPJourneyStep(id: "step-05-cache-state-boundary")
        let ordinaryStateObserver = NativeMTPStateDigestObserver()
        let nativeStateObserver = NativeMTPStateDigestObserver()
        guard await ordinary.installLabNativeMTPStateDigestObserver(ordinaryStateObserver),
              await native.installLabNativeMTPStateDigestObserver(nativeStateObserver) else {
            _ = await ordinary.installLabNativeMTPStateDigestObserver(nil)
            _ = await native.installLabNativeMTPStateDigestObserver(nil)
            throw NativeMTPHardwareE2EError.assertionFailed("runtimes cannot install paired native-MTP state digest observers")
        }
        do {
            let cases = [
                ("journey-reject-all-0", "Tell a detailed story about a lighthouse keeper (journey-reject-all-0)."),
                ("journey-boundary-0", "Tell a detailed story about a lighthouse keeper (journey-boundary-0)."),
                ("journey-boundary-1", "Tell a detailed story about a lighthouse keeper (journey-boundary-1)."),
            ]
            for (id, prompt) in cases {
                let request = try makeRequest(
                    id: id,
                    prompt: prompt,
                    maxTokens: id.hasPrefix("journey-boundary-") ? boundaryTokens : 256,
                    temperature: 0,
                    topP: 1
                )
                let expected = try await ordinary.complete(request)
                let before = await native.currentSnapshot().nativeMTPStatus
                let actual = try await native.complete(request)
                let delta = NativeMTPStatusDelta(before: before, after: await native.currentSnapshot().nativeMTPStatus)
                let forced = override.overriddenRounds(requestID: id)
                step.check("\(id).parity", same(expected, actual))
                step.check("\(id).native_admitted", lastPath(recorder, id) == .nativeMTP)
                step.check("\(id).forced_rejections_applied", forced > 0)
                // Every forced proposal must be rejected (natural rejections can only
                // add); on the reject-all row every proposal is forced.
                step.check("\(id).every_forced_proposal_rejected", forced > 0 && delta.rejectedTokens >= UInt64(forced))
                if id.hasPrefix("journey-reject-all-") {
                    step.check("\(id).all_rejected", delta.proposedTokens == UInt64(forced) && delta.rejectedTokens == delta.proposedTokens)
                }
                let promptTokenIDs = try await servedPromptTokens(prompt, runtime: ordinary)
                let oracleProbe = try await ordinary.labTokenProbe(
                    id: "\(id)-state-oracle",
                    promptTokenIDs: promptTokenIDs,
                    maxCompletionTokens: 64,
                    nativeDepth: nil
                )
                let nativeProbe = try await native.labTokenProbe(
                    id: "\(id)-state-native",
                    promptTokenIDs: promptTokenIDs,
                    maxCompletionTokens: 64,
                    nativeDepth: 1
                )
                let stateDigest = nativeProbe.nativeMTPCounters.flatMap { counters in
                    committedStateDigest(
                        promptTokenIDs: promptTokenIDs,
                        result: nativeProbe,
                        counters: counters
                    )
                }
                let oracleStateDigest = nativeProbe.nativeMTPCounters.flatMap { counters in
                    committedStateDigest(
                        promptTokenIDs: promptTokenIDs,
                        result: oracleProbe,
                        counters: counters
                    )
                }
                step.check("\(id).state_probe_tokens_equal", !nativeProbe.generatedTokens.isEmpty && nativeProbe.generatedTokens == oracleProbe.generatedTokens)
                step.check("\(id).state_probe_terminal_equal", nativeProbe.terminalStatus == oracleProbe.terminalStatus)
                step.check("\(id).state_probe_native_counters_present", nativeProbe.nativeMTPCounters != nil)
                step.check("\(id).token_counter_terminal_digest_parity", stateDigest != nil && stateDigest == oracleStateDigest)
                let ordinaryStateRecords = ordinaryStateObserver.snapshot().filter { $0.requestID == id }
                let ordinaryAfterDecode = ordinaryStateRecords.filter { $0.phase == .ordinaryAfterDecode }
                let stateRecords = nativeStateObserver.snapshot().filter { $0.requestID == id }
                let phases = Set(stateRecords.map(\.phase))
                let afterVerify = stateRecords.filter { $0.phase == .afterVerify }
                let afterFinalize = stateRecords.filter { $0.phase == .afterFinalize }
                let beforeAbort = stateRecords.filter { $0.phase == .beforeAbort }
                let afterAbort = stateRecords.filter { $0.phase == .afterAbort }
                let terminalPhasePresent = phases.contains(.afterFinalize) || phases.contains(.afterAbort) || phases.contains(.abort)
                // The ordinary oracle's state exists only at its decode-window
                // ends (one record per window), so only those token counts can
                // be compared; every native round that lands on one must match.
                let alignment = Self.alignedCacheComparison(
                    native: Self.nativeRoundRecords(stateRecords, requestID: id),
                    ordinary: ordinaryAfterDecode.map { (tokens: $0.committedKVTokenCount, digest: $0.cacheDigestSHA256) }
                )
                step.check("\(id).ordinary_state_observer_after_decode", !ordinaryAfterDecode.isEmpty)
                step.check("\(id).native_state_observer_records", !stateRecords.isEmpty)
                step.check("\(id).native_state_observer_after_verify", !afterVerify.isEmpty)
                step.check("\(id).native_state_observer_terminal_phase", terminalPhasePresent)
                step.check("\(id).state_observer_raw_digest_shape", (ordinaryStateRecords + stateRecords).allSatisfy {
                    isSHA256Hex($0.digestSHA256)
                        && isSHA256Hex($0.cacheDigestSHA256)
                        && ($0.drafterDigestSHA256.map { isSHA256Hex($0) } ?? true)
                        && ($0.pendingTargetDigestSHA256.map { isSHA256Hex($0) } ?? true)
                })
                step.check("\(id).aligned_prefix_cache_digest_comparison", alignment.holds)
                let recomputedDrafterRecords = stateRecords.filter {
                    $0.phase == .afterFinalize && $0.drafterRecomputeDigestSHA256 != nil
                }
                // The O(context) recompute runs on the first committed round
                // and once per crossed recompute interval, not every round.
                step.check("\(id).independent_drafter_recomputation_observed", Self.drafterRecomputeCoverageHolds(
                    finalizeTokenCounts: afterFinalize.map(\.committedKVTokenCount),
                    recomputedTokenCounts: recomputedDrafterRecords.map(\.committedKVTokenCount)
                ))
                // Drafter byte parity is diagnostic: packed/full-prefix kernels
                // may accumulate differently. Target-cache and token parity
                // remain mandatory checks above (SPEC-048 MTP-5/MTP-6).
                let drafterRecomputeByteEqual = recomputedDrafterRecords.allSatisfy {
                    $0.drafterDigestSHA256 != nil && $0.drafterDigestSHA256 == $0.drafterRecomputeDigestSHA256
                }
                if id.hasPrefix("journey-reject-all-") {
                    // A rejected depth-1 round still commits its base column
                    // (MTP-6 commit(0)); only cancellation aborts a round, and
                    // step 09 checks abort stability.
                    step.check("\(id).rejected_rounds_commit_without_abort",
                        !phases.contains(.beforeAbort) && !phases.contains(.afterAbort)
                            && afterFinalize.count >= forced
                            && afterFinalize.allSatisfy { $0.committedProposalTokens == 0 })
                }
                step.details[id] = [
                    "forced_rounds": forced,
                    "proposed": delta.proposedTokens,
                    "accepted": delta.acceptedTokens,
                    "rejected": delta.rejectedTokens,
                    "token_counter_terminal_digest": stateDigest ?? "",
                    "state_probe_tokens": nativeProbe.generatedTokens.count,
                    "ordinary_state_observer_record_count": ordinaryStateRecords.count,
                    "native_state_observer_phases": Array(phases.map(\.rawValue)).sorted(),
                    "native_state_observer_record_count": stateRecords.count,
                    "aligned_prefix_cache_pairs": alignment.pairs,
                    "aligned_prefix_cache_equal_pairs": alignment.equalPairs,
                    "aligned_prefix_cache_pairs_following_rejection": alignment.pairsFollowingRejection,
                    "native_rounds_ordered": alignment.roundsOrdered,
                    "aligned_prefix_cache_comparable_ordinary_counts": alignment.comparableOrdinaryCounts,
                    "aligned_prefix_cache_mismatch_token_counts": alignment.mismatchTokenCounts,
                    "independent_drafter_recompute_records": recomputedDrafterRecords.count,
                    "independent_drafter_recompute_byte_equal": drafterRecomputeByteEqual,
                    "abort_records": beforeAbort.count + afterAbort.count,
                    "state_observer_latest_cache_sha256": stateRecords.last?.cacheDigestSHA256 ?? "",
                    "state_observer_latest_target_sha256": stateRecords.last?.pendingTargetDigestSHA256 ?? "",
                    "state_observer_scope": "ordinary_window_end_vs_native_after_finalize_oracle_state_digest",
                ]
            }
            _ = await ordinary.installLabNativeMTPStateDigestObserver(nil)
            _ = await native.installLabNativeMTPStateDigestObserver(nil)
            return step
        } catch {
            _ = await ordinary.installLabNativeMTPStateDigestObserver(nil)
            _ = await native.installLabNativeMTPStateDigestObserver(nil)
            throw error
        }
    }

    /// step-06: streaming equals non-streaming equals ordinary for a stop
    /// string, a max-tokens terminal, and a sampled row.
    private func streamingStop(ordinary: ModelRuntime, native: ModelRuntime, recorder: NativeMTPHardwareAdmissionRecorder) async throws -> NativeMTPJourneyStep {
        var step = NativeMTPJourneyStep(id: "step-06-streaming-stop")
        let phaseTrap = NativeMTPLabPhaseTrap(cancellations: [:])
        let phaseTrapInstalled = await native.installLabNativeMTPPhaseTrap(phaseTrap)
        let commitObserver = NativeMTPLabCommittedTokenTimingObserver()
        let commitObserverInstalled = await native.installLabNativeMTPCommitTimingObserver(commitObserver)
        guard phaseTrapInstalled, commitObserverInstalled else {
            _ = await native.installLabNativeMTPPhaseTrap(nil)
            _ = await native.installLabNativeMTPCommitTimingObserver(nil)
            throw NativeMTPHardwareE2EError.assertionFailed("native runtime cannot install step-06 phase/commit observers")
        }
        do {
            let cases: [(String, String, [String]?, Int, Double)] = [
                ("journey-stream-stop", "Count from one to thirty in English words, separated by commas.", [" twelve"], 256, 0),
                ("journey-stream-length", "Write a long essay about the history of printing.", nil, 160, 0),
                // The A3B response did not reach EOS inside 64 tokens, so that cap
                // accidentally duplicated the length-terminal case instead of
                // exercising the model's end-of-sequence terminal.
                ("journey-stream-eos", "Reply with exactly the single word OK and nothing else.", nil, 512, 0),
                ("journey-stream-sampled", "Invent a recipe for a winter soup.", nil, 160, 0.7),
            ]
            var terminals: [String: String] = [:]
            var streamResults: [String: CompletionResult] = [:]
            for (id, prompt, stop, maxTokens, temperature) in cases {
                // Distinct scheduler ids per mode: a reused id would replay the
                // retained terminal result instead of generating again. Each
                // mode compares with ordinary under the same id (same seed).
                let plainID = id + "-ns"
                let streamID = id + "-s"
                let plain = try makeRequest(id: plainID, prompt: prompt, maxTokens: maxTokens, temperature: temperature, topP: 1, stop: stop)
                let streamed = try makeRequest(id: streamID, prompt: prompt, maxTokens: maxTokens, temperature: temperature, topP: 1, stop: stop, stream: true)
                let expected = try await ordinary.complete(plain)
                let nonStreaming = try await native.complete(plain)
                let (expectedStream, expectedText) = try await streamCollect(streamed, runtime: ordinary)
                let (streamingResult, text) = try await streamCollect(streamed, runtime: native)
                step.check("\(id).non_streaming_parity", same(expected, nonStreaming))
                step.check("\(id).streaming_parity", same(expectedStream, streamingResult))
                step.check("\(id).streamed_text_equals_content", text == streamingResult.content && expectedText == expectedStream.content)
                if temperature == 0 {
                    step.check("\(id).streaming_equals_non_streaming", same(expected, streamingResult))
                }
                if temperature != 0, !admitsSampledRows {
                    step.check(
                        "\(id).routed_ordinary_sampling",
                        routedOrdinaryForSampling(recorder, plainID) && routedOrdinaryForSampling(recorder, streamID)
                    )
                } else {
                    step.check("\(id).native_admitted", lastPath(recorder, plainID) == .nativeMTP && lastPath(recorder, streamID) == .nativeMTP)
                }
                terminals[id] = expected.finishReason
                streamResults[id] = streamingResult
            }
            step.check("stop_terminal_observed", terminals["journey-stream-stop"] == "stop")
            step.check("length_terminal_observed", terminals["journey-stream-length"] == "length")
            step.check("eos_terminal_observed", terminals["journey-stream-eos"] == "stop")

            let stopStreamID = "journey-stream-stop-s"
            let stopPhaseEvents = phaseTrap.snapshot().filter { $0.requestIDs.contains(stopStreamID) }
            let stopCommitEvents = commitObserver.snapshot().filter { $0.requestID == stopStreamID }
            let stopBeforeFinalizeEvents = stopPhaseEvents.filter { $0.phase == .beforeFinalize }
            let stopOutputCounts = stopCommitEvents.map(\.outputCount)
            let stopGeneratedTokens = streamResults["journey-stream-stop"]?.generatedCompletionTokens ?? 0
            let stopAPITokenCount = streamResults["journey-stream-stop"]?.completionTokens ?? 0
            let stopFinalVisibleTokenCount = stopOutputCounts.max() ?? 0
            step.check("stop_round_boundary.phase_events_observed", !stopPhaseEvents.isEmpty)
            step.check("stop_round_boundary.proposal_verify_finalize_events",
                stopPhaseEvents.contains { $0.phase == .afterProposal }
                    && stopPhaseEvents.contains { $0.phase == .afterVerify }
                    && !stopBeforeFinalizeEvents.isEmpty)
            step.check("stop_round_boundary.spans_multiple_native_finalize_rounds", stopBeforeFinalizeEvents.count >= 2)
            step.check("stop_round_boundary.commit_token_positions_observed", !stopCommitEvents.isEmpty)
            step.check("stop_round_boundary.stop_tokens_stripped_after_visible_prefix",
                stopGeneratedTokens > stopFinalVisibleTokenCount && stopFinalVisibleTokenCount > 0)
            step.check("stop_round_boundary.visible_prefix_crossed_commit_positions",
                stopOutputCounts.contains { $0 > 0 && $0 < stopFinalVisibleTokenCount })
            step.details["stop_round_boundary"] = [
                "request_id": stopStreamID,
                "stop_text": " twelve",
                "finish_reason": streamResults["journey-stream-stop"]?.finishReason ?? "",
                "api_completion_tokens": stopAPITokenCount,
                "visible_output_tokens_from_commit_events": stopFinalVisibleTokenCount,
                "generated_completion_tokens": stopGeneratedTokens,
                "phase_events": phaseEventDetails(stopPhaseEvents),
                "commit_output_counts": stopOutputCounts,
            ]

            let earlyStopID = "journey-stream-early-consumer-stop"
            let earlyStopRequest = try makeRequest(
                id: earlyStopID,
                prompt: "Write a long numbered explanation of how sailors navigate by stars.",
                maxTokens: 512,
                temperature: 0,
                topP: 1,
                stream: true
            )
            let earlyStopChunks = NativeMTPJourneyCounter()
            let earlyStopHandle = try await native.acquireRequestHandle(earlyStopRequest)
            var earlyStopCancelled = false
            var earlyStopCompleted = false
            do {
                _ = try await native.stream(
                    earlyStopRequest,
                    with: earlyStopHandle,
                    shouldCancel: { earlyStopChunks.value >= 4 }
                ) { chunk in
                    if case .content(let text) = chunk, !text.isEmpty { earlyStopChunks.increment() }
                }
                earlyStopCompleted = true
            } catch is CancellationError {
                earlyStopCancelled = true
            } catch {
                step.details["early_consumer_stop_error"] = String(describing: error)
            }
            await native.unregisterInFlight(earlyStopHandle.registrationID)
            let earlyStopIdle = try await waitForSchedulerIdle(native)
            step.check("early_consumer_stop.native_admitted", lastPath(recorder, earlyStopID) == .nativeMTP)
            step.check("early_consumer_stop.after_visible_output", earlyStopChunks.value >= 4)
            step.check("early_consumer_stop.cancelled_not_completed", earlyStopCancelled && !earlyStopCompleted)
            step.check("early_consumer_stop.scheduler_released_row", earlyStopIdle)
            let faultID = "journey-stream-postoutput-fault"
            let fault = NativeMTPLabPostoutputFault(requestIDs: [faultID])
            let faultInstalled = await native.installLabNativeMTPPostoutputFault(fault)
            let faultBefore = await native.currentSnapshot().nativeMTPStatus
            let faultRequest = try makeRequest(
                id: faultID,
                prompt: "Write a long numbered field guide to constellations used by navigators.",
                maxTokens: 512,
                temperature: 0,
                topP: 1,
                stream: true
            )
            var faultChunks = 0
            var faultCompleted = false
            var faultErrored = false
            do {
                _ = try await streamCollect(faultRequest, runtime: native) { piece in
                    if !piece.isEmpty { faultChunks += 1 }
                }
                faultCompleted = true
            } catch {
                faultErrored = true
                step.details["postoutput_fault_error"] = String(describing: error)
            }
            _ = await native.installLabNativeMTPPostoutputFault(nil)
            let faultAfter = await native.currentSnapshot().nativeMTPStatus
            step.check("postoutput_fault.installed", faultInstalled)
            step.check("postoutput_fault.native_admitted", lastPath(recorder, faultID) == .nativeMTP)
            step.check("postoutput_fault.after_visible_output", faultChunks > 0)
            step.check("postoutput_fault.failed_not_completed", faultErrored && !faultCompleted)
            step.check("postoutput_fault.counter_incremented", faultAfter.postoutputFailures > faultBefore.postoutputFailures)
            step.check("postoutput_fault.hook_fired", fault.snapshot().contains(faultID))

            step.details["terminals"] = terminals
            step.details["early_consumer_stop_chunks"] = earlyStopChunks.value
            step.details["postoutput_fault_chunks"] = faultChunks
            step.details["postoutput_fault_fired"] = fault.snapshot()
            _ = await native.installLabNativeMTPPhaseTrap(nil)
            _ = await native.installLabNativeMTPCommitTimingObserver(nil)
            return step
        } catch {
            _ = await native.installLabNativeMTPPhaseTrap(nil)
            _ = await native.installLabNativeMTPCommitTimingObserver(nil)
            throw error
        }
    }

    /// step-07 + step-08: one batch at the tuple's qualified slots mixing a
    /// native row, ineligible ordinary rows, load-gate downgrades, unequal
    /// prompts/outputs/arrivals, and a prompt above the signed cap; every row
    /// matches ordinary, the gate held the native row at depth zero and
    /// restored it, and nothing overcommitted.
    private func mixedMultirowAndCapacity(
        ordinary: ModelRuntime,
        native: ModelRuntime,
        recorder: NativeMTPHardwareAdmissionRecorder,
        gateRecorder: NativeMTPLoadGateRecorder,
        container: ModelContainer
    ) async throws -> NativeMTPJourneyStep {
        var step = NativeMTPJourneyStep(id: "step-07-08-mixed-multirow-capacity")
        var requests: [ChatCompletionRequest] = []
        for row in 0..<qualifiedSlots {
            let id = "journey-mixed-\(row)"
            let ineligible = row % 3 == 2
            requests.append(try makeRequest(
                id: id,
                prompt: "Row \(row): summarize the causes and effects of the industrial revolution in \(3 + row) points.",
                maxTokens: 256 + 32 * row,
                // Greedy: a sampled row's draws depend on batch composition
                // timing even on the ordinary path, so only greedy rows give
                // a cross-runtime oracle (sampled parity is step-04/06).
                temperature: 0,
                topP: 1,
                conversationKey: ineligible ? "conv:journey-mixed-\(row)" : nil
            ))
        }
        let expected = try await completeDeterministicBatch(requests, runtime: ordinary)
        // Control: the exact ordinary batch composition must reproduce itself,
        // or a native mismatch would mean nothing.
        // Fresh request ids and keys: the scheduler rejects a reused id with a
        // different body, and a reused key would hit the conversation cache.
        let control = try await completeDeterministicBatch(
            requests.map {
                $0.withRequestID(($0.requestID ?? "") + "-control")
                    .withConversationKey($0.conversationKey.map { $0 + "-control" })
            },
            runtime: ordinary
        )
        let actual = try await completeDeterministicBatch(requests, runtime: native)
        var paths: [String: String] = [:]
        var reasons: [String: String] = [:]
        for request in requests {
            let id = request.requestID ?? ""
            step.check("\(id).ordinary_control_reproducible", expected[id].map { exp in control[id + "-control"].map { same(exp, $0) } ?? false } ?? false)
            step.check("\(id).parity", expected[id].map { exp in actual[id].map { same(exp, $0) } ?? false } ?? false)
            let admission = recorder.requestSnapshot().last { $0.requestID == id }
            paths[id] = admission?.admission.effectivePath.rawValue ?? "missing"
            reasons[id] = admission?.admission.selection.nativeMTPReason?.rawValue ?? ""
        }
        let nativeRows = paths.values.filter { $0 == DecodePath.nativeMTP.rawValue }.count
        let downgraded = reasons.values.filter { $0 == NativeMTPSelectorReason.capacityAboveNativeBound.rawValue }.count
        let ineligible = reasons.values.filter { $0 == NativeMTPSelectorReason.conversationKey.rawValue }.count
        step.check("mixed_paths_in_one_batch", nativeRows >= 1 && nativeRows <= maxNativeActiveRows && downgraded >= 1 && ineligible >= 1)
        let summary = gateRecorder.summary(requestIDs: Set(requests.compactMap(\.requestID)))
        step.check("depth_zero_hold_observed", summary.depthZeroRounds > 0)
        step.check("holds_resolved", summary.heldUnresolved == 0
            && summary.holdEpisodes == summary.depthRestorations + summary.heldFinishesClean)
        let snapshot = await native.currentSnapshot()
        step.check("batch_depth_reached_qualified_slots", (snapshot.continuousBatching?.scheduler?.maxObservedBatchDepth ?? 0) >= qualifiedSlots)
        step.details["max_observed_batch_depth"] = snapshot.continuousBatching?.scheduler?.maxObservedBatchDepth ?? 0
        step.check("slots_unchanged", snapshot.continuousBatching?.scheduler?.slotsTotal == qualifiedSlots)

        // Signed prompt cap: a prompt above max_prompt_tokens selects ordinary.
        let longPrompt = try await prompt(container: container, minimumTokens: maxPromptTokens + 64)
        let capped = try makeRequest(id: "journey-prompt-cap", prompt: longPrompt, maxTokens: 64, temperature: 0, topP: 1)
        let cappedExpected = try await ordinary.complete(capped)
        let cappedActual = try await native.complete(capped)
        step.check("prompt_cap.parity", same(cappedExpected, cappedActual))
        let cappedAdmission = recorder.requestSnapshot().last { $0.requestID == "journey-prompt-cap" }
        step.check("prompt_cap.selected_ordinary", cappedAdmission?.admission.effectivePath == .ordinary
            && cappedAdmission?.admission.selection.nativeMTPReason == .capabilityMismatch)
        step.details["oracle_batch_composition"] = requests.compactMap(\.requestID)
        step.details["paths"] = paths
        step.details["selector_reasons"] = reasons
        step.details["prompt_cap_reason"] = cappedAdmission?.admission.selection.nativeMTPReason?.rawValue ?? ""
        step.details["load_gate"] = [
            "depth_zero_rounds": summary.depthZeroRounds,
            "hold_episodes": summary.holdEpisodes,
            "depth_restorations": summary.depthRestorations,
            "held_finishes_clean": summary.heldFinishesClean,
            "held_unresolved": summary.heldUnresolved,
        ]
        return step
    }

    /// step-09: cancel a streaming native row mid-flight; the scheduler
    /// releases it (no active or waiting rows remain) and the next native
    /// row still matches ordinary.
    private func cancellation(ordinary: ModelRuntime, native: ModelRuntime, recorder: NativeMTPHardwareAdmissionRecorder) async throws -> NativeMTPJourneyStep {
        var step = NativeMTPJourneyStep(id: "step-09-cancellation")
        let phaseCases: [(String, NativeMTPLabPhaseTrapPhase)] = [
            ("journey-cancel-after-proposal", .afterProposal),
            ("journey-cancel-after-verify", .afterVerify),
            ("journey-cancel-before-finalize", .beforeFinalize),
        ]
        for (id, phase) in phaseCases {
            let stateObserver = NativeMTPStateDigestObserver()
            let observerInstalled = await native.installLabNativeMTPStateDigestObserver(stateObserver)
            let trap = NativeMTPLabPhaseTrap(cancellations: [phase: [id]])
            let installed = await native.installLabNativeMTPPhaseTrap(trap)
            let peerID = "\(id)-peer"
            let prompt = "Write a very long story about a journey across a desert and include many vivid details."
            let request = try makeRequest(
                id: id,
                prompt: prompt,
                maxTokens: 256,
                temperature: 0,
                topP: 1
            )
            let peerRequest = try makeRequest(
                id: peerID,
                prompt: prompt,
                maxTokens: 256,
                temperature: 0,
                topP: 1,
                conversationKey: "conv:\(peerID)"
            )
            let cancelledTask = Task { try await native.complete(request) }
            let peerTask = Task { try await native.complete(peerRequest) }
            var completed = false
            var failed = false
            var peerCompleted = false
            do {
                _ = try await cancelledTask.value
                completed = true
            } catch {
                failed = true
                step.details["\(id).error"] = String(describing: error)
            }
            do {
                _ = try await peerTask.value
                peerCompleted = true
            } catch {
                step.details["\(peerID).error"] = String(describing: error)
            }
            _ = await native.installLabNativeMTPPhaseTrap(nil)
            _ = await native.installLabNativeMTPStateDigestObserver(nil)
            let events = trap.snapshot()
            let stateRecords = stateObserver.snapshot().filter { $0.requestID == id }
            let beforeAbort = stateRecords.filter { $0.phase == (phase == .afterProposal ? .afterProposal : .beforeAbort) }
            let afterAbort = stateRecords.filter { $0.phase == .afterAbort }
            let abortPairs = Array(zip(beforeAbort, afterAbort))
            let abortStateStable = !abortPairs.isEmpty && beforeAbort.count == afterAbort.count && abortPairs.allSatisfy { before, after in
                before.committedKVTokenCount == after.committedKVTokenCount
                    && before.cacheDigestSHA256 == after.cacheDigestSHA256
                    && before.drafterDigestSHA256 == after.drafterDigestSHA256
            }
            let idle = try await waitForSchedulerIdle(native)
            step.check("\(id).state_observer_installed", observerInstalled)
            step.check("\(id).trap_installed", installed)
            step.check("\(id).native_admitted", lastPath(recorder, id) == .nativeMTP)
            step.check("\(id).trap_fired", events.contains { $0.phase == phase && $0.cancelledRequestIDs.contains(id) })
            step.check("\(id).ordinary_peer_selected_ordinary", lastPath(recorder, peerID) == .ordinary)
            step.check("\(id).ordinary_peer_not_cancelled", events.allSatisfy { !$0.cancelledRequestIDs.contains(peerID) })
            step.check("\(id).ordinary_peer_completed", peerCompleted)
            step.check("\(id).cancelled_not_completed", failed && !completed)
            step.check("\(id).no_later_native_phase_after_cancel", !hasLaterPhaseEvent(events: events, requestID: id, phase: phase))
            step.check("\(id).pre_post_abort_digest_observed", !beforeAbort.isEmpty && !afterAbort.isEmpty)
            step.check("\(id).pre_post_abort_cache_and_drafter_stable", abortStateStable)
            step.check("\(id).after_abort_fresh_drafter_recomputation", !afterAbort.isEmpty && afterAbort.allSatisfy {
                $0.drafterDigestSHA256 != nil && $0.drafterRecomputeDigestSHA256 == $0.drafterDigestSHA256
            })
            step.check("\(id).scheduler_released_row", idle)
            step.details["\(id).events"] = phaseEventDetails(events)
            step.details["\(id).abort_state"] = [
                "before_abort_records": beforeAbort.count,
                "after_abort_records": afterAbort.count,
                "matched_pairs": abortPairs.count,
                "pending_target_digest_ignored": true,
            ]
        }

        let request = try makeRequest(
            id: "journey-cancel-0",
            prompt: "Write a very long story about a journey across a desert.",
            maxTokens: 512,
            temperature: 0,
            topP: 1,
            stream: true
        )
        let chunks = NativeMTPJourneyCounter()
        let handle = try await native.acquireRequestHandle(request)
        var cancelledCleanly = false
        var completedNormally = false
        do {
            _ = try await native.stream(request, with: handle, shouldCancel: { chunks.value >= 16 }) { chunk in
                if case .content(let text) = chunk, !text.isEmpty { chunks.increment() }
            }
            completedNormally = true
        } catch is CancellationError {
            cancelledCleanly = true
        } catch {
            step.details["cancel_error"] = String(describing: error)
        }
        await native.unregisterInFlight(handle.registrationID)
        step.details["chunks_before_cancel"] = chunks.value
        step.check("native_admitted", lastPath(recorder, "journey-cancel-0") == .nativeMTP)
        step.check("cancellation_threshold_reached", chunks.value >= 16)
        step.check("cancelled_not_completed", cancelledCleanly && !completedNormally)
        let idle = try await waitForSchedulerIdle(native)
        step.check("scheduler_released_row", idle)
        let follow = try makeRequest(id: "journey-cancel-follow", prompt: "Name three rivers in Europe.", maxTokens: 96, temperature: 0, topP: 1)
        let expected = try await ordinary.complete(follow)
        let actual = try await native.complete(follow)
        step.check("follow_up_parity", same(expected, actual))
        step.check("follow_up_native", lastPath(recorder, "journey-cancel-follow") == .nativeMTP)
        return step
    }

    /// step-10: hold an old native request across a runtime-publication
    /// boundary, then publish a fresh model identity with native-MTP disabled.
    /// The old request's served snapshot and counters stay bound to the old
    /// tuple; the first request against the new identity cannot inherit native
    /// capability or native counters.
    private func warmSwapBoundary(
        ordinary: ModelRuntime,
        native: ModelRuntime,
        recorder: NativeMTPHardwareAdmissionRecorder,
        fixture: NativeMTPHardwareRuntimeFixture
    ) async throws -> NativeMTPJourneyStep {
        var step = NativeMTPJourneyStep(id: "step-10-warm-swap")
        let oldRequest = try makeRequest(
            id: "journey-warm-swap-old-native",
            prompt: "Write a compact but detailed explanation of how lighthouses use lenses to focus light.",
            maxTokens: 512,
            temperature: 0,
            topP: 1,
            stream: true
        )
        let oldHandle = try await native.acquireRequestHandle(oldRequest)
        let oldStartSnapshot = oldHandle.snapshot
        let oldBefore = oldStartSnapshot.nativeMTPStatus
        let oldChunks = NativeMTPJourneyCounter()
        let oldText = NativeMTPJourneyText()
        let oldTask = Task {
            let result = try await native.stream(oldRequest, with: oldHandle) { chunk in
                if case .content(let piece) = chunk, !piece.isEmpty {
                    oldText.append(piece)
                    oldChunks.increment()
                }
            }
            return (result, oldHandle.snapshot)
        }
        var observedInFlight = false
        for _ in 0..<100 {
            if oldChunks.value >= 8 {
                observedInFlight = true
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard observedInFlight else {
            oldTask.cancel()
            await native.unregisterInFlight(oldHandle.registrationID)
            throw NativeMTPHardwareE2EError.assertionFailed("warm-swap old request did not reach in-flight streaming boundary")
        }

        let oldPreSwapStatus = await native.currentSnapshot().nativeMTPStatus
        let swappedModelID = modelID + "-warm-swap-alias"
        let postSwapSnapshot = try await native.labCompleteWarmSwapForNativeMTPJourney(
            modelID: swappedModelID,
            artifactSHA256: fixture.targetIdentity.digest
        )

        let (expectedOld, expectedOldText) = try await streamCollect(oldRequest, runtime: ordinary)
        let (oldResult, oldServedSnapshot): (CompletionResult, RuntimeSnapshot)
        do {
            (oldResult, oldServedSnapshot) = try await oldTask.value
        } catch {
            await native.unregisterInFlight(oldHandle.registrationID)
            throw error
        }
        await native.unregisterInFlight(oldHandle.registrationID)
        let oldAfter = await native.currentSnapshot().nativeMTPStatus

        let postSwapBeforeNewRequest = oldAfter
        let newRequest = try makeRequest(
            id: "journey-warm-swap-new-ordinary",
            model: swappedModelID,
            prompt: "Name three ocean currents and give one fact about each.",
            maxTokens: 96,
            temperature: 0,
            topP: 1
        )
        let newResult = try await native.complete(newRequest)
        let postSwapAfter = await native.currentSnapshot().nativeMTPStatus
        let newDelta = NativeMTPStatusDelta(before: postSwapBeforeNewRequest, after: postSwapAfter)
        let newAdmissions = recorder.requestSnapshot().filter { $0.requestID == "journey-warm-swap-new-ordinary" }
        step.check("old_request_started_before_swap", oldStartSnapshot.modelID == modelID && oldStartSnapshot.modelHash == fixture.targetIdentity.digest)
        step.check("old_request_start_native_enabled", oldStartSnapshot.nativeMTPStatus.enabled && oldStartSnapshot.nativeMTPStatus.resetGeneration > 0)
        step.check("old_request_observed_inflight_at_swap", observedInFlight)
        step.check("old_request_served_old_tuple", oldServedSnapshot.modelID == modelID && oldServedSnapshot.modelHash == fixture.targetIdentity.digest)
        step.check("old_request_parity", same(expectedOld, oldResult))
        step.check("old_streamed_text_equals_content", oldText.value == oldResult.content && expectedOldText == expectedOld.content)
        step.check("old_request_native_counters_bound", oldPreSwapStatus.resetGeneration == oldBefore.resetGeneration
            && oldPreSwapStatus.proposedTokens > oldBefore.proposedTokens
            && oldPreSwapStatus.targetForwards > oldBefore.targetForwards
            && oldPreSwapStatus.mtpForwards > oldBefore.mtpForwards)
        step.check("same_runtime_alias_differs", swappedModelID != modelID)
        step.check("same_runtime_identity_published", postSwapSnapshot.modelID == swappedModelID && postSwapSnapshot.modelHash == fixture.targetIdentity.digest)
        step.check("same_runtime_hash_algorithm_actual", postSwapSnapshot.modelHashAlgorithm == ModelArtifactIdentity.snapshotManifestV1)
        step.check("same_runtime_native_disabled", !postSwapSnapshot.nativeMTPStatus.enabled && !postSwapSnapshot.nativeMTPStatus.supported && postSwapSnapshot.nativeMTPStatus.lastReason == .warmSwap)
        step.check("new_request_completed", !newResult.content.isEmpty && newResult.modelHashObserved == fixture.targetIdentity.digest)
        step.check("new_request_no_native_counters", newDelta.proposedTokens == 0
            && newDelta.acceptedTokens == 0
            && newDelta.rejectedTokens == 0
            && newDelta.targetForwards == 0
            && newDelta.mtpForwards == 0)
        step.check("new_request_not_native_admitted", !newAdmissions.isEmpty && newAdmissions.allSatisfy { $0.admission.effectivePath != .nativeMTP })
        step.details["old_tuple"] = [
            "model_id": modelID,
            "model_hash": fixture.targetIdentity.digest,
            "native_reset_generation": oldStartSnapshot.nativeMTPStatus.resetGeneration,
            "pre_swap_proposed": oldPreSwapStatus.proposedTokens,
            "pre_swap_accepted": oldPreSwapStatus.acceptedTokens,
            "pre_swap_rejected": oldPreSwapStatus.rejectedTokens,
            "pre_swap_target_forwards": oldPreSwapStatus.targetForwards,
            "pre_swap_mtp_forwards": oldPreSwapStatus.mtpForwards,
            "chunks_before_swap": oldChunks.value,
        ]
        step.details["post_swap_tuple"] = [
            "model_id": swappedModelID,
            "model_hash": fixture.targetIdentity.digest,
            "model_hash_algorithm": postSwapSnapshot.modelHashAlgorithm ?? "",
            "native_enabled": postSwapSnapshot.nativeMTPStatus.enabled,
            "native_supported": postSwapSnapshot.nativeMTPStatus.supported,
            "native_reset_generation": postSwapSnapshot.nativeMTPStatus.resetGeneration,
            "new_request_finish_reason": newResult.finishReason,
            "new_request_native_admissions": newAdmissions.filter { $0.admission.effectivePath == .nativeMTP }.count,
        ]
        return step
    }

    /// step-12 (provider-local half): the `native_mtp_selftest_v1` request
    /// shape at the fixed depth is exact against the ordinary oracle and
    /// deterministic across runs, so its counters and committed-state digest
    /// can be signed into the release challenge bank. Emits that record.
    private func selfTest(
        ordinary: ModelRuntime,
        native: ModelRuntime,
        fixture: NativeMTPHardwareRuntimeFixture,
        prompt: String,
        promptIndex: Int
    ) async throws -> NativeMTPJourneyStep {
        var step = NativeMTPJourneyStep(id: "step-12-native-selftest")
        step.uncovered = ["coordinator-issued SPEC-031-R033 canary and its negative outcomes"]
        let promptTokenIDs = try await fixture.runtimes.targetContainer.perform { context in
            context.tokenizer.encode(text: prompt, addSpecialTokens: true)
        }
        // Execution ids are replay keys: each prompt gets its own (the first
        // keeps the ids every earlier record used).
        let suffix = promptIndex == 0 ? "" : "-p\(promptIndex)"
        let maxCompletionTokens = 64
        let depth = fixture.admission.maxProposalDepth
        // Native twice, then ordinary: the provider's self-check order, so the
        // speedup estimate below sees the same warm/cold split.
        // Distinct execution ids: a reused id would replay the retained
        // terminal result and make determinism trivially true.
        var started = Date()
        let first = try await native.labTokenProbe(
            id: "native-mtp-selftest-journey-0001-run-a\(suffix)",
            promptTokenIDs: promptTokenIDs,
            maxCompletionTokens: maxCompletionTokens,
            nativeDepth: depth
        )
        let firstSeconds = Date().timeIntervalSince(started)
        started = Date()
        let second = try await native.labTokenProbe(
            id: "native-mtp-selftest-journey-0001-run-b\(suffix)",
            promptTokenIDs: promptTokenIDs,
            maxCompletionTokens: maxCompletionTokens,
            nativeDepth: depth
        )
        let secondSeconds = Date().timeIntervalSince(started)
        started = Date()
        let oracle = try await ordinary.labTokenProbe(
            id: "native-mtp-selftest-oracle\(suffix)",
            promptTokenIDs: promptTokenIDs,
            maxCompletionTokens: maxCompletionTokens,
            nativeDepth: nil
        )
        let ordinarySeconds = Date().timeIntervalSince(started)
        func digest(_ result: ContinuousBatchSchedulerResult) -> String? {
            guard let counters = result.nativeMTPCounters else { return nil }
            return NativeMTPSelfTestDigest.committedStateDigest(
                promptTokenIDs: promptTokenIDs,
                generatedTokenIDs: result.generatedTokens,
                acceptedTokens: Int(clamping: counters.acceptedTokens),
                rejectedTokens: Int(clamping: counters.rejectedTokens),
                bonusTokens: Int(clamping: counters.bonusTokens),
                committedTokens: Int(clamping: counters.committedTokens),
                terminalReason: result.terminalStatus
            )
        }
        step.check("tokens_equal_ordinary_oracle", first.generatedTokens == oracle.generatedTokens)
        step.check("terminal_equal_ordinary_oracle", first.terminalStatus == oracle.terminalStatus)
        step.check("native_counters_present", first.nativeMTPCounters != nil)
        step.check("native_proposals", (first.nativeMTPCounters?.acceptedTokens ?? 0) + (first.nativeMTPCounters?.rejectedTokens ?? 0) > 0)
        step.check("deterministic_tokens", first.generatedTokens == second.generatedTokens)
        step.check("deterministic_counters", first.nativeMTPCounters == second.nativeMTPCounters)
        step.check("deterministic_state_digest", digest(first) != nil && digest(first) == digest(second))
        if let counters = first.nativeMTPCounters, let state = digest(first) {
            // Exactly the SPEC-031-R033 challenge-bank entry fields; the release
            // signs this into native-mtp-selftest-bank.json.
            step.details["challenge_bank_entry"] = [
                "challenge_id": selfTestChallengeID,
                "model_id": modelID,
                "model_hash": fixture.targetIdentity.digest,
                "tokenizer_sha256": fixture.tokenizerSHA256,
                "artifact_sha256": fixture.mtpIdentity.digest,
                "mtp_manifest_sha256": fixture.manifestSHA256,
                "prompt_token_ids": promptTokenIDs,
                "max_completion_tokens": maxCompletionTokens,
                "fixed_proposal_depth": depth,
                "expected_token_ids": first.generatedTokens,
                "expected_token_id_sha256": NativeMTPSelfTest.tokenDigest(first.generatedTokens),
                "expected_terminal_reason": first.terminalStatus.rawValue,
                "expected_counters": [
                    "accepted": counters.acceptedTokens,
                    "rejected": counters.rejectedTokens,
                    "bonus": counters.bonusTokens,
                    "committed": counters.committedTokens,
                ],
                "expected_committed_state_sha256": state,
            ] as [String: Any]
        }
        // The provider's on-device self-check (SPEC-048-R016 0.1.32) runs this
        // same challenge and needs native at least 1.15x faster than ordinary
        // (best of two native runs). An estimate only: the provider times both
        // paths on one paged engine, this step on two runtimes.
        let verdict = NativeMTPOnDeviceSelfCheck.decide(
            mtpTokens: first.generatedTokens,
            mtpSeconds: min(firstSeconds, secondSeconds),
            ordinaryTokens: oracle.generatedTokens,
            ordinarySeconds: ordinarySeconds
        )
        step.details["on_device_selfcheck_estimate"] = [
            "ordinary_seconds": ordinarySeconds,
            "native_best_seconds": min(firstSeconds, secondSeconds),
            "speedup": verdict.speedup,
            "minimum_speedup": NativeMTPOnDeviceSelfCheck.minimumSpeedup,
            "reason": verdict.reason,
        ] as [String: Any]
        step.details["selftest_prompt_index"] = promptIndex
        step.details["selftest_prompt"] = prompt
        step.details["coordinator_canary"] = "not_run_isolated_no_join"
        return step
    }

    // MARK: helpers

    private func makeRequest(
        id: String,
        model: String? = nil,
        prompt: String,
        maxTokens: Int,
        temperature: Double,
        topP: Double,
        stop: [String]? = nil,
        stream: Bool = false,
        conversationKey: String? = nil
    ) throws -> ChatCompletionRequest {
        var object: [String: Any] = [
            "model": model ?? modelID,
            "messages": [["role": "user", "content": prompt]],
            "max_tokens": maxTokens,
            "temperature": temperature,
            "top_p": topP,
            "stream": stream,
        ]
        if let stop { object["stop"] = stop }
        return try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: object))
            .withRequestID(id)
            .withConversationKey(conversationKey)
    }

    private func same(_ lhs: CompletionResult, _ rhs: CompletionResult) -> Bool {
        lhs.content == rhs.content
            && lhs.finishReason == rhs.finishReason
            && lhs.promptTokens == rhs.promptTokens
            && lhs.completionTokens == rhs.completionTokens
            && lhs.generatedCompletionTokens == rhs.generatedCompletionTokens
    }

    private func lastPath(_ recorder: NativeMTPHardwareAdmissionRecorder, _ id: String) -> DecodePath? {
        recorder.requestSnapshot().last { $0.requestID == id }?.admission.effectivePath
    }

    /// The row was admitted to ordinary decode because the tuple does not
    /// sign sampled rows.
    private func routedOrdinaryForSampling(_ recorder: NativeMTPHardwareAdmissionRecorder, _ id: String) -> Bool {
        guard let admission = recorder.requestSnapshot().last(where: { $0.requestID == id })?.admission else { return false }
        return admission.effectivePath == .ordinary && admission.selection.nativeMTPReason == .sampling
    }

    private func complete(
        _ requests: [ChatCompletionRequest],
        runtime: ModelRuntime,
        staggerMS: UInt64
    ) async throws -> [String: CompletionResult] {
        try await withThrowingTaskGroup(of: (String, CompletionResult).self) { group in
            for (index, request) in requests.enumerated() {
                let id = request.requestID ?? ""
                group.addTask {
                    if index > 0 { try await Task.sleep(nanoseconds: UInt64(index) * staggerMS * 1_000_000) }
                    return (id, try await runtime.complete(request))
                }
            }
            var results: [String: CompletionResult] = [:]
            for try await (id, result) in group { results[id] = result }
            return results
        }
    }

    private func completeDeterministicBatch(
        _ requests: [ChatCompletionRequest],
        runtime: ModelRuntime
    ) async throws -> [String: CompletionResult] {
        let requestIDs = requests.compactMap(\.requestID)
        guard requestIDs.count == requests.count,
              await runtime.installLabBatchComposition(requestIDs) else {
            throw NativeMTPHardwareE2EError.assertionFailed(
                "could not install deterministic batch composition on an idle scheduler"
            )
        }
        return try await complete(requests, runtime: runtime, staggerMS: 0)
    }

    private func waitForSchedulerIdle(_ runtime: ModelRuntime) async throws -> Bool {
        for _ in 0..<50 {
            let scheduler = await runtime.currentSnapshot().continuousBatching?.scheduler
            if scheduler?.activeDecodeRows == 0, scheduler?.waitingCount == 0 { return true }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    private func phaseEventDetails(_ events: [NativeMTPLabPhaseTrap.Event]) -> [[String: Any]] {
        events.map { event in
            [
                "phase": event.phase.rawValue,
                "request_ids": event.requestIDs,
                "cancelled_request_ids": event.cancelledRequestIDs,
            ]
        }
    }

    private func hasLaterPhaseEvent(
        events: [NativeMTPLabPhaseTrap.Event],
        requestID: String,
        phase: NativeMTPLabPhaseTrapPhase
    ) -> Bool {
        let order: [NativeMTPLabPhaseTrapPhase: Int] = [
            .afterProposal: 0,
            .afterVerify: 1,
            .beforeFinalize: 2,
        ]
        guard let trappedOrder = order[phase] else { return true }
        return events.contains { event in
            (order[event.phase] ?? Int.max) > trappedOrder && event.requestIDs.contains(requestID)
        }
    }

    private func streamCollect(_ request: ChatCompletionRequest, runtime: ModelRuntime) async throws -> (CompletionResult, String) {
        try await streamCollect(request, runtime: runtime, onContent: nil)
    }

    private func streamCollect(
        _ request: ChatCompletionRequest,
        runtime: ModelRuntime,
        onContent: ((String) -> Void)?
    ) async throws -> (CompletionResult, String) {
        let text = NativeMTPJourneyText()
        let handle = try await runtime.acquireRequestHandle(request)
        do {
            let result = try await runtime.stream(request, with: handle) { chunk in
                if case .content(let piece) = chunk {
                    text.append(piece)
                    onContent?(piece)
                }
            }
            await runtime.unregisterInFlight(handle.registrationID)
            return (result, text.value)
        } catch {
            await runtime.unregisterInFlight(handle.registrationID)
            throw error
        }
    }

    private func isSHA256Hex(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }

    private func servedPromptTokens(_ prompt: String, runtime: ModelRuntime) async throws -> [Int] {
        let snapshot = await runtime.currentSnapshot()
        guard let container = snapshot.container else {
            throw NativeMTPHardwareE2EError.assertionFailed("runtime has no loaded container")
        }
        let request = try makeRequest(id: "journey-prompt-tokens", prompt: prompt, maxTokens: 1, temperature: 0, topP: 1)
        let thinkingToggle = snapshot.templateSupportsThinkingToggle
        let preserveThinking = snapshot.templateSupportsPreserveThinking
        return try await container.perform { context in
            let input = try ModelRuntime.userInput(
                for: request,
                templateSupportsThinkingToggle: thinkingToggle,
                templateSupportsPreserveThinking: preserveThinking
            )
            return try await context.processor.prepare(input: input).text.tokens.asArray(Int.self)
        }
    }

    private func committedStateDigest(
        promptTokenIDs: [Int],
        result: ContinuousBatchSchedulerResult,
        counters: NativeMTPSelfTestCounters
    ) -> String {
        NativeMTPSelfTestDigest.committedStateDigest(
            promptTokenIDs: promptTokenIDs,
            generatedTokenIDs: result.generatedTokens,
            acceptedTokens: Int(clamping: counters.acceptedTokens),
            rejectedTokens: Int(clamping: counters.rejectedTokens),
            bonusTokens: Int(clamping: counters.bonusTokens),
            committedTokens: Int(clamping: counters.committedTokens),
            terminalReason: result.terminalStatus
        )
    }

    private func prompt(container: ModelContainer, minimumTokens: Int) async throws -> String {
        try await container.perform { context in
            var text = "Summarize the following notes."
            var salt = 0
            while context.tokenizer.encode(text: text, addSpecialTokens: true).count < minimumTokens {
                text += " note-\(salt) the committee reviewed the quarterly logistics report and its appendices."
                salt += 1
            }
            return text
        }
    }
}

private final class NativeMTPJourneyCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}

private final class NativeMTPJourneyText: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    var value: String { lock.lock(); defer { lock.unlock() }; return text }
    func append(_ piece: String) { lock.lock(); text += piece; lock.unlock() }
}
#endif
