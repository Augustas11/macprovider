import ArgumentParser
import CryptoKit
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

    func run() async throws {
        guard ProcessInfo.processInfo.environment["MACPROVIDER_NATIVE_MTP_E2E"] == "1" else {
            FileHandle.standardError.write(Data("native-mtp-journey-e2e: set MACPROVIDER_NATIVE_MTP_E2E=1 on the Mac Studio\n".utf8))
            throw ExitCode(2)
        }
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
            maxPromptTokens: maxPromptTokens
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

private final class NativeMTPJourneyRunner {
    private let root: String
    private let modelID: String
    private let qualifiedSlots: Int
    private let maxNativeActiveRows: Int
    private let maxPromptTokens: Int
    private static let blockTokens = 32

    init(root: String, modelID: String, qualifiedSlots: Int, maxNativeActiveRows: Int, maxPromptTokens: Int) {
        self.root = root
        self.modelID = modelID
        self.qualifiedSlots = qualifiedSlots
        self.maxNativeActiveRows = maxNativeActiveRows
        self.maxPromptTokens = maxPromptTokens
    }

    func run() async throws -> (document: [String: Any], passed: Bool) {
        let outputBudget = 512
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
            (prefix: "journey-boundary-", mode: .blockBoundary(blockTokens: Self.blockTokens)),
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
            do {
                steps.append(try await body())
            } catch {
                var failed = NativeMTPJourneyStep(id: id)
                failed.check("completed_without_error", false)
                failed.details["error"] = String(describing: error)
                steps.append(failed)
            }
        }
        await run("step-04-serial-token-oracle") {
            try await serialOracle(ordinary: ordinary, native: native, recorder: recorder)
        }
        await run("step-05-cache-state-boundary") {
            try await cacheStateBoundary(ordinary: ordinary, native: native, recorder: recorder, override: override)
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
        await run("step-12-native-selftest") {
            try await selfTest(ordinary: ordinary, native: native, fixture: fixture)
        }
        let passed = steps.allSatisfy(\.passed)
        // pass only when every executed step is complete; partial when any
        // passing step leaves journey clauses uncovered.
        let executedStatus = !passed ? "fail" : (steps.allSatisfy { $0.uncovered.isEmpty } ? "pass" : "partial")
        let document: [String: Any] = [
            "schema": "macprovider.native-mtp-journey-hardware-result.v1",
            // Covers only the hardware steps below; never a journey verdict.
            "journey_complete": false,
            "executed_steps_status": executedStatus,
            "covered_steps": [
                "step-04-serial-token-oracle",
                "step-05-cache-state-boundary",
                "step-06-streaming-stop",
                "step-07-mixed-multirow",
                "step-08-capacity-and-depth-zero",
                "step-09-cancellation",
                "step-12-native-canary (provider-local self-test half)",
            ],
            "pending_steps": [
                "step-01-bind-tuple",
                "step-02-capability-negatives",
                "step-03-artifact-security-negatives",
                "step-10-warm-swap",
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
            "request_feature_profile": NativeMTPAdmissionSidecar.sampledRequestFeatureProfile,
            "machine": [
                "chip": fixture.machine.chip,
                "ram_gb": fixture.machine.ramGB,
                "os_version": fixture.machine.osVersion,
            ],
            "steps": steps.map(\.document),
        ]
        return (document, passed)
    }

    // MARK: steps

    /// step-04: native output equals isolated ordinary output (tokens, text,
    /// usage, terminal) for greedy and seeded sampled rows, streaming off.
    private func serialOracle(ordinary: ModelRuntime, native: ModelRuntime, recorder: NativeMTPHardwareAdmissionRecorder) async throws -> NativeMTPJourneyStep {
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
        step.uncovered = ["partial acceptance within a round (needs proposal depth >= 2)"]
        step.details["requests"] = compared
        step.details["accepted"] = accepted
        step.details["rejected"] = rejected
        return step
    }

    /// step-05: forced rejection on every round and on every round whose
    /// staged positions cross a paged-KV block boundary; output and state
    /// stay exact (later tokens of the same row still match ordinary).
    private func cacheStateBoundary(
        ordinary: ModelRuntime,
        native: ModelRuntime,
        recorder: NativeMTPHardwareAdmissionRecorder,
        override: NativeMTPLabProposalOverride
    ) async throws -> NativeMTPJourneyStep {
        var step = NativeMTPJourneyStep(id: "step-05-cache-state-boundary")
        step.uncovered = ["committed-state digest parity after each forced rejection (only output parity is compared)"]
        for id in ["journey-reject-all-0", "journey-boundary-0", "journey-boundary-1"] {
            let request = try makeRequest(
                id: id,
                prompt: "Tell a detailed story about a lighthouse keeper (\(id)).",
                maxTokens: 256,
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
            step.details[id] = [
                "forced_rounds": forced,
                "proposed": delta.proposedTokens,
                "accepted": delta.acceptedTokens,
                "rejected": delta.rejectedTokens,
            ]
        }
        return step
    }

    /// step-06: streaming equals non-streaming equals ordinary for a stop
    /// string, a max-tokens terminal, and a sampled row.
    private func streamingStop(ordinary: ModelRuntime, native: ModelRuntime, recorder: NativeMTPHardwareAdmissionRecorder) async throws -> NativeMTPJourneyStep {
        var step = NativeMTPJourneyStep(id: "step-06-streaming-stop")
        let cases: [(String, String, [String]?, Int, Double)] = [
            ("journey-stream-stop", "Count from one to thirty in English words, separated by commas.", [" twelve"], 256, 0),
            ("journey-stream-length", "Write a long essay about the history of printing.", nil, 160, 0),
            ("journey-stream-eos", "Reply with exactly the single word OK and nothing else.", nil, 64, 0),
            ("journey-stream-sampled", "Invent a recipe for a winter soup.", nil, 160, 0.7),
        ]
        var terminals: [String: String] = [:]
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
            step.check("\(id).native_admitted", lastPath(recorder, plainID) == .nativeMTP && lastPath(recorder, streamID) == .nativeMTP)
            terminals[id] = expected.finishReason
        }
        step.check("stop_terminal_observed", terminals["journey-stream-stop"] == "stop")
        step.check("length_terminal_observed", terminals["journey-stream-length"] == "length")
        step.check("eos_terminal_observed", terminals["journey-stream-eos"] == "stop")
        step.uncovered = [
            "stop string verified to span a proposal/round boundary",
            "early consumer stop (covered only as step-09 cancellation)",
            "post-output injected failure with no retry or stitching",
        ]
        step.details["terminals"] = terminals
        return step
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
        let expected = try await complete(requests, runtime: ordinary, staggerMS: 150)
        // Control: ordinary batched decode must reproduce itself under the
        // same staggered load, or a native mismatch would mean nothing.
        // Fresh request ids and keys: the scheduler rejects a reused id with a
        // different body, and a reused key would hit the conversation cache.
        let control = try await complete(
            requests.map {
                $0.withRequestID(($0.requestID ?? "") + "-control")
                    .withConversationKey($0.conversationKey.map { $0 + "-control" })
            },
            runtime: ordinary,
            staggerMS: 150
        )
        // Diagnostic: the same ordinary batch under slightly different arrival
        // timing. A row that differs here is batch-composition sensitive on
        // the ordinary path itself; it is reported, never counted as parity.
        let perturbed = try await complete(
            requests.map {
                $0.withRequestID(($0.requestID ?? "") + "-perturbed")
                    .withConversationKey($0.conversationKey.map { $0 + "-perturbed" })
            },
            runtime: ordinary,
            staggerMS: 170
        )
        let actual = try await complete(requests, runtime: native, staggerMS: 150)
        var timingSensitive: [String] = []
        var paths: [String: String] = [:]
        var reasons: [String: String] = [:]
        for request in requests {
            let id = request.requestID ?? ""
            step.check("\(id).ordinary_control_reproducible", expected[id].map { exp in control[id + "-control"].map { same(exp, $0) } ?? false } ?? false)
            step.check("\(id).parity", expected[id].map { exp in actual[id].map { same(exp, $0) } ?? false } ?? false)
            if let exp = expected[id], let other = perturbed[id + "-perturbed"], !same(exp, other) {
                timingSensitive.append(id)
            }
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
        step.details["ordinary_rows_differing_under_perturbed_arrival_timing"] = timingSensitive.sorted()
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
        step.uncovered = ["cancellation at the proposal, verification, and commit boundaries (only mid-stream is exercised)"]
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
        var idle = false
        for _ in 0..<50 {
            let scheduler = await native.currentSnapshot().continuousBatching?.scheduler
            if scheduler?.activeDecodeRows == 0, scheduler?.waitingCount == 0 { idle = true; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        step.check("scheduler_released_row", idle)
        let follow = try makeRequest(id: "journey-cancel-follow", prompt: "Name three rivers in Europe.", maxTokens: 96, temperature: 0, topP: 1)
        let expected = try await ordinary.complete(follow)
        let actual = try await native.complete(follow)
        step.check("follow_up_parity", same(expected, actual))
        step.check("follow_up_native", lastPath(recorder, "journey-cancel-follow") == .nativeMTP)
        return step
    }

    /// step-12 (provider-local half): the `native_mtp_selftest_v1` request
    /// shape at the fixed depth is exact against the ordinary oracle and
    /// deterministic across runs, so its counters and committed-state digest
    /// can be signed into the release challenge bank. Emits that record.
    private func selfTest(ordinary: ModelRuntime, native: ModelRuntime, fixture: NativeMTPHardwareRuntimeFixture) async throws -> NativeMTPJourneyStep {
        var step = NativeMTPJourneyStep(id: "step-12-native-selftest")
        step.uncovered = ["coordinator-issued SPEC-031-R033 canary and its negative outcomes"]
        let promptTokenIDs = try await fixture.runtimes.targetContainer.perform { context in
            context.tokenizer.encode(
                text: "native_mtp_selftest_v1 synthetic challenge: continue the sequence alpha beta gamma delta",
                addSpecialTokens: true
            )
        }
        let maxCompletionTokens = 64
        let depth = fixture.admission.maxProposalDepth
        let oracle = try await ordinary.labTokenProbe(
            id: "native-mtp-selftest-oracle",
            promptTokenIDs: promptTokenIDs,
            maxCompletionTokens: maxCompletionTokens,
            nativeDepth: nil
        )
        // Distinct execution ids: a reused id would replay the retained
        // terminal result and make determinism trivially true.
        let first = try await native.labTokenProbe(
            id: "native-mtp-selftest-journey-0001-run-a",
            promptTokenIDs: promptTokenIDs,
            maxCompletionTokens: maxCompletionTokens,
            nativeDepth: depth
        )
        let second = try await native.labTokenProbe(
            id: "native-mtp-selftest-journey-0001-run-b",
            promptTokenIDs: promptTokenIDs,
            maxCompletionTokens: maxCompletionTokens,
            nativeDepth: depth
        )
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
                "challenge_id": "native-mtp-selftest-journey-0001",
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
        step.details["coordinator_canary"] = "not_run_isolated_no_join"
        return step
    }

    // MARK: helpers

    private func makeRequest(
        id: String,
        prompt: String,
        maxTokens: Int,
        temperature: Double,
        topP: Double,
        stop: [String]? = nil,
        stream: Bool = false,
        conversationKey: String? = nil
    ) throws -> ChatCompletionRequest {
        var object: [String: Any] = [
            "model": modelID,
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

    private func streamCollect(_ request: ChatCompletionRequest, runtime: ModelRuntime) async throws -> (CompletionResult, String) {
        let text = NativeMTPJourneyText()
        let handle = try await runtime.acquireRequestHandle(request)
        do {
            let result = try await runtime.stream(request, with: handle) { chunk in
                if case .content(let piece) = chunk { text.append(piece) }
            }
            await runtime.unregisterInFlight(handle.registrationID)
            return (result, text.value)
        } catch {
            await runtime.unregisterInFlight(handle.registrationID)
            throw error
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
