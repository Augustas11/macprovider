# codex advisor artifact

- Provider: codex
- Exit code: 0
- Created at: 2026-09-25T11:21:57.006Z

## Original task

# Codex audit: tool-bearing and structured-output rows batch (#1646, SPEC-038 AC-6c)

Method constraint: this is a first-party software-correctness review. Read the
source and run EXISTING tests only. Do NOT construct malformed payloads;
describe any gaps abstractly in prose.

Worktree: `/Users/augstar/macprovider-1646-rest`. Branch:
`campaign/1646-remaining`. Review `git show 52fcb7e4` (the full diff vs
origin/main).

## The change
- **Gate.** `ModelRuntime.requestStateRepresentable` no longer serial-routes
  JSON `response_format` or enabled tools. Harmony (gpt-oss) models with
  tools or structured output stay serial-routed, as do `logit_bias` and
  logprobs.
- **Streaming.** Batched rows reuse the serial path's finalize. A new shared
  `SerialStreamingTextEmitter`, extracted from the serial streaming path, runs
  per batched streaming row in `AttachedPagedKVStreamState.step`, including
  the tool-turn stop, the structured accumulator and the SPEC-018 byte caps.
- **Non-streaming.** Batched non-streaming uses `parseGeneratedOutput` and
  `validateStructuredCompletion`, exactly as serial does.
- **Scheduler.** `ContinuousBatchScheduler` gains a row-stop hook, so a row
  stops at the serial stop point.
- **Spec.** SPEC-038 v0.2.11 AC-6c.
- **Tests.** `ContinuousBatchToolStructuredRowTests` (10 tests) and the routing
  tests. The full suite passes: 3535 tests, 0 failures.

## Gate
0 CRITICAL, 0 HIGH, 0 MEDIUM. Report findings with file:line, a concrete
failure scenario, and a fix. Do not manufacture findings. End with
`VERDICT: PASS` or `VERDICT: FAIL (C/H/M counts)`.
## Lane: SECURITY / MONEY PATH

Check:
- Usage, receipt and settlement fields for batched tool and structured rows, especially tokens generated after the serial stop point: are they billed or excluded exactly as on the serial path?
- Cross-row isolation of tool-call parser state and of structured accumulators.
- The SPEC-018 argument byte caps are enforced per row.
- Harmony gating: no path lets a Harmony tool request batch.

## Final prompt

# Codex audit: tool-bearing and structured-output rows batch (#1646, SPEC-038 AC-6c)

Method constraint: this is a first-party software-correctness review. Read the
source and run EXISTING tests only. Do NOT construct malformed payloads;
describe any gaps abstractly in prose.

Worktree: `/Users/augstar/macprovider-1646-rest`. Branch:
`campaign/1646-remaining`. Review `git show 52fcb7e4` (the full diff vs
origin/main).

## The change
- **Gate.** `ModelRuntime.requestStateRepresentable` no longer serial-routes
  JSON `response_format` or enabled tools. Harmony (gpt-oss) models with
  tools or structured output stay serial-routed, as do `logit_bias` and
  logprobs.
- **Streaming.** Batched rows reuse the serial path's finalize. A new shared
  `SerialStreamingTextEmitter`, extracted from the serial streaming path, runs
  per batched streaming row in `AttachedPagedKVStreamState.step`, including
  the tool-turn stop, the structured accumulator and the SPEC-018 byte caps.
- **Non-streaming.** Batched non-streaming uses `parseGeneratedOutput` and
  `validateStructuredCompletion`, exactly as serial does.
- **Scheduler.** `ContinuousBatchScheduler` gains a row-stop hook, so a row
  stops at the serial stop point.
- **Spec.** SPEC-038 v0.2.11 AC-6c.
- **Tests.** `ContinuousBatchToolStructuredRowTests` (10 tests) and the routing
  tests. The full suite passes: 3535 tests, 0 failures.

## Gate
0 CRITICAL, 0 HIGH, 0 MEDIUM. Report findings with file:line, a concrete
failure scenario, and a fix. Do not manufacture findings. End with
`VERDICT: PASS` or `VERDICT: FAIL (C/H/M counts)`.
## Lane: SECURITY / MONEY PATH

Check:
- Usage, receipt and settlement fields for batched tool and structured rows, especially tokens generated after the serial stop point: are they billed or excluded exactly as on the serial path?
- Cross-row isolation of tool-call parser state and of structured accumulators.
- The SPEC-018 argument byte caps are enforced per row.
- Harmony gating: no path lets a Harmony tool request batch.

## Raw output

```text
Audit found one MEDIUM issue:

- `ModelRuntime.swift:4029-4047`, `4103-4107`; `ContinuousBatchScheduler.swift:1627-1632`  
  A duplicate/replayed tool request receives the full accumulated `replayTokens`, but the fresh parser records that full length as the serial stop point—or receives no token events on terminal replay. Since finalization only truncates when `serialStopTokenCount` is present, post-stop tokens can be included in `completionTokens`/receipts and cache commits. The existing scheduler test confirms stop-after-next-token behavior (`generatedTokens == [7, 8]`).

  Fix: derive or persist the canonical serial tool-stop boundary from `result.generatedTokens` once per row, and use it for every waiter/replay before billing and cache settlement.

No issues found with per-row parser/accumulator isolation, SPEC-018 caps, or Harmony tool routing.

Validation: row tests passed (9 tests); scheduler/routing selection passed (95 tests, 4 existing metallib skips); diff check passed.

VERDICT: FAIL (0/0/1)


OpenAI Codex v0.156.1
--------
workdir: /Users/augstar/macprovider-1646-rest
model: gpt-5.6-luna
provider: openai
approval: never
sandbox: danger-full-access
reasoning effort: high
reasoning summaries: none
session id: 01a0d845-428f-71d0-b0ed-723535711154
--------
user
# Codex audit: tool-bearing and structured-output rows batch (#1646, SPEC-038 AC-6c)

Method constraint: this is a first-party software-correctness review. Read the
source and run EXISTING tests only. Do NOT construct malformed payloads;
describe any gaps abstractly in prose.

Worktree: `/Users/augstar/macprovider-1646-rest`. Branch:
`campaign/1646-remaining`. Review `git show 52fcb7e4` (the full diff vs
origin/main).

## The change
- **Gate.** `ModelRuntime.requestStateRepresentable` no longer serial-routes
  JSON `response_format` or enabled tools. Harmony (gpt-oss) models with
  tools or structured output stay serial-routed, as do `logit_bias` and
  logprobs.
- **Streaming.** Batched rows reuse the serial path's finalize. A new shared
  `SerialStreamingTextEmitter`, extracted from the serial streaming path, runs
  per batched streaming row in `AttachedPagedKVStreamState.step`, including
  the tool-turn stop, the structured accumulator and the SPEC-018 byte caps.
- **Non-streaming.** Batched non-streaming uses `parseGeneratedOutput` and
  `validateStructuredCompletion`, exactly as serial does.
- **Scheduler.** `ContinuousBatchScheduler` gains a row-stop hook, so a row
  stops at the serial stop point.
- **Spec.** SPEC-038 v0.2.11 AC-6c.
- **Tests.** `ContinuousBatchToolStructuredRowTests` (10 tests) and the routing
  tests. The full suite passes: 3535 tests, 0 failures.

## Gate
0 CRITICAL, 0 HIGH, 0 MEDIUM. Report findings with file:line, a concrete
failure scenario, and a fix. Do not manufacture findings. End with
`VERDICT: PASS` or `VERDICT: FAIL (C/H/M counts)`.
## Lane: SECURITY / MONEY PATH

Check:
- Usage, receipt and settlement fields for batched tool and structured rows, especially tokens generated after the serial stop point: are they billed or excluded exactly as on the serial path?
- Cross-row isolation of tool-call parser state and of structured accumulators.
- The SPEC-018 argument byte caps are enforced per row.
- Harmony gating: no path lets a Harmony tool request batch.
warning: Codex is ignoring 1 unrecognized configuration setting. Check for typos or deprecated settings.
  user (/Users/augstar/.codex/config.toml): `features.child_agents_md` is ignored.
warning: Codex is ignoring 1 unrecognized configuration setting. Check for typos or deprecated settings.
  user (/Users/augstar/.codex/config.toml): `features.child_agents_md` is ignored.
warning: failed to parse hooks config /Users/augstar/.codex/hooks.json: unknown field `state`, expected `description` or `hooks` at line 2 column 9
codex
I’ll audit the full `52fcb7e4` diff for the security/money-path lane, trace serial-versus-batched stop/finalization and per-row state, then run only existing relevant tests. I’ll report only evidence-backed C/H/M findings with file:line, scenario, and fix; no malformed-payload construction.
exec
/bin/bash -lc 'git status -sb && git show --stat --oneline --decorate --no-renames 52fcb7e4 && git diff --no-ext-diff --unified=80 52fcb7e4''^ 52fcb7e4 --' in /Users/augstar/macprovider-1646-rest
 succeeded in 128ms:
52fcb7e48 (HEAD -> campaign/1646-remaining) Batch tool-bearing and structured-output rows with the serial path's own finalize
 .../macprovider-cli/ContinuousBatchScheduler.swift |  18 +
 .../Sources/macprovider-cli/ModelRuntime.swift     | 886 ++++++++++++++-------
 .../ContinuousBatchSchedulerTests.swift            |  30 +
 .../ContinuousBatchToolStructuredRowTests.swift    | 499 ++++++++++++
 .../ServingKnobsConfigTests.swift                  |  49 +-
 5 files changed, 1161 insertions(+), 321 deletions(-)
diff --git a/phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift b/phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift
index 0c656309..68b1c6ba 100644
--- a/phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift
+++ b/phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift
@@ -1136,160 +1136,163 @@ actor ContinuousBatchScheduler {
         }
     }
 
     private struct Row: Sendable {
         var request: ContinuousBatchSchedulerRequest
         var handle: PagedKVBlockTableHandle
         var currentToken: Int
         /// All sampled tokens, including stop tokens held back from buyers.
         var generatedTokens: [Int]
         var outputTokens: [Int]
         var pendingOutputTokens: [Int]
         var prefillCursor: Int
         var snapshot: ContinuousBatchSchedulerSnapshot
         /// Keyed hybrid rows: recurrent state at each reached checkpoint (<= 2).
         var recurrentCheckpoints: [RecurrentStateCheckpoint] = []
 
         var retainedLogicalTokenCount: Int {
             request.promptTokens.count + generatedTokens.count
         }
     }
 
     private struct PendingTerminalDelivery {
         let result: ContinuousBatchSchedulerResult
         var waiters: [Waiter]
         var remainingWaiterIDs: Set<UUID>
         var deliveryOutcomes: [UUID: Bool] = [:]
     }
 
     private struct StoppingActiveWaiter {
         let requestID: String
         let waiter: Waiter
         let error: any Error
     }
 
     private struct DeferredTerminalCompletion {
         let result: ContinuousBatchSchedulerResult
         let waiters: [Waiter]
     }
 
     private struct DeliveredRetainedOwner {
         let retained: PagedKVRetainedSequence
         let conversationKey: String
     }
 
     private let configuration: ContinuousBatchSchedulerConfiguration
     private let schedulerID = UUID()
     private let allocator: PagedKVBlockAllocator
     private let backend: any ContinuousBatchSchedulerBackend
     private let replayAuthority: any ContinuousBatchSchedulerReplayAuthority
     private let contiguousCacheBridge: (any ContinuousBatchRetainedCacheBridge)?
     private let tokenDeliveryCapacity: ContinuousBatchTokenDeliveryCapacity
 
     private var waiting: [ContinuousBatchSchedulerRequest] = []
     /// Absolute uptime deadline per queued request, set once when the request
     /// enters `waiting` so a re-queued admission attempt keeps the original
     /// clock instead of restarting it.
     private var queueWaitDeadlines: [String: UInt64] = [:]
     private var queueWaitTimeoutTasks: [String: Task<Void, Never>] = [:]
     private var pendingBindingChecks = 0
     private var pendingBindingTokenCount = 0
     private var nextAdmissionSequence: UInt64 = 0
     private var currentAdmissionSequence: UInt64 = 0
     private var admissionTurnWaiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
     private var requestAdmissionSequences: [String: UInt64] = [:]
     private var admittingRequests: [String: ContinuousBatchSchedulerRequest] = [:]
     private var activePrompt: [String: Row] = [:]
     private var promptOrder: [String] = []
     private var activeDecode: [String: Row] = [:]
     private var requestWaiters: [String: [Waiter]] = [:]
     private var knownRequests: [String: RequestFingerprint] = [:]
     private var terminalResults: [String: ContinuousBatchSchedulerResult] = [:]
     private var pendingTerminalDeliveries: [String: PendingTerminalDelivery] = [:]
     private var stoppingWaiterIDs: Set<UUID> = []
     private var stoppingActiveWaiters: [UUID: StoppingActiveWaiter] = [:]
     private var deferredTerminalCompletions: [String: DeferredTerminalCompletion] = [:]
     private var deliveredRetainedOwners: [UUID: DeliveredRetainedOwner] = [:]
     private var terminalResultOrder: [String] = []
     private var dedupeTombstones: Set<String> = []
     private var dedupeTombstoneOrder: [String] = []
     private var cancelledIDs: Set<String> = []
+    /// SPEC-038 AC-6c: decoding rows asked to end as a normal `.stop` at their
+    /// next applied token (a serial tool turn completed its first tool call).
+    private var earlyStopIDs: Set<String> = []
     private var draining = false
     private var cleanupFailedClosed = false
     private var backendCancellationPending = false
     private var pumpRestartRequested = false
     private var pumpRunning = false
     private var diagnostics: [ContinuousBatchSchedulerDiagnostic] = []
     private var sharedForwardCalls = 0
     private var prefillCalls = 0
     private var maxObservedBatchDepth = 0
 
     init(
         configuration: ContinuousBatchSchedulerConfiguration,
         allocator: PagedKVBlockAllocator,
         backend: any ContinuousBatchSchedulerBackend,
         replayAuthority: any ContinuousBatchSchedulerReplayAuthority,
         contiguousCacheBridge: (any ContinuousBatchRetainedCacheBridge)? = nil
     ) {
         self.configuration = configuration
         self.tokenDeliveryCapacity = ContinuousBatchTokenDeliveryCapacity(
             limit: configuration.tokenDeliveryTaskLimit
         )
         self.allocator = allocator
         self.backend = backend
         self.replayAuthority = replayAuthority
         self.contiguousCacheBridge = contiguousCacheBridge
     }
 
     static func localCapabilityReason(
         descriptor: PagedKVDescriptor,
         tuple: ContinuousBatchingRequestedTuple,
         moePromotionEvidenceAvailable: Bool = false
     ) -> String? {
         guard tuple.isAdmitted(by: descriptor) else {
             return "local_paged_kv_descriptor_mismatch"
         }
         if tuple.requiresMoE && !moePromotionEvidenceAvailable {
             return "moe_promotion_evidence_unavailable"
         }
         return nil
     }
 
     func submit(
         _ request: ContinuousBatchSchedulerRequest,
         tokenSink: @escaping ContinuousBatchSchedulerTokenSink = { _ in }
     ) async throws -> ContinuousBatchSchedulerResult {
         do {
             try Task.checkCancellation()
         } catch {
             await discardUnacceptedRetainedCache(for: request)
             throw error
         }
         if cleanupFailedClosed {
             await discardUnacceptedRetainedCache(for: request)
             throw ContinuousBatchSchedulerError.unsupported("continuous_batching_scheduler_failed_closed")
         }
         if let reason = Self.localCapabilityReason(
             descriptor: configuration.descriptor,
             tuple: configuration.tuple,
             moePromotionEvidenceAvailable: configuration.moePromotionEvidenceAvailable
         ) {
             record(.localCapabilityMissing)
             await discardUnacceptedRetainedCache(for: request)
             throw ContinuousBatchSchedulerError.unsupported(reason)
         }
         if request.cachedPromptTokens > 0 && request.retainedPagedKVSequence == nil {
             record(.stickyCacheUnsupported)
             throw ContinuousBatchSchedulerError.unsupported("continuous_batching_paged_kv_handoff_unavailable")
         }
         let trimmedConversationKey = request.conversationKey.trimmingCharacters(in: .whitespacesAndNewlines)
         if request.cachedPromptTokens > 0 && trimmedConversationKey.isEmpty {
             record(.stickyCacheUnsupported)
             await discardUnacceptedRetainedCache(for: request)
             throw ContinuousBatchSchedulerError.unsupported("continuous_batching_cached_tokens_require_conversation_key")
         }
         if request.cachedPromptTokens > 0 && request.cachedPromptTokens >= request.promptTokens.count {
             record(.stickyCacheUnsupported)
             await discardUnacceptedRetainedCache(for: request)
             throw ContinuousBatchSchedulerError.requestFailed("continuous_batching_invalid_cached_prompt_tokens")
         }
         guard !request.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
@@ -1300,160 +1303,171 @@ actor ContinuousBatchScheduler {
               request.stopTokenSequences.allSatisfy({ sequence in
                   !sequence.isEmpty
                       && sequence.count <= configuration.maxStopSequenceTokens
                       && sequence.allSatisfy { (0..<configuration.vocabularySize).contains($0) }
               }),
               let retainedTokenCost = validatedRetainedTokenCost(for: request),
               retainedTokenCost <= configuration.maxRequestTokens else {
             await discardUnacceptedRetainedCache(for: request)
             throw ContinuousBatchSchedulerError.requestFailed("continuous_batching_invalid_request")
         }
         guard queueHasCapacity(addingTokenCost: retainedTokenCost) else {
             record(.backpressureRejected)
             await discardUnacceptedRetainedCache(for: request)
             throw ContinuousBatchSchedulerError.backpressure
         }
         guard nextAdmissionSequence < UInt64.max else {
             cleanupFailedClosed = true
             await discardUnacceptedRetainedCache(for: request)
             throw ContinuousBatchSchedulerError.unsupported("continuous_batching_admission_sequence_exhausted")
         }
         let admissionSequence = nextAdmissionSequence
         nextAdmissionSequence += 1
         pendingBindingChecks += 1
         pendingBindingTokenCount += retainedTokenCost
         CBTrace.log(request.id, "sch_submit seq=\(admissionSequence) cur=\(currentAdmissionSequence) active=\(activeDecode.count)")
         let bindingsAreValid = await localBindingsAreValid()
         CBTrace.log(request.id, "sch_bindings")
         await waitForAdmissionTurn(admissionSequence)
         CBTrace.log(request.id, "sch_turn")
         pendingBindingChecks -= 1
         pendingBindingTokenCount -= retainedTokenCost
         guard bindingsAreValid else {
             record(.localCapabilityMissing)
             finishAdmissionTurn(admissionSequence)
             await discardUnacceptedRetainedCache(for: request)
             throw ContinuousBatchSchedulerError.unsupported("continuous_batching_local_binding_mismatch")
         }
         do {
             try Task.checkCancellation()
         } catch {
             finishAdmissionTurn(admissionSequence)
             await discardUnacceptedRetainedCache(for: request)
             throw error
         }
         let waiterID = UUID()
         let delivery = ContinuousBatchTokenDelivery(
             bufferLimit: configuration.tokenDeliveryBufferLimit,
             timeoutNanoseconds: configuration.tokenDeliveryTimeoutNanoseconds,
             capacity: tokenDeliveryCapacity,
             sink: tokenSink
         )
         return try await withTaskCancellationHandler {
             try await withCheckedThrowingContinuation { continuation in
                 enqueue(
                     request,
                     admissionSequence: admissionSequence,
                     waiterID: waiterID,
                     continuation: continuation,
                     delivery: delivery
                 )
                 CBTrace.log(request.id, "sch_enqueued waiting=\(waiting.count) active=\(activeDecode.count)")
                 finishAdmissionTurn(admissionSequence)
             }
         } onCancel: {
             Task { await self.cancelWaiter(requestID: request.id, waiterID: waiterID) }
         }
     }
 
     func cancel(requestID: String) {
         guard terminalResults[requestID] == nil, knownRequests[requestID] != nil else { return }
         // Once generation has produced its terminal result, accepted token
         // delivery owns completion ordering. Cancellation cannot overtake that
         // delivery fence and rewrite the already-decided terminal state.
         if pendingTerminalDeliveries[requestID] != nil {
             return
         }
         cancelledIDs.insert(requestID)
         ensurePump()
     }
 
+    /// SPEC-038 AC-6c: end a decoding row as a normal `.stop` at its next
+    /// applied token. The serial path stops a serial tool turn (SPEC-018,
+    /// `parallel_tool_calls` omitted/false) once the first tool call is
+    /// complete; the batched caller truncates the row's tokens back to that
+    /// exact point, so this only bounds wasted decode. A row that is not
+    /// decoding (queued, prefilling, or already terminal) is left alone.
+    func stopEarly(requestID: String) {
+        guard activeDecode[requestID] != nil else { return }
+        earlyStopIDs.insert(requestID)
+    }
+
     func drain() async throws -> ContinuousBatchDrainPermit {
         guard !cleanupFailedClosed else {
             throw ContinuousBatchSchedulerError.unsupported(
                 "continuous_batching_scheduler_failed_closed"
             )
         }
         draining = true
         record(.drained)
         while !waiting.isEmpty {
             let request = waiting.removeFirst()
             await finishQueued(
                 request,
                 status: .rejected,
                 errorCode: "continuous_batching_draining"
             )
         }
         ensurePump()
         let startedAt = DispatchTime.now().uptimeNanoseconds
         let (candidateDeadline, deadlineOverflow) = startedAt.addingReportingOverflow(
             configuration.drainTimeoutNanoseconds
         )
         var deadline = deadlineOverflow ? UInt64.max : candidateDeadline
         var forcedCancellation = false
         while pendingBindingChecks > 0 || !waiting.isEmpty || !admittingRequests.isEmpty
             || !activePrompt.isEmpty || !activeDecode.isEmpty || !pendingTerminalDeliveries.isEmpty
             || !stoppingActiveWaiters.isEmpty || !deferredTerminalCompletions.isEmpty
             || pumpRunning || backendCancellationPending {
             let now = DispatchTime.now().uptimeNanoseconds
             if now >= deadline {
                 if forcedCancellation {
                     cleanupFailedClosed = true
                     throw ContinuousBatchSchedulerError.drainTimedOut
                 }
                 cleanupFailedClosed = true
                 record(.forcedDrainStarted)
                 forcedCancellation = true
                 cancelledIDs.formUnion(admittingRequests.keys)
                 cancelledIDs.formUnion(activePrompt.keys)
                 cancelledIDs.formUnion(activeDecode.keys)
                 stopPendingTerminalDeliveriesForDrain()
                 startBackendCancellation()
                 let (graceDeadline, graceOverflow) = now.addingReportingOverflow(
                     configuration.drainCancellationGraceNanoseconds
                 )
                 deadline = graceOverflow ? UInt64.max : graceDeadline
             }
             do {
                 try await Task.sleep(nanoseconds: 10_000_000)
             } catch {
                 throw error
             }
         }
         if forcedCancellation {
             cleanupFailedClosed = true
             throw ContinuousBatchSchedulerError.drainTimedOut
         }
         guard !cleanupFailedClosed else {
             throw ContinuousBatchSchedulerError.unsupported(
                 "continuous_batching_scheduler_failed_closed"
             )
         }
         return ContinuousBatchDrainPermit(
             schedulerID: schedulerID,
             snapshot: configuration.snapshot
         )
     }
 
     func validatesQuiescentDrainPermit(_ permit: ContinuousBatchDrainPermit) -> Bool {
         !cleanupFailedClosed
             && permit.schedulerID == schedulerID
             && permit.snapshot == configuration.snapshot
             && pendingBindingChecks == 0
             && waiting.isEmpty
             && admittingRequests.isEmpty
             && activePrompt.isEmpty
             && activeDecode.isEmpty
             && pendingTerminalDeliveries.isEmpty
             && stoppingActiveWaiters.isEmpty
             && deferredTerminalCompletions.isEmpty
             && !pumpRunning
@@ -2148,160 +2162,162 @@ actor ContinuousBatchScheduler {
         }
         guard !cleanupFailedClosed else { return }
         let outputs = outcomes.compactMap { outcome -> ContinuousBatchDecodeOutput? in
             guard case .output(let output) = outcome else { return nil }
             return output
         }
         var invalidOutputIDs: Set<String> = []
         for output in outputs {
             let sampled = output.tokens
             let invalid = sampled.isEmpty
                 || sampled.contains { !(0..<configuration.vocabularySize).contains($0) }
             guard invalid else { continue }
             invalidOutputIDs.insert(output.requestID)
             record(.localPreparationFailed)
             if let removed = activeDecode.removeValue(forKey: output.requestID) {
                 let released = await release(removed.handle)
                 finish(
                     removed,
                     status: .requestFailed,
                     errorCode: released
                         ? "continuous_batching_invalid_decode_token"
                         : "continuous_batching_cleanup_failed"
                 )
                 if !released { return }
             }
         }
         let stillActive = Set(activeDecode.keys)
         await applyDecodeOutputs(outputs.filter {
             healthyOutputIDs.contains($0.requestID)
                 && stillActive.contains($0.requestID)
                 && !invalidOutputIDs.contains($0.requestID)
         })
     }
 
     private func applyDecodeOutputs(_ outputs: [ContinuousBatchDecodeOutput]) async {
         var byID: [String: ContinuousBatchDecodeOutput] = [:]
         for output in outputs {
             byID[output.requestID] = output
         }
         var maxSteps = 1
         for output in outputs {
             let count = output.tokens.isEmpty ? 1 : output.tokens.count
             maxSteps = max(maxSteps, count)
         }
         for step in 0..<maxSteps {
             for id in activeDecode.keys.sorted(by: admissionPrecedes) {
                 guard let row = activeDecode[id], let output = byID[id] else { continue }
                 let sampled = output.tokens
                 guard step < sampled.count else { continue }
                 await applyToken(sampled[step], to: row)
                 if cleanupFailedClosed { return }
             }
         }
     }
 
     private func applyToken(_ token: Int, to initialRow: Row) async {
         guard var row = activeDecode[initialRow.request.id] else { return }
         row.generatedTokens.append(token)
         row.currentToken = token
         row.pendingOutputTokens.append(token)
 
         let terminalStatus: ContinuousBatchSchedulerTerminalStatus?
         if let stopLength = matchingStopLength(
             row.generatedTokens,
             stopSequences: row.request.stopTokenSequences
         ) {
             guard stopLength <= row.pendingOutputTokens.count else {
                 activeDecode.removeValue(forKey: row.request.id)
                 let released = await release(row.handle)
                 finish(
                     row,
                     status: .requestFailed,
                     errorCode: released
                         ? "continuous_batching_stop_filter_state_invalid"
                         : "continuous_batching_cleanup_failed"
                 )
                 return
             }
             row.pendingOutputTokens.removeLast(stopLength)
             terminalStatus = .stop
+        } else if earlyStopIDs.contains(row.request.id) {
+            terminalStatus = .stop
         } else if row.generatedTokens.count >= row.request.maxOutputTokens {
             terminalStatus = .length
         } else {
             terminalStatus = nil
         }
 
         let visibleTokens: [Int]
         if terminalStatus != nil {
             visibleTokens = row.pendingOutputTokens
             row.pendingOutputTokens.removeAll(keepingCapacity: true)
         } else {
             var ready: [Int] = []
             while let first = row.pendingOutputTokens.first,
                   !isPotentialStopPrefix(
                       row.pendingOutputTokens,
                       stopSequences: row.request.stopTokenSequences
                   ) {
                 ready.append(first)
                 row.pendingOutputTokens.removeFirst()
             }
             visibleTokens = ready
         }
 
         let firstVisibleIndex = row.outputTokens.count
         row.outputTokens.append(contentsOf: visibleTokens)
         activeDecode[row.request.id] = row
         CBTrace.log(row.request.id, "sch_active")
         if !deliverVisibleTokens(
             visibleTokens,
             firstIndex: firstVisibleIndex,
             row: row
         ) {
             activeDecode.removeValue(forKey: row.request.id)
             let released = await release(row.handle)
             // Post-token, like the `.deliveryBackpressure` thrown at the
             // waiter above: this row was decoding when its last consumer
             // refused an event. The terminal result is replayable to a later
             // duplicate of the same request id, so it must not carry the
             // pre-admission code — that one is retryable and this is not.
             finish(
                 row,
                 status: .requestFailed,
                 errorCode: released
                     ? ContinuousBatchSchedulerError.deliveryBackpressureCode
                     : "continuous_batching_cleanup_failed"
             )
             return
         }
 
         if let terminalStatus {
             activeDecode.removeValue(forKey: row.request.id)
             await finishTerminal(row, status: terminalStatus)
         }
     }
 
     /// Normal terminal for a row already removed from active tracking. The
     /// retain / materialize awaits can interleave with `cancel(requestID:)`,
     /// which only records the ID and no longer finds the row; a cancel recorded
     /// meanwhile wins, and no conversation cache is published for it.
     private func finishTerminal(_ row: Row, status: ContinuousBatchSchedulerTerminalStatus) async {
         if let retainedCache = await retainTerminalCache(
             for: row,
             targetLogicalTokens: row.retainedLogicalTokenCount
         ) {
             if cancelledIDs.remove(row.request.id) != nil {
                 await discardRetainedCache(
                     retainedCache.retainedSequence,
                     conversationKey: schedulerConversationKey(for: row.request)
                 )
                 finish(row, status: .cancelled, errorCode: "request_cancelled")
                 return
             }
             finish(row, status: status, errorCode: nil, retainedCache: retainedCache)
             return
         }
         let serialCache = await materializeSerialConversationCache(for: row)
         let released = await release(row.handle)
         if cancelledIDs.remove(row.request.id) != nil {
             finish(row, status: released ? .cancelled : .requestFailed, errorCode: released
                 ? "request_cancelled"
@@ -2671,188 +2687,190 @@ actor ContinuousBatchScheduler {
                 status: .requestFailed,
                 errorCode: "continuous_batching_scheduler_failed_closed"
             )
         }
         for id in promptOrder {
             guard let row = activePrompt.removeValue(forKey: id) else { continue }
             _ = await release(row.handle)
             finish(row, status: .requestFailed, errorCode: "continuous_batching_scheduler_failed_closed")
         }
         promptOrder.removeAll()
         for id in activeDecode.keys.sorted() {
             guard let row = activeDecode.removeValue(forKey: id) else { continue }
             _ = await release(row.handle)
             finish(row, status: .requestFailed, errorCode: "continuous_batching_scheduler_failed_closed")
         }
         cancelledIDs.removeAll()
     }
 
     private func failClosedIfNeeded() async -> Bool {
         guard cleanupFailedClosed else { return false }
         await processCancellations()
         await failRemainingAfterCleanupFailure()
         return true
     }
 
     private func finishQueued(
         _ request: ContinuousBatchSchedulerRequest,
         status: ContinuousBatchSchedulerTerminalStatus,
         errorCode: String?
     ) async {
         // Every pre-admission completion funnels through here. A cancel recorded
         // while the request was out of `waiting` (mid-admission, e.g. during a
         // retained install) wins over the admission outcome: nothing ran for
         // it, and `requestFailed`/`rejected` would contradict the caller's
         // cancel. A cleanup failure stays visible as such.
         await discardUnacceptedRetainedCache(for: request)
         // Checked after the last await and with none before the result is
         // built, so a cancel recorded during the discard above wins too.
         var status = status
         var errorCode = errorCode
         if status != .cancelled,
            errorCode != "continuous_batching_cleanup_failed",
            cancelledIDs.remove(request.id) != nil {
             status = .cancelled
             errorCode = "request_cancelled"
         }
         let result = ContinuousBatchSchedulerResult(
             requestID: request.id,
             conversationKey: request.conversationKey,
             generatedTokens: [],
             outputTokens: [],
             promptTokens: 0,
             completionTokens: 0,
             emittedTokens: 0,
             cachedPromptTokens: 0,
             terminalStatus: status,
             errorCode: errorCode,
             snapshot: nil,
             settlementDisposition: .notEligible,
             retainedCache: nil
         )
         complete(requestID: request.id, result: result)
     }
 
     private func discardUnacceptedRetainedCache(for request: ContinuousBatchSchedulerRequest) async {
         guard let retained = request.retainedPagedKVSequence else { return }
         await discardRetainedCache(retained)
     }
 
     private func scheduleDiscardUnacceptedRetainedCache(for request: ContinuousBatchSchedulerRequest) {
         guard let retained = request.retainedPagedKVSequence else { return }
         Task { await self.discardRetainedCache(retained) }
     }
 
     private func finish(
         _ row: Row,
         status: ContinuousBatchSchedulerTerminalStatus,
         errorCode: String?,
         serialConversationCache: ContinuousBatchSerialConversationCache? = nil
     ) {
+        earlyStopIDs.remove(row.request.id)
         record(status == .cancelled ? .cancelled : .stopped)
         let isSuccessful = status == .stop || status == .length
         let outputTokens = isSuccessful ? row.outputTokens : []
         let result = ContinuousBatchSchedulerResult(
             requestID: row.request.id,
             conversationKey: row.request.conversationKey,
             generatedTokens: isSuccessful ? row.generatedTokens : [],
             outputTokens: outputTokens,
             promptTokens: row.request.promptTokens.count,
             completionTokens: isSuccessful ? row.generatedTokens.count : 0,
             emittedTokens: row.outputTokens.count,
             cachedPromptTokens: row.request.cachedPromptTokens,
             terminalStatus: status,
             errorCode: errorCode,
             snapshot: row.snapshot,
             settlementDisposition: isSuccessful ? .eligibleOwner : .notEligible,
             retainedCache: nil,
             serialConversationCache: isSuccessful ? serialConversationCache : nil
         )
         complete(requestID: row.request.id, result: result)
     }
 
     private func finish(
         _ row: Row,
         status: ContinuousBatchSchedulerTerminalStatus,
         errorCode: String?,
         retainedCache: ContinuousBatchRetainedCache?
     ) {
+        earlyStopIDs.remove(row.request.id)
         record(status == .cancelled ? .cancelled : .stopped)
         let isSuccessful = status == .stop || status == .length
         let outputTokens = isSuccessful ? row.outputTokens : []
         let result = ContinuousBatchSchedulerResult(
             requestID: row.request.id,
             conversationKey: row.request.conversationKey,
             generatedTokens: isSuccessful ? row.generatedTokens : [],
             outputTokens: outputTokens,
             promptTokens: row.request.promptTokens.count,
             completionTokens: isSuccessful ? row.generatedTokens.count : 0,
             emittedTokens: row.outputTokens.count,
             cachedPromptTokens: row.request.cachedPromptTokens,
             terminalStatus: status,
             errorCode: errorCode,
             snapshot: row.snapshot,
             settlementDisposition: isSuccessful ? .eligibleOwner : .notEligible,
             retainedCache: isSuccessful ? retainedCache : nil
         )
         complete(requestID: row.request.id, result: result)
     }
 
     private func complete(requestID: String, result: ContinuousBatchSchedulerResult) {
         CBTrace.log(requestID, "sch_complete status=\(result.terminalStatus) waiters=\(requestWaiters[requestID]?.count ?? 0) stopping=\(stoppingActiveWaiters.values.contains(where: { $0.requestID == requestID }))")
         endQueueWait(requestID: requestID)
         guard terminalResults[requestID] == nil, pendingTerminalDeliveries[requestID] == nil else { return }
         requestAdmissionSequences.removeValue(forKey: requestID)
         let waiters = requestWaiters.removeValue(forKey: requestID) ?? []
         if stoppingActiveWaiters.values.contains(where: { $0.requestID == requestID }) {
             deferredTerminalCompletions[requestID] = DeferredTerminalCompletion(
                 result: result,
                 waiters: waiters
             )
             return
         }
         beginTerminalDelivery(requestID: requestID, result: result, waiters: waiters)
     }
 
     private func beginTerminalDelivery(
         requestID: String,
         result: ContinuousBatchSchedulerResult,
         waiters: [Waiter]
     ) {
         guard !waiters.isEmpty else {
             finalizeTerminalResult(requestID: requestID, result: result, waiters: [])
             if let retainedCache = result.retainedCache {
                 Task {
                     await self.discardRetainedCache(
                         retainedCache.retainedSequence,
                         conversationKey: result.conversationKey
                     )
                 }
             }
             return
         }
         pendingTerminalDeliveries[requestID] = PendingTerminalDelivery(
             result: result,
             waiters: waiters,
             remainingWaiterIDs: Set(waiters.map(\.id))
         )
         for waiter in waiters {
             waiter.delivery.finish(afterDraining: { delivered in
                 Task {
                     await self.finishTerminalDelivery(
                         requestID: requestID,
                         waiterID: waiter.id,
                         delivered: delivered
                     )
                 }
             })
         }
     }
 
     private func finishTerminalDelivery(requestID: String, waiterID: UUID, delivered: Bool) async {
         guard !stoppingWaiterIDs.contains(waiterID) else {
             CBTrace.log(requestID, "sch_ftd_skip_stopping")
             return
         }
         guard var pending = pendingTerminalDeliveries[requestID],
               pending.remainingWaiterIDs.remove(waiterID) != nil else {
             CBTrace.log(requestID, "sch_ftd_skip_no_pending")
diff --git a/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift b/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift
index d82c7835..04ca2b0f 100644
--- a/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift
+++ b/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift
@@ -3286,173 +3286,185 @@ actor ModelRuntime: ModelRuntimeServing {
                 replayAuthority: replayAuthority
             )
         }
         guard case .attached(let descriptor) = decision,
               let container,
               let cacheKinds = await pagedKVCacheKinds(container: container)
         else {
             return nil
         }
         // A hybrid (Qwen3.6) row retains its paged KV only when cached-turn
         // batching is on (SPEC-038 AC-26): the next turn then restores the
         // recurrent layers from a checkpoint. Off, a keyed hybrid row keeps the
         // serial-format materialize at terminal instead.
         let isHybrid = cacheKinds.contains(.recurrentMamba)
         let contiguousCacheBridge = isHybrid && !cachedTurns ? nil : PagedKVRuntimeContiguousCacheBridge()
         return makeContinuousBatchScheduler(
             decision: decision,
             tuple: tuple,
             backend: PagedKVSharedForwardBackend(
                 container: container,
                 descriptor: descriptor,
                 layerCount: cacheKinds.count,
                 cacheKinds: cacheKinds,
                 contiguousCacheBridge: contiguousCacheBridge,
                 // Off on the serve path. A replayed `MLX.compile` step never
                 // re-runs `KVCacheSimple.update`'s Swift offset/grow logic, so
                 // every step after the trace writes the same KV slot at the
                 // same RoPE position: greedy rows loop on the prompt within a
                 // few tokens and fail `continuous_batching_invalid_cache_layout`
                 // once the traced buffer (seed + 256) is full. Measured on
                 // Studio 2026-09-24: signed 176, 181 and main all degenerate
                 // with this on and are coherent with it off. Applies to
                 // hybrid (Qwen3.6) and KV-only layouts alike.
                 compiledDecode: false
             ),
             maxBatch: maxBatch,
             queueLimit: queueLimit,
             queueWaitTimeoutMS: queueWaitTimeoutMS,
             maxContextTokens: maxContextTokens,
             modelID: modelID,
             modelSHA256: modelSHA256,
             weightsGeneration: weightsGeneration,
             prefillStepSize: prefillStepSize,
             replayAuthority: replayAuthority,
             contiguousCacheBridge: contiguousCacheBridge
         )
     }
 
     private static func pagedKVCacheKinds(
         container: ModelContainer
     ) async -> [PagedKVSharedForwardBackend.CacheKind]? {
         await container.perform { context in
             return Self.pagedKVCacheKinds(model: context.model)
         }
     }
 
     private func rebuildContinuousBatchScheduler(container: ModelContainer?) async {
         continuousBatchScheduler = await Self.makeContinuousBatchScheduler(
             decision: pagedKVAttachDecision,
             tuple: continuousBatchingRequestedTuple(),
             container: container,
             backendOverride: testContinuousBatchingBackend,
             maxBatch: maxBatch,
             queueLimit: continuousBatchQueueLimit,
             queueWaitTimeoutMS: continuousBatchQueueWaitTimeoutMS,
             maxContextTokens: maxContextTokens,
             modelID: currentModelID,
             modelSHA256: currentModelHash,
             weightsGeneration: currentSpecDecodeGeneration,
             kvBitsOverride: kvBitsOverride,
             prefillStepSize: prefillStepSize,
             replayAuthority: continuousBatchReplayAuthority,
             cachedTurns: continuousBatchingCachedTurns
         )
         continuousBatchingDurableReplayAuthorityAvailable =
             continuousBatchScheduler != nil && continuousBatchReplayAuthority.durableAvailable
     }
 
     /// A request is representable by the batched shared-forward contract only if
     /// its generation is fully described by the scalar sampling parameters the
-    /// contract carries. Structured-output/grammar validation, tool-constrained
-    /// decoding, logit_bias, and logprobs all impose row-local decoder state the
-    /// contract does not model, so such requests must serial-route (canary) / fail
-    /// closed (strict) before admission — a gate that holds for the SPEC-039 bridge
-    /// so a future backend cannot silently drop that state.
+    /// contract carries. logit_bias and logprobs impose row-local decoder state
+    /// the contract does not model, so such requests must serial-route (canary) /
+    /// fail closed (strict) before admission — a gate that holds for the SPEC-039
+    /// bridge so a future backend cannot silently drop that state.
+    ///
+    /// SPEC-038 AC-6c: structured output (`response_format` json_object /
+    /// json_schema) and enabled tools constrain no logit. The serial path
+    /// renders them into the prompt (`userInput(for:)`) and applies them after
+    /// generation (`parseGeneratedOutput`, `validateStructuredCompletion`, the
+    /// SPEC-018 byte caps, the serial tool-turn stop, and the streaming
+    /// `SerialStreamingTextEmitter`); a batched row reuses exactly those, so
+    /// they batch. Kept gated: Harmony (gpt-oss) models with tools or
+    /// structured output. Their serial stream parses Harmony channels as
+    /// tokens arrive and sends only the final channel; the batched stream
+    /// sink streams decoded text and has no Harmony channel parser, and the
+    /// gate cannot tell a streaming request from a non-streaming one.
     static func requestStateRepresentable(_ request: ChatCompletionRequest) -> Bool {
-        // Structured-output / grammar-constrained decoding.
-        if requiresStructuredValidation(request.responseFormat) { return false }
-        // Tool-bearing requests carry tool schemas + tool-call parser state.
         // hasEnabledTools treats an absent, explicit-null, or empty tools array as
         // no-tools, so a bare or explicit-null `tool_choice` does not false-positive
         // here (the meaningful signal is whether tools are actually enabled).
-        if hasEnabledTools(request.promptSource.tools) { return false }
+        if HarmonyResponseParser.isHarmonyModelID(request.model),
+           requiresStructuredValidation(request.responseFormat)
+            || hasEnabledTools(request.promptSource.tools) {
+            return false
+        }
         // logit_bias and logprobs (incl. top_logprobs metadata) have no carrier in
         // the scheduler row contract. top_logprobs only shapes response metadata,
         // not token selection, but is rejected here too so the gate is provably
         // complete and no per-request logprob surface can reach a batch unrepresented.
         if isActiveJSONValue(request.promptSource.logitBias) { return false }
         if isRequestedLogprobs(request.promptSource.logprobs) { return false }
         if isActiveJSONValue(request.promptSource.topLogprobs) { return false }
         // SPEC-038 AC-6b: each batched row samples with the serial path's own
         // sampler for its temperature/top_p and a row-local seed
         // (`ContinuousBatchRowSampler`). The serial path ignores presence and
         // frequency penalties, so they do not change what a row can represent.
         return ContinuousBatchRowSampler.supports(
             temperature: request.temperature,
             topP: request.topP
         )
     }
 
     nonisolated static func requestHasStableRequestID(_ request: ChatCompletionRequest) -> Bool {
         nonEmpty(request.requestID) != nil
     }
 
     /// True when a JSON field is present and not explicit null. `optionalJSONValue`
     /// preserves JSON `null` as `.null`, so a bare `!= nil` check would misclassify
     /// an explicit-null field as active.
     static func isActiveJSONValue(_ value: MacProviderCore.JSONValue?) -> Bool {
         guard let value else { return false }
         if case .null = value { return false }
         return true
     }
 
     /// True when logprobs are actually requested. Absent, null, or `false` are not
     /// requests and must not force serial routing.
     static func isRequestedLogprobs(_ value: MacProviderCore.JSONValue?) -> Bool {
         guard let value else { return false }
         switch value {
         case .null, .bool(false):
             return false
         default:
             return true
         }
     }
 
     private func applyContinuousBatchingPolicy(
         request: ChatCompletionRequest,
         snapshot: RuntimeSnapshot,
         emitTelemetry: Bool = true
     ) throws -> ContinuousBatchingCapability {
         let capability = continuousBatchingCapability(
             draftConfigured: snapshot.hasTargetCompatibleDraft || currentDraftModelID != nil,
             requestHasStableRequestID: Self.requestHasStableRequestID(request),
             requestStateRepresentable: Self.requestStateRepresentable(request)
         )
         // Telemetry is emitted once per request at preflight; execution paths
         // re-validate for fail-closed safety but must not re-log the same
         // serial-route event (avoids double-counting canary promotion evidence).
         if emitTelemetry {
             ContinuousBatchingPolicy.logSerialRouteIfNeeded(capability)
         }
         try ContinuousBatchingPolicy.validateStrictStartup(capability)
         return capability
     }
 
     func maxContextTokensForTest() -> Int {
         maxContextTokens
     }
 
     #if DEBUG
     func runBlockingInferenceProbeForTest(milliseconds: Int) async throws {
         let deadline = Date().addingTimeInterval(Double(milliseconds) / 1000.0)
         try await blockingInferenceExecutor.run { inferenceCancellation in
             while Date() < deadline {
                 if inferenceCancellation.isCancelled {
                     throw CancellationError()
                 }
                 Thread.sleep(forTimeInterval: 0.005)
             }
         }
     }
     #endif
 
@@ -3824,825 +3836,978 @@ actor ModelRuntime: ModelRuntimeServing {
 
     func relayBlindPrepare(_ request: ChatCompletionRequest) async throws -> RelayBlindPreparedRequest {
         let handle = try acquireRequestHandle(request)
         do {
             _ = try applyContinuousBatchingPolicy(request: request, snapshot: handle.snapshot)
             try Self.enforcePagedKVPreflight(pagedKVAttachDecision)
             try handle.drainCancelled.check()
             guard let container = handle.snapshot.container else {
                 throw APIError(status: 503, message: "Model not loaded", type: "server_error", code: "model_not_loaded")
             }
             let maxContextTokens = maxContextTokens
             let templateSupportsThinkingToggle = handle.snapshot.templateSupportsThinkingToggle
             let inputTokens = try await inferenceGate.withPermit {
                 try handle.drainCancelled.check()
                 return try await container.perform { context in
                     try handle.drainCancelled.check()
                     let input = try Self.userInput(
                         for: request,
                         templateSupportsThinkingToggle: templateSupportsThinkingToggle
                     )
                     let prepared = try await context.processor.prepare(input: input)
                     let count = prepared.text.tokens.size
                     try Self.validatePromptTokenCount(count, maxContextTokens: maxContextTokens)
                     return count
                 }
             }
             return RelayBlindPreparedRequest(handle: handle, inputTokens: inputTokens)
         } catch {
             unregisterInFlight(handle.registrationID)
             throw error
         }
     }
 
     func pagedKVPreflight(_ request: ChatCompletionRequest, with handle: RequestHandle) async throws {
         _ = try applyContinuousBatchingPolicy(request: request, snapshot: handle.snapshot)
         try Self.enforcePagedKVPreflight(pagedKVAttachDecision)
         try handle.drainCancelled.check()
     }
 
     private struct ContinuousBatchPreparedRequest: Sendable {
         let promptTokens: [Int]
         let stopTokenSequences: [[Int]]
         let modelStopTokenIDs: Set<Int>
         let recurrentCheckpointPositions: [Int]
         /// The loaded model has recurrent (hybrid) layers; computed for keyed
         /// requests only, false otherwise.
         let modelHasRecurrentLayers: Bool
     }
 
     /// Keyed hybrid requests only: where the batched row snapshots recurrent
     /// state, identical to the serial path's `prefillRecurrentCheckpoints`.
     private nonisolated static func continuousBatchRecurrentCheckpointPositions(
         promptTokens: [Int],
         conversationKey: String?,
         hybrid: Bool,
         context: ModelContext
     ) -> [Int] {
         guard nonEmpty(conversationKey) != nil else { return [] }
         return ConversationCache.recurrentCheckpointPositions(
             promptTokenIds: promptTokens.map(Int32.init),
             imStartTokenID: context.tokenizer.convertTokenToId("<|im_start|>").map(Int32.init),
             hybrid: hybrid,
             decode: { context.tokenizer.decode(tokenIds: $0) })
     }
 
     /// The tokens a batched hybrid entry commits: the canonical list cut to the
     /// length its attention layers cover, so `begin`'s trim lands exactly on a
     /// checkpoint. Nil if the canonical list is shorter (never expected).
     nonisolated static func serialConversationCacheCommitTokens(
         canonicalTokens: [Int32],
         coveredTokenCount: Int
     ) -> [Int32]? {
         guard coveredTokenCount <= canonicalTokens.count else { return nil }
         return Array(canonicalTokens.prefix(coveredTokenCount))
     }
 
     /// Tokenizer decode for CB streaming. Must not take `ModelContainer`:
     /// compiled lockstep already holds that hop, and a per-token `perform`
     /// behind the delivery buffer is what turned longer canary streams into
     /// `internal_error` after the first content chunk.
-    private struct StreamingDetokenizer: @unchecked Sendable {
+    struct StreamingDetokenizer: @unchecked Sendable {
         let decode: ([Int]) -> String
     }
 
-    private final class AttachedPagedKVStreamState: @unchecked Sendable {
+    /// A batched streaming row's buyer-visible state (SPEC-038 AC-6c). Each
+    /// delivered token runs the serial path's `SerialStreamingTextEmitter`
+    /// step over the decode of every token so far, as the serial generate
+    /// callback does. Once the serial path would have stopped generating (a
+    /// serial tool turn's first complete tool call, or a structured-output
+    /// accumulator error) later tokens are ignored and the stop point is kept
+    /// so the finalize truncates the row to it.
+    final class AttachedPagedKVStreamState: @unchecked Sendable {
         private let lock = NSLock()
         private var tokenIDs: [Int] = []
-        private var emittedText = ""
+        private var emitter: SerialStreamingTextEmitter
         private var recordedError: APIError?
-
-        func appendTokens(_ tokens: [Int]) -> [Int] {
+        private var stoppedValue = false
+        private var serialStopTokenCountValue: Int?
+
+        init(request: ChatCompletionRequest) {
+            emitter = SerialStreamingTextEmitter(request: request)
+        }
+
+        /// Returns true the first time the row should stop decoding.
+        func step(
+            eventTokens: [Int],
+            decode: ([Int]) -> String,
+            stopTokenFilter: StopTokenFilter,
+            requestStops: [String],
+            structuredAccumulator: StructuredStreamingContentAccumulator,
+            idleState: StructuredStreamingIdleState,
+            onChunk: (StreamChunk) -> Void
+        ) -> Bool {
             lock.lock()
             defer { lock.unlock() }
-            tokenIDs.append(contentsOf: tokens)
-            return tokenIDs
+            guard !stoppedValue, !eventTokens.isEmpty else { return false }
+            tokenIDs.append(contentsOf: eventTokens)
+            let candidate = ModelRuntime.streamingSafePrefix(
+                decode(tokenIDs),
+                stopTokenFilter: stopTokenFilter,
+                requestStops: requestStops
+            )
+            switch emitter.step(
+                candidate: candidate,
+                structuredAccumulator: structuredAccumulator,
+                idleState: idleState,
+                onChunk: onChunk
+            ) {
+            case .more, .requestStop:
+                // A buyer stop string ends the row through its stop-token
+                // sequences, and the final filter cuts the text at it.
+                return false
+            case .toolCallComplete:
+                stoppedValue = true
+                serialStopTokenCountValue = tokenIDs.count
+                return true
+            case .structuredError:
+                stoppedValue = true
+                if recordedError == nil {
+                    recordedError = structuredAccumulator.error
+                }
+                return true
+            }
         }
 
-        func delta(to candidateText: String) -> String {
+        func finish(
+            finalText: String,
+            parsed: ModelRuntime.ParsedGeneratedOutput,
+            structuredAccumulator: StructuredStreamingContentAccumulator,
+            idleState: StructuredStreamingIdleState,
+            onChunk: (StreamChunk) -> Void
+        ) throws {
             lock.lock()
             defer { lock.unlock() }
-            let delta = ModelRuntime.streamDelta(from: emittedText, to: candidateText)
-            if !delta.isEmpty {
-                emittedText = candidateText
-            }
-            return delta
+            try emitter.finish(
+                finalText: finalText,
+                parsed: parsed,
+                structuredAccumulator: structuredAccumulator,
+                idleState: idleState,
+                onChunk: onChunk
+            )
         }
 
-        func record(_ error: APIError) {
+        /// Token count at which the serial path would have stopped a serial
+        /// tool turn; nil when it would not have stopped early.
+        var serialStopTokenCount: Int? {
             lock.lock()
-            if recordedError == nil {
-                recordedError = error
-            }
-            lock.unlock()
+            defer { lock.unlock() }
+            return serialStopTokenCountValue
         }
 
         func error() -> APIError? {
             lock.lock()
             defer { lock.unlock() }
             return recordedError
         }
     }
 
+    /// A batched non-streaming serial tool turn (SPEC-038 AC-6c): the serial
+    /// non-streaming stop test over each delivered token.
+    final class ContinuousBatchSerialToolStopState: @unchecked Sendable {
+        private let lock = NSLock()
+        private var tokenIDs: [Int] = []
+        private var observer: NativeToolCallStreamEmitter
+        private var stopTokenCountValue: Int?
+
+        init(request: ChatCompletionRequest) {
+            observer = NativeToolCallStreamEmitter(
+                modelID: request.model,
+                allowedFunctionNames: ModelRuntime.toolFunctionNames(from: request.promptSource.tools)
+            )
+        }
+
+        /// Returns true the first time the row should stop decoding.
+        func observe(
+            eventTokens: [Int],
+            decode: ([Int]) -> String,
+            stopTokenFilter: StopTokenFilter,
+            requestStops: [String]
+        ) -> Bool {
+            lock.lock()
+            defer { lock.unlock() }
+            guard stopTokenCountValue == nil, !eventTokens.isEmpty else { return false }
+            tokenIDs.append(contentsOf: eventTokens)
+            guard ModelRuntime.observeSerialToolStop(
+                &observer,
+                decoded: decode(tokenIDs),
+                stopTokenFilter: stopTokenFilter,
+                requestStops: requestStops
+            ) else { return false }
+            stopTokenCountValue = tokenIDs.count
+            return true
+        }
+
+        var stopTokenCount: Int? {
+            lock.lock()
+            defer { lock.unlock() }
+            return stopTokenCountValue
+        }
+    }
+
+    struct ContinuousBatchFinalizedRow: Sendable {
+        /// Not yet structured-validated: the non-streaming caller runs
+        /// `validateStructuredCompletion`, the streaming caller first sends
+        /// the held-back text and then `validateStructuredStreamingCompletion`,
+        /// each exactly as its serial counterpart does.
+        let completion: CompletionResult
+        let filteredText: String
+        let parsed: ParsedGeneratedOutput
+        /// Generated tokens the completion accounts for (model EOS dropped,
+        /// truncated to the serial stop point).
+        let generatedTokens: [Int]
+        /// The row decoded past the serial stop point, so its retained cache
+        /// covers tokens the completion does not and must not be committed.
+        let truncatedAtSerialStop: Bool
+    }
+
+    /// SPEC-038 AC-6c: the one post-generation finalize for a batched row,
+    /// streaming and non-streaming. It applies the serial path's response
+    /// byte cap, output filters, `parseGeneratedOutput` (tool calls,
+    /// SPEC-018 caps, Harmony) and finish-reason rule to the row's text. A
+    /// serial tool turn is first truncated to the token at which the serial
+    /// path stops generating, so the parsed text and billed tokens match.
+    static func finalizeContinuousBatchRow(
+        request: ChatCompletionRequest,
+        result: ContinuousBatchSchedulerResult,
+        modelStopTokenIDs: Set<Int>,
+        serialStopTokenCount: Int?,
+        promptTokenIDs: [Int32],
+        decode: ([Int]) -> String,
+        stopTokenFilter: StopTokenFilter,
+        generationMilliseconds: Int64,
+        modelHash: String?
+    ) throws -> ContinuousBatchFinalizedRow {
+        // The serial path discards the model's end-of-generation token
+        // before counting it; bill and cache the batched row the same way.
+        // Harmony `<|return|>`/`<|call|>` are excluded from this set, as
+        // they are from the serial stop set: the parser reads and counts them.
+        var generatedTokens = droppingTrailingModelStop(
+            result.generatedTokens,
+            terminalStatus: result.terminalStatus,
+            modelStopTokenIDs: modelStopTokenIDs
+        )
+        var completionTokenCount = result.completionTokens
+            - (result.generatedTokens.count - generatedTokens.count)
+        var outputTokens = result.outputTokens
+        var truncated = false
+        if let serialStopTokenCount, serialStopTokenCount < generatedTokens.count {
+            completionTokenCount -= generatedTokens.count - serialStopTokenCount
+            generatedTokens = Array(generatedTokens.prefix(serialStopTokenCount))
+            outputTokens = Array(outputTokens.prefix(serialStopTokenCount))
+            truncated = true
+        }
+        let decoded = decode(outputTokens)
+        guard decoded.utf8.count <= ToolCallParser.SPEC018_ARGUMENTS_PER_RESPONSE_BYTE_CAP else {
+            throw APIError(
+                status: 502,
+                message: "Model response exceeded 2097152 bytes",
+                type: "upstream_provider_error",
+                code: "response_byte_cap_exceeded",
+                inferenceRan: true,
+                settlementRan: true
+            )
+        }
+        let filtered = applyOutputFilters(
+            decoded,
+            stopTokenFilter: stopTokenFilter,
+            requestStops: request.stop
+        )
+        // A truncated row ended where the serial path's early stop does,
+        // which is never a length finish.
+        let lengthTerminal = result.terminalStatus == .length && !truncated
+        let parserFinishReason = lengthTerminal && !filtered.hitStop
+            ? "length"
+            : (filtered.hitStop ? "request_stop" : "stop")
+        let parsed = try parseGeneratedOutput(
+            filteredText: filtered.text,
+            generatedTokenIDs: generatedTokens,
+            decode: decode,
+            request: request,
+            mode: .complete(finishReason: parserFinishReason),
+            defaultCompletionTokens: completionTokenCount,
+            stopTokenFilter: stopTokenFilter,
+            requestStops: request.stop,
+            globalHitStop: filtered.hitStop
+        )
+        let finishReason: String
+        if !parsed.toolCalls.isEmpty {
+            finishReason = "tool_calls"
+        } else if lengthTerminal, !filtered.hitStop, !parsed.hitStop {
+            finishReason = "length"
+        } else {
+            finishReason = "stop"
+        }
+        let kvCacheBytesReused = cachedPromptUTF8Bytes(
+            promptTokenIds: promptTokenIDs,
+            cachedPromptTokens: result.cachedPromptTokens,
+            decode: decode
+        )
+        return ContinuousBatchFinalizedRow(
+            completion: CompletionResult(
+                content: parsed.content,
+                finishReason: finishReason,
+                promptTokens: promptTokenIDs.count,
+                cachedPromptTokens: result.cachedPromptTokens,
+                kvCacheBytesReused: kvCacheBytesReused,
+                completionTokens: parsed.completionTokens,
+                generatedCompletionTokens: parsed.generatedCompletionTokens,
+                ttftMilliseconds: nil,
+                generationMilliseconds: generationMilliseconds,
+                toolCalls: parsed.toolCalls.isEmpty ? nil : parsed.toolCalls,
+                modelHashObserved: validObservedModelHash(modelHash),
+                settlementDisposition: result.settlementDisposition
+            ),
+            filteredText: filtered.text,
+            parsed: parsed,
+            generatedTokens: generatedTokens,
+            truncatedAtSerialStop: truncated
+        )
+    }
+
+    /// SPEC-038 AC-6c: the batched streaming end, in the serial stream's
+    /// order: remaining tool-call deltas and held-back content first, then
+    /// the structured verdict on the buyer-visible text.
+    static func finishContinuousBatchStream(
+        _ finalized: ContinuousBatchFinalizedRow,
+        state: AttachedPagedKVStreamState,
+        request: ChatCompletionRequest,
+        structuredAccumulator: StructuredStreamingContentAccumulator,
+        idleState: StructuredStreamingIdleState,
+        onChunk: (StreamChunk) -> Void
+    ) throws -> CompletionResult {
+        try state.finish(
+            finalText: finalized.filteredText,
+            parsed: finalized.parsed,
+            structuredAccumulator: structuredAccumulator,
+            idleState: idleState,
+            onChunk: onChunk
+        )
+        return try validateStructuredStreamingCompletion(
+            finalized.completion,
+            request: request,
+            buyerVisibleContent: structuredAccumulator.content
+        )
+    }
+
     private func serialRouteCanaryCachedHitMissingRetainedHandoff(
         _ lease: ConversationCacheLease?,
         capability: ContinuousBatchingCapability,
         modelHasRecurrentLayers: Bool
     ) async throws -> Bool {
         guard let lease,
               let reason = Self.cachedHitFenceReason(
                   mode: capability.mode,
                   cachedPromptTokens: lease.cachedPromptTokens,
                   hasRetainedPagedKVHandoff: Self.leaseHasUsableRetainedHandoff(
                       lease,
                       modelHasRecurrentLayers: modelHasRecurrentLayers
                   ),
                   cachedTurnsEnabled: continuousBatchingCachedTurns,
                   cachedTurnsAccepted: continuousBatchingCachedTurns
                       && continuousBatchingRequestedTuple().map {
                           continuousBatchingAcceptanceCoverage.coversCachedTurns($0)
                       } == true
               )
         else {
             return false
         }
         // A retained entry (hybrid or not) cannot serve the serial path, so
         // this discards it and the serial request misses; a serial-format entry
         // is put back for the serial path to reuse.
         await conversationCache.abortForSerialFallback(lease)
         let blocked = ContinuousBatchingCapability(
             mode: capability.mode,
             maxActiveRows: capability.maxActiveRows,
             queueLimit: capability.queueLimit,
             descriptor: capability.descriptor,
             unsupportedReason: reason
         )
         // Strict `.on` must fail closed with the named reason (FR-CB8). Canary
         // serial-routes the same AC-26 fence with reason-coded telemetry.
         try ContinuousBatchingPolicy.validateStrictStartup(blocked)
         ContinuousBatchingPolicy.logSerialRouteIfNeeded(blocked)
         return true
     }
 
     static func canaryShouldSerialRouteCachedHitMissingRetainedHandoff(
         mode: ContinuousBatchingMode,
         cachedPromptTokens: Int,
         hasRetainedPagedKVHandoff: Bool,
         cachedTurnsEnabled: Bool = false,
         cachedTurnsAccepted: Bool = false
     ) -> Bool {
         cachedHitFenceReason(
             mode: mode,
             cachedPromptTokens: cachedPromptTokens,
             hasRetainedPagedKVHandoff: hasRetainedPagedKVHandoff,
             cachedTurnsEnabled: cachedTurnsEnabled,
             cachedTurnsAccepted: cachedTurnsAccepted
         ) != nil
     }
 
     /// AC-26 fence for a positive cached-token hit. It stays out of the
     /// scheduler unless the operator opted into `continuous_batching_cached_turns`,
     /// the lease carries a usable retained handoff, AND the accepted tuple
     /// covering this runtime records `cached_turns_accepted` (the per-tuple,
     /// revision-bound packaged proof). A retained handoff alone is capability,
     /// not authorization. Nil means the request may enter the scheduler.
     static func cachedHitFenceReason(
         mode: ContinuousBatchingMode,
         cachedPromptTokens: Int,
         hasRetainedPagedKVHandoff: Bool,
         cachedTurnsEnabled: Bool,
         cachedTurnsAccepted: Bool
     ) -> ContinuousBatchingUnsupportedReason? {
         guard mode != .off, cachedPromptTokens > 0 else { return nil }
         guard cachedTurnsEnabled, hasRetainedPagedKVHandoff else { return .stickyCacheHandoffUnavailable }
         return cachedTurnsAccepted ? nil : .cachedTurnsNotAccepted
     }
 
     /// A hybrid retained delivery is resumable only from a recurrent checkpoint;
     /// one without any is discarded instead of committed as an entry no turn
     /// could resume (SPEC-038 AC-26).
     nonisolated static func retainedCacheIsCommittable(
         _ retainedCache: ContinuousBatchRetainedCache,
         modelHasRecurrentLayers: Bool
     ) -> Bool {
         !modelHasRecurrentLayers || !retainedCache.recurrentCheckpoints.isEmpty
     }
 
     /// A retained paged-KV sequence, plus on a hybrid model the recurrent
     /// checkpoint at exactly the cached length (SPEC-038 AC-26).
     nonisolated static func leaseHasUsableRetainedHandoff(
         _ lease: ConversationCacheLease,
         modelHasRecurrentLayers: Bool
     ) -> Bool {
         guard lease.reusableCache?.retainedPagedKVSequence != nil else { return false }
         guard modelHasRecurrentLayers else { return true }
         return lease.recurrentCheckpoint?.tokenCount == lease.cachedPromptTokens
     }
 
     /// The stored checkpoints a hybrid cached turn hands the scheduler: every
     /// one at or below the cached length (they are a prefix of this prompt).
     /// Empty unless the lease resumes a retained hybrid entry.
     nonisolated static func retainedRecurrentCheckpoints(
         for lease: ConversationCacheLease?
     ) -> [RecurrentStateCheckpoint] {
         guard let lease,
               lease.recurrentCheckpoint != nil,
               let reusable = lease.reusableCache,
               reusable.retainedPagedKVSequence != nil
         else { return [] }
         return reusable.recurrentCheckpoints.filter { $0.tokenCount <= lease.cachedPromptTokens }
     }
 
     private func attachedContinuousBatchCompletion(
         request: ChatCompletionRequest,
         snapshot: RuntimeSnapshot,
         capability: ContinuousBatchingCapability,
         completionStartedAt: Date,
         shouldCancel: @escaping @Sendable () -> Bool,
         drainCancelled: DrainCancelToken
     ) async throws -> CompletionResult? {
         guard capability.isRequested,
               capability.unsupportedReason == nil,
               !capability.shouldUseSerialPath,
               case .attached = pagedKVAttachDecision
         else {
             return nil
         }
         guard let scheduler = continuousBatchScheduler else {
             throw Self.attachedPagedKVUnavailableError(code: "continuous_batching_scheduler_unavailable")
         }
         guard let schedulerRequestID = Self.schedulerRequestID(for: request) else {
             throw Self.attachedPagedKVUnavailableError(code: ContinuousBatchingUnsupportedReason.stableRequestIDUnavailable.apiCode)
         }
         guard let container = snapshot.container else {
             throw APIError(status: 503, message: "Model not loaded", type: "server_error", code: "model_not_loaded")
         }
 
         let maxContextTokens = maxContextTokens
         let stopTokenFilter = stopTokenFilter
         let templateSupportsThinkingToggle = snapshot.templateSupportsThinkingToggle
         CBTrace.log(schedulerRequestID, "rt_cb_prepare")
-        let prepared = try await container.perform { context -> ContinuousBatchPreparedRequest in
+        let (prepared, detokenizer) = try await container.perform { context -> (ContinuousBatchPreparedRequest, StreamingDetokenizer) in
             try drainCancelled.check()
             try Task.checkCancellation()
             let input = try Self.userInput(
                 for: request,
                 templateSupportsThinkingToggle: templateSupportsThinkingToggle
             )
             let lmInput = try await context.processor.prepare(input: input)
             let promptTokens = lmInput.text.tokens.asArray(Int32.self).map(Int.init)
             try Self.validatePromptTokenCount(promptTokens.count, maxContextTokens: maxContextTokens)
             let stopTokenSequences = Self.continuousBatchStopTokenSequences(
                 requestStops: request.stop,
                 context: context
             )
+            let tokenizer = context.tokenizer
             // Only keyed requests can hold or reuse conversation state.
             let hybrid = Self.nonEmpty(request.conversationKey) != nil
                 && ConversationCacheLayers.hasRecurrentLayers(context.model.newCache(parameters: nil))
-            return ContinuousBatchPreparedRequest(
-                promptTokens: promptTokens,
-                stopTokenSequences: stopTokenSequences,
-                modelStopTokenIDs: Self.generationStopTokenIDs(
-                    for: Self.harmonyTerminalPreservingContext(from: context, modelID: request.model)
-                ),
-                recurrentCheckpointPositions: Self.continuousBatchRecurrentCheckpointPositions(
+            return (
+                ContinuousBatchPreparedRequest(
                     promptTokens: promptTokens,
-                    conversationKey: request.conversationKey,
-                    hybrid: hybrid,
-                    context: context
+                    stopTokenSequences: stopTokenSequences,
+                    modelStopTokenIDs: Self.generationStopTokenIDs(
+                        for: Self.harmonyTerminalPreservingContext(from: context, modelID: request.model)
+                    ),
+                    recurrentCheckpointPositions: Self.continuousBatchRecurrentCheckpointPositions(
+                        promptTokens: promptTokens,
+                        conversationKey: request.conversationKey,
+                        hybrid: hybrid,
+                        context: context
+                    ),
+                    modelHasRecurrentLayers: hybrid
                 ),
-                modelHasRecurrentLayers: hybrid
+                StreamingDetokenizer { tokenizer.decode(tokenIds: $0) }
             )
         }
 
         try drainCancelled.check()
         try Task.checkCancellation()
         if shouldCancel() { throw CancellationError() }
         let maxOutputTokens = request.maxTokens ?? max(1, maxContextTokens - prepared.promptTokens.count)
         let preparedPromptTokenIDs = prepared.promptTokens.map(Int32.init)
         let batchKVBits = Self.effectiveKVBits(
             configured: kvBitsOverride,
             conversationKey: request.conversationKey
         )
         let lease = await conversationCache.begin(
             conversationKey: request.conversationKey,
             incomingTokens: preparedPromptTokenIDs,
             modelID: request.model,
             kvBits: batchKVBits,
             allowRetainedPagedKVHandoff: true
         )
         CBTrace.log(schedulerRequestID, "rt_cb_lease cached=\(lease?.cachedPromptTokens ?? -1)")
         if try await serialRouteCanaryCachedHitMissingRetainedHandoff(
             lease,
             capability: capability,
             modelHasRecurrentLayers: prepared.modelHasRecurrentLayers
         ) {
             return nil
         }
+        // SPEC-038 AC-6c: a serial tool turn stops where the serial path
+        // stops generating (its first complete valid tool call).
+        let serialToolStop = Self.serialToolStopApplies(request)
+            ? ContinuousBatchSerialToolStopState(request: request)
+            : nil
+        let requestStops = request.stop
         let result: ContinuousBatchSchedulerResult
         do {
             CBTrace.log(schedulerRequestID, "rt_cb_submit")
             result = try await Self.withDrainAndClientCancellation(drainCancelled, shouldCancel: shouldCancel) {
                 try await scheduler.submit(ContinuousBatchSchedulerRequest(
                     id: schedulerRequestID,
                     conversationKey: request.conversationKey ?? "",
                     promptTokens: prepared.promptTokens,
                     maxOutputTokens: maxOutputTokens,
                     stopTokenSequences: prepared.stopTokenSequences,
                     samplerSeed: ContinuousBatchRowSampler.requestSeed(requestID: schedulerRequestID),
                     temperature: request.temperature,
                     topP: request.topP,
                     presencePenalty: request.presencePenalty,
                     frequencyPenalty: request.frequencyPenalty,
                     cachedPromptTokens: lease?.cachedPromptTokens ?? 0,
                     retainedPagedKVSequence: lease?.reusableCache?.retainedPagedKVSequence,
                     recurrentCheckpointPositions: prepared.recurrentCheckpointPositions,
                     retainedRecurrentCheckpoints: Self.retainedRecurrentCheckpoints(for: lease)
-                ))
+                ), tokenSink: { event in
+                    guard let serialToolStop else { return }
+                    if serialToolStop.observe(
+                        eventTokens: event.replayTokens ?? [event.token],
+                        decode: detokenizer.decode,
+                        stopTokenFilter: stopTokenFilter,
+                        requestStops: requestStops
+                    ) {
+                        Task { await scheduler.stopEarly(requestID: schedulerRequestID) }
+                    }
+                })
             }
         } catch {
             if let lease {
                 await conversationCache.abort(lease)
             }
             // SPEC-038 AC-25: one shared scheduler-error map, so the
             // non-streaming and streaming paths cannot drift.
             CBTrace.log(schedulerRequestID, "rt_cb_threw \(type(of: error))")
             throw (error as? ContinuousBatchSchedulerError)?.asAPIError() ?? error
         }
         CBTrace.log(schedulerRequestID, "rt_cb_returned status=\(result.terminalStatus)")
         do {
             try drainCancelled.check()
             try Task.checkCancellation()
             if shouldCancel() { throw CancellationError() }
             guard result.terminalStatus == .stop || result.terminalStatus == .length else {
                 throw Self.terminalFailureError(code: result.errorCode ?? "continuous_batching_request_failed")
             }
             let completionEndedAt = Date()
-            // The serial path discards the model's end-of-generation token
-            // before counting it; bill and cache the batched row the same way.
-            // Harmony `<|return|>`/`<|call|>` are excluded from this set, as
-            // they are from the serial stop set: the parser reads and counts them.
-            let generatedTokens = Self.droppingTrailingModelStop(
-                result.generatedTokens,
-                terminalStatus: result.terminalStatus,
-                modelStopTokenIDs: prepared.modelStopTokenIDs
-            )
-            let completionTokenCount = result.completionTokens
-                - (result.generatedTokens.count - generatedTokens.count)
-            let completion = try await container.perform { context in
-                let decoded = context.tokenizer.decode(tokenIds: result.outputTokens)
-                guard decoded.utf8.count <= ToolCallParser.SPEC018_ARGUMENTS_PER_RESPONSE_BYTE_CAP else {
-                    throw APIError(
-                        status: 502,
-                        message: "Model response exceeded 2097152 bytes",
-                        type: "upstream_provider_error",
-                        code: "response_byte_cap_exceeded",
-                        inferenceRan: true,
-                        settlementRan: true
-                    )
-                }
-                let filtered = Self.applyOutputFilters(
-                    decoded,
-                    stopTokenFilter: stopTokenFilter,
-                    requestStops: request.stop
-                )
-                let parserFinishReason = result.terminalStatus == .length && !filtered.hitStop
-                    ? "length"
-                    : (filtered.hitStop ? "request_stop" : "stop")
-                let parsed = try Self.parseGeneratedOutput(
-                    filteredText: filtered.text,
-                    generatedTokenIDs: generatedTokens,
-                    decode: { context.tokenizer.decode(tokenIds: $0) },
+            let finalized = try await container.perform { context in
+                try Self.finalizeContinuousBatchRow(
                     request: request,
-                    mode: .complete(finishReason: parserFinishReason),
-                    defaultCompletionTokens: completionTokenCount,
+                    result: result,
+                    modelStopTokenIDs: prepared.modelStopTokenIDs,
+                    serialStopTokenCount: serialToolStop?.stopTokenCount,
+                    promptTokenIDs: preparedPromptTokenIDs,
+                    decode: { context.tokenizer.decode(tokenIds: $0) },
                     stopTokenFilter: stopTokenFilter,
-                    requestStops: request.stop,
-                    globalHitStop: filtered.hitStop
-                )
-                let finishReason: String
-                if !parsed.toolCalls.isEmpty {
-                    finishReason = "tool_calls"
-                } else if result.terminalStatus == .length, !filtered.hitStop, !parsed.hitStop {
-                    finishReason = "length"
-                } else {
-                    finishReason = "stop"
-                }
-                let kvCacheBytesReused = Self.cachedPromptUTF8Bytes(
-                    promptTokenIds: preparedPromptTokenIDs,
-                    cachedPromptTokens: result.cachedPromptTokens,
-                    decode: { context.tokenizer.decode(tokenIds: $0) }
-                )
-                return try Self.validateStructuredCompletion(CompletionResult(
-                    content: parsed.content,
-                    finishReason: finishReason,
-                    promptTokens: prepared.promptTokens.count,
-                    cachedPromptTokens: result.cachedPromptTokens,
-                    kvCacheBytesReused: kvCacheBytesReused,
-                    completionTokens: parsed.completionTokens,
-                    generatedCompletionTokens: parsed.generatedCompletionTokens,
-                    ttftMilliseconds: nil,
                     generationMilliseconds: Int64(completionEndedAt.timeIntervalSince(completionStartedAt) * 1000),
-                    toolCalls: parsed.toolCalls.isEmpty ? nil : parsed.toolCalls,
-                    modelHashObserved: Self.validObservedModelHash(snapshot.modelHash),
-                    settlementDisposition: result.settlementDisposition
-                ), request: request)
+                    modelHash: snapshot.modelHash
+                )
             }
-            if let lease, let retainedCache = result.retainedCache,
+            let completion = try Self.validateStructuredCompletion(finalized.completion, request: request)
+            let generatedTokens = finalized.generatedTokens
+            if !finalized.truncatedAtSerialStop,
+               let lease, let retainedCache = result.retainedCache,
                Self.retainedCacheIsCommittable(
                    retainedCache,
                    modelHasRecurrentLayers: prepared.modelHasRecurrentLayers
                ) {
                 await conversationCache.commit(
                     lease,
                     cache: ConversationCacheLayers(
                         retainedCache.layers,
                         retainedPagedKVSequence: retainedCache.retainedSequence,
                         discardRetainedPagedKVSequence: { retained, key in
                             await scheduler.discardRetainedCache(retained, conversationKey: key)
                         },
                         recurrentCheckpoints: retainedCache.recurrentCheckpoints
                     ),
                     fullTokens: preparedPromptTokenIDs + generatedTokens.map(Int32.init)
                 )
                 await scheduler.acknowledgeRetainedCacheDelivery(retainedCache)
-            } else if let lease, let serialCache = result.serialConversationCache,
+            } else if !finalized.truncatedAtSerialStop,
+                      let lease, let serialCache = result.serialConversationCache,
                       let fullTokens = Self.serialConversationCacheCommitTokens(
                           canonicalTokens: preparedPromptTokenIDs + generatedTokens.map(Int32.init),
                           coveredTokenCount: serialCache.tokenCount
                       ) {
                 // SPEC-038 FR-CB4 hybrid first turn: the next keyed turn serial-
                 // routes (AC-26) and reuses this entry from its checkpoints.
                 await conversationCache.commit(
                     lease,
                     cache: ConversationCacheLayers(
                         serialCache.layers,
                         recurrentCheckpoints: serialCache.recurrentCheckpoints
                     ),
                     fullTokens: fullTokens
                 )
             } else if let retainedCache = result.retainedCache {
                 await scheduler.cancelRetainedCacheDelivery(
                     retainedCache,
                     conversationKey: result.conversationKey
                 )
                 if let lease {
                     await conversationCache.abort(lease)
                 }
             } else if let lease {
                 await conversationCache.abort(lease)
             }
             return completion
         } catch {
             if let retainedCache = result.retainedCache {
                 await scheduler.cancelRetainedCacheDelivery(
                     retainedCache,
                     conversationKey: result.conversationKey
                 )
             }
             if let lease {
                 await conversationCache.abort(lease)
             }
             throw error
         }
     }
 
     nonisolated static func schedulerRequestID(for request: ChatCompletionRequest) -> String? {
         nonEmpty(request.requestID)
     }
 
     private func attachedContinuousBatchStreamingCompletion(
         request: ChatCompletionRequest,
         snapshot: RuntimeSnapshot,
         capability: ContinuousBatchingCapability,
         completionStartedAt: Date,
         shouldCancel: @escaping @Sendable () -> Bool,
         drainCancelled: DrainCancelToken,
         structuredAccumulator: StructuredStreamingContentAccumulator,
         idleState: StructuredStreamingIdleState,
+        idleCancellation: DrainCancelToken,
         onChunk: @escaping @Sendable (StreamChunk) -> Void
     ) async throws -> CompletionResult? {
         guard capability.isRequested,
               capability.unsupportedReason == nil,
               !capability.shouldUseSerialPath,
               case .attached = pagedKVAttachDecision
         else {
             return nil
         }
         guard let scheduler = continuousBatchScheduler else {
             throw Self.attachedPagedKVUnavailableError(code: "continuous_batching_scheduler_unavailable")
         }
         guard let schedulerRequestID = Self.schedulerRequestID(for: request) else {
             throw Self.attachedPagedKVUnavailableError(code: ContinuousBatchingUnsupportedReason.stableRequestIDUnavailable.apiCode)
         }
         guard let container = snapshot.container else {
             throw APIError(status: 503, message: "Model not loaded", type: "server_error", code: "model_not_loaded")
         }
 
         let maxContextTokens = maxContextTokens
         let stopTokenFilter = stopTokenFilter
         let templateSupportsThinkingToggle = snapshot.templateSupportsThinkingToggle
         let requestStops = request.stop
         let (prepared, detokenizer) = try await container.perform { context -> (ContinuousBatchPreparedRequest, StreamingDetokenizer) in
             try drainCancelled.check()
             try Task.checkCancellation()
             let input = try Self.userInput(
                 for: request,
                 templateSupportsThinkingToggle: templateSupportsThinkingToggle
             )
             let lmInput = try await context.processor.prepare(input: input)
             let promptTokens = lmInput.text.tokens.asArray(Int32.self).map(Int.init)
             try Self.validatePromptTokenCount(promptTokens.count, maxContextTokens: maxContextTokens)
             let stopTokenSequences = Self.continuousBatchStopTokenSequences(
                 requestStops: requestStops,
                 context: context
             )
             let tokenizer = context.tokenizer
             // Only keyed requests can hold or reuse conversation state.
             let hybrid = Self.nonEmpty(request.conversationKey) != nil
                 && ConversationCacheLayers.hasRecurrentLayers(context.model.newCache(parameters: nil))
             return (
                 ContinuousBatchPreparedRequest(
                     promptTokens: promptTokens,
                     stopTokenSequences: stopTokenSequences,
                     modelStopTokenIDs: Self.generationStopTokenIDs(
                     for: Self.harmonyTerminalPreservingContext(from: context, modelID: request.model)
                 ),
                     recurrentCheckpointPositions: Self.continuousBatchRecurrentCheckpointPositions(
                         promptTokens: promptTokens,
                         conversationKey: request.conversationKey,
                         hybrid: hybrid,
                         context: context
                     ),
                     modelHasRecurrentLayers: hybrid
                 ),
                 StreamingDetokenizer { tokenizer.decode(tokenIds: $0) }
             )
         }
 
         try drainCancelled.check()
         try Task.checkCancellation()
         if shouldCancel() { throw CancellationError() }
-        let streamState = AttachedPagedKVStreamState()
+        let streamState = AttachedPagedKVStreamState(request: request)
         let maxOutputTokens = request.maxTokens ?? max(1, maxContextTokens - prepared.promptTokens.count)
         let preparedPromptTokenIDs = prepared.promptTokens.map(Int32.init)
         let batchKVBits = Self.effectiveKVBits(
             configured: kvBitsOverride,
             conversationKey: request.conversationKey
         )
         let lease = await conversationCache.begin(
             conversationKey: request.conversationKey,
             incomingTokens: preparedPromptTokenIDs,
             modelID: request.model,
             kvBits: batchKVBits,
             allowRetainedPagedKVHandoff: true
         )
         if try await serialRouteCanaryCachedHitMissingRetainedHandoff(
             lease,
             capability: capability,
             modelHasRecurrentLayers: prepared.modelHasRecurrentLayers
         ) {
             return nil
         }
         let result: ContinuousBatchSchedulerResult
         do {
-            result = try await Self.withDrainAndClientCancellation(drainCancelled, shouldCancel: shouldCancel) {
+            // The SPEC-019 structured idle timeout ends the row as it ends the
+            // serial generate loop.
+            result = try await Self.withDrainAndClientCancellation(
+                drainCancelled,
+                shouldCancel: { shouldCancel() || idleCancellation.isFired }
+            ) {
                 try await scheduler.submit(ContinuousBatchSchedulerRequest(
                     id: schedulerRequestID,
                     conversationKey: request.conversationKey ?? "",
                     promptTokens: prepared.promptTokens,
                     maxOutputTokens: maxOutputTokens,
                     stopTokenSequences: prepared.stopTokenSequences,
                     samplerSeed: ContinuousBatchRowSampler.requestSeed(requestID: schedulerRequestID),
                     temperature: request.temperature,
                     topP: request.topP,
                     presencePenalty: request.presencePenalty,
                     frequencyPenalty: request.frequencyPenalty,
                     cachedPromptTokens: lease?.cachedPromptTokens ?? 0,
                     retainedPagedKVSequence: lease?.reusableCache?.retainedPagedKVSequence,
                     recurrentCheckpointPositions: prepared.recurrentCheckpointPositions,
                     retainedRecurrentCheckpoints: Self.retainedRecurrentCheckpoints(for: lease)
                 ), tokenSink: { event in
-                    let eventTokens = event.replayTokens ?? [event.token]
-                    guard !eventTokens.isEmpty else { return }
-                    let allTokens = streamState.appendTokens(eventTokens)
-                    let candidate = Self.streamingSafePrefix(
-                        detokenizer.decode(allTokens),
+                    guard !idleCancellation.isFired else { return }
+                    if streamState.step(
+                        eventTokens: event.replayTokens ?? [event.token],
+                        decode: detokenizer.decode,
                         stopTokenFilter: stopTokenFilter,
-                        requestStops: requestStops
-                    )
-                    let delta = streamState.delta(to: candidate.text)
-                    guard !delta.isEmpty else { return }
-                    if let error = structuredAccumulator.append(delta) {
-                        streamState.record(error)
-                        return
+                        requestStops: requestStops,
+                        structuredAccumulator: structuredAccumulator,
+                        idleState: idleState,
+                        onChunk: onChunk
+                    ) {
+                        Task { await scheduler.stopEarly(requestID: schedulerRequestID) }
                     }
-                    idleState.noteContent()
-                    onChunk(.content(delta))
                 })
             }
         } catch {
             if let lease {
                 await conversationCache.abort(lease)
             }
             // SPEC-038 AC-25: one shared scheduler-error map, so the
             // streaming and non-streaming paths cannot drift.
             throw (error as? ContinuousBatchSchedulerError)?.asAPIError() ?? error
         }
         do {
             if let error = streamState.error() {
                 throw error
             }
             try drainCancelled.check()
             try Task.checkCancellation()
             if shouldCancel() { throw CancellationError() }
             guard result.terminalStatus == .stop || result.terminalStatus == .length else {
                 throw Self.terminalFailureError(code: result.errorCode ?? "continuous_batching_request_failed")
             }
             let completionEndedAt = Date()
-            // The serial path discards the model's end-of-generation token
-            // before counting it; bill and cache the batched row the same way.
-            // Harmony `<|return|>`/`<|call|>` are excluded from this set, as
-            // they are from the serial stop set: the parser reads and counts them.
-            let generatedTokens = Self.droppingTrailingModelStop(
-                result.generatedTokens,
-                terminalStatus: result.terminalStatus,
-                modelStopTokenIDs: prepared.modelStopTokenIDs
-            )
-            let completionTokenCount = result.completionTokens
-                - (result.generatedTokens.count - generatedTokens.count)
-            let completion = try await container.perform { context in
-                let decoded = context.tokenizer.decode(tokenIds: result.outputTokens)
-                guard decoded.utf8.count <= ToolCallParser.SPEC018_ARGUMENTS_PER_RESPONSE_BYTE_CAP else {
-                    throw APIError(
-                        status: 502,
-                        message: "Model response exceeded 2097152 bytes",
-                        type: "upstream_provider_error",
-                        code: "response_byte_cap_exceeded",
-                        inferenceRan: true,
-                        settlementRan: true
-                    )
-                }
-                let filtered = Self.applyOutputFilters(
-                    decoded,
-                    stopTokenFilter: stopTokenFilter,
-                    requestStops: requestStops
-                )
-                let parserFinishReason = result.terminalStatus == .length && !filtered.hitStop
-                    ? "length"
-                    : (filtered.hitStop ? "request_stop" : "stop")
-                let parsed = try Self.parseGeneratedOutput(
-                    filteredText: filtered.text,
-                    generatedTokenIDs: generatedTokens,
-                    decode: { context.tokenizer.decode(tokenIds: $0) },
+            let finalized = try await container.perform { context in
+                try Self.finalizeContinuousBatchRow(
                     request: request,
-                    mode: .complete(finishReason: parserFinishReason),
-                    defaultCompletionTokens: completionTokenCount,
+                    result: result,
+                    modelStopTokenIDs: prepared.modelStopTokenIDs,
+                    serialStopTokenCount: streamState.serialStopTokenCount,
+                    promptTokenIDs: preparedPromptTokenIDs,
+                    decode: { context.tokenizer.decode(tokenIds: $0) },
                     stopTokenFilter: stopTokenFilter,
-                    requestStops: requestStops,
-                    globalHitStop: filtered.hitStop
-                )
-                let finishReason: String
-                if !parsed.toolCalls.isEmpty {
-                    finishReason = "tool_calls"
-                } else if result.terminalStatus == .length, !filtered.hitStop, !parsed.hitStop {
-                    finishReason = "length"
-                } else {
-                    finishReason = "stop"
-                }
-                let kvCacheBytesReused = Self.cachedPromptUTF8Bytes(
-                    promptTokenIds: preparedPromptTokenIDs,
-                    cachedPromptTokens: result.cachedPromptTokens,
-                    decode: { context.tokenizer.decode(tokenIds: $0) }
-                )
-                return try Self.validateStructuredCompletion(CompletionResult(
-                    content: parsed.content,
-                    finishReason: finishReason,
-                    promptTokens: prepared.promptTokens.count,
-                    cachedPromptTokens: result.cachedPromptTokens,
-                    kvCacheBytesReused: kvCacheBytesReused,
-                    completionTokens: parsed.completionTokens,
-                    generatedCompletionTokens: parsed.generatedCompletionTokens,
-                    ttftMilliseconds: nil,
                     generationMilliseconds: Int64(completionEndedAt.timeIntervalSince(completionStartedAt) * 1000),
-                    toolCalls: parsed.toolCalls.isEmpty ? nil : parsed.toolCalls,
-                    modelHashObserved: Self.validObservedModelHash(snapshot.modelHash),
-                    settlementDisposition: result.settlementDisposition
-                ), request: request)
+                    modelHash: snapshot.modelHash
+                )
             }
             // #1690 E2E-F13: the stream held back an incomplete UTF-8 tail
-            // and any stop-string prefix; send the remainder as the final
-            // text renders it, so the buyer's bytes equal the receipt's.
-            if completion.toolCalls?.isEmpty != false {
-                let remainder = streamState.delta(to: completion.content)
-                if !remainder.isEmpty {
-                    if let error = structuredAccumulator.append(remainder) {
-                        throw error
-                    }
-                    idleState.noteContent()
-                    onChunk(.content(remainder))
-                }
-            }
-            let validated = try Self.validateStructuredStreamingCompletion(
-                completion,
+            // and any stop-string prefix; the serial stream's end sends the
+            // remainder as the final text renders it, so the buyer's bytes
+            // equal the receipt's.
+            let validated = try Self.finishContinuousBatchStream(
+                finalized,
+                state: streamState,
                 request: request,
-                buyerVisibleContent: structuredAccumulator.content
+                structuredAccumulator: structuredAccumulator,
+                idleState: idleState,
+                onChunk: onChunk
             )
-            if let lease, let retainedCache = result.retainedCache,
+            let generatedTokens = finalized.generatedTokens
+            if !finalized.truncatedAtSerialStop,
+               let lease, let retainedCache = result.retainedCache,
                Self.retainedCacheIsCommittable(
                    retainedCache,
                    modelHasRecurrentLayers: prepared.modelHasRecurrentLayers
                ) {
                 await conversationCache.commit(
                     lease,
                     cache: ConversationCacheLayers(
                         retainedCache.layers,
                         retainedPagedKVSequence: retainedCache.retainedSequence,
                         discardRetainedPagedKVSequence: { retained, key in
                             await scheduler.discardRetainedCache(retained, conversationKey: key)
                         },
                         recurrentCheckpoints: retainedCache.recurrentCheckpoints
                     ),
                     fullTokens: preparedPromptTokenIDs + generatedTokens.map(Int32.init)
                 )
                 await scheduler.acknowledgeRetainedCacheDelivery(retainedCache)
-            } else if let lease, let serialCache = result.serialConversationCache,
+            } else if !finalized.truncatedAtSerialStop,
+                      let lease, let serialCache = result.serialConversationCache,
                       let fullTokens = Self.serialConversationCacheCommitTokens(
                           canonicalTokens: preparedPromptTokenIDs + generatedTokens.map(Int32.init),
                           coveredTokenCount: serialCache.tokenCount
                       ) {
                 // SPEC-038 FR-CB4 hybrid first turn: the next keyed turn serial-
                 // routes (AC-26) and reuses this entry from its checkpoints.
                 await conversationCache.commit(
                     lease,
                     cache: ConversationCacheLayers(
                         serialCache.layers,
                         recurrentCheckpoints: serialCache.recurrentCheckpoints
                     ),
                     fullTokens: fullTokens
                 )
             } else if let retainedCache = result.retainedCache {
                 await scheduler.cancelRetainedCacheDelivery(
                     retainedCache,
                     conversationKey: result.conversationKey
                 )
                 if let lease {
                     await conversationCache.abort(lease)
                 }
             } else if let lease {
                 await conversationCache.abort(lease)
             }
             return validated
         } catch {
             if let retainedCache = result.retainedCache {
                 await scheduler.cancelRetainedCacheDelivery(
                     retainedCache,
                     conversationKey: result.conversationKey
                 )
             }
             if let lease {
                 await conversationCache.abort(lease)
             }
             throw error
         }
     }
 
     /// SPEC-038 AC-25: a non-terminal scheduler *result*, as distinct from a
     /// thrown scheduler error. Most carried codes are pre-inference, so they
     /// take the `inferenceRan: false` shape. The one that is not is
     /// post-token delivery backpressure — the row was decoding and the buyer
     /// may already hold partial output — so it reuses the single
     /// `.deliveryBackpressure` mapping rather than a second, divergent copy.
     private nonisolated static func terminalFailureError(code: String) -> APIError {
         if code == ContinuousBatchSchedulerError.deliveryBackpressureCode,
            let mapped = ContinuousBatchSchedulerError.deliveryBackpressure.asAPIError() {
             return mapped
         }
         return attachedPagedKVUnavailableError(code: code)
     }
 
     private nonisolated static func attachedPagedKVUnavailableError(code: String) -> APIError {
         APIError(
             status: 503,
             message: "Inference engine unavailable",
             type: "server_error",
             code: code,
             inferenceRan: false,
             settlementRan: false
         )
     }
 
     func complete(
         _ request: ChatCompletionRequest,
         shouldCancel: @escaping @Sendable () -> Bool = { false }
     ) async throws -> CompletionResult {
         let (result, _) = try await completeWithServedSnapshot(request, shouldCancel: shouldCancel)
         return result
     }
 
     /// Runs a synthetic, coordinator-invisible inference against the loaded
     /// runtime. This intentionally bypasses ProviderStatus request accounting,
     /// receipt emission, and conversation-cache reads/writes.
     func runInternalWarmup(
         maxTokens: Int,
         prompt: String,
         shouldCancel: @escaping @Sendable () -> Bool
@@ -4875,187 +5040,183 @@ actor ModelRuntime: ModelRuntimeServing {
                         draftLoaded: snapshot.hasTargetCompatibleDraft && snapshot.draftContainer != nil,
                         numDraftTokens: snapshot.numDraftTokens
                     ) == .speculative,
                        let draftContainer = snapshot.draftContainer,
                        let numDraftTokens = snapshot.numDraftTokens,
                        speculativeCacheWrapValidated,
                        Self.speculativeCacheWindowSafe(
                            promptTokens: promptTokenIds.count,
                            maxTokens: request.maxTokens,
                            maxContextTokens: maxContextTokens,
                            numDraftTokens: numDraftTokens
                        ) {
                         do {
                             return try await Self.runSpeculativeCompletion(
                                 input: lmInput,
                                 parameters: parameters,
                                 targetContext: context,
                                 draft: draftContainer,
                                 numDraftTokens: numDraftTokens,
                                 request: request,
                                 stopTokenFilter: stopTokenFilter,
                                 promptTokenCount: promptTokenIds.count,
                                 completionStartedAt: completionStartedAt,
                                 modelHash: snapshot.modelHash,
                                 specDecodeGeneration: snapshot.specDecodeGeneration,
                                 shouldCancel: shouldCancel,
                                 drainCancelled: drainCancelled,
                                 blockingInferenceExecutor: blockingInferenceExecutor
                             )
                         } catch let error as DrainCancelledError {
                             throw error
                         } catch let error as CancellationError {
                             throw error
                         } catch let error as SpeculativeGenerationFailure {
                             // FR-12 permits one pre-output retry on the existing
                             // non-speculative target path. This branch happens
                             // before any buyer-visible response exists for the
                             // non-streaming endpoint.
                             Self.logSpeculativeFallback(error)
                         }
                     }
                     let lease = await conversationCache.begin(
                         conversationKey: request.conversationKey,
                         incomingTokens: promptTokenIds,
                         modelID: request.model,
                         kvBits: kvBitsOverride,
                         cold: coldContext
                     )
                         do {
                             let generationContext = Self.harmonyTerminalPreservingContext(from: context, modelID: request.model)
                             let kvCache: [KVCache]
                             var iteratorInput: LMInput
                             if let reusableCache = lease?.reusableCache, let lcp = lease?.lcp {
                                 kvCache = reusableCache.layers
                                 iteratorInput = LMInput(tokens: MLXArray(Array(promptTokenIds[lcp...])))
                             } else {
                                 // SPEC-037 FR-KVP1 / SPEC-024-R001: eligible persist and
                                 // keyed serial reuse allocate KVCacheSimple; keyless traffic
                                 // keeps the rotating cap. TokenIterator still gets the
                                 // original `parameters` (its maxKVSize is ignored once the
                                 // cache is passed explicitly).
                                 kvCache = Self.serveCache(
                                     model: generationContext.model, baseParameters: parameters,
                                     forceSimpleKV: Self.forceSimpleKVCache(
                                         eligible: coldContext?.eligible == true,
                                         conversationKey: request.conversationKey))
                                 iteratorInput = lmInput
                             }
                             let recurrent = Self.prefillRecurrentCheckpoints(
                                 lease: lease, cache: kvCache, promptTokenIds: promptTokenIds,
                                 context: generationContext, prefillStepSize: parameters.prefillStepSize)
                             if let resumeAt = recurrent.resumeAt {
                                 iteratorInput = LMInput(tokens: MLXArray(Array(promptTokenIds[resumeAt...])))
                             }
 
                             let iterator = try TokenIterator(input: iteratorInput, model: generationContext.model, cache: kvCache, parameters: parameters)
                             var serialToolObserver = NativeToolCallStreamEmitter(
                                 modelID: request.model,
                                 allowedFunctionNames: Self.toolFunctionNames(from: request.promptSource.tools)
                             )
+                            let serialToolStopApplies = Self.serialToolStopApplies(request)
                             let result: BlockingGenerateResult = try await blockingInferenceExecutor.run { inferenceCancellation in
                                 BlockingGenerateResult(generate(input: iteratorInput, context: generationContext, iterator: iterator) { tokens in
                                     if !tokens.isEmpty {
                                         firstToken.recordIfMissing()
                                         ModelLivenessTracker.shared.recordProgress()
                                     }
                                     if Task.isCancelled || inferenceCancellation.isCancelled || shouldCancel() || drainCancelled.isFired {
                                         return GenerateDisposition.stop
                                     }
                                     if HarmonyResponseParser.isHarmonyModelID(request.model),
                                        tokens.last.map(Self.isHarmonyTerminalToken) == true {
                                         return GenerateDisposition.stop
                                     }
-                                    if request.stopsAfterFirstCompleteToolCall,
-                                       !HarmonyResponseParser.isHarmonyModelID(request.model),
-                                       Self.hasEnabledTools(request.promptSource.tools)
+                                    if serialToolStopApplies,
+                                       Self.observeSerialToolStop(
+                                           &serialToolObserver,
+                                           decoded: generationContext.tokenizer.decode(tokenIds: tokens),
+                                           stopTokenFilter: stopTokenFilter,
+                                           requestStops: request.stop
+                                       )
                                     {
-                                        let decoded = generationContext.tokenizer.decode(tokenIds: tokens)
-                                        let candidate = Self.streamingSafePrefix(
-                                            decoded,
-                                            stopTokenFilter: stopTokenFilter,
-                                            requestStops: request.stop
-                                        )
-                                        _ = serialToolObserver.observe(candidate.text)
-                                        if serialToolObserver.hasCompletedValidToolCall {
-                                            return GenerateDisposition.stop
-                                        }
+                                        return GenerateDisposition.stop
                                     }
                                     return GenerateDisposition.more
                                 })
                             }
                             try drainCancelled.check()
                             try Task.checkCancellation()
                             if shouldCancel() {
                                 throw CancellationError()
                             }
                             let resultTokenIDs = result.tokenIds
 
                         guard result.output.utf8.count <= ToolCallParser.SPEC018_ARGUMENTS_PER_RESPONSE_BYTE_CAP else {
                             throw APIError(
                                 status: 502,
                                 message: "Model response exceeded 2097152 bytes",
                                 type: "upstream_provider_error",
                                 code: "response_byte_cap_exceeded",
                                 inferenceRan: true,
                                 settlementRan: true
                             )
                         }
 
                         let filtered = Self.applyOutputFilters(
                             result.output,
                             stopTokenFilter: stopTokenFilter,
                             requestStops: request.stop
                         )
 
                         let rawLengthFinish = request.maxTokens.map { result.generationTokenCount >= $0 } ?? false
                         let harmonyTerminalFinish = Self.isHarmonyTerminalFinish(
                             modelID: request.model,
                             generatedTokenIDs: resultTokenIDs
                         )
                         let parserFinishReason = HarmonyResponseParser.isHarmonyModelID(request.model)
                             ? (rawLengthFinish && !filtered.hitStop && !harmonyTerminalFinish ? "length" : (filtered.hitStop ? "request_stop" : "stop"))
                             : (rawLengthFinish && !filtered.hitStop ? "length" : (filtered.hitStop ? "request_stop" : "stop"))
                         let parsed = try Self.parseGeneratedOutput(
                             filteredText: filtered.text,
                             generatedTokenIDs: resultTokenIDs,
                             decode: { context.tokenizer.decode(tokenIds: $0) },
                             request: request,
                             mode: .complete(finishReason: parserFinishReason),
                             defaultCompletionTokens: result.generationTokenCount,
                             stopTokenFilter: stopTokenFilter,
                             requestStops: request.stop,
                             globalHitStop: filtered.hitStop
                         )
                         let finishReason: String
                         if !parsed.toolCalls.isEmpty {
                             finishReason = "tool_calls"
                         } else if rawLengthFinish, !filtered.hitStop, !parsed.hitStop, !harmonyTerminalFinish {
                             finishReason = "length"
                         } else {
                             finishReason = "stop"
                         }
 
                         let cachedPromptTokens = lease?.cachedPromptTokens ?? 0
                         let kvCacheBytesReused = Self.cachedPromptUTF8Bytes(
                             promptTokenIds: promptTokenIds,
                             cachedPromptTokens: cachedPromptTokens,
                             decode: { context.tokenizer.decode(tokenIds: $0) }
                         )
                         let completion = try Self.validateStructuredCompletion(CompletionResult(
                             content: parsed.content,
                             finishReason: finishReason,
                             promptTokens: promptTokenIds.count,
                             cachedPromptTokens: cachedPromptTokens,
                             kvCacheBytesReused: kvCacheBytesReused,
                             completionTokens: parsed.completionTokens,
                             generatedCompletionTokens: parsed.generatedCompletionTokens,
                             ttftMilliseconds: firstToken.elapsedMilliseconds(since: completionStartedAt),
                             toolCalls: parsed.toolCalls.isEmpty ? nil : parsed.toolCalls,
                             modelHashObserved: Self.validObservedModelHash(snapshot.modelHash),
                             settlementDisposition: .eligibleOwner
                         ), request: request)
                         if let lease {
                             await conversationCache.commit(lease, cache: ConversationCacheLayers(kvCache, recurrentCheckpoints: recurrent.checkpoints), fullTokens: promptTokenIds + resultTokenIDs.map(Int32.init), cold: coldContext)
                         }
                         return completion
                     } catch {
@@ -5225,171 +5386,191 @@ actor ModelRuntime: ModelRuntimeServing {
                         draftedTokens: telemetry?.draftTokenCount ?? 0,
                         acceptedTokens: telemetry?.acceptedDraftTokenCount ?? 0,
                         firstToken: firstToken
                     )
                 }
             }
         } catch let error as DrainCancelledError {
             throw error
         } catch let error as CancellationError {
             throw error
         } catch let error as SpeculativeGenerationFailure {
             throw error
         } catch {
             throw SpeculativeGenerationFailure(reason: "generation_threw")
         }
     }
 
     /// Stop sequences for a batched row: the model's end-of-generation
     /// tokens plus the buyer's `stop` strings. The scheduler stops a row only
     /// on these, so omitting the model EOS set made every batched row run to
     /// `max_tokens` and emit text past the end of the answer, where the serial
     /// path stops on `generationStopTokenIDs`.
     static func continuousBatchStopTokenSequences(
         requestStops: [String],
         context: ModelContext
     ) -> [[Int]] {
         let modelStops = generationStopTokenIDs(for: context).sorted().map { [$0] }
         let buyerStops = requestStops.map {
             context.tokenizer.encode(text: $0, addSpecialTokens: false)
         }.filter { !$0.isEmpty }
         return modelStops + buyerStops
     }
 
     static func droppingTrailingModelStop(
         _ generatedTokens: [Int],
         terminalStatus: ContinuousBatchSchedulerTerminalStatus,
         modelStopTokenIDs: Set<Int>
     ) -> [Int] {
         guard terminalStatus == .stop,
               let last = generatedTokens.last,
               modelStopTokenIDs.contains(last) else {
             return generatedTokens
         }
         return Array(generatedTokens.dropLast())
     }
 
     private static func generationStopTokenIDs(for context: ModelContext) -> Set<Int> {
         var stopTokenIDs = context.configuration.eosTokenIds
         let tokenizer = context.tokenizer
         if let eosTokenID = tokenizer.eosTokenId {
             stopTokenIDs.insert(eosTokenID)
         }
         for token in context.configuration.extraEOSTokens {
             if let tokenID = tokenizer.convertTokenToId(token) {
                 stopTokenIDs.insert(tokenID)
             }
         }
         return stopTokenIDs
     }
 
     func stream(
         _ request: ChatCompletionRequest,
         with handle: RequestHandle,
         shouldCancel: @escaping @Sendable () -> Bool = { false },
         onChunk: @escaping @Sendable (StreamChunk) -> Void
     ) async throws -> CompletionResult {
         // SPEC-025 §5.2 model-liveness: mark active buyer inference so a stalled
         // progress token is interpretable as a wedge (observability only).
         ModelLivenessTracker.shared.beginInference()
         defer { ModelLivenessTracker.shared.endInference() }
         let snapshot = handle.snapshot
         let drainCancelled = handle.drainCancelled
         let continuousBatchingCapability = try applyContinuousBatchingPolicy(
             request: request,
             snapshot: snapshot,
             emitTelemetry: false
         )
         try Self.enforcePagedKVPreflight(pagedKVAttachDecision)
         let structuredAccumulator = StructuredStreamingContentAccumulator(enabled: Self.requiresStructuredValidation(request.responseFormat))
         let idleState = StructuredStreamingIdleState(enabled: Self.requiresStructuredValidation(request.responseFormat))
-        if let completion = try await attachedContinuousBatchStreamingCompletion(
-            request: request,
-            snapshot: snapshot,
-            capability: continuousBatchingCapability,
-            completionStartedAt: Date(),
-            shouldCancel: shouldCancel,
-            drainCancelled: drainCancelled,
-            structuredAccumulator: structuredAccumulator,
-            idleState: idleState,
-            onChunk: onChunk
-        ) {
+        // SPEC-038 AC-6c: a batched structured-output stream runs under the
+        // same SPEC-019 idle timeout as the serial one. It gets its own idle
+        // state because the timeout race marks its state finished, and a
+        // batched attempt that serial-routes (nil) must leave the serial
+        // stream's timeout armed.
+        let batchedIdleState = StructuredStreamingIdleState(enabled: Self.requiresStructuredValidation(request.responseFormat))
+        let batchedCompletionStartedAt = Date()
+        let batchedCompletion = try await Self.withStructuredStreamingIdleTimeout(
+            idleState: batchedIdleState,
+            onIdleTimeout: { () throws -> CompletionResult? in
+                try Self.synthesizeIdleTimeoutResultOrThrow(
+                    accumulator: structuredAccumulator,
+                    request: request,
+                    modelHash: snapshot.modelHash
+                )
+            }
+        ) { idleCancellation in
+            try await self.attachedContinuousBatchStreamingCompletion(
+                request: request,
+                snapshot: snapshot,
+                capability: continuousBatchingCapability,
+                completionStartedAt: batchedCompletionStartedAt,
+                shouldCancel: shouldCancel,
+                drainCancelled: drainCancelled,
+                structuredAccumulator: structuredAccumulator,
+                idleState: batchedIdleState,
+                idleCancellation: idleCancellation,
+                onChunk: onChunk
+            )
+        }
+        if let completion = batchedCompletion {
             return completion
         }
         if speculativeCacheWrapValidated,
            let testSpeculativeStream,
            Self.speculativeRoute(
                for: request,
                draftLoaded: snapshot.hasTargetCompatibleDraft,
                numDraftTokens: snapshot.numDraftTokens
            ) == .speculative {
             let completion = try await Self.withDrainCancellation(drainCancelled) {
                 try await testSpeculativeStream(snapshot, request)
             }.withModelHashObservedIfMissing(Self.validObservedModelHash(snapshot.modelHash))
             if !completion.content.isEmpty {
                 if let error = structuredAccumulator.append(completion.content) {
                     throw error
                 }
                 idleState.noteContent()
                 onChunk(.content(completion.content))
             }
             return try Self.validateStructuredStreamingCompletion(
                 completion,
                 request: request,
                 buyerVisibleContent: structuredAccumulator.content
             )
         }
         if let testCompletion {
             let completion = try await Self.withDrainCancellation(drainCancelled) {
                 try await testCompletion(snapshot, request)
             }.withModelHashObservedIfMissing(Self.validObservedModelHash(snapshot.modelHash))
             if !completion.content.isEmpty {
                 if let error = structuredAccumulator.append(completion.content) {
                     throw error
                 }
                 idleState.noteContent()
                 onChunk(.content(completion.content))
             }
             return try Self.validateStructuredStreamingCompletion(
                 completion,
                 request: request,
                 buyerVisibleContent: structuredAccumulator.content
             )
         }
         guard let container = snapshot.container else {
             throw APIError(status: 503, message: "Model not loaded", type: "server_error", code: "model_not_loaded")
         }
 
         // T2-01: compiled decode env-flag wire-in. When enabled, the
         // decode-bench path uses MLX.compile()-wrapped per-token forwards
         // (see DecodeBenchCommand.runCompiledOnce). Full production stream()
         // wire-in is deferred to a follow-up PR after bench correctness is
         // confirmed via T2-01 artifact. The flag is read here so it appears
         // in inference logs and the serve path is ready to branch on it.
         let compiledDecodeEnabled = CompiledDecode.isEnabledByEnvironment()
         if compiledDecodeEnabled {
             let line = "event=compiled_decode_enabled status=stream_path_deferred flag=\(CompiledDecode.envFlag)\n"
             FileHandle.standardError.write(Data(line.utf8))
         }
 
         let maxContextTokens = maxContextTokens
         let kvBitsOverride = Self.effectiveKVBits(
             configured: kvBitsOverride,
             conversationKey: request.conversationKey
         )
         let speculativeCacheWrapValidated = speculativeCacheWrapValidated
         let prefillStepSize = prefillStepSize
         let conversationCache = conversationCache
         // SPEC-037 stage 5 — per-request cold-tier context (streaming endpoint).
         let coldContext = coldContext(for: request, snapshot: snapshot)
         let inferenceGate = inferenceGate
         let blockingInferenceExecutor = blockingInferenceExecutor
         let stopTokenFilter = stopTokenFilter
         let templateSupportsThinkingToggle = snapshot.templateSupportsThinkingToggle
         return try await Self.withDrainCancellation(drainCancelled) {
             try await Self.withStructuredStreamingIdleTimeout(
                 idleState: idleState,
                 onIdleTimeout: {
                     try Self.synthesizeIdleTimeoutResultOrThrow(
                         accumulator: structuredAccumulator,
                         request: request,
                         modelHash: snapshot.modelHash
@@ -5481,363 +5662,310 @@ actor ModelRuntime: ModelRuntimeServing {
                         let finalDelta = Self.delta(from: emittedText, to: final.text)
                         let parsed = Self.parseToolCallsIfRequested(final.text, request: request)
                         if !finalDelta.isEmpty {
                             if let error = structuredAccumulator.append(finalDelta) {
                                 throw error
                             }
                             idleState.noteContent()
                             emittedText = final.text
                             stoppedByRequestStop = final.hitStop
                             onChunk(.content(finalDelta))
                         }
                         if final.hitStop {
                             stoppedByRequestStop = true
                         }
                         if let error = structuredAccumulator.error {
                             throw error
                         }
 
                         let finishReason: String
                         if !parsed.toolCalls.isEmpty {
                             finishReason = "tool_calls"
                         } else if let maxTokens = request.maxTokens,
                                   generated.generationTokenCount >= maxTokens,
                                   !stoppedByRequestStop,
                                   !final.hitStop {
                             finishReason = "length"
                         } else {
                             finishReason = "stop"
                         }
 
                         let completion = CompletionResult(
                             content: parsed.content,
                             finishReason: finishReason,
                             promptTokens: promptTokenIds.count,
                             cachedPromptTokens: 0,
                             completionTokens: generated.generationTokenCount,
                             generationMilliseconds: generationMS,
                             toolCalls: parsed.toolCalls.isEmpty ? nil : parsed.toolCalls,
                             modelHashObserved: Self.validObservedModelHash(snapshot.modelHash),
                             settlementDisposition: .eligibleOwner,
                             specDecodeDraftedTokens: generated.draftedTokens,
                             specDecodeAcceptedTokens: generated.acceptedTokens,
                             specDecodeGeneration: snapshot.specDecodeGeneration
                         )
                         return try Self.validateStructuredStreamingCompletion(
                             completion,
                             request: request,
                             buyerVisibleContent: structuredAccumulator.content
                         )
                     }
 
                     let lease = await conversationCache.begin(
                         conversationKey: request.conversationKey,
                         incomingTokens: promptTokenIds,
                         modelID: request.model,
                         kvBits: kvBitsOverride,
                         cold: coldContext
                     )
                     let kvCache: [KVCache]
                     var iteratorInput: LMInput
                     if let reusableCache = lease?.reusableCache, let lcp = lease?.lcp {
                         kvCache = reusableCache.layers
                         iteratorInput = LMInput(tokens: MLXArray(Array(promptTokenIds[lcp...])))
                     } else {
                         // SPEC-037 FR-KVP1 / SPEC-024-R001: same KVCacheSimple selector as
                         // the non-streaming path (eligible persist or keyed serial reuse).
                         kvCache = Self.serveCache(
                             model: generationContext.model, baseParameters: parameters,
                             forceSimpleKV: Self.forceSimpleKVCache(
                                 eligible: coldContext?.eligible == true,
                                 conversationKey: request.conversationKey))
                         iteratorInput = lmInput
                     }
                     let recurrent = Self.prefillRecurrentCheckpoints(
                         lease: lease, cache: kvCache, promptTokenIds: promptTokenIds,
                         context: generationContext, prefillStepSize: parameters.prefillStepSize)
                     if let resumeAt = recurrent.resumeAt {
                         iteratorInput = LMInput(tokens: MLXArray(Array(promptTokenIds[resumeAt...])))
                     }
 
-                    var emittedText = ""
                     var stoppedByRequestStop = false
-                    var toolStreamer = NativeToolCallStreamEmitter(
-                        modelID: request.model,
-                        allowedFunctionNames: Self.toolFunctionNames(from: request.promptSource.tools)
-                    )
+                    var textEmitter = SerialStreamingTextEmitter(request: request)
                     var streamingParseError: APIError?
                     var harmonyObservedFinalTokenCount = 0
                     var harmonyObservedTokenCount = 0
 
                     // SPEC-037 FR-KVP2.5: speculative-decode routing is determined
                     // BEFORE conversationCache.begin() (block above, ahead of the
                     // lease acquisition) — a speculative-routed request acquires no
                     // lease, triggers no promotion, commits nothing, and leaves no
                     // busy key. This non-speculative path therefore never re-checks
                     // speculativeRoute; the post-begin speculative block that origin
                     // carried here would double-run and (on its success return) leak
                     // the lease as a stuck busy key, so it is intentionally dropped.
                     let isHarmonyResponse = HarmonyResponseParser.isHarmonyModelID(request.model)
                     var harmonyFinalDetokenizer = NaiveStreamingDetokenizer(tokenizer: context.tokenizer)
                     var harmonyStreamingParser = HarmonyResponseParser.StreamingParser(
                         decode: { context.tokenizer.decode(tokenIds: $0) },
                         decodeFinalToken: { tokenID in
                             harmonyFinalDetokenizer.append(token: tokenID)
                             return harmonyFinalDetokenizer.next()
                         },
                         allowedFunctionNames: Self.toolFunctionNames(from: request.promptSource.tools),
                         stopCandidates: stopTokenFilter.tokens + request.stop
                     )
-                    let streamToolsIncrementally = Self.hasEnabledTools(request.promptSource.tools) && !isHarmonyResponse
                     let iterator = try TokenIterator(input: iteratorInput, model: generationContext.model, cache: kvCache, parameters: parameters)
                     do {
                         let result: BlockingGenerateResult = try await blockingInferenceExecutor.run { inferenceCancellation in
                             BlockingGenerateResult(generate(input: iteratorInput, context: generationContext, iterator: iterator) { tokens in
                                 EgressPerfTraceKey.current?.recordDecodeCallbackEntry()
                                 // Round-2 code LOW: only start the decode timer
                                 // on a callback that actually carries a token.
                                 // An empty first callback would otherwise start
                                 // the clock during prefill and inflate the
                                 // measured decode window. Mirrors the
                                 // `if !tokens.isEmpty { firstToken.recordIfMissing() }`
                                 // guards elsewhere in this file.
                                 if !tokens.isEmpty {
                                     decodeTimer.recordIfMissing()
                                     ModelLivenessTracker.shared.recordProgress()
                                 }
                                 if Task.isCancelled || inferenceCancellation.isCancelled || shouldCancel() || drainCancelled.isFired || idleCancellation.isFired {
                                     return .stop
                                 }
                                 if isHarmonyResponse {
                                     do {
                                         guard tokens.count >= harmonyObservedTokenCount else {
                                             streamingParseError = Self.malformedHarmonyResponseError()
                                             return .stop
                                         }
                                         let newTokenIDs = Array(tokens.dropFirst(harmonyObservedTokenCount))
                                         harmonyObservedTokenCount = tokens.count
                                         let parsed = harmonyStreamingParser.parse(newTokenIDs: newTokenIDs)
                                         if parsed.finalContentTokenCount > harmonyObservedFinalTokenCount {
                                             harmonyObservedFinalTokenCount = parsed.finalContentTokenCount
                                             idleState.noteContent()
                                         }
                                         let output = try Self.harmonyParsedOutput(
                                             from: parsed,
                                             decode: { context.tokenizer.decode(tokenIds: $0) },
                                             stopTokenFilter: stopTokenFilter,
                                             requestStops: request.stop,
                                             countCompletionTokens: false
                                         )
                                         if output.hitStop {
                                             stoppedByRequestStop = true
                                             return .stop
                                         }
                                         if tokens.last.map(Self.isHarmonyTerminalToken) == true {
                                             return .stop
                                         }
                                         return .more
                                     } catch let error as APIError {
                                         streamingParseError = error
                                         return .stop
                                     } catch {
                                         streamingParseError = Self.malformedHarmonyResponseError()
                                         return .stop
                                     }
                                 }
                                 let decoded = context.tokenizer.decode(tokenIds: tokens)
                                 let candidate = Self.streamingSafePrefix(
                                     decoded,
                                     stopTokenFilter: stopTokenFilter,
                                     requestStops: request.stop
                                 )
-                                    if streamToolsIncrementally {
-                                        for event in toolStreamer.observe(candidate.text) {
-                                        onChunk(event)
-                                    }
-                                    if !toolStreamer.suppressesAssistantContent {
-                                        let safe = toolStreamer.visibleContentPrefix(of: candidate.text)
-                                        let delta = Self.delta(from: emittedText, to: safe)
-                                        if !delta.isEmpty {
-                                            if structuredAccumulator.append(delta) != nil {
-                                                return .stop
-                                            }
-                                            idleState.noteContent()
-                                            emittedText = safe
-                                            onChunk(.content(delta))
-                                        }
-                                    }
-                                    if request.stopsAfterFirstCompleteToolCall, toolStreamer.hasCompletedValidToolCall {
-                                        return .stop
-                                    }
-                                    if candidate.hitStop {
-                                        stoppedByRequestStop = true
-                                        return .stop
-                                    }
+                                switch textEmitter.step(
+                                    candidate: candidate,
+                                    structuredAccumulator: structuredAccumulator,
+                                    idleState: idleState,
+                                    onChunk: onChunk
+                                ) {
+                                case .more:
                                     return .more
-                                }
-
-                                let delta = Self.delta(from: emittedText, to: candidate.text)
-                                if !delta.isEmpty {
-                                    if structuredAccumulator.append(delta) != nil {
-                                        return .stop
-                                    }
-                                    idleState.noteContent()
-                                    emittedText = candidate.text
-                                    onChunk(.content(delta))
-                                }
-
-                                if candidate.hitStop {
+                                case .requestStop:
                                     stoppedByRequestStop = true
                                     return .stop
+                                case .toolCallComplete, .structuredError:
+                                    return .stop
                                 }
-                                return .more
                             })
                         }
                         // Warm-decode wall-time: from the first decoded token
                         // (any channel) to the generate result. Reported to the
                         // client as `macprovider_generation_ms` so the autotune
                         // probe can divide total decoded tokens by this window
                         // even when the reasoning channel is silent in SSE.
                         let decodeEndedAt = Date()
                         let generationMS = decodeTimer.durationMilliseconds(until: decodeEndedAt)
                         try drainCancelled.check()
                         try Task.checkCancellation()
                         if shouldCancel() {
                             throw CancellationError()
                         }
                         if let streamingParseError {
                             throw streamingParseError
                         }
                         let resultTokenIDs = result.tokenIds
 
                         let final = Self.applyOutputFilters(
                             result.output,
                             stopTokenFilter: stopTokenFilter,
                             requestStops: request.stop
                         )
                         let rawLengthFinish = request.maxTokens.map { result.generationTokenCount >= $0 } ?? false
                         let harmonyTerminalFinish = Self.isHarmonyTerminalFinish(
                             modelID: request.model,
                             generatedTokenIDs: resultTokenIDs
                         )
                         let parserFinishReason = isHarmonyResponse
                             ? (rawLengthFinish && !stoppedByRequestStop && !harmonyTerminalFinish ? "length" : (stoppedByRequestStop ? "request_stop" : "stop"))
                             : (rawLengthFinish && !final.hitStop && !stoppedByRequestStop ? "length" : ((final.hitStop || stoppedByRequestStop) ? "request_stop" : "stop"))
                         let parsed = try Self.parseGeneratedOutput(
                             filteredText: final.text,
                             generatedTokenIDs: resultTokenIDs,
                             decode: { context.tokenizer.decode(tokenIds: $0) },
                             request: request,
                             mode: .complete(finishReason: parserFinishReason),
                             defaultCompletionTokens: result.generationTokenCount,
                             stopTokenFilter: stopTokenFilter,
                             requestStops: request.stop,
                             globalHitStop: final.hitStop || stoppedByRequestStop
                         )
-                        let finalDelta = Self.delta(from: emittedText, to: parsed.content)
-                        if streamToolsIncrementally {
-                            for event in toolStreamer.observe(final.text) {
-                                onChunk(event)
-                            }
-                            if parsed.toolCalls.isEmpty,
-                               !parsed.content.isEmpty,
-                               !toolStreamer.suppressesAssistantContent
-                            {
-                                let contentDelta = Self.delta(from: emittedText, to: parsed.content)
-                                if !contentDelta.isEmpty {
-                                    if let error = structuredAccumulator.append(contentDelta) {
-                                        throw error
-                                    }
-                                    idleState.noteContent()
-                                    onChunk(.content(contentDelta))
-                                }
-                            }
-                        } else if !finalDelta.isEmpty {
-                            if let error = structuredAccumulator.append(finalDelta) {
-                                throw error
-                            }
-                            idleState.noteContent()
-                            onChunk(.content(finalDelta))
-                        }
-                        if let error = structuredAccumulator.error {
-                            throw error
-                        }
+                        try textEmitter.finish(
+                            finalText: final.text,
+                            parsed: parsed,
+                            structuredAccumulator: structuredAccumulator,
+                            idleState: idleState,
+                            onChunk: onChunk
+                        )
 
                         let finishReason: String
                         if !parsed.toolCalls.isEmpty {
                             finishReason = "tool_calls"
                         } else if let maxTokens = request.maxTokens,
                            result.generationTokenCount >= maxTokens,
                            !stoppedByRequestStop,
                            !final.hitStop,
                            !parsed.hitStop,
                            !harmonyTerminalFinish
                         {
                             finishReason = "length"
                         } else {
                             finishReason = "stop"
                         }
 
                         let cachedPromptTokens = lease?.cachedPromptTokens ?? 0
                         let kvCacheBytesReused = Self.cachedPromptUTF8Bytes(
                             promptTokenIds: promptTokenIds,
                             cachedPromptTokens: cachedPromptTokens,
                             decode: { context.tokenizer.decode(tokenIds: $0) }
                         )
                         let completion = CompletionResult(
                             content: parsed.content,
                             finishReason: finishReason,
                             promptTokens: promptTokenIds.count,
                             cachedPromptTokens: cachedPromptTokens,
                             kvCacheBytesReused: kvCacheBytesReused,
                             completionTokens: parsed.completionTokens,
                             generatedCompletionTokens: parsed.generatedCompletionTokens,
                             generationMilliseconds: generationMS,
                             toolCalls: parsed.toolCalls.isEmpty ? nil : parsed.toolCalls,
                             modelHashObserved: Self.validObservedModelHash(snapshot.modelHash),
                             settlementDisposition: .eligibleOwner
                         )
                         let validated = try Self.validateStructuredStreamingCompletion(
                             completion,
                             request: request,
                             buyerVisibleContent: structuredAccumulator.content
                         )
                         if let lease {
                             await conversationCache.commit(lease, cache: ConversationCacheLayers(kvCache, recurrentCheckpoints: recurrent.checkpoints), fullTokens: promptTokenIds + resultTokenIDs.map(Int32.init), cold: coldContext)
                         }
                         return validated
                     } catch {
                         if let lease {
                             await conversationCache.abort(lease)
                         }
                         throw error
                     }
                 }
             }
             }
         }
     }
 
     /// SPEC-037 stage 5 (FR-KVP7) — attach the activated disk cold tier. Called by
     /// the serve lifecycle after the store acquires its namespace lock, so the hot
     /// tier only reaches disk once single-writer ownership is established.
     func attachKVDiskTier(_ tier: KVDiskTier) async {
         let adapter = KVConversationColdTierAdapter(
             store: tier.store, namespaceID: tier.namespaceID,
             eligibilityTTLSeconds: tier.eligibilityTTLSeconds,
             writeStagingMaxBytes: tier.config.writeStagingMaxBytes,
             maxEntryBytes: tier.config.maxEntryBytes,
             stagingMaxBytes: tier.config.stagingMaxBytes)
         await conversationCache.attachColdTier(adapter)
         // CRITICAL-2: keep the adapter's cached epoch in step with the store so
         // captureSnapshot stamps the epoch at commit time. Seeds immediately.
         await tier.store.setEpochObserver { [weak adapter] epoch in adapter?.cacheEpoch(epoch) }
         // CRITICAL-1: wire the store's purge path back to the hot tier so a purge /
         // purge-all drops the matching RAM entry and fences outstanding leases
         // before the on-disk generation is unlinked / the epoch is rotated.
         let cache = conversationCache
         await tier.store.setHotPurgeHooks(
             single: { key in await cache.purgeHot(conversationKey: key) },
             all: { await cache.purgeAllHot() })
         // HIGH-5: drain queued cold writes on graceful shutdown before lock release.
         tier.setDrainHook { seconds in await cache.drainColdWrites(timeoutSeconds: seconds) }
         // HIGH-1 (SPEC-037 KVS-01a): seed the adapter's live-model geometry template
@@ -6543,245 +6671,245 @@ actor ModelRuntime: ModelRuntimeServing {
                 "tokenizer_config.json",
                 "special_tokens_map.json",
                 "tokenizer.model",
                 "vocab.json",
                 "merges.txt",
                 "added_tokens.json",
             ]
         let files = try tokenizerArtifactNames.compactMap { name -> TokenizerArtifactManifestFile? in
             let url = directory.appendingPathComponent(name)
             var isDirectory = ObjCBool(false)
             guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                   !isDirectory.boolValue
             else {
                 return nil
             }
             let contentURL = url.resolvingSymlinksInPath()
             let data = try tokenizerArtifactFingerprintData(for: contentURL, name: name)
             return TokenizerArtifactManifestFile(
                 name: name,
                 sha256: hexString(SHA256.hash(data: data)),
                 size: UInt64(data.count)
             )
         }
 
         guard !files.isEmpty else { return nil }
 
         let manifest = TokenizerArtifactManifest(files: files)
         let encoder = JSONEncoder()
         encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
         let data = try encoder.encode(manifest)
         return hexString(SHA256.hash(data: data))
     }
 
     private static func tokenizerArtifactFingerprintData(for url: URL, name: String) throws -> Data {
         let data = try Data(contentsOf: url)
         guard name == "tokenizer_config.json",
               var root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
         else {
             return data
         }
         // Chat-template default prompt text can differ across same-vocabulary
         // draft/target repos. Runtime token probes plus the equivalence canary
         // remain the authority for whether such a pair is actually compatible.
         root.removeValue(forKey: "chat_template")
         return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])
     }
 
     private static func sha256Hex(ofFileAt url: URL) throws -> String {
         let handle = try FileHandle(forReadingFrom: url)
         defer { try? handle.close() }
 
         var hasher = SHA256()
         while true {
             let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
             guard !chunk.isEmpty else { break }
             hasher.update(data: chunk)
         }
         return hexString(hasher.finalize())
     }
 
     private static func hexString<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
         bytes.map { String(format: "%02x", $0) }.joined()
     }
 
     static func validObservedModelHash(_ hash: String?) -> String? {
         guard let hash, hash.utf8.count == 64 else {
             if let hash, !hash.isEmpty {
                 FileHandle.standardError.write(Data("AC-46: validObservedModelHash rejected malformed value: \(hash.prefix(16))...\n".utf8))
             }
             return nil
         }
         guard hash.utf8.allSatisfy({ byte in
             (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
         }) else {
             FileHandle.standardError.write(Data("AC-46: validObservedModelHash rejected non-hex value: \(hash.prefix(16))...\n".utf8))
             return nil
         }
         return hash
     }
 
-    private static func applyOutputFilters(
+    static func applyOutputFilters(
         _ text: String,
         stopTokenFilter: StopTokenFilter,
         requestStops: [String]
     ) -> (text: String, hitStop: Bool) {
         let stripped = stopTokenFilter.stripping(from: text)
         var earliestStop: String.Index?
         for stop in requestStops where !stop.isEmpty {
             if let range = stripped.range(of: stop) {
                 if earliestStop == nil || range.lowerBound < earliestStop! {
                     earliestStop = range.lowerBound
                 }
             }
         }
         if let earliestStop {
             return (String(stripped[..<earliestStop]), true)
         }
         return (stripped, false)
     }
 
     /// SPEC-024 FR-CI2 hybrid reuse. For a keyed serial request on a model with
     /// recurrent layers, prefill `cache` from the tokens it already holds up to each
     /// recurrent checkpoint position (`ConversationCache.recurrentCheckpointPositions`)
     /// and snapshot the recurrent states there. Checkpoint positions the restored
     /// cache is already past reuse the stored checkpoint at that exact length (still
     /// a prefix of this prompt). `resumeAt` is the prompt index the TokenIterator
     /// must continue from, or nil when nothing was prefilled here.
     static func prefillRecurrentCheckpoints(
         lease: ConversationCacheLease?,
         cache: [KVCache],
         promptTokenIds: [Int32],
         context: ModelContext,
         prefillStepSize: Int
     ) -> (checkpoints: [RecurrentStateCheckpoint], resumeAt: Int?) {
         guard let lease else { return ([], nil) }
         let positions = ConversationCache.recurrentCheckpointPositions(
             promptTokenIds: promptTokenIds,
             imStartTokenID: context.tokenizer.convertTokenToId("<|im_start|>").map(Int32.init),
             hybrid: ConversationCacheLayers.hasRecurrentLayers(cache),
             decode: { context.tokenizer.decode(tokenIds: $0) })
         guard !positions.isEmpty else { return ([], nil) }
         let cachedTokens = lease.reusableCache == nil ? 0 : lease.lcp
         let reusable = lease.reusableCache?.recurrentCheckpoints ?? []
         var cursor = cachedTokens
         var checkpoints: [RecurrentStateCheckpoint] = []
         for position in positions {
             if position < cursor {
                 if let stored = reusable.first(where: { $0.tokenCount == position }) {
                     checkpoints.append(stored)
                 }
                 continue
             }
             var start = cursor
             while start < position {
                 let end = min(start + max(1, prefillStepSize), position)
                 let chunk = LMInput.Text(tokens: MLXArray(Array(promptTokenIds[start..<end])))
                 _ = context.model(chunk[text: .newAxis], cache: cache, state: nil)
                 asyncEval(cache)
                 start = end
             }
             eval(cache)
             cursor = position
             var states: [Int: [MLXArray]] = [:]
             for (index, layer) in cache.enumerated() where layer is ArraysCache {
                 let state = layer.state
                 guard !state.isEmpty else { return (checkpoints, cursor > cachedTokens ? cursor : nil) }
                 states[index] = state
             }
             checkpoints.append(RecurrentStateCheckpoint(tokenCount: position, states: states))
         }
         return (checkpoints, cursor > cachedTokens ? cursor : nil)
     }
 
     static func cachedPromptUTF8Bytes(
         promptTokenIds: [Int32],
         cachedPromptTokens: Int,
         decode: ([Int]) -> String
     ) -> Int {
         let clamped = max(0, min(cachedPromptTokens, promptTokenIds.count))
         guard clamped > 0 else { return 0 }
         let prefixTokens = promptTokenIds.prefix(clamped).map(Int.init)
         return decode(Array(prefixTokens)).utf8.count
     }
 
-    private static func streamingSafePrefix(
+    static func streamingSafePrefix(
         _ text: String,
         stopTokenFilter: StopTokenFilter,
         requestStops: [String]
     ) -> (text: String, hitStop: Bool) {
         let filtered = applyOutputFilters(
             text,
             stopTokenFilter: stopTokenFilter,
             requestStops: requestStops
         )
         guard !filtered.hitStop else {
             return filtered
         }
 
         let candidates = stopTokenFilter.tokens + requestStops.filter { !$0.isEmpty }
         let holdback = longestSuffixPrefixLength(in: filtered.text, candidates: candidates)
         let safe = holdback > 0 ? String(filtered.text.dropLast(holdback)) : filtered.text
         return (withoutIncompleteUTF8Tail(safe), false)
     }
 
     /// #1690 E2E-F13: a decode of a token prefix that ends inside a
     /// multi-byte UTF-8 character renders the partial bytes as trailing
     /// U+FFFD, which the next token replaces with the real character. Such a
     /// tail is never streamed; the final decode flushes it as it renders.
     static func withoutIncompleteUTF8Tail(_ text: String) -> String {
         var scalars = text.unicodeScalars
         while scalars.last == "\u{FFFD}" {
             scalars.removeLast()
         }
         return String(scalars)
     }
 
     /// The text to append so the streamed bytes become `current`: exact on
     /// Unicode scalars, not Characters, so a combining mark or a completed
     /// grapheme cluster never makes `emitted` look like a non-prefix or a
     /// dropped Character eat scalars. Empty when `current` does not extend
     /// `emitted` (never a lossy or out-of-order fragment).
     static func streamDelta(from emitted: String, to current: String) -> String {
         let emittedScalars = emitted.unicodeScalars
         let currentScalars = current.unicodeScalars
         guard currentScalars.starts(with: emittedScalars) else { return "" }
         var appended = String.UnicodeScalarView()
         appended.append(contentsOf: currentScalars.dropFirst(emittedScalars.count))
         return String(appended)
     }
 
     private static func longestSuffixPrefixLength(in text: String, candidates: [String]) -> Int {
         guard !text.isEmpty, !candidates.isEmpty else { return 0 }
         let maxLength = min(text.count, candidates.map(\.count).max() ?? 0)
         guard maxLength > 0 else { return 0 }
 
         var longest = 0
         for length in 1 ... maxLength {
             let suffix = String(text.suffix(length))
             if candidates.contains(where: { $0.hasPrefix(suffix) }) {
                 longest = length
             }
         }
         return longest
     }
 
     private static func delta(from emitted: String, to current: String) -> String {
         streamDelta(from: emitted, to: current)
     }
 
     struct ParsedGeneratedOutput: Sendable {
         let content: String
         let toolCalls: [ToolCall]
         let completionTokens: Int
         let generatedCompletionTokens: Int
         let hitStop: Bool
         let isTerminal: Bool
     }
 
     static func parseGeneratedOutput(
         filteredText: String,
         generatedTokenIDs: [Int],
         decode: ([Int]) -> String,
         request: ChatCompletionRequest,
         mode: HarmonyResponseParser.Mode,
         defaultCompletionTokens: Int,
@@ -6836,227 +6964,254 @@ actor ModelRuntime: ModelRuntimeServing {
             stopTokenFilter: stopTokenFilter,
             requestStops: requestStops
         )
         guard !globalHitStop || filteredVisible.hitStop else {
             throw malformedHarmonyResponseError()
         }
         let toolCalls = filteredVisible.hitStop ? [] : parsed.toolCalls
         let hasToolCalls = !toolCalls.isEmpty
         let visibleContent = hasToolCalls ? "" : filteredVisible.text
         return ParsedGeneratedOutput(
             content: visibleContent,
             toolCalls: toolCalls,
             completionTokens: countCompletionTokens ? harmonyVisibleFinalTokenCount(
                 tokenIDs: parsed.finalContentTokenIDs,
                 parsedContent: parsed.content ?? "",
                 visibleText: visibleContent,
                 decode: decode
             ) : 0,
             generatedCompletionTokens: generatedCompletionTokens,
             hitStop: filteredVisible.hitStop,
             isTerminal: parsed.status == .parsed
         )
     }
 
     private static func harmonyVisibleFinalTokenCount(
         tokenIDs: [Int],
         parsedContent: String,
         visibleText: String,
         decode: ([Int]) -> String
     ) -> Int {
         guard !visibleText.isEmpty, !tokenIDs.isEmpty else { return 0 }
         guard visibleText != parsedContent else { return tokenIDs.count }
         for count in 1 ... tokenIDs.count {
             let prefix = decode(Array(tokenIDs.prefix(count)))
             if prefix == visibleText || prefix.hasPrefix(visibleText) {
                 return count
             }
             if !visibleText.hasPrefix(prefix) {
                 return max(0, count - 1)
             }
         }
         return tokenIDs.count
     }
 
     static func malformedHarmonyResponseError() -> APIError {
         APIError(
             status: 502,
             message: "Malformed Harmony tool-call response",
             type: "upstream_provider_error",
             code: "malformed_tool_call_final_json",
             inferenceRan: true,
             settlementRan: true
         )
     }
 
     static func harmonyResponseError(for failure: HarmonyResponseParser.Failure?) -> APIError {
         switch failure {
         case .perCallByteCapExceeded:
             return APIError(
                 status: 502,
                 message: "Tool call arguments exceeded 1048576 bytes",
                 type: "upstream_provider_error",
                 code: "byte_cap_exceeded",
                 inferenceRan: true,
                 settlementRan: true
             )
         case .responseByteCapExceeded:
             return APIError(
                 status: 502,
                 message: "Tool call arguments exceeded 2097152 bytes",
                 type: "upstream_provider_error",
                 code: "response_byte_cap_exceeded",
                 inferenceRan: true,
                 settlementRan: true
             )
         case .malformed, .none:
             return malformedHarmonyResponseError()
         }
     }
 
+    /// SPEC-018 serial tool turn (`parallel_tool_calls` omitted/false) on a
+    /// non-Harmony model with tools: generation stops once the first tool
+    /// call is complete and valid.
+    static func serialToolStopApplies(_ request: ChatCompletionRequest) -> Bool {
+        request.stopsAfterFirstCompleteToolCall
+            && !HarmonyResponseParser.isHarmonyModelID(request.model)
+            && hasEnabledTools(request.promptSource.tools)
+    }
+
+    /// One serial-tool-turn stop test over the decode of every token so far.
+    /// The serial non-streaming path and the continuous-batching rows
+    /// (SPEC-038 AC-6c) share it, so both stop at the same token.
+    static func observeSerialToolStop(
+        _ observer: inout NativeToolCallStreamEmitter,
+        decoded: String,
+        stopTokenFilter: StopTokenFilter,
+        requestStops: [String]
+    ) -> Bool {
+        let candidate = streamingSafePrefix(
+            decoded,
+            stopTokenFilter: stopTokenFilter,
+            requestStops: requestStops
+        )
+        _ = observer.observe(candidate.text)
+        return observer.hasCompletedValidToolCall
+    }
+
     private static func parseToolCallsIfRequested(_ text: String, request: ChatCompletionRequest) -> (content: String, toolCalls: [ToolCall]) {
         guard let allowedFunctionNames = toolFunctionNames(from: request.promptSource.tools) else {
             return (text, [])
         }
         let parsed = ToolCallParser.parseToolCalls(
             rawOutput: text,
             modelID: request.model,
             allowedFunctionNames: allowedFunctionNames
         )
         guard !parsed.toolCalls.isEmpty else {
             return (text, [])
         }
         if request.stopsAfterFirstCompleteToolCall, parsed.toolCalls.count > 1 {
             return ("", Array(parsed.toolCalls.prefix(1)))
         }
         return ("", parsed.toolCalls)
     }
 
-    private static func requiresStructuredValidation(_ responseFormat: ResponseFormat) -> Bool {
+    static func requiresStructuredValidation(_ responseFormat: ResponseFormat) -> Bool {
         switch responseFormat {
         case .text:
             return false
         case .jsonObject, .jsonSchema:
             return true
         }
     }
 
     static func templateAdditionalContext(supportsThinkingToggle: Bool) -> [String: any Sendable]? {
         guard supportsThinkingToggle else { return nil }
         return ["enable_thinking": false]
     }
 
     static func userInput(
         for request: ChatCompletionRequest,
         templateSupportsThinkingToggle: Bool = false
     ) throws -> UserInput {
         let structuredMessages = try StructuredOutputRenderer.prependResponseFormatInstruction(
             to: request.messages,
             responseFormat: request.responseFormat,
             modelID: request.model
         )
         return UserInput(
             chat: try ToolPromptRenderer.renderMessages(structuredMessages, modelID: request.model),
             tools: Self.mlxToolsForTemplate(from: request.promptSource.tools),
             additionalContext: Self.templateAdditionalContext(
                 supportsThinkingToggle: templateSupportsThinkingToggle
             )
         )
     }
 
     private static func internalWarmupRequest(modelID: String?, prompt: String, maxTokens: Int) throws -> ChatCompletionRequest {
         let body: [String: Any] = [
             "model": modelID ?? "internal-warmup",
             "messages": [
                 [
                     "role": "user",
                     "content": prompt,
                 ],
             ],
             "max_tokens": maxTokens,
             "temperature": 0,
             "top_p": 1,
         ]
         return try ChatCompletionRequest.parse(data: try JSONSerialization.data(withJSONObject: body))
     }
 
-    private static func validateStructuredCompletion(_ completion: CompletionResult, request: ChatCompletionRequest) throws -> CompletionResult {
+    static func validateStructuredCompletion(_ completion: CompletionResult, request: ChatCompletionRequest) throws -> CompletionResult {
         if completion.toolCalls?.isEmpty == false {
             return completion
         }
         switch request.responseFormat {
         case .text:
             return completion
         case .jsonObject:
             _ = try parseStructuredJSONContent(completion.content, requireObjectOrArray: true)
             return completion
         case .jsonSchema(let spec):
             let parsed = try parseStructuredJSONContent(completion.content, requireObjectOrArray: false)
             do {
                 try JSONSchemaValidator.validateInstance(parsed, against: spec.schema)
             } catch let error as APIError {
                 throw error
             } catch {
                 throw APIError(
                     status: 502,
                     message: "Schema validation aborted before completion",
                     type: "upstream_provider_error",
                     code: "json_schema_validation_failed",
                     param: "",
                     inferenceRan: true,
                     settlementRan: true
                 )
             }
             return completion
         }
     }
 
     static func validateStructuredStreamingCompletion(
         _ completion: CompletionResult,
         request: ChatCompletionRequest,
         buyerVisibleContent: String
     ) throws -> CompletionResult {
         guard requiresStructuredValidation(request.responseFormat), completion.toolCalls?.isEmpty != false else {
             return completion
         }
         let visibleCompletion = CompletionResult(
             content: buyerVisibleContent,
             finishReason: completion.finishReason,
             promptTokens: completion.promptTokens,
             cachedPromptTokens: completion.cachedPromptTokens,
             kvCacheBytesReused: completion.kvCacheBytesReused,
             completionTokens: completion.completionTokens,
             generatedCompletionTokens: completion.generatedCompletionTokens,
             ttftMilliseconds: completion.ttftMilliseconds,
             // Architect LOW: forward the decode-window so the structured
             // streaming path's usage carries `macprovider_generation_ms`
             // instead of null, matching the non-structured path.
             generationMilliseconds: completion.generationMilliseconds,
             toolCalls: completion.toolCalls,
             modelHashObserved: completion.modelHashObserved,
             settlementDisposition: completion.settlementDisposition,
             specDecodeDraftedTokens: completion.specDecodeDraftedTokens,
             specDecodeAcceptedTokens: completion.specDecodeAcceptedTokens,
             specDecodeGeneration: completion.specDecodeGeneration
         )
         return try validateStructuredCompletion(visibleCompletion, request: request)
     }
 
     static func synthesizeIdleTimeoutResultOrThrow(
         accumulator: StructuredStreamingContentAccumulator,
         request: ChatCompletionRequest,
         modelHash: String?
     ) throws -> CompletionResult {
         let content = accumulator.content
         let synthetic = CompletionResult(
             content: content,
             finishReason: "stop",
             promptTokens: 0,
             completionTokens: 0,
             ttftMilliseconds: 0,
             toolCalls: nil,
             modelHashObserved: validObservedModelHash(modelHash),
             settlementDisposition: .eligibleOwner
         )
         do {
             return try validateStructuredStreamingCompletion(
                 synthetic,
@@ -7193,244 +7348,359 @@ actor ModelRuntime: ModelRuntimeServing {
                 settlementRan: true
             )
         }
         let parsed: MacProviderCore.JSONValue
         do {
             parsed = try StrictJSONParser.parse(content)
         } catch let error as APIError {
             throw error
         } catch {
             throw APIError(
                 status: 502,
                 message: "Model output was not valid JSON for the requested response_format. If you intended free-form prose, send response_format: {\"type\":\"text\"} or omit the field. Per SPEC-019 v0.1.0, json_object now enforces top-level JSON; this is a breaking change from earlier versions where json_object was a silent no-op.",
                 type: "upstream_provider_error",
                 code: "malformed_json_response",
                 param: "",
                 inferenceRan: true,
                 settlementRan: true
             )
         }
         if requireObjectOrArray {
             do {
                 try JSONSchemaValidator.validateJSONObjectOrArray(parsed)
             } catch let error as APIError where error.code == "malformed_json_response" {
                 throw error
             } catch let error as APIError where error.code == "json_schema_validation_failed" {
                 throw APIError(
                     status: 502,
                     message: "Model output JSON exceeds the structured-output depth limit",
                     type: "upstream_provider_error",
                     code: "json_schema_validation_failed",
                     param: error.param ?? "",
                     inferenceRan: true,
                     settlementRan: true
                 )
             }
         }
         return parsed
     }
 
     private static func isASCIIStructuredOutputWhitespace(_ character: Character) -> Bool {
         character == " " || character == "\t" || character == "\n" || character == "\r"
     }
 
     static func mlxToolsForTemplate(from value: MacProviderCore.JSONValue?) -> [[String: Any]]? {
         guard let value, case .array(let tools) = value, !tools.isEmpty else {
             return nil
         }
         let converted = tools.compactMap { tool -> [String: Any]? in
             guard case .object(let object) = tool,
                   case .object(let functionObject)? = object["function"],
                   case .string(let name)? = functionObject["name"],
                   let parameters = functionObject["parameters"]
             else {
                 return nil
             }
             // Chat-template engines (swift-jinja via Tokenizers) reject
             // Foundation `NSNull` (issue #718). Represent every JSON null as a
             // native `Jinja.Value.null`, which `Value(any:)` passes through
             // unchanged, so the rendered schema keeps its keys and array
             // positions instead of silently dropping `enum:[null,…]`,
             // `const:null`, or positional defaults.
             // `description` is part of the receipt canonical tool subset, where
             // an absent key and an explicit `null` both canonicalize to JCS null
             // (PromptCanonicalizer.canonicalTool via jcsOrNull) — i.e. they share
             // one signed prompt hash. Render both as a native Jinja null so the
             // template the model actually sees cannot diverge from that hash.
             let description = functionObject["description"].map { jsonAnyForTemplate($0) } ?? Jinja.Value.null
             let function: [String: Any] = [
                 "name": name,
                 "description": description,
                 "parameters": jsonAnyForTemplate(parameters),
             ]
             return [
                 "type": "function",
                 "function": function,
             ]
         }
         return converted.isEmpty ? nil : converted
     }
 
-    private static func hasEnabledTools(_ value: MacProviderCore.JSONValue?) -> Bool {
+    static func hasEnabledTools(_ value: MacProviderCore.JSONValue?) -> Bool {
         toolFunctionNames(from: value) != nil
     }
 
-    private static func toolFunctionNames(from value: MacProviderCore.JSONValue?) -> Set<String>? {
+    static func toolFunctionNames(from value: MacProviderCore.JSONValue?) -> Set<String>? {
         guard let value, case .array(let tools) = value, !tools.isEmpty else {
             return nil
         }
         let names = tools.compactMap { tool -> String? in
             guard case .object(let toolObject) = tool,
                   case .object(let functionObject)? = toolObject["function"],
                   case .string(let name)? = functionObject["name"],
                   !name.isEmpty
             else {
                 return nil
             }
             return name
         }
         return names.isEmpty ? nil : Set(names)
     }
 
     /// Converts a JSONValue subtree into the `Any` graph the chat template
     /// consumes, preserving every key and array position. JSON null becomes a
     /// native `Jinja.Value.null` (not `NSNull` and not an omission): swift-jinja
     /// `Value(any:)` matches `case let value as Value` and passes it through,
     /// so `default:null`, `const:null`, `enum:[null,…]`, and positional array
     /// nulls survive round-trip with their original schema semantics (#718/#719).
     ///
     /// Recursion is bounded by the caller, not here: tool schemas are rejected
     /// at `validateTools` (ChatCompletionRequest) when they exceed
     /// `JSONSchemaValidator.maxDepth`, before `JSONValue.parse` builds the tree
     /// this walk consumes. So every value reaching here is already depth-capped,
     /// and the converter can stay a faithful shape-preserving pass with no
     /// silent truncation of over-deep subtrees.
     private static func jsonAnyForTemplate(_ value: MacProviderCore.JSONValue) -> Any {
         switch value {
         case .object(let object):
             var result: [String: Any] = [:]
             result.reserveCapacity(object.count)
             for (key, member) in object {
                 result[key] = jsonAnyForTemplate(member)
             }
             return result
         case .array(let array):
             return array.map { jsonAnyForTemplate($0) }
         case .string(let string):
             return string
         case .int(let int):
             return int
         case .double(let double):
             return double
         case .bool(let bool):
             return bool
         case .null:
             return Jinja.Value.null
         }
     }
 
     private static func validateToolChoiceScope(_ request: ChatCompletionRequest) throws {
         if let toolChoice = request.promptSource.toolChoice,
            !isSupportedToolChoice(toolChoice)
         {
             throw APIError(
                 status: 400,
                 message: "tool_choice values other than auto are not supported by this provider",
                 code: "unsupported_tool_choice"
             )
         }
     }
 
     private static func isSupportedToolChoice(_ value: MacProviderCore.JSONValue) -> Bool {
         switch value {
         case .string(let choice):
             // OpenAI/Pi send "required". We do not force a call, but rejecting it
             // with 400/502 is worse than treating it as auto.
             return choice == "auto" || choice == "required"
         case .null:
             return true
         default:
             return false
         }
     }
 }
 
+/// The serial streaming path's buyer-visible text step for non-Harmony output:
+/// incremental tool-call deltas (SPEC-018), assistant-content suppression once
+/// a tool call opens, the SPEC-019 structured-content accumulator, and the
+/// serial-tool-turn stop. The serial `stream` path and the continuous-batching
+/// stream sink (SPEC-038 AC-6c) both drive this one type, so a batched
+/// tool-bearing or structured-output row emits the serial SSE sequence.
+struct SerialStreamingTextEmitter {
+    enum Step: Equatable {
+        case more
+        /// A buyer `stop` string matched in the decoded text.
+        case requestStop
+        /// A serial tool turn completed its first valid tool call.
+        case toolCallComplete
+        /// The structured-output accumulator refused the delta (its error is
+        /// held by the accumulator).
+        case structuredError
+    }
+
+    private let streamToolsIncrementally: Bool
+    private let stopsAfterFirstCompleteToolCall: Bool
+    private var toolStreamer: NativeToolCallStreamEmitter
+    private(set) var emittedText = ""
+
+    init(request: ChatCompletionRequest) {
+        streamToolsIncrementally = ModelRuntime.hasEnabledTools(request.promptSource.tools)
+            && !HarmonyResponseParser.isHarmonyModelID(request.model)
+        stopsAfterFirstCompleteToolCall = request.stopsAfterFirstCompleteToolCall
+        toolStreamer = NativeToolCallStreamEmitter(
+            modelID: request.model,
+            allowedFunctionNames: ModelRuntime.toolFunctionNames(from: request.promptSource.tools)
+        )
+    }
+
+    /// One decoded prefix of the generation (`streamingSafePrefix` of every
+    /// token so far).
+    mutating func step(
+        candidate: (text: String, hitStop: Bool),
+        structuredAccumulator: StructuredStreamingContentAccumulator,
+        idleState: StructuredStreamingIdleState,
+        onChunk: (StreamChunk) -> Void
+    ) -> Step {
+        if streamToolsIncrementally {
+            for event in toolStreamer.observe(candidate.text) {
+                onChunk(event)
+            }
+            if !toolStreamer.suppressesAssistantContent {
+                let safe = toolStreamer.visibleContentPrefix(of: candidate.text)
+                let delta = ModelRuntime.streamDelta(from: emittedText, to: safe)
+                if !delta.isEmpty {
+                    if structuredAccumulator.append(delta) != nil {
+                        return .structuredError
+                    }
+                    idleState.noteContent()
+                    emittedText = safe
+                    onChunk(.content(delta))
+                }
+            }
+            if stopsAfterFirstCompleteToolCall, toolStreamer.hasCompletedValidToolCall {
+                return .toolCallComplete
+            }
+            return candidate.hitStop ? .requestStop : .more
+        }
+
+        let delta = ModelRuntime.streamDelta(from: emittedText, to: candidate.text)
+        if !delta.isEmpty {
+            if structuredAccumulator.append(delta) != nil {
+                return .structuredError
+            }
+            idleState.noteContent()
+            emittedText = candidate.text
+            onChunk(.content(delta))
+        }
+        return candidate.hitStop ? .requestStop : .more
+    }
+
+    /// The end of generation: remaining tool-call deltas over the final
+    /// filtered text, then any content the stream held back.
+    mutating func finish(
+        finalText: String,
+        parsed: ModelRuntime.ParsedGeneratedOutput,
+        structuredAccumulator: StructuredStreamingContentAccumulator,
+        idleState: StructuredStreamingIdleState,
+        onChunk: (StreamChunk) -> Void
+    ) throws {
+        let finalDelta = ModelRuntime.streamDelta(from: emittedText, to: parsed.content)
+        if streamToolsIncrementally {
+            for event in toolStreamer.observe(finalText) {
+                onChunk(event)
+            }
+            if parsed.toolCalls.isEmpty,
+               !parsed.content.isEmpty,
+               !toolStreamer.suppressesAssistantContent
+            {
+                let contentDelta = ModelRuntime.streamDelta(from: emittedText, to: parsed.content)
+                if !contentDelta.isEmpty {
+                    if let error = structuredAccumulator.append(contentDelta) {
+                        throw error
+                    }
+                    idleState.noteContent()
+                    onChunk(.content(contentDelta))
+                }
+            }
+        } else if !finalDelta.isEmpty {
+            if let error = structuredAccumulator.append(finalDelta) {
+                throw error
+            }
+            idleState.noteContent()
+            onChunk(.content(finalDelta))
+        }
+        if let error = structuredAccumulator.error {
+            throw error
+        }
+    }
+}
+
 // `internal` (not `private`) so the allowlist fail-closed behavior is unit-testable via
 // `@testable import macprovider_cli` (see NativeToolCallStreamEmitterTests).
 struct NativeToolCallStreamEmitter {
     private let startDelimiter: String
     private let endDelimiter: String
     private let argumentKey: String
     /// Declared tools for this request. A streamed tool-call delta MUST NOT be emitted for
     /// any function name not in this set — otherwise a widened name grammar could surface an
     /// undeclared tool_call to the buyer before the final parser's fail-closed check
     /// (SPEC-018 §3.5). `nil`/empty means no tools were declared, so nothing may be emitted.
     private let allowedFunctionNames: Set<String>?
     /// Function-XML (`<function=…>`) is a Qwen-row-only grammar (SPEC-018 §3.1 v0.2.7). The
     /// streaming emitter mirrors the non-streaming parser's family gate: only Qwen models may
     /// stream `<function=…>` tool-call deltas; other families fall through to JSON parsing (which
     /// yields nothing for XML), so no non-Qwen family can stream a function-XML delta.
     private let allowsFunctionXML: Bool
     /// SPEC-018 §3.2: only Qwen 2.5/3 and Llama 3.3 native grammars are recognized.
     /// Unsupported families must not complete a serial stop on lookalike markup.
     private let enabled: Bool
     private var sawToolDelimiter = false
     private var opened = false
     private var closed = false
     private var completedValidToolCall = false
     private var emittedArguments = ""
     private var callID = "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
 
     init(modelID: String, allowedFunctionNames: Set<String>?) {
         self.allowedFunctionNames = allowedFunctionNames
         let isQwen = modelID.localizedCaseInsensitiveContains("qwen2.5")
             || modelID.localizedCaseInsensitiveContains("qwen3")
         let isLlama33 = modelID.localizedCaseInsensitiveContains("llama-3.3")
         self.enabled = isQwen || isLlama33
         self.allowsFunctionXML = isQwen
         if isLlama33 {
             startDelimiter = "<|python_tag|>"
             endDelimiter = "<|eom_id|>"
             argumentKey = "parameters"
         } else {
             startDelimiter = "<tool_call>"
             endDelimiter = "</tool_call>"
             argumentKey = "arguments"
         }
     }
 
     var suppressesAssistantContent: Bool { enabled && (opened || sawToolDelimiter) }
 
     /// True once a declared tool has parser-valid, within-cap arguments (complete
     /// JSON object or closed function-XML). Wrapper-close, prefixes, and cap
     /// failures must not satisfy this; they must not stop a serial turn.
     var hasCompletedValidToolCall: Bool { completedValidToolCall }
 
     func visibleContentPrefix(of text: String) -> String {
         guard enabled else { return text }
         if suppressesAssistantContent {
             return ""
         }
         if let start = text.range(of: startDelimiter) {
             return String(text[..<start.lowerBound])
         }
         if allowsFunctionXML, let start = text.range(of: "<function=") {
             return String(text[..<start.lowerBound])
         }
         return Self.stripIncompleteOpenDelimiter(from: text, delimiter: startDelimiter, extra: allowsFunctionXML ? "<function=" : nil)
     }
 
     mutating func observe(_ text: String) -> [StreamChunk] {
         guard enabled, !closed else {
             return []
         }
         if let start = text.range(of: startDelimiter) {
             sawToolDelimiter = true
             let afterStart = start.upperBound
             let bodyEnd = text.range(of: endDelimiter, range: afterStart..<text.endIndex)?.lowerBound ?? text.endIndex
             let body = String(text[afterStart..<bodyEnd])
             var isClosed = text.range(of: endDelimiter, range: afterStart..<text.endIndex) != nil
             if allowsFunctionXML, body.contains("<function=") {
                 // Outer </tool_call> is not a valid XML close; wait for </function>.
                 return observeNemotronXML(body: body, isClosed: body.contains("</function>"))
             }
             if !isClosed, ToolCallParser.firstCompleteJSONObject(in: body) != nil {
diff --git a/phase3-binary/Tests/macprovider-cliTests/ContinuousBatchSchedulerTests.swift b/phase3-binary/Tests/macprovider-cliTests/ContinuousBatchSchedulerTests.swift
index dba1253c..d95a2276 100644
--- a/phase3-binary/Tests/macprovider-cliTests/ContinuousBatchSchedulerTests.swift
+++ b/phase3-binary/Tests/macprovider-cliTests/ContinuousBatchSchedulerTests.swift
@@ -1729,160 +1729,190 @@ final class ContinuousBatchSchedulerTests: XCTestCase {
                 maxActiveRows: 1,
                 queueLimit: 4,
                 decodeHeadroomTokens: 1,
                 maxRequestTokens: 8,
                 maxQueuedTokens: 8,
                 snapshot: ContinuousBatchSchedulerSnapshot(
                     modelID: Self.modelID,
                     modelSHA256: Self.modelSHA,
                     weightsGeneration: 3
                 )
             ),
             allocator: allocator,
             backend: backend,
             replayAuthority: TestReplayAuthority()
         )
         func request(_ id: String, promptCount: Int) -> ContinuousBatchSchedulerRequest {
             .init(
                 id: id,
                 conversationKey: "",
                 promptTokens: Array(repeating: 1, count: promptCount),
                 maxOutputTokens: 1
             )
         }
 
         let active = Task { try await scheduler.submit(request("active", promptCount: 2)) }
         try await eventually { await backend.prefillCallCount() == 1 }
         let queued1 = Task { try await scheduler.submit(request("queued1", promptCount: 7)) }
         try await eventually { await scheduler.metrics().waitingCount == 1 }
         let overflow = Task { () -> Error? in
             do {
                 _ = try await scheduler.submit(request("overflow", promptCount: 2))
                 return nil
             } catch {
                 return error
             }
         }
         try await Task.sleep(nanoseconds: 20_000_000)
 
         await prefillGate.open()
         let overflowError = await overflow.value
         guard case ContinuousBatchSchedulerError.backpressure? = overflowError else {
             XCTFail("expected aggregate queue-token backpressure, got \(String(describing: overflowError))")
             _ = try? await active.value
             _ = try? await queued1.value
             return
         }
         // Count capacity remains, but retained token capacity is exhausted.
         _ = try await active.value
         _ = try await queued1.value
         try await eventually { await scheduler.metrics().retainedTerminalResults == 2 }
     }
 
     func testTokenSinkStreamsDeltasAndFailureRetainsEmittedAccounting() async throws {
         let recorder = TokenEventRecorder()
         let backend = ScriptedBackend(scripts: ["stream": [7, 8]], failDecodeCall: 2)
         let scheduler = try await makeScheduler(maxActiveRows: 1, backend: backend)
 
         let result = try await scheduler.submit(
             .init(
                 id: "stream",
                 conversationKey: "",
                 promptTokens: [1],
                 maxOutputTokens: 2
             ),
             tokenSink: { recorder.append($0) }
         )
 
         try await eventually { recorder.events().count == 1 }
         let events = recorder.events()
         XCTAssertEqual(events.map(\.tokenIndex), [0])
         XCTAssertEqual(events.map(\.token), [7])
         XCTAssertEqual(events.map(\.replayTokens), [nil])
         XCTAssertEqual(events.first?.snapshot.modelSHA256, Self.modelSHA)
         XCTAssertEqual(result.terminalStatus, .batchFailed)
         XCTAssertEqual(result.outputTokens, [])
         XCTAssertEqual(result.completionTokens, 0)
         XCTAssertEqual(result.emittedTokens, 1)
         XCTAssertEqual(result.snapshot?.modelSHA256, Self.modelSHA)
     }
 
+    /// SPEC-038 AC-6c: a serial tool turn asks its decoding row to end; the
+    /// row finishes as a normal `.stop` at its next token instead of running
+    /// to `max_tokens`.
+    func testStopEarlyEndsDecodingRowAsStopAtNextToken() async throws {
+        let secondDecodeGate = AsyncGate()
+        let recorder = TokenEventRecorder()
+        let backend = SecondDecodeGateBackend(secondDecodeGate: secondDecodeGate)
+        let scheduler = try await makeScheduler(maxActiveRows: 1, backend: backend)
+        let submitted = Task {
+            try await scheduler.submit(
+                .init(id: "tool-turn", conversationKey: "", promptTokens: [1], maxOutputTokens: 8),
+                tokenSink: { recorder.append($0) }
+            )
+        }
+        try await eventually { recorder.events().count == 1 }
+        await scheduler.stopEarly(requestID: "tool-turn")
+        await secondDecodeGate.open()
+        let result = try await submitted.value
+
+        XCTAssertEqual(result.terminalStatus, .stop)
+        XCTAssertNil(result.errorCode)
+        XCTAssertEqual(result.generatedTokens, [7, 8])
+        XCTAssertEqual(result.outputTokens, [7, 8])
+        XCTAssertEqual(result.completionTokens, 2)
+        XCTAssertEqual(result.settlementDisposition, .eligibleOwner)
+        // A stop request for a row that is not decoding is ignored.
+        await scheduler.stopEarly(requestID: "tool-turn")
+        await scheduler.stopEarly(requestID: "unknown")
+    }
+
     func testTerminalResultWaitsForAcceptedTokenDelivery() async throws {
         let sinkGate = AsyncGate()
         let recorder = TokenEventRecorder()
         let completion = CompletionFlag()
         let duplicateRecorder = TokenEventRecorder()
         let duplicateCompletion = CompletionFlag()
         let backend = ScriptedBackend(scripts: ["ordered": [7]])
         let scheduler = try await makeScheduler(maxActiveRows: 1, backend: backend)
 
         let submission = Task {
             let result = try await scheduler.submit(
                 .init(
                     id: "ordered",
                     conversationKey: "",
                     promptTokens: [1],
                     maxOutputTokens: 1
                 ),
                 tokenSink: { event in
                     recorder.append(event)
                     await sinkGate.wait()
                 }
             )
             await completion.markComplete()
             return result
         }
 
         try await eventually { recorder.events().count == 1 }
         try await Task.sleep(nanoseconds: 20_000_000)
         let completedBeforeDelivery = await completion.isComplete
         XCTAssertFalse(completedBeforeDelivery)
 
         let duplicate = Task {
             let result = try await scheduler.submit(
                 .init(
                     id: "ordered",
                     conversationKey: "",
                     promptTokens: [1],
                     maxOutputTokens: 1
                 ),
                 tokenSink: { duplicateRecorder.append($0) }
             )
             await duplicateCompletion.markComplete()
             return result
         }
         try await eventually { duplicateRecorder.events().count == 1 }
         XCTAssertEqual(duplicateRecorder.events().first?.replayTokens, [7])
         duplicate.cancel()
         try await Task.sleep(nanoseconds: 20_000_000)
         let duplicateCompletedBeforeOriginalDelivery = await duplicateCompletion.isComplete
         XCTAssertFalse(duplicateCompletedBeforeOriginalDelivery)
 
         await sinkGate.open()
         let result = try await submission.value
         let duplicateResult = try await duplicate.value
         let completedAfterDelivery = await completion.isComplete
         XCTAssertTrue(completedAfterDelivery)
         XCTAssertEqual(result.terminalStatus, .length)
         XCTAssertEqual(result.outputTokens, [7])
         XCTAssertEqual(duplicateResult.terminalStatus, .length)
         XCTAssertEqual(duplicateResult.settlementDisposition, .nonSettlingReplay)
     }
 
     func testDrainWaitsForPendingTerminalTokenDelivery() async throws {
         let sinkGate = AsyncGate()
         let recorder = TokenEventRecorder()
         let drainCompletion = CompletionFlag()
         let backend = ScriptedBackend(scripts: ["drain-delivery": [7]])
         let scheduler = try await makeScheduler(maxActiveRows: 1, backend: backend)
 
         let submission = Task {
             try await scheduler.submit(
                 .init(
                     id: "drain-delivery",
                     conversationKey: "",
                     promptTokens: [1],
                     maxOutputTokens: 1
                 ),
                 tokenSink: { event in
                     recorder.append(event)
                     await sinkGate.wait()
diff --git a/phase3-binary/Tests/macprovider-cliTests/ContinuousBatchToolStructuredRowTests.swift b/phase3-binary/Tests/macprovider-cliTests/ContinuousBatchToolStructuredRowTests.swift
new file mode 100644
index 00000000..d3320c43
--- /dev/null
+++ b/phase3-binary/Tests/macprovider-cliTests/ContinuousBatchToolStructuredRowTests.swift
@@ -0,0 +1,499 @@
+import XCTest
+import MacProviderCore
+@testable import macprovider_cli
+
+/// SPEC-038 AC-6c: given identical generated text, a batched row's finalize
+/// and stream produce exactly the serial path's `tool_calls`, SSE chunks and
+/// structured-validation verdicts. The "serial" side of each test drives the
+/// functions the serial `complete`/`stream` paths call, token by token, the
+/// way their generate callbacks do.
+final class ContinuousBatchToolStructuredRowTests: XCTestCase {
+    private static let qwen = "mlx-community/Qwen3-8B-4bit"
+    private static let stopTokenFilter = StopTokenFilter(tokens: ["<|im_end|>"])
+    private static let weatherTool: [[String: Any]] = [[
+        "type": "function",
+        "function": [
+            "name": "get_weather",
+            "parameters": ["type": "object", "properties": ["city": ["type": "string"]]],
+        ],
+    ]]
+    private static let schema: [String: Any] = [
+        "type": "json_schema",
+        "json_schema": [
+            "name": "answer",
+            "schema": [
+                "type": "object",
+                "properties": ["a": ["type": "integer"]],
+                "required": ["a"],
+                "additionalProperties": false,
+            ],
+        ],
+    ]
+
+    /// Two complete tool calls, one token per piece, then trailing text.
+    private static let twoCallPieces: [String] = [
+        "<tool_call>", "\n{\"name\": ", "\"get_weather\"", ", \"arguments\": ",
+        "{\"city\": ", "\"Paris\"}", "}", "\n</tool_call>",
+        "\n<tool_call>", "\n{\"name\": \"get_weather\", ", "\"arguments\": {\"city\": \"Rome\"}}",
+        "\n</tool_call>", " trailing",
+    ]
+
+    // MARK: - fixtures
+
+    private struct Vocab {
+        let pieces: [String]
+        var ids: [Int] { Array(pieces.indices) }
+        func decode(_ ids: [Int]) -> String { ids.map { pieces[$0] }.joined() }
+    }
+
+    private func request(_ body: [String: Any]) throws -> ChatCompletionRequest {
+        var dict = body
+        dict["model"] = dict["model"] ?? Self.qwen
+        dict["messages"] = dict["messages"] ?? [["role": "user", "content": "hi"]]
+        return try ChatCompletionRequest.parse(data: try JSONSerialization.data(withJSONObject: dict))
+    }
+
+    private func schedulerResult(
+        _ ids: [Int],
+        status: ContinuousBatchSchedulerTerminalStatus = .stop
+    ) -> ContinuousBatchSchedulerResult {
+        ContinuousBatchSchedulerResult(
+            requestID: "r",
+            conversationKey: "",
+            generatedTokens: ids,
+            outputTokens: ids,
+            promptTokens: 3,
+            completionTokens: ids.count,
+            emittedTokens: ids.count,
+            cachedPromptTokens: 0,
+            terminalStatus: status,
+            errorCode: nil,
+            snapshot: nil,
+            settlementDisposition: .eligibleOwner,
+            retainedCache: nil
+        )
+    }
+
+    private func finalizeBatched(
+        _ request: ChatCompletionRequest,
+        vocab: Vocab,
+        ids: [Int],
+        serialStopTokenCount: Int?,
+        status: ContinuousBatchSchedulerTerminalStatus = .stop
+    ) throws -> ModelRuntime.ContinuousBatchFinalizedRow {
+        try ModelRuntime.finalizeContinuousBatchRow(
+            request: request,
+            result: schedulerResult(ids, status: status),
+            modelStopTokenIDs: [],
+            serialStopTokenCount: serialStopTokenCount,
+            promptTokenIDs: [1, 2, 3],
+            decode: vocab.decode,
+            stopTokenFilter: Self.stopTokenFilter,
+            generationMilliseconds: 0,
+            modelHash: nil
+        )
+    }
+
+    /// The serial non-streaming path: its generate callback stops a serial
+    /// tool turn at the first complete valid tool call, then it parses and
+    /// validates the text of the tokens it generated.
+    private func serialComplete(
+        _ request: ChatCompletionRequest,
+        vocab: Vocab
+    ) throws -> (completion: CompletionResult, tokenCount: Int) {
+        var generated: [Int] = []
+        var observer = NativeToolCallStreamEmitter(
+            modelID: request.model,
+            allowedFunctionNames: ModelRuntime.toolFunctionNames(from: request.promptSource.tools)
+        )
+        for id in vocab.ids {
+            generated.append(id)
+            if ModelRuntime.serialToolStopApplies(request),
+               ModelRuntime.observeSerialToolStop(
+                   &observer,
+                   decoded: vocab.decode(generated),
+                   stopTokenFilter: Self.stopTokenFilter,
+                   requestStops: request.stop
+               ) {
+                break
+            }
+        }
+        let filtered = ModelRuntime.applyOutputFilters(
+            vocab.decode(generated),
+            stopTokenFilter: Self.stopTokenFilter,
+            requestStops: request.stop
+        )
+        let parsed = try ModelRuntime.parseGeneratedOutput(
+            filteredText: filtered.text,
+            generatedTokenIDs: generated,
+            decode: vocab.decode,
+            request: request,
+            mode: .complete(finishReason: filtered.hitStop ? "request_stop" : "stop"),
+            defaultCompletionTokens: generated.count,
+            stopTokenFilter: Self.stopTokenFilter,
+            requestStops: request.stop,
+            globalHitStop: filtered.hitStop
+        )
+        let completion = try ModelRuntime.validateStructuredCompletion(CompletionResult(
+            content: parsed.content,
+            finishReason: parsed.toolCalls.isEmpty ? "stop" : "tool_calls",
+            promptTokens: 3,
+            completionTokens: parsed.completionTokens,
+            toolCalls: parsed.toolCalls.isEmpty ? nil : parsed.toolCalls,
+            settlementDisposition: .eligibleOwner
+        ), request: request)
+        return (completion, generated.count)
+    }
+
+    /// The serial streaming path over the same tokens: one emitter step per
+    /// token until it would stop generating, then its finish and the
+    /// structured verdict on buyer-visible content.
+    private func serialStream(
+        _ request: ChatCompletionRequest,
+        vocab: Vocab
+    ) -> (chunks: [String], result: Result<CompletionResult, APIError>) {
+        let accumulator = StructuredStreamingContentAccumulator(
+            enabled: ModelRuntime.requiresStructuredValidation(request.responseFormat)
+        )
+        let idle = StructuredStreamingIdleState(enabled: false)
+        let sink = ChunkSink()
+        var emitter = SerialStreamingTextEmitter(request: request)
+        var generated: [Int] = []
+        loop: for id in vocab.ids {
+            generated.append(id)
+            let candidate = ModelRuntime.streamingSafePrefix(
+                vocab.decode(generated),
+                stopTokenFilter: Self.stopTokenFilter,
+                requestStops: request.stop
+            )
+            switch emitter.step(
+                candidate: candidate,
+                structuredAccumulator: accumulator,
+                idleState: idle,
+                onChunk: sink.append
+            ) {
+            case .more:
+                continue
+            case .requestStop, .toolCallComplete, .structuredError:
+                break loop
+            }
+        }
+        let final = ModelRuntime.applyOutputFilters(
+            vocab.decode(generated),
+            stopTokenFilter: Self.stopTokenFilter,
+            requestStops: request.stop
+        )
+        do {
+            let parsed = try ModelRuntime.parseGeneratedOutput(
+                filteredText: final.text,
+                generatedTokenIDs: generated,
+                decode: vocab.decode,
+                request: request,
+                mode: .complete(finishReason: "stop"),
+                defaultCompletionTokens: generated.count,
+                stopTokenFilter: Self.stopTokenFilter,
+                requestStops: request.stop,
+                globalHitStop: final.hitStop
+            )
+            try emitter.finish(
+                finalText: final.text,
+                parsed: parsed,
+                structuredAccumulator: accumulator,
+                idleState: idle,
+                onChunk: sink.append
+            )
+            let completion = try ModelRuntime.validateStructuredStreamingCompletion(
+                CompletionResult(
+                    content: parsed.content,
+                    finishReason: parsed.toolCalls.isEmpty ? "stop" : "tool_calls",
+                    promptTokens: 3,
+                    completionTokens: parsed.completionTokens,
+                    toolCalls: parsed.toolCalls.isEmpty ? nil : parsed.toolCalls,
+                    settlementDisposition: .eligibleOwner
+                ),
+                request: request,
+                buyerVisibleContent: accumulator.content
+            )
+            return (sink.normalized(), .success(completion))
+        } catch {
+            return (sink.normalized(), .failure(error as! APIError))
+        }
+    }
+
+    /// The batched stream: every delivered token goes through the row's
+    /// stream state (tokens past the serial stop point included, as a row
+    /// may decode on before `stopEarly` lands), then the batched finalize.
+    private func batchedStream(
+        _ request: ChatCompletionRequest,
+        vocab: Vocab,
+        deliveredIDs: [Int]? = nil
+    ) -> (chunks: [String], result: Result<CompletionResult, APIError>, stopRequests: Int, finalized: ModelRuntime.ContinuousBatchFinalizedRow?) {
+        let accumulator = StructuredStreamingContentAccumulator(
+            enabled: ModelRuntime.requiresStructuredValidation(request.responseFormat)
+        )
+        let idle = StructuredStreamingIdleState(enabled: false)
+        let sink = ChunkSink()
+        let state = ModelRuntime.AttachedPagedKVStreamState(request: request)
+        let ids = deliveredIDs ?? vocab.ids
+        var stopRequests = 0
+        for id in ids where state.step(
+            eventTokens: [id],
+            decode: vocab.decode,
+            stopTokenFilter: Self.stopTokenFilter,
+            requestStops: request.stop,
+            structuredAccumulator: accumulator,
+            idleState: idle,
+            onChunk: sink.append
+        ) {
+            stopRequests += 1
+        }
+        if let error = state.error() {
+            return (sink.normalized(), .failure(error), stopRequests, nil)
+        }
+        do {
+            let finalized = try finalizeBatched(
+                request,
+                vocab: vocab,
+                ids: ids,
+                serialStopTokenCount: state.serialStopTokenCount
+            )
+            let completion = try ModelRuntime.finishContinuousBatchStream(
+                finalized,
+                state: state,
+                request: request,
+                structuredAccumulator: accumulator,
+                idleState: idle,
+                onChunk: sink.append
+            )
+            return (sink.normalized(), .success(completion), stopRequests, finalized)
+        } catch {
+            return (sink.normalized(), .failure(error as! APIError), stopRequests, nil)
+        }
+    }
+
+    private func calls(_ toolCalls: [macprovider_cli.ToolCall]?) -> [String] {
+        (toolCalls ?? []).map { "\($0.functionName) \($0.arguments)" }
+    }
+
+    // MARK: - non-streaming tool calls
+
+    func testSerialToolTurnTruncatesToSerialStopAndMatchesSerialToolCalls() throws {
+        let request = try request(["tools": Self.weatherTool])
+        let vocab = Vocab(pieces: Self.twoCallPieces)
+        let serial = try serialComplete(request, vocab: vocab)
+        XCTAssertLessThan(serial.tokenCount, vocab.pieces.count, "serial stops at the first complete call")
+
+        // The batched row's sink runs the serial stop test on each token.
+        let stop = ModelRuntime.ContinuousBatchSerialToolStopState(request: request)
+        var stopRequests = 0
+        for id in vocab.ids where stop.observe(
+            eventTokens: [id],
+            decode: vocab.decode,
+            stopTokenFilter: Self.stopTokenFilter,
+            requestStops: request.stop
+        ) {
+            stopRequests += 1
+        }
+        XCTAssertEqual(stopRequests, 1)
+        XCTAssertEqual(stop.stopTokenCount, serial.tokenCount)
+
+        // The row decoded every token before stopping; the finalize truncates.
+        let batched = try finalizeBatched(
+            request,
+            vocab: vocab,
+            ids: vocab.ids,
+            serialStopTokenCount: stop.stopTokenCount,
+            status: .length
+        )
+        let completion = try ModelRuntime.validateStructuredCompletion(batched.completion, request: request)
+        XCTAssertEqual(calls(completion.toolCalls), calls(serial.completion.toolCalls))
+        XCTAssertEqual(calls(completion.toolCalls), [#"get_weather {"city":"Paris"}"#])
+        XCTAssertEqual(completion.finishReason, "tool_calls")
+        XCTAssertEqual(completion.content, serial.completion.content)
+        XCTAssertEqual(completion.completionTokens, serial.completion.completionTokens)
+        XCTAssertEqual(completion.completionTokens, serial.tokenCount)
+        XCTAssertEqual(batched.generatedTokens, Array(vocab.ids.prefix(serial.tokenCount)))
+        XCTAssertTrue(batched.truncatedAtSerialStop, "a row past the stop point must not commit its cache")
+    }
+
+    func testParallelToolTurnKeepsEveryCallLikeSerial() throws {
+        let request = try request(["tools": Self.weatherTool, "parallel_tool_calls": true])
+        let vocab = Vocab(pieces: Self.twoCallPieces)
+        let serial = try serialComplete(request, vocab: vocab)
+        XCTAssertEqual(serial.tokenCount, vocab.pieces.count)
+        XCTAssertFalse(ModelRuntime.serialToolStopApplies(request))
+
+        let batched = try finalizeBatched(request, vocab: vocab, ids: vocab.ids, serialStopTokenCount: nil)
+        let completion = try ModelRuntime.validateStructuredCompletion(batched.completion, request: request)
+        XCTAssertEqual(calls(completion.toolCalls), calls(serial.completion.toolCalls))
+        XCTAssertEqual(completion.toolCalls?.count, 2)
+        XCTAssertEqual(completion.finishReason, "tool_calls")
+        XCTAssertFalse(batched.truncatedAtSerialStop)
+    }
+
+    func testResponseByteCapMatchesSerialNonStreamingGuard() throws {
+        let request = try request(["tools": Self.weatherTool])
+        let vocab = Vocab(pieces: [String(repeating: "a", count: ToolCallParser.SPEC018_ARGUMENTS_PER_RESPONSE_BYTE_CAP + 1)])
+        XCTAssertThrowsError(try finalizeBatched(request, vocab: vocab, ids: vocab.ids, serialStopTokenCount: nil)) { error in
+            let apiError = error as? APIError
+            XCTAssertEqual(apiError?.status, 502)
+            XCTAssertEqual(apiError?.code, "response_byte_cap_exceeded")
+            XCTAssertEqual(apiError?.message, "Model response exceeded 2097152 bytes")
+        }
+        let atCap = Vocab(pieces: [String(repeating: "a", count: ToolCallParser.SPEC018_ARGUMENTS_PER_RESPONSE_BYTE_CAP)])
+        XCTAssertNoThrow(try finalizeBatched(request, vocab: atCap, ids: atCap.ids, serialStopTokenCount: nil))
+    }
+
+    // MARK: - non-streaming structured output
+
+    func testStructuredVerdictsMatchSerialNonStreaming() throws {
+        let request = try request(["response_format": Self.schema])
+        let cases: [(pieces: [String], expectedCode: String?)] = [
+            (["{\"a\"", ": 1}"], nil),
+            (["{\"a\"", ": 1"], "malformed_json_response"),
+            (["{\"a\"", ": \"x\"}"], "json_schema_validation_failed"),
+        ]
+        for testCase in cases {
+            let vocab = Vocab(pieces: testCase.pieces)
+            let serialCode = Self.apiCode { _ = try self.serialComplete(request, vocab: vocab) }
+            let batchedCode = Self.apiCode {
+                let row = try self.finalizeBatched(request, vocab: vocab, ids: vocab.ids, serialStopTokenCount: nil)
+                _ = try ModelRuntime.validateStructuredCompletion(row.completion, request: request)
+            }
+            XCTAssertEqual(batchedCode, serialCode, "\(testCase.pieces)")
+            XCTAssertEqual(serialCode, testCase.expectedCode, "\(testCase.pieces)")
+        }
+    }
+
+    // MARK: - streaming
+
+    func testStreamingToolTurnEmitsSerialToolDeltasAndStopsAtSerialToken() throws {
+        let request = try request(["tools": Self.weatherTool])
+        let vocab = Vocab(pieces: ["Checking. "] + Self.twoCallPieces)
+        let serial = serialStream(request, vocab: vocab)
+        let batched = batchedStream(request, vocab: vocab)
+
+        XCTAssertEqual(batched.chunks, serial.chunks)
+        XCTAssertTrue(batched.chunks.contains("tool:get_weather:"), "\(batched.chunks)")
+        XCTAssertFalse(batched.chunks.contains { $0.hasPrefix("content:") && $0.contains("<tool_call>") })
+        XCTAssertEqual(batched.chunks.first, "content:Checking. ")
+        XCTAssertEqual(batched.stopRequests, 1)
+        let serialCompletion = try serial.result.get()
+        let batchedCompletion = try batched.result.get()
+        XCTAssertEqual(calls(batchedCompletion.toolCalls), calls(serialCompletion.toolCalls))
+        XCTAssertEqual(batchedCompletion.finishReason, "tool_calls")
+        XCTAssertEqual(batchedCompletion.completionTokens, serialCompletion.completionTokens)
+        XCTAssertEqual(batched.finalized?.truncatedAtSerialStop, true)
+    }
+
+    func testStreamingOversizedToolArgumentsStreamNothingLikeSerial() throws {
+        let request = try request(["tools": Self.weatherTool])
+        let big = String(repeating: "x", count: ToolCallParser.SPEC018_ARGUMENTS_PER_CALL_BYTE_CAP + 1)
+        let vocab = Vocab(pieces: [
+            "<tool_call>\n{\"name\": \"get_weather\", \"arguments\": {\"city\": \"", big, "\"}}\n</tool_call>",
+        ])
+        let serial = serialStream(request, vocab: vocab)
+        let batched = batchedStream(request, vocab: vocab)
+        XCTAssertEqual(batched.chunks, serial.chunks)
+        // The serial emitter opens the call on the first piece and then
+        // closes on the over-cap arguments: nothing past the cap, and no
+        // tool markup as assistant content.
+        XCTAssertEqual(batched.chunks, ["tool:get_weather:", "args:0:{\"city\": \""])
+        XCTAssertFalse(batched.chunks.contains { $0.hasPrefix("content:") })
+        XCTAssertNil(try batched.result.get().toolCalls)
+        XCTAssertEqual(try batched.result.get().finishReason, try serial.result.get().finishReason)
+    }
+
+    func testStreamingInvalidJSONUnderJSONSchemaMatchesSerialChunksAndError() throws {
+        let request = try request(["response_format": Self.schema])
+        // The trailing "<" is held back as a possible stop-token prefix and
+        // only sent by the stream's end, before the structured verdict.
+        let vocab = Vocab(pieces: ["{\"a\"", ": 1}", "<"])
+        let serial = serialStream(request, vocab: vocab)
+        let batched = batchedStream(request, vocab: vocab)
+        XCTAssertEqual(batched.chunks, serial.chunks)
+        XCTAssertEqual(batched.chunks, ["content:{\"a\"", "content:: 1}", "content:<"])
+        guard case .failure(let serialError) = serial.result,
+              case .failure(let batchedError) = batched.result else {
+            return XCTFail("both paths must reject invalid JSON: \(serial.result) \(batched.result)")
+        }
+        XCTAssertEqual(batchedError.code, serialError.code)
+        XCTAssertEqual(batchedError.status, serialError.status)
+    }
+
+    func testStreamingSchemaMismatchAndValidJSONMatchSerial() throws {
+        let request = try request(["response_format": Self.schema])
+        for pieces in [["{\"a\"", ": \"x\"}"], ["{\"a\"", ": 1}"]] {
+            let vocab = Vocab(pieces: pieces)
+            let serial = serialStream(request, vocab: vocab)
+            let batched = batchedStream(request, vocab: vocab)
+            XCTAssertEqual(batched.chunks, serial.chunks)
+            switch (serial.result, batched.result) {
+            case (.success(let s), .success(let b)):
+                XCTAssertEqual(b.content, s.content)
+            case (.failure(let s), .failure(let b)):
+                XCTAssertEqual(b.code, s.code)
+            default:
+                XCTFail("verdicts differ: \(serial.result) \(batched.result)")
+            }
+        }
+    }
+
+    func testStreamingStructuredByteCapStopsRowWithSerialError() throws {
+        let request = try request(["response_format": ["type": "json_object"]])
+        let over = String(repeating: "1", count: ModelRuntime.structuredStreamingValidationBufferByteCap)
+        let vocab = Vocab(pieces: ["[", over, "]"])
+        let serial = serialStream(request, vocab: vocab)
+        let batched = batchedStream(request, vocab: vocab)
+        XCTAssertEqual(batched.chunks, serial.chunks)
+        XCTAssertEqual(batched.stopRequests, 1)
+        guard case .failure(let serialError) = serial.result,
+              case .failure(let batchedError) = batched.result else {
+            return XCTFail("both paths must fail the structured stream cap")
+        }
+        XCTAssertEqual(batchedError.code, "response_byte_cap_exceeded")
+        XCTAssertEqual(batchedError.code, serialError.code)
+    }
+
+    // MARK: - helpers
+
+    private static func apiCode(_ body: () throws -> Void) -> String? {
+        do {
+            try body()
+            return nil
+        } catch let error as APIError {
+            return error.code
+        } catch {
+            return "non_api_error:\(error)"
+        }
+    }
+}
+
+/// Normalized SSE-relevant chunks: tool-call ids are random per emitter, so
+/// the first delta records only its function name.
+private final class ChunkSink: @unchecked Sendable {
+    private let lock = NSLock()
+    private var chunks: [StreamChunk] = []
+
+    func append(_ chunk: StreamChunk) {
+        lock.lock()
+        chunks.append(chunk)
+        lock.unlock()
+    }
+
+    func normalized() -> [String] {
+        lock.lock()
+        defer { lock.unlock() }
+        return chunks.map { chunk in
+            switch chunk {
+            case .content(let text):
+                return "content:\(text)"
+            case .toolCallDelta(let delta):
+                if let name = delta.functionName {
+                    return "tool:\(name):\(delta.arguments ?? "")"
+                }
+                return "args:\(delta.index):\(delta.arguments ?? "")"
+            }
+        }
+    }
+}
diff --git a/phase3-binary/Tests/macprovider-cliTests/ServingKnobsConfigTests.swift b/phase3-binary/Tests/macprovider-cliTests/ServingKnobsConfigTests.swift
index a298727e..2806825b 100644
--- a/phase3-binary/Tests/macprovider-cliTests/ServingKnobsConfigTests.swift
+++ b/phase3-binary/Tests/macprovider-cliTests/ServingKnobsConfigTests.swift
@@ -1189,176 +1189,199 @@ final class ServingKnobsConfigTests: XCTestCase {
             maxBatch: 2,
             queueLimit: nil,
             kvBits: nil,
             draftConfigured: false,
             schedulerBackendAvailable: false,
             pagedKVDecision: .disabled,
             requestedTuple: nil,
             acceptanceCoverage: .unrestrictedForTests
         )
         XCTAssertEqual(capability.unsupportedReason, .pagedKVDisabled)
         XCTAssertTrue(capability.shouldUseSerialPath)
     }
 
     func testUnrepresentableRequestStateSerialRoutesInCanary() {
         let capability = ContinuousBatchingPolicy.capability(
             mode: .canary,
             maxBatch: 2,
             queueLimit: nil,
             kvBits: nil,
             draftConfigured: false,
             requestStateRepresentable: false,
             schedulerBackendAvailable: true,
             pagedKVDecision: .disabled,
             requestedTuple: nil,
             acceptanceCoverage: .unrestrictedForTests
         )
         XCTAssertEqual(capability.unsupportedReason, .requestStateUnrepresented)
         XCTAssertTrue(capability.shouldUseSerialPath)
     }
 
     func testUnrepresentableRequestStateFailsClosedInStrict() {
         // The gate must win even when the backend is available and the tuple
         // would otherwise be admitted: row-local generation state the shared
         // forward cannot represent must never enter a batch.
         let capability = ContinuousBatchingPolicy.capability(
             mode: .on,
             maxBatch: 4,
             queueLimit: nil,
             kvBits: nil,
             draftConfigured: false,
             requestStateRepresentable: false,
             schedulerBackendAvailable: true,
             pagedKVDecision: .disabled,
             requestedTuple: nil,
             acceptanceCoverage: .unrestrictedForTests
         )
         XCTAssertEqual(capability.unsupportedReason, .requestStateUnrepresented)
         XCTAssertThrowsError(try ContinuousBatchingPolicy.validateStrictStartup(capability)) { error in
             guard let apiError = error as? APIError else {
                 return XCTFail("expected APIError, got \(error)")
             }
             XCTAssertEqual(apiError.code, "continuous_batching_request_state_unsupported")
             XCTAssertEqual(apiError.status, 400)
         }
     }
 
     private func parsedRequest(_ body: [String: Any]) throws -> ChatCompletionRequest {
         var dict = body
         dict["model"] = dict["model"] ?? "catalog/model"
         dict["messages"] = dict["messages"] ?? [["role": "user", "content": "hi"]]
         let data = try JSONSerialization.data(withJSONObject: dict)
         return try ChatCompletionRequest.parse(data: data)
     }
 
     func testRequestStateRepresentableGateOnParsedRequests() throws {
         // SPEC-038 AC-6b: sampled rows batch with the serial path's sampler and a
         // row-local seed, so plain sampling parameters no longer force serial.
         XCTAssertTrue(ModelRuntime.requestStateRepresentable(try parsedRequest([:])))
 
         let greedy: [String: Any] = ["temperature": 0, "top_p": 1.0]
         XCTAssertTrue(ModelRuntime.requestStateRepresentable(try parsedRequest(greedy)))
         XCTAssertTrue(ModelRuntime.requestStateRepresentable(try parsedRequest([
             "temperature": 0.7, "top_p": 0.9
         ])))
         // The serial path ignores presence/frequency penalties, so they do not
         // change what a batched row must represent.
         XCTAssertTrue(ModelRuntime.requestStateRepresentable(try parsedRequest([
             "temperature": 0.7, "presence_penalty": 0.5, "frequency_penalty": 0.5
         ])))
 
-        // Structured output (json_schema) → not representable.
+        // SPEC-038 AC-6c: structured output and tools constrain no logit; the
+        // batched row reuses the serial prompt rendering and finalize.
+        let jsonSchema: [String: Any] = ["type": "json_schema",
+                                         "json_schema": ["name": "s",
+                                                         "schema": ["type": "object",
+                                                                    "additionalProperties": false]]]
+        let tools: [[String: Any]] = [["type": "function",
+                                       "function": ["name": "f", "parameters": ["type": "object"]]]]
+        XCTAssertTrue(ModelRuntime.requestStateRepresentable(try parsedRequest([
+            "temperature": 0, "top_p": 1.0, "response_format": jsonSchema
+        ])))
+        XCTAssertTrue(ModelRuntime.requestStateRepresentable(try parsedRequest([
+            "temperature": 0.7, "response_format": ["type": "json_object"]
+        ])))
+        // Tools present WITHOUT tool_choice, and with a serial or parallel tool turn.
+        XCTAssertTrue(ModelRuntime.requestStateRepresentable(try parsedRequest([
+            "temperature": 0, "top_p": 1.0, "tools": tools
+        ])))
+        XCTAssertTrue(ModelRuntime.requestStateRepresentable(try parsedRequest([
+            "temperature": 0, "tools": tools, "parallel_tool_calls": true
+        ])))
+        // Harmony (gpt-oss) with tools or structured output stays serial: the
+        // batched stream has no Harmony channel parser. Plain Harmony is unchanged.
+        let harmony = "mlx-community/gpt-oss-20b-MXFP4-Q8"
         XCTAssertFalse(ModelRuntime.requestStateRepresentable(try parsedRequest([
-            "temperature": 0,
-            "top_p": 1.0,
-            "response_format": ["type": "json_schema",
-                                "json_schema": ["name": "s",
-                                                "schema": ["type": "object",
-                                                           "additionalProperties": false]]]
+            "model": harmony, "temperature": 0, "tools": tools
         ])))
-
-        // Tools present WITHOUT tool_choice → not representable (the HIGH the gate missed).
         XCTAssertFalse(ModelRuntime.requestStateRepresentable(try parsedRequest([
-            "temperature": 0,
-            "top_p": 1.0,
-            "tools": [["type": "function",
-                       "function": ["name": "f", "parameters": ["type": "object"]]]]
+            "model": harmony, "temperature": 0, "response_format": jsonSchema
+        ])))
+        XCTAssertTrue(ModelRuntime.requestStateRepresentable(try parsedRequest([
+            "model": harmony, "temperature": 0
+        ])))
+        // logit_bias / logprobs stay gated even alongside tools or structured output.
+        XCTAssertFalse(ModelRuntime.requestStateRepresentable(try parsedRequest([
+            "temperature": 0, "tools": tools, "logit_bias": ["123": -100]
+        ])))
+        XCTAssertFalse(ModelRuntime.requestStateRepresentable(try parsedRequest([
+            "temperature": 0, "response_format": jsonSchema, "logprobs": true
         ])))
 
         // Explicit JSON null tool_choice, no tools → representable (must NOT false-positive).
         var explicitNullToolChoice = greedy
         explicitNullToolChoice["tool_choice"] = NSNull()
         XCTAssertTrue(ModelRuntime.requestStateRepresentable(try parsedRequest(explicitNullToolChoice)))
 
         // logit_bias → not representable; logprobs:false → representable.
         XCTAssertFalse(ModelRuntime.requestStateRepresentable(try parsedRequest([
             "temperature": 0,
             "top_p": 1.0,
             "logit_bias": ["123": -100]
         ])))
         var logprobsFalse = greedy
         logprobsFalse["logprobs"] = false
         XCTAssertTrue(ModelRuntime.requestStateRepresentable(try parsedRequest(logprobsFalse)))
         XCTAssertFalse(ModelRuntime.requestStateRepresentable(try parsedRequest([
             "temperature": 0,
             "top_p": 1.0,
             "logprobs": true
         ])))
         // top_logprobs (response metadata) is rejected too so the gate is provably complete.
         XCTAssertFalse(ModelRuntime.requestStateRepresentable(try parsedRequest([
             "temperature": 0,
             "top_p": 1.0,
             "logprobs": true, "top_logprobs": 5
         ])))
     }
 
     func testRepresentableRequestStateDoesNotTripTheGate() {
         // Default representable=true path must be unaffected by the new gate.
         let capability = ContinuousBatchingPolicy.capability(
             mode: .canary,
             maxBatch: 2,
             queueLimit: nil,
             kvBits: nil,
             draftConfigured: false,
             requestStateRepresentable: true,
             schedulerBackendAvailable: false,
             pagedKVDecision: .disabled,
             requestedTuple: nil,
             acceptanceCoverage: .unrestrictedForTests
         )
         XCTAssertNotEqual(capability.unsupportedReason, .requestStateUnrepresented)
     }
 
     func testStableRequestIDGateOnlyTripsWhenSchedulerWouldOtherwiseAttach() {
         let descriptor = Self.pagedKVDescriptor()
         let tuple = Self.continuousBatchingTuple()
         let canary = ContinuousBatchingPolicy.capability(
             mode: .canary,
             maxBatch: 2,
             queueLimit: nil,
             kvBits: nil,
             draftConfigured: false,
             requestHasStableRequestID: false,
             schedulerBackendAvailable: true,
             durableReplayAuthorityAvailable: true,
             pagedKVDecision: .attached(descriptor),
             requestedTuple: tuple,
             acceptanceCoverage: Self.acceptanceCoverage(for: tuple)
         )
         XCTAssertEqual(canary.unsupportedReason, .stableRequestIDUnavailable)
         XCTAssertTrue(canary.shouldUseSerialPath)
         XCTAssertEqual(
             ContinuousBatchingPolicy.serialRouteTelemetryLine(canary),
             "event=batching_unsupported action=serial_routed reason=stable_request_id_unavailable\n"
         )
 
         let strict = ContinuousBatchingPolicy.capability(
             mode: .on,
             maxBatch: 2,
             queueLimit: nil,
             kvBits: nil,
             draftConfigured: false,
             requestHasStableRequestID: false,
             schedulerBackendAvailable: true,
             durableReplayAuthorityAvailable: true,
             pagedKVDecision: .attached(descriptor),
             requestedTuple: tuple,

exec
/bin/bash -lc 'git diff --no-ext-diff --unified=8 52fcb7e4''^ 52fcb7e4 -- phase3-binary/Sources/macprovider-cli/ModelRuntime.swift phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift | rg -n '"'"'^diff |''^@@|SerialStreamingTextEmitter|requestStateRepresentable|parseGeneratedOutput|validateStructuredCompletion|stopEarly|earlyStop|applyToken|finalize|structured|tool|completionTokens|usage|receipt|settle|generatedTokens|outputTokens'"'" in /Users/augstar/macprovider-1646-rest
 succeeded in 0ms:
1:diff --git a/phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift b/phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift
5:@@ -1208,16 +1208,19 @@ actor ContinuousBatchScheduler {
15:+    /// next applied token (a serial tool turn completed its first tool call).
16:+    private var earlyStopIDs: Set<String> = []
25:@@ -1372,16 +1375,27 @@ actor ContinuousBatchScheduler {
35:+    /// applied token. The serial path stops a serial tool turn (SPEC-018,
36:+    /// `parallel_tool_calls` omitted/false) once the first tool call is
40:+    func stopEarly(requestID: String) {
42:+        earlyStopIDs.insert(requestID)
53:@@ -2220,16 +2234,18 @@ actor ContinuousBatchScheduler {
62:+        } else if earlyStopIDs.contains(row.request.id) {
64:         } else if row.generatedTokens.count >= row.request.maxOutputTokens {
72:@@ -2743,16 +2759,17 @@ actor ContinuousBatchScheduler {
81:+        earlyStopIDs.remove(row.request.id)
84:         let outputTokens = isSuccessful ? row.outputTokens : []
88:             generatedTokens: isSuccessful ? row.generatedTokens : [],
89:             outputTokens: outputTokens,
90:@@ -2771,16 +2788,17 @@ actor ContinuousBatchScheduler {
99:+        earlyStopIDs.remove(row.request.id)
102:         let outputTokens = isSuccessful ? row.outputTokens : []
106:             generatedTokens: isSuccessful ? row.generatedTokens : [],
107:             outputTokens: outputTokens,
108:diff --git a/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift b/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift
112:@@ -3358,29 +3358,41 @@ actor ModelRuntime: ModelRuntimeServing {
121:-    /// contract carries. Structured-output/grammar validation, tool-constrained
131:+    /// SPEC-038 AC-6c: structured output (`response_format` json_object /
132:+    /// json_schema) and enabled tools constrain no logit. The serial path
134:+    /// generation (`parseGeneratedOutput`, `validateStructuredCompletion`, the
135:+    /// SPEC-018 byte caps, the serial tool-turn stop, and the streaming
136:+    /// `SerialStreamingTextEmitter`); a batched row reuses exactly those, so
137:+    /// they batch. Kept gated: Harmony (gpt-oss) models with tools or
138:+    /// structured output. Their serial stream parses Harmony channels as
142:     static func requestStateRepresentable(_ request: ChatCompletionRequest) -> Bool {
145:-        // Tool-bearing requests carry tool schemas + tool-call parser state.
146:         // hasEnabledTools treats an absent, explicit-null, or empty tools array as
147:         // no-tools, so a bare or explicit-null `tool_choice` does not false-positive
148:         // here (the meaningful signal is whether tools are actually enabled).
149:-        if hasEnabledTools(request.promptSource.tools) { return false }
152:+            || hasEnabledTools(request.promptSource.tools) {
163:@@ -3896,58 +3908,302 @@ actor ModelRuntime: ModelRuntimeServing {
179:+    /// delivered token runs the serial path's `SerialStreamingTextEmitter`
182:+    /// serial tool turn's first complete tool call, or a structured-output
184:+    /// so the finalize truncates the row to it.
189:+        private var emitter: SerialStreamingTextEmitter
197:+            emitter = SerialStreamingTextEmitter(request: request)
206:+            structuredAccumulator: StructuredStreamingContentAccumulator,
223:+                structuredAccumulator: structuredAccumulator,
231:+            case .toolCallComplete:
235:+            case .structuredError:
238:+                    recordedError = structuredAccumulator.error
248:+            structuredAccumulator: StructuredStreamingContentAccumulator,
262:+                structuredAccumulator: structuredAccumulator,
270:+        /// tool turn; nil when it would not have stopped early.
288:+    /// A batched non-streaming serial tool turn (SPEC-038 AC-6c): the serial
299:+                allowedFunctionNames: ModelRuntime.toolFunctionNames(from: request.promptSource.tools)
332:+        /// Not yet structured-validated: the non-streaming caller runs
333:+        /// `validateStructuredCompletion`, the streaming caller first sends
341:+        let generatedTokens: [Int]
347:+    /// SPEC-038 AC-6c: the one post-generation finalize for a batched row,
349:+    /// byte cap, output filters, `parseGeneratedOutput` (tool calls,
351:+    /// serial tool turn is first truncated to the token at which the serial
353:+    static func finalizeContinuousBatchRow(
368:+        var generatedTokens = droppingTrailingModelStop(
369:+            result.generatedTokens,
373:+        var completionTokenCount = result.completionTokens
374:+            - (result.generatedTokens.count - generatedTokens.count)
375:+        var outputTokens = result.outputTokens
377:+        if let serialStopTokenCount, serialStopTokenCount < generatedTokens.count {
378:+            completionTokenCount -= generatedTokens.count - serialStopTokenCount
379:+            generatedTokens = Array(generatedTokens.prefix(serialStopTokenCount))
380:+            outputTokens = Array(outputTokens.prefix(serialStopTokenCount))
383:+        let decoded = decode(outputTokens)
391:+                settlementRan: true
405:+        let parsed = try parseGeneratedOutput(
407:+            generatedTokenIDs: generatedTokens,
417:+        if !parsed.toolCalls.isEmpty {
418:+            finishReason = "tool_calls"
436:+                completionTokens: parsed.completionTokens,
440:+                toolCalls: parsed.toolCalls.isEmpty ? nil : parsed.toolCalls,
442:+                settlementDisposition: result.settlementDisposition
446:+            generatedTokens: generatedTokens,
452:+    /// order: remaining tool-call deltas and held-back content first, then
453:+    /// the structured verdict on the buyer-visible text.
455:+        _ finalized: ContinuousBatchFinalizedRow,
458:+        structuredAccumulator: StructuredStreamingContentAccumulator,
463:+            finalText: finalized.filteredText,
464:+            parsed: finalized.parsed,
465:+            structuredAccumulator: structuredAccumulator,
470:+            finalized.completion,
472:+            buyerVisibleContent: structuredAccumulator.content
484:@@ -4076,46 +4332,50 @@ actor ModelRuntime: ModelRuntimeServing {
547:@@ -4133,16 +4393,22 @@ actor ModelRuntime: ModelRuntimeServing {
556:+        // SPEC-038 AC-6c: a serial tool turn stops where the serial path
557:+        // stops generating (its first complete valid tool call).
570:@@ -4152,17 +4418,27 @@ actor ModelRuntime: ModelRuntimeServing {
588:+                        Task { await scheduler.stopEarly(requestID: schedulerRequestID) }
599:@@ -4172,87 +4448,33 @@ actor ModelRuntime: ModelRuntimeServing {
612:-            let generatedTokens = Self.droppingTrailingModelStop(
613:-                result.generatedTokens,
617:-            let completionTokenCount = result.completionTokens
618:-                - (result.generatedTokens.count - generatedTokens.count)
620:-                let decoded = context.tokenizer.decode(tokenIds: result.outputTokens)
628:-                        settlementRan: true
639:-                let parsed = try Self.parseGeneratedOutput(
641:-                    generatedTokenIDs: generatedTokens,
643:+            let finalized = try await container.perform { context in
644:+                try Self.finalizeContinuousBatchRow(
658:-                if !parsed.toolCalls.isEmpty {
659:-                    finishReason = "tool_calls"
670:-                return try Self.validateStructuredCompletion(CompletionResult(
676:-                    completionTokens: parsed.completionTokens,
680:-                    toolCalls: parsed.toolCalls.isEmpty ? nil : parsed.toolCalls,
682:-                    settlementDisposition: result.settlementDisposition
688:+            let completion = try Self.validateStructuredCompletion(finalized.completion, request: request)
689:+            let generatedTokens = finalized.generatedTokens
690:+            if !finalized.truncatedAtSerialStop,
700:@@ -4260,17 +4482,18 @@ actor ModelRuntime: ModelRuntimeServing {
706:                     fullTokens: preparedPromptTokenIDs + generatedTokens.map(Int32.init)
710:+            } else if !finalized.truncatedAtSerialStop,
713:                           canonicalTokens: preparedPromptTokenIDs + generatedTokens.map(Int32.init),
720:@@ -4314,16 +4537,17 @@ actor ModelRuntime: ModelRuntimeServing {
727:         structuredAccumulator: StructuredStreamingContentAccumulator,
738:@@ -4377,17 +4601,17 @@ actor ModelRuntime: ModelRuntimeServing {
757:@@ -4400,49 +4624,50 @@ actor ModelRuntime: ModelRuntimeServing {
767:+            // The SPEC-019 structured idle timeout ends the row as it ends the
803:-                    if let error = structuredAccumulator.append(delta) {
807:+                        structuredAccumulator: structuredAccumulator,
811:+                        Task { await scheduler.stopEarly(requestID: schedulerRequestID) }
823:@@ -4454,105 +4679,44 @@ actor ModelRuntime: ModelRuntimeServing {
836:-            let generatedTokens = Self.droppingTrailingModelStop(
837:-                result.generatedTokens,
841:-            let completionTokenCount = result.completionTokens
842:-                - (result.generatedTokens.count - generatedTokens.count)
844:-                let decoded = context.tokenizer.decode(tokenIds: result.outputTokens)
852:-                        settlementRan: true
863:-                let parsed = try Self.parseGeneratedOutput(
865:-                    generatedTokenIDs: generatedTokens,
867:+            let finalized = try await container.perform { context in
868:+                try Self.finalizeContinuousBatchRow(
882:-                if !parsed.toolCalls.isEmpty {
883:-                    finishReason = "tool_calls"
894:-                return try Self.validateStructuredCompletion(CompletionResult(
900:-                    completionTokens: parsed.completionTokens,
904:-                    toolCalls: parsed.toolCalls.isEmpty ? nil : parsed.toolCalls,
906:-                    settlementDisposition: result.settlementDisposition
913:-            // text renders it, so the buyer's bytes equal the receipt's.
914:-            if completion.toolCalls?.isEmpty != false {
917:-                    if let error = structuredAccumulator.append(remainder) {
928:+            // equal the receipt's.
930:+                finalized,
933:-                buyerVisibleContent: structuredAccumulator.content
934:+                structuredAccumulator: structuredAccumulator,
939:+            let generatedTokens = finalized.generatedTokens
940:+            if !finalized.truncatedAtSerialStop,
950:@@ -4560,17 +4724,18 @@ actor ModelRuntime: ModelRuntimeServing {
956:                     fullTokens: preparedPromptTokenIDs + generatedTokens.map(Int32.init)
960:+            } else if !finalized.truncatedAtSerialStop,
963:                           canonicalTokens: preparedPromptTokenIDs + generatedTokens.map(Int32.init),
970:@@ -4947,43 +5112,39 @@ actor ModelRuntime: ModelRuntimeServing {
977:                                 allowedFunctionNames: Self.toolFunctionNames(from: request.promptSource.tools)
995:-                                       Self.hasEnabledTools(request.promptSource.tools)
1023:@@ -5297,27 +5458,47 @@ actor ModelRuntime: ModelRuntimeServing {
1030:         let structuredAccumulator = StructuredStreamingContentAccumulator(enabled: Self.requiresStructuredValidation(request.responseFormat))
1039:-            structuredAccumulator: structuredAccumulator,
1043:+        // SPEC-038 AC-6c: a batched structured-output stream runs under the
1054:+                    accumulator: structuredAccumulator,
1067:+                structuredAccumulator: structuredAccumulator,
1082:@@ -5553,22 +5734,18 @@ actor ModelRuntime: ModelRuntimeServing {
1093:-                    var toolStreamer = NativeToolCallStreamEmitter(
1095:-                        allowedFunctionNames: Self.toolFunctionNames(from: request.promptSource.tools)
1097:+                    var textEmitter = SerialStreamingTextEmitter(request: request)
1106:@@ -5582,17 +5759,16 @@ actor ModelRuntime: ModelRuntimeServing {
1112:                         allowedFunctionNames: Self.toolFunctionNames(from: request.promptSource.tools),
1115:-                    let streamToolsIncrementally = Self.hasEnabledTools(request.promptSource.tools) && !isHarmonyResponse
1124:@@ -5644,57 +5820,30 @@ actor ModelRuntime: ModelRuntimeServing {
1134:-                                        for event in toolStreamer.observe(candidate.text) {
1137:-                                    if !toolStreamer.suppressesAssistantContent {
1138:-                                        let safe = toolStreamer.visibleContentPrefix(of: candidate.text)
1141:-                                            if structuredAccumulator.append(delta) != nil {
1149:-                                    if request.stopsAfterFirstCompleteToolCall, toolStreamer.hasCompletedValidToolCall {
1158:+                                    structuredAccumulator: structuredAccumulator,
1168:-                                    if structuredAccumulator.append(delta) != nil {
1180:+                                case .toolCallComplete, .structuredError:
1192:@@ -5728,44 +5877,23 @@ actor ModelRuntime: ModelRuntimeServing {
1203:-                            for event in toolStreamer.observe(final.text) {
1206:-                            if parsed.toolCalls.isEmpty,
1208:-                               !toolStreamer.suppressesAssistantContent
1212:-                                    if let error = structuredAccumulator.append(contentDelta) {
1220:-                            if let error = structuredAccumulator.append(finalDelta) {
1226:-                        if let error = structuredAccumulator.error {
1232:+                            structuredAccumulator: structuredAccumulator,
1238:                         if !parsed.toolCalls.isEmpty {
1239:                             finishReason = "tool_calls"
1244:@@ -6615,17 +6743,17 @@ actor ModelRuntime: ModelRuntimeServing {
1263:@@ -6699,17 +6827,17 @@ actor ModelRuntime: ModelRuntimeServing {
1282:@@ -6908,16 +7036,43 @@ actor ModelRuntime: ModelRuntimeServing {
1284:                 settlementRan: true
1291:+    /// SPEC-018 serial tool turn (`parallel_tool_calls` omitted/false) on a
1292:+    /// non-Harmony model with tools: generation stops once the first tool
1297:+            && hasEnabledTools(request.promptSource.tools)
1300:+    /// One serial-tool-turn stop test over the decode of every token so far.
1318:     private static func parseToolCallsIfRequested(_ text: String, request: ChatCompletionRequest) -> (content: String, toolCalls: [ToolCall]) {
1319:         guard let allowedFunctionNames = toolFunctionNames(from: request.promptSource.tools) else {
1326:@@ -6926,17 +7081,17 @@ actor ModelRuntime: ModelRuntimeServing {
1329:         if request.stopsAfterFirstCompleteToolCall, parsed.toolCalls.count > 1 {
1330:             return ("", Array(parsed.toolCalls.prefix(1)))
1332:         return ("", parsed.toolCalls)
1345:@@ -6974,17 +7129,17 @@ actor ModelRuntime: ModelRuntimeServing {
1354:-    private static func validateStructuredCompletion(_ completion: CompletionResult, request: ChatCompletionRequest) throws -> CompletionResult {
1355:+    static func validateStructuredCompletion(_ completion: CompletionResult, request: ChatCompletionRequest) throws -> CompletionResult {
1356:         if completion.toolCalls?.isEmpty == false {
1364:@@ -7265,21 +7420,21 @@ actor ModelRuntime: ModelRuntimeServing {
1375:         toolFunctionNames(from: value) != nil
1378:-    private static func toolFunctionNames(from value: MacProviderCore.JSONValue?) -> Set<String>? {
1379:+    static func toolFunctionNames(from value: MacProviderCore.JSONValue?) -> Set<String>? {
1380:         guard let value, case .array(let tools) = value, !tools.isEmpty else {
1383:         let names = tools.compactMap { tool -> String? in
1384:             guard case .object(let toolObject) = tool,
1385:                   case .object(let functionObject)? = toolObject["function"],
1388:@@ -7349,16 +7504,131 @@ actor ModelRuntime: ModelRuntimeServing {
1398:+/// incremental tool-call deltas (SPEC-018), assistant-content suppression once
1399:+/// a tool call opens, the SPEC-019 structured-content accumulator, and the
1400:+/// serial-tool-turn stop. The serial `stream` path and the continuous-batching
1402:+/// tool-bearing or structured-output row emits the serial SSE sequence.
1403:+struct SerialStreamingTextEmitter {
1408:+        /// A serial tool turn completed its first valid tool call.
1409:+        case toolCallComplete
1410:+        /// The structured-output accumulator refused the delta (its error is
1412:+        case structuredError
1417:+    private var toolStreamer: NativeToolCallStreamEmitter
1421:+        streamToolsIncrementally = ModelRuntime.hasEnabledTools(request.promptSource.tools)
1424:+        toolStreamer = NativeToolCallStreamEmitter(
1426:+            allowedFunctionNames: ModelRuntime.toolFunctionNames(from: request.promptSource.tools)
1434:+        structuredAccumulator: StructuredStreamingContentAccumulator,
1439:+            for event in toolStreamer.observe(candidate.text) {
1442:+            if !toolStreamer.suppressesAssistantContent {
1443:+                let safe = toolStreamer.visibleContentPrefix(of: candidate.text)
1446:+                    if structuredAccumulator.append(delta) != nil {
1447:+                        return .structuredError
1454:+            if stopsAfterFirstCompleteToolCall, toolStreamer.hasCompletedValidToolCall {
1455:+                return .toolCallComplete
1462:+            if structuredAccumulator.append(delta) != nil {
1463:+                return .structuredError
1472:+    /// The end of generation: remaining tool-call deltas over the final
1477:+        structuredAccumulator: StructuredStreamingContentAccumulator,
1483:+            for event in toolStreamer.observe(finalText) {
1486:+            if parsed.toolCalls.isEmpty,
1488:+               !toolStreamer.suppressesAssistantContent
1492:+                    if let error = structuredAccumulator.append(contentDelta) {
1500:+            if let error = structuredAccumulator.append(finalDelta) {
1506:+        if let error = structuredAccumulator.error {
1518:     /// Declared tools for this request. A streamed tool-call delta MUST NOT be emitted for

exec
/bin/bash -lc "sed -n '3330,3445p;3860,4345p' phase3-binary/Sources/macprovider-cli/ModelRuntime.swift" in /Users/augstar/macprovider-1646-rest
 succeeded in 0ms:
            contiguousCacheBridge: contiguousCacheBridge
        )
    }

    private static func pagedKVCacheKinds(
        container: ModelContainer
    ) async -> [PagedKVSharedForwardBackend.CacheKind]? {
        await container.perform { context in
            return Self.pagedKVCacheKinds(model: context.model)
        }
    }

    private func rebuildContinuousBatchScheduler(container: ModelContainer?) async {
        continuousBatchScheduler = await Self.makeContinuousBatchScheduler(
            decision: pagedKVAttachDecision,
            tuple: continuousBatchingRequestedTuple(),
            container: container,
            backendOverride: testContinuousBatchingBackend,
            maxBatch: maxBatch,
            queueLimit: continuousBatchQueueLimit,
            queueWaitTimeoutMS: continuousBatchQueueWaitTimeoutMS,
            maxContextTokens: maxContextTokens,
            modelID: currentModelID,
            modelSHA256: currentModelHash,
            weightsGeneration: currentSpecDecodeGeneration,
            kvBitsOverride: kvBitsOverride,
            prefillStepSize: prefillStepSize,
            replayAuthority: continuousBatchReplayAuthority,
            cachedTurns: continuousBatchingCachedTurns
        )
        continuousBatchingDurableReplayAuthorityAvailable =
            continuousBatchScheduler != nil && continuousBatchReplayAuthority.durableAvailable
    }

    /// A request is representable by the batched shared-forward contract only if
    /// its generation is fully described by the scalar sampling parameters the
    /// contract carries. logit_bias and logprobs impose row-local decoder state
    /// the contract does not model, so such requests must serial-route (canary) /
    /// fail closed (strict) before admission — a gate that holds for the SPEC-039
    /// bridge so a future backend cannot silently drop that state.
    ///
    /// SPEC-038 AC-6c: structured output (`response_format` json_object /
    /// json_schema) and enabled tools constrain no logit. The serial path
    /// renders them into the prompt (`userInput(for:)`) and applies them after
    /// generation (`parseGeneratedOutput`, `validateStructuredCompletion`, the
    /// SPEC-018 byte caps, the serial tool-turn stop, and the streaming
    /// `SerialStreamingTextEmitter`); a batched row reuses exactly those, so
    /// they batch. Kept gated: Harmony (gpt-oss) models with tools or
    /// structured output. Their serial stream parses Harmony channels as
    /// tokens arrive and sends only the final channel; the batched stream
    /// sink streams decoded text and has no Harmony channel parser, and the
    /// gate cannot tell a streaming request from a non-streaming one.
    static func requestStateRepresentable(_ request: ChatCompletionRequest) -> Bool {
        // hasEnabledTools treats an absent, explicit-null, or empty tools array as
        // no-tools, so a bare or explicit-null `tool_choice` does not false-positive
        // here (the meaningful signal is whether tools are actually enabled).
        if HarmonyResponseParser.isHarmonyModelID(request.model),
           requiresStructuredValidation(request.responseFormat)
            || hasEnabledTools(request.promptSource.tools) {
            return false
        }
        // logit_bias and logprobs (incl. top_logprobs metadata) have no carrier in
        // the scheduler row contract. top_logprobs only shapes response metadata,
        // not token selection, but is rejected here too so the gate is provably
        // complete and no per-request logprob surface can reach a batch unrepresented.
        if isActiveJSONValue(request.promptSource.logitBias) { return false }
        if isRequestedLogprobs(request.promptSource.logprobs) { return false }
        if isActiveJSONValue(request.promptSource.topLogprobs) { return false }
        // SPEC-038 AC-6b: each batched row samples with the serial path's own
        // sampler for its temperature/top_p and a row-local seed
        // (`ContinuousBatchRowSampler`). The serial path ignores presence and
        // frequency penalties, so they do not change what a row can represent.
        return ContinuousBatchRowSampler.supports(
            temperature: request.temperature,
            topP: request.topP
        )
    }

    nonisolated static func requestHasStableRequestID(_ request: ChatCompletionRequest) -> Bool {
        nonEmpty(request.requestID) != nil
    }

    /// True when a JSON field is present and not explicit null. `optionalJSONValue`
    /// preserves JSON `null` as `.null`, so a bare `!= nil` check would misclassify
    /// an explicit-null field as active.
    static func isActiveJSONValue(_ value: MacProviderCore.JSONValue?) -> Bool {
        guard let value else { return false }
        if case .null = value { return false }
        return true
    }

    /// True when logprobs are actually requested. Absent, null, or `false` are not
    /// requests and must not force serial routing.
    static func isRequestedLogprobs(_ value: MacProviderCore.JSONValue?) -> Bool {
        guard let value else { return false }
        switch value {
        case .null, .bool(false):
            return false
        default:
            return true
        }
    }

    private func applyContinuousBatchingPolicy(
        request: ChatCompletionRequest,
        snapshot: RuntimeSnapshot,
        emitTelemetry: Bool = true
    ) throws -> ContinuousBatchingCapability {
        let capability = continuousBatchingCapability(
            draftConfigured: snapshot.hasTargetCompatibleDraft || currentDraftModelID != nil,
            requestHasStableRequestID: Self.requestHasStableRequestID(request),
            requestStateRepresentable: Self.requestStateRepresentable(request)
        )
        // Telemetry is emitted once per request at preflight; execution paths
        // re-validate for fail-closed safety but must not re-log the same
        // serial-route event (avoids double-counting canary promotion evidence).
                }
            }
            return RelayBlindPreparedRequest(handle: handle, inputTokens: inputTokens)
        } catch {
            unregisterInFlight(handle.registrationID)
            throw error
        }
    }

    func pagedKVPreflight(_ request: ChatCompletionRequest, with handle: RequestHandle) async throws {
        _ = try applyContinuousBatchingPolicy(request: request, snapshot: handle.snapshot)
        try Self.enforcePagedKVPreflight(pagedKVAttachDecision)
        try handle.drainCancelled.check()
    }

    private struct ContinuousBatchPreparedRequest: Sendable {
        let promptTokens: [Int]
        let stopTokenSequences: [[Int]]
        let modelStopTokenIDs: Set<Int>
        let recurrentCheckpointPositions: [Int]
        /// The loaded model has recurrent (hybrid) layers; computed for keyed
        /// requests only, false otherwise.
        let modelHasRecurrentLayers: Bool
    }

    /// Keyed hybrid requests only: where the batched row snapshots recurrent
    /// state, identical to the serial path's `prefillRecurrentCheckpoints`.
    private nonisolated static func continuousBatchRecurrentCheckpointPositions(
        promptTokens: [Int],
        conversationKey: String?,
        hybrid: Bool,
        context: ModelContext
    ) -> [Int] {
        guard nonEmpty(conversationKey) != nil else { return [] }
        return ConversationCache.recurrentCheckpointPositions(
            promptTokenIds: promptTokens.map(Int32.init),
            imStartTokenID: context.tokenizer.convertTokenToId("<|im_start|>").map(Int32.init),
            hybrid: hybrid,
            decode: { context.tokenizer.decode(tokenIds: $0) })
    }

    /// The tokens a batched hybrid entry commits: the canonical list cut to the
    /// length its attention layers cover, so `begin`'s trim lands exactly on a
    /// checkpoint. Nil if the canonical list is shorter (never expected).
    nonisolated static func serialConversationCacheCommitTokens(
        canonicalTokens: [Int32],
        coveredTokenCount: Int
    ) -> [Int32]? {
        guard coveredTokenCount <= canonicalTokens.count else { return nil }
        return Array(canonicalTokens.prefix(coveredTokenCount))
    }

    /// Tokenizer decode for CB streaming. Must not take `ModelContainer`:
    /// compiled lockstep already holds that hop, and a per-token `perform`
    /// behind the delivery buffer is what turned longer canary streams into
    /// `internal_error` after the first content chunk.
    struct StreamingDetokenizer: @unchecked Sendable {
        let decode: ([Int]) -> String
    }

    /// A batched streaming row's buyer-visible state (SPEC-038 AC-6c). Each
    /// delivered token runs the serial path's `SerialStreamingTextEmitter`
    /// step over the decode of every token so far, as the serial generate
    /// callback does. Once the serial path would have stopped generating (a
    /// serial tool turn's first complete tool call, or a structured-output
    /// accumulator error) later tokens are ignored and the stop point is kept
    /// so the finalize truncates the row to it.
    final class AttachedPagedKVStreamState: @unchecked Sendable {
        private let lock = NSLock()
        private var tokenIDs: [Int] = []
        private var emitter: SerialStreamingTextEmitter
        private var recordedError: APIError?
        private var stoppedValue = false
        private var serialStopTokenCountValue: Int?

        init(request: ChatCompletionRequest) {
            emitter = SerialStreamingTextEmitter(request: request)
        }

        /// Returns true the first time the row should stop decoding.
        func step(
            eventTokens: [Int],
            decode: ([Int]) -> String,
            stopTokenFilter: StopTokenFilter,
            requestStops: [String],
            structuredAccumulator: StructuredStreamingContentAccumulator,
            idleState: StructuredStreamingIdleState,
            onChunk: (StreamChunk) -> Void
        ) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !stoppedValue, !eventTokens.isEmpty else { return false }
            tokenIDs.append(contentsOf: eventTokens)
            let candidate = ModelRuntime.streamingSafePrefix(
                decode(tokenIDs),
                stopTokenFilter: stopTokenFilter,
                requestStops: requestStops
            )
            switch emitter.step(
                candidate: candidate,
                structuredAccumulator: structuredAccumulator,
                idleState: idleState,
                onChunk: onChunk
            ) {
            case .more, .requestStop:
                // A buyer stop string ends the row through its stop-token
                // sequences, and the final filter cuts the text at it.
                return false
            case .toolCallComplete:
                stoppedValue = true
                serialStopTokenCountValue = tokenIDs.count
                return true
            case .structuredError:
                stoppedValue = true
                if recordedError == nil {
                    recordedError = structuredAccumulator.error
                }
                return true
            }
        }

        func finish(
            finalText: String,
            parsed: ModelRuntime.ParsedGeneratedOutput,
            structuredAccumulator: StructuredStreamingContentAccumulator,
            idleState: StructuredStreamingIdleState,
            onChunk: (StreamChunk) -> Void
        ) throws {
            lock.lock()
            defer { lock.unlock() }
            try emitter.finish(
                finalText: finalText,
                parsed: parsed,
                structuredAccumulator: structuredAccumulator,
                idleState: idleState,
                onChunk: onChunk
            )
        }

        /// Token count at which the serial path would have stopped a serial
        /// tool turn; nil when it would not have stopped early.
        var serialStopTokenCount: Int? {
            lock.lock()
            defer { lock.unlock() }
            return serialStopTokenCountValue
        }

        func error() -> APIError? {
            lock.lock()
            defer { lock.unlock() }
            return recordedError
        }
    }

    /// A batched non-streaming serial tool turn (SPEC-038 AC-6c): the serial
    /// non-streaming stop test over each delivered token.
    final class ContinuousBatchSerialToolStopState: @unchecked Sendable {
        private let lock = NSLock()
        private var tokenIDs: [Int] = []
        private var observer: NativeToolCallStreamEmitter
        private var stopTokenCountValue: Int?

        init(request: ChatCompletionRequest) {
            observer = NativeToolCallStreamEmitter(
                modelID: request.model,
                allowedFunctionNames: ModelRuntime.toolFunctionNames(from: request.promptSource.tools)
            )
        }

        /// Returns true the first time the row should stop decoding.
        func observe(
            eventTokens: [Int],
            decode: ([Int]) -> String,
            stopTokenFilter: StopTokenFilter,
            requestStops: [String]
        ) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard stopTokenCountValue == nil, !eventTokens.isEmpty else { return false }
            tokenIDs.append(contentsOf: eventTokens)
            guard ModelRuntime.observeSerialToolStop(
                &observer,
                decoded: decode(tokenIDs),
                stopTokenFilter: stopTokenFilter,
                requestStops: requestStops
            ) else { return false }
            stopTokenCountValue = tokenIDs.count
            return true
        }

        var stopTokenCount: Int? {
            lock.lock()
            defer { lock.unlock() }
            return stopTokenCountValue
        }
    }

    struct ContinuousBatchFinalizedRow: Sendable {
        /// Not yet structured-validated: the non-streaming caller runs
        /// `validateStructuredCompletion`, the streaming caller first sends
        /// the held-back text and then `validateStructuredStreamingCompletion`,
        /// each exactly as its serial counterpart does.
        let completion: CompletionResult
        let filteredText: String
        let parsed: ParsedGeneratedOutput
        /// Generated tokens the completion accounts for (model EOS dropped,
        /// truncated to the serial stop point).
        let generatedTokens: [Int]
        /// The row decoded past the serial stop point, so its retained cache
        /// covers tokens the completion does not and must not be committed.
        let truncatedAtSerialStop: Bool
    }

    /// SPEC-038 AC-6c: the one post-generation finalize for a batched row,
    /// streaming and non-streaming. It applies the serial path's response
    /// byte cap, output filters, `parseGeneratedOutput` (tool calls,
    /// SPEC-018 caps, Harmony) and finish-reason rule to the row's text. A
    /// serial tool turn is first truncated to the token at which the serial
    /// path stops generating, so the parsed text and billed tokens match.
    static func finalizeContinuousBatchRow(
        request: ChatCompletionRequest,
        result: ContinuousBatchSchedulerResult,
        modelStopTokenIDs: Set<Int>,
        serialStopTokenCount: Int?,
        promptTokenIDs: [Int32],
        decode: ([Int]) -> String,
        stopTokenFilter: StopTokenFilter,
        generationMilliseconds: Int64,
        modelHash: String?
    ) throws -> ContinuousBatchFinalizedRow {
        // The serial path discards the model's end-of-generation token
        // before counting it; bill and cache the batched row the same way.
        // Harmony `<|return|>`/`<|call|>` are excluded from this set, as
        // they are from the serial stop set: the parser reads and counts them.
        var generatedTokens = droppingTrailingModelStop(
            result.generatedTokens,
            terminalStatus: result.terminalStatus,
            modelStopTokenIDs: modelStopTokenIDs
        )
        var completionTokenCount = result.completionTokens
            - (result.generatedTokens.count - generatedTokens.count)
        var outputTokens = result.outputTokens
        var truncated = false
        if let serialStopTokenCount, serialStopTokenCount < generatedTokens.count {
            completionTokenCount -= generatedTokens.count - serialStopTokenCount
            generatedTokens = Array(generatedTokens.prefix(serialStopTokenCount))
            outputTokens = Array(outputTokens.prefix(serialStopTokenCount))
            truncated = true
        }
        let decoded = decode(outputTokens)
        guard decoded.utf8.count <= ToolCallParser.SPEC018_ARGUMENTS_PER_RESPONSE_BYTE_CAP else {
            throw APIError(
                status: 502,
                message: "Model response exceeded 2097152 bytes",
                type: "upstream_provider_error",
                code: "response_byte_cap_exceeded",
                inferenceRan: true,
                settlementRan: true
            )
        }
        let filtered = applyOutputFilters(
            decoded,
            stopTokenFilter: stopTokenFilter,
            requestStops: request.stop
        )
        // A truncated row ended where the serial path's early stop does,
        // which is never a length finish.
        let lengthTerminal = result.terminalStatus == .length && !truncated
        let parserFinishReason = lengthTerminal && !filtered.hitStop
            ? "length"
            : (filtered.hitStop ? "request_stop" : "stop")
        let parsed = try parseGeneratedOutput(
            filteredText: filtered.text,
            generatedTokenIDs: generatedTokens,
            decode: decode,
            request: request,
            mode: .complete(finishReason: parserFinishReason),
            defaultCompletionTokens: completionTokenCount,
            stopTokenFilter: stopTokenFilter,
            requestStops: request.stop,
            globalHitStop: filtered.hitStop
        )
        let finishReason: String
        if !parsed.toolCalls.isEmpty {
            finishReason = "tool_calls"
        } else if lengthTerminal, !filtered.hitStop, !parsed.hitStop {
            finishReason = "length"
        } else {
            finishReason = "stop"
        }
        let kvCacheBytesReused = cachedPromptUTF8Bytes(
            promptTokenIds: promptTokenIDs,
            cachedPromptTokens: result.cachedPromptTokens,
            decode: decode
        )
        return ContinuousBatchFinalizedRow(
            completion: CompletionResult(
                content: parsed.content,
                finishReason: finishReason,
                promptTokens: promptTokenIDs.count,
                cachedPromptTokens: result.cachedPromptTokens,
                kvCacheBytesReused: kvCacheBytesReused,
                completionTokens: parsed.completionTokens,
                generatedCompletionTokens: parsed.generatedCompletionTokens,
                ttftMilliseconds: nil,
                generationMilliseconds: generationMilliseconds,
                toolCalls: parsed.toolCalls.isEmpty ? nil : parsed.toolCalls,
                modelHashObserved: validObservedModelHash(modelHash),
                settlementDisposition: result.settlementDisposition
            ),
            filteredText: filtered.text,
            parsed: parsed,
            generatedTokens: generatedTokens,
            truncatedAtSerialStop: truncated
        )
    }

    /// SPEC-038 AC-6c: the batched streaming end, in the serial stream's
    /// order: remaining tool-call deltas and held-back content first, then
    /// the structured verdict on the buyer-visible text.
    static func finishContinuousBatchStream(
        _ finalized: ContinuousBatchFinalizedRow,
        state: AttachedPagedKVStreamState,
        request: ChatCompletionRequest,
        structuredAccumulator: StructuredStreamingContentAccumulator,
        idleState: StructuredStreamingIdleState,
        onChunk: (StreamChunk) -> Void
    ) throws -> CompletionResult {
        try state.finish(
            finalText: finalized.filteredText,
            parsed: finalized.parsed,
            structuredAccumulator: structuredAccumulator,
            idleState: idleState,
            onChunk: onChunk
        )
        return try validateStructuredStreamingCompletion(
            finalized.completion,
            request: request,
            buyerVisibleContent: structuredAccumulator.content
        )
    }

    private func serialRouteCanaryCachedHitMissingRetainedHandoff(
        _ lease: ConversationCacheLease?,
        capability: ContinuousBatchingCapability,
        modelHasRecurrentLayers: Bool
    ) async throws -> Bool {
        guard let lease,
              let reason = Self.cachedHitFenceReason(
                  mode: capability.mode,
                  cachedPromptTokens: lease.cachedPromptTokens,
                  hasRetainedPagedKVHandoff: Self.leaseHasUsableRetainedHandoff(
                      lease,
                      modelHasRecurrentLayers: modelHasRecurrentLayers
                  ),
                  cachedTurnsEnabled: continuousBatchingCachedTurns,
                  cachedTurnsAccepted: continuousBatchingCachedTurns
                      && continuousBatchingRequestedTuple().map {
                          continuousBatchingAcceptanceCoverage.coversCachedTurns($0)
                      } == true
              )
        else {
            return false
        }
        // A retained entry (hybrid or not) cannot serve the serial path, so
        // this discards it and the serial request misses; a serial-format entry
        // is put back for the serial path to reuse.
        await conversationCache.abortForSerialFallback(lease)
        let blocked = ContinuousBatchingCapability(
            mode: capability.mode,
            maxActiveRows: capability.maxActiveRows,
            queueLimit: capability.queueLimit,
            descriptor: capability.descriptor,
            unsupportedReason: reason
        )
        // Strict `.on` must fail closed with the named reason (FR-CB8). Canary
        // serial-routes the same AC-26 fence with reason-coded telemetry.
        try ContinuousBatchingPolicy.validateStrictStartup(blocked)
        ContinuousBatchingPolicy.logSerialRouteIfNeeded(blocked)
        return true
    }

    static func canaryShouldSerialRouteCachedHitMissingRetainedHandoff(
        mode: ContinuousBatchingMode,
        cachedPromptTokens: Int,
        hasRetainedPagedKVHandoff: Bool,
        cachedTurnsEnabled: Bool = false,
        cachedTurnsAccepted: Bool = false
    ) -> Bool {
        cachedHitFenceReason(
            mode: mode,
            cachedPromptTokens: cachedPromptTokens,
            hasRetainedPagedKVHandoff: hasRetainedPagedKVHandoff,
            cachedTurnsEnabled: cachedTurnsEnabled,
            cachedTurnsAccepted: cachedTurnsAccepted
        ) != nil
    }

    /// AC-26 fence for a positive cached-token hit. It stays out of the
    /// scheduler unless the operator opted into `continuous_batching_cached_turns`,
    /// the lease carries a usable retained handoff, AND the accepted tuple
    /// covering this runtime records `cached_turns_accepted` (the per-tuple,
    /// revision-bound packaged proof). A retained handoff alone is capability,
    /// not authorization. Nil means the request may enter the scheduler.
    static func cachedHitFenceReason(
        mode: ContinuousBatchingMode,
        cachedPromptTokens: Int,
        hasRetainedPagedKVHandoff: Bool,
        cachedTurnsEnabled: Bool,
        cachedTurnsAccepted: Bool
    ) -> ContinuousBatchingUnsupportedReason? {
        guard mode != .off, cachedPromptTokens > 0 else { return nil }
        guard cachedTurnsEnabled, hasRetainedPagedKVHandoff else { return .stickyCacheHandoffUnavailable }
        return cachedTurnsAccepted ? nil : .cachedTurnsNotAccepted
    }

    /// A hybrid retained delivery is resumable only from a recurrent checkpoint;
    /// one without any is discarded instead of committed as an entry no turn
    /// could resume (SPEC-038 AC-26).
    nonisolated static func retainedCacheIsCommittable(
        _ retainedCache: ContinuousBatchRetainedCache,
        modelHasRecurrentLayers: Bool
    ) -> Bool {
        !modelHasRecurrentLayers || !retainedCache.recurrentCheckpoints.isEmpty
    }

    /// A retained paged-KV sequence, plus on a hybrid model the recurrent
    /// checkpoint at exactly the cached length (SPEC-038 AC-26).
    nonisolated static func leaseHasUsableRetainedHandoff(
        _ lease: ConversationCacheLease,
        modelHasRecurrentLayers: Bool
    ) -> Bool {
        guard lease.reusableCache?.retainedPagedKVSequence != nil else { return false }
        guard modelHasRecurrentLayers else { return true }
        return lease.recurrentCheckpoint?.tokenCount == lease.cachedPromptTokens
    }

    /// The stored checkpoints a hybrid cached turn hands the scheduler: every
    /// one at or below the cached length (they are a prefix of this prompt).
    /// Empty unless the lease resumes a retained hybrid entry.
    nonisolated static func retainedRecurrentCheckpoints(
        for lease: ConversationCacheLease?
    ) -> [RecurrentStateCheckpoint] {
        guard let lease,
              lease.recurrentCheckpoint != nil,
              let reusable = lease.reusableCache,
              reusable.retainedPagedKVSequence != nil
        else { return [] }
        return reusable.recurrentCheckpoints.filter { $0.tokenCount <= lease.cachedPromptTokens }
    }

    private func attachedContinuousBatchCompletion(
        request: ChatCompletionRequest,
        snapshot: RuntimeSnapshot,
        capability: ContinuousBatchingCapability,
        completionStartedAt: Date,
        shouldCancel: @escaping @Sendable () -> Bool,
        drainCancelled: DrainCancelToken
    ) async throws -> CompletionResult? {
        guard capability.isRequested,
              capability.unsupportedReason == nil,
              !capability.shouldUseSerialPath,
              case .attached = pagedKVAttachDecision
        else {
            return nil
        }
        guard let scheduler = continuousBatchScheduler else {
            throw Self.attachedPagedKVUnavailableError(code: "continuous_batching_scheduler_unavailable")
        }
        guard let schedulerRequestID = Self.schedulerRequestID(for: request) else {
            throw Self.attachedPagedKVUnavailableError(code: ContinuousBatchingUnsupportedReason.stableRequestIDUnavailable.apiCode)
        }
        guard let container = snapshot.container else {
            throw APIError(status: 503, message: "Model not loaded", type: "server_error", code: "model_not_loaded")
        }

        let maxContextTokens = maxContextTokens
        let stopTokenFilter = stopTokenFilter
        let templateSupportsThinkingToggle = snapshot.templateSupportsThinkingToggle
        CBTrace.log(schedulerRequestID, "rt_cb_prepare")
        let (prepared, detokenizer) = try await container.perform { context -> (ContinuousBatchPreparedRequest, StreamingDetokenizer) in
            try drainCancelled.check()
            try Task.checkCancellation()
            let input = try Self.userInput(
                for: request,
                templateSupportsThinkingToggle: templateSupportsThinkingToggle

exec
/bin/bash -lc "sed -n '4328,4785p' phase3-binary/Sources/macprovider-cli/ModelRuntime.swift" in /Users/augstar/macprovider-1646-rest
 succeeded in 0ms:
        }
        guard let schedulerRequestID = Self.schedulerRequestID(for: request) else {
            throw Self.attachedPagedKVUnavailableError(code: ContinuousBatchingUnsupportedReason.stableRequestIDUnavailable.apiCode)
        }
        guard let container = snapshot.container else {
            throw APIError(status: 503, message: "Model not loaded", type: "server_error", code: "model_not_loaded")
        }

        let maxContextTokens = maxContextTokens
        let stopTokenFilter = stopTokenFilter
        let templateSupportsThinkingToggle = snapshot.templateSupportsThinkingToggle
        CBTrace.log(schedulerRequestID, "rt_cb_prepare")
        let (prepared, detokenizer) = try await container.perform { context -> (ContinuousBatchPreparedRequest, StreamingDetokenizer) in
            try drainCancelled.check()
            try Task.checkCancellation()
            let input = try Self.userInput(
                for: request,
                templateSupportsThinkingToggle: templateSupportsThinkingToggle
            )
            let lmInput = try await context.processor.prepare(input: input)
            let promptTokens = lmInput.text.tokens.asArray(Int32.self).map(Int.init)
            try Self.validatePromptTokenCount(promptTokens.count, maxContextTokens: maxContextTokens)
            let stopTokenSequences = Self.continuousBatchStopTokenSequences(
                requestStops: request.stop,
                context: context
            )
            let tokenizer = context.tokenizer
            // Only keyed requests can hold or reuse conversation state.
            let hybrid = Self.nonEmpty(request.conversationKey) != nil
                && ConversationCacheLayers.hasRecurrentLayers(context.model.newCache(parameters: nil))
            return (
                ContinuousBatchPreparedRequest(
                    promptTokens: promptTokens,
                    stopTokenSequences: stopTokenSequences,
                    modelStopTokenIDs: Self.generationStopTokenIDs(
                        for: Self.harmonyTerminalPreservingContext(from: context, modelID: request.model)
                    ),
                    recurrentCheckpointPositions: Self.continuousBatchRecurrentCheckpointPositions(
                        promptTokens: promptTokens,
                        conversationKey: request.conversationKey,
                        hybrid: hybrid,
                        context: context
                    ),
                    modelHasRecurrentLayers: hybrid
                ),
                StreamingDetokenizer { tokenizer.decode(tokenIds: $0) }
            )
        }

        try drainCancelled.check()
        try Task.checkCancellation()
        if shouldCancel() { throw CancellationError() }
        let maxOutputTokens = request.maxTokens ?? max(1, maxContextTokens - prepared.promptTokens.count)
        let preparedPromptTokenIDs = prepared.promptTokens.map(Int32.init)
        let batchKVBits = Self.effectiveKVBits(
            configured: kvBitsOverride,
            conversationKey: request.conversationKey
        )
        let lease = await conversationCache.begin(
            conversationKey: request.conversationKey,
            incomingTokens: preparedPromptTokenIDs,
            modelID: request.model,
            kvBits: batchKVBits,
            allowRetainedPagedKVHandoff: true
        )
        CBTrace.log(schedulerRequestID, "rt_cb_lease cached=\(lease?.cachedPromptTokens ?? -1)")
        if try await serialRouteCanaryCachedHitMissingRetainedHandoff(
            lease,
            capability: capability,
            modelHasRecurrentLayers: prepared.modelHasRecurrentLayers
        ) {
            return nil
        }
        // SPEC-038 AC-6c: a serial tool turn stops where the serial path
        // stops generating (its first complete valid tool call).
        let serialToolStop = Self.serialToolStopApplies(request)
            ? ContinuousBatchSerialToolStopState(request: request)
            : nil
        let requestStops = request.stop
        let result: ContinuousBatchSchedulerResult
        do {
            CBTrace.log(schedulerRequestID, "rt_cb_submit")
            result = try await Self.withDrainAndClientCancellation(drainCancelled, shouldCancel: shouldCancel) {
                try await scheduler.submit(ContinuousBatchSchedulerRequest(
                    id: schedulerRequestID,
                    conversationKey: request.conversationKey ?? "",
                    promptTokens: prepared.promptTokens,
                    maxOutputTokens: maxOutputTokens,
                    stopTokenSequences: prepared.stopTokenSequences,
                    samplerSeed: ContinuousBatchRowSampler.requestSeed(requestID: schedulerRequestID),
                    temperature: request.temperature,
                    topP: request.topP,
                    presencePenalty: request.presencePenalty,
                    frequencyPenalty: request.frequencyPenalty,
                    cachedPromptTokens: lease?.cachedPromptTokens ?? 0,
                    retainedPagedKVSequence: lease?.reusableCache?.retainedPagedKVSequence,
                    recurrentCheckpointPositions: prepared.recurrentCheckpointPositions,
                    retainedRecurrentCheckpoints: Self.retainedRecurrentCheckpoints(for: lease)
                ), tokenSink: { event in
                    guard let serialToolStop else { return }
                    if serialToolStop.observe(
                        eventTokens: event.replayTokens ?? [event.token],
                        decode: detokenizer.decode,
                        stopTokenFilter: stopTokenFilter,
                        requestStops: requestStops
                    ) {
                        Task { await scheduler.stopEarly(requestID: schedulerRequestID) }
                    }
                })
            }
        } catch {
            if let lease {
                await conversationCache.abort(lease)
            }
            // SPEC-038 AC-25: one shared scheduler-error map, so the
            // non-streaming and streaming paths cannot drift.
            CBTrace.log(schedulerRequestID, "rt_cb_threw \(type(of: error))")
            throw (error as? ContinuousBatchSchedulerError)?.asAPIError() ?? error
        }
        CBTrace.log(schedulerRequestID, "rt_cb_returned status=\(result.terminalStatus)")
        do {
            try drainCancelled.check()
            try Task.checkCancellation()
            if shouldCancel() { throw CancellationError() }
            guard result.terminalStatus == .stop || result.terminalStatus == .length else {
                throw Self.terminalFailureError(code: result.errorCode ?? "continuous_batching_request_failed")
            }
            let completionEndedAt = Date()
            let finalized = try await container.perform { context in
                try Self.finalizeContinuousBatchRow(
                    request: request,
                    result: result,
                    modelStopTokenIDs: prepared.modelStopTokenIDs,
                    serialStopTokenCount: serialToolStop?.stopTokenCount,
                    promptTokenIDs: preparedPromptTokenIDs,
                    decode: { context.tokenizer.decode(tokenIds: $0) },
                    stopTokenFilter: stopTokenFilter,
                    generationMilliseconds: Int64(completionEndedAt.timeIntervalSince(completionStartedAt) * 1000),
                    modelHash: snapshot.modelHash
                )
            }
            let completion = try Self.validateStructuredCompletion(finalized.completion, request: request)
            let generatedTokens = finalized.generatedTokens
            if !finalized.truncatedAtSerialStop,
               let lease, let retainedCache = result.retainedCache,
               Self.retainedCacheIsCommittable(
                   retainedCache,
                   modelHasRecurrentLayers: prepared.modelHasRecurrentLayers
               ) {
                await conversationCache.commit(
                    lease,
                    cache: ConversationCacheLayers(
                        retainedCache.layers,
                        retainedPagedKVSequence: retainedCache.retainedSequence,
                        discardRetainedPagedKVSequence: { retained, key in
                            await scheduler.discardRetainedCache(retained, conversationKey: key)
                        },
                        recurrentCheckpoints: retainedCache.recurrentCheckpoints
                    ),
                    fullTokens: preparedPromptTokenIDs + generatedTokens.map(Int32.init)
                )
                await scheduler.acknowledgeRetainedCacheDelivery(retainedCache)
            } else if !finalized.truncatedAtSerialStop,
                      let lease, let serialCache = result.serialConversationCache,
                      let fullTokens = Self.serialConversationCacheCommitTokens(
                          canonicalTokens: preparedPromptTokenIDs + generatedTokens.map(Int32.init),
                          coveredTokenCount: serialCache.tokenCount
                      ) {
                // SPEC-038 FR-CB4 hybrid first turn: the next keyed turn serial-
                // routes (AC-26) and reuses this entry from its checkpoints.
                await conversationCache.commit(
                    lease,
                    cache: ConversationCacheLayers(
                        serialCache.layers,
                        recurrentCheckpoints: serialCache.recurrentCheckpoints
                    ),
                    fullTokens: fullTokens
                )
            } else if let retainedCache = result.retainedCache {
                await scheduler.cancelRetainedCacheDelivery(
                    retainedCache,
                    conversationKey: result.conversationKey
                )
                if let lease {
                    await conversationCache.abort(lease)
                }
            } else if let lease {
                await conversationCache.abort(lease)
            }
            return completion
        } catch {
            if let retainedCache = result.retainedCache {
                await scheduler.cancelRetainedCacheDelivery(
                    retainedCache,
                    conversationKey: result.conversationKey
                )
            }
            if let lease {
                await conversationCache.abort(lease)
            }
            throw error
        }
    }

    nonisolated static func schedulerRequestID(for request: ChatCompletionRequest) -> String? {
        nonEmpty(request.requestID)
    }

    private func attachedContinuousBatchStreamingCompletion(
        request: ChatCompletionRequest,
        snapshot: RuntimeSnapshot,
        capability: ContinuousBatchingCapability,
        completionStartedAt: Date,
        shouldCancel: @escaping @Sendable () -> Bool,
        drainCancelled: DrainCancelToken,
        structuredAccumulator: StructuredStreamingContentAccumulator,
        idleState: StructuredStreamingIdleState,
        idleCancellation: DrainCancelToken,
        onChunk: @escaping @Sendable (StreamChunk) -> Void
    ) async throws -> CompletionResult? {
        guard capability.isRequested,
              capability.unsupportedReason == nil,
              !capability.shouldUseSerialPath,
              case .attached = pagedKVAttachDecision
        else {
            return nil
        }
        guard let scheduler = continuousBatchScheduler else {
            throw Self.attachedPagedKVUnavailableError(code: "continuous_batching_scheduler_unavailable")
        }
        guard let schedulerRequestID = Self.schedulerRequestID(for: request) else {
            throw Self.attachedPagedKVUnavailableError(code: ContinuousBatchingUnsupportedReason.stableRequestIDUnavailable.apiCode)
        }
        guard let container = snapshot.container else {
            throw APIError(status: 503, message: "Model not loaded", type: "server_error", code: "model_not_loaded")
        }

        let maxContextTokens = maxContextTokens
        let stopTokenFilter = stopTokenFilter
        let templateSupportsThinkingToggle = snapshot.templateSupportsThinkingToggle
        let requestStops = request.stop
        let (prepared, detokenizer) = try await container.perform { context -> (ContinuousBatchPreparedRequest, StreamingDetokenizer) in
            try drainCancelled.check()
            try Task.checkCancellation()
            let input = try Self.userInput(
                for: request,
                templateSupportsThinkingToggle: templateSupportsThinkingToggle
            )
            let lmInput = try await context.processor.prepare(input: input)
            let promptTokens = lmInput.text.tokens.asArray(Int32.self).map(Int.init)
            try Self.validatePromptTokenCount(promptTokens.count, maxContextTokens: maxContextTokens)
            let stopTokenSequences = Self.continuousBatchStopTokenSequences(
                requestStops: requestStops,
                context: context
            )
            let tokenizer = context.tokenizer
            // Only keyed requests can hold or reuse conversation state.
            let hybrid = Self.nonEmpty(request.conversationKey) != nil
                && ConversationCacheLayers.hasRecurrentLayers(context.model.newCache(parameters: nil))
            return (
                ContinuousBatchPreparedRequest(
                    promptTokens: promptTokens,
                    stopTokenSequences: stopTokenSequences,
                    modelStopTokenIDs: Self.generationStopTokenIDs(
                    for: Self.harmonyTerminalPreservingContext(from: context, modelID: request.model)
                ),
                    recurrentCheckpointPositions: Self.continuousBatchRecurrentCheckpointPositions(
                        promptTokens: promptTokens,
                        conversationKey: request.conversationKey,
                        hybrid: hybrid,
                        context: context
                    ),
                    modelHasRecurrentLayers: hybrid
                ),
                StreamingDetokenizer { tokenizer.decode(tokenIds: $0) }
            )
        }

        try drainCancelled.check()
        try Task.checkCancellation()
        if shouldCancel() { throw CancellationError() }
        let streamState = AttachedPagedKVStreamState(request: request)
        let maxOutputTokens = request.maxTokens ?? max(1, maxContextTokens - prepared.promptTokens.count)
        let preparedPromptTokenIDs = prepared.promptTokens.map(Int32.init)
        let batchKVBits = Self.effectiveKVBits(
            configured: kvBitsOverride,
            conversationKey: request.conversationKey
        )
        let lease = await conversationCache.begin(
            conversationKey: request.conversationKey,
            incomingTokens: preparedPromptTokenIDs,
            modelID: request.model,
            kvBits: batchKVBits,
            allowRetainedPagedKVHandoff: true
        )
        if try await serialRouteCanaryCachedHitMissingRetainedHandoff(
            lease,
            capability: capability,
            modelHasRecurrentLayers: prepared.modelHasRecurrentLayers
        ) {
            return nil
        }
        let result: ContinuousBatchSchedulerResult
        do {
            // The SPEC-019 structured idle timeout ends the row as it ends the
            // serial generate loop.
            result = try await Self.withDrainAndClientCancellation(
                drainCancelled,
                shouldCancel: { shouldCancel() || idleCancellation.isFired }
            ) {
                try await scheduler.submit(ContinuousBatchSchedulerRequest(
                    id: schedulerRequestID,
                    conversationKey: request.conversationKey ?? "",
                    promptTokens: prepared.promptTokens,
                    maxOutputTokens: maxOutputTokens,
                    stopTokenSequences: prepared.stopTokenSequences,
                    samplerSeed: ContinuousBatchRowSampler.requestSeed(requestID: schedulerRequestID),
                    temperature: request.temperature,
                    topP: request.topP,
                    presencePenalty: request.presencePenalty,
                    frequencyPenalty: request.frequencyPenalty,
                    cachedPromptTokens: lease?.cachedPromptTokens ?? 0,
                    retainedPagedKVSequence: lease?.reusableCache?.retainedPagedKVSequence,
                    recurrentCheckpointPositions: prepared.recurrentCheckpointPositions,
                    retainedRecurrentCheckpoints: Self.retainedRecurrentCheckpoints(for: lease)
                ), tokenSink: { event in
                    guard !idleCancellation.isFired else { return }
                    if streamState.step(
                        eventTokens: event.replayTokens ?? [event.token],
                        decode: detokenizer.decode,
                        stopTokenFilter: stopTokenFilter,
                        requestStops: requestStops,
                        structuredAccumulator: structuredAccumulator,
                        idleState: idleState,
                        onChunk: onChunk
                    ) {
                        Task { await scheduler.stopEarly(requestID: schedulerRequestID) }
                    }
                })
            }
        } catch {
            if let lease {
                await conversationCache.abort(lease)
            }
            // SPEC-038 AC-25: one shared scheduler-error map, so the
            // streaming and non-streaming paths cannot drift.
            throw (error as? ContinuousBatchSchedulerError)?.asAPIError() ?? error
        }
        do {
            if let error = streamState.error() {
                throw error
            }
            try drainCancelled.check()
            try Task.checkCancellation()
            if shouldCancel() { throw CancellationError() }
            guard result.terminalStatus == .stop || result.terminalStatus == .length else {
                throw Self.terminalFailureError(code: result.errorCode ?? "continuous_batching_request_failed")
            }
            let completionEndedAt = Date()
            let finalized = try await container.perform { context in
                try Self.finalizeContinuousBatchRow(
                    request: request,
                    result: result,
                    modelStopTokenIDs: prepared.modelStopTokenIDs,
                    serialStopTokenCount: streamState.serialStopTokenCount,
                    promptTokenIDs: preparedPromptTokenIDs,
                    decode: { context.tokenizer.decode(tokenIds: $0) },
                    stopTokenFilter: stopTokenFilter,
                    generationMilliseconds: Int64(completionEndedAt.timeIntervalSince(completionStartedAt) * 1000),
                    modelHash: snapshot.modelHash
                )
            }
            // #1690 E2E-F13: the stream held back an incomplete UTF-8 tail
            // and any stop-string prefix; the serial stream's end sends the
            // remainder as the final text renders it, so the buyer's bytes
            // equal the receipt's.
            let validated = try Self.finishContinuousBatchStream(
                finalized,
                state: streamState,
                request: request,
                structuredAccumulator: structuredAccumulator,
                idleState: idleState,
                onChunk: onChunk
            )
            let generatedTokens = finalized.generatedTokens
            if !finalized.truncatedAtSerialStop,
               let lease, let retainedCache = result.retainedCache,
               Self.retainedCacheIsCommittable(
                   retainedCache,
                   modelHasRecurrentLayers: prepared.modelHasRecurrentLayers
               ) {
                await conversationCache.commit(
                    lease,
                    cache: ConversationCacheLayers(
                        retainedCache.layers,
                        retainedPagedKVSequence: retainedCache.retainedSequence,
                        discardRetainedPagedKVSequence: { retained, key in
                            await scheduler.discardRetainedCache(retained, conversationKey: key)
                        },
                        recurrentCheckpoints: retainedCache.recurrentCheckpoints
                    ),
                    fullTokens: preparedPromptTokenIDs + generatedTokens.map(Int32.init)
                )
                await scheduler.acknowledgeRetainedCacheDelivery(retainedCache)
            } else if !finalized.truncatedAtSerialStop,
                      let lease, let serialCache = result.serialConversationCache,
                      let fullTokens = Self.serialConversationCacheCommitTokens(
                          canonicalTokens: preparedPromptTokenIDs + generatedTokens.map(Int32.init),
                          coveredTokenCount: serialCache.tokenCount
                      ) {
                // SPEC-038 FR-CB4 hybrid first turn: the next keyed turn serial-
                // routes (AC-26) and reuses this entry from its checkpoints.
                await conversationCache.commit(
                    lease,
                    cache: ConversationCacheLayers(
                        serialCache.layers,
                        recurrentCheckpoints: serialCache.recurrentCheckpoints
                    ),
                    fullTokens: fullTokens
                )
            } else if let retainedCache = result.retainedCache {
                await scheduler.cancelRetainedCacheDelivery(
                    retainedCache,
                    conversationKey: result.conversationKey
                )
                if let lease {
                    await conversationCache.abort(lease)
                }
            } else if let lease {
                await conversationCache.abort(lease)
            }
            return validated
        } catch {
            if let retainedCache = result.retainedCache {
                await scheduler.cancelRetainedCacheDelivery(
                    retainedCache,
                    conversationKey: result.conversationKey
                )
            }
            if let lease {
                await conversationCache.abort(lease)
            }
            throw error
        }
    }

    /// SPEC-038 AC-25: a non-terminal scheduler *result*, as distinct from a
    /// thrown scheduler error. Most carried codes are pre-inference, so they
    /// take the `inferenceRan: false` shape. The one that is not is
    /// post-token delivery backpressure — the row was decoding and the buyer
    /// may already hold partial output — so it reuses the single
    /// `.deliveryBackpressure` mapping rather than a second, divergent copy.
    private nonisolated static func terminalFailureError(code: String) -> APIError {
        if code == ContinuousBatchSchedulerError.deliveryBackpressureCode,
           let mapped = ContinuousBatchSchedulerError.deliveryBackpressure.asAPIError() {
            return mapped
        }
        return attachedPagedKVUnavailableError(code: code)

exec
/bin/bash -lc "sed -n '2180,2285p;2690,2820p' phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift && sed -n '7500,7665p' phase3-binary/Sources/macprovider-cli/ModelRuntime.swift" in /Users/augstar/macprovider-1646-rest
 succeeded in 0ms:
                    status: .requestFailed,
                    errorCode: released
                        ? "continuous_batching_invalid_decode_token"
                        : "continuous_batching_cleanup_failed"
                )
                if !released { return }
            }
        }
        let stillActive = Set(activeDecode.keys)
        await applyDecodeOutputs(outputs.filter {
            healthyOutputIDs.contains($0.requestID)
                && stillActive.contains($0.requestID)
                && !invalidOutputIDs.contains($0.requestID)
        })
    }

    private func applyDecodeOutputs(_ outputs: [ContinuousBatchDecodeOutput]) async {
        var byID: [String: ContinuousBatchDecodeOutput] = [:]
        for output in outputs {
            byID[output.requestID] = output
        }
        var maxSteps = 1
        for output in outputs {
            let count = output.tokens.isEmpty ? 1 : output.tokens.count
            maxSteps = max(maxSteps, count)
        }
        for step in 0..<maxSteps {
            for id in activeDecode.keys.sorted(by: admissionPrecedes) {
                guard let row = activeDecode[id], let output = byID[id] else { continue }
                let sampled = output.tokens
                guard step < sampled.count else { continue }
                await applyToken(sampled[step], to: row)
                if cleanupFailedClosed { return }
            }
        }
    }

    private func applyToken(_ token: Int, to initialRow: Row) async {
        guard var row = activeDecode[initialRow.request.id] else { return }
        row.generatedTokens.append(token)
        row.currentToken = token
        row.pendingOutputTokens.append(token)

        let terminalStatus: ContinuousBatchSchedulerTerminalStatus?
        if let stopLength = matchingStopLength(
            row.generatedTokens,
            stopSequences: row.request.stopTokenSequences
        ) {
            guard stopLength <= row.pendingOutputTokens.count else {
                activeDecode.removeValue(forKey: row.request.id)
                let released = await release(row.handle)
                finish(
                    row,
                    status: .requestFailed,
                    errorCode: released
                        ? "continuous_batching_stop_filter_state_invalid"
                        : "continuous_batching_cleanup_failed"
                )
                return
            }
            row.pendingOutputTokens.removeLast(stopLength)
            terminalStatus = .stop
        } else if earlyStopIDs.contains(row.request.id) {
            terminalStatus = .stop
        } else if row.generatedTokens.count >= row.request.maxOutputTokens {
            terminalStatus = .length
        } else {
            terminalStatus = nil
        }

        let visibleTokens: [Int]
        if terminalStatus != nil {
            visibleTokens = row.pendingOutputTokens
            row.pendingOutputTokens.removeAll(keepingCapacity: true)
        } else {
            var ready: [Int] = []
            while let first = row.pendingOutputTokens.first,
                  !isPotentialStopPrefix(
                      row.pendingOutputTokens,
                      stopSequences: row.request.stopTokenSequences
                  ) {
                ready.append(first)
                row.pendingOutputTokens.removeFirst()
            }
            visibleTokens = ready
        }

        let firstVisibleIndex = row.outputTokens.count
        row.outputTokens.append(contentsOf: visibleTokens)
        activeDecode[row.request.id] = row
        CBTrace.log(row.request.id, "sch_active")
        if !deliverVisibleTokens(
            visibleTokens,
            firstIndex: firstVisibleIndex,
            row: row
        ) {
            activeDecode.removeValue(forKey: row.request.id)
            let released = await release(row.handle)
            // Post-token, like the `.deliveryBackpressure` thrown at the
            // waiter above: this row was decoding when its last consumer
            // refused an event. The terminal result is replayable to a later
            // duplicate of the same request id, so it must not carry the
            // pre-admission code — that one is retryable and this is not.
            finish(
                row,
                status: .requestFailed,
        }
        for id in promptOrder {
            guard let row = activePrompt.removeValue(forKey: id) else { continue }
            _ = await release(row.handle)
            finish(row, status: .requestFailed, errorCode: "continuous_batching_scheduler_failed_closed")
        }
        promptOrder.removeAll()
        for id in activeDecode.keys.sorted() {
            guard let row = activeDecode.removeValue(forKey: id) else { continue }
            _ = await release(row.handle)
            finish(row, status: .requestFailed, errorCode: "continuous_batching_scheduler_failed_closed")
        }
        cancelledIDs.removeAll()
    }

    private func failClosedIfNeeded() async -> Bool {
        guard cleanupFailedClosed else { return false }
        await processCancellations()
        await failRemainingAfterCleanupFailure()
        return true
    }

    private func finishQueued(
        _ request: ContinuousBatchSchedulerRequest,
        status: ContinuousBatchSchedulerTerminalStatus,
        errorCode: String?
    ) async {
        // Every pre-admission completion funnels through here. A cancel recorded
        // while the request was out of `waiting` (mid-admission, e.g. during a
        // retained install) wins over the admission outcome: nothing ran for
        // it, and `requestFailed`/`rejected` would contradict the caller's
        // cancel. A cleanup failure stays visible as such.
        await discardUnacceptedRetainedCache(for: request)
        // Checked after the last await and with none before the result is
        // built, so a cancel recorded during the discard above wins too.
        var status = status
        var errorCode = errorCode
        if status != .cancelled,
           errorCode != "continuous_batching_cleanup_failed",
           cancelledIDs.remove(request.id) != nil {
            status = .cancelled
            errorCode = "request_cancelled"
        }
        let result = ContinuousBatchSchedulerResult(
            requestID: request.id,
            conversationKey: request.conversationKey,
            generatedTokens: [],
            outputTokens: [],
            promptTokens: 0,
            completionTokens: 0,
            emittedTokens: 0,
            cachedPromptTokens: 0,
            terminalStatus: status,
            errorCode: errorCode,
            snapshot: nil,
            settlementDisposition: .notEligible,
            retainedCache: nil
        )
        complete(requestID: request.id, result: result)
    }

    private func discardUnacceptedRetainedCache(for request: ContinuousBatchSchedulerRequest) async {
        guard let retained = request.retainedPagedKVSequence else { return }
        await discardRetainedCache(retained)
    }

    private func scheduleDiscardUnacceptedRetainedCache(for request: ContinuousBatchSchedulerRequest) {
        guard let retained = request.retainedPagedKVSequence else { return }
        Task { await self.discardRetainedCache(retained) }
    }

    private func finish(
        _ row: Row,
        status: ContinuousBatchSchedulerTerminalStatus,
        errorCode: String?,
        serialConversationCache: ContinuousBatchSerialConversationCache? = nil
    ) {
        earlyStopIDs.remove(row.request.id)
        record(status == .cancelled ? .cancelled : .stopped)
        let isSuccessful = status == .stop || status == .length
        let outputTokens = isSuccessful ? row.outputTokens : []
        let result = ContinuousBatchSchedulerResult(
            requestID: row.request.id,
            conversationKey: row.request.conversationKey,
            generatedTokens: isSuccessful ? row.generatedTokens : [],
            outputTokens: outputTokens,
            promptTokens: row.request.promptTokens.count,
            completionTokens: isSuccessful ? row.generatedTokens.count : 0,
            emittedTokens: row.outputTokens.count,
            cachedPromptTokens: row.request.cachedPromptTokens,
            terminalStatus: status,
            errorCode: errorCode,
            snapshot: row.snapshot,
            settlementDisposition: isSuccessful ? .eligibleOwner : .notEligible,
            retainedCache: nil,
            serialConversationCache: isSuccessful ? serialConversationCache : nil
        )
        complete(requestID: row.request.id, result: result)
    }

    private func finish(
        _ row: Row,
        status: ContinuousBatchSchedulerTerminalStatus,
        errorCode: String?,
        retainedCache: ContinuousBatchRetainedCache?
    ) {
        earlyStopIDs.remove(row.request.id)
        record(status == .cancelled ? .cancelled : .stopped)
        let isSuccessful = status == .stop || status == .length
        let outputTokens = isSuccessful ? row.outputTokens : []
        let result = ContinuousBatchSchedulerResult(
            requestID: row.request.id,
            conversationKey: row.request.conversationKey,
            generatedTokens: isSuccessful ? row.generatedTokens : [],
            outputTokens: outputTokens,
            promptTokens: row.request.promptTokens.count,
            completionTokens: isSuccessful ? row.generatedTokens.count : 0,
            emittedTokens: row.outputTokens.count,
            cachedPromptTokens: row.request.cachedPromptTokens,
            terminalStatus: status,
            errorCode: errorCode,
            snapshot: row.snapshot,
            settlementDisposition: isSuccessful ? .eligibleOwner : .notEligible,
            retainedCache: isSuccessful ? retainedCache : nil
        )
        complete(requestID: row.request.id, result: result)
    }

    private func complete(requestID: String, result: ContinuousBatchSchedulerResult) {
        CBTrace.log(requestID, "sch_complete status=\(result.terminalStatus) waiters=\(requestWaiters[requestID]?.count ?? 0) stopping=\(stoppingActiveWaiters.values.contains(where: { $0.requestID == requestID }))")
        endQueueWait(requestID: requestID)
        case .string(let choice):
            // OpenAI/Pi send "required". We do not force a call, but rejecting it
            // with 400/502 is worse than treating it as auto.
            return choice == "auto" || choice == "required"
        case .null:
            return true
        default:
            return false
        }
    }
}

/// The serial streaming path's buyer-visible text step for non-Harmony output:
/// incremental tool-call deltas (SPEC-018), assistant-content suppression once
/// a tool call opens, the SPEC-019 structured-content accumulator, and the
/// serial-tool-turn stop. The serial `stream` path and the continuous-batching
/// stream sink (SPEC-038 AC-6c) both drive this one type, so a batched
/// tool-bearing or structured-output row emits the serial SSE sequence.
struct SerialStreamingTextEmitter {
    enum Step: Equatable {
        case more
        /// A buyer `stop` string matched in the decoded text.
        case requestStop
        /// A serial tool turn completed its first valid tool call.
        case toolCallComplete
        /// The structured-output accumulator refused the delta (its error is
        /// held by the accumulator).
        case structuredError
    }

    private let streamToolsIncrementally: Bool
    private let stopsAfterFirstCompleteToolCall: Bool
    private var toolStreamer: NativeToolCallStreamEmitter
    private(set) var emittedText = ""

    init(request: ChatCompletionRequest) {
        streamToolsIncrementally = ModelRuntime.hasEnabledTools(request.promptSource.tools)
            && !HarmonyResponseParser.isHarmonyModelID(request.model)
        stopsAfterFirstCompleteToolCall = request.stopsAfterFirstCompleteToolCall
        toolStreamer = NativeToolCallStreamEmitter(
            modelID: request.model,
            allowedFunctionNames: ModelRuntime.toolFunctionNames(from: request.promptSource.tools)
        )
    }

    /// One decoded prefix of the generation (`streamingSafePrefix` of every
    /// token so far).
    mutating func step(
        candidate: (text: String, hitStop: Bool),
        structuredAccumulator: StructuredStreamingContentAccumulator,
        idleState: StructuredStreamingIdleState,
        onChunk: (StreamChunk) -> Void
    ) -> Step {
        if streamToolsIncrementally {
            for event in toolStreamer.observe(candidate.text) {
                onChunk(event)
            }
            if !toolStreamer.suppressesAssistantContent {
                let safe = toolStreamer.visibleContentPrefix(of: candidate.text)
                let delta = ModelRuntime.streamDelta(from: emittedText, to: safe)
                if !delta.isEmpty {
                    if structuredAccumulator.append(delta) != nil {
                        return .structuredError
                    }
                    idleState.noteContent()
                    emittedText = safe
                    onChunk(.content(delta))
                }
            }
            if stopsAfterFirstCompleteToolCall, toolStreamer.hasCompletedValidToolCall {
                return .toolCallComplete
            }
            return candidate.hitStop ? .requestStop : .more
        }

        let delta = ModelRuntime.streamDelta(from: emittedText, to: candidate.text)
        if !delta.isEmpty {
            if structuredAccumulator.append(delta) != nil {
                return .structuredError
            }
            idleState.noteContent()
            emittedText = candidate.text
            onChunk(.content(delta))
        }
        return candidate.hitStop ? .requestStop : .more
    }

    /// The end of generation: remaining tool-call deltas over the final
    /// filtered text, then any content the stream held back.
    mutating func finish(
        finalText: String,
        parsed: ModelRuntime.ParsedGeneratedOutput,
        structuredAccumulator: StructuredStreamingContentAccumulator,
        idleState: StructuredStreamingIdleState,
        onChunk: (StreamChunk) -> Void
    ) throws {
        let finalDelta = ModelRuntime.streamDelta(from: emittedText, to: parsed.content)
        if streamToolsIncrementally {
            for event in toolStreamer.observe(finalText) {
                onChunk(event)
            }
            if parsed.toolCalls.isEmpty,
               !parsed.content.isEmpty,
               !toolStreamer.suppressesAssistantContent
            {
                let contentDelta = ModelRuntime.streamDelta(from: emittedText, to: parsed.content)
                if !contentDelta.isEmpty {
                    if let error = structuredAccumulator.append(contentDelta) {
                        throw error
                    }
                    idleState.noteContent()
                    onChunk(.content(contentDelta))
                }
            }
        } else if !finalDelta.isEmpty {
            if let error = structuredAccumulator.append(finalDelta) {
                throw error
            }
            idleState.noteContent()
            onChunk(.content(finalDelta))
        }
        if let error = structuredAccumulator.error {
            throw error
        }
    }
}

// `internal` (not `private`) so the allowlist fail-closed behavior is unit-testable via
// `@testable import macprovider_cli` (see NativeToolCallStreamEmitterTests).
struct NativeToolCallStreamEmitter {
    private let startDelimiter: String
    private let endDelimiter: String
    private let argumentKey: String
    /// Declared tools for this request. A streamed tool-call delta MUST NOT be emitted for
    /// any function name not in this set — otherwise a widened name grammar could surface an
    /// undeclared tool_call to the buyer before the final parser's fail-closed check
    /// (SPEC-018 §3.5). `nil`/empty means no tools were declared, so nothing may be emitted.
    private let allowedFunctionNames: Set<String>?
    /// Function-XML (`<function=…>`) is a Qwen-row-only grammar (SPEC-018 §3.1 v0.2.7). The
    /// streaming emitter mirrors the non-streaming parser's family gate: only Qwen models may
    /// stream `<function=…>` tool-call deltas; other families fall through to JSON parsing (which
    /// yields nothing for XML), so no non-Qwen family can stream a function-XML delta.
    private let allowsFunctionXML: Bool
    /// SPEC-018 §3.2: only Qwen 2.5/3 and Llama 3.3 native grammars are recognized.
    /// Unsupported families must not complete a serial stop on lookalike markup.
    private let enabled: Bool
    private var sawToolDelimiter = false
    private var opened = false
    private var closed = false
    private var completedValidToolCall = false
    private var emittedArguments = ""
    private var callID = "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"

    init(modelID: String, allowedFunctionNames: Set<String>?) {
        self.allowedFunctionNames = allowedFunctionNames
        let isQwen = modelID.localizedCaseInsensitiveContains("qwen2.5")
            || modelID.localizedCaseInsensitiveContains("qwen3")
        let isLlama33 = modelID.localizedCaseInsensitiveContains("llama-3.3")
        self.enabled = isQwen || isLlama33
        self.allowsFunctionXML = isQwen
        if isLlama33 {
            startDelimiter = "<|python_tag|>"
            endDelimiter = "<|eom_id|>"
            argumentKey = "parameters"
        } else {
            startDelimiter = "<tool_call>"

exec
/bin/bash -lc "rg -n \"struct ContinuousBatch.*Token|replayTokens|deliverVisibleTokens|tokenSink|ContinuousBatchSchedulerToken\" phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift phase3-binary/Sources/macprovider-cli/*.swift | head -120 && sed -n '2270,2415p' phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift" in /Users/augstar/macprovider-1646-rest
 succeeded in 0ms:
phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:396:struct ContinuousBatchSchedulerTokenEvent: Sendable, Equatable {
phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:402:    let replayTokens: [Int]?
phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:406:typealias ContinuousBatchSchedulerTokenSink = @Sendable (ContinuousBatchSchedulerTokenEvent) async -> Void
phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:721:    private let sink: ContinuousBatchSchedulerTokenSink
phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:723:    private var queue: [ContinuousBatchSchedulerTokenEvent] = []
phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:740:        sink: @escaping ContinuousBatchSchedulerTokenSink
phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:750:    func offer(_ event: ContinuousBatchSchedulerTokenEvent) -> Bool {
phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:870:    private func nextEvent(generation: UUID) -> ContinuousBatchSchedulerTokenEvent? {
phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:1262:        tokenSink: @escaping ContinuousBatchSchedulerTokenSink = { _ in }
phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:1352:            sink: tokenSink
phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:1564:                let replay = ContinuousBatchSchedulerTokenEvent(
phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:1568:                    replayTokens: pending.result.outputTokens,
phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:1627:                let replay = ContinuousBatchSchedulerTokenEvent(
phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:1631:                    replayTokens: row.outputTokens,
phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:2271:        if !deliverVisibleTokens(
phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:2332:    private func deliverVisibleTokens(_ tokens: [Int], firstIndex: Int, row: Row) -> Bool {
phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:2335:            let event = ContinuousBatchSchedulerTokenEvent(
phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:2339:                replayTokens: nil,
phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:396:struct ContinuousBatchSchedulerTokenEvent: Sendable, Equatable {
phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:402:    let replayTokens: [Int]?
phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:406:typealias ContinuousBatchSchedulerTokenSink = @Sendable (ContinuousBatchSchedulerTokenEvent) async -> Void
phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:721:    private let sink: ContinuousBatchSchedulerTokenSink
phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:723:    private var queue: [ContinuousBatchSchedulerTokenEvent] = []
phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:740:        sink: @escaping ContinuousBatchSchedulerTokenSink
phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:750:    func offer(_ event: ContinuousBatchSchedulerTokenEvent) -> Bool {
phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:870:    private func nextEvent(generation: UUID) -> ContinuousBatchSchedulerTokenEvent? {
phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:1262:        tokenSink: @escaping ContinuousBatchSchedulerTokenSink = { _ in }
phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:1352:            sink: tokenSink
phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:1564:                let replay = ContinuousBatchSchedulerTokenEvent(
phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:1568:                    replayTokens: pending.result.outputTokens,
phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:1627:                let replay = ContinuousBatchSchedulerTokenEvent(
phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:1631:                    replayTokens: row.outputTokens,
phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:2271:        if !deliverVisibleTokens(
phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:2332:    private func deliverVisibleTokens(_ tokens: [Int], firstIndex: Int, row: Row) -> Bool {
phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:2335:            let event = ContinuousBatchSchedulerTokenEvent(
phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:2339:                replayTokens: nil,
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4426:                ), tokenSink: { event in
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4429:                        eventTokens: event.replayTokens ?? [event.token],
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4653:                ), tokenSink: { event in
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4656:                        eventTokens: event.replayTokens ?? [event.token],
phase3-binary/Sources/macprovider-cli/MSBThroughputCommand.swift:597:                            tokenSink: { _ in firstToken.note() }
phase3-binary/Sources/macprovider-cli/MSBThroughputCommand.swift:1262:                tokenSink: { event in latch.note(requestID: event.requestID) }
phase3-binary/Sources/macprovider-cli/MSBThroughputCommand.swift:1275:                tokenSink: { event in latch.note(requestID: event.requestID) }
phase3-binary/Sources/macprovider-cli/MSBThroughputCommand.swift:1434:                tokenSink: { event in latch.note(requestID: event.requestID) }
phase3-binary/Sources/macprovider-cli/MSBThroughputCommand.swift:1447:                tokenSink: { event in latch.note(requestID: event.requestID) }
        CBTrace.log(row.request.id, "sch_active")
        if !deliverVisibleTokens(
            visibleTokens,
            firstIndex: firstVisibleIndex,
            row: row
        ) {
            activeDecode.removeValue(forKey: row.request.id)
            let released = await release(row.handle)
            // Post-token, like the `.deliveryBackpressure` thrown at the
            // waiter above: this row was decoding when its last consumer
            // refused an event. The terminal result is replayable to a later
            // duplicate of the same request id, so it must not carry the
            // pre-admission code — that one is retryable and this is not.
            finish(
                row,
                status: .requestFailed,
                errorCode: released
                    ? ContinuousBatchSchedulerError.deliveryBackpressureCode
                    : "continuous_batching_cleanup_failed"
            )
            return
        }

        if let terminalStatus {
            activeDecode.removeValue(forKey: row.request.id)
            await finishTerminal(row, status: terminalStatus)
        }
    }

    /// Normal terminal for a row already removed from active tracking. The
    /// retain / materialize awaits can interleave with `cancel(requestID:)`,
    /// which only records the ID and no longer finds the row; a cancel recorded
    /// meanwhile wins, and no conversation cache is published for it.
    private func finishTerminal(_ row: Row, status: ContinuousBatchSchedulerTerminalStatus) async {
        if let retainedCache = await retainTerminalCache(
            for: row,
            targetLogicalTokens: row.retainedLogicalTokenCount
        ) {
            if cancelledIDs.remove(row.request.id) != nil {
                await discardRetainedCache(
                    retainedCache.retainedSequence,
                    conversationKey: schedulerConversationKey(for: row.request)
                )
                finish(row, status: .cancelled, errorCode: "request_cancelled")
                return
            }
            finish(row, status: status, errorCode: nil, retainedCache: retainedCache)
            return
        }
        let serialCache = await materializeSerialConversationCache(for: row)
        let released = await release(row.handle)
        if cancelledIDs.remove(row.request.id) != nil {
            finish(row, status: released ? .cancelled : .requestFailed, errorCode: released
                ? "request_cancelled"
                : "continuous_batching_cleanup_failed")
            return
        }
        finish(row, status: released ? status : .requestFailed, errorCode: released
            ? nil
            : "continuous_batching_cleanup_failed", serialConversationCache: serialCache)
    }

    private func deliverVisibleTokens(_ tokens: [Int], firstIndex: Int, row: Row) -> Bool {
        guard !tokens.isEmpty else { return !(requestWaiters[row.request.id]?.isEmpty ?? true) }
        for (offset, token) in tokens.enumerated() {
            let event = ContinuousBatchSchedulerTokenEvent(
                requestID: row.request.id,
                tokenIndex: firstIndex + offset,
                token: token,
                replayTokens: nil,
                snapshot: row.snapshot
            )
            var retained: [Waiter] = []
            for waiter in requestWaiters[row.request.id] ?? [] {
                if waiter.delivery.offer(event) {
                    retained.append(waiter)
                } else {
                    beginStoppingActiveWaiter(
                        requestID: row.request.id,
                        waiter: waiter,
                        error: ContinuousBatchSchedulerError.deliveryBackpressure
                    )
                }
            }
            if retained.isEmpty {
                requestWaiters.removeValue(forKey: row.request.id)
                return false
            }
            requestWaiters[row.request.id] = retained
        }
        return true
    }

    private func beginStoppingActiveWaiter(
        requestID: String,
        waiter: Waiter,
        error: any Error
    ) {
        guard stoppingWaiterIDs.insert(waiter.id).inserted else { return }
        stoppingActiveWaiters[waiter.id] = StoppingActiveWaiter(
            requestID: requestID,
            waiter: waiter,
            error: error
        )
        waiter.delivery.stop(afterStopping: {
            Task { await self.finishStoppedWaiter(requestID: requestID, waiterID: waiter.id) }
        })
    }

    private func admitWaitingRows() async -> Bool {
        guard occupiedSlots < configuration.maxActiveRows, !waiting.isEmpty else { return false }
        var madeProgress = false
        var attempts = 0
        while attempts < configuration.maxPrefillRowsPerIteration,
              occupiedSlots < configuration.maxActiveRows,
              !waiting.isEmpty {
            attempts += 1
            // SPEC-038 AC-25: a request already past its absolute admission
            // deadline (for example re-queued by a `capacityExceeded` bounce
            // after the deadline passed) expires here, synchronously. Its
            // zero-delay timeout task would otherwise race this pump, and the
            // pump could admit it after the bound it was promised.
            if let deadline = queueWaitDeadlines[waiting[0].id],
               DispatchTime.now().uptimeNanoseconds >= deadline {
                await expireQueueWait(requestID: waiting[0].id)
                madeProgress = true
                continue
            }
            let request = waiting.removeFirst()
            suspendQueueWaitTimeout(requestID: request.id)
            madeProgress = true
            if cancelledIDs.remove(request.id) != nil {
                await finishQueued(request, status: .cancelled, errorCode: "request_cancelled")
                continue
            }

            admittingRequests[request.id] = request
            var admissionHandle: PagedKVBlockTableHandle?
            do {
                let reservation = try initialReservation(for: request)
                let handle: PagedKVBlockTableHandle
                let prefillCursor: Int
                if let retained = request.retainedPagedKVSequence {
                    guard let contiguousCacheBridge else {
                        throw ContinuousBatchSchedulerError.unsupported(
                            "continuous_batching_paged_kv_handoff_unavailable"

exec
/bin/bash -lc "sed -n '370,420p;700,900p;1520,1650p' phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift" in /Users/augstar/macprovider-1646-rest
 succeeded in 0ms:
    func withDeliveryID(_ deliveryID: UUID?) -> ContinuousBatchRetainedCache {
        ContinuousBatchRetainedCache(
            retainedSequence: retainedSequence,
            layers: layers,
            deliveryID: deliveryID,
            recurrentCheckpoints: recurrentCheckpoints
        )
    }
}

/// SPEC-038 FR-CB4: a keyed hybrid row's cache in the serial conversation-cache
/// format. Attention layers are contiguous `KVCacheSimple` covering the first
/// `tokenCount` canonical tokens; recurrent layers are empty `MambaCache`s,
/// because reuse always restores one of `recurrentCheckpoints` (SPEC-024 FR-CI2).
final class ContinuousBatchSerialConversationCache: @unchecked Sendable {
    let layers: [KVCache]
    let recurrentCheckpoints: [RecurrentStateCheckpoint]
    let tokenCount: Int

    init(layers: [KVCache], recurrentCheckpoints: [RecurrentStateCheckpoint], tokenCount: Int) {
        self.layers = layers
        self.recurrentCheckpoints = recurrentCheckpoints
        self.tokenCount = tokenCount
    }
}

struct ContinuousBatchSchedulerTokenEvent: Sendable, Equatable {
    let requestID: String
    let tokenIndex: Int
    let token: Int
    /// Present only when a duplicate waiter attaches after visible output has
    /// already been delivered. Ordinary decode events are delta-only.
    let replayTokens: [Int]?
    let snapshot: ContinuousBatchSchedulerSnapshot
}

typealias ContinuousBatchSchedulerTokenSink = @Sendable (ContinuousBatchSchedulerTokenEvent) async -> Void

struct ContinuousBatchSchedulerMetrics: Sendable, Equatable {
    let slotsTotal: Int
    let slotsFree: Int
    let waitingCount: Int
    let activeDecodeRows: Int
    let activePromptRows: Int
    let sharedForwardCalls: Int
    let prefillCalls: Int
    let maxObservedBatchDepth: Int
    let retainedTerminalResults: Int
    let retainedDedupeTombstones: Int
    let attachedWaiters: Int
    let retainedDiagnostics: Int

    func tryAcquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard inUse < limit else { return false }
        inUse += 1
        return true
    }

    func release() {
        lock.lock()
        precondition(inUse > 0, "token delivery capacity release must balance acquisition")
        inUse -= 1
        lock.unlock()
    }
}

final class ContinuousBatchTokenDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private let bufferLimit: Int
    private let timeoutNanoseconds: UInt64
    private let sink: ContinuousBatchSchedulerTokenSink
    private let capacity: ContinuousBatchTokenDeliveryCapacity
    private var queue: [ContinuousBatchSchedulerTokenEvent] = []
    private var drainCompletion: (@Sendable (Bool) -> Void)?
    private var accepting = true
    private var draining = false
    private var timedOut = false
    private var ownsCapacity = false
    private var drainGeneration: UUID?
    private var deliveryTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    /// Test seam: runs after the drain loop sees an empty queue and before it
    /// decides whether to finish, the window an `offer()` can land in.
    var afterDrainSawEmptyQueueForTest: (@Sendable () -> Void)?

    init(
        bufferLimit: Int,
        timeoutNanoseconds: UInt64,
        capacity: ContinuousBatchTokenDeliveryCapacity,
        sink: @escaping ContinuousBatchSchedulerTokenSink
    ) {
        self.bufferLimit = max(1, bufferLimit)
        self.timeoutNanoseconds = timeoutNanoseconds
        self.capacity = capacity
        self.sink = sink
    }

    /// Non-blocking offer. The scheduler fails only this waiter when its
    /// consumer cannot keep up with the bounded delivery buffer.
    func offer(_ event: ContinuousBatchSchedulerTokenEvent) -> Bool {
        var generationToStart: UUID?
        lock.lock()
        guard accepting, queue.count < bufferLimit else {
            lock.unlock()
            return false
        }
        if !draining {
            guard capacity.tryAcquire() else {
                lock.unlock()
                return false
            }
            ownsCapacity = true
            draining = true
            let generation = UUID()
            drainGeneration = generation
            generationToStart = generation
        }
        queue.append(event)
        lock.unlock()
        if let generationToStart {
            startDrain(generation: generationToStart)
        }
        return true
    }

    /// Stops new events while allowing the already-bounded queue to drain in
    /// order outside scheduler isolation.
    func finish() {
        stop(afterStopping: {})
    }

    /// Stops new delivery. Cooperative sinks acknowledge immediately; a sink
    /// that ignores cancellation is detached from scheduler state at the same
    /// hard deadline used by terminal delivery and completes this waiter as a
    /// non-settling failure. Its live-task capacity remains quarantined until
    /// the sink actually returns, preventing unbounded detached-task growth.
    func stop(afterStopping completion: @escaping @Sendable () -> Void) {
        lock.lock()
        accepting = false
        queue.removeAll()
        if draining {
            drainCompletion = { _ in completion() }
            let task = deliveryTask
            lock.unlock()
            task?.cancel()
            startTimeout()
            return
        }
        let task = deliveryTask
        lock.unlock()
        task?.cancel()
        completion()
    }

    /// Stops new events and invokes `completion` only after every accepted
    /// event has completed delivery. The callback runs outside the lock and
    /// outside scheduler actor isolation.
    func finish(afterDraining completion: @escaping @Sendable (Bool) -> Void) {
        lock.lock()
        accepting = false
        if draining || !queue.isEmpty {
            precondition(drainCompletion == nil, "token delivery may finish only once")
            drainCompletion = completion
            lock.unlock()
            startTimeout()
            return
        }
        lock.unlock()
        completion(true)
    }

    private func startDrain(generation: UUID) {
        let task = Task { await self.drain(generation: generation) }
        lock.lock()
        if drainGeneration == generation {
            deliveryTask = task
            lock.unlock()
        } else {
            lock.unlock()
            task.cancel()
        }
    }

    private func startTimeout() {
        lock.lock()
        guard drainCompletion != nil, timeoutTask == nil else {
            lock.unlock()
            return
        }
        let task = Task { [timeoutNanoseconds] in
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            self.timeout()
        }
        timeoutTask = task
        lock.unlock()
    }

    private func drain(generation: UUID) async {
        while true {
            while let event = nextEvent(generation: generation) {
                await sink(event)
                if Task.isCancelled { break }
            }
            afterDrainSawEmptyQueueForTest?()
            // An `offer()` between the empty check above and this call saw
            // `draining == true`, appended, and started no drain of its own;
            // finishing here would strand that event and the terminal
            // `finish(afterDraining:)` would wait forever. `finishDrain`
            // re-checks the queue under the same lock that clears `draining`.
            if finishDrain(generation: generation, keepDrainingIfQueued: !Task.isCancelled) {
                return
            }
        }
    }

    private func nextEvent(generation: UUID) -> ContinuousBatchSchedulerTokenEvent? {
        lock.lock()
        if drainGeneration == generation, !timedOut, !queue.isEmpty {
            let event = queue.removeFirst()
            lock.unlock()
            return event
        }
        lock.unlock()
        return nil
    }

    private func timeout() {
        lock.lock()
        guard drainGeneration != nil, let completion = drainCompletion else {
            lock.unlock()
            return
        }
        timedOut = true
        accepting = false
        queue.removeAll()
        let task = deliveryTask
        draining = false
        drainGeneration = nil
        deliveryTask = nil
        timeoutTask = nil
        drainCompletion = nil
        lock.unlock()
        task?.cancel()
        completion(false)
    }

            scheduleDiscardUnacceptedRetainedCache(for: request)
            continuation.resume(throwing: ContinuousBatchSchedulerError.requestFailed(
                "continuous_batching_request_fingerprint_failed"
            ))
            return
        }
        if Task.isCancelled {
            delivery.finish()
            scheduleDiscardUnacceptedRetainedCache(for: request)
            continuation.resume(throwing: CancellationError())
            return
        }
        if let known = knownRequests[request.id], known != requestFingerprint {
            delivery.finish()
            scheduleDiscardUnacceptedRetainedCache(for: request)
            continuation.resume(throwing: ContinuousBatchSchedulerError.duplicateRequestMismatch)
            return
        }
        if let terminal = terminalResults[request.id] {
            delivery.finish()
            scheduleDiscardUnacceptedRetainedCache(for: request)
            continuation.resume(returning: terminal.withSettlementDisposition(.nonSettlingReplay))
            return
        }
        if var pending = pendingTerminalDeliveries[request.id] {
            // Pre-admission for *this* caller: a duplicate that could not be
            // attached to the in-flight terminal delivery. Its own delivery
            // has never been offered an event, so nothing reached this buyer
            // and re-sending the same id is safe — it attaches or replays.
            guard pending.waiters.count < configuration.duplicateWaiterLimit else {
                record(.backpressureRejected)
                delivery.finish()
                scheduleDiscardUnacceptedRetainedCache(for: request)
                continuation.resume(throwing: ContinuousBatchSchedulerError.backpressure)
                return
            }
            scheduleDiscardUnacceptedRetainedCache(for: request)
            let waiter = Waiter(
                id: waiterID,
                continuation: continuation,
                delivery: delivery
            )
            if let token = pending.result.outputTokens.last,
               let snapshot = pending.result.snapshot {
                let replay = ContinuousBatchSchedulerTokenEvent(
                    requestID: request.id,
                    tokenIndex: pending.result.outputTokens.count - 1,
                    token: token,
                    replayTokens: pending.result.outputTokens,
                    snapshot: snapshot
                )
                // Still pre-admission for this caller: `delivery` is the
                // new waiter's, freshly built in `submit()`, and this replay
                // is the first event ever offered to it. A refusal here means
                // the caller has seen nothing.
                guard delivery.offer(replay) else {
                    record(.backpressureRejected)
                    delivery.finish()
                    continuation.resume(throwing: ContinuousBatchSchedulerError.backpressure)
                    return
                }
            }
            pending.waiters.append(waiter)
            pending.remainingWaiterIDs.insert(waiterID)
            pendingTerminalDeliveries[request.id] = pending
            delivery.finish(afterDraining: { delivered in
                Task {
                    await self.finishTerminalDelivery(
                        requestID: request.id,
                        waiterID: waiterID,
                        delivered: delivered
                    )
                }
            })
            return
        }
        if dedupeTombstones.contains(request.id) {
            delivery.finish()
            scheduleDiscardUnacceptedRetainedCache(for: request)
            continuation.resume(throwing: ContinuousBatchSchedulerError.idempotencyWindowExpired)
            return
        }
        if draining {
            delivery.finish()
            scheduleDiscardUnacceptedRetainedCache(for: request)
            continuation.resume(throwing: ContinuousBatchSchedulerError.drained)
            return
        }
        if knownRequests[request.id] != nil {
            // Same shape as the `pendingTerminalDeliveries` guard above:
            // the duplicate never attached and never received an event.
            let deferredWaiterCount = deferredTerminalCompletions[request.id]?.waiters.count ?? 0
            guard requestWaiters[request.id, default: []].count + deferredWaiterCount
                    < configuration.duplicateWaiterLimit else {
                record(.backpressureRejected)
                delivery.finish()
                scheduleDiscardUnacceptedRetainedCache(for: request)
                continuation.resume(throwing: ContinuousBatchSchedulerError.backpressure)
                return
            }
            scheduleDiscardUnacceptedRetainedCache(for: request)
            requestWaiters[request.id, default: []].append(Waiter(
                id: waiterID,
                continuation: continuation,
                delivery: delivery
            ))
            if let row = activeDecode[request.id], let token = row.outputTokens.last {
                let replay = ContinuousBatchSchedulerTokenEvent(
                    requestID: row.request.id,
                    tokenIndex: row.outputTokens.count - 1,
                    token: token,
                    replayTokens: row.outputTokens,
                    snapshot: row.snapshot
                )
                // First offer to this waiter's own fresh delivery, as
                // above: the attach is rolled back and the caller has seen
                // no output, so this stays the pre-admission classification
                // even though the request it tried to join is decoding.
                if !delivery.offer(replay) {
                    var retained = requestWaiters[request.id] ?? []
                    retained.removeAll { $0.id == waiterID }
                    if retained.isEmpty {
                        requestWaiters.removeValue(forKey: request.id)
                        cancel(requestID: request.id)
                    } else {
                        requestWaiters[request.id] = retained
                    }
                    delivery.finish()
                    continuation.resume(throwing: ContinuousBatchSchedulerError.backpressure)
                }
            }

exec
/bin/bash -lc "rg -n \"struct StructuredStreamingContentAccumulator|class StructuredStreaming|structuredAccumulator|validateStructuredStreamingCompletion|structuredStreamingValidationBufferByteCap|stream\\(\" phase3-binary/Sources/macprovider-cli/ModelRuntime.swift | head -160 && sed -n '5160,5355p;5480,5925p' phase3-binary/Sources/macprovider-cli/ModelRuntime.swift" in /Users/augstar/macprovider-1646-rest
 succeeded in 0ms:
22:    func stream(_ request: ChatCompletionRequest, with handle: RequestHandle, shouldCancel: @escaping @Sendable () -> Bool, onChunk: @escaping @Sendable (StreamChunk) -> Void) async throws -> CompletionResult
89:final class StructuredStreamingContentAccumulator: @unchecked Sendable {
123:        guard nextBytes <= ModelRuntime.structuredStreamingValidationBufferByteCap else {
141:final class StructuredStreamingIdleState: @unchecked Sendable {
1039:    static let structuredStreamingValidationBufferByteCap = 2_097_152
3805:        // container.perform — real model-thread work) before stream() brackets
3945:            structuredAccumulator: StructuredStreamingContentAccumulator,
3960:                structuredAccumulator: structuredAccumulator,
3975:                    recordedError = structuredAccumulator.error
3984:            structuredAccumulator: StructuredStreamingContentAccumulator,
3993:                structuredAccumulator: structuredAccumulator,
4060:        /// the held-back text and then `validateStructuredStreamingCompletion`,
4184:        structuredAccumulator: StructuredStreamingContentAccumulator,
4191:            structuredAccumulator: structuredAccumulator,
4195:        return try validateStructuredStreamingCompletion(
4198:            buyerVisibleContent: structuredAccumulator.content
4543:        structuredAccumulator: StructuredStreamingContentAccumulator,
4660:                        structuredAccumulator: structuredAccumulator,
4708:                structuredAccumulator: structuredAccumulator,
5446:    func stream(
5464:        let structuredAccumulator = StructuredStreamingContentAccumulator(enabled: Self.requiresStructuredValidation(request.responseFormat))
5477:                    accumulator: structuredAccumulator,
5490:                structuredAccumulator: structuredAccumulator,
5510:                if let error = structuredAccumulator.append(completion.content) {
5516:            return try Self.validateStructuredStreamingCompletion(
5519:                buyerVisibleContent: structuredAccumulator.content
5527:                if let error = structuredAccumulator.append(completion.content) {
5533:            return try Self.validateStructuredStreamingCompletion(
5536:                buyerVisibleContent: structuredAccumulator.content
5545:        // (see DecodeBenchCommand.runCompiledOnce). Full production stream()
5574:                        accumulator: structuredAccumulator,
5665:                            if let error = structuredAccumulator.append(finalDelta) {
5676:                        if let error = structuredAccumulator.error {
5706:                        return try Self.validateStructuredStreamingCompletion(
5709:                            buyerVisibleContent: structuredAccumulator.content
5830:                                    structuredAccumulator: structuredAccumulator,
5888:                            structuredAccumulator: structuredAccumulator,
5927:                        let validated = try Self.validateStructuredStreamingCompletion(
5930:                            buyerVisibleContent: structuredAccumulator.content
7168:    static func validateStructuredStreamingCompletion(
7216:            return try validateStructuredStreamingCompletion(
7549:        structuredAccumulator: StructuredStreamingContentAccumulator,
7561:                    if structuredAccumulator.append(delta) != nil {
7577:            if structuredAccumulator.append(delta) != nil {
7592:        structuredAccumulator: StructuredStreamingContentAccumulator,
7607:                    if let error = structuredAccumulator.append(contentDelta) {
7615:            if let error = structuredAccumulator.append(finalDelta) {
7621:        if let error = structuredAccumulator.error {
                                inferenceRan: true,
                                settlementRan: true
                            )
                        }

                        let filtered = Self.applyOutputFilters(
                            result.output,
                            stopTokenFilter: stopTokenFilter,
                            requestStops: request.stop
                        )

                        let rawLengthFinish = request.maxTokens.map { result.generationTokenCount >= $0 } ?? false
                        let harmonyTerminalFinish = Self.isHarmonyTerminalFinish(
                            modelID: request.model,
                            generatedTokenIDs: resultTokenIDs
                        )
                        let parserFinishReason = HarmonyResponseParser.isHarmonyModelID(request.model)
                            ? (rawLengthFinish && !filtered.hitStop && !harmonyTerminalFinish ? "length" : (filtered.hitStop ? "request_stop" : "stop"))
                            : (rawLengthFinish && !filtered.hitStop ? "length" : (filtered.hitStop ? "request_stop" : "stop"))
                        let parsed = try Self.parseGeneratedOutput(
                            filteredText: filtered.text,
                            generatedTokenIDs: resultTokenIDs,
                            decode: { context.tokenizer.decode(tokenIds: $0) },
                            request: request,
                            mode: .complete(finishReason: parserFinishReason),
                            defaultCompletionTokens: result.generationTokenCount,
                            stopTokenFilter: stopTokenFilter,
                            requestStops: request.stop,
                            globalHitStop: filtered.hitStop
                        )
                        let finishReason: String
                        if !parsed.toolCalls.isEmpty {
                            finishReason = "tool_calls"
                        } else if rawLengthFinish, !filtered.hitStop, !parsed.hitStop, !harmonyTerminalFinish {
                            finishReason = "length"
                        } else {
                            finishReason = "stop"
                        }

                        let cachedPromptTokens = lease?.cachedPromptTokens ?? 0
                        let kvCacheBytesReused = Self.cachedPromptUTF8Bytes(
                            promptTokenIds: promptTokenIds,
                            cachedPromptTokens: cachedPromptTokens,
                            decode: { context.tokenizer.decode(tokenIds: $0) }
                        )
                        let completion = try Self.validateStructuredCompletion(CompletionResult(
                            content: parsed.content,
                            finishReason: finishReason,
                            promptTokens: promptTokenIds.count,
                            cachedPromptTokens: cachedPromptTokens,
                            kvCacheBytesReused: kvCacheBytesReused,
                            completionTokens: parsed.completionTokens,
                            generatedCompletionTokens: parsed.generatedCompletionTokens,
                            ttftMilliseconds: firstToken.elapsedMilliseconds(since: completionStartedAt),
                            toolCalls: parsed.toolCalls.isEmpty ? nil : parsed.toolCalls,
                            modelHashObserved: Self.validObservedModelHash(snapshot.modelHash),
                            settlementDisposition: .eligibleOwner
                        ), request: request)
                        if let lease {
                            await conversationCache.commit(lease, cache: ConversationCacheLayers(kvCache, recurrentCheckpoints: recurrent.checkpoints), fullTokens: promptTokenIds + resultTokenIDs.map(Int32.init), cold: coldContext)
                        }
                        return completion
                    } catch {
                        if let lease {
                            await conversationCache.abort(lease)
                        }
                        throw error
                    }
                }
            }
        }
        return (completion, snapshot)
    }

    private static func runSpeculativeCompletion(
        input: LMInput,
        parameters: GenerateParameters,
        targetContext: ModelContext,
        draft: ModelContainer,
        numDraftTokens: Int,
        request: ChatCompletionRequest,
        stopTokenFilter: StopTokenFilter,
        promptTokenCount: Int,
        completionStartedAt: Date,
        modelHash: String?,
        specDecodeGeneration: Int,
        shouldCancel: @escaping @Sendable () -> Bool,
        drainCancelled: DrainCancelToken,
        blockingInferenceExecutor: BlockingInferenceExecutor
    ) async throws -> CompletionResult {
        let generated = try await collectSpeculativeText(
            input: input,
            cache: nil,
            parameters: parameters,
            targetContext: targetContext,
            draft: draft,
            numDraftTokens: numDraftTokens,
            shouldCancel: shouldCancel,
            drainCancelled: drainCancelled,
            blockingInferenceExecutor: blockingInferenceExecutor
        )
        try drainCancelled.check()
        try Task.checkCancellation()
        guard generated.output.utf8.count <= ToolCallParser.SPEC018_ARGUMENTS_PER_RESPONSE_BYTE_CAP else {
            throw APIError(
                status: 502,
                message: "Model response exceeded 2097152 bytes",
                type: "upstream_provider_error",
                code: "response_byte_cap_exceeded",
                inferenceRan: true,
                settlementRan: true
            )
        }

        let filtered = applyOutputFilters(
            generated.output,
            stopTokenFilter: stopTokenFilter,
            requestStops: request.stop
        )
        let parsed = parseToolCallsIfRequested(filtered.text, request: request)
        let finishReason: String
        if !parsed.toolCalls.isEmpty {
            finishReason = "tool_calls"
        } else if let maxTokens = request.maxTokens,
                  generated.generationTokenCount >= maxTokens,
                  !filtered.hitStop {
            finishReason = "length"
        } else {
            finishReason = "stop"
        }
        return try validateStructuredCompletion(CompletionResult(
            content: parsed.content,
            finishReason: finishReason,
            promptTokens: promptTokenCount,
            completionTokens: generated.generationTokenCount,
            ttftMilliseconds: generated.firstToken.elapsedMilliseconds(since: completionStartedAt),
            toolCalls: parsed.toolCalls.isEmpty ? nil : parsed.toolCalls,
            modelHashObserved: validObservedModelHash(modelHash),
            settlementDisposition: .eligibleOwner,
            specDecodeDraftedTokens: generated.draftedTokens,
            specDecodeAcceptedTokens: generated.acceptedTokens,
            specDecodeGeneration: specDecodeGeneration
        ), request: request)
    }

    struct SpeculativeGenerationFailure: Error, Sendable {
        let reason: String
    }

    private static func logSpeculativeFallback(_ error: SpeculativeGenerationFailure) {
        let line = "event=spec_decode_fallback reason=\(error.reason)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    private struct SpeculativeTextResult: Sendable {
        let output: String
        let generationTokenCount: Int
        let draftedTokens: Int
        let acceptedTokens: Int
        let firstToken: FirstTokenRecorder
    }

    private static func collectSpeculativeText(
        input: LMInput,
        cache: [KVCache]?,
        parameters: GenerateParameters,
        targetContext: ModelContext,
        draft: ModelContainer,
        numDraftTokens: Int,
        shouldCancel: @escaping @Sendable () -> Bool,
        drainCancelled: DrainCancelToken,
        blockingInferenceExecutor: BlockingInferenceExecutor
    ) async throws -> SpeculativeTextResult {
        do {
            return try await draft.perform(nonSendable: (input, targetContext, cache)) { draftContext, values in
                let (input, targetContext, cache) = values
                return try await blockingInferenceExecutor.run { inferenceCancellation in
                    let draftCache = draftContext.model.newCache(parameters: parameters)
                    var iterator = try SpeculativeTokenIterator(
                        input: input,
                        mainModel: targetContext.model,
                        draftModel: draftContext.model,
                        mainCache: cache,
                        draftCache: draftCache,
                        parameters: parameters,
                        numDraftTokens: numDraftTokens
                    )
                    let stopTokenIDs = Self.generationStopTokenIDs(for: targetContext)
                    var tokenIDs: [Int] = []
                    var output = ""
                    var detokenizer = MLXLMCommon.NaiveStreamingDetokenizer(tokenizer: targetContext.tokenizer)
                    var stopStringFilter = GenerationConfigStopStringFilter(
                        stopStrings: targetContext.configuration.effectiveStopStrings
                    )
                    let firstToken = FirstTokenRecorder()
                    while let token = iterator.next() {
                )
            }
        ) { idleCancellation in
            try await self.attachedContinuousBatchStreamingCompletion(
                request: request,
                snapshot: snapshot,
                capability: continuousBatchingCapability,
                completionStartedAt: batchedCompletionStartedAt,
                shouldCancel: shouldCancel,
                drainCancelled: drainCancelled,
                structuredAccumulator: structuredAccumulator,
                idleState: batchedIdleState,
                idleCancellation: idleCancellation,
                onChunk: onChunk
            )
        }
        if let completion = batchedCompletion {
            return completion
        }
        if speculativeCacheWrapValidated,
           let testSpeculativeStream,
           Self.speculativeRoute(
               for: request,
               draftLoaded: snapshot.hasTargetCompatibleDraft,
               numDraftTokens: snapshot.numDraftTokens
           ) == .speculative {
            let completion = try await Self.withDrainCancellation(drainCancelled) {
                try await testSpeculativeStream(snapshot, request)
            }.withModelHashObservedIfMissing(Self.validObservedModelHash(snapshot.modelHash))
            if !completion.content.isEmpty {
                if let error = structuredAccumulator.append(completion.content) {
                    throw error
                }
                idleState.noteContent()
                onChunk(.content(completion.content))
            }
            return try Self.validateStructuredStreamingCompletion(
                completion,
                request: request,
                buyerVisibleContent: structuredAccumulator.content
            )
        }
        if let testCompletion {
            let completion = try await Self.withDrainCancellation(drainCancelled) {
                try await testCompletion(snapshot, request)
            }.withModelHashObservedIfMissing(Self.validObservedModelHash(snapshot.modelHash))
            if !completion.content.isEmpty {
                if let error = structuredAccumulator.append(completion.content) {
                    throw error
                }
                idleState.noteContent()
                onChunk(.content(completion.content))
            }
            return try Self.validateStructuredStreamingCompletion(
                completion,
                request: request,
                buyerVisibleContent: structuredAccumulator.content
            )
        }
        guard let container = snapshot.container else {
            throw APIError(status: 503, message: "Model not loaded", type: "server_error", code: "model_not_loaded")
        }

        // T2-01: compiled decode env-flag wire-in. When enabled, the
        // decode-bench path uses MLX.compile()-wrapped per-token forwards
        // (see DecodeBenchCommand.runCompiledOnce). Full production stream()
        // wire-in is deferred to a follow-up PR after bench correctness is
        // confirmed via T2-01 artifact. The flag is read here so it appears
        // in inference logs and the serve path is ready to branch on it.
        let compiledDecodeEnabled = CompiledDecode.isEnabledByEnvironment()
        if compiledDecodeEnabled {
            let line = "event=compiled_decode_enabled status=stream_path_deferred flag=\(CompiledDecode.envFlag)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }

        let maxContextTokens = maxContextTokens
        let kvBitsOverride = Self.effectiveKVBits(
            configured: kvBitsOverride,
            conversationKey: request.conversationKey
        )
        let speculativeCacheWrapValidated = speculativeCacheWrapValidated
        let prefillStepSize = prefillStepSize
        let conversationCache = conversationCache
        // SPEC-037 stage 5 — per-request cold-tier context (streaming endpoint).
        let coldContext = coldContext(for: request, snapshot: snapshot)
        let inferenceGate = inferenceGate
        let blockingInferenceExecutor = blockingInferenceExecutor
        let stopTokenFilter = stopTokenFilter
        let templateSupportsThinkingToggle = snapshot.templateSupportsThinkingToggle
        return try await Self.withDrainCancellation(drainCancelled) {
            try await Self.withStructuredStreamingIdleTimeout(
                idleState: idleState,
                onIdleTimeout: {
                    try Self.synthesizeIdleTimeoutResultOrThrow(
                        accumulator: structuredAccumulator,
                        request: request,
                        modelHash: snapshot.modelHash
                    )
                }
            ) { idleCancellation in
                try await inferenceGate.withPermit {
                try drainCancelled.check()
                try Task.checkCancellation()
                return try await container.perform { context in
                    try drainCancelled.check()
                    try Task.checkCancellation()
                    let input = try Self.userInput(
                        for: request,
                        templateSupportsThinkingToggle: templateSupportsThinkingToggle
                    )
                    let lmInput = try await context.processor.prepare(input: input)
                    try Self.validatePromptTokenCount(lmInput.text.tokens.size, maxContextTokens: maxContextTokens)
                    let parameters = Self.makeServeGenerateParameters(
                        maxTokens: request.maxTokens,
                        maxContextTokens: maxContextTokens,
                        kvBitsOverride: kvBitsOverride,
                        prefillStepSize: prefillStepSize,
                        temperature: Float(request.temperature),
                        topP: Float(request.topP)
                    )
                    let generationContext = Self.harmonyTerminalPreservingContext(from: context, modelID: request.model)

                    let promptTokenIds: [Int32] = lmInput.text.tokens.asArray(Int32.self)
                    // Autotune throughput probe: measure warm-decode
                    // wall-time on the provider so the client can derive an
                    // honest decode rate even for reasoning models whose
                    // analysis channel is silent in the SSE stream. Fires on
                    // the first decoded token of ANY channel (reasoning or
                    // final) inside the generate closure below; the duration
                    // to the generate result is reported as
                    // `macprovider_generation_ms`.
                    let decodeTimer = FirstTokenRecorder()
                    // SPEC-037 FR-KVP2.5: speculative-decode routing is
                    // determined BEFORE any conversation-cache begin(). A
                    // speculative-routed request acquires no lease, triggers no
                    // promotion, commits nothing, and leaves no busy key. This
                    // also fixes the latent stuck-busy-key bug on the streaming
                    // speculative path, whose success branch previously returned
                    // without committing or aborting a lease acquired above it
                    // (and passed a possibly-trimmed prompt with cache: nil).
                    if Self.speculativeRoute(
                        for: request,
                        draftLoaded: snapshot.hasTargetCompatibleDraft && snapshot.draftContainer != nil,
                        numDraftTokens: snapshot.numDraftTokens
                    ) == .speculative,
                       let draftContainer = snapshot.draftContainer,
                       let numDraftTokens = snapshot.numDraftTokens,
                       speculativeCacheWrapValidated,
                       Self.speculativeCacheWindowSafe(
                           promptTokens: promptTokenIds.count,
                           maxTokens: request.maxTokens,
                           maxContextTokens: maxContextTokens,
                           numDraftTokens: numDraftTokens
                       ) {
                        var emittedText = ""
                        var stoppedByRequestStop = false
                        let generated = try await Self.collectSpeculativeText(
                            input: lmInput,
                            cache: nil,
                            parameters: parameters,
                            targetContext: context,
                            draft: draftContainer,
                            numDraftTokens: numDraftTokens,
                            shouldCancel: shouldCancel,
                            drainCancelled: drainCancelled,
                            blockingInferenceExecutor: blockingInferenceExecutor
                        )
                        // Warm-decode wall-time for the speculative path.
                        // collectSpeculativeText owns its own decode loop and
                        // does not fire `decodeTimer`, so this resolves to nil
                        // here; the field is passed for construction-site parity
                        // with the non-speculative path.
                        let decodeEndedAt = Date()
                        let generationMS = decodeTimer.durationMilliseconds(until: decodeEndedAt)
                        try drainCancelled.check()
                        try Task.checkCancellation()

                        let final = Self.applyOutputFilters(
                            generated.output,
                            stopTokenFilter: stopTokenFilter,
                            requestStops: request.stop
                        )
                        let finalDelta = Self.delta(from: emittedText, to: final.text)
                        let parsed = Self.parseToolCallsIfRequested(final.text, request: request)
                        if !finalDelta.isEmpty {
                            if let error = structuredAccumulator.append(finalDelta) {
                                throw error
                            }
                            idleState.noteContent()
                            emittedText = final.text
                            stoppedByRequestStop = final.hitStop
                            onChunk(.content(finalDelta))
                        }
                        if final.hitStop {
                            stoppedByRequestStop = true
                        }
                        if let error = structuredAccumulator.error {
                            throw error
                        }

                        let finishReason: String
                        if !parsed.toolCalls.isEmpty {
                            finishReason = "tool_calls"
                        } else if let maxTokens = request.maxTokens,
                                  generated.generationTokenCount >= maxTokens,
                                  !stoppedByRequestStop,
                                  !final.hitStop {
                            finishReason = "length"
                        } else {
                            finishReason = "stop"
                        }

                        let completion = CompletionResult(
                            content: parsed.content,
                            finishReason: finishReason,
                            promptTokens: promptTokenIds.count,
                            cachedPromptTokens: 0,
                            completionTokens: generated.generationTokenCount,
                            generationMilliseconds: generationMS,
                            toolCalls: parsed.toolCalls.isEmpty ? nil : parsed.toolCalls,
                            modelHashObserved: Self.validObservedModelHash(snapshot.modelHash),
                            settlementDisposition: .eligibleOwner,
                            specDecodeDraftedTokens: generated.draftedTokens,
                            specDecodeAcceptedTokens: generated.acceptedTokens,
                            specDecodeGeneration: snapshot.specDecodeGeneration
                        )
                        return try Self.validateStructuredStreamingCompletion(
                            completion,
                            request: request,
                            buyerVisibleContent: structuredAccumulator.content
                        )
                    }

                    let lease = await conversationCache.begin(
                        conversationKey: request.conversationKey,
                        incomingTokens: promptTokenIds,
                        modelID: request.model,
                        kvBits: kvBitsOverride,
                        cold: coldContext
                    )
                    let kvCache: [KVCache]
                    var iteratorInput: LMInput
                    if let reusableCache = lease?.reusableCache, let lcp = lease?.lcp {
                        kvCache = reusableCache.layers
                        iteratorInput = LMInput(tokens: MLXArray(Array(promptTokenIds[lcp...])))
                    } else {
                        // SPEC-037 FR-KVP1 / SPEC-024-R001: same KVCacheSimple selector as
                        // the non-streaming path (eligible persist or keyed serial reuse).
                        kvCache = Self.serveCache(
                            model: generationContext.model, baseParameters: parameters,
                            forceSimpleKV: Self.forceSimpleKVCache(
                                eligible: coldContext?.eligible == true,
                                conversationKey: request.conversationKey))
                        iteratorInput = lmInput
                    }
                    let recurrent = Self.prefillRecurrentCheckpoints(
                        lease: lease, cache: kvCache, promptTokenIds: promptTokenIds,
                        context: generationContext, prefillStepSize: parameters.prefillStepSize)
                    if let resumeAt = recurrent.resumeAt {
                        iteratorInput = LMInput(tokens: MLXArray(Array(promptTokenIds[resumeAt...])))
                    }

                    var stoppedByRequestStop = false
                    var textEmitter = SerialStreamingTextEmitter(request: request)
                    var streamingParseError: APIError?
                    var harmonyObservedFinalTokenCount = 0
                    var harmonyObservedTokenCount = 0

                    // SPEC-037 FR-KVP2.5: speculative-decode routing is determined
                    // BEFORE conversationCache.begin() (block above, ahead of the
                    // lease acquisition) — a speculative-routed request acquires no
                    // lease, triggers no promotion, commits nothing, and leaves no
                    // busy key. This non-speculative path therefore never re-checks
                    // speculativeRoute; the post-begin speculative block that origin
                    // carried here would double-run and (on its success return) leak
                    // the lease as a stuck busy key, so it is intentionally dropped.
                    let isHarmonyResponse = HarmonyResponseParser.isHarmonyModelID(request.model)
                    var harmonyFinalDetokenizer = NaiveStreamingDetokenizer(tokenizer: context.tokenizer)
                    var harmonyStreamingParser = HarmonyResponseParser.StreamingParser(
                        decode: { context.tokenizer.decode(tokenIds: $0) },
                        decodeFinalToken: { tokenID in
                            harmonyFinalDetokenizer.append(token: tokenID)
                            return harmonyFinalDetokenizer.next()
                        },
                        allowedFunctionNames: Self.toolFunctionNames(from: request.promptSource.tools),
                        stopCandidates: stopTokenFilter.tokens + request.stop
                    )
                    let iterator = try TokenIterator(input: iteratorInput, model: generationContext.model, cache: kvCache, parameters: parameters)
                    do {
                        let result: BlockingGenerateResult = try await blockingInferenceExecutor.run { inferenceCancellation in
                            BlockingGenerateResult(generate(input: iteratorInput, context: generationContext, iterator: iterator) { tokens in
                                EgressPerfTraceKey.current?.recordDecodeCallbackEntry()
                                // Round-2 code LOW: only start the decode timer
                                // on a callback that actually carries a token.
                                // An empty first callback would otherwise start
                                // the clock during prefill and inflate the
                                // measured decode window. Mirrors the
                                // `if !tokens.isEmpty { firstToken.recordIfMissing() }`
                                // guards elsewhere in this file.
                                if !tokens.isEmpty {
                                    decodeTimer.recordIfMissing()
                                    ModelLivenessTracker.shared.recordProgress()
                                }
                                if Task.isCancelled || inferenceCancellation.isCancelled || shouldCancel() || drainCancelled.isFired || idleCancellation.isFired {
                                    return .stop
                                }
                                if isHarmonyResponse {
                                    do {
                                        guard tokens.count >= harmonyObservedTokenCount else {
                                            streamingParseError = Self.malformedHarmonyResponseError()
                                            return .stop
                                        }
                                        let newTokenIDs = Array(tokens.dropFirst(harmonyObservedTokenCount))
                                        harmonyObservedTokenCount = tokens.count
                                        let parsed = harmonyStreamingParser.parse(newTokenIDs: newTokenIDs)
                                        if parsed.finalContentTokenCount > harmonyObservedFinalTokenCount {
                                            harmonyObservedFinalTokenCount = parsed.finalContentTokenCount
                                            idleState.noteContent()
                                        }
                                        let output = try Self.harmonyParsedOutput(
                                            from: parsed,
                                            decode: { context.tokenizer.decode(tokenIds: $0) },
                                            stopTokenFilter: stopTokenFilter,
                                            requestStops: request.stop,
                                            countCompletionTokens: false
                                        )
                                        if output.hitStop {
                                            stoppedByRequestStop = true
                                            return .stop
                                        }
                                        if tokens.last.map(Self.isHarmonyTerminalToken) == true {
                                            return .stop
                                        }
                                        return .more
                                    } catch let error as APIError {
                                        streamingParseError = error
                                        return .stop
                                    } catch {
                                        streamingParseError = Self.malformedHarmonyResponseError()
                                        return .stop
                                    }
                                }
                                let decoded = context.tokenizer.decode(tokenIds: tokens)
                                let candidate = Self.streamingSafePrefix(
                                    decoded,
                                    stopTokenFilter: stopTokenFilter,
                                    requestStops: request.stop
                                )
                                switch textEmitter.step(
                                    candidate: candidate,
                                    structuredAccumulator: structuredAccumulator,
                                    idleState: idleState,
                                    onChunk: onChunk
                                ) {
                                case .more:
                                    return .more
                                case .requestStop:
                                    stoppedByRequestStop = true
                                    return .stop
                                case .toolCallComplete, .structuredError:
                                    return .stop
                                }
                            })
                        }
                        // Warm-decode wall-time: from the first decoded token
                        // (any channel) to the generate result. Reported to the
                        // client as `macprovider_generation_ms` so the autotune
                        // probe can divide total decoded tokens by this window
                        // even when the reasoning channel is silent in SSE.
                        let decodeEndedAt = Date()
                        let generationMS = decodeTimer.durationMilliseconds(until: decodeEndedAt)
                        try drainCancelled.check()
                        try Task.checkCancellation()
                        if shouldCancel() {
                            throw CancellationError()
                        }
                        if let streamingParseError {
                            throw streamingParseError
                        }
                        let resultTokenIDs = result.tokenIds

                        let final = Self.applyOutputFilters(
                            result.output,
                            stopTokenFilter: stopTokenFilter,
                            requestStops: request.stop
                        )
                        let rawLengthFinish = request.maxTokens.map { result.generationTokenCount >= $0 } ?? false
                        let harmonyTerminalFinish = Self.isHarmonyTerminalFinish(
                            modelID: request.model,
                            generatedTokenIDs: resultTokenIDs
                        )
                        let parserFinishReason = isHarmonyResponse
                            ? (rawLengthFinish && !stoppedByRequestStop && !harmonyTerminalFinish ? "length" : (stoppedByRequestStop ? "request_stop" : "stop"))
                            : (rawLengthFinish && !final.hitStop && !stoppedByRequestStop ? "length" : ((final.hitStop || stoppedByRequestStop) ? "request_stop" : "stop"))
                        let parsed = try Self.parseGeneratedOutput(
                            filteredText: final.text,
                            generatedTokenIDs: resultTokenIDs,
                            decode: { context.tokenizer.decode(tokenIds: $0) },
                            request: request,
                            mode: .complete(finishReason: parserFinishReason),
                            defaultCompletionTokens: result.generationTokenCount,
                            stopTokenFilter: stopTokenFilter,
                            requestStops: request.stop,
                            globalHitStop: final.hitStop || stoppedByRequestStop
                        )
                        try textEmitter.finish(
                            finalText: final.text,
                            parsed: parsed,
                            structuredAccumulator: structuredAccumulator,
                            idleState: idleState,
                            onChunk: onChunk
                        )

                        let finishReason: String
                        if !parsed.toolCalls.isEmpty {
                            finishReason = "tool_calls"
                        } else if let maxTokens = request.maxTokens,
                           result.generationTokenCount >= maxTokens,
                           !stoppedByRequestStop,
                           !final.hitStop,
                           !parsed.hitStop,
                           !harmonyTerminalFinish
                        {
                            finishReason = "length"
                        } else {
                            finishReason = "stop"
                        }

                        let cachedPromptTokens = lease?.cachedPromptTokens ?? 0
                        let kvCacheBytesReused = Self.cachedPromptUTF8Bytes(
                            promptTokenIds: promptTokenIds,
                            cachedPromptTokens: cachedPromptTokens,
                            decode: { context.tokenizer.decode(tokenIds: $0) }
                        )
                        let completion = CompletionResult(
                            content: parsed.content,
                            finishReason: finishReason,
                            promptTokens: promptTokenIds.count,
                            cachedPromptTokens: cachedPromptTokens,
                            kvCacheBytesReused: kvCacheBytesReused,
                            completionTokens: parsed.completionTokens,
                            generatedCompletionTokens: parsed.generatedCompletionTokens,
                            generationMilliseconds: generationMS,
                            toolCalls: parsed.toolCalls.isEmpty ? nil : parsed.toolCalls,
                            modelHashObserved: Self.validObservedModelHash(snapshot.modelHash),
                            settlementDisposition: .eligibleOwner

exec
/bin/bash -lc "sed -n '1,175p;5890,5955p;7130,7235p' phase3-binary/Sources/macprovider-cli/ModelRuntime.swift" in /Users/augstar/macprovider-1646-rest
 succeeded in 0ms:
import Foundation
import CryptoKit
import Darwin
import Jinja
import MLX
import MLXLLM
import MLXHuggingFace
import MLXLMCommon
import MacProviderCore
import Tokenizers

protocol ModelRuntimeServing: Actor {
    func complete(_ request: ChatCompletionRequest, shouldCancel: @escaping @Sendable () -> Bool) async throws -> CompletionResult
    /// SPEC-015 §M.2 — return the runtime-owned snapshot that
    /// actually drove inference (validation, in-flight registration,
    /// generation) so the receipt can bind `model_hash` to the
    /// container that served. Atomically captured inside the actor
    /// turn — distinct from a caller-side `currentSnapshot()` sample,
    /// which can drift across an actor interleaving / warm-swap.
    func completeWithServedSnapshot(_ request: ChatCompletionRequest, shouldCancel: @escaping @Sendable () -> Bool) async throws -> (CompletionResult, RuntimeSnapshot)
    func completeWithServedSnapshot(_ request: ChatCompletionRequest, with handle: RequestHandle, shouldCancel: @escaping @Sendable () -> Bool) async throws -> (CompletionResult, RuntimeSnapshot)
    func stream(_ request: ChatCompletionRequest, with handle: RequestHandle, shouldCancel: @escaping @Sendable () -> Bool, onChunk: @escaping @Sendable (StreamChunk) -> Void) async throws -> CompletionResult
    func preflight(_ request: ChatCompletionRequest, with handle: RequestHandle) async throws
    func pagedKVPreflight(_ request: ChatCompletionRequest, with handle: RequestHandle) async throws
    /// Tokenize through the active model processor without entering generation.
    /// SPEC-041 uses this exact count to enforce the buyer-declared input bound
    /// before emitting validation evidence or starting inference.
    func relayBlindPrepare(_ request: ChatCompletionRequest) async throws -> RelayBlindPreparedRequest
    func acquireRequestHandle(_ request: ChatCompletionRequest) throws -> RequestHandle
    func unregisterInFlight(_ id: Int)
    func currentSnapshot() async -> RuntimeSnapshot
    /// Identity/status surface the serve command reads to build ProviderStatus.
    /// The concrete MLX `ModelRuntime` witnesses these with actor-isolated
    /// members; loopback runtimes report their own GGUF-file identity. Every
    /// conformer implements them explicitly -- no protocol-extension default,
    /// which on an actor conformer would shadow the synchronous witness in an
    /// `await` context and silently no-op status/identity reads.
    var loadedModelHash: String? { get async }
    var loadedModelHashAlgorithm: String? { get async }
    var loadedWeightsManifestSHA256: String? { get async }
    var isLoaded: Bool { get async }
    func setProviderStatus(_ providerStatus: ProviderStatus) async
    /// Issue #1695: whether completions from this runtime may carry a signed
    /// SPEC-015 receipt at all. Every conformer declares it explicitly (no
    /// protocol-extension default) so a new loopback or fixture runtime cannot
    /// inherit receipt eligibility by omission. This is a CLI accident guard,
    /// not a security boundary: the coordinator settlement gate is the control.
    /// SPEC-015 §N.12 (#1690 M5) lifts it for one request at a time, only
    /// through a matching coordinator `pool_runtime_authorization`.
    nonisolated var isSettlementReceiptEligible: Bool { get }
    /// SPEC-015 §N.12: the SPEC-046 `runtime_source` a request's
    /// `pool_runtime_authorization` must name to let this runtime sign that
    /// request's v0.4 receipt. Nil for a runtime no pool authorization can
    /// enable. Declared explicitly by every conformer, as above.
    nonisolated var settlementRuntimeSource: String? { get }
}

struct RelayBlindPreparedRequest: @unchecked Sendable {
    let handle: RequestHandle
    let inputTokens: Int
}

enum StreamChunk: Sendable {
    case content(String)
    case toolCallDelta(StreamToolCallDelta)
}

struct StreamToolCallDelta: Sendable {
    let index: Int
    let id: String?
    let type: String?
    let functionName: String?
    let arguments: String?

    /// OpenAI wire-shape conversion: first delta carries id/type/function.name;
    /// subsequent deltas carry function.arguments fragments. All deltas carry index.
    func openAIDeltaDict() -> [String: Any] {
        var delta: [String: Any] = ["index": index]
        if let id { delta["id"] = id }
        if let type { delta["type"] = type }
        var function: [String: Any] = [:]
        if let functionName { function["name"] = functionName }
        if let arguments { function["arguments"] = arguments }
        if !function.isEmpty { delta["function"] = function }
        return delta
    }
}

final class StructuredStreamingContentAccumulator: @unchecked Sendable {
    private let enabled: Bool
    private let lock = NSLock()
    private var bytes = 0
    private var contentValue = ""
    private var capError: APIError?

    init(enabled: Bool) {
        self.enabled = enabled
    }

    var content: String {
        lock.lock()
        defer { lock.unlock() }
        return contentValue
    }

    var error: APIError? {
        lock.lock()
        defer { lock.unlock() }
        return capError
    }

    @discardableResult
    func append(_ delta: String) -> APIError? {
        guard enabled else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let capError {
            return capError
        }
        let nextBytes = bytes + delta.utf8.count
        // AC-V2-9b (SPEC-019 v0.2.4 §6): 2 MiB streaming content cap on
        // post-stop-token-filter buyer-visible content delta concatenation.
        guard nextBytes <= ModelRuntime.structuredStreamingValidationBufferByteCap else {
            let error = APIError(
                status: 502,
                message: "Structured streaming content exceeded 2097152 bytes",
                type: "upstream_provider_error",
                code: "response_byte_cap_exceeded",
                inferenceRan: true,
                settlementRan: true
            )
            capError = error
            return error
        }
        bytes = nextBytes
        contentValue += delta
        return nil
    }
}

final class StructuredStreamingIdleState: @unchecked Sendable {
    let enabled: Bool
    private let lock = NSLock()
    private var lastContentAt = Date()
    private var finishedValue = false
    private var timedOutValue = false
    private var operationStoppedValue = false

    init(enabled: Bool) {
        self.enabled = enabled
    }

    func noteContent() {
        guard enabled else { return }
        lock.lock()
        lastContentAt = Date()
        lock.unlock()
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finishedValue
    }

    var timedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOutValue
    }

    var operationStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return operationStoppedValue
                            onChunk: onChunk
                        )

                        let finishReason: String
                        if !parsed.toolCalls.isEmpty {
                            finishReason = "tool_calls"
                        } else if let maxTokens = request.maxTokens,
                           result.generationTokenCount >= maxTokens,
                           !stoppedByRequestStop,
                           !final.hitStop,
                           !parsed.hitStop,
                           !harmonyTerminalFinish
                        {
                            finishReason = "length"
                        } else {
                            finishReason = "stop"
                        }

                        let cachedPromptTokens = lease?.cachedPromptTokens ?? 0
                        let kvCacheBytesReused = Self.cachedPromptUTF8Bytes(
                            promptTokenIds: promptTokenIds,
                            cachedPromptTokens: cachedPromptTokens,
                            decode: { context.tokenizer.decode(tokenIds: $0) }
                        )
                        let completion = CompletionResult(
                            content: parsed.content,
                            finishReason: finishReason,
                            promptTokens: promptTokenIds.count,
                            cachedPromptTokens: cachedPromptTokens,
                            kvCacheBytesReused: kvCacheBytesReused,
                            completionTokens: parsed.completionTokens,
                            generatedCompletionTokens: parsed.generatedCompletionTokens,
                            generationMilliseconds: generationMS,
                            toolCalls: parsed.toolCalls.isEmpty ? nil : parsed.toolCalls,
                            modelHashObserved: Self.validObservedModelHash(snapshot.modelHash),
                            settlementDisposition: .eligibleOwner
                        )
                        let validated = try Self.validateStructuredStreamingCompletion(
                            completion,
                            request: request,
                            buyerVisibleContent: structuredAccumulator.content
                        )
                        if let lease {
                            await conversationCache.commit(lease, cache: ConversationCacheLayers(kvCache, recurrentCheckpoints: recurrent.checkpoints), fullTokens: promptTokenIds + resultTokenIDs.map(Int32.init), cold: coldContext)
                        }
                        return validated
                    } catch {
                        if let lease {
                            await conversationCache.abort(lease)
                        }
                        throw error
                    }
                }
            }
            }
        }
    }

    /// SPEC-037 stage 5 (FR-KVP7) — attach the activated disk cold tier. Called by
    /// the serve lifecycle after the store acquires its namespace lock, so the hot
    /// tier only reaches disk once single-writer ownership is established.
    func attachKVDiskTier(_ tier: KVDiskTier) async {
        let adapter = KVConversationColdTierAdapter(
            store: tier.store, namespaceID: tier.namespaceID,
            eligibilityTTLSeconds: tier.eligibilityTTLSeconds,
            writeStagingMaxBytes: tier.config.writeStagingMaxBytes,
            "max_tokens": maxTokens,
            "temperature": 0,
            "top_p": 1,
        ]
        return try ChatCompletionRequest.parse(data: try JSONSerialization.data(withJSONObject: body))
    }

    static func validateStructuredCompletion(_ completion: CompletionResult, request: ChatCompletionRequest) throws -> CompletionResult {
        if completion.toolCalls?.isEmpty == false {
            return completion
        }
        switch request.responseFormat {
        case .text:
            return completion
        case .jsonObject:
            _ = try parseStructuredJSONContent(completion.content, requireObjectOrArray: true)
            return completion
        case .jsonSchema(let spec):
            let parsed = try parseStructuredJSONContent(completion.content, requireObjectOrArray: false)
            do {
                try JSONSchemaValidator.validateInstance(parsed, against: spec.schema)
            } catch let error as APIError {
                throw error
            } catch {
                throw APIError(
                    status: 502,
                    message: "Schema validation aborted before completion",
                    type: "upstream_provider_error",
                    code: "json_schema_validation_failed",
                    param: "",
                    inferenceRan: true,
                    settlementRan: true
                )
            }
            return completion
        }
    }

    static func validateStructuredStreamingCompletion(
        _ completion: CompletionResult,
        request: ChatCompletionRequest,
        buyerVisibleContent: String
    ) throws -> CompletionResult {
        guard requiresStructuredValidation(request.responseFormat), completion.toolCalls?.isEmpty != false else {
            return completion
        }
        let visibleCompletion = CompletionResult(
            content: buyerVisibleContent,
            finishReason: completion.finishReason,
            promptTokens: completion.promptTokens,
            cachedPromptTokens: completion.cachedPromptTokens,
            kvCacheBytesReused: completion.kvCacheBytesReused,
            completionTokens: completion.completionTokens,
            generatedCompletionTokens: completion.generatedCompletionTokens,
            ttftMilliseconds: completion.ttftMilliseconds,
            // Architect LOW: forward the decode-window so the structured
            // streaming path's usage carries `macprovider_generation_ms`
            // instead of null, matching the non-structured path.
            generationMilliseconds: completion.generationMilliseconds,
            toolCalls: completion.toolCalls,
            modelHashObserved: completion.modelHashObserved,
            settlementDisposition: completion.settlementDisposition,
            specDecodeDraftedTokens: completion.specDecodeDraftedTokens,
            specDecodeAcceptedTokens: completion.specDecodeAcceptedTokens,
            specDecodeGeneration: completion.specDecodeGeneration
        )
        return try validateStructuredCompletion(visibleCompletion, request: request)
    }

    static func synthesizeIdleTimeoutResultOrThrow(
        accumulator: StructuredStreamingContentAccumulator,
        request: ChatCompletionRequest,
        modelHash: String?
    ) throws -> CompletionResult {
        let content = accumulator.content
        let synthetic = CompletionResult(
            content: content,
            finishReason: "stop",
            promptTokens: 0,
            completionTokens: 0,
            ttftMilliseconds: 0,
            toolCalls: nil,
            modelHashObserved: validObservedModelHash(modelHash),
            settlementDisposition: .eligibleOwner
        )
        do {
            return try validateStructuredStreamingCompletion(
                synthetic,
                request: request,
                buyerVisibleContent: content
            )
        } catch {
            throw structuredStreamingProviderTimeoutError()
        }
    }

    // AC-V2-9 (SPEC-019 v0.2.4 §10): provider-idle breach validates the
    // buyer-visible buffer-as-of-close before emitting provider_timeout.
    static func withStructuredStreamingIdleTimeout<T: Sendable>(
        idleState: StructuredStreamingIdleState,
        timeout: TimeInterval = structuredStreamingIdleTimeoutSeconds,
        pollNanoseconds: UInt64 = 100_000_000,
        onIdleTimeout: @escaping @Sendable () throws -> T,
        operation: @escaping @Sendable (_ idleCancellation: DrainCancelToken) async throws -> T
    ) async throws -> T {
        guard idleState.enabled else {

exec
/bin/bash -lc "nl -ba phase3-binary/Sources/macprovider-cli/ModelRuntime.swift | sed -n '3890,4198p;4400,4725p;7500,7625p' && nl -ba phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift | sed -n '1365,1395p;2215,2285p;2760,2815p'" in /Users/augstar/macprovider-1646-rest
 succeeded in 0ms:
  3890	        hybrid: Bool,
  3891	        context: ModelContext
  3892	    ) -> [Int] {
  3893	        guard nonEmpty(conversationKey) != nil else { return [] }
  3894	        return ConversationCache.recurrentCheckpointPositions(
  3895	            promptTokenIds: promptTokens.map(Int32.init),
  3896	            imStartTokenID: context.tokenizer.convertTokenToId("<|im_start|>").map(Int32.init),
  3897	            hybrid: hybrid,
  3898	            decode: { context.tokenizer.decode(tokenIds: $0) })
  3899	    }
  3900	
  3901	    /// The tokens a batched hybrid entry commits: the canonical list cut to the
  3902	    /// length its attention layers cover, so `begin`'s trim lands exactly on a
  3903	    /// checkpoint. Nil if the canonical list is shorter (never expected).
  3904	    nonisolated static func serialConversationCacheCommitTokens(
  3905	        canonicalTokens: [Int32],
  3906	        coveredTokenCount: Int
  3907	    ) -> [Int32]? {
  3908	        guard coveredTokenCount <= canonicalTokens.count else { return nil }
  3909	        return Array(canonicalTokens.prefix(coveredTokenCount))
  3910	    }
  3911	
  3912	    /// Tokenizer decode for CB streaming. Must not take `ModelContainer`:
  3913	    /// compiled lockstep already holds that hop, and a per-token `perform`
  3914	    /// behind the delivery buffer is what turned longer canary streams into
  3915	    /// `internal_error` after the first content chunk.
  3916	    struct StreamingDetokenizer: @unchecked Sendable {
  3917	        let decode: ([Int]) -> String
  3918	    }
  3919	
  3920	    /// A batched streaming row's buyer-visible state (SPEC-038 AC-6c). Each
  3921	    /// delivered token runs the serial path's `SerialStreamingTextEmitter`
  3922	    /// step over the decode of every token so far, as the serial generate
  3923	    /// callback does. Once the serial path would have stopped generating (a
  3924	    /// serial tool turn's first complete tool call, or a structured-output
  3925	    /// accumulator error) later tokens are ignored and the stop point is kept
  3926	    /// so the finalize truncates the row to it.
  3927	    final class AttachedPagedKVStreamState: @unchecked Sendable {
  3928	        private let lock = NSLock()
  3929	        private var tokenIDs: [Int] = []
  3930	        private var emitter: SerialStreamingTextEmitter
  3931	        private var recordedError: APIError?
  3932	        private var stoppedValue = false
  3933	        private var serialStopTokenCountValue: Int?
  3934	
  3935	        init(request: ChatCompletionRequest) {
  3936	            emitter = SerialStreamingTextEmitter(request: request)
  3937	        }
  3938	
  3939	        /// Returns true the first time the row should stop decoding.
  3940	        func step(
  3941	            eventTokens: [Int],
  3942	            decode: ([Int]) -> String,
  3943	            stopTokenFilter: StopTokenFilter,
  3944	            requestStops: [String],
  3945	            structuredAccumulator: StructuredStreamingContentAccumulator,
  3946	            idleState: StructuredStreamingIdleState,
  3947	            onChunk: (StreamChunk) -> Void
  3948	        ) -> Bool {
  3949	            lock.lock()
  3950	            defer { lock.unlock() }
  3951	            guard !stoppedValue, !eventTokens.isEmpty else { return false }
  3952	            tokenIDs.append(contentsOf: eventTokens)
  3953	            let candidate = ModelRuntime.streamingSafePrefix(
  3954	                decode(tokenIDs),
  3955	                stopTokenFilter: stopTokenFilter,
  3956	                requestStops: requestStops
  3957	            )
  3958	            switch emitter.step(
  3959	                candidate: candidate,
  3960	                structuredAccumulator: structuredAccumulator,
  3961	                idleState: idleState,
  3962	                onChunk: onChunk
  3963	            ) {
  3964	            case .more, .requestStop:
  3965	                // A buyer stop string ends the row through its stop-token
  3966	                // sequences, and the final filter cuts the text at it.
  3967	                return false
  3968	            case .toolCallComplete:
  3969	                stoppedValue = true
  3970	                serialStopTokenCountValue = tokenIDs.count
  3971	                return true
  3972	            case .structuredError:
  3973	                stoppedValue = true
  3974	                if recordedError == nil {
  3975	                    recordedError = structuredAccumulator.error
  3976	                }
  3977	                return true
  3978	            }
  3979	        }
  3980	
  3981	        func finish(
  3982	            finalText: String,
  3983	            parsed: ModelRuntime.ParsedGeneratedOutput,
  3984	            structuredAccumulator: StructuredStreamingContentAccumulator,
  3985	            idleState: StructuredStreamingIdleState,
  3986	            onChunk: (StreamChunk) -> Void
  3987	        ) throws {
  3988	            lock.lock()
  3989	            defer { lock.unlock() }
  3990	            try emitter.finish(
  3991	                finalText: finalText,
  3992	                parsed: parsed,
  3993	                structuredAccumulator: structuredAccumulator,
  3994	                idleState: idleState,
  3995	                onChunk: onChunk
  3996	            )
  3997	        }
  3998	
  3999	        /// Token count at which the serial path would have stopped a serial
  4000	        /// tool turn; nil when it would not have stopped early.
  4001	        var serialStopTokenCount: Int? {
  4002	            lock.lock()
  4003	            defer { lock.unlock() }
  4004	            return serialStopTokenCountValue
  4005	        }
  4006	
  4007	        func error() -> APIError? {
  4008	            lock.lock()
  4009	            defer { lock.unlock() }
  4010	            return recordedError
  4011	        }
  4012	    }
  4013	
  4014	    /// A batched non-streaming serial tool turn (SPEC-038 AC-6c): the serial
  4015	    /// non-streaming stop test over each delivered token.
  4016	    final class ContinuousBatchSerialToolStopState: @unchecked Sendable {
  4017	        private let lock = NSLock()
  4018	        private var tokenIDs: [Int] = []
  4019	        private var observer: NativeToolCallStreamEmitter
  4020	        private var stopTokenCountValue: Int?
  4021	
  4022	        init(request: ChatCompletionRequest) {
  4023	            observer = NativeToolCallStreamEmitter(
  4024	                modelID: request.model,
  4025	                allowedFunctionNames: ModelRuntime.toolFunctionNames(from: request.promptSource.tools)
  4026	            )
  4027	        }
  4028	
  4029	        /// Returns true the first time the row should stop decoding.
  4030	        func observe(
  4031	            eventTokens: [Int],
  4032	            decode: ([Int]) -> String,
  4033	            stopTokenFilter: StopTokenFilter,
  4034	            requestStops: [String]
  4035	        ) -> Bool {
  4036	            lock.lock()
  4037	            defer { lock.unlock() }
  4038	            guard stopTokenCountValue == nil, !eventTokens.isEmpty else { return false }
  4039	            tokenIDs.append(contentsOf: eventTokens)
  4040	            guard ModelRuntime.observeSerialToolStop(
  4041	                &observer,
  4042	                decoded: decode(tokenIDs),
  4043	                stopTokenFilter: stopTokenFilter,
  4044	                requestStops: requestStops
  4045	            ) else { return false }
  4046	            stopTokenCountValue = tokenIDs.count
  4047	            return true
  4048	        }
  4049	
  4050	        var stopTokenCount: Int? {
  4051	            lock.lock()
  4052	            defer { lock.unlock() }
  4053	            return stopTokenCountValue
  4054	        }
  4055	    }
  4056	
  4057	    struct ContinuousBatchFinalizedRow: Sendable {
  4058	        /// Not yet structured-validated: the non-streaming caller runs
  4059	        /// `validateStructuredCompletion`, the streaming caller first sends
  4060	        /// the held-back text and then `validateStructuredStreamingCompletion`,
  4061	        /// each exactly as its serial counterpart does.
  4062	        let completion: CompletionResult
  4063	        let filteredText: String
  4064	        let parsed: ParsedGeneratedOutput
  4065	        /// Generated tokens the completion accounts for (model EOS dropped,
  4066	        /// truncated to the serial stop point).
  4067	        let generatedTokens: [Int]
  4068	        /// The row decoded past the serial stop point, so its retained cache
  4069	        /// covers tokens the completion does not and must not be committed.
  4070	        let truncatedAtSerialStop: Bool
  4071	    }
  4072	
  4073	    /// SPEC-038 AC-6c: the one post-generation finalize for a batched row,
  4074	    /// streaming and non-streaming. It applies the serial path's response
  4075	    /// byte cap, output filters, `parseGeneratedOutput` (tool calls,
  4076	    /// SPEC-018 caps, Harmony) and finish-reason rule to the row's text. A
  4077	    /// serial tool turn is first truncated to the token at which the serial
  4078	    /// path stops generating, so the parsed text and billed tokens match.
  4079	    static func finalizeContinuousBatchRow(
  4080	        request: ChatCompletionRequest,
  4081	        result: ContinuousBatchSchedulerResult,
  4082	        modelStopTokenIDs: Set<Int>,
  4083	        serialStopTokenCount: Int?,
  4084	        promptTokenIDs: [Int32],
  4085	        decode: ([Int]) -> String,
  4086	        stopTokenFilter: StopTokenFilter,
  4087	        generationMilliseconds: Int64,
  4088	        modelHash: String?
  4089	    ) throws -> ContinuousBatchFinalizedRow {
  4090	        // The serial path discards the model's end-of-generation token
  4091	        // before counting it; bill and cache the batched row the same way.
  4092	        // Harmony `<|return|>`/`<|call|>` are excluded from this set, as
  4093	        // they are from the serial stop set: the parser reads and counts them.
  4094	        var generatedTokens = droppingTrailingModelStop(
  4095	            result.generatedTokens,
  4096	            terminalStatus: result.terminalStatus,
  4097	            modelStopTokenIDs: modelStopTokenIDs
  4098	        )
  4099	        var completionTokenCount = result.completionTokens
  4100	            - (result.generatedTokens.count - generatedTokens.count)
  4101	        var outputTokens = result.outputTokens
  4102	        var truncated = false
  4103	        if let serialStopTokenCount, serialStopTokenCount < generatedTokens.count {
  4104	            completionTokenCount -= generatedTokens.count - serialStopTokenCount
  4105	            generatedTokens = Array(generatedTokens.prefix(serialStopTokenCount))
  4106	            outputTokens = Array(outputTokens.prefix(serialStopTokenCount))
  4107	            truncated = true
  4108	        }
  4109	        let decoded = decode(outputTokens)
  4110	        guard decoded.utf8.count <= ToolCallParser.SPEC018_ARGUMENTS_PER_RESPONSE_BYTE_CAP else {
  4111	            throw APIError(
  4112	                status: 502,
  4113	                message: "Model response exceeded 2097152 bytes",
  4114	                type: "upstream_provider_error",
  4115	                code: "response_byte_cap_exceeded",
  4116	                inferenceRan: true,
  4117	                settlementRan: true
  4118	            )
  4119	        }
  4120	        let filtered = applyOutputFilters(
  4121	            decoded,
  4122	            stopTokenFilter: stopTokenFilter,
  4123	            requestStops: request.stop
  4124	        )
  4125	        // A truncated row ended where the serial path's early stop does,
  4126	        // which is never a length finish.
  4127	        let lengthTerminal = result.terminalStatus == .length && !truncated
  4128	        let parserFinishReason = lengthTerminal && !filtered.hitStop
  4129	            ? "length"
  4130	            : (filtered.hitStop ? "request_stop" : "stop")
  4131	        let parsed = try parseGeneratedOutput(
  4132	            filteredText: filtered.text,
  4133	            generatedTokenIDs: generatedTokens,
  4134	            decode: decode,
  4135	            request: request,
  4136	            mode: .complete(finishReason: parserFinishReason),
  4137	            defaultCompletionTokens: completionTokenCount,
  4138	            stopTokenFilter: stopTokenFilter,
  4139	            requestStops: request.stop,
  4140	            globalHitStop: filtered.hitStop
  4141	        )
  4142	        let finishReason: String
  4143	        if !parsed.toolCalls.isEmpty {
  4144	            finishReason = "tool_calls"
  4145	        } else if lengthTerminal, !filtered.hitStop, !parsed.hitStop {
  4146	            finishReason = "length"
  4147	        } else {
  4148	            finishReason = "stop"
  4149	        }
  4150	        let kvCacheBytesReused = cachedPromptUTF8Bytes(
  4151	            promptTokenIds: promptTokenIDs,
  4152	            cachedPromptTokens: result.cachedPromptTokens,
  4153	            decode: decode
  4154	        )
  4155	        return ContinuousBatchFinalizedRow(
  4156	            completion: CompletionResult(
  4157	                content: parsed.content,
  4158	                finishReason: finishReason,
  4159	                promptTokens: promptTokenIDs.count,
  4160	                cachedPromptTokens: result.cachedPromptTokens,
  4161	                kvCacheBytesReused: kvCacheBytesReused,
  4162	                completionTokens: parsed.completionTokens,
  4163	                generatedCompletionTokens: parsed.generatedCompletionTokens,
  4164	                ttftMilliseconds: nil,
  4165	                generationMilliseconds: generationMilliseconds,
  4166	                toolCalls: parsed.toolCalls.isEmpty ? nil : parsed.toolCalls,
  4167	                modelHashObserved: validObservedModelHash(modelHash),
  4168	                settlementDisposition: result.settlementDisposition
  4169	            ),
  4170	            filteredText: filtered.text,
  4171	            parsed: parsed,
  4172	            generatedTokens: generatedTokens,
  4173	            truncatedAtSerialStop: truncated
  4174	        )
  4175	    }
  4176	
  4177	    /// SPEC-038 AC-6c: the batched streaming end, in the serial stream's
  4178	    /// order: remaining tool-call deltas and held-back content first, then
  4179	    /// the structured verdict on the buyer-visible text.
  4180	    static func finishContinuousBatchStream(
  4181	        _ finalized: ContinuousBatchFinalizedRow,
  4182	        state: AttachedPagedKVStreamState,
  4183	        request: ChatCompletionRequest,
  4184	        structuredAccumulator: StructuredStreamingContentAccumulator,
  4185	        idleState: StructuredStreamingIdleState,
  4186	        onChunk: (StreamChunk) -> Void
  4187	    ) throws -> CompletionResult {
  4188	        try state.finish(
  4189	            finalText: finalized.filteredText,
  4190	            parsed: finalized.parsed,
  4191	            structuredAccumulator: structuredAccumulator,
  4192	            idleState: idleState,
  4193	            onChunk: onChunk
  4194	        )
  4195	        return try validateStructuredStreamingCompletion(
  4196	            finalized.completion,
  4197	            request: request,
  4198	            buyerVisibleContent: structuredAccumulator.content
  4400	        }
  4401	        // SPEC-038 AC-6c: a serial tool turn stops where the serial path
  4402	        // stops generating (its first complete valid tool call).
  4403	        let serialToolStop = Self.serialToolStopApplies(request)
  4404	            ? ContinuousBatchSerialToolStopState(request: request)
  4405	            : nil
  4406	        let requestStops = request.stop
  4407	        let result: ContinuousBatchSchedulerResult
  4408	        do {
  4409	            CBTrace.log(schedulerRequestID, "rt_cb_submit")
  4410	            result = try await Self.withDrainAndClientCancellation(drainCancelled, shouldCancel: shouldCancel) {
  4411	                try await scheduler.submit(ContinuousBatchSchedulerRequest(
  4412	                    id: schedulerRequestID,
  4413	                    conversationKey: request.conversationKey ?? "",
  4414	                    promptTokens: prepared.promptTokens,
  4415	                    maxOutputTokens: maxOutputTokens,
  4416	                    stopTokenSequences: prepared.stopTokenSequences,
  4417	                    samplerSeed: ContinuousBatchRowSampler.requestSeed(requestID: schedulerRequestID),
  4418	                    temperature: request.temperature,
  4419	                    topP: request.topP,
  4420	                    presencePenalty: request.presencePenalty,
  4421	                    frequencyPenalty: request.frequencyPenalty,
  4422	                    cachedPromptTokens: lease?.cachedPromptTokens ?? 0,
  4423	                    retainedPagedKVSequence: lease?.reusableCache?.retainedPagedKVSequence,
  4424	                    recurrentCheckpointPositions: prepared.recurrentCheckpointPositions,
  4425	                    retainedRecurrentCheckpoints: Self.retainedRecurrentCheckpoints(for: lease)
  4426	                ), tokenSink: { event in
  4427	                    guard let serialToolStop else { return }
  4428	                    if serialToolStop.observe(
  4429	                        eventTokens: event.replayTokens ?? [event.token],
  4430	                        decode: detokenizer.decode,
  4431	                        stopTokenFilter: stopTokenFilter,
  4432	                        requestStops: requestStops
  4433	                    ) {
  4434	                        Task { await scheduler.stopEarly(requestID: schedulerRequestID) }
  4435	                    }
  4436	                })
  4437	            }
  4438	        } catch {
  4439	            if let lease {
  4440	                await conversationCache.abort(lease)
  4441	            }
  4442	            // SPEC-038 AC-25: one shared scheduler-error map, so the
  4443	            // non-streaming and streaming paths cannot drift.
  4444	            CBTrace.log(schedulerRequestID, "rt_cb_threw \(type(of: error))")
  4445	            throw (error as? ContinuousBatchSchedulerError)?.asAPIError() ?? error
  4446	        }
  4447	        CBTrace.log(schedulerRequestID, "rt_cb_returned status=\(result.terminalStatus)")
  4448	        do {
  4449	            try drainCancelled.check()
  4450	            try Task.checkCancellation()
  4451	            if shouldCancel() { throw CancellationError() }
  4452	            guard result.terminalStatus == .stop || result.terminalStatus == .length else {
  4453	                throw Self.terminalFailureError(code: result.errorCode ?? "continuous_batching_request_failed")
  4454	            }
  4455	            let completionEndedAt = Date()
  4456	            let finalized = try await container.perform { context in
  4457	                try Self.finalizeContinuousBatchRow(
  4458	                    request: request,
  4459	                    result: result,
  4460	                    modelStopTokenIDs: prepared.modelStopTokenIDs,
  4461	                    serialStopTokenCount: serialToolStop?.stopTokenCount,
  4462	                    promptTokenIDs: preparedPromptTokenIDs,
  4463	                    decode: { context.tokenizer.decode(tokenIds: $0) },
  4464	                    stopTokenFilter: stopTokenFilter,
  4465	                    generationMilliseconds: Int64(completionEndedAt.timeIntervalSince(completionStartedAt) * 1000),
  4466	                    modelHash: snapshot.modelHash
  4467	                )
  4468	            }
  4469	            let completion = try Self.validateStructuredCompletion(finalized.completion, request: request)
  4470	            let generatedTokens = finalized.generatedTokens
  4471	            if !finalized.truncatedAtSerialStop,
  4472	               let lease, let retainedCache = result.retainedCache,
  4473	               Self.retainedCacheIsCommittable(
  4474	                   retainedCache,
  4475	                   modelHasRecurrentLayers: prepared.modelHasRecurrentLayers
  4476	               ) {
  4477	                await conversationCache.commit(
  4478	                    lease,
  4479	                    cache: ConversationCacheLayers(
  4480	                        retainedCache.layers,
  4481	                        retainedPagedKVSequence: retainedCache.retainedSequence,
  4482	                        discardRetainedPagedKVSequence: { retained, key in
  4483	                            await scheduler.discardRetainedCache(retained, conversationKey: key)
  4484	                        },
  4485	                        recurrentCheckpoints: retainedCache.recurrentCheckpoints
  4486	                    ),
  4487	                    fullTokens: preparedPromptTokenIDs + generatedTokens.map(Int32.init)
  4488	                )
  4489	                await scheduler.acknowledgeRetainedCacheDelivery(retainedCache)
  4490	            } else if !finalized.truncatedAtSerialStop,
  4491	                      let lease, let serialCache = result.serialConversationCache,
  4492	                      let fullTokens = Self.serialConversationCacheCommitTokens(
  4493	                          canonicalTokens: preparedPromptTokenIDs + generatedTokens.map(Int32.init),
  4494	                          coveredTokenCount: serialCache.tokenCount
  4495	                      ) {
  4496	                // SPEC-038 FR-CB4 hybrid first turn: the next keyed turn serial-
  4497	                // routes (AC-26) and reuses this entry from its checkpoints.
  4498	                await conversationCache.commit(
  4499	                    lease,
  4500	                    cache: ConversationCacheLayers(
  4501	                        serialCache.layers,
  4502	                        recurrentCheckpoints: serialCache.recurrentCheckpoints
  4503	                    ),
  4504	                    fullTokens: fullTokens
  4505	                )
  4506	            } else if let retainedCache = result.retainedCache {
  4507	                await scheduler.cancelRetainedCacheDelivery(
  4508	                    retainedCache,
  4509	                    conversationKey: result.conversationKey
  4510	                )
  4511	                if let lease {
  4512	                    await conversationCache.abort(lease)
  4513	                }
  4514	            } else if let lease {
  4515	                await conversationCache.abort(lease)
  4516	            }
  4517	            return completion
  4518	        } catch {
  4519	            if let retainedCache = result.retainedCache {
  4520	                await scheduler.cancelRetainedCacheDelivery(
  4521	                    retainedCache,
  4522	                    conversationKey: result.conversationKey
  4523	                )
  4524	            }
  4525	            if let lease {
  4526	                await conversationCache.abort(lease)
  4527	            }
  4528	            throw error
  4529	        }
  4530	    }
  4531	
  4532	    nonisolated static func schedulerRequestID(for request: ChatCompletionRequest) -> String? {
  4533	        nonEmpty(request.requestID)
  4534	    }
  4535	
  4536	    private func attachedContinuousBatchStreamingCompletion(
  4537	        request: ChatCompletionRequest,
  4538	        snapshot: RuntimeSnapshot,
  4539	        capability: ContinuousBatchingCapability,
  4540	        completionStartedAt: Date,
  4541	        shouldCancel: @escaping @Sendable () -> Bool,
  4542	        drainCancelled: DrainCancelToken,
  4543	        structuredAccumulator: StructuredStreamingContentAccumulator,
  4544	        idleState: StructuredStreamingIdleState,
  4545	        idleCancellation: DrainCancelToken,
  4546	        onChunk: @escaping @Sendable (StreamChunk) -> Void
  4547	    ) async throws -> CompletionResult? {
  4548	        guard capability.isRequested,
  4549	              capability.unsupportedReason == nil,
  4550	              !capability.shouldUseSerialPath,
  4551	              case .attached = pagedKVAttachDecision
  4552	        else {
  4553	            return nil
  4554	        }
  4555	        guard let scheduler = continuousBatchScheduler else {
  4556	            throw Self.attachedPagedKVUnavailableError(code: "continuous_batching_scheduler_unavailable")
  4557	        }
  4558	        guard let schedulerRequestID = Self.schedulerRequestID(for: request) else {
  4559	            throw Self.attachedPagedKVUnavailableError(code: ContinuousBatchingUnsupportedReason.stableRequestIDUnavailable.apiCode)
  4560	        }
  4561	        guard let container = snapshot.container else {
  4562	            throw APIError(status: 503, message: "Model not loaded", type: "server_error", code: "model_not_loaded")
  4563	        }
  4564	
  4565	        let maxContextTokens = maxContextTokens
  4566	        let stopTokenFilter = stopTokenFilter
  4567	        let templateSupportsThinkingToggle = snapshot.templateSupportsThinkingToggle
  4568	        let requestStops = request.stop
  4569	        let (prepared, detokenizer) = try await container.perform { context -> (ContinuousBatchPreparedRequest, StreamingDetokenizer) in
  4570	            try drainCancelled.check()
  4571	            try Task.checkCancellation()
  4572	            let input = try Self.userInput(
  4573	                for: request,
  4574	                templateSupportsThinkingToggle: templateSupportsThinkingToggle
  4575	            )
  4576	            let lmInput = try await context.processor.prepare(input: input)
  4577	            let promptTokens = lmInput.text.tokens.asArray(Int32.self).map(Int.init)
  4578	            try Self.validatePromptTokenCount(promptTokens.count, maxContextTokens: maxContextTokens)
  4579	            let stopTokenSequences = Self.continuousBatchStopTokenSequences(
  4580	                requestStops: requestStops,
  4581	                context: context
  4582	            )
  4583	            let tokenizer = context.tokenizer
  4584	            // Only keyed requests can hold or reuse conversation state.
  4585	            let hybrid = Self.nonEmpty(request.conversationKey) != nil
  4586	                && ConversationCacheLayers.hasRecurrentLayers(context.model.newCache(parameters: nil))
  4587	            return (
  4588	                ContinuousBatchPreparedRequest(
  4589	                    promptTokens: promptTokens,
  4590	                    stopTokenSequences: stopTokenSequences,
  4591	                    modelStopTokenIDs: Self.generationStopTokenIDs(
  4592	                    for: Self.harmonyTerminalPreservingContext(from: context, modelID: request.model)
  4593	                ),
  4594	                    recurrentCheckpointPositions: Self.continuousBatchRecurrentCheckpointPositions(
  4595	                        promptTokens: promptTokens,
  4596	                        conversationKey: request.conversationKey,
  4597	                        hybrid: hybrid,
  4598	                        context: context
  4599	                    ),
  4600	                    modelHasRecurrentLayers: hybrid
  4601	                ),
  4602	                StreamingDetokenizer { tokenizer.decode(tokenIds: $0) }
  4603	            )
  4604	        }
  4605	
  4606	        try drainCancelled.check()
  4607	        try Task.checkCancellation()
  4608	        if shouldCancel() { throw CancellationError() }
  4609	        let streamState = AttachedPagedKVStreamState(request: request)
  4610	        let maxOutputTokens = request.maxTokens ?? max(1, maxContextTokens - prepared.promptTokens.count)
  4611	        let preparedPromptTokenIDs = prepared.promptTokens.map(Int32.init)
  4612	        let batchKVBits = Self.effectiveKVBits(
  4613	            configured: kvBitsOverride,
  4614	            conversationKey: request.conversationKey
  4615	        )
  4616	        let lease = await conversationCache.begin(
  4617	            conversationKey: request.conversationKey,
  4618	            incomingTokens: preparedPromptTokenIDs,
  4619	            modelID: request.model,
  4620	            kvBits: batchKVBits,
  4621	            allowRetainedPagedKVHandoff: true
  4622	        )
  4623	        if try await serialRouteCanaryCachedHitMissingRetainedHandoff(
  4624	            lease,
  4625	            capability: capability,
  4626	            modelHasRecurrentLayers: prepared.modelHasRecurrentLayers
  4627	        ) {
  4628	            return nil
  4629	        }
  4630	        let result: ContinuousBatchSchedulerResult
  4631	        do {
  4632	            // The SPEC-019 structured idle timeout ends the row as it ends the
  4633	            // serial generate loop.
  4634	            result = try await Self.withDrainAndClientCancellation(
  4635	                drainCancelled,
  4636	                shouldCancel: { shouldCancel() || idleCancellation.isFired }
  4637	            ) {
  4638	                try await scheduler.submit(ContinuousBatchSchedulerRequest(
  4639	                    id: schedulerRequestID,
  4640	                    conversationKey: request.conversationKey ?? "",
  4641	                    promptTokens: prepared.promptTokens,
  4642	                    maxOutputTokens: maxOutputTokens,
  4643	                    stopTokenSequences: prepared.stopTokenSequences,
  4644	                    samplerSeed: ContinuousBatchRowSampler.requestSeed(requestID: schedulerRequestID),
  4645	                    temperature: request.temperature,
  4646	                    topP: request.topP,
  4647	                    presencePenalty: request.presencePenalty,
  4648	                    frequencyPenalty: request.frequencyPenalty,
  4649	                    cachedPromptTokens: lease?.cachedPromptTokens ?? 0,
  4650	                    retainedPagedKVSequence: lease?.reusableCache?.retainedPagedKVSequence,
  4651	                    recurrentCheckpointPositions: prepared.recurrentCheckpointPositions,
  4652	                    retainedRecurrentCheckpoints: Self.retainedRecurrentCheckpoints(for: lease)
  4653	                ), tokenSink: { event in
  4654	                    guard !idleCancellation.isFired else { return }
  4655	                    if streamState.step(
  4656	                        eventTokens: event.replayTokens ?? [event.token],
  4657	                        decode: detokenizer.decode,
  4658	                        stopTokenFilter: stopTokenFilter,
  4659	                        requestStops: requestStops,
  4660	                        structuredAccumulator: structuredAccumulator,
  4661	                        idleState: idleState,
  4662	                        onChunk: onChunk
  4663	                    ) {
  4664	                        Task { await scheduler.stopEarly(requestID: schedulerRequestID) }
  4665	                    }
  4666	                })
  4667	            }
  4668	        } catch {
  4669	            if let lease {
  4670	                await conversationCache.abort(lease)
  4671	            }
  4672	            // SPEC-038 AC-25: one shared scheduler-error map, so the
  4673	            // streaming and non-streaming paths cannot drift.
  4674	            throw (error as? ContinuousBatchSchedulerError)?.asAPIError() ?? error
  4675	        }
  4676	        do {
  4677	            if let error = streamState.error() {
  4678	                throw error
  4679	            }
  4680	            try drainCancelled.check()
  4681	            try Task.checkCancellation()
  4682	            if shouldCancel() { throw CancellationError() }
  4683	            guard result.terminalStatus == .stop || result.terminalStatus == .length else {
  4684	                throw Self.terminalFailureError(code: result.errorCode ?? "continuous_batching_request_failed")
  4685	            }
  4686	            let completionEndedAt = Date()
  4687	            let finalized = try await container.perform { context in
  4688	                try Self.finalizeContinuousBatchRow(
  4689	                    request: request,
  4690	                    result: result,
  4691	                    modelStopTokenIDs: prepared.modelStopTokenIDs,
  4692	                    serialStopTokenCount: streamState.serialStopTokenCount,
  4693	                    promptTokenIDs: preparedPromptTokenIDs,
  4694	                    decode: { context.tokenizer.decode(tokenIds: $0) },
  4695	                    stopTokenFilter: stopTokenFilter,
  4696	                    generationMilliseconds: Int64(completionEndedAt.timeIntervalSince(completionStartedAt) * 1000),
  4697	                    modelHash: snapshot.modelHash
  4698	                )
  4699	            }
  4700	            // #1690 E2E-F13: the stream held back an incomplete UTF-8 tail
  4701	            // and any stop-string prefix; the serial stream's end sends the
  4702	            // remainder as the final text renders it, so the buyer's bytes
  4703	            // equal the receipt's.
  4704	            let validated = try Self.finishContinuousBatchStream(
  4705	                finalized,
  4706	                state: streamState,
  4707	                request: request,
  4708	                structuredAccumulator: structuredAccumulator,
  4709	                idleState: idleState,
  4710	                onChunk: onChunk
  4711	            )
  4712	            let generatedTokens = finalized.generatedTokens
  4713	            if !finalized.truncatedAtSerialStop,
  4714	               let lease, let retainedCache = result.retainedCache,
  4715	               Self.retainedCacheIsCommittable(
  4716	                   retainedCache,
  4717	                   modelHasRecurrentLayers: prepared.modelHasRecurrentLayers
  4718	               ) {
  4719	                await conversationCache.commit(
  4720	                    lease,
  4721	                    cache: ConversationCacheLayers(
  4722	                        retainedCache.layers,
  4723	                        retainedPagedKVSequence: retainedCache.retainedSequence,
  4724	                        discardRetainedPagedKVSequence: { retained, key in
  4725	                            await scheduler.discardRetainedCache(retained, conversationKey: key)
  7500	        case .string(let choice):
  7501	            // OpenAI/Pi send "required". We do not force a call, but rejecting it
  7502	            // with 400/502 is worse than treating it as auto.
  7503	            return choice == "auto" || choice == "required"
  7504	        case .null:
  7505	            return true
  7506	        default:
  7507	            return false
  7508	        }
  7509	    }
  7510	}
  7511	
  7512	/// The serial streaming path's buyer-visible text step for non-Harmony output:
  7513	/// incremental tool-call deltas (SPEC-018), assistant-content suppression once
  7514	/// a tool call opens, the SPEC-019 structured-content accumulator, and the
  7515	/// serial-tool-turn stop. The serial `stream` path and the continuous-batching
  7516	/// stream sink (SPEC-038 AC-6c) both drive this one type, so a batched
  7517	/// tool-bearing or structured-output row emits the serial SSE sequence.
  7518	struct SerialStreamingTextEmitter {
  7519	    enum Step: Equatable {
  7520	        case more
  7521	        /// A buyer `stop` string matched in the decoded text.
  7522	        case requestStop
  7523	        /// A serial tool turn completed its first valid tool call.
  7524	        case toolCallComplete
  7525	        /// The structured-output accumulator refused the delta (its error is
  7526	        /// held by the accumulator).
  7527	        case structuredError
  7528	    }
  7529	
  7530	    private let streamToolsIncrementally: Bool
  7531	    private let stopsAfterFirstCompleteToolCall: Bool
  7532	    private var toolStreamer: NativeToolCallStreamEmitter
  7533	    private(set) var emittedText = ""
  7534	
  7535	    init(request: ChatCompletionRequest) {
  7536	        streamToolsIncrementally = ModelRuntime.hasEnabledTools(request.promptSource.tools)
  7537	            && !HarmonyResponseParser.isHarmonyModelID(request.model)
  7538	        stopsAfterFirstCompleteToolCall = request.stopsAfterFirstCompleteToolCall
  7539	        toolStreamer = NativeToolCallStreamEmitter(
  7540	            modelID: request.model,
  7541	            allowedFunctionNames: ModelRuntime.toolFunctionNames(from: request.promptSource.tools)
  7542	        )
  7543	    }
  7544	
  7545	    /// One decoded prefix of the generation (`streamingSafePrefix` of every
  7546	    /// token so far).
  7547	    mutating func step(
  7548	        candidate: (text: String, hitStop: Bool),
  7549	        structuredAccumulator: StructuredStreamingContentAccumulator,
  7550	        idleState: StructuredStreamingIdleState,
  7551	        onChunk: (StreamChunk) -> Void
  7552	    ) -> Step {
  7553	        if streamToolsIncrementally {
  7554	            for event in toolStreamer.observe(candidate.text) {
  7555	                onChunk(event)
  7556	            }
  7557	            if !toolStreamer.suppressesAssistantContent {
  7558	                let safe = toolStreamer.visibleContentPrefix(of: candidate.text)
  7559	                let delta = ModelRuntime.streamDelta(from: emittedText, to: safe)
  7560	                if !delta.isEmpty {
  7561	                    if structuredAccumulator.append(delta) != nil {
  7562	                        return .structuredError
  7563	                    }
  7564	                    idleState.noteContent()
  7565	                    emittedText = safe
  7566	                    onChunk(.content(delta))
  7567	                }
  7568	            }
  7569	            if stopsAfterFirstCompleteToolCall, toolStreamer.hasCompletedValidToolCall {
  7570	                return .toolCallComplete
  7571	            }
  7572	            return candidate.hitStop ? .requestStop : .more
  7573	        }
  7574	
  7575	        let delta = ModelRuntime.streamDelta(from: emittedText, to: candidate.text)
  7576	        if !delta.isEmpty {
  7577	            if structuredAccumulator.append(delta) != nil {
  7578	                return .structuredError
  7579	            }
  7580	            idleState.noteContent()
  7581	            emittedText = candidate.text
  7582	            onChunk(.content(delta))
  7583	        }
  7584	        return candidate.hitStop ? .requestStop : .more
  7585	    }
  7586	
  7587	    /// The end of generation: remaining tool-call deltas over the final
  7588	    /// filtered text, then any content the stream held back.
  7589	    mutating func finish(
  7590	        finalText: String,
  7591	        parsed: ModelRuntime.ParsedGeneratedOutput,
  7592	        structuredAccumulator: StructuredStreamingContentAccumulator,
  7593	        idleState: StructuredStreamingIdleState,
  7594	        onChunk: (StreamChunk) -> Void
  7595	    ) throws {
  7596	        let finalDelta = ModelRuntime.streamDelta(from: emittedText, to: parsed.content)
  7597	        if streamToolsIncrementally {
  7598	            for event in toolStreamer.observe(finalText) {
  7599	                onChunk(event)
  7600	            }
  7601	            if parsed.toolCalls.isEmpty,
  7602	               !parsed.content.isEmpty,
  7603	               !toolStreamer.suppressesAssistantContent
  7604	            {
  7605	                let contentDelta = ModelRuntime.streamDelta(from: emittedText, to: parsed.content)
  7606	                if !contentDelta.isEmpty {
  7607	                    if let error = structuredAccumulator.append(contentDelta) {
  7608	                        throw error
  7609	                    }
  7610	                    idleState.noteContent()
  7611	                    onChunk(.content(contentDelta))
  7612	                }
  7613	            }
  7614	        } else if !finalDelta.isEmpty {
  7615	            if let error = structuredAccumulator.append(finalDelta) {
  7616	                throw error
  7617	            }
  7618	            idleState.noteContent()
  7619	            onChunk(.content(finalDelta))
  7620	        }
  7621	        if let error = structuredAccumulator.error {
  7622	            throw error
  7623	        }
  7624	    }
  7625	}
  1365	            }
  1366	        } onCancel: {
  1367	            Task { await self.cancelWaiter(requestID: request.id, waiterID: waiterID) }
  1368	        }
  1369	    }
  1370	
  1371	    func cancel(requestID: String) {
  1372	        guard terminalResults[requestID] == nil, knownRequests[requestID] != nil else { return }
  1373	        // Once generation has produced its terminal result, accepted token
  1374	        // delivery owns completion ordering. Cancellation cannot overtake that
  1375	        // delivery fence and rewrite the already-decided terminal state.
  1376	        if pendingTerminalDeliveries[requestID] != nil {
  1377	            return
  1378	        }
  1379	        cancelledIDs.insert(requestID)
  1380	        ensurePump()
  1381	    }
  1382	
  1383	    /// SPEC-038 AC-6c: end a decoding row as a normal `.stop` at its next
  1384	    /// applied token. The serial path stops a serial tool turn (SPEC-018,
  1385	    /// `parallel_tool_calls` omitted/false) once the first tool call is
  1386	    /// complete; the batched caller truncates the row's tokens back to that
  1387	    /// exact point, so this only bounds wasted decode. A row that is not
  1388	    /// decoding (queued, prefilling, or already terminal) is left alone.
  1389	    func stopEarly(requestID: String) {
  1390	        guard activeDecode[requestID] != nil else { return }
  1391	        earlyStopIDs.insert(requestID)
  1392	    }
  1393	
  1394	    func drain() async throws -> ContinuousBatchDrainPermit {
  1395	        guard !cleanupFailedClosed else {
  2215	    }
  2216	
  2217	    private func applyToken(_ token: Int, to initialRow: Row) async {
  2218	        guard var row = activeDecode[initialRow.request.id] else { return }
  2219	        row.generatedTokens.append(token)
  2220	        row.currentToken = token
  2221	        row.pendingOutputTokens.append(token)
  2222	
  2223	        let terminalStatus: ContinuousBatchSchedulerTerminalStatus?
  2224	        if let stopLength = matchingStopLength(
  2225	            row.generatedTokens,
  2226	            stopSequences: row.request.stopTokenSequences
  2227	        ) {
  2228	            guard stopLength <= row.pendingOutputTokens.count else {
  2229	                activeDecode.removeValue(forKey: row.request.id)
  2230	                let released = await release(row.handle)
  2231	                finish(
  2232	                    row,
  2233	                    status: .requestFailed,
  2234	                    errorCode: released
  2235	                        ? "continuous_batching_stop_filter_state_invalid"
  2236	                        : "continuous_batching_cleanup_failed"
  2237	                )
  2238	                return
  2239	            }
  2240	            row.pendingOutputTokens.removeLast(stopLength)
  2241	            terminalStatus = .stop
  2242	        } else if earlyStopIDs.contains(row.request.id) {
  2243	            terminalStatus = .stop
  2244	        } else if row.generatedTokens.count >= row.request.maxOutputTokens {
  2245	            terminalStatus = .length
  2246	        } else {
  2247	            terminalStatus = nil
  2248	        }
  2249	
  2250	        let visibleTokens: [Int]
  2251	        if terminalStatus != nil {
  2252	            visibleTokens = row.pendingOutputTokens
  2253	            row.pendingOutputTokens.removeAll(keepingCapacity: true)
  2254	        } else {
  2255	            var ready: [Int] = []
  2256	            while let first = row.pendingOutputTokens.first,
  2257	                  !isPotentialStopPrefix(
  2258	                      row.pendingOutputTokens,
  2259	                      stopSequences: row.request.stopTokenSequences
  2260	                  ) {
  2261	                ready.append(first)
  2262	                row.pendingOutputTokens.removeFirst()
  2263	            }
  2264	            visibleTokens = ready
  2265	        }
  2266	
  2267	        let firstVisibleIndex = row.outputTokens.count
  2268	        row.outputTokens.append(contentsOf: visibleTokens)
  2269	        activeDecode[row.request.id] = row
  2270	        CBTrace.log(row.request.id, "sch_active")
  2271	        if !deliverVisibleTokens(
  2272	            visibleTokens,
  2273	            firstIndex: firstVisibleIndex,
  2274	            row: row
  2275	        ) {
  2276	            activeDecode.removeValue(forKey: row.request.id)
  2277	            let released = await release(row.handle)
  2278	            // Post-token, like the `.deliveryBackpressure` thrown at the
  2279	            // waiter above: this row was decoding when its last consumer
  2280	            // refused an event. The terminal result is replayable to a later
  2281	            // duplicate of the same request id, so it must not carry the
  2282	            // pre-admission code — that one is retryable and this is not.
  2283	            finish(
  2284	                row,
  2285	                status: .requestFailed,
  2760	
  2761	    private func finish(
  2762	        _ row: Row,
  2763	        status: ContinuousBatchSchedulerTerminalStatus,
  2764	        errorCode: String?,
  2765	        serialConversationCache: ContinuousBatchSerialConversationCache? = nil
  2766	    ) {
  2767	        earlyStopIDs.remove(row.request.id)
  2768	        record(status == .cancelled ? .cancelled : .stopped)
  2769	        let isSuccessful = status == .stop || status == .length
  2770	        let outputTokens = isSuccessful ? row.outputTokens : []
  2771	        let result = ContinuousBatchSchedulerResult(
  2772	            requestID: row.request.id,
  2773	            conversationKey: row.request.conversationKey,
  2774	            generatedTokens: isSuccessful ? row.generatedTokens : [],
  2775	            outputTokens: outputTokens,
  2776	            promptTokens: row.request.promptTokens.count,
  2777	            completionTokens: isSuccessful ? row.generatedTokens.count : 0,
  2778	            emittedTokens: row.outputTokens.count,
  2779	            cachedPromptTokens: row.request.cachedPromptTokens,
  2780	            terminalStatus: status,
  2781	            errorCode: errorCode,
  2782	            snapshot: row.snapshot,
  2783	            settlementDisposition: isSuccessful ? .eligibleOwner : .notEligible,
  2784	            retainedCache: nil,
  2785	            serialConversationCache: isSuccessful ? serialConversationCache : nil
  2786	        )
  2787	        complete(requestID: row.request.id, result: result)
  2788	    }
  2789	
  2790	    private func finish(
  2791	        _ row: Row,
  2792	        status: ContinuousBatchSchedulerTerminalStatus,
  2793	        errorCode: String?,
  2794	        retainedCache: ContinuousBatchRetainedCache?
  2795	    ) {
  2796	        earlyStopIDs.remove(row.request.id)
  2797	        record(status == .cancelled ? .cancelled : .stopped)
  2798	        let isSuccessful = status == .stop || status == .length
  2799	        let outputTokens = isSuccessful ? row.outputTokens : []
  2800	        let result = ContinuousBatchSchedulerResult(
  2801	            requestID: row.request.id,
  2802	            conversationKey: row.request.conversationKey,
  2803	            generatedTokens: isSuccessful ? row.generatedTokens : [],
  2804	            outputTokens: outputTokens,
  2805	            promptTokens: row.request.promptTokens.count,
  2806	            completionTokens: isSuccessful ? row.generatedTokens.count : 0,
  2807	            emittedTokens: row.outputTokens.count,
  2808	            cachedPromptTokens: row.request.cachedPromptTokens,
  2809	            terminalStatus: status,
  2810	            errorCode: errorCode,
  2811	            snapshot: row.snapshot,
  2812	            settlementDisposition: isSuccessful ? .eligibleOwner : .notEligible,
  2813	            retainedCache: isSuccessful ? retainedCache : nil
  2814	        )
  2815	        complete(requestID: row.request.id, result: result)

exec
/bin/bash -lc "rg -n \"requestStateRepresentable|applyContinuousBatchingPolicy|continuousBatchingCapability\\(|attachedContinuousBatch(Streaming)?Completion|serialToolStopApplies|observeSerialToolStop\" phase3-binary/Sources/macprovider-cli/ModelRuntime.swift phase3-binary/Sources/macprovider-cli/*.swift | head -240" in /Users/augstar/macprovider-1646-rest
 succeeded in 0ms:
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:2479:        let capability = continuousBatchingCapability(draftConfigured: currentDraftModelID != nil)
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:3092:        continuousBatchingCapability(
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:3097:    private func continuousBatchingCapability(
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:3100:        requestStateRepresentable: Bool = true
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:3127:            requestStateRepresentable: requestStateRepresentable,
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:3382:    static func requestStateRepresentable(_ request: ChatCompletionRequest) -> Bool {
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:3433:    private func applyContinuousBatchingPolicy(
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:3438:        let capability = continuousBatchingCapability(
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:3441:            requestStateRepresentable: Self.requestStateRepresentable(request)
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:3810:        _ = try applyContinuousBatchingPolicy(request: request, snapshot: handle.snapshot)
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:3840:            _ = try applyContinuousBatchingPolicy(request: request, snapshot: handle.snapshot)
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:3870:        _ = try applyContinuousBatchingPolicy(request: request, snapshot: handle.snapshot)
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4040:            guard ModelRuntime.observeSerialToolStop(
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4311:    private func attachedContinuousBatchCompletion(
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4403:        let serialToolStop = Self.serialToolStopApplies(request)
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4536:    private func attachedContinuousBatchStreamingCompletion(
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4951:        let continuousBatchingCapability = try applyContinuousBatchingPolicy(
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4959:        if let completion = try await attachedContinuousBatchCompletion(
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:5120:                            let serialToolStopApplies = Self.serialToolStopApplies(request)
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:5134:                                    if serialToolStopApplies,
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:5135:                                       Self.observeSerialToolStop(
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:5458:        let continuousBatchingCapability = try applyContinuousBatchingPolicy(
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:5483:            try await self.attachedContinuousBatchStreamingCompletion(
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:7047:    static func serialToolStopApplies(_ request: ChatCompletionRequest) -> Bool {
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:7056:    static func observeSerialToolStop(
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:2479:        let capability = continuousBatchingCapability(draftConfigured: currentDraftModelID != nil)
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:3092:        continuousBatchingCapability(
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:3097:    private func continuousBatchingCapability(
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:3100:        requestStateRepresentable: Bool = true
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:3127:            requestStateRepresentable: requestStateRepresentable,
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:3382:    static func requestStateRepresentable(_ request: ChatCompletionRequest) -> Bool {
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:3433:    private func applyContinuousBatchingPolicy(
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:3438:        let capability = continuousBatchingCapability(
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:3441:            requestStateRepresentable: Self.requestStateRepresentable(request)
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:3810:        _ = try applyContinuousBatchingPolicy(request: request, snapshot: handle.snapshot)
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:3840:            _ = try applyContinuousBatchingPolicy(request: request, snapshot: handle.snapshot)
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:3870:        _ = try applyContinuousBatchingPolicy(request: request, snapshot: handle.snapshot)
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4040:            guard ModelRuntime.observeSerialToolStop(
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4311:    private func attachedContinuousBatchCompletion(
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4403:        let serialToolStop = Self.serialToolStopApplies(request)
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4536:    private func attachedContinuousBatchStreamingCompletion(
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4951:        let continuousBatchingCapability = try applyContinuousBatchingPolicy(
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4959:        if let completion = try await attachedContinuousBatchCompletion(
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:5120:                            let serialToolStopApplies = Self.serialToolStopApplies(request)
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:5134:                                    if serialToolStopApplies,
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:5135:                                       Self.observeSerialToolStop(
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:5458:        let continuousBatchingCapability = try applyContinuousBatchingPolicy(
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:5483:            try await self.attachedContinuousBatchStreamingCompletion(
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:7047:    static func serialToolStopApplies(_ request: ChatCompletionRequest) -> Bool {
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:7056:    static func observeSerialToolStop(
phase3-binary/Sources/macprovider-cli/ContinuousBatching.swift:262:        requestStateRepresentable: Bool = true,
phase3-binary/Sources/macprovider-cli/ContinuousBatching.swift:280:            requestStateRepresentable: requestStateRepresentable,
phase3-binary/Sources/macprovider-cli/ContinuousBatching.swift:299:        requestStateRepresentable: Bool = true,
phase3-binary/Sources/macprovider-cli/ContinuousBatching.swift:314:        } else if !requestStateRepresentable {

exec
/bin/bash -lc "sed -n '4900,5185p;5425,5510p;7028,7095p' phase3-binary/Sources/macprovider-cli/ModelRuntime.swift" in /Users/augstar/macprovider-1646-rest
 succeeded in 0ms:
                        if Task.isCancelled || inferenceCancellation.isCancelled || shouldCancel() {
                            cancellation.record()
                            return .stop
                        }
                        return .more
                    })
                }
            }
        }
        if cancellation.wasCancelled || Task.isCancelled || shouldCancel() {
            throw CancellationError()
        }
        let elapsed = Date().timeIntervalSince(startedAt) * 1000.0
        return InternalWarmupResult(
            tokensGenerated: result.generationTokenCount,
            firstTokenElapsedMS: Double(firstToken.elapsedMilliseconds(since: startedAt) ?? Int64(elapsed)),
            totalElapsedMS: elapsed
        )
    }

    /// SPEC-015 §M.2.2 — atomic snapshot capture inside the actor
    /// turn that started inference. The returned snapshot IS the
    /// container that served the response (in-flight tracking pins
    /// it for the request lifetime per SPEC-011 R-3.4.1). Callers
    /// MUST bind the receipt's `model_hash` to this snapshot, NOT to
    /// a separately-sampled `currentSnapshot()`.
    func completeWithServedSnapshot(
        _ request: ChatCompletionRequest,
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) async throws -> (CompletionResult, RuntimeSnapshot) {
        let handle = try acquireRequestHandle(request)
        defer { unregisterInFlight(handle.registrationID) }
        return try await completeWithServedSnapshot(request, with: handle, shouldCancel: shouldCancel)
    }

    func completeWithServedSnapshot(
        _ request: ChatCompletionRequest,
        with handle: RequestHandle,
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) async throws -> (CompletionResult, RuntimeSnapshot) {
        // SPEC-025 §5.2 model-liveness: mark active buyer inference so a stalled
        // progress token is interpretable as a wedge (observability only).
        ModelLivenessTracker.shared.beginInference()
        defer { ModelLivenessTracker.shared.endInference() }
        let completionStartedAt = Date()
        let snapshot = handle.snapshot
        let drainCancelled = handle.drainCancelled
        // Non-streaming execution is a direct entry path with no preceding
        // preflight (HTTP + relay), so it OWNS the single serial-route telemetry
        // emission for this request. (Streaming preflights first and suppresses
        // here to stay exactly-once.)
        let continuousBatchingCapability = try applyContinuousBatchingPolicy(
            request: request,
            snapshot: snapshot,
            emitTelemetry: true
        )
        try Self.enforcePagedKVPreflight(pagedKVAttachDecision)
        try drainCancelled.check()
        CBTrace.log(request.requestID, "rt_complete_enter")
        if let completion = try await attachedContinuousBatchCompletion(
            request: request,
            snapshot: snapshot,
            capability: continuousBatchingCapability,
            completionStartedAt: completionStartedAt,
            shouldCancel: shouldCancel,
            drainCancelled: drainCancelled
        ) {
            return (completion, snapshot)
        }
        CBTrace.log(request.requestID, "rt_serial_path")
        if speculativeCacheWrapValidated,
           let testSpeculativeCompletion,
           Self.speculativeRoute(
               for: request,
               draftLoaded: snapshot.hasTargetCompatibleDraft,
               numDraftTokens: snapshot.numDraftTokens
           ) == .speculative {
            do {
                let result = try await Self.withDrainCancellation(drainCancelled) {
                    try await testSpeculativeCompletion(snapshot, request)
                }
                return (try Self.validateStructuredCompletion(result, request: request).withModelHashObservedIfMissing(Self.validObservedModelHash(snapshot.modelHash)), snapshot)
            } catch let error as DrainCancelledError {
                throw error
            } catch let error as CancellationError {
                throw error
            } catch let error as SpeculativeGenerationFailure {
                Self.logSpeculativeFallback(error)
            }
        }
        if let testCompletion {
            let result = try await Self.withDrainCancellation(drainCancelled) {
                try await testCompletion(snapshot, request)
            }
            return (try Self.validateStructuredCompletion(result, request: request).withModelHashObservedIfMissing(Self.validObservedModelHash(snapshot.modelHash)), snapshot)
        }
        guard let container = snapshot.container else {
            throw APIError(status: 503, message: "Model not loaded", type: "server_error", code: "model_not_loaded")
        }

        let maxContextTokens = maxContextTokens
        let kvBitsOverride = Self.effectiveKVBits(
            configured: kvBitsOverride,
            conversationKey: request.conversationKey
        )
        let speculativeCacheWrapValidated = speculativeCacheWrapValidated
        let prefillStepSize = prefillStepSize
        let conversationCache = conversationCache
        // SPEC-037 stage 5 — per-request cold-tier context, captured before the
        // nonisolated inference closure (nil unless the disk tier is attached).
        let coldContext = coldContext(for: request, snapshot: snapshot)
        let inferenceGate = inferenceGate
        let blockingInferenceExecutor = blockingInferenceExecutor
        let stopTokenFilter = stopTokenFilter
        let templateSupportsThinkingToggle = snapshot.templateSupportsThinkingToggle
        let completion = try await Self.withDrainCancellation(drainCancelled) {
            try await inferenceGate.withPermit {
                try drainCancelled.check()
                try Task.checkCancellation()
                return try await container.perform { context in
                    try drainCancelled.check()
                    try Task.checkCancellation()
                    let input = try Self.userInput(
                        for: request,
                        templateSupportsThinkingToggle: templateSupportsThinkingToggle
                    )
                    let lmInput = try await context.processor.prepare(input: input)
                    try Self.validatePromptTokenCount(lmInput.text.tokens.size, maxContextTokens: maxContextTokens)
                    let parameters = Self.makeServeGenerateParameters(
                        maxTokens: request.maxTokens,
                        maxContextTokens: maxContextTokens,
                        kvBitsOverride: kvBitsOverride,
                        prefillStepSize: prefillStepSize,
                        temperature: Float(request.temperature),
                        topP: Float(request.topP)
                    )
                    let firstToken = FirstTokenRecorder()
                    let promptTokenIds: [Int32] = lmInput.text.tokens.asArray(Int32.self)
                    if Self.speculativeRoute(
                        for: request,
                        draftLoaded: snapshot.hasTargetCompatibleDraft && snapshot.draftContainer != nil,
                        numDraftTokens: snapshot.numDraftTokens
                    ) == .speculative,
                       let draftContainer = snapshot.draftContainer,
                       let numDraftTokens = snapshot.numDraftTokens,
                       speculativeCacheWrapValidated,
                       Self.speculativeCacheWindowSafe(
                           promptTokens: promptTokenIds.count,
                           maxTokens: request.maxTokens,
                           maxContextTokens: maxContextTokens,
                           numDraftTokens: numDraftTokens
                       ) {
                        do {
                            return try await Self.runSpeculativeCompletion(
                                input: lmInput,
                                parameters: parameters,
                                targetContext: context,
                                draft: draftContainer,
                                numDraftTokens: numDraftTokens,
                                request: request,
                                stopTokenFilter: stopTokenFilter,
                                promptTokenCount: promptTokenIds.count,
                                completionStartedAt: completionStartedAt,
                                modelHash: snapshot.modelHash,
                                specDecodeGeneration: snapshot.specDecodeGeneration,
                                shouldCancel: shouldCancel,
                                drainCancelled: drainCancelled,
                                blockingInferenceExecutor: blockingInferenceExecutor
                            )
                        } catch let error as DrainCancelledError {
                            throw error
                        } catch let error as CancellationError {
                            throw error
                        } catch let error as SpeculativeGenerationFailure {
                            // FR-12 permits one pre-output retry on the existing
                            // non-speculative target path. This branch happens
                            // before any buyer-visible response exists for the
                            // non-streaming endpoint.
                            Self.logSpeculativeFallback(error)
                        }
                    }
                    let lease = await conversationCache.begin(
                        conversationKey: request.conversationKey,
                        incomingTokens: promptTokenIds,
                        modelID: request.model,
                        kvBits: kvBitsOverride,
                        cold: coldContext
                    )
                        do {
                            let generationContext = Self.harmonyTerminalPreservingContext(from: context, modelID: request.model)
                            let kvCache: [KVCache]
                            var iteratorInput: LMInput
                            if let reusableCache = lease?.reusableCache, let lcp = lease?.lcp {
                                kvCache = reusableCache.layers
                                iteratorInput = LMInput(tokens: MLXArray(Array(promptTokenIds[lcp...])))
                            } else {
                                // SPEC-037 FR-KVP1 / SPEC-024-R001: eligible persist and
                                // keyed serial reuse allocate KVCacheSimple; keyless traffic
                                // keeps the rotating cap. TokenIterator still gets the
                                // original `parameters` (its maxKVSize is ignored once the
                                // cache is passed explicitly).
                                kvCache = Self.serveCache(
                                    model: generationContext.model, baseParameters: parameters,
                                    forceSimpleKV: Self.forceSimpleKVCache(
                                        eligible: coldContext?.eligible == true,
                                        conversationKey: request.conversationKey))
                                iteratorInput = lmInput
                            }
                            let recurrent = Self.prefillRecurrentCheckpoints(
                                lease: lease, cache: kvCache, promptTokenIds: promptTokenIds,
                                context: generationContext, prefillStepSize: parameters.prefillStepSize)
                            if let resumeAt = recurrent.resumeAt {
                                iteratorInput = LMInput(tokens: MLXArray(Array(promptTokenIds[resumeAt...])))
                            }

                            let iterator = try TokenIterator(input: iteratorInput, model: generationContext.model, cache: kvCache, parameters: parameters)
                            var serialToolObserver = NativeToolCallStreamEmitter(
                                modelID: request.model,
                                allowedFunctionNames: Self.toolFunctionNames(from: request.promptSource.tools)
                            )
                            let serialToolStopApplies = Self.serialToolStopApplies(request)
                            let result: BlockingGenerateResult = try await blockingInferenceExecutor.run { inferenceCancellation in
                                BlockingGenerateResult(generate(input: iteratorInput, context: generationContext, iterator: iterator) { tokens in
                                    if !tokens.isEmpty {
                                        firstToken.recordIfMissing()
                                        ModelLivenessTracker.shared.recordProgress()
                                    }
                                    if Task.isCancelled || inferenceCancellation.isCancelled || shouldCancel() || drainCancelled.isFired {
                                        return GenerateDisposition.stop
                                    }
                                    if HarmonyResponseParser.isHarmonyModelID(request.model),
                                       tokens.last.map(Self.isHarmonyTerminalToken) == true {
                                        return GenerateDisposition.stop
                                    }
                                    if serialToolStopApplies,
                                       Self.observeSerialToolStop(
                                           &serialToolObserver,
                                           decoded: generationContext.tokenizer.decode(tokenIds: tokens),
                                           stopTokenFilter: stopTokenFilter,
                                           requestStops: request.stop
                                       )
                                    {
                                        return GenerateDisposition.stop
                                    }
                                    return GenerateDisposition.more
                                })
                            }
                            try drainCancelled.check()
                            try Task.checkCancellation()
                            if shouldCancel() {
                                throw CancellationError()
                            }
                            let resultTokenIDs = result.tokenIds

                        guard result.output.utf8.count <= ToolCallParser.SPEC018_ARGUMENTS_PER_RESPONSE_BYTE_CAP else {
                            throw APIError(
                                status: 502,
                                message: "Model response exceeded 2097152 bytes",
                                type: "upstream_provider_error",
                                code: "response_byte_cap_exceeded",
                                inferenceRan: true,
                                settlementRan: true
                            )
                        }

                        let filtered = Self.applyOutputFilters(
                            result.output,
                            stopTokenFilter: stopTokenFilter,
                            requestStops: request.stop
                        )

                        let rawLengthFinish = request.maxTokens.map { result.generationTokenCount >= $0 } ?? false
                        let harmonyTerminalFinish = Self.isHarmonyTerminalFinish(
                            modelID: request.model,
                            generatedTokenIDs: resultTokenIDs
                        )
                        let parserFinishReason = HarmonyResponseParser.isHarmonyModelID(request.model)
                            ? (rawLengthFinish && !filtered.hitStop && !harmonyTerminalFinish ? "length" : (filtered.hitStop ? "request_stop" : "stop"))
                            : (rawLengthFinish && !filtered.hitStop ? "length" : (filtered.hitStop ? "request_stop" : "stop"))
                        let parsed = try Self.parseGeneratedOutput(
                            filteredText: filtered.text,
                            generatedTokenIDs: resultTokenIDs,
                            decode: { context.tokenizer.decode(tokenIds: $0) },
                            request: request,
                            mode: .complete(finishReason: parserFinishReason),
                            defaultCompletionTokens: result.generationTokenCount,
              let last = generatedTokens.last,
              modelStopTokenIDs.contains(last) else {
            return generatedTokens
        }
        return Array(generatedTokens.dropLast())
    }

    private static func generationStopTokenIDs(for context: ModelContext) -> Set<Int> {
        var stopTokenIDs = context.configuration.eosTokenIds
        let tokenizer = context.tokenizer
        if let eosTokenID = tokenizer.eosTokenId {
            stopTokenIDs.insert(eosTokenID)
        }
        for token in context.configuration.extraEOSTokens {
            if let tokenID = tokenizer.convertTokenToId(token) {
                stopTokenIDs.insert(tokenID)
            }
        }
        return stopTokenIDs
    }

    func stream(
        _ request: ChatCompletionRequest,
        with handle: RequestHandle,
        shouldCancel: @escaping @Sendable () -> Bool = { false },
        onChunk: @escaping @Sendable (StreamChunk) -> Void
    ) async throws -> CompletionResult {
        // SPEC-025 §5.2 model-liveness: mark active buyer inference so a stalled
        // progress token is interpretable as a wedge (observability only).
        ModelLivenessTracker.shared.beginInference()
        defer { ModelLivenessTracker.shared.endInference() }
        let snapshot = handle.snapshot
        let drainCancelled = handle.drainCancelled
        let continuousBatchingCapability = try applyContinuousBatchingPolicy(
            request: request,
            snapshot: snapshot,
            emitTelemetry: false
        )
        try Self.enforcePagedKVPreflight(pagedKVAttachDecision)
        let structuredAccumulator = StructuredStreamingContentAccumulator(enabled: Self.requiresStructuredValidation(request.responseFormat))
        let idleState = StructuredStreamingIdleState(enabled: Self.requiresStructuredValidation(request.responseFormat))
        // SPEC-038 AC-6c: a batched structured-output stream runs under the
        // same SPEC-019 idle timeout as the serial one. It gets its own idle
        // state because the timeout race marks its state finished, and a
        // batched attempt that serial-routes (nil) must leave the serial
        // stream's timeout armed.
        let batchedIdleState = StructuredStreamingIdleState(enabled: Self.requiresStructuredValidation(request.responseFormat))
        let batchedCompletionStartedAt = Date()
        let batchedCompletion = try await Self.withStructuredStreamingIdleTimeout(
            idleState: batchedIdleState,
            onIdleTimeout: { () throws -> CompletionResult? in
                try Self.synthesizeIdleTimeoutResultOrThrow(
                    accumulator: structuredAccumulator,
                    request: request,
                    modelHash: snapshot.modelHash
                )
            }
        ) { idleCancellation in
            try await self.attachedContinuousBatchStreamingCompletion(
                request: request,
                snapshot: snapshot,
                capability: continuousBatchingCapability,
                completionStartedAt: batchedCompletionStartedAt,
                shouldCancel: shouldCancel,
                drainCancelled: drainCancelled,
                structuredAccumulator: structuredAccumulator,
                idleState: batchedIdleState,
                idleCancellation: idleCancellation,
                onChunk: onChunk
            )
        }
        if let completion = batchedCompletion {
            return completion
        }
        if speculativeCacheWrapValidated,
           let testSpeculativeStream,
           Self.speculativeRoute(
               for: request,
               draftLoaded: snapshot.hasTargetCompatibleDraft,
               numDraftTokens: snapshot.numDraftTokens
           ) == .speculative {
            let completion = try await Self.withDrainCancellation(drainCancelled) {
                try await testSpeculativeStream(snapshot, request)
            }.withModelHashObservedIfMissing(Self.validObservedModelHash(snapshot.modelHash))
            if !completion.content.isEmpty {
                if let error = structuredAccumulator.append(completion.content) {
                settlementRan: true
            )
        case .responseByteCapExceeded:
            return APIError(
                status: 502,
                message: "Tool call arguments exceeded 2097152 bytes",
                type: "upstream_provider_error",
                code: "response_byte_cap_exceeded",
                inferenceRan: true,
                settlementRan: true
            )
        case .malformed, .none:
            return malformedHarmonyResponseError()
        }
    }

    /// SPEC-018 serial tool turn (`parallel_tool_calls` omitted/false) on a
    /// non-Harmony model with tools: generation stops once the first tool
    /// call is complete and valid.
    static func serialToolStopApplies(_ request: ChatCompletionRequest) -> Bool {
        request.stopsAfterFirstCompleteToolCall
            && !HarmonyResponseParser.isHarmonyModelID(request.model)
            && hasEnabledTools(request.promptSource.tools)
    }

    /// One serial-tool-turn stop test over the decode of every token so far.
    /// The serial non-streaming path and the continuous-batching rows
    /// (SPEC-038 AC-6c) share it, so both stop at the same token.
    static func observeSerialToolStop(
        _ observer: inout NativeToolCallStreamEmitter,
        decoded: String,
        stopTokenFilter: StopTokenFilter,
        requestStops: [String]
    ) -> Bool {
        let candidate = streamingSafePrefix(
            decoded,
            stopTokenFilter: stopTokenFilter,
            requestStops: requestStops
        )
        _ = observer.observe(candidate.text)
        return observer.hasCompletedValidToolCall
    }

    private static func parseToolCallsIfRequested(_ text: String, request: ChatCompletionRequest) -> (content: String, toolCalls: [ToolCall]) {
        guard let allowedFunctionNames = toolFunctionNames(from: request.promptSource.tools) else {
            return (text, [])
        }
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: text,
            modelID: request.model,
            allowedFunctionNames: allowedFunctionNames
        )
        guard !parsed.toolCalls.isEmpty else {
            return (text, [])
        }
        if request.stopsAfterFirstCompleteToolCall, parsed.toolCalls.count > 1 {
            return ("", Array(parsed.toolCalls.prefix(1)))
        }
        return ("", parsed.toolCalls)
    }

    static func requiresStructuredValidation(_ responseFormat: ResponseFormat) -> Bool {
        switch responseFormat {
        case .text:
            return false
        case .jsonObject, .jsonSchema:
            return true
        }

exec
/bin/bash -lc 'git diff --no-ext-diff --unified=30 52fcb7e4''^ 52fcb7e4 -- phase3-binary/Sources/macprovider-cli/ModelRuntime.swift | sed -n '"'1,380p'" in /Users/augstar/macprovider-1646-rest
 succeeded in 0ms:
diff --git a/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift b/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift
index d82c7835..04ca2b0f 100644
--- a/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift
+++ b/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift
@@ -3336,73 +3336,85 @@ actor ModelRuntime: ModelRuntimeServing {
     ) async -> [PagedKVSharedForwardBackend.CacheKind]? {
         await container.perform { context in
             return Self.pagedKVCacheKinds(model: context.model)
         }
     }
 
     private func rebuildContinuousBatchScheduler(container: ModelContainer?) async {
         continuousBatchScheduler = await Self.makeContinuousBatchScheduler(
             decision: pagedKVAttachDecision,
             tuple: continuousBatchingRequestedTuple(),
             container: container,
             backendOverride: testContinuousBatchingBackend,
             maxBatch: maxBatch,
             queueLimit: continuousBatchQueueLimit,
             queueWaitTimeoutMS: continuousBatchQueueWaitTimeoutMS,
             maxContextTokens: maxContextTokens,
             modelID: currentModelID,
             modelSHA256: currentModelHash,
             weightsGeneration: currentSpecDecodeGeneration,
             kvBitsOverride: kvBitsOverride,
             prefillStepSize: prefillStepSize,
             replayAuthority: continuousBatchReplayAuthority,
             cachedTurns: continuousBatchingCachedTurns
         )
         continuousBatchingDurableReplayAuthorityAvailable =
             continuousBatchScheduler != nil && continuousBatchReplayAuthority.durableAvailable
     }
 
     /// A request is representable by the batched shared-forward contract only if
     /// its generation is fully described by the scalar sampling parameters the
-    /// contract carries. Structured-output/grammar validation, tool-constrained
-    /// decoding, logit_bias, and logprobs all impose row-local decoder state the
-    /// contract does not model, so such requests must serial-route (canary) / fail
-    /// closed (strict) before admission — a gate that holds for the SPEC-039 bridge
-    /// so a future backend cannot silently drop that state.
+    /// contract carries. logit_bias and logprobs impose row-local decoder state
+    /// the contract does not model, so such requests must serial-route (canary) /
+    /// fail closed (strict) before admission — a gate that holds for the SPEC-039
+    /// bridge so a future backend cannot silently drop that state.
+    ///
+    /// SPEC-038 AC-6c: structured output (`response_format` json_object /
+    /// json_schema) and enabled tools constrain no logit. The serial path
+    /// renders them into the prompt (`userInput(for:)`) and applies them after
+    /// generation (`parseGeneratedOutput`, `validateStructuredCompletion`, the
+    /// SPEC-018 byte caps, the serial tool-turn stop, and the streaming
+    /// `SerialStreamingTextEmitter`); a batched row reuses exactly those, so
+    /// they batch. Kept gated: Harmony (gpt-oss) models with tools or
+    /// structured output. Their serial stream parses Harmony channels as
+    /// tokens arrive and sends only the final channel; the batched stream
+    /// sink streams decoded text and has no Harmony channel parser, and the
+    /// gate cannot tell a streaming request from a non-streaming one.
     static func requestStateRepresentable(_ request: ChatCompletionRequest) -> Bool {
-        // Structured-output / grammar-constrained decoding.
-        if requiresStructuredValidation(request.responseFormat) { return false }
-        // Tool-bearing requests carry tool schemas + tool-call parser state.
         // hasEnabledTools treats an absent, explicit-null, or empty tools array as
         // no-tools, so a bare or explicit-null `tool_choice` does not false-positive
         // here (the meaningful signal is whether tools are actually enabled).
-        if hasEnabledTools(request.promptSource.tools) { return false }
+        if HarmonyResponseParser.isHarmonyModelID(request.model),
+           requiresStructuredValidation(request.responseFormat)
+            || hasEnabledTools(request.promptSource.tools) {
+            return false
+        }
         // logit_bias and logprobs (incl. top_logprobs metadata) have no carrier in
         // the scheduler row contract. top_logprobs only shapes response metadata,
         // not token selection, but is rejected here too so the gate is provably
         // complete and no per-request logprob surface can reach a batch unrepresented.
         if isActiveJSONValue(request.promptSource.logitBias) { return false }
         if isRequestedLogprobs(request.promptSource.logprobs) { return false }
         if isActiveJSONValue(request.promptSource.topLogprobs) { return false }
         // SPEC-038 AC-6b: each batched row samples with the serial path's own
         // sampler for its temperature/top_p and a row-local seed
         // (`ContinuousBatchRowSampler`). The serial path ignores presence and
         // frequency penalties, so they do not change what a row can represent.
         return ContinuousBatchRowSampler.supports(
             temperature: request.temperature,
             topP: request.topP
         )
     }
 
     nonisolated static func requestHasStableRequestID(_ request: ChatCompletionRequest) -> Bool {
         nonEmpty(request.requestID) != nil
     }
 
     /// True when a JSON field is present and not explicit null. `optionalJSONValue`
     /// preserves JSON `null` as `.null`, so a bare `!= nil` check would misclassify
     /// an explicit-null field as active.
     static func isActiveJSONValue(_ value: MacProviderCore.JSONValue?) -> Bool {
         guard let value else { return false }
         if case .null = value { return false }
         return true
     }
 
@@ -3874,102 +3886,346 @@ actor ModelRuntime: ModelRuntimeServing {
     /// state, identical to the serial path's `prefillRecurrentCheckpoints`.
     private nonisolated static func continuousBatchRecurrentCheckpointPositions(
         promptTokens: [Int],
         conversationKey: String?,
         hybrid: Bool,
         context: ModelContext
     ) -> [Int] {
         guard nonEmpty(conversationKey) != nil else { return [] }
         return ConversationCache.recurrentCheckpointPositions(
             promptTokenIds: promptTokens.map(Int32.init),
             imStartTokenID: context.tokenizer.convertTokenToId("<|im_start|>").map(Int32.init),
             hybrid: hybrid,
             decode: { context.tokenizer.decode(tokenIds: $0) })
     }
 
     /// The tokens a batched hybrid entry commits: the canonical list cut to the
     /// length its attention layers cover, so `begin`'s trim lands exactly on a
     /// checkpoint. Nil if the canonical list is shorter (never expected).
     nonisolated static func serialConversationCacheCommitTokens(
         canonicalTokens: [Int32],
         coveredTokenCount: Int
     ) -> [Int32]? {
         guard coveredTokenCount <= canonicalTokens.count else { return nil }
         return Array(canonicalTokens.prefix(coveredTokenCount))
     }
 
     /// Tokenizer decode for CB streaming. Must not take `ModelContainer`:
     /// compiled lockstep already holds that hop, and a per-token `perform`
     /// behind the delivery buffer is what turned longer canary streams into
     /// `internal_error` after the first content chunk.
-    private struct StreamingDetokenizer: @unchecked Sendable {
+    struct StreamingDetokenizer: @unchecked Sendable {
         let decode: ([Int]) -> String
     }
 
-    private final class AttachedPagedKVStreamState: @unchecked Sendable {
+    /// A batched streaming row's buyer-visible state (SPEC-038 AC-6c). Each
+    /// delivered token runs the serial path's `SerialStreamingTextEmitter`
+    /// step over the decode of every token so far, as the serial generate
+    /// callback does. Once the serial path would have stopped generating (a
+    /// serial tool turn's first complete tool call, or a structured-output
+    /// accumulator error) later tokens are ignored and the stop point is kept
+    /// so the finalize truncates the row to it.
+    final class AttachedPagedKVStreamState: @unchecked Sendable {
         private let lock = NSLock()
         private var tokenIDs: [Int] = []
-        private var emittedText = ""
+        private var emitter: SerialStreamingTextEmitter
         private var recordedError: APIError?
-
-        func appendTokens(_ tokens: [Int]) -> [Int] {
+        private var stoppedValue = false
+        private var serialStopTokenCountValue: Int?
+
+        init(request: ChatCompletionRequest) {
+            emitter = SerialStreamingTextEmitter(request: request)
+        }
+
+        /// Returns true the first time the row should stop decoding.
+        func step(
+            eventTokens: [Int],
+            decode: ([Int]) -> String,
+            stopTokenFilter: StopTokenFilter,
+            requestStops: [String],
+            structuredAccumulator: StructuredStreamingContentAccumulator,
+            idleState: StructuredStreamingIdleState,
+            onChunk: (StreamChunk) -> Void
+        ) -> Bool {
             lock.lock()
             defer { lock.unlock() }
-            tokenIDs.append(contentsOf: tokens)
-            return tokenIDs
+            guard !stoppedValue, !eventTokens.isEmpty else { return false }
+            tokenIDs.append(contentsOf: eventTokens)
+            let candidate = ModelRuntime.streamingSafePrefix(
+                decode(tokenIDs),
+                stopTokenFilter: stopTokenFilter,
+                requestStops: requestStops
+            )
+            switch emitter.step(
+                candidate: candidate,
+                structuredAccumulator: structuredAccumulator,
+                idleState: idleState,
+                onChunk: onChunk
+            ) {
+            case .more, .requestStop:
+                // A buyer stop string ends the row through its stop-token
+                // sequences, and the final filter cuts the text at it.
+                return false
+            case .toolCallComplete:
+                stoppedValue = true
+                serialStopTokenCountValue = tokenIDs.count
+                return true
+            case .structuredError:
+                stoppedValue = true
+                if recordedError == nil {
+                    recordedError = structuredAccumulator.error
+                }
+                return true
+            }
         }
 
-        func delta(to candidateText: String) -> String {
+        func finish(
+            finalText: String,
+            parsed: ModelRuntime.ParsedGeneratedOutput,
+            structuredAccumulator: StructuredStreamingContentAccumulator,
+            idleState: StructuredStreamingIdleState,
+            onChunk: (StreamChunk) -> Void
+        ) throws {
             lock.lock()
             defer { lock.unlock() }
-            let delta = ModelRuntime.streamDelta(from: emittedText, to: candidateText)
-            if !delta.isEmpty {
-                emittedText = candidateText
-            }
-            return delta
+            try emitter.finish(
+                finalText: finalText,
+                parsed: parsed,
+                structuredAccumulator: structuredAccumulator,
+                idleState: idleState,
+                onChunk: onChunk
+            )
         }
 
-        func record(_ error: APIError) {
+        /// Token count at which the serial path would have stopped a serial
+        /// tool turn; nil when it would not have stopped early.
+        var serialStopTokenCount: Int? {
             lock.lock()
-            if recordedError == nil {
-                recordedError = error
-            }
-            lock.unlock()
+            defer { lock.unlock() }
+            return serialStopTokenCountValue
         }
 
         func error() -> APIError? {
             lock.lock()
             defer { lock.unlock() }
             return recordedError
         }
     }
 
+    /// A batched non-streaming serial tool turn (SPEC-038 AC-6c): the serial
+    /// non-streaming stop test over each delivered token.
+    final class ContinuousBatchSerialToolStopState: @unchecked Sendable {
+        private let lock = NSLock()
+        private var tokenIDs: [Int] = []
+        private var observer: NativeToolCallStreamEmitter
+        private var stopTokenCountValue: Int?
+
+        init(request: ChatCompletionRequest) {
+            observer = NativeToolCallStreamEmitter(
+                modelID: request.model,
+                allowedFunctionNames: ModelRuntime.toolFunctionNames(from: request.promptSource.tools)
+            )
+        }
+
+        /// Returns true the first time the row should stop decoding.
+        func observe(
+            eventTokens: [Int],
+            decode: ([Int]) -> String,
+            stopTokenFilter: StopTokenFilter,
+            requestStops: [String]
+        ) -> Bool {
+            lock.lock()
+            defer { lock.unlock() }
+            guard stopTokenCountValue == nil, !eventTokens.isEmpty else { return false }
+            tokenIDs.append(contentsOf: eventTokens)
+            guard ModelRuntime.observeSerialToolStop(
+                &observer,
+                decoded: decode(tokenIDs),
+                stopTokenFilter: stopTokenFilter,
+                requestStops: requestStops
+            ) else { return false }
+            stopTokenCountValue = tokenIDs.count
+            return true
+        }
+
+        var stopTokenCount: Int? {
+            lock.lock()
+            defer { lock.unlock() }
+            return stopTokenCountValue
+        }
+    }
+
+    struct ContinuousBatchFinalizedRow: Sendable {
+        /// Not yet structured-validated: the non-streaming caller runs
+        /// `validateStructuredCompletion`, the streaming caller first sends
+        /// the held-back text and then `validateStructuredStreamingCompletion`,
+        /// each exactly as its serial counterpart does.
+        let completion: CompletionResult
+        let filteredText: String
+        let parsed: ParsedGeneratedOutput
+        /// Generated tokens the completion accounts for (model EOS dropped,
+        /// truncated to the serial stop point).
+        let generatedTokens: [Int]
+        /// The row decoded past the serial stop point, so its retained cache
+        /// covers tokens the completion does not and must not be committed.
+        let truncatedAtSerialStop: Bool
+    }
+
+    /// SPEC-038 AC-6c: the one post-generation finalize for a batched row,
+    /// streaming and non-streaming. It applies the serial path's response
+    /// byte cap, output filters, `parseGeneratedOutput` (tool calls,
+    /// SPEC-018 caps, Harmony) and finish-reason rule to the row's text. A
+    /// serial tool turn is first truncated to the token at which the serial
+    /// path stops generating, so the parsed text and billed tokens match.
+    static func finalizeContinuousBatchRow(
+        request: ChatCompletionRequest,
+        result: ContinuousBatchSchedulerResult,
+        modelStopTokenIDs: Set<Int>,
+        serialStopTokenCount: Int?,
+        promptTokenIDs: [Int32],
+        decode: ([Int]) -> String,
+        stopTokenFilter: StopTokenFilter,
+        generationMilliseconds: Int64,
+        modelHash: String?
+    ) throws -> ContinuousBatchFinalizedRow {
+        // The serial path discards the model's end-of-generation token
+        // before counting it; bill and cache the batched row the same way.
+        // Harmony `<|return|>`/`<|call|>` are excluded from this set, as
+        // they are from the serial stop set: the parser reads and counts them.
+        var generatedTokens = droppingTrailingModelStop(
+            result.generatedTokens,
+            terminalStatus: result.terminalStatus,
+            modelStopTokenIDs: modelStopTokenIDs
+        )
+        var completionTokenCount = result.completionTokens
+            - (result.generatedTokens.count - generatedTokens.count)
+        var outputTokens = result.outputTokens
+        var truncated = false
+        if let serialStopTokenCount, serialStopTokenCount < generatedTokens.count {
+            completionTokenCount -= generatedTokens.count - serialStopTokenCount
+            generatedTokens = Array(generatedTokens.prefix(serialStopTokenCount))
+            outputTokens = Array(outputTokens.prefix(serialStopTokenCount))
+            truncated = true
+        }
+        let decoded = decode(outputTokens)
+        guard decoded.utf8.count <= ToolCallParser.SPEC018_ARGUMENTS_PER_RESPONSE_BYTE_CAP else {
+            throw APIError(
+                status: 502,
+                message: "Model response exceeded 2097152 bytes",
+                type: "upstream_provider_error",
+                code: "response_byte_cap_exceeded",
+                inferenceRan: true,
+                settlementRan: true
+            )
+        }
+        let filtered = applyOutputFilters(
+            decoded,
+            stopTokenFilter: stopTokenFilter,
+            requestStops: request.stop
+        )
+        // A truncated row ended where the serial path's early stop does,
+        // which is never a length finish.
+        let lengthTerminal = result.terminalStatus == .length && !truncated
+        let parserFinishReason = lengthTerminal && !filtered.hitStop
+            ? "length"
+            : (filtered.hitStop ? "request_stop" : "stop")
+        let parsed = try parseGeneratedOutput(
+            filteredText: filtered.text,
+            generatedTokenIDs: generatedTokens,
+            decode: decode,
+            request: request,
+            mode: .complete(finishReason: parserFinishReason),
+            defaultCompletionTokens: completionTokenCount,
+            stopTokenFilter: stopTokenFilter,
+            requestStops: request.stop,
+            globalHitStop: filtered.hitStop
+        )
+        let finishReason: String
+        if !parsed.toolCalls.isEmpty {
+            finishReason = "tool_calls"
+        } else if lengthTerminal, !filtered.hitStop, !parsed.hitStop {
+            finishReason = "length"
+        } else {

exec
/bin/bash -lc 'git show 52fcb7e4''^:phase3-binary/Sources/macprovider-cli/ModelRuntime.swift | sed -n '"'3870,4055p;4380,4615p'" in /Users/augstar/macprovider-1646-rest
 succeeded in 0ms:
        let modelHasRecurrentLayers: Bool
    }

    /// Keyed hybrid requests only: where the batched row snapshots recurrent
    /// state, identical to the serial path's `prefillRecurrentCheckpoints`.
    private nonisolated static func continuousBatchRecurrentCheckpointPositions(
        promptTokens: [Int],
        conversationKey: String?,
        hybrid: Bool,
        context: ModelContext
    ) -> [Int] {
        guard nonEmpty(conversationKey) != nil else { return [] }
        return ConversationCache.recurrentCheckpointPositions(
            promptTokenIds: promptTokens.map(Int32.init),
            imStartTokenID: context.tokenizer.convertTokenToId("<|im_start|>").map(Int32.init),
            hybrid: hybrid,
            decode: { context.tokenizer.decode(tokenIds: $0) })
    }

    /// The tokens a batched hybrid entry commits: the canonical list cut to the
    /// length its attention layers cover, so `begin`'s trim lands exactly on a
    /// checkpoint. Nil if the canonical list is shorter (never expected).
    nonisolated static func serialConversationCacheCommitTokens(
        canonicalTokens: [Int32],
        coveredTokenCount: Int
    ) -> [Int32]? {
        guard coveredTokenCount <= canonicalTokens.count else { return nil }
        return Array(canonicalTokens.prefix(coveredTokenCount))
    }

    /// Tokenizer decode for CB streaming. Must not take `ModelContainer`:
    /// compiled lockstep already holds that hop, and a per-token `perform`
    /// behind the delivery buffer is what turned longer canary streams into
    /// `internal_error` after the first content chunk.
    private struct StreamingDetokenizer: @unchecked Sendable {
        let decode: ([Int]) -> String
    }

    private final class AttachedPagedKVStreamState: @unchecked Sendable {
        private let lock = NSLock()
        private var tokenIDs: [Int] = []
        private var emittedText = ""
        private var recordedError: APIError?

        func appendTokens(_ tokens: [Int]) -> [Int] {
            lock.lock()
            defer { lock.unlock() }
            tokenIDs.append(contentsOf: tokens)
            return tokenIDs
        }

        func delta(to candidateText: String) -> String {
            lock.lock()
            defer { lock.unlock() }
            let delta = ModelRuntime.streamDelta(from: emittedText, to: candidateText)
            if !delta.isEmpty {
                emittedText = candidateText
            }
            return delta
        }

        func record(_ error: APIError) {
            lock.lock()
            if recordedError == nil {
                recordedError = error
            }
            lock.unlock()
        }

        func error() -> APIError? {
            lock.lock()
            defer { lock.unlock() }
            return recordedError
        }
    }

    private func serialRouteCanaryCachedHitMissingRetainedHandoff(
        _ lease: ConversationCacheLease?,
        capability: ContinuousBatchingCapability,
        modelHasRecurrentLayers: Bool
    ) async throws -> Bool {
        guard let lease,
              let reason = Self.cachedHitFenceReason(
                  mode: capability.mode,
                  cachedPromptTokens: lease.cachedPromptTokens,
                  hasRetainedPagedKVHandoff: Self.leaseHasUsableRetainedHandoff(
                      lease,
                      modelHasRecurrentLayers: modelHasRecurrentLayers
                  ),
                  cachedTurnsEnabled: continuousBatchingCachedTurns,
                  cachedTurnsAccepted: continuousBatchingCachedTurns
                      && continuousBatchingRequestedTuple().map {
                          continuousBatchingAcceptanceCoverage.coversCachedTurns($0)
                      } == true
              )
        else {
            return false
        }
        // A retained entry (hybrid or not) cannot serve the serial path, so
        // this discards it and the serial request misses; a serial-format entry
        // is put back for the serial path to reuse.
        await conversationCache.abortForSerialFallback(lease)
        let blocked = ContinuousBatchingCapability(
            mode: capability.mode,
            maxActiveRows: capability.maxActiveRows,
            queueLimit: capability.queueLimit,
            descriptor: capability.descriptor,
            unsupportedReason: reason
        )
        // Strict `.on` must fail closed with the named reason (FR-CB8). Canary
        // serial-routes the same AC-26 fence with reason-coded telemetry.
        try ContinuousBatchingPolicy.validateStrictStartup(blocked)
        ContinuousBatchingPolicy.logSerialRouteIfNeeded(blocked)
        return true
    }

    static func canaryShouldSerialRouteCachedHitMissingRetainedHandoff(
        mode: ContinuousBatchingMode,
        cachedPromptTokens: Int,
        hasRetainedPagedKVHandoff: Bool,
        cachedTurnsEnabled: Bool = false,
        cachedTurnsAccepted: Bool = false
    ) -> Bool {
        cachedHitFenceReason(
            mode: mode,
            cachedPromptTokens: cachedPromptTokens,
            hasRetainedPagedKVHandoff: hasRetainedPagedKVHandoff,
            cachedTurnsEnabled: cachedTurnsEnabled,
            cachedTurnsAccepted: cachedTurnsAccepted
        ) != nil
    }

    /// AC-26 fence for a positive cached-token hit. It stays out of the
    /// scheduler unless the operator opted into `continuous_batching_cached_turns`,
    /// the lease carries a usable retained handoff, AND the accepted tuple
    /// covering this runtime records `cached_turns_accepted` (the per-tuple,
    /// revision-bound packaged proof). A retained handoff alone is capability,
    /// not authorization. Nil means the request may enter the scheduler.
    static func cachedHitFenceReason(
        mode: ContinuousBatchingMode,
        cachedPromptTokens: Int,
        hasRetainedPagedKVHandoff: Bool,
        cachedTurnsEnabled: Bool,
        cachedTurnsAccepted: Bool
    ) -> ContinuousBatchingUnsupportedReason? {
        guard mode != .off, cachedPromptTokens > 0 else { return nil }
        guard cachedTurnsEnabled, hasRetainedPagedKVHandoff else { return .stickyCacheHandoffUnavailable }
        return cachedTurnsAccepted ? nil : .cachedTurnsNotAccepted
    }

    /// A hybrid retained delivery is resumable only from a recurrent checkpoint;
    /// one without any is discarded instead of committed as an entry no turn
    /// could resume (SPEC-038 AC-26).
    nonisolated static func retainedCacheIsCommittable(
        _ retainedCache: ContinuousBatchRetainedCache,
        modelHasRecurrentLayers: Bool
    ) -> Bool {
        !modelHasRecurrentLayers || !retainedCache.recurrentCheckpoints.isEmpty
    }

    /// A retained paged-KV sequence, plus on a hybrid model the recurrent
    /// checkpoint at exactly the cached length (SPEC-038 AC-26).
    nonisolated static func leaseHasUsableRetainedHandoff(
        _ lease: ConversationCacheLease,
        modelHasRecurrentLayers: Bool
    ) -> Bool {
        guard lease.reusableCache?.retainedPagedKVSequence != nil else { return false }
        guard modelHasRecurrentLayers else { return true }
        return lease.recurrentCheckpoint?.tokenCount == lease.cachedPromptTokens
    }

    /// The stored checkpoints a hybrid cached turn hands the scheduler: every
    /// one at or below the cached length (they are a prefix of this prompt).
    /// Empty unless the lease resumes a retained hybrid entry.
    nonisolated static func retainedRecurrentCheckpoints(
        for lease: ConversationCacheLease?
    ) -> [RecurrentStateCheckpoint] {
        guard let lease,
              lease.recurrentCheckpoint != nil,
              let reusable = lease.reusableCache,
              reusable.retainedPagedKVSequence != nil
        else { return [] }
        return reusable.recurrentCheckpoints.filter { $0.tokenCount <= lease.cachedPromptTokens }
    }

    private func attachedContinuousBatchCompletion(
        }

        try drainCancelled.check()
        try Task.checkCancellation()
        if shouldCancel() { throw CancellationError() }
        let streamState = AttachedPagedKVStreamState()
        let maxOutputTokens = request.maxTokens ?? max(1, maxContextTokens - prepared.promptTokens.count)
        let preparedPromptTokenIDs = prepared.promptTokens.map(Int32.init)
        let batchKVBits = Self.effectiveKVBits(
            configured: kvBitsOverride,
            conversationKey: request.conversationKey
        )
        let lease = await conversationCache.begin(
            conversationKey: request.conversationKey,
            incomingTokens: preparedPromptTokenIDs,
            modelID: request.model,
            kvBits: batchKVBits,
            allowRetainedPagedKVHandoff: true
        )
        if try await serialRouteCanaryCachedHitMissingRetainedHandoff(
            lease,
            capability: capability,
            modelHasRecurrentLayers: prepared.modelHasRecurrentLayers
        ) {
            return nil
        }
        let result: ContinuousBatchSchedulerResult
        do {
            result = try await Self.withDrainAndClientCancellation(drainCancelled, shouldCancel: shouldCancel) {
                try await scheduler.submit(ContinuousBatchSchedulerRequest(
                    id: schedulerRequestID,
                    conversationKey: request.conversationKey ?? "",
                    promptTokens: prepared.promptTokens,
                    maxOutputTokens: maxOutputTokens,
                    stopTokenSequences: prepared.stopTokenSequences,
                    samplerSeed: ContinuousBatchRowSampler.requestSeed(requestID: schedulerRequestID),
                    temperature: request.temperature,
                    topP: request.topP,
                    presencePenalty: request.presencePenalty,
                    frequencyPenalty: request.frequencyPenalty,
                    cachedPromptTokens: lease?.cachedPromptTokens ?? 0,
                    retainedPagedKVSequence: lease?.reusableCache?.retainedPagedKVSequence,
                    recurrentCheckpointPositions: prepared.recurrentCheckpointPositions,
                    retainedRecurrentCheckpoints: Self.retainedRecurrentCheckpoints(for: lease)
                ), tokenSink: { event in
                    let eventTokens = event.replayTokens ?? [event.token]
                    guard !eventTokens.isEmpty else { return }
                    let allTokens = streamState.appendTokens(eventTokens)
                    let candidate = Self.streamingSafePrefix(
                        detokenizer.decode(allTokens),
                        stopTokenFilter: stopTokenFilter,
                        requestStops: requestStops
                    )
                    let delta = streamState.delta(to: candidate.text)
                    guard !delta.isEmpty else { return }
                    if let error = structuredAccumulator.append(delta) {
                        streamState.record(error)
                        return
                    }
                    idleState.noteContent()
                    onChunk(.content(delta))
                })
            }
        } catch {
            if let lease {
                await conversationCache.abort(lease)
            }
            // SPEC-038 AC-25: one shared scheduler-error map, so the
            // streaming and non-streaming paths cannot drift.
            throw (error as? ContinuousBatchSchedulerError)?.asAPIError() ?? error
        }
        do {
            if let error = streamState.error() {
                throw error
            }
            try drainCancelled.check()
            try Task.checkCancellation()
            if shouldCancel() { throw CancellationError() }
            guard result.terminalStatus == .stop || result.terminalStatus == .length else {
                throw Self.terminalFailureError(code: result.errorCode ?? "continuous_batching_request_failed")
            }
            let completionEndedAt = Date()
            // The serial path discards the model's end-of-generation token
            // before counting it; bill and cache the batched row the same way.
            // Harmony `<|return|>`/`<|call|>` are excluded from this set, as
            // they are from the serial stop set: the parser reads and counts them.
            let generatedTokens = Self.droppingTrailingModelStop(
                result.generatedTokens,
                terminalStatus: result.terminalStatus,
                modelStopTokenIDs: prepared.modelStopTokenIDs
            )
            let completionTokenCount = result.completionTokens
                - (result.generatedTokens.count - generatedTokens.count)
            let completion = try await container.perform { context in
                let decoded = context.tokenizer.decode(tokenIds: result.outputTokens)
                guard decoded.utf8.count <= ToolCallParser.SPEC018_ARGUMENTS_PER_RESPONSE_BYTE_CAP else {
                    throw APIError(
                        status: 502,
                        message: "Model response exceeded 2097152 bytes",
                        type: "upstream_provider_error",
                        code: "response_byte_cap_exceeded",
                        inferenceRan: true,
                        settlementRan: true
                    )
                }
                let filtered = Self.applyOutputFilters(
                    decoded,
                    stopTokenFilter: stopTokenFilter,
                    requestStops: requestStops
                )
                let parserFinishReason = result.terminalStatus == .length && !filtered.hitStop
                    ? "length"
                    : (filtered.hitStop ? "request_stop" : "stop")
                let parsed = try Self.parseGeneratedOutput(
                    filteredText: filtered.text,
                    generatedTokenIDs: generatedTokens,
                    decode: { context.tokenizer.decode(tokenIds: $0) },
                    request: request,
                    mode: .complete(finishReason: parserFinishReason),
                    defaultCompletionTokens: completionTokenCount,
                    stopTokenFilter: stopTokenFilter,
                    requestStops: requestStops,
                    globalHitStop: filtered.hitStop
                )
                let finishReason: String
                if !parsed.toolCalls.isEmpty {
                    finishReason = "tool_calls"
                } else if result.terminalStatus == .length, !filtered.hitStop, !parsed.hitStop {
                    finishReason = "length"
                } else {
                    finishReason = "stop"
                }
                let kvCacheBytesReused = Self.cachedPromptUTF8Bytes(
                    promptTokenIds: preparedPromptTokenIDs,
                    cachedPromptTokens: result.cachedPromptTokens,
                    decode: { context.tokenizer.decode(tokenIds: $0) }
                )
                return try Self.validateStructuredCompletion(CompletionResult(
                    content: parsed.content,
                    finishReason: finishReason,
                    promptTokens: prepared.promptTokens.count,
                    cachedPromptTokens: result.cachedPromptTokens,
                    kvCacheBytesReused: kvCacheBytesReused,
                    completionTokens: parsed.completionTokens,
                    generatedCompletionTokens: parsed.generatedCompletionTokens,
                    ttftMilliseconds: nil,
                    generationMilliseconds: Int64(completionEndedAt.timeIntervalSince(completionStartedAt) * 1000),
                    toolCalls: parsed.toolCalls.isEmpty ? nil : parsed.toolCalls,
                    modelHashObserved: Self.validObservedModelHash(snapshot.modelHash),
                    settlementDisposition: result.settlementDisposition
                ), request: request)
            }
            // #1690 E2E-F13: the stream held back an incomplete UTF-8 tail
            // and any stop-string prefix; send the remainder as the final
            // text renders it, so the buyer's bytes equal the receipt's.
            if completion.toolCalls?.isEmpty != false {
                let remainder = streamState.delta(to: completion.content)
                if !remainder.isEmpty {
                    if let error = structuredAccumulator.append(remainder) {
                        throw error
                    }
                    idleState.noteContent()
                    onChunk(.content(remainder))
                }
            }
            let validated = try Self.validateStructuredStreamingCompletion(
                completion,
                request: request,
                buyerVisibleContent: structuredAccumulator.content
            )
            if let lease, let retainedCache = result.retainedCache,
               Self.retainedCacheIsCommittable(
                   retainedCache,
                   modelHasRecurrentLayers: prepared.modelHasRecurrentLayers
               ) {
                await conversationCache.commit(
                    lease,
                    cache: ConversationCacheLayers(
                        retainedCache.layers,
                        retainedPagedKVSequence: retainedCache.retainedSequence,
                        discardRetainedPagedKVSequence: { retained, key in
                            await scheduler.discardRetainedCache(retained, conversationKey: key)
                        },
                        recurrentCheckpoints: retainedCache.recurrentCheckpoints
                    ),
                    fullTokens: preparedPromptTokenIDs + generatedTokens.map(Int32.init)
                )
                await scheduler.acknowledgeRetainedCacheDelivery(retainedCache)
            } else if let lease, let serialCache = result.serialConversationCache,
                      let fullTokens = Self.serialConversationCacheCommitTokens(
                          canonicalTokens: preparedPromptTokenIDs + generatedTokens.map(Int32.init),
                          coveredTokenCount: serialCache.tokenCount
                      ) {
                // SPEC-038 FR-CB4 hybrid first turn: the next keyed turn serial-
                // routes (AC-26) and reuses this entry from its checkpoints.
                await conversationCache.commit(
                    lease,
                    cache: ConversationCacheLayers(
                        serialCache.layers,
                        recurrentCheckpoints: serialCache.recurrentCheckpoints
                    ),
                    fullTokens: fullTokens
                )
            } else if let retainedCache = result.retainedCache {
                await scheduler.cancelRetainedCacheDelivery(
                    retainedCache,
                    conversationKey: result.conversationKey
                )
                if let lease {
                    await conversationCache.abort(lease)
                }
            } else if let lease {
                await conversationCache.abort(lease)
            }
            return validated
        } catch {
            if let retainedCache = result.retainedCache {
                await scheduler.cancelRetainedCacheDelivery(
                    retainedCache,
                    conversationKey: result.conversationKey
                )
            }
            if let lease {
                await conversationCache.abort(lease)
            }
            throw error
        }
    }

    /// SPEC-038 AC-25: a non-terminal scheduler *result*, as distinct from a
    /// thrown scheduler error. Most carried codes are pre-inference, so they
    /// take the `inferenceRan: false` shape. The one that is not is
    /// post-token delivery backpressure — the row was decoding and the buyer
    /// may already hold partial output — so it reuses the single
    /// `.deliveryBackpressure` mapping rather than a second, divergent copy.
    private nonisolated static func terminalFailureError(code: String) -> APIError {

codex
The main risk surface is now narrowed to the new row-stop/finalize boundary: whether asynchronous early-stop races are later truncated before usage/cache settlement, and whether parser/accumulator state is truly per request. I’m checking those paths against the serial implementation and will validate with the committed test cases.
exec
/bin/bash -lc 'swift test --filter ContinuousBatchToolStructuredRowTests' in /Users/augstar/macprovider-1646-rest/phase3-binary
 succeeded in 39060ms:
[0/1] Planning build
[1/1] Compiling plugin GenerateManual
[2/2] Compiling plugin GenerateDoccReference
Building for debugging...
[2/6] Write swift-version--58304C5D6DBC2206.txt
Build complete! (24.75s)
Test Suite 'Selected tests' started at 2026-09-25 19:16:03.030.
Test Suite 'phase3-binaryPackageTests.xctest' started at 2026-09-25 19:16:03.033.
Test Suite 'ContinuousBatchToolStructuredRowTests' started at 2026-09-25 19:16:03.033.
Test Case '-[macprovider_cliTests.ContinuousBatchToolStructuredRowTests testParallelToolTurnKeepsEveryCallLikeSerial]' started.
Test Case '-[macprovider_cliTests.ContinuousBatchToolStructuredRowTests testParallelToolTurnKeepsEveryCallLikeSerial]' passed (0.015 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchToolStructuredRowTests testResponseByteCapMatchesSerialNonStreamingGuard]' started.
Test Case '-[macprovider_cliTests.ContinuousBatchToolStructuredRowTests testResponseByteCapMatchesSerialNonStreamingGuard]' passed (1.019 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchToolStructuredRowTests testSerialToolTurnTruncatesToSerialStopAndMatchesSerialToolCalls]' started.
warning: malformed tool-call output for mlx-community/Qwen3-8B-4bit: missingEndDelimiter
warning: malformed tool-call output for mlx-community/Qwen3-8B-4bit: missingEndDelimiter
Test Case '-[macprovider_cliTests.ContinuousBatchToolStructuredRowTests testSerialToolTurnTruncatesToSerialStopAndMatchesSerialToolCalls]' passed (0.006 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchToolStructuredRowTests testStreamingInvalidJSONUnderJSONSchemaMatchesSerialChunksAndError]' started.
Test Case '-[macprovider_cliTests.ContinuousBatchToolStructuredRowTests testStreamingInvalidJSONUnderJSONSchemaMatchesSerialChunksAndError]' passed (0.003 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchToolStructuredRowTests testStreamingOversizedToolArgumentsStreamNothingLikeSerial]' started.
warning: malformed tool-call output for mlx-community/Qwen3-8B-4bit: byteCapExceeded
warning: malformed tool-call output for mlx-community/Qwen3-8B-4bit: byteCapExceeded
Test Case '-[macprovider_cliTests.ContinuousBatchToolStructuredRowTests testStreamingOversizedToolArgumentsStreamNothingLikeSerial]' passed (5.853 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchToolStructuredRowTests testStreamingSchemaMismatchAndValidJSONMatchSerial]' started.
Test Case '-[macprovider_cliTests.ContinuousBatchToolStructuredRowTests testStreamingSchemaMismatchAndValidJSONMatchSerial]' passed (0.002 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchToolStructuredRowTests testStreamingStructuredByteCapStopsRowWithSerialError]' started.
Test Case '-[macprovider_cliTests.ContinuousBatchToolStructuredRowTests testStreamingStructuredByteCapStopsRowWithSerialError]' passed (1.316 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchToolStructuredRowTests testStreamingToolTurnEmitsSerialToolDeltasAndStopsAtSerialToken]' started.
warning: malformed tool-call output for mlx-community/Qwen3-8B-4bit: missingEndDelimiter
warning: malformed tool-call output for mlx-community/Qwen3-8B-4bit: missingEndDelimiter
Test Case '-[macprovider_cliTests.ContinuousBatchToolStructuredRowTests testStreamingToolTurnEmitsSerialToolDeltasAndStopsAtSerialToken]' passed (0.003 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchToolStructuredRowTests testStructuredVerdictsMatchSerialNonStreaming]' started.
Test Case '-[macprovider_cliTests.ContinuousBatchToolStructuredRowTests testStructuredVerdictsMatchSerialNonStreaming]' passed (0.001 seconds).
Test Suite 'ContinuousBatchToolStructuredRowTests' passed at 2026-09-25 19:16:11.254.
	 Executed 9 tests, with 0 failures (0 unexpected) in 8.219 (8.221) seconds
Test Suite 'phase3-binaryPackageTests.xctest' passed at 2026-09-25 19:16:11.254.
	 Executed 9 tests, with 0 failures (0 unexpected) in 8.219 (8.221) seconds
Test Suite 'Selected tests' passed at 2026-09-25 19:16:11.254.
	 Executed 9 tests, with 0 failures (0 unexpected) in 8.219 (8.224) seconds
◇ Test run started.
↳ Testing Library Version: 1902
↳ Target Platform: arm64e-apple-macos14.0
✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.

exec
/bin/bash -lc "rg -n '"'^    func test'"' phase3-binary/Tests/macprovider-cliTests/ContinuousBatchToolStructuredRowTests.swift && swift test --filter 'ServingKnobsConfigTests.testRequestStateRepresentableGateOnParsedRequests|ContinuousBatchSchedulerTests'" in /Users/augstar/macprovider-1646-rest/phase3-binary
 exited 2 in 39ms:
rg: phase3-binary/Tests/macprovider-cliTests/ContinuousBatchToolStructuredRowTests.swift: IO error for operation on phase3-binary/Tests/macprovider-cliTests/ContinuousBatchToolStructuredRowTests.swift: No such file or directory (os error 2)

exec
/bin/bash -lc "rg -n '"'^    func test'"' Tests/macprovider-cliTests/ContinuousBatchToolStructuredRowTests.swift && swift test --filter 'ServingKnobsConfigTests.testRequestStateRepresentableGateOnParsedRequests|ContinuousBatchSchedulerTests'" in /Users/augstar/macprovider-1646-rest/phase3-binary
exec
/bin/bash -lc "ps -Ao pid,etime,command | rg 'swift|xctest|5365' | head -30" in /Users/augstar/macprovider-1646-rest
 succeeded in 45ms:
 3650       01:20 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-driver --driver-mode=swiftc -Xfrontend -new-driver-path -Xfrontend /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-driver -module-name macprovider_cli -emit-dependencies -emit-module -emit-module-path /Users/augstar/macprovider-1745-air/phase3-binary/.build/arm64-apple-macosx/release/Modules/macprovider_cli.swiftmodule -output-file-map /Users/augstar/macprovider-1745-air/phase3-binary/.build/arm64-apple-macosx/release/macprovider_cli.build/output-file-map.json -whole-module-optimization -num-threads 10 -c @/Users/augstar/macprovider-1745-air/phase3-binary/.build/arm64-apple-macosx/release/macprovider_cli.build/sources -I /Users/augstar/macprovider-1745-air/phase3-binary/.build/arm64-apple-macosx/release/Modules -target arm64-apple-macosx14.0 -whole-module-optimization -num-threads 10 -serialize-diagnostics -O -j10 -DSWIFT_PACKAGE -DSWIFT_MODULE_RESOURCE_BUNDLE_AVAILABLE -Xcc -fmodule-map-file=/Users/augstar/macprovider-1745-air/phase3-binary/.build/checkouts/swift-numerics/Sources/_NumericsShims/include/module.modulemap -Xcc -I -Xcc /Users/augstar/macprovider-1745-air/phase3-binary/.build/checkouts/swift-numerics/Sources/_NumericsShims/include -Xcc -fmodule-map-file=/Users/augstar/macprovider-1745-air/phase3-binary/.build/checkouts/mlx-swift/Source/Cmlx/include/module.modulemap -Xcc -I -Xcc /Users/augstar/macprovider-1745-air/phase3-binary/.build/checkouts/mlx-swift/Source/Cmlx/include -Xcc -fmodule-map-file=/Users/augstar/macprovider-1745-air/phase3-binary/.build/arm64-apple-macosx/release/yyjson.build/module.modulemap -Xcc -I -Xcc /Users/augstar/macprovider-1745-air/phase3-binary/.build/checkouts/yyjson/src -Xcc -fmodule-map-file=/Users/augstar/macprovider-1745-air/phase3-binary/.build/checkouts/swift-atomics/Sources/_AtomicsShims/include/module.modulemap -Xcc -I -Xcc /Users/augstar/macprovider-1745-air/phase3-binary/.build/checkouts/swift-atomics/Sources/_AtomicsShims/include -Xcc -fmodule-map-file=/Users/augstar/macprovider-1745-air/phase3-binary/.build/arm64-apple-macosx/release/CNIOPosix.build/module.modulemap -Xcc -I -Xcc /Users/augstar/macprovider-1745-air/phase3-binary/.build/checkouts/swift-nio/Sources/CNIOPosix/include -Xcc -fmodule-map-file=/Users/augstar/macprovider-1745-air/phase3-binary/.build/arm64-apple-macosx/release/CNIOAtomics.build/module.modulemap -Xcc -I -Xcc /Users/augstar/macprovider-1745-air/phase3-binary/.build/checkouts/swift-nio/Sources/CNIOAtomics/include -Xcc -fmodule-map-file=/Users/augstar/macprovider-1745-air/phase3-binary/.build/checkouts/swift-nio/Sources/CNIOWindows/include/module.modulemap -Xcc -I -Xcc /Users/augstar/macprovider-1745-air/phase3-binary/.build/checkouts/swift-nio/Sources/CNIOWindows/include -Xcc -fmodule-map-file=/Users/augstar/macprovider-1745-air/phase3-binary/.build/arm64-apple-macosx/release/CNIODarwin.build/module.modulemap -Xcc -I -Xcc /Users/augstar/macprovider-1745-air/phase3-binary/.build/checkouts/swift-nio/Sources/CNIODarwin/include -Xcc -fmodule-map-file=/Users/augstar/macprovider-1745-air/phase3-binary/.build/arm64-apple-macosx/release/CNIOLinux.build/module.modulemap -Xcc -I -Xcc /Users/augstar/macprovider-1745-air/phase3-binary/.build/checkouts/swift-nio/Sources/CNIOLinux/include -Xcc -fmodule-map-file=/Users/augstar/macprovider-1745-air/phase3-binary/.build/arm64-apple-macosx/release/CNIOOpenBSD.build/module.modulemap -Xcc -I -Xcc /Users/augstar/macprovider-1745-air/phase3-binary/.build/checkouts/swift-nio/Sources/CNIOOpenBSD/include -Xcc -fmodule-map-file=/Users/augstar/macprovider-1745-air/phase3-binary/.build/arm64-apple-macosx/release/CNIOWASI.build/module.modulemap -Xcc -I -Xcc /Users/augstar/macprovider-1745-air/phase3-binary/.build/checkouts/swift-nio/Sources/CNIOWASI/include -Xcc -fmodule-map-file=/Users/augstar/macprovider-1745-air/phase3-binary/.build/arm64-apple-macosx/release/CNIOFreeBSD.build/module.modulemap -Xcc -I -Xcc /Users/augstar/macprovider-1745-air/phase3-binary/.build/checkouts/swift-nio/Sources/CNIOFreeBSD/include -Xcc -fmodule-map-file=/Users/augstar/macprovider-1745-air/phase3-binary/.build/arm64-apple-macosx/release/CNIOLLHTTP.build/module.modulemap -Xcc -I -Xcc /Users/augstar/macprovider-1745-air/phase3-binary/.build/checkouts/swift-nio/Sources/CNIOLLHTTP/include -Xcc -fmodule-map-file=/Users/augstar/macprovider-1745-air/phase3-binary/.build/checkouts/Yams/Sources/CYaml/include/module.modulemap -Xcc -I -Xcc /Users/augstar/macprovider-1745-air/phase3-binary/.build/checkouts/Yams/Sources/CYaml/include -module-cache-path /Users/augstar/macprovider-1745-air/phase3-binary/.build/arm64-apple-macosx/release/ModuleCache -parseable-output -Xfrontend -entry-point-function-name -Xfrontend macprovider_cli_main -swift-version 5 -enable-experimental-feature StrictConcurrency -plugin-path /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing -sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk -F /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks -I /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib -L /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib -g -Xcc -isysroot -Xcc /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk -Xcc -F -Xcc /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks -Xcc -fPIC -Xcc -g -package-name phase3_binary -Xfrontend -load-plugin-executable -Xfrontend /Users/augstar/macprovider-1745-air/phase3-binary/.build/arm64-apple-macosx/release/MLXHuggingFaceMacros-tool#MLXHuggingFaceMacros
 3658       01:20 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend -frontend -c -filelist /var/folders/dr/s790cqgx6dx_55127wsgnkw00000gn/T/TemporaryDirectory.QA8Wcv/sources-1 -supplementary-output-file-map /var/folders/dr/s790cqgx6dx_55127wsgnkw00000gn/T/TemporaryDirectory.QA8Wcv/supplementaryOutputs-1 -target arm64-apple-macosx14.0 -Xllvm -aarch64-use-tbi -enable-objc-interop -stack-check -sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk -I /Users/augstar/macprovider-1745-air/phase3-binary/.build/arm64-apple-macosx/release/Modules -I /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib -F /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks -no-color-diagnostics -Xcc -fno-color-diagnostics -g -debug-info-format=dwarf -dwarf-version=4 -module-cache-path /Users/augstar/macprovider-1745-air/phase3-binary/.build/arm64-apple-macosx/release/ModuleCache -swift-version 5 -O -D SWIFT_PACKAGE -D SWIFT_MODULE_RESOURCE_BUNDLE_AVAILABLE -new-driver-path /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-driver -entry-point-function-name macprovider_cli_main -load-plugin-executable /Users/augstar/macprovider-1745-air/phase3-binary/.build/arm64-apple-macosx/release/MLXHuggingFaceMacros-tool#MLXHuggingFaceMacros -enable-experimental-feature StrictConcurrency -empty-abi-descriptor -plugin-path /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing -file-compilation-dir /Users/augstar/macprovider-1745-air/phase3-binary -Xcc -fmodule-map-file=/Users/augstar/macprovider-1745-air/phase3-binary/.build/checkouts/swift-numerics/Sources/_NumericsShims/include/module.modulemap -Xcc -I -Xcc /Users/augstar/macprovider-1745-air/phase3-binary/.build/checkouts/swift-numerics/Sources/_NumericsShims/include -Xcc -fmodule-map-file=/Users/augstar/macprovider-1745-air/phase3-binary/.build/checkouts/mlx-swift/Source/Cmlx/include/module.modulemap -Xcc -I -Xcc /Users/augstar/macprovider-1745-air/phase3-binary/.build/checkouts/mlx-swift/Source/Cmlx/include -Xcc -fmodule-map-file=/Users/augstar/macprovider-1745-air/phase3-binary/.build/arm64-apple-macosx/release/yyjson.build/module.modulemap -Xcc -I -Xcc /Users/augstar/macprovider-1745-air/phase3-binary/.build/checkouts/yyjson/src -Xcc -fmodule-map-file=/Users/augstar/macprovider-1745-air/phase3-binary/.build/checkouts/swift-atomics/Sources/_AtomicsShims/include/module.modulemap -Xcc -I -Xcc /Users/augstar/macprovider-1745-air/phase3-binary/.build/checkouts/swift-atomics/Sources/_AtomicsShims/include -Xcc -fmodule-map-file=/Users/augstar/macprovider-1745-air/phase3-binary/.build/arm64-apple-macosx/release/CNIOPosix.build/module.modulemap -Xcc -I -Xcc /Users/augstar/macprovider-1745-air/phase3-binary/.build/checkouts/swift-nio/Sources/CNIOPosix/include -Xcc -fmodule-map-file=/Users/augstar/macprovider-1745-air/phase3-binary/.build/arm64-apple-macosx/release/CNIOAtomics.build/module.modulemap -Xcc -I -Xcc /Users/augstar/macprovider-1745-air/phase3-binary/.build/checkouts/swift-nio/Sources/CNIOAtomics/include -Xcc -fmodule-map-file=/Users/augstar/macprovider-1745-air/phase3-binary/.build/checkouts/swift-nio/Sources/CNIOWindows/include/module.modulemap -Xcc -I -Xcc /Users/augstar/macprovider-1745-air/phase3-binary/.build/checkouts/swift-nio/Sources/CNIOWindows/include -Xcc -fmodule-map-file=/Users/augstar/macprovider-1745-air/phase3-binary/.build/arm64-apple-macosx/release/CNIODarwin.build/module.modulemap -Xcc -I -Xcc /Users/augstar/macprovider-1745-air/phase3-binary/.build/checkouts/swift-nio/Sources/CNIODarwin/include -Xcc -fmodule-map-file=/Users/augstar/macprovider-1745-air/phase3-binary/.build/arm64-apple-macosx/release/CNIOLinux.build/module.modulemap -Xcc -I -Xcc /Users/augstar/macprovider-1745-air/phase3-binary/.build/checkouts/swift-nio/Sources/CNIOLinux/include -Xcc -fmodule-map-file=/Users/augstar/macprovider-1745-air/phase3-binary/.build/arm64-apple-macosx/release/CNIOOpenBSD.build/module.modulemap -Xcc -I -Xcc /Users/augstar/macprovider-1745-air/phase3-binary/.build/checkouts/swift-nio/Sources/CNIOOpenBSD/include -Xcc -fmodule-map-file=/Users/augstar/macprovider-1745-air/phase3-binary/.build/arm64-apple-macosx/release/CNIOWASI.build/module.modulemap -Xcc -I -Xcc /Users/augstar/macprovider-1745-air/phase3-binary/.build/checkouts/swift-nio/Sources/CNIOWASI/include -Xcc -fmodule-map-file=/Users/augstar/macprovider-1745-air/phase3-binary/.build/arm64-apple-macosx/release/CNIOFreeBSD.build/module.modulemap -Xcc -I -Xcc /Users/augstar/macprovider-1745-air/phase3-binary/.build/checkouts/swift-nio/Sources/CNIOFreeBSD/include -Xcc -fmodule-map-file=/Users/augstar/macprovider-1745-air/phase3-binary/.build/arm64-apple-macosx/release/CNIOLLHTTP.build/module.modulemap -Xcc -I -Xcc /Users/augstar/macprovider-1745-air/phase3-binary/.build/checkouts/swift-nio/Sources/CNIOLLHTTP/include -Xcc -fmodule-map-file=/Users/augstar/macprovider-1745-air/phase3-binary/.build/checkouts/Yams/Sources/CYaml/include/module.modulemap -Xcc -I -Xcc /Users/augstar/macprovider-1745-air/phase3-binary/.build/checkouts/Yams/Sources/CYaml/include -Xcc -isysroot -Xcc /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk -Xcc -F -Xcc /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks -Xcc -fPIC -Xcc -g -no-auto-bridging-header-chaining -module-name macprovider_cli -package-name phase3_binary -disable-clang-spi -target-sdk-version 26.5 -target-sdk-name macosx26.5 -external-plugin-path /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins#/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/bin/swift-plugin-server -external-plugin-path /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/local/lib/swift/host/plugins#/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/bin/swift-plugin-server -in-process-plugin-server-path /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/libSwiftInProcPluginServer.dylib -plugin-path /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins -plugin-path /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/local/lib/swift/host/plugins -enable-default-cmo -num-threads 10 -output-filelist /var/folders/dr/s790cqgx6dx_55127wsgnkw00000gn/T/TemporaryDirectory.QA8Wcv/outputs-1
 5159       01:01 /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/bin/swift-plugin-server
 5338       00:50 /bin/bash -lc swift test --filter ContinuousBatchToolStructuredRowTests && swift test --filter 'ContinuousBatchSchedulerTests|ContinuousBatchStopTokenTests|ServingKnobsConfigTests'
 5368       00:50 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-test --filter ContinuousBatchToolStructuredRowTests
 5370       00:50 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-test --filter ServingKnobsConfigTests/testRequestStateRepresentableGateOnParsedRequests
 5374       00:50 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-test --filter ContinuousBatchSchedulerTests/testStopEarlyEndsDecodingRowAsStopAtNextToken
 7115       00:27 /bin/bash -lc rg -n '^    func test' Tests/macprovider-cliTests/ContinuousBatchToolStructuredRowTests.swift && swift test --filter 'ServingKnobsConfigTests.testRequestStateRepresentableGateOnParsedRequests|ContinuousBatchSchedulerTests'
 7143       00:27 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-test --filter ServingKnobsConfigTests.testRequestStateRepresentableGateOnParsedRequests|ContinuousBatchSchedulerTests
 7967       00:04 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-test --filter ContinuousBatchSchedulerTests|ContinuousBatchStopTokenTests|ServingKnobsConfigTests
 8483       00:00 /bin/bash -c ps -Ao pid,etime,command | rg 'swift|xctest|5365' | head -30
 8485       00:00 rg swift|xctest|5365
44853 01-02:35:34 /Applications/Cursor.app/Contents/Resources/app/resources/helpers/cursorsandbox --run-proxy --policy-json {"allow":["public.ecr.aws","awscli.amazonaws.com","anaconda.com","azure.com","cloudflarestorage.com","*.cloudflarestorage.com","docker.com","*.docker.com","github.com","codeload.github.com","githubusercontent.com","*.githubusercontent.com","gitlab.com","google.com","dl.google.com","*.googleapis.com","*.gvt1.com","hashicorp.com","java.com","microsoft.com","dotnet.microsoft.com","mcr.microsoft.com","packages.microsoft.com","npmjs.com","oracle.com","ubuntu.com","archive.ubuntu.com","security.ubuntu.com","public.blob.vercel-storage.com","*.public.blob.vercel-storage.com","visualstudio.com","yarnpkg.com","*.yarnpkg.com","pkg.go.dev","*.anysphere.workers.dev","*.jdx.dev","pub.dev","crates.io","index.crates.io","static.crates.io","docker.io","*.docker.io","gcr.io","ghcr.io","goproxy.io","k8s.io","packagecloud.io","pypa.io","quay.io","rvm.io","spring.io","playwright.azureedge.net","dot.net","java.net","launchpad.net","ppa.launchpad.net","sourceforge.net","alpinelinux.org","apache.org","archlinux.org","bitbucket.org","centos.org","cocoapods.org","cpan.org","debian.org","npm.duckdb.org","eclipse.org","fedoraproject.org","golang.org","proxy.golang.org","sum.golang.org","gradle.org","haskell.org","json-schema.org","apt.llvm.org","maven.org","metacpan.org","nodejs.org","npmjs.org","registry.npmjs.org","nuget.org","packagist.org","pypi.org","pypi.python.org","pythonhosted.org","files.pythonhosted.org","ruby-lang.org","rubygems.org","rubyonrails.org","static.rust-lang.org","json.schemastore.org","swift.org","ziglang.org","hex.pm","rustup.rs","sh.rustup.rs","mise.run","binaries.prisma.sh","fonts.gstatic.com","repo.maven.apache.org","registry.yarnpkg.com"],"default":"deny","version":1}
65204 07-01:39:05 /Applications/Cursor.app/Contents/Resources/app/resources/helpers/cursorsandbox --run-proxy --policy-json {"allow":["public.ecr.aws","awscli.amazonaws.com","anaconda.com","azure.com","cloudflarestorage.com","*.cloudflarestorage.com","docker.com","*.docker.com","github.com","codeload.github.com","githubusercontent.com","*.githubusercontent.com","gitlab.com","google.com","dl.google.com","*.googleapis.com","*.gvt1.com","hashicorp.com","java.com","microsoft.com","dotnet.microsoft.com","mcr.microsoft.com","packages.microsoft.com","npmjs.com","oracle.com","ubuntu.com","archive.ubuntu.com","security.ubuntu.com","public.blob.vercel-storage.com","*.public.blob.vercel-storage.com","visualstudio.com","yarnpkg.com","*.yarnpkg.com","pkg.go.dev","*.anysphere.workers.dev","*.jdx.dev","pub.dev","crates.io","index.crates.io","static.crates.io","docker.io","*.docker.io","gcr.io","ghcr.io","goproxy.io","k8s.io","packagecloud.io","pypa.io","quay.io","rvm.io","spring.io","playwright.azureedge.net","dot.net","java.net","launchpad.net","ppa.launchpad.net","sourceforge.net","alpinelinux.org","apache.org","archlinux.org","bitbucket.org","centos.org","cocoapods.org","cpan.org","debian.org","npm.duckdb.org","eclipse.org","fedoraproject.org","golang.org","proxy.golang.org","sum.golang.org","gradle.org","haskell.org","json-schema.org","apt.llvm.org","maven.org","metacpan.org","nodejs.org","npmjs.org","registry.npmjs.org","nuget.org","packagist.org","pypi.org","pypi.python.org","pythonhosted.org","files.pythonhosted.org","ruby-lang.org","rubygems.org","rubyonrails.org","static.rust-lang.org","json.schemastore.org","swift.org","ziglang.org","hex.pm","rustup.rs","sh.rustup.rs","mise.run","binaries.prisma.sh","fonts.gstatic.com","repo.maven.apache.org","registry.yarnpkg.com"],"default":"deny","version":1}
76594    01:11:57 /Applications/Cursor.app/Contents/Resources/app/resources/helpers/cursorsandbox --run-proxy --policy-json {"allow":["public.ecr.aws","awscli.amazonaws.com","anaconda.com","azure.com","cloudflarestorage.com","*.cloudflarestorage.com","docker.com","*.docker.com","github.com","codeload.github.com","githubusercontent.com","*.githubusercontent.com","gitlab.com","google.com","dl.google.com","*.googleapis.com","*.gvt1.com","hashicorp.com","java.com","microsoft.com","dotnet.microsoft.com","mcr.microsoft.com","packages.microsoft.com","npmjs.com","oracle.com","ubuntu.com","archive.ubuntu.com","security.ubuntu.com","public.blob.vercel-storage.com","*.public.blob.vercel-storage.com","visualstudio.com","yarnpkg.com","*.yarnpkg.com","pkg.go.dev","*.anysphere.workers.dev","*.jdx.dev","pub.dev","crates.io","index.crates.io","static.crates.io","docker.io","*.docker.io","gcr.io","ghcr.io","goproxy.io","k8s.io","packagecloud.io","pypa.io","quay.io","rvm.io","spring.io","playwright.azureedge.net","dot.net","java.net","launchpad.net","ppa.launchpad.net","sourceforge.net","alpinelinux.org","apache.org","archlinux.org","bitbucket.org","centos.org","cocoapods.org","cpan.org","debian.org","npm.duckdb.org","eclipse.org","fedoraproject.org","golang.org","proxy.golang.org","sum.golang.org","gradle.org","haskell.org","json-schema.org","apt.llvm.org","maven.org","metacpan.org","nodejs.org","npmjs.org","registry.npmjs.org","nuget.org","packagist.org","pypi.org","pypi.python.org","pythonhosted.org","files.pythonhosted.org","ruby-lang.org","rubygems.org","rubyonrails.org","static.rust-lang.org","json.schemastore.org","swift.org","ziglang.org","hex.pm","rustup.rs","sh.rustup.rs","mise.run","binaries.prisma.sh","fonts.gstatic.com","repo.maven.apache.org","registry.yarnpkg.com"],"default":"deny","version":1}
77225 07-01:33:25 /Applications/Cursor.app/Contents/Resources/app/resources/helpers/cursorsandbox --run-proxy --policy-json {"allow":["public.ecr.aws","awscli.amazonaws.com","anaconda.com","azure.com","cloudflarestorage.com","*.cloudflarestorage.com","docker.com","*.docker.com","github.com","codeload.github.com","githubusercontent.com","*.githubusercontent.com","gitlab.com","google.com","dl.google.com","*.googleapis.com","*.gvt1.com","hashicorp.com","java.com","microsoft.com","dotnet.microsoft.com","mcr.microsoft.com","packages.microsoft.com","npmjs.com","oracle.com","ubuntu.com","archive.ubuntu.com","security.ubuntu.com","public.blob.vercel-storage.com","*.public.blob.vercel-storage.com","visualstudio.com","yarnpkg.com","*.yarnpkg.com","pkg.go.dev","*.anysphere.workers.dev","*.jdx.dev","pub.dev","crates.io","index.crates.io","static.crates.io","docker.io","*.docker.io","gcr.io","ghcr.io","goproxy.io","k8s.io","packagecloud.io","pypa.io","quay.io","rvm.io","spring.io","playwright.azureedge.net","dot.net","java.net","launchpad.net","ppa.launchpad.net","sourceforge.net","alpinelinux.org","apache.org","archlinux.org","bitbucket.org","centos.org","cocoapods.org","cpan.org","debian.org","npm.duckdb.org","eclipse.org","fedoraproject.org","golang.org","proxy.golang.org","sum.golang.org","gradle.org","haskell.org","json-schema.org","apt.llvm.org","maven.org","metacpan.org","nodejs.org","npmjs.org","registry.npmjs.org","nuget.org","packagist.org","pypi.org","pypi.python.org","pythonhosted.org","files.pythonhosted.org","ruby-lang.org","rubygems.org","rubyonrails.org","static.rust-lang.org","json.schemastore.org","swift.org","ziglang.org","hex.pm","rustup.rs","sh.rustup.rs","mise.run","binaries.prisma.sh","fonts.gstatic.com","repo.maven.apache.org","registry.yarnpkg.com"],"default":"deny","version":1}
79534       09:39 /bin/bash -O extglob -c snap=$(command cat <&3) && builtin shopt -s extglob && builtin eval -- "$snap" && { builtin set +u 2>/dev/null || true; builtin eval "${__CURSOR_SANDBOX_ENV_RESTORE:-}" 2>/dev/null; builtin export PWD="$(builtin pwd)"; builtin shopt -s expand_aliases 2>/dev/null; builtin eval "$1" < /dev/null; }; COMMAND_EXIT_CODE=$?; dump_bash_state >&4; builtin exit $COMMAND_EXIT_CODE -- cd /Users/augstar/macprovider-1745-air/phase3-binary && swift build -c release --product macprovider-cli
79547       09:39 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-build -c release --product macprovider-cli

exec
/bin/bash -lc "ps -Ao pid,etime,command | rg '/Users/augstar/macprovider-1646-rest/phase3-binary|PID: 5365|swift-test|xctest' | head -50" in /Users/augstar/macprovider-1646-rest
 succeeded in 0ms:
 5368       00:55 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-test --filter ContinuousBatchToolStructuredRowTests
 5370       00:55 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-test --filter ServingKnobsConfigTests/testRequestStateRepresentableGateOnParsedRequests
 5374       00:55 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-test --filter ContinuousBatchSchedulerTests/testStopEarlyEndsDecodingRowAsStopAtNextToken
 7143       00:32 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-test --filter ServingKnobsConfigTests.testRequestStateRepresentableGateOnParsedRequests|ContinuousBatchSchedulerTests
 7967       00:09 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-test --filter ContinuousBatchSchedulerTests|ContinuousBatchStopTokenTests|ServingKnobsConfigTests
 9009       00:00 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-driver --driver-mode=swiftc -Xfrontend -new-driver-path -Xfrontend /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-driver -vfsoverlay /var/folders/dr/s790cqgx6dx_55127wsgnkw00000gn/T/TemporaryDirectory.gzE7Hl/vfs.yaml -L /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI -lPackageDescription -Xlinker -rpath -Xlinker /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI -target arm64-apple-macosx14.0 -plugin-path /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing -sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk -F /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks -I /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib -L /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib -swift-version 6 -I /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI -sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk -package-description-version 6.1.0 /Users/augstar/macprovider-1646-rest/phase3-binary/.build/checkouts/EventSource/Package.swift -o /var/folders/dr/s790cqgx6dx_55127wsgnkw00000gn/T/TemporaryDirectory.HgoEAg/eventsource-manifest
 9012       00:00 /bin/bash -c ps -Ao pid,etime,command | rg '/Users/augstar/macprovider-1646-rest/phase3-binary|PID: 5365|swift-test|xctest' | head -50
 9014       00:00 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend -frontend -c -primary-file /Users/augstar/macprovider-1646-rest/phase3-binary/.build/checkouts/EventSource/Package.swift -target arm64-apple-macosx14.0 -Xllvm -aarch64-use-tbi -enable-objc-interop -stack-check -sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk -I /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib -I /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI -F /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks -vfsoverlay /var/folders/dr/s790cqgx6dx_55127wsgnkw00000gn/T/TemporaryDirectory.gzE7Hl/vfs.yaml -no-color-diagnostics -Xcc -fno-color-diagnostics -swift-version 6 -package-description-version 6.1.0 -new-driver-path /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-driver -empty-abi-descriptor -plugin-path /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing -no-auto-bridging-header-chaining -module-name main -disable-clang-spi -target-sdk-version 26.5 -target-sdk-name macosx26.5 -external-plugin-path /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins#/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/bin/swift-plugin-server -external-plugin-path /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/local/lib/swift/host/plugins#/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/bin/swift-plugin-server -in-process-plugin-server-path /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/libSwiftInProcPluginServer.dylib -plugin-path /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins -plugin-path /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/local/lib/swift/host/plugins -o /var/folders/dr/s790cqgx6dx_55127wsgnkw00000gn/T/TemporaryDirectory.o8UeKq/Package-1.o
 9016       00:00 rg /Users/augstar/macprovider-1646-rest/phase3-binary|PID: 5365|swift-test|xctest

exec
/bin/bash -lc 'ps -p 5368,5370,5374,7143,7967 -o pid,ppid,stat,etime,command && lsof -p 5368 2>/dev/null | tail -10' in /Users/augstar/macprovider-1646-rest
 succeeded in 0ms:
  PID  PPID STAT ELAPSED COMMAND
 5368 99442 Ss     01:10 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-test --filter ContinuousBatchToolStructuredRowTests
 5370 99442 Ss     01:10 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-test --filter ServingKnobsConfigTests/testRequestStateRepresentableGateOnParsedRequests
 5374 99442 Ss     01:10 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-test --filter ContinuousBatchSchedulerTests/testStopEarlyEndsDecodingRowAsStopAtNextToken
 7143  7115 S      00:47 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-test --filter ServingKnobsConfigTests.testRequestStateRepresentableGateOnParsedRequests|ContinuousBatchSchedulerTests
 7967  5338 S      00:24 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-test --filter ContinuousBatchSchedulerTests|ContinuousBatchStopTokenTests|ServingKnobsConfigTests
swift-pac 5368 augstar    9u      REG               1,17     16384            16027378 /Users/augstar/Library/HTTPStorages/swift-test/httpstorages.sqlite
swift-pac 5368 augstar   10u      REG               1,17   1565632            16027381 /Users/augstar/Library/HTTPStorages/swift-test/httpstorages.sqlite-wal
swift-pac 5368 augstar   11u      REG               1,17     32768            16027382 /Users/augstar/Library/HTTPStorages/swift-test/httpstorages.sqlite-shm
swift-pac 5368 augstar   12   NPOLICY                                                  
swift-pac 5368 augstar   13u    systm 0x5b1fc502f5072085       0t0                     [ctl com.apple.netsrc id 7 unit 11]
swift-pac 5368 augstar   14      CHAN             flowsw                               E4B48B2E-14B0-47CF-BABD-AD6E41324C3A[9] user-packet-pool
swift-pac 5368 augstar   15u      REG               1,17     65536            16027372 /Users/augstar/Library/Caches/swift-test/Cache.db
swift-pac 5368 augstar   16u      REG               1,17   3691552            16027375 /Users/augstar/Library/Caches/swift-test/Cache.db-wal
swift-pac 5368 augstar   17      PIPE 0x8a67e3aea2272542     16384                     ->0xbfac360a6b04b07b
swift-pac 5368 augstar   19      PIPE 0xea413f8803702c34     16384                     ->0x8c5475a8da5b4bb7

exec
/bin/bash -lc 'git log --oneline --decorate --max-count=5 && git diff --stat origin/main...52fcb7e4 && git diff --name-only origin/main...52fcb7e4' in /Users/augstar/macprovider-1646-rest
 succeeded in 63ms:
 .../macprovider-cli/ContinuousBatchScheduler.swift |  18 +
 .../Sources/macprovider-cli/ModelRuntime.swift     | 886 ++++++++++++++-------
 .../ContinuousBatchSchedulerTests.swift            |  30 +
 .../ContinuousBatchToolStructuredRowTests.swift    | 499 ++++++++++++
 .../ServingKnobsConfigTests.swift                  |  49 +-
 specs/CONFORMANCE.json                             |   2 +-
 specs/README.md                                    |   2 +-
 specs/SPEC-038-continuous-batching.md              |  53 +-
 8 files changed, 1215 insertions(+), 324 deletions(-)
phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift
phase3-binary/Tests/macprovider-cliTests/ContinuousBatchSchedulerTests.swift
phase3-binary/Tests/macprovider-cliTests/ContinuousBatchToolStructuredRowTests.swift
phase3-binary/Tests/macprovider-cliTests/ServingKnobsConfigTests.swift
specs/CONFORMANCE.json
specs/README.md
specs/SPEC-038-continuous-batching.md

exec
/bin/bash -lc 'git diff --no-ext-diff --unified=20 origin/main...52fcb7e4 -- specs/SPEC-038-continuous-batching.md specs/CONFORMANCE.json specs/README.md && git diff --no-ext-diff --unified=20 origin/main...52fcb7e4 -- phase3-binary/Tests/macprovider-cliTests/ContinuousBatchSchedulerTests.swift' in /Users/augstar/macprovider-1646-rest
 succeeded in 0ms:
diff --git a/specs/CONFORMANCE.json b/specs/CONFORMANCE.json
index db4656ed..32ec02e5 100644
--- a/specs/CONFORMANCE.json
+++ b/specs/CONFORMANCE.json
@@ -1082,41 +1082,41 @@
         "SPEC-015",
         "SPEC-022",
         "SPEC-026",
         "SPEC-030"
       ],
       "implementation_status": "pending-reconciliation",
       "production_status": "pending-verification",
       "last_reconciled_commit": null,
       "last_reconciled_at": null,
       "evidence": [],
       "requirement_id_migration": "complete",
       "gap": {
         "verdict": "UNKNOWN",
         "owner": "@Augustas11",
         "issue": "https://github.com/Augustas11/macprovider/issues/614"
       }
     },
     {
       "spec_id": "SPEC-038",
       "title": "Continuous batching for concurrent provider inference",
-      "version": "v0.2.10",
+      "version": "v0.2.11",
       "path": "specs/SPEC-038-continuous-batching.md",
       "status": "draft",
       "owner": "@Augustas11",
       "authority_domains": [
         "continuous-batching-serving"
       ],
       "supersedes": [],
       "depends_on": [
         "SPEC-005",
         "SPEC-010",
         "SPEC-015",
         "SPEC-023",
         "SPEC-024",
         "SPEC-028",
         "SPEC-037",
         "SPEC-039"
       ],
       "implementation_status": "pending-reconciliation",
       "production_status": "not-deployed",
       "last_reconciled_commit": null,
diff --git a/specs/README.md b/specs/README.md
index 01f06436..a064ce46 100644
--- a/specs/README.md
+++ b/specs/README.md
@@ -29,41 +29,41 @@ it can no longer drift. Do not hand-edit the table; edit each spec's
 | SPEC-018 | Agentic tool calling (provider-side response synthesis) | 0.2.9 | normative | pending | pending: 4 | [SPEC-018-agentic-tool-calling.md](SPEC-018-agentic-tool-calling.md) |
 | SPEC-019 | Structured output (`response_format: json_schema`) | 0.2.5 | normative | pending | pending corpus migration | [SPEC-019-structured-output.md](SPEC-019-structured-output.md) |
 | SPEC-020 | Provider autoupdate | v0.1.19 | normative | pending | pending: 5 | [SPEC-020-provider-autoupdate.md](SPEC-020-provider-autoupdate.md) |
 | SPEC-021 | MALIBU rewards emission ledger | 0.4.0 | draft | complete | pending: 10 | [SPEC-021-malibu-emission-ledger.md](SPEC-021-malibu-emission-ledger.md) |
 | SPEC-022 | Verified model settlement | v0.2.2 | draft | complete | conformant: 4, pending: 8 | [SPEC-022-verified-model-settlement.md](SPEC-022-verified-model-settlement.md) |
 | SPEC-023 | Installer-Integrated Autotune Recommend | v0.17.1 | normative | pending | conformant: 2, pending: 15 | [SPEC-023-installer-autotune-recommend.md](SPEC-023-installer-autotune-recommend.md) |
 | SPEC-024 | Prefix-cache billing and provider-local cache isolation | 0.2.6 | normative | pending | pending: 2 | [SPEC-024-prefix-cache-billing.md](SPEC-024-prefix-cache-billing.md) |
 | SPEC-025 | Native Mac App (signed `.dmg` + menu bar wrapper) | v0.29 | draft | pending | pending corpus migration | [SPEC-025-native-mac-app.md](SPEC-025-native-mac-app.md) |
 | SPEC-026 | Browserless Provider Onboarding (one-click Launch Provider) | v0.29 | draft | pending | pending corpus migration | [SPEC-026-browserless-provider-onboarding.md](SPEC-026-browserless-provider-onboarding.md) |
 | SPEC-027 | Provider Proof of Ownership for App-Track Wallet Changes | v0.1 | draft | pending | pending corpus migration | [SPEC-027-provider-proof-of-ownership.md](SPEC-027-provider-proof-of-ownership.md) |
 | SPEC-028 | MLX Speculative Decoding for Provider Serve | 0.2-draft | draft | pending | pending corpus migration | [SPEC-028-mlx-speculative-decoding.md](SPEC-028-mlx-speculative-decoding.md) |
 | SPEC-029 | Sweep Workload-Class Stratification | 0.1-draft | draft | pending | pending corpus migration | [SPEC-029-sweep-workload-class-stratification.md](SPEC-029-sweep-workload-class-stratification.md) |
 | SPEC-030 | Losslessness Probe | v0.1 | draft | pending | pending corpus migration | [SPEC-030-losslessness-probe.md](SPEC-030-losslessness-probe.md) |
 | SPEC-031 | Canary Probe, Degrade & Sanction Lifecycle | v0.2 | draft | pending | pending corpus migration | [SPEC-031-canary-degrade-sanctions.md](SPEC-031-canary-degrade-sanctions.md) |
 | SPEC-032 | Autotune Hardware-Evidence Admission Gate, OPoI & Proof-of-Weights Boundary | v0.3.1 | draft | complete | conformant: 2, pending: 2 | [SPEC-032-proof-of-weights-hello-gate.md](SPEC-032-proof-of-weights-hello-gate.md) |
 | SPEC-033 | Hardware-Evidence Verifier (`hardware-verifier.v2`) | v0.6.3 | draft | pending | conformant: 1 | [SPEC-033-hardware-verifier.md](SPEC-033-hardware-verifier.md) |
 | SPEC-034 | Referral admission, provider invites, and advocacy rewards | v0.4.7 | normative | pending | conformant: 1 | [SPEC-034-referral-gated-prebeta.md](SPEC-034-referral-gated-prebeta.md) |
 | SPEC-035 | Provider connection diagnostics and failure history | v0.4.3 | draft | complete | pending: 13 | [SPEC-035-provider-connection-diagnostics.md](SPEC-035-provider-connection-diagnostics.md) |
 | SPEC-036 | Compute-Integrity Receipt Companion | v0.1.1 | draft | complete | pending: 17 | [SPEC-036-compute-integrity-receipt.md](SPEC-036-compute-integrity-receipt.md) |
 | SPEC-037 | KV survival across provider restarts (encrypted provider-local disk tier) | v0.1.4 | draft | complete | pending: 13 | [SPEC-037-kv-survival-restart.md](SPEC-037-kv-survival-restart.md) |
-| SPEC-038 | Continuous batching for concurrent provider inference | v0.2.10 | draft | complete | pending: 17 | [SPEC-038-continuous-batching.md](SPEC-038-continuous-batching.md) |
+| SPEC-038 | Continuous batching for concurrent provider inference | v0.2.11 | draft | complete | pending: 17 | [SPEC-038-continuous-batching.md](SPEC-038-continuous-batching.md) |
 | SPEC-039 | Paged KV / paged-attention engine | v0.1.6 | draft | complete | pending: 14 | [SPEC-039-paged-kv-attention-engine.md](SPEC-039-paged-kv-attention-engine.md) |
 | SPEC-040 | Wallet-Native Buyer Sessions | 0.1.9 | draft | complete | pending: 10 | [SPEC-040-wallet-native-buyer-sessions.md](SPEC-040-wallet-native-buyer-sessions.md) |
 | SPEC-041 | Relay-Blind Request Encryption | 0.2.0 | draft | complete | pending: 8 | [SPEC-041-relay-blind-request-encryption.md](SPEC-041-relay-blind-request-encryption.md) |
 | SPEC-042 | Pool Control Plane and Trusted-Pool Manifest | 0.0.34 | draft | complete | pending: 14 | [SPEC-042-pool-control-plane.md](SPEC-042-pool-control-plane.md) |
 | SPEC-043 | Trusted Pool Creator Onboarding MVP | 0.2.0 | normative | complete | pending: 13 | [SPEC-043-trusted-pool-creator-onboarding.md](SPEC-043-trusted-pool-creator-onboarding.md) |
 | SPEC-044 | Malibu Model Catalog Economics | 0.2.10 | draft | complete | pending: 12 | [SPEC-044-malibu-model-catalog-economics.md](SPEC-044-malibu-model-catalog-economics.md) |
 | SPEC-045 | Local Consumer Endpoint Mode | 0.1.0 | draft | complete | conformant: 4, pending: 4 | [SPEC-045-local-consumer-endpoint-mode.md](SPEC-045-local-consumer-endpoint-mode.md) |
 | SPEC-046 | Provider BYOM Discovery | 0.3.0 | draft | complete | conformant: 6, pending: 3 | [SPEC-046-provider-byom-discovery.md](SPEC-046-provider-byom-discovery.md) |
 | SPEC-047 | Network Model Admission | 0.2.2 | draft | complete | conformant: 7, pending: 3 | [SPEC-047-network-model-admission.md](SPEC-047-network-model-admission.md) |
 <!-- AUTOGEN:spec-index END -->
 
 **Version of record is each spec's own `**Version:**` header, not this table.**
 The table now mirrors those headers exactly (CI fails if it drifts), but for a
 compatibility decision still read the spec header — `grep -m1 '^\*\*Version'
 specs/SPEC-NNN-*.md`.
 
 Only **canonical** specs appear above — a file with a `# SPEC-NNN — Title`
 first line **and** a `**Version:**` header. Supporting artifacts (round-N
 audits, `FIX`/`ABSORB` prompts, impl/step notes) are intentionally excluded and
 were moved out of `specs/` per [`REORG_PLAN.md`](REORG_PLAN.md). If a SPEC
diff --git a/specs/SPEC-038-continuous-batching.md b/specs/SPEC-038-continuous-batching.md
index 8d629630..cd3bc2af 100644
--- a/specs/SPEC-038-continuous-batching.md
+++ b/specs/SPEC-038-continuous-batching.md
@@ -1,35 +1,47 @@
 # SPEC-038 — Continuous batching for concurrent provider inference
 
-Version: v0.2.10
+Version: v0.2.11
 Status: draft (normative design; no IMPL in this SPEC - implementation is a separate PR behind a disabled-by-default flag)
 Owner: provider runtime / inference scheduler
 Decision source: `docs/research/RESEARCH_232_MULTISTREAM_BATCHING_MEMO.md` (original memo, commit `8d80f6c4`), `docs/research/RESEARCH_232_ADDENDUM_PAGED_REDECISION_2026-07-29.md`, `docs/research/SPIKE_PAGED_ATTN_PHASE0_RESULT_2026-07-29.md` (commit `e5ded571`), `docs/research/SPIKE_PAGED_ATTN_PHASE2_RESULT_2026-07-29.md` (commit `acc30b1e`), and `docs/research/SPIKE_PAGED_ATTN_PHASE3_MOE_RESULT_2026-07-29.md` (commit `da21af53`).
 Audit history: v0.2 is subject to three-lane codex SPEC audit (code / security / architect). Convergence and any carried LOW/INFO findings are recorded in the SPEC PR body and `audits/2026-07-29/SPEC-038-v0_2-rN-audit.md`.
 v0.2.3 lets canary admit conversation-keyed first-turn / cache-miss requests
 into the scheduler. Any positive `cached_prompt_tokens` still serial-routes
 until AC-26, even when a retained FR-PKV10 paged-KV handoff exists. v0.2.2
 clarifies the API-visible admission/replay/terminal contract, records
 decode-first scheduling as a conservative v0.2 choice rather than a claim of
 vLLM/SGLang-style unified-token scheduling, and tightens the real-serving
 evidence gate for retained paged-KV reuse.
 
+**Change log v0.2.11 (2026-09-25, tool-bearing and structured-output rows):**
+FR-CB6 and the new AC-6c admit requests with enabled tools or a JSON
+`response_format` (json_object / json_schema) into the shared forward. Neither
+constrains a logit: the serial path renders them into the prompt and applies
+them after generation, and a batched row now reuses exactly that prompt
+rendering and post-generation finalize. That covers tool-call parsing, the
+SPEC-018 byte caps, structured validation, and the streamed tool-call deltas
+and structured accumulator. A serial tool turn (`parallel_tool_calls` omitted
+or false) ends where the serial path stops generating. Harmony models with
+tools or structured output, logit-bias requests and logprob requests still
+serial-route.
+
 **Change log v0.2.10 (2026-09-25, bounded decode windows):** FR-CB2 now
 describes the decode hop as the implementation runs it. One hop advances every
 active decode row by a bounded window of W tokens, applying sampling, stop and
 emission to each token in order. W is at most the lockstep window (16 in
 production) and is capped by each row's remaining output budget.
 
 - W is 1 whenever a request waits for a free slot or is being admitted, so it
   joins at the next hop boundary.
 - While a prompt is mid-prefill and nothing else waits to join, W is at most
   the prefill decode window (8 in production). The rule was one token per
   prefill chunk, which left active rows at about 0.6 tok/s behind a long
   prompt on the M3 Ultra, because a 512-token chunk costs about as much as
   30–50 decode steps.
 
 Prefill evaluates only the caches, never the vocabulary projection, because
 prefill never samples.
 
 **Change log v0.2.9 (2026-09-24, per-tuple cached-turn acceptance):** AC-26
 is satisfied per tuple and per runtime revision. The FR-CB10 accepted-tuple
 entry gains an optional boolean `cached_turns_accepted` (default false). A
@@ -468,40 +480,62 @@ MUST guarantee, per request:
 Batch metadata (row index, batch depth, mean fill, cohort) MAY appear only in
 non-receipt diagnostic telemetry (FR-CB14) and MUST NOT alter buyer-visible
 token accounting. Deterministic (temperature-0) output for a request under
 batching MUST match its serial-path output within the accepted numerical
 tolerance.
 
 A sampled (non-greedy) request MAY batch. Its row MUST select each token with
 exactly the sampling algorithm the serial path uses for the same request
 parameters (temperature, top_p), applied only to that row's own logits. The
 row's randomness MUST be row-local:
 - it is derived from that request's identity and the step index;
 - it is never shared with another row;
 - it is never carried in hidden cross-step state.
 
 Sampled output is therefore equal in distribution to the serial path, not
 token-identical to a particular serial run (the serial path is not seeded). A
 replay of the same request identity reproduces the same draws. Parameters the
 serial path ignores (presence and frequency penalties) MUST be ignored on the
 batched path too, so batching never changes what a request asks for.
 
+**(v0.2.11)** A request with enabled tools or a JSON `response_format` MAY
+batch, because neither constrains a logit. Its row MUST use the serial path's
+prompt rendering (response-format instruction, tool schemas in the chat
+template) and, on the row's generated text, the serial path's post-generation
+steps:
+- the SPEC-018 response and per-call byte caps and tool-call parsing, with the
+  same `tool_calls` and `finish_reason: tool_calls` in non-streaming bodies;
+- the serial streaming text step, so streamed tool-call deltas, assistant
+  content suppression and the SPEC-019 structured-content accumulator produce
+  the serial SSE sequence;
+- structured validation with the serial error, raised after the same chunks
+  as on the serial path, and the SPEC-019 structured-streaming idle timeout.
+
+A serial tool turn (`parallel_tool_calls` omitted or false) MUST end where the
+serial path stops generating: at the first token whose decoded prefix holds a
+complete valid tool call. The row MAY decode past that token before it stops.
+The completion MUST then be computed from the tokens up to that point only,
+for text and billed tokens, and a row that decoded past it MUST NOT commit a
+conversation-cache entry. Requests on a Harmony model with tools or structured
+output stay serial-routed, because the batched stream has no Harmony channel
+parser. Logit-bias and logprob requests stay serial-routed too.
+
 The accepted numerical tolerance recognizes that a shared batched forward and
 a serial forward differ only in floating-point ACCUMULATION ORDER (batched
 matmuls and MoE expert routing versus a single row), which can flip greedy
 argmax between two near-tied tokens of the SAME request's own distribution. For
 the load-time batched isolation self-test (the MoE input-isolation probe), a
 row's greedy token is therefore conformant when it is EITHER the row's own
 serial-path argmax, OR the row's own serial-path runner-up whose logit is within
 a fixed small tolerance of that row's serial argmax logit — a genuine
 own-distribution numerical tie. Any other token is a divergence; in particular a
 token equal to ANOTHER row's serial argmax MUST always be treated as a
 divergence (a leak), never as a tie. This tolerance applies ONLY to the
 batched-versus-serial argmax comparison; it does NOT relax the SPEC-039 single-
 row paged-gather parity gate, which shares the serial computation's accumulation
 order and so remains exact.
 
 ### FR-CB7 - single-owner actor isolation (SPEC-038-R007)
 
 All mutable batch state (queue, prompt set, decode batch, per-row lifecycle,
 request block tables, cache handles, admission reservations, and terminal
 bookkeeping) MUST be owned by a single Swift actor or an equivalently
@@ -881,40 +915,57 @@ hardware-capability run or a static-review obligation. Every
   output, both as a lone row and as one row among a full batch. Under greedy
   decoding the sampled token sequence MUST be identical (byte/token-identical);
   a numerical tolerance applies only where the fixture explicitly compares raw
   logits, and then the exact threshold MUST be stated in the fixture.
 - **AC-6b sampled-row equivalence and isolation (FR-CB6):** a unit fixture
   shows three things. With identical logits, parameters and seed, a batched
   row's token equals the serial sampler's token (same algorithm). A row's token
   is unchanged by its batch neighbours. A nucleus small enough to keep only the
   argmax yields the greedy token.
   On hardware, three things hold:
   - a sampled request's output for a given request identity is identical as a
     lone row and as one row among concurrent sampled rows;
   - it is identical across repeats;
   - there is no cross-row leak signal.
   Against the serial path's own sampler for the same parameters it matches
   within the FR-CB6 numerical tolerance. Differences are allowed only where the
   batched forward's logits differ by accumulation order, or at exact bf16 logit
   ties that sampling filters and argmax break differently. A tiny top_p is NOT
   equivalent to greedy even on the serial path, because of those ties.
   Distinct concurrent requests MUST NOT share a sampler seed.
+- **AC-6c tool-bearing and structured-output row equivalence (FR-CB6,
+  v0.2.11):** unit fixtures show, for identical generated text:
+  - the batched finalize yields exactly the serial `tool_calls`,
+    `finish_reason` and structured-validation verdict (including invalid JSON
+    under `json_schema` and the SPEC-018 response byte cap), non-streaming and
+    streaming;
+  - the batched stream emits the serial tool-call delta and content chunk
+    sequence;
+  - a serial tool turn that decoded past its first complete tool call is
+    truncated to the serial stop token for text and billed tokens.
+
+  The routing gate admits tool-bearing and structured-output requests and
+  still rejects logit-bias and logprob requests. On hardware, a tool-bearing
+  request and a `json_schema` request each run as one row among concurrent
+  batched rows, streaming and non-streaming. Each returns the same
+  `tool_calls` (name and arguments) or schema-valid content that the serial
+  path returns for the same greedy request.
 - **AC-7 unsupported cache/`kv_bits`/local capability rejection (FR-CB8,
   FR-CB10):** a `newCache`-overriding model family, an unsupported
   `SPEC-039` tuple, an unsupported MoE expert-dispatch surface, and an
   unsupported quantized-KV (`kv_bits`) configuration each either route to the
   serial path (permissive mode) or fail preflight with a named, observable
   reason code; none silently downgrade KV quantization, reinterpret a
   quantized cache as ordinary KV, cite a missing upstream pin, or silently
   run serial.
 - **AC-8 Entry 110 capacity mapping (FR-CB11):** `slots_total` equals the
   persisted `max_concurrency_override` across each hardware tier fixture;
   active rows never exceed it; a scheduler with `slots_total` active rows and
   a full waiting queue still advertises `slots_total`, not
   `slots_total + queue`.
 - **AC-9 SPEC-028 exclusion (FR-CB12):** a draft-enabled provider keeps
   `effective_max_batch = 1`; an explicit `max_concurrency_override > 1` with a
   draft model fails preflight `draft_model_capacity_shortfall`; a
   speculative-routed request acquires no batch row and triggers no shared
   forward.
 - **AC-10 warm-swap drain + snapshot binding (FR-CB13):** a warm swap with
   active prompt rows, active decode rows, and accepted queued work: accepted
diff --git a/phase3-binary/Tests/macprovider-cliTests/ContinuousBatchSchedulerTests.swift b/phase3-binary/Tests/macprovider-cliTests/ContinuousBatchSchedulerTests.swift
index dba1253c..d95a2276 100644
--- a/phase3-binary/Tests/macprovider-cliTests/ContinuousBatchSchedulerTests.swift
+++ b/phase3-binary/Tests/macprovider-cliTests/ContinuousBatchSchedulerTests.swift
@@ -1789,40 +1789,70 @@ final class ContinuousBatchSchedulerTests: XCTestCase {
                 conversationKey: "",
                 promptTokens: [1],
                 maxOutputTokens: 2
             ),
             tokenSink: { recorder.append($0) }
         )
 
         try await eventually { recorder.events().count == 1 }
         let events = recorder.events()
         XCTAssertEqual(events.map(\.tokenIndex), [0])
         XCTAssertEqual(events.map(\.token), [7])
         XCTAssertEqual(events.map(\.replayTokens), [nil])
         XCTAssertEqual(events.first?.snapshot.modelSHA256, Self.modelSHA)
         XCTAssertEqual(result.terminalStatus, .batchFailed)
         XCTAssertEqual(result.outputTokens, [])
         XCTAssertEqual(result.completionTokens, 0)
         XCTAssertEqual(result.emittedTokens, 1)
         XCTAssertEqual(result.snapshot?.modelSHA256, Self.modelSHA)
     }
 
+    /// SPEC-038 AC-6c: a serial tool turn asks its decoding row to end; the
+    /// row finishes as a normal `.stop` at its next token instead of running
+    /// to `max_tokens`.
+    func testStopEarlyEndsDecodingRowAsStopAtNextToken() async throws {
+        let secondDecodeGate = AsyncGate()
+        let recorder = TokenEventRecorder()
+        let backend = SecondDecodeGateBackend(secondDecodeGate: secondDecodeGate)
+        let scheduler = try await makeScheduler(maxActiveRows: 1, backend: backend)
+        let submitted = Task {
+            try await scheduler.submit(
+                .init(id: "tool-turn", conversationKey: "", promptTokens: [1], maxOutputTokens: 8),
+                tokenSink: { recorder.append($0) }
+            )
+        }
+        try await eventually { recorder.events().count == 1 }
+        await scheduler.stopEarly(requestID: "tool-turn")
+        await secondDecodeGate.open()
+        let result = try await submitted.value
+
+        XCTAssertEqual(result.terminalStatus, .stop)
+        XCTAssertNil(result.errorCode)
+        XCTAssertEqual(result.generatedTokens, [7, 8])
+        XCTAssertEqual(result.outputTokens, [7, 8])
+        XCTAssertEqual(result.completionTokens, 2)
+        XCTAssertEqual(result.settlementDisposition, .eligibleOwner)
+        // A stop request for a row that is not decoding is ignored.
+        await scheduler.stopEarly(requestID: "tool-turn")
+        await scheduler.stopEarly(requestID: "unknown")
+    }
+
     func testTerminalResultWaitsForAcceptedTokenDelivery() async throws {
         let sinkGate = AsyncGate()
         let recorder = TokenEventRecorder()
         let completion = CompletionFlag()
         let duplicateRecorder = TokenEventRecorder()
         let duplicateCompletion = CompletionFlag()
         let backend = ScriptedBackend(scripts: ["ordered": [7]])
         let scheduler = try await makeScheduler(maxActiveRows: 1, backend: backend)
 
         let submission = Task {
             let result = try await scheduler.submit(
                 .init(
                     id: "ordered",
                     conversationKey: "",
                     promptTokens: [1],
                     maxOutputTokens: 1
                 ),
                 tokenSink: { event in
                     recorder.append(event)
                     await sinkGate.wait()

exec
/bin/bash -lc "rg -n \"struct ParsedGeneratedOutput|func parseGeneratedOutput|generatedCompletionTokens|completionTokens\" phase3-binary/Sources/macprovider-cli/ModelRuntime.swift | tail -60 && sed -n '6720,7050p' phase3-binary/Sources/macprovider-cli/ModelRuntime.swift" in /Users/augstar/macprovider-1646-rest
 succeeded in 0ms:
4099:        var completionTokenCount = result.completionTokens
4162:                completionTokens: parsed.completionTokens,
4163:                generatedCompletionTokens: parsed.generatedCompletionTokens,
4856:                tokensGenerated: completion.generatedCompletionTokens,
5211:                            completionTokens: parsed.completionTokens,
5212:                            generatedCompletionTokens: parsed.generatedCompletionTokens,
5294:            completionTokens: generated.generationTokenCount,
5697:                            completionTokens: generated.generationTokenCount,
5920:                            completionTokens: parsed.completionTokens,
5921:                            generatedCompletionTokens: parsed.generatedCompletionTokens,
6900:    struct ParsedGeneratedOutput: Sendable {
6903:        let completionTokens: Int
6904:        let generatedCompletionTokens: Int
6909:    static func parseGeneratedOutput(
6925:                completionTokens: defaultCompletionTokens,
6926:                generatedCompletionTokens: defaultCompletionTokens,
6946:            generatedCompletionTokens: defaultCompletionTokens
6957:        generatedCompletionTokens: Int = 0
6976:            completionTokens: countCompletionTokens ? harmonyVisibleFinalTokenCount(
6982:            generatedCompletionTokens: generatedCompletionTokens,
7182:            completionTokens: completion.completionTokens,
7183:            generatedCompletionTokens: completion.generatedCompletionTokens,
7209:            completionTokens: 0,
7951:    let completionTokens: Int
7952:    let generatedCompletionTokens: Int
7973:        completionTokens: Int,
7974:        generatedCompletionTokens: Int? = nil,
7994:        self.completionTokens = completionTokens
7995:        self.generatedCompletionTokens = max(0, generatedCompletionTokens ?? completionTokens)
8014:            completionTokens: completionTokens,
8015:            generatedCompletionTokens: generatedCompletionTokens,
8045:            completionTokens: tokens ?? completionTokens,
8046:            generatedCompletionTokens: tokens ?? generatedCompletionTokens,
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            guard !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hexString(hasher.finalize())
    }

    private static func hexString<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func validObservedModelHash(_ hash: String?) -> String? {
        guard let hash, hash.utf8.count == 64 else {
            if let hash, !hash.isEmpty {
                FileHandle.standardError.write(Data("AC-46: validObservedModelHash rejected malformed value: \(hash.prefix(16))...\n".utf8))
            }
            return nil
        }
        guard hash.utf8.allSatisfy({ byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }) else {
            FileHandle.standardError.write(Data("AC-46: validObservedModelHash rejected non-hex value: \(hash.prefix(16))...\n".utf8))
            return nil
        }
        return hash
    }

    static func applyOutputFilters(
        _ text: String,
        stopTokenFilter: StopTokenFilter,
        requestStops: [String]
    ) -> (text: String, hitStop: Bool) {
        let stripped = stopTokenFilter.stripping(from: text)
        var earliestStop: String.Index?
        for stop in requestStops where !stop.isEmpty {
            if let range = stripped.range(of: stop) {
                if earliestStop == nil || range.lowerBound < earliestStop! {
                    earliestStop = range.lowerBound
                }
            }
        }
        if let earliestStop {
            return (String(stripped[..<earliestStop]), true)
        }
        return (stripped, false)
    }

    /// SPEC-024 FR-CI2 hybrid reuse. For a keyed serial request on a model with
    /// recurrent layers, prefill `cache` from the tokens it already holds up to each
    /// recurrent checkpoint position (`ConversationCache.recurrentCheckpointPositions`)
    /// and snapshot the recurrent states there. Checkpoint positions the restored
    /// cache is already past reuse the stored checkpoint at that exact length (still
    /// a prefix of this prompt). `resumeAt` is the prompt index the TokenIterator
    /// must continue from, or nil when nothing was prefilled here.
    static func prefillRecurrentCheckpoints(
        lease: ConversationCacheLease?,
        cache: [KVCache],
        promptTokenIds: [Int32],
        context: ModelContext,
        prefillStepSize: Int
    ) -> (checkpoints: [RecurrentStateCheckpoint], resumeAt: Int?) {
        guard let lease else { return ([], nil) }
        let positions = ConversationCache.recurrentCheckpointPositions(
            promptTokenIds: promptTokenIds,
            imStartTokenID: context.tokenizer.convertTokenToId("<|im_start|>").map(Int32.init),
            hybrid: ConversationCacheLayers.hasRecurrentLayers(cache),
            decode: { context.tokenizer.decode(tokenIds: $0) })
        guard !positions.isEmpty else { return ([], nil) }
        let cachedTokens = lease.reusableCache == nil ? 0 : lease.lcp
        let reusable = lease.reusableCache?.recurrentCheckpoints ?? []
        var cursor = cachedTokens
        var checkpoints: [RecurrentStateCheckpoint] = []
        for position in positions {
            if position < cursor {
                if let stored = reusable.first(where: { $0.tokenCount == position }) {
                    checkpoints.append(stored)
                }
                continue
            }
            var start = cursor
            while start < position {
                let end = min(start + max(1, prefillStepSize), position)
                let chunk = LMInput.Text(tokens: MLXArray(Array(promptTokenIds[start..<end])))
                _ = context.model(chunk[text: .newAxis], cache: cache, state: nil)
                asyncEval(cache)
                start = end
            }
            eval(cache)
            cursor = position
            var states: [Int: [MLXArray]] = [:]
            for (index, layer) in cache.enumerated() where layer is ArraysCache {
                let state = layer.state
                guard !state.isEmpty else { return (checkpoints, cursor > cachedTokens ? cursor : nil) }
                states[index] = state
            }
            checkpoints.append(RecurrentStateCheckpoint(tokenCount: position, states: states))
        }
        return (checkpoints, cursor > cachedTokens ? cursor : nil)
    }

    static func cachedPromptUTF8Bytes(
        promptTokenIds: [Int32],
        cachedPromptTokens: Int,
        decode: ([Int]) -> String
    ) -> Int {
        let clamped = max(0, min(cachedPromptTokens, promptTokenIds.count))
        guard clamped > 0 else { return 0 }
        let prefixTokens = promptTokenIds.prefix(clamped).map(Int.init)
        return decode(Array(prefixTokens)).utf8.count
    }

    static func streamingSafePrefix(
        _ text: String,
        stopTokenFilter: StopTokenFilter,
        requestStops: [String]
    ) -> (text: String, hitStop: Bool) {
        let filtered = applyOutputFilters(
            text,
            stopTokenFilter: stopTokenFilter,
            requestStops: requestStops
        )
        guard !filtered.hitStop else {
            return filtered
        }

        let candidates = stopTokenFilter.tokens + requestStops.filter { !$0.isEmpty }
        let holdback = longestSuffixPrefixLength(in: filtered.text, candidates: candidates)
        let safe = holdback > 0 ? String(filtered.text.dropLast(holdback)) : filtered.text
        return (withoutIncompleteUTF8Tail(safe), false)
    }

    /// #1690 E2E-F13: a decode of a token prefix that ends inside a
    /// multi-byte UTF-8 character renders the partial bytes as trailing
    /// U+FFFD, which the next token replaces with the real character. Such a
    /// tail is never streamed; the final decode flushes it as it renders.
    static func withoutIncompleteUTF8Tail(_ text: String) -> String {
        var scalars = text.unicodeScalars
        while scalars.last == "\u{FFFD}" {
            scalars.removeLast()
        }
        return String(scalars)
    }

    /// The text to append so the streamed bytes become `current`: exact on
    /// Unicode scalars, not Characters, so a combining mark or a completed
    /// grapheme cluster never makes `emitted` look like a non-prefix or a
    /// dropped Character eat scalars. Empty when `current` does not extend
    /// `emitted` (never a lossy or out-of-order fragment).
    static func streamDelta(from emitted: String, to current: String) -> String {
        let emittedScalars = emitted.unicodeScalars
        let currentScalars = current.unicodeScalars
        guard currentScalars.starts(with: emittedScalars) else { return "" }
        var appended = String.UnicodeScalarView()
        appended.append(contentsOf: currentScalars.dropFirst(emittedScalars.count))
        return String(appended)
    }

    private static func longestSuffixPrefixLength(in text: String, candidates: [String]) -> Int {
        guard !text.isEmpty, !candidates.isEmpty else { return 0 }
        let maxLength = min(text.count, candidates.map(\.count).max() ?? 0)
        guard maxLength > 0 else { return 0 }

        var longest = 0
        for length in 1 ... maxLength {
            let suffix = String(text.suffix(length))
            if candidates.contains(where: { $0.hasPrefix(suffix) }) {
                longest = length
            }
        }
        return longest
    }

    private static func delta(from emitted: String, to current: String) -> String {
        streamDelta(from: emitted, to: current)
    }

    struct ParsedGeneratedOutput: Sendable {
        let content: String
        let toolCalls: [ToolCall]
        let completionTokens: Int
        let generatedCompletionTokens: Int
        let hitStop: Bool
        let isTerminal: Bool
    }

    static func parseGeneratedOutput(
        filteredText: String,
        generatedTokenIDs: [Int],
        decode: ([Int]) -> String,
        request: ChatCompletionRequest,
        mode: HarmonyResponseParser.Mode,
        defaultCompletionTokens: Int,
        stopTokenFilter: StopTokenFilter = StopTokenFilter(tokens: []),
        requestStops: [String] = [],
        globalHitStop: Bool = false
    ) throws -> ParsedGeneratedOutput {
        guard HarmonyResponseParser.isHarmonyModelID(request.model) else {
            let parsed = parseToolCallsIfRequested(filteredText, request: request)
            return ParsedGeneratedOutput(
                content: parsed.content,
                toolCalls: parsed.toolCalls,
                completionTokens: defaultCompletionTokens,
                generatedCompletionTokens: defaultCompletionTokens,
                hitStop: false,
                isTerminal: true
            )
        }

        let parsed = HarmonyResponseParser.parse(
            tokenIDs: generatedTokenIDs,
            decode: decode,
            allowedFunctionNames: toolFunctionNames(from: request.promptSource.tools),
            mode: mode,
            stopCandidates: stopTokenFilter.tokens + requestStops
        )
        return try harmonyParsedOutput(
            from: parsed,
            decode: decode,
            stopTokenFilter: stopTokenFilter,
            requestStops: requestStops,
            globalHitStop: globalHitStop,
            countCompletionTokens: true,
            generatedCompletionTokens: defaultCompletionTokens
        )
    }

    private static func harmonyParsedOutput(
        from parsed: HarmonyResponseParser.ParseResult,
        decode: ([Int]) -> String,
        stopTokenFilter: StopTokenFilter,
        requestStops: [String],
        globalHitStop: Bool = false,
        countCompletionTokens: Bool,
        generatedCompletionTokens: Int = 0
    ) throws -> ParsedGeneratedOutput {
        guard parsed.status != .malformed, parsed.status != .notApplicable else {
            throw harmonyResponseError(for: parsed.failure)
        }
        let filteredVisible = applyOutputFilters(
            parsed.content ?? "",
            stopTokenFilter: stopTokenFilter,
            requestStops: requestStops
        )
        guard !globalHitStop || filteredVisible.hitStop else {
            throw malformedHarmonyResponseError()
        }
        let toolCalls = filteredVisible.hitStop ? [] : parsed.toolCalls
        let hasToolCalls = !toolCalls.isEmpty
        let visibleContent = hasToolCalls ? "" : filteredVisible.text
        return ParsedGeneratedOutput(
            content: visibleContent,
            toolCalls: toolCalls,
            completionTokens: countCompletionTokens ? harmonyVisibleFinalTokenCount(
                tokenIDs: parsed.finalContentTokenIDs,
                parsedContent: parsed.content ?? "",
                visibleText: visibleContent,
                decode: decode
            ) : 0,
            generatedCompletionTokens: generatedCompletionTokens,
            hitStop: filteredVisible.hitStop,
            isTerminal: parsed.status == .parsed
        )
    }

    private static func harmonyVisibleFinalTokenCount(
        tokenIDs: [Int],
        parsedContent: String,
        visibleText: String,
        decode: ([Int]) -> String
    ) -> Int {
        guard !visibleText.isEmpty, !tokenIDs.isEmpty else { return 0 }
        guard visibleText != parsedContent else { return tokenIDs.count }
        for count in 1 ... tokenIDs.count {
            let prefix = decode(Array(tokenIDs.prefix(count)))
            if prefix == visibleText || prefix.hasPrefix(visibleText) {
                return count
            }
            if !visibleText.hasPrefix(prefix) {
                return max(0, count - 1)
            }
        }
        return tokenIDs.count
    }

    static func malformedHarmonyResponseError() -> APIError {
        APIError(
            status: 502,
            message: "Malformed Harmony tool-call response",
            type: "upstream_provider_error",
            code: "malformed_tool_call_final_json",
            inferenceRan: true,
            settlementRan: true
        )
    }

    static func harmonyResponseError(for failure: HarmonyResponseParser.Failure?) -> APIError {
        switch failure {
        case .perCallByteCapExceeded:
            return APIError(
                status: 502,
                message: "Tool call arguments exceeded 1048576 bytes",
                type: "upstream_provider_error",
                code: "byte_cap_exceeded",
                inferenceRan: true,
                settlementRan: true
            )
        case .responseByteCapExceeded:
            return APIError(
                status: 502,
                message: "Tool call arguments exceeded 2097152 bytes",
                type: "upstream_provider_error",
                code: "response_byte_cap_exceeded",
                inferenceRan: true,
                settlementRan: true
            )
        case .malformed, .none:
            return malformedHarmonyResponseError()
        }
    }

    /// SPEC-018 serial tool turn (`parallel_tool_calls` omitted/false) on a
    /// non-Harmony model with tools: generation stops once the first tool
    /// call is complete and valid.
    static func serialToolStopApplies(_ request: ChatCompletionRequest) -> Bool {
        request.stopsAfterFirstCompleteToolCall
            && !HarmonyResponseParser.isHarmonyModelID(request.model)
            && hasEnabledTools(request.promptSource.tools)

 succeeded in 73940ms:
Another instance of SwiftPM (PID: 5365) is already running using '/Users/augstar/macprovider-1646-rest/phase3-binary/.build', waiting until that process has finished execution...[0/1] Planning build
[1/1] Compiling plugin GenerateManual
[2/2] Compiling plugin GenerateDoccReference
Building for debugging...
[2/6] Write swift-version--58304C5D6DBC2206.txt
Build complete! (11.19s)
Test Suite 'Selected tests' started at 2026-09-25 19:17:33.425.
Test Suite 'phase3-binaryPackageTests.xctest' started at 2026-09-25 19:17:33.427.
Test Suite 'ContinuousBatchSchedulerTests' started at 2026-09-25 19:17:33.427.
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testAC10DrainTimeoutFailsClosedAndLeavesOldWorkOnItsSnapshot]' started.
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testAC10DrainTimeoutFailsClosedAndLeavesOldWorkOnItsSnapshot]' passed (0.037 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testAC11BatchForwardFailureCleansEveryParticipatingRow]' started.
event=batching_admitted action=scheduler_admitted
event=batching_admitted action=scheduler_admitted
event=batching_forward_failed action=fail_closed reason=backendfailure
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testAC11BatchForwardFailureCleansEveryParticipatingRow]' passed (0.003 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testAC17AC24MidDecodeAllocatorExtensionFailureFailsOnlyThatRowAndReleasesBlocks]' started.
event=batching_admitted action=scheduler_admitted
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testAC17AC24MidDecodeAllocatorExtensionFailureFailsOnlyThatRowAndReleasesBlocks]' passed (0.002 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testAC20AC10DrainRejectsQueuedWorkAndDuplicateSubmitReturnsSameTerminal]' started.
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testAC20AC10DrainRejectsQueuedWorkAndDuplicateSubmitReturnsSameTerminal]' passed (0.043 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testAC20DuplicateRequestMismatchIsRejectedAfterTerminalResult]' started.
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testAC20DuplicateRequestMismatchIsRejectedAfterTerminalResult]' passed (0.002 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testAC24AdmissionPoolCapacityRejectsWithoutRunningInference]' started.
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testAC24AdmissionPoolCapacityRejectsWithoutRunningInference]' passed (0.002 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testAC25CarriedSchedulerCodesMapToStatusByShape]' started.
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testAC25CarriedSchedulerCodesMapToStatusByShape]' passed (0.001 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testAC25DeliveryBackpressureIsAPostTokenNonRetryableOutcome]' started.
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testAC25DeliveryBackpressureIsAPostTokenNonRetryableOutcome]' passed (0.000 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testAC25OverdueRequestIsExpiredAtAdmissionEvenIfItsTimerHasNotRun]' started.
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testAC25OverdueRequestIsExpiredAtAdmissionEvenIfItsTimerHasNotRun]' passed (0.339 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testAC25QueuePressureCodesSerializeAsRetryable]' started.
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testAC25QueuePressureCodesSerializeAsRetryable]' passed (0.000 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testAC25QueueWaitDeadlineDoesNotExpireAdmittedRows]' started.
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testAC25QueueWaitDeadlineDoesNotExpireAdmittedRows]' passed (0.002 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testAC25QueueWaitDeadlineRejectsUnadmittedRequestAndLeavesNoState]' started.
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testAC25QueueWaitDeadlineRejectsUnadmittedRequestAndLeavesNoState]' passed (0.164 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testAC25QueueWaitTimeoutReleasesTheReplayClaimSoTheSameIDCanRetry]' started.
event=batching_admitted action=scheduler_admitted
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testAC25QueueWaitTimeoutReleasesTheReplayClaimSoTheSameIDCanRetry]' passed (0.168 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testAC25SchedulerErrorAPIMappingIsExhaustiveAndNonSettling]' started.
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testAC25SchedulerErrorAPIMappingIsExhaustiveAndNonSettling]' passed (0.000 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testAC25StaleQueueWaitTimeoutDuringAdmissionKeepsTheDeadline]' started.
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testAC25StaleQueueWaitTimeoutDuringAdmissionKeepsTheDeadline]' passed (0.935 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testAC25UnmappedSchedulerErrorsRethrowUnchanged]' started.
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testAC25UnmappedSchedulerErrorsRethrowUnchanged]' passed (0.000 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testAC3CancellationIsIdempotentAndLeavesHealthyRowRunning]' started.
event=batching_admitted action=scheduler_admitted
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testAC3CancellationIsIdempotentAndLeavesHealthyRowRunning]' passed (0.011 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testActiveRowsDecodeABoundedWindowBetweenPrefillChunks]' started.
event=batching_admitted action=scheduler_admitted
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testActiveRowsDecodeABoundedWindowBetweenPrefillChunks]' passed (0.022 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testAggregateQueuedTokenBudgetBackpressuresBeforeRetention]' started.
event=batching_admitted action=scheduler_admitted
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testAggregateQueuedTokenBudgetBackpressuresBeforeRetention]' passed (0.047 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testCachedPromptTokensCannotExceedPromptLengthEvenWithRetainedHandoff]' started.
/Users/augstar/macprovider-1646-rest/phase3-binary/Tests/macprovider-cliTests/ContinuousBatchSchedulerTests.swift:4209: -[macprovider_cliTests.ContinuousBatchSchedulerTests testCachedPromptTokensCannotExceedPromptLengthEvenWithRetainedHandoff] : Test skipped - MLX default metallib is unavailable in this test host
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testCachedPromptTokensCannotExceedPromptLengthEvenWithRetainedHandoff]' skipped (0.003 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testCachedPromptTokensRequireRetainedPagedKVHandoff]' started.
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testCachedPromptTokensRequireRetainedPagedKVHandoff]' passed (0.001 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testCancelDuringFailingRetainedInstallReportsCancelled]' started.
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testCancelDuringFailingRetainedInstallReportsCancelled]' passed (0.012 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testCancelDuringHybridRetainedInstallReleasesTheRow]' started.
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testCancelDuringHybridRetainedInstallReleasesTheRow]' passed (0.013 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testCancelDuringRecurrentSnapshotCancelsWithoutMaterializing]' started.
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testCancelDuringRecurrentSnapshotCancelsWithoutMaterializing]' passed (0.012 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testCancelDuringTerminalMaterializeSuppressesTheCache]' started.
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testCancelDuringTerminalMaterializeSuppressesTheCache]' passed (0.013 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testCancellationDuringPrefillWinsForZeroOutputRequest]' started.
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testCancellationDuringPrefillWinsForZeroOutputRequest]' passed (0.011 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testCancelledHangingTokenSinkHardTimeoutReleasesSchedulerState]' started.
event=batching_admitted action=scheduler_admitted
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testCancelledHangingTokenSinkHardTimeoutReleasesSchedulerState]' passed (0.054 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testCancelledHybridRowDeliversNoSerialCacheAndReleasesBlocks]' started.
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testCancelledHybridRowDeliversNoSerialCacheAndReleasesBlocks]' passed (0.012 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testCancellingDrainKeepsSchedulerFailedClosedUntilOldWorkFinishes]' started.
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testCancellingDrainKeepsSchedulerFailedClosedUntilOldWorkFinishes]' passed (0.024 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testCancellingDuplicateWaiterDoesNotCancelSharedRequest]' started.
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testCancellingDuplicateWaiterDoesNotCancelSharedRequest]' passed (0.023 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testCleanupFailureCannotProduceSuccessAndFailsSchedulerClosed]' started.
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testCleanupFailureCannotProduceSuccessAndFailsSchedulerClosed]' passed (0.001 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testCleanupFailureStopsCurrentPumpBeforeAdmittingAnotherRow]' started.
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testCleanupFailureStopsCurrentPumpBeforeAdmittingAnotherRow]' passed (0.022 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testConversationCacheRetainedPagedKVHitLeavesTrimToSchedulerHandoff]' started.
/Users/augstar/macprovider-1646-rest/phase3-binary/Tests/macprovider-cliTests/ContinuousBatchSchedulerTests.swift:4209: -[macprovider_cliTests.ContinuousBatchSchedulerTests testConversationCacheRetainedPagedKVHitLeavesTrimToSchedulerHandoff] : Test skipped - MLX default metallib is unavailable in this test host
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testConversationCacheRetainedPagedKVHitLeavesTrimToSchedulerHandoff]' skipped (0.002 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testConversationKeyWithoutReusableStateBatchesAsFreshRequest]' started.
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testConversationKeyWithoutReusableStateBatchesAsFreshRequest]' passed (0.001 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testCrossConversationRetainedHandoffFailureDiscardsOwner]' started.
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testCrossConversationRetainedHandoffFailureDiscardsOwner]' passed (0.003 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testDeliveredRetainedCacheCanBeReclaimedAfterCallerCancellationRace]' started.
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testDeliveredRetainedCacheCanBeReclaimedAfterCallerCancellationRace]' passed (0.004 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testDescriptorDrivenLocalCapabilityRejectsUnsupportedTuple]' started.
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testDescriptorDrivenLocalCapabilityRejectsUnsupportedTuple]' passed (0.000 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testDrainGraceDeadlineDoesNotAwaitWedgedBackendCancellation]' started.
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testDrainGraceDeadlineDoesNotAwaitWedgedBackendCancellation]' passed (0.033 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testDrainWaitsForPendingTerminalTokenDelivery]' started.
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testDrainWaitsForPendingTerminalTokenDelivery]' passed (0.031 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testDuplicateDuringDeferredTerminalCompletionIsNotStranded]' started.
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testDuplicateDuringDeferredTerminalCompletionIsNotStranded]' passed (0.054 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testDuplicateSuccessfulWaitersHaveExactlyOneSettlementOwner]' started.
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testDuplicateSuccessfulWaitersHaveExactlyOneSettlementOwner]' passed (0.021 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testDurableReplayAuthorityAllowsLocalRetentionToRollWithoutReexecution]' started.
event=batching_admitted action=scheduler_admitted
event=batching_admitted action=scheduler_admitted
event=batching_admitted action=scheduler_admitted
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testDurableReplayAuthorityAllowsLocalRetentionToRollWithoutReexecution]' passed (0.002 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testEveryCarriedSchedulerCodeIsClassified]' started.
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testEveryCarriedSchedulerCodeIsClassified]' passed (0.006 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testFailedHybridRowDeliversNoSerialCacheAndReleasesBlocks]' started.
event=batching_admitted action=scheduler_admitted
event=batching_forward_failed action=fail_closed reason=backendfailure
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testFailedHybridRowDeliversNoSerialCacheAndReleasesBlocks]' passed (0.001 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testForcedDrainPreservesDeliveredDuplicateAsSettlementOwner]' started.
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testForcedDrainPreservesDeliveredDuplicateAsSettlementOwner]' passed (0.091 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testForcedDrainStopsPendingTerminalDeliveryBeforeReturningTimeout]' started.
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testForcedDrainStopsPendingTerminalDeliveryBeforeReturningTimeout]' passed (0.057 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testFullPromptCachedRangeDiscardsSuppliedRetainedOwner]' started.
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testFullPromptCachedRangeDiscardsSuppliedRetainedOwner]' passed (0.001 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testHangingTokenSinkHardTimeoutKeepsLiveTaskCapacityBounded]' started.
event=batching_admitted action=scheduler_admitted
event=batching_admitted action=scheduler_admitted
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testHangingTokenSinkHardTimeoutKeepsLiveTaskCapacityBounded]' passed (0.051 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testHybridCachedTurnResumesFromRetainedCheckpointAndChains]' started.
event=conv_cache action=miss key_hash=67cdb90d reason=cold_start
event=batching_admitted action=scheduler_admitted
event=conv_cache action=cold_unattached key_hash=67cdb90d
event=conv_cache action=hit key_hash=67cdb90d cached_prompt_tokens=38 prompt_tokens=48 lcp=42 trim_by=4 recurrent_checkpoint=38 conv_cache_entries=0 conv_cache_tokens=0
event=batching_admitted action=scheduler_admitted
event=conv_cache action=cold_unattached key_hash=67cdb90d
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testHybridCachedTurnResumesFromRetainedCheckpointAndChains]' passed (0.006 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testHybridRetainedHandoffWithoutCheckpointAtCachedLengthFailsClosed]' started.
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testHybridRetainedHandoffWithoutCheckpointAtCachedLengthFailsClosed]' passed (0.001 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testIdleDecodeUsesLockstepWindowAndAppliesEveryToken]' started.
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testIdleDecodeUsesLockstepWindowAndAppliesEveryToken]' passed (0.002 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testInvalidCachedRangeDiscardsSuppliedRetainedOwner]' started.
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testInvalidCachedRangeDiscardsSuppliedRetainedOwner]' passed (0.001 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testKeyedHybridRowSplitsPrefillAtCheckpointsAndDeliversSerialCache]' started.
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testKeyedHybridRowSplitsPrefillAtCheckpointsAndDeliversSerialCache]' passed (0.001 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testKeylessOrPositionlessHybridRowCapturesNothing]' started.
event=batching_admitted action=scheduler_admitted
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testKeylessOrPositionlessHybridRowCapturesNothing]' passed (0.001 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testLockstepWindowOverflowsDefaultDeliveryBufferWhenSinkCannotDrain]' started.
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testLockstepWindowOverflowsDefaultDeliveryBufferWhenSinkCannotDrain]' passed (0.053 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testLockstepWindowStopSequenceAppliesTokensSequentially]' started.
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testLockstepWindowStopSequenceAppliesTokensSequentially]' passed (0.001 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testLongPrefillIsActuallyChunkedAndDecodeRunsBetweenChunks]' started.
event=batching_admitted action=scheduler_admitted
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testLongPrefillIsActuallyChunkedAndDecodeRunsBetweenChunks]' passed (0.013 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testMalformedBackendTokenFailsOnlyItsRow]' started.
event=batching_admitted action=scheduler_admitted
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testMalformedBackendTokenFailsOnlyItsRow]' passed (0.023 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testMalformedBackendTokenFailsRowWithoutReturningPartialOutput]' started.
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testMalformedBackendTokenFailsRowWithoutReturningPartialOutput]' passed (0.001 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testMissingContiguousBridgeAdmissionFailureDiscardsSuppliedRetainedOwner]' started.
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testMissingContiguousBridgeAdmissionFailureDiscardsSuppliedRetainedOwner]' passed (0.001 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testMoETupleAdmitsWhenPromotionEvidenceIsAvailable]' started.
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testMoETupleAdmitsWhenPromotionEvidenceIsAvailable]' passed (0.000 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testMoETupleRequiresSeparatePromotionEvidenceAtSchedulerAdmission]' started.
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testMoETupleRequiresSeparatePromotionEvidenceAtSchedulerAdmission]' passed (0.000 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testMultiTokenStopPrefixIsHeldBackUntilMatchedOrDisproved]' started.
event=batching_admitted action=scheduler_admitted
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testMultiTokenStopPrefixIsHeldBackUntilMatchedOrDisproved]' passed (0.002 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testNonHybridCachedTurnIsAdmittedOnlyWithFlagAndResumesAtLCP]' started.
event=conv_cache action=miss key_hash=364a29e0 reason=cold_start
event=batching_admitted action=scheduler_admitted
event=conv_cache action=cold_unattached key_hash=364a29e0
event=conv_cache action=hit key_hash=364a29e0 cached_prompt_tokens=37 prompt_tokens=40 lcp=37 trim_by=0 conv_cache_entries=0 conv_cache_tokens=0
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testNonHybridCachedTurnIsAdmittedOnlyWithFlagAndResumesAtLCP]' passed (0.002 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testNonSettlingReplayResultDropsRetainedCacheOwnership]' started.
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testNonSettlingReplayResultDropsRetainedCacheOwnership]' passed (0.001 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testOfferRacingDrainExitIsDeliveredAndTerminalCompletes]' started.
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testOfferRacingDrainExitIsDeliveredAndTerminalCompletes]' passed (0.012 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testOneStepWhilePrefillingKeepsStrictAlternation]' started.
event=batching_admitted action=scheduler_admitted
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testOneStepWhilePrefillingKeepsStrictAlternation]' passed (0.024 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testOversizedQueueWaitIsClampedNotTurnedIntoAnUnboundedWait]' started.
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testOversizedQueueWaitIsClampedNotTurnedIntoAnUnboundedWait]' passed (0.000 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testPartialDecodeLeaseCleanupFailureStillUnwindsEveryPreparedRow]' started.
event=batching_admitted action=scheduler_admitted
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testPartialDecodeLeaseCleanupFailureStillUnwindsEveryPreparedRow]' passed (0.031 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testPositiveCachedTerminalReplayDiscardsSuppliedRetainedOwner]' started.
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testPositiveCachedTerminalReplayDiscardsSuppliedRetainedOwner]' passed (0.011 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testPrefillBackendFailureFailsClosedWithReasonCodedTelemetry]' started.
event=batching_admitted action=scheduler_admitted
event=batching_prefill_failed action=fail_closed reason=continuous_batching_invalid_cache_layout
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testPrefillBackendFailureFailsClosedWithReasonCodedTelemetry]' passed (0.001 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testPrefillLeavesFinalPromptTokenForFirstDecodeKVSlot]' started.
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testPrefillLeavesFinalPromptTokenForFirstDecodeKVSlot]' passed (0.001 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testProductionDeliveryBufferAbsorbsLockstepWhileSinkDrains]' started.
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testProductionDeliveryBufferAbsorbsLockstepWhileSinkDrains]' passed (0.079 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testQueuedCancellationDiscardsSuppliedRetainedOwner]' started.
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testQueuedCancellationDiscardsSuppliedRetainedOwner]' passed (0.022 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testQueuedJoinForcesOneTokenDecodeThenWindowResumes]' started.
event=batching_admitted action=scheduler_admitted
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testQueuedJoinForcesOneTokenDecodeThenWindowResumes]' passed (0.023 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testRequestRetentionAndQueueTokenBudgetsRejectBeforeBackendWork]' started.
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testRequestRetentionAndQueueTokenBudgetsRejectBeforeBackendWork]' passed (0.001 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testRetainedPagedKVHandoffResumesPrefillAtStickyLCP]' started.
/Users/augstar/macprovider-1646-rest/phase3-binary/Tests/macprovider-cliTests/ContinuousBatchSchedulerTests.swift:4209: -[macprovider_cliTests.ContinuousBatchSchedulerTests testRetainedPagedKVHandoffResumesPrefillAtStickyLCP] : Test skipped - MLX default metallib is unavailable in this test host
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testRetainedPagedKVHandoffResumesPrefillAtStickyLCP]' skipped (0.001 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testRetainedReattachExpandsMaxLogicalTokensForContinuation]' started.
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testRetainedReattachExpandsMaxLogicalTokensForContinuation]' passed (0.000 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testRetainedStickyStopSequenceCommitsCanonicalGeneratedTokens]' started.
event=batching_admitted action=scheduler_admitted
event=conv_cache action=miss key_hash=413055e0 reason=cold_start
event=conv_cache action=cold_unattached key_hash=413055e0
event=conv_cache action=hit key_hash=413055e0 cached_prompt_tokens=43 prompt_tokens=44 lcp=43 trim_by=0 conv_cache_entries=0 conv_cache_tokens=0
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testRetainedStickyStopSequenceCommitsCanonicalGeneratedTokens]' passed (0.003 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testRowLocalSamplerFailureDoesNotFailHealthyRows]' started.
event=batching_admitted action=scheduler_admitted
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testRowLocalSamplerFailureDoesNotFailHealthyRows]' passed (0.022 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testSchedulerContractBoundedFCFSQueueRejectsAtBackpressureLimit]' started.
event=batching_admitted action=scheduler_admitted
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testSchedulerContractBoundedFCFSQueueRejectsAtBackpressureLimit]' passed (0.022 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testSchedulerContractMatchesReferenceSerialTokenUsageAndStops]' started.
event=batching_admitted action=scheduler_admitted
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testSchedulerContractMatchesReferenceSerialTokenUsageAndStops]' passed (0.022 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testSchedulerContractMoERowsFeedTheirOwnCurrentTokenAndTelemetryStaysPerRow]' started.
event=batching_admitted action=scheduler_admitted
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testSchedulerContractMoERowsFeedTheirOwnCurrentTokenAndTelemetryStaysPerRow]' passed (0.032 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testSchedulerContractSharedForwardIsolatesUsageStopsAndSamplers]' started.
event=batching_admitted action=scheduler_admitted
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testSchedulerContractSharedForwardIsolatesUsageStopsAndSamplers]' passed (0.023 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testSlowTokenSinkCannotBlockSchedulerAndIsBoundedPerWaiter]' started.
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testSlowTokenSinkCannotBlockSchedulerAndIsBoundedPerWaiter]' passed (0.023 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testStopEarlyEndsDecodingRowAsStopAtNextToken]' started.
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testStopEarlyEndsDecodingRowAsStopAtNextToken]' passed (0.012 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testStopSequenceWinsWhenItAlsoReachesOutputLimit]' started.
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testStopSequenceWinsWhenItAlsoReachesOutputLimit]' passed (0.001 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testTerminalAndDiagnosticRetentionAreBounded]' started.
event=batching_admitted action=scheduler_admitted
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testTerminalAndDiagnosticRetentionAreBounded]' passed (0.002 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testTerminalReplayDiscardsSuppliedRetainedOwner]' started.
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testTerminalReplayDiscardsSuppliedRetainedOwner]' passed (0.011 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testTerminalResultWaitsForAcceptedTokenDelivery]' started.
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testTerminalResultWaitsForAcceptedTokenDelivery]' passed (0.066 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testTerminalRetainFailureReleasesFreshHandleWithoutFailClosing]' started.
event=batching_admitted action=scheduler_admitted
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testTerminalRetainFailureReleasesFreshHandleWithoutFailClosing]' passed (0.002 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testTimedOutTerminalDeliveryDiscardsRetainedPagedKVOwner]' started.
/Users/augstar/macprovider-1646-rest/phase3-binary/Tests/macprovider-cliTests/ContinuousBatchSchedulerTests.swift:4209: -[macprovider_cliTests.ContinuousBatchSchedulerTests testTimedOutTerminalDeliveryDiscardsRetainedPagedKVOwner] : Test skipped - MLX default metallib is unavailable in this test host
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testTimedOutTerminalDeliveryDiscardsRetainedPagedKVOwner]' skipped (0.001 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testTokenSinkStreamsDeltasAndFailureRetainsEmittedAccounting]' started.
event=batching_admitted action=scheduler_admitted
event=batching_forward_failed action=fail_closed reason=backendfailure
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testTokenSinkStreamsDeltasAndFailureRetainsEmittedAccounting]' passed (0.001 seconds).
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testTwoRetainedConversationKeysShareDecodeBatchWithoutCrossAttribution]' started.
event=batching_admitted action=scheduler_admitted
event=batching_admitted action=scheduler_admitted
Test Case '-[macprovider_cliTests.ContinuousBatchSchedulerTests testTwoRetainedConversationKeysShareDecodeBatchWithoutCrossAttribution]' passed (0.023 seconds).
Test Suite 'ContinuousBatchSchedulerTests' passed at 2026-09-25 19:17:36.363.
	 Executed 94 tests, with 4 tests skipped and 0 failures (0 unexpected) in 2.921 (2.936) seconds
Test Suite 'ServingKnobsConfigTests' started at 2026-09-25 19:17:36.363.
Test Case '-[macprovider_cliTests.ServingKnobsConfigTests testRequestStateRepresentableGateOnParsedRequests]' started.
Test Case '-[macprovider_cliTests.ServingKnobsConfigTests testRequestStateRepresentableGateOnParsedRequests]' passed (0.005 seconds).
Test Suite 'ServingKnobsConfigTests' passed at 2026-09-25 19:17:36.369.
	 Executed 1 test, with 0 failures (0 unexpected) in 0.005 (0.006) seconds
Test Suite 'phase3-binaryPackageTests.xctest' passed at 2026-09-25 19:17:36.369.
	 Executed 95 tests, with 4 tests skipped and 0 failures (0 unexpected) in 2.926 (2.942) seconds
Test Suite 'Selected tests' passed at 2026-09-25 19:17:36.369.
	 Executed 95 tests, with 4 tests skipped and 0 failures (0 unexpected) in 2.926 (2.944) seconds
◇ Test run started.
↳ Testing Library Version: 1902
↳ Target Platform: arm64e-apple-macos14.0
✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.

exec
/bin/bash -lc "sed -n '1,280p;280,470p' phase3-binary/Tests/macprovider-cliTests/ContinuousBatchToolStructuredRowTests.swift" in /Users/augstar/macprovider-1646-rest
 succeeded in 0ms:
import XCTest
import MacProviderCore
@testable import macprovider_cli

/// SPEC-038 AC-6c: given identical generated text, a batched row's finalize
/// and stream produce exactly the serial path's `tool_calls`, SSE chunks and
/// structured-validation verdicts. The "serial" side of each test drives the
/// functions the serial `complete`/`stream` paths call, token by token, the
/// way their generate callbacks do.
final class ContinuousBatchToolStructuredRowTests: XCTestCase {
    private static let qwen = "mlx-community/Qwen3-8B-4bit"
    private static let stopTokenFilter = StopTokenFilter(tokens: ["<|im_end|>"])
    private static let weatherTool: [[String: Any]] = [[
        "type": "function",
        "function": [
            "name": "get_weather",
            "parameters": ["type": "object", "properties": ["city": ["type": "string"]]],
        ],
    ]]
    private static let schema: [String: Any] = [
        "type": "json_schema",
        "json_schema": [
            "name": "answer",
            "schema": [
                "type": "object",
                "properties": ["a": ["type": "integer"]],
                "required": ["a"],
                "additionalProperties": false,
            ],
        ],
    ]

    /// Two complete tool calls, one token per piece, then trailing text.
    private static let twoCallPieces: [String] = [
        "<tool_call>", "\n{\"name\": ", "\"get_weather\"", ", \"arguments\": ",
        "{\"city\": ", "\"Paris\"}", "}", "\n</tool_call>",
        "\n<tool_call>", "\n{\"name\": \"get_weather\", ", "\"arguments\": {\"city\": \"Rome\"}}",
        "\n</tool_call>", " trailing",
    ]

    // MARK: - fixtures

    private struct Vocab {
        let pieces: [String]
        var ids: [Int] { Array(pieces.indices) }
        func decode(_ ids: [Int]) -> String { ids.map { pieces[$0] }.joined() }
    }

    private func request(_ body: [String: Any]) throws -> ChatCompletionRequest {
        var dict = body
        dict["model"] = dict["model"] ?? Self.qwen
        dict["messages"] = dict["messages"] ?? [["role": "user", "content": "hi"]]
        return try ChatCompletionRequest.parse(data: try JSONSerialization.data(withJSONObject: dict))
    }

    private func schedulerResult(
        _ ids: [Int],
        status: ContinuousBatchSchedulerTerminalStatus = .stop
    ) -> ContinuousBatchSchedulerResult {
        ContinuousBatchSchedulerResult(
            requestID: "r",
            conversationKey: "",
            generatedTokens: ids,
            outputTokens: ids,
            promptTokens: 3,
            completionTokens: ids.count,
            emittedTokens: ids.count,
            cachedPromptTokens: 0,
            terminalStatus: status,
            errorCode: nil,
            snapshot: nil,
            settlementDisposition: .eligibleOwner,
            retainedCache: nil
        )
    }

    private func finalizeBatched(
        _ request: ChatCompletionRequest,
        vocab: Vocab,
        ids: [Int],
        serialStopTokenCount: Int?,
        status: ContinuousBatchSchedulerTerminalStatus = .stop
    ) throws -> ModelRuntime.ContinuousBatchFinalizedRow {
        try ModelRuntime.finalizeContinuousBatchRow(
            request: request,
            result: schedulerResult(ids, status: status),
            modelStopTokenIDs: [],
            serialStopTokenCount: serialStopTokenCount,
            promptTokenIDs: [1, 2, 3],
            decode: vocab.decode,
            stopTokenFilter: Self.stopTokenFilter,
            generationMilliseconds: 0,
            modelHash: nil
        )
    }

    /// The serial non-streaming path: its generate callback stops a serial
    /// tool turn at the first complete valid tool call, then it parses and
    /// validates the text of the tokens it generated.
    private func serialComplete(
        _ request: ChatCompletionRequest,
        vocab: Vocab
    ) throws -> (completion: CompletionResult, tokenCount: Int) {
        var generated: [Int] = []
        var observer = NativeToolCallStreamEmitter(
            modelID: request.model,
            allowedFunctionNames: ModelRuntime.toolFunctionNames(from: request.promptSource.tools)
        )
        for id in vocab.ids {
            generated.append(id)
            if ModelRuntime.serialToolStopApplies(request),
               ModelRuntime.observeSerialToolStop(
                   &observer,
                   decoded: vocab.decode(generated),
                   stopTokenFilter: Self.stopTokenFilter,
                   requestStops: request.stop
               ) {
                break
            }
        }
        let filtered = ModelRuntime.applyOutputFilters(
            vocab.decode(generated),
            stopTokenFilter: Self.stopTokenFilter,
            requestStops: request.stop
        )
        let parsed = try ModelRuntime.parseGeneratedOutput(
            filteredText: filtered.text,
            generatedTokenIDs: generated,
            decode: vocab.decode,
            request: request,
            mode: .complete(finishReason: filtered.hitStop ? "request_stop" : "stop"),
            defaultCompletionTokens: generated.count,
            stopTokenFilter: Self.stopTokenFilter,
            requestStops: request.stop,
            globalHitStop: filtered.hitStop
        )
        let completion = try ModelRuntime.validateStructuredCompletion(CompletionResult(
            content: parsed.content,
            finishReason: parsed.toolCalls.isEmpty ? "stop" : "tool_calls",
            promptTokens: 3,
            completionTokens: parsed.completionTokens,
            toolCalls: parsed.toolCalls.isEmpty ? nil : parsed.toolCalls,
            settlementDisposition: .eligibleOwner
        ), request: request)
        return (completion, generated.count)
    }

    /// The serial streaming path over the same tokens: one emitter step per
    /// token until it would stop generating, then its finish and the
    /// structured verdict on buyer-visible content.
    private func serialStream(
        _ request: ChatCompletionRequest,
        vocab: Vocab
    ) -> (chunks: [String], result: Result<CompletionResult, APIError>) {
        let accumulator = StructuredStreamingContentAccumulator(
            enabled: ModelRuntime.requiresStructuredValidation(request.responseFormat)
        )
        let idle = StructuredStreamingIdleState(enabled: false)
        let sink = ChunkSink()
        var emitter = SerialStreamingTextEmitter(request: request)
        var generated: [Int] = []
        loop: for id in vocab.ids {
            generated.append(id)
            let candidate = ModelRuntime.streamingSafePrefix(
                vocab.decode(generated),
                stopTokenFilter: Self.stopTokenFilter,
                requestStops: request.stop
            )
            switch emitter.step(
                candidate: candidate,
                structuredAccumulator: accumulator,
                idleState: idle,
                onChunk: sink.append
            ) {
            case .more:
                continue
            case .requestStop, .toolCallComplete, .structuredError:
                break loop
            }
        }
        let final = ModelRuntime.applyOutputFilters(
            vocab.decode(generated),
            stopTokenFilter: Self.stopTokenFilter,
            requestStops: request.stop
        )
        do {
            let parsed = try ModelRuntime.parseGeneratedOutput(
                filteredText: final.text,
                generatedTokenIDs: generated,
                decode: vocab.decode,
                request: request,
                mode: .complete(finishReason: "stop"),
                defaultCompletionTokens: generated.count,
                stopTokenFilter: Self.stopTokenFilter,
                requestStops: request.stop,
                globalHitStop: final.hitStop
            )
            try emitter.finish(
                finalText: final.text,
                parsed: parsed,
                structuredAccumulator: accumulator,
                idleState: idle,
                onChunk: sink.append
            )
            let completion = try ModelRuntime.validateStructuredStreamingCompletion(
                CompletionResult(
                    content: parsed.content,
                    finishReason: parsed.toolCalls.isEmpty ? "stop" : "tool_calls",
                    promptTokens: 3,
                    completionTokens: parsed.completionTokens,
                    toolCalls: parsed.toolCalls.isEmpty ? nil : parsed.toolCalls,
                    settlementDisposition: .eligibleOwner
                ),
                request: request,
                buyerVisibleContent: accumulator.content
            )
            return (sink.normalized(), .success(completion))
        } catch {
            return (sink.normalized(), .failure(error as! APIError))
        }
    }

    /// The batched stream: every delivered token goes through the row's
    /// stream state (tokens past the serial stop point included, as a row
    /// may decode on before `stopEarly` lands), then the batched finalize.
    private func batchedStream(
        _ request: ChatCompletionRequest,
        vocab: Vocab,
        deliveredIDs: [Int]? = nil
    ) -> (chunks: [String], result: Result<CompletionResult, APIError>, stopRequests: Int, finalized: ModelRuntime.ContinuousBatchFinalizedRow?) {
        let accumulator = StructuredStreamingContentAccumulator(
            enabled: ModelRuntime.requiresStructuredValidation(request.responseFormat)
        )
        let idle = StructuredStreamingIdleState(enabled: false)
        let sink = ChunkSink()
        let state = ModelRuntime.AttachedPagedKVStreamState(request: request)
        let ids = deliveredIDs ?? vocab.ids
        var stopRequests = 0
        for id in ids where state.step(
            eventTokens: [id],
            decode: vocab.decode,
            stopTokenFilter: Self.stopTokenFilter,
            requestStops: request.stop,
            structuredAccumulator: accumulator,
            idleState: idle,
            onChunk: sink.append
        ) {
            stopRequests += 1
        }
        if let error = state.error() {
            return (sink.normalized(), .failure(error), stopRequests, nil)
        }
        do {
            let finalized = try finalizeBatched(
                request,
                vocab: vocab,
                ids: ids,
                serialStopTokenCount: state.serialStopTokenCount
            )
            let completion = try ModelRuntime.finishContinuousBatchStream(
                finalized,
                state: state,
                request: request,
                structuredAccumulator: accumulator,
                idleState: idle,
                onChunk: sink.append
            )
            return (sink.normalized(), .success(completion), stopRequests, finalized)
        } catch {
            return (sink.normalized(), .failure(error as! APIError), stopRequests, nil)
        }
    }

    private func calls(_ toolCalls: [macprovider_cli.ToolCall]?) -> [String] {
        (toolCalls ?? []).map { "\($0.functionName) \($0.arguments)" }
    }

    // MARK: - non-streaming tool calls

    func testSerialToolTurnTruncatesToSerialStopAndMatchesSerialToolCalls() throws {
    func testSerialToolTurnTruncatesToSerialStopAndMatchesSerialToolCalls() throws {
        let request = try request(["tools": Self.weatherTool])
        let vocab = Vocab(pieces: Self.twoCallPieces)
        let serial = try serialComplete(request, vocab: vocab)
        XCTAssertLessThan(serial.tokenCount, vocab.pieces.count, "serial stops at the first complete call")

        // The batched row's sink runs the serial stop test on each token.
        let stop = ModelRuntime.ContinuousBatchSerialToolStopState(request: request)
        var stopRequests = 0
        for id in vocab.ids where stop.observe(
            eventTokens: [id],
            decode: vocab.decode,
            stopTokenFilter: Self.stopTokenFilter,
            requestStops: request.stop
        ) {
            stopRequests += 1
        }
        XCTAssertEqual(stopRequests, 1)
        XCTAssertEqual(stop.stopTokenCount, serial.tokenCount)

        // The row decoded every token before stopping; the finalize truncates.
        let batched = try finalizeBatched(
            request,
            vocab: vocab,
            ids: vocab.ids,
            serialStopTokenCount: stop.stopTokenCount,
            status: .length
        )
        let completion = try ModelRuntime.validateStructuredCompletion(batched.completion, request: request)
        XCTAssertEqual(calls(completion.toolCalls), calls(serial.completion.toolCalls))
        XCTAssertEqual(calls(completion.toolCalls), [#"get_weather {"city":"Paris"}"#])
        XCTAssertEqual(completion.finishReason, "tool_calls")
        XCTAssertEqual(completion.content, serial.completion.content)
        XCTAssertEqual(completion.completionTokens, serial.completion.completionTokens)
        XCTAssertEqual(completion.completionTokens, serial.tokenCount)
        XCTAssertEqual(batched.generatedTokens, Array(vocab.ids.prefix(serial.tokenCount)))
        XCTAssertTrue(batched.truncatedAtSerialStop, "a row past the stop point must not commit its cache")
    }

    func testParallelToolTurnKeepsEveryCallLikeSerial() throws {
        let request = try request(["tools": Self.weatherTool, "parallel_tool_calls": true])
        let vocab = Vocab(pieces: Self.twoCallPieces)
        let serial = try serialComplete(request, vocab: vocab)
        XCTAssertEqual(serial.tokenCount, vocab.pieces.count)
        XCTAssertFalse(ModelRuntime.serialToolStopApplies(request))

        let batched = try finalizeBatched(request, vocab: vocab, ids: vocab.ids, serialStopTokenCount: nil)
        let completion = try ModelRuntime.validateStructuredCompletion(batched.completion, request: request)
        XCTAssertEqual(calls(completion.toolCalls), calls(serial.completion.toolCalls))
        XCTAssertEqual(completion.toolCalls?.count, 2)
        XCTAssertEqual(completion.finishReason, "tool_calls")
        XCTAssertFalse(batched.truncatedAtSerialStop)
    }

    func testResponseByteCapMatchesSerialNonStreamingGuard() throws {
        let request = try request(["tools": Self.weatherTool])
        let vocab = Vocab(pieces: [String(repeating: "a", count: ToolCallParser.SPEC018_ARGUMENTS_PER_RESPONSE_BYTE_CAP + 1)])
        XCTAssertThrowsError(try finalizeBatched(request, vocab: vocab, ids: vocab.ids, serialStopTokenCount: nil)) { error in
            let apiError = error as? APIError
            XCTAssertEqual(apiError?.status, 502)
            XCTAssertEqual(apiError?.code, "response_byte_cap_exceeded")
            XCTAssertEqual(apiError?.message, "Model response exceeded 2097152 bytes")
        }
        let atCap = Vocab(pieces: [String(repeating: "a", count: ToolCallParser.SPEC018_ARGUMENTS_PER_RESPONSE_BYTE_CAP)])
        XCTAssertNoThrow(try finalizeBatched(request, vocab: atCap, ids: atCap.ids, serialStopTokenCount: nil))
    }

    // MARK: - non-streaming structured output

    func testStructuredVerdictsMatchSerialNonStreaming() throws {
        let request = try request(["response_format": Self.schema])
        let cases: [(pieces: [String], expectedCode: String?)] = [
            (["{\"a\"", ": 1}"], nil),
            (["{\"a\"", ": 1"], "malformed_json_response"),
            (["{\"a\"", ": \"x\"}"], "json_schema_validation_failed"),
        ]
        for testCase in cases {
            let vocab = Vocab(pieces: testCase.pieces)
            let serialCode = Self.apiCode { _ = try self.serialComplete(request, vocab: vocab) }
            let batchedCode = Self.apiCode {
                let row = try self.finalizeBatched(request, vocab: vocab, ids: vocab.ids, serialStopTokenCount: nil)
                _ = try ModelRuntime.validateStructuredCompletion(row.completion, request: request)
            }
            XCTAssertEqual(batchedCode, serialCode, "\(testCase.pieces)")
            XCTAssertEqual(serialCode, testCase.expectedCode, "\(testCase.pieces)")
        }
    }

    // MARK: - streaming

    func testStreamingToolTurnEmitsSerialToolDeltasAndStopsAtSerialToken() throws {
        let request = try request(["tools": Self.weatherTool])
        let vocab = Vocab(pieces: ["Checking. "] + Self.twoCallPieces)
        let serial = serialStream(request, vocab: vocab)
        let batched = batchedStream(request, vocab: vocab)

        XCTAssertEqual(batched.chunks, serial.chunks)
        XCTAssertTrue(batched.chunks.contains("tool:get_weather:"), "\(batched.chunks)")
        XCTAssertFalse(batched.chunks.contains { $0.hasPrefix("content:") && $0.contains("<tool_call>") })
        XCTAssertEqual(batched.chunks.first, "content:Checking. ")
        XCTAssertEqual(batched.stopRequests, 1)
        let serialCompletion = try serial.result.get()
        let batchedCompletion = try batched.result.get()
        XCTAssertEqual(calls(batchedCompletion.toolCalls), calls(serialCompletion.toolCalls))
        XCTAssertEqual(batchedCompletion.finishReason, "tool_calls")
        XCTAssertEqual(batchedCompletion.completionTokens, serialCompletion.completionTokens)
        XCTAssertEqual(batched.finalized?.truncatedAtSerialStop, true)
    }

    func testStreamingOversizedToolArgumentsStreamNothingLikeSerial() throws {
        let request = try request(["tools": Self.weatherTool])
        let big = String(repeating: "x", count: ToolCallParser.SPEC018_ARGUMENTS_PER_CALL_BYTE_CAP + 1)
        let vocab = Vocab(pieces: [
            "<tool_call>\n{\"name\": \"get_weather\", \"arguments\": {\"city\": \"", big, "\"}}\n</tool_call>",
        ])
        let serial = serialStream(request, vocab: vocab)
        let batched = batchedStream(request, vocab: vocab)
        XCTAssertEqual(batched.chunks, serial.chunks)
        // The serial emitter opens the call on the first piece and then
        // closes on the over-cap arguments: nothing past the cap, and no
        // tool markup as assistant content.
        XCTAssertEqual(batched.chunks, ["tool:get_weather:", "args:0:{\"city\": \""])
        XCTAssertFalse(batched.chunks.contains { $0.hasPrefix("content:") })
        XCTAssertNil(try batched.result.get().toolCalls)
        XCTAssertEqual(try batched.result.get().finishReason, try serial.result.get().finishReason)
    }

    func testStreamingInvalidJSONUnderJSONSchemaMatchesSerialChunksAndError() throws {
        let request = try request(["response_format": Self.schema])
        // The trailing "<" is held back as a possible stop-token prefix and
        // only sent by the stream's end, before the structured verdict.
        let vocab = Vocab(pieces: ["{\"a\"", ": 1}", "<"])
        let serial = serialStream(request, vocab: vocab)
        let batched = batchedStream(request, vocab: vocab)
        XCTAssertEqual(batched.chunks, serial.chunks)
        XCTAssertEqual(batched.chunks, ["content:{\"a\"", "content:: 1}", "content:<"])
        guard case .failure(let serialError) = serial.result,
              case .failure(let batchedError) = batched.result else {
            return XCTFail("both paths must reject invalid JSON: \(serial.result) \(batched.result)")
        }
        XCTAssertEqual(batchedError.code, serialError.code)
        XCTAssertEqual(batchedError.status, serialError.status)
    }

    func testStreamingSchemaMismatchAndValidJSONMatchSerial() throws {
        let request = try request(["response_format": Self.schema])
        for pieces in [["{\"a\"", ": \"x\"}"], ["{\"a\"", ": 1}"]] {
            let vocab = Vocab(pieces: pieces)
            let serial = serialStream(request, vocab: vocab)
            let batched = batchedStream(request, vocab: vocab)
            XCTAssertEqual(batched.chunks, serial.chunks)
            switch (serial.result, batched.result) {
            case (.success(let s), .success(let b)):
                XCTAssertEqual(b.content, s.content)
            case (.failure(let s), .failure(let b)):
                XCTAssertEqual(b.code, s.code)
            default:
                XCTFail("verdicts differ: \(serial.result) \(batched.result)")
            }
        }
    }

    func testStreamingStructuredByteCapStopsRowWithSerialError() throws {
        let request = try request(["response_format": ["type": "json_object"]])
        let over = String(repeating: "1", count: ModelRuntime.structuredStreamingValidationBufferByteCap)
        let vocab = Vocab(pieces: ["[", over, "]"])
        let serial = serialStream(request, vocab: vocab)
        let batched = batchedStream(request, vocab: vocab)
        XCTAssertEqual(batched.chunks, serial.chunks)
        XCTAssertEqual(batched.stopRequests, 1)
        guard case .failure(let serialError) = serial.result,
              case .failure(let batchedError) = batched.result else {
            return XCTFail("both paths must fail the structured stream cap")
        }
        XCTAssertEqual(batchedError.code, "response_byte_cap_exceeded")
        XCTAssertEqual(batchedError.code, serialError.code)
    }

    // MARK: - helpers

    private static func apiCode(_ body: () throws -> Void) -> String? {
        do {
            try body()
            return nil
        } catch let error as APIError {
            return error.code
        } catch {
            return "non_api_error:\(error)"
        }
    }
}

exec
/bin/bash -lc "git diff --no-ext-diff --unified=60 origin/main...52fcb7e4 -- phase3-binary/Sources/macprovider-cli/ModelRuntime.swift | sed -n '900,1400p'" in /Users/augstar/macprovider-1646-rest
 succeeded in 0ms:
                 }
             } else if let lease {
                 await conversationCache.abort(lease)
             }
             return completion
         } catch {
             if let retainedCache = result.retainedCache {
                 await scheduler.cancelRetainedCacheDelivery(
                     retainedCache,
                     conversationKey: result.conversationKey
                 )
             }
             if let lease {
                 await conversationCache.abort(lease)
             }
             throw error
         }
     }
 
     nonisolated static func schedulerRequestID(for request: ChatCompletionRequest) -> String? {
         nonEmpty(request.requestID)
     }
 
     private func attachedContinuousBatchStreamingCompletion(
         request: ChatCompletionRequest,
         snapshot: RuntimeSnapshot,
         capability: ContinuousBatchingCapability,
         completionStartedAt: Date,
         shouldCancel: @escaping @Sendable () -> Bool,
         drainCancelled: DrainCancelToken,
         structuredAccumulator: StructuredStreamingContentAccumulator,
         idleState: StructuredStreamingIdleState,
+        idleCancellation: DrainCancelToken,
         onChunk: @escaping @Sendable (StreamChunk) -> Void
     ) async throws -> CompletionResult? {
         guard capability.isRequested,
               capability.unsupportedReason == nil,
               !capability.shouldUseSerialPath,
               case .attached = pagedKVAttachDecision
         else {
             return nil
         }
         guard let scheduler = continuousBatchScheduler else {
             throw Self.attachedPagedKVUnavailableError(code: "continuous_batching_scheduler_unavailable")
         }
         guard let schedulerRequestID = Self.schedulerRequestID(for: request) else {
             throw Self.attachedPagedKVUnavailableError(code: ContinuousBatchingUnsupportedReason.stableRequestIDUnavailable.apiCode)
         }
         guard let container = snapshot.container else {
             throw APIError(status: 503, message: "Model not loaded", type: "server_error", code: "model_not_loaded")
         }
 
         let maxContextTokens = maxContextTokens
         let stopTokenFilter = stopTokenFilter
         let templateSupportsThinkingToggle = snapshot.templateSupportsThinkingToggle
         let requestStops = request.stop
         let (prepared, detokenizer) = try await container.perform { context -> (ContinuousBatchPreparedRequest, StreamingDetokenizer) in
             try drainCancelled.check()
             try Task.checkCancellation()
             let input = try Self.userInput(
                 for: request,
                 templateSupportsThinkingToggle: templateSupportsThinkingToggle
             )
             let lmInput = try await context.processor.prepare(input: input)
             let promptTokens = lmInput.text.tokens.asArray(Int32.self).map(Int.init)
             try Self.validatePromptTokenCount(promptTokens.count, maxContextTokens: maxContextTokens)
             let stopTokenSequences = Self.continuousBatchStopTokenSequences(
                 requestStops: requestStops,
                 context: context
             )
             let tokenizer = context.tokenizer
             // Only keyed requests can hold or reuse conversation state.
             let hybrid = Self.nonEmpty(request.conversationKey) != nil
                 && ConversationCacheLayers.hasRecurrentLayers(context.model.newCache(parameters: nil))
             return (
                 ContinuousBatchPreparedRequest(
                     promptTokens: promptTokens,
                     stopTokenSequences: stopTokenSequences,
                     modelStopTokenIDs: Self.generationStopTokenIDs(
                     for: Self.harmonyTerminalPreservingContext(from: context, modelID: request.model)
                 ),
                     recurrentCheckpointPositions: Self.continuousBatchRecurrentCheckpointPositions(
                         promptTokens: promptTokens,
                         conversationKey: request.conversationKey,
                         hybrid: hybrid,
                         context: context
                     ),
                     modelHasRecurrentLayers: hybrid
                 ),
                 StreamingDetokenizer { tokenizer.decode(tokenIds: $0) }
             )
         }
 
         try drainCancelled.check()
         try Task.checkCancellation()
         if shouldCancel() { throw CancellationError() }
-        let streamState = AttachedPagedKVStreamState()
+        let streamState = AttachedPagedKVStreamState(request: request)
         let maxOutputTokens = request.maxTokens ?? max(1, maxContextTokens - prepared.promptTokens.count)
         let preparedPromptTokenIDs = prepared.promptTokens.map(Int32.init)
         let batchKVBits = Self.effectiveKVBits(
             configured: kvBitsOverride,
             conversationKey: request.conversationKey
         )
         let lease = await conversationCache.begin(
             conversationKey: request.conversationKey,
             incomingTokens: preparedPromptTokenIDs,
             modelID: request.model,
             kvBits: batchKVBits,
             allowRetainedPagedKVHandoff: true
         )
         if try await serialRouteCanaryCachedHitMissingRetainedHandoff(
             lease,
             capability: capability,
             modelHasRecurrentLayers: prepared.modelHasRecurrentLayers
         ) {
             return nil
         }
         let result: ContinuousBatchSchedulerResult
         do {
-            result = try await Self.withDrainAndClientCancellation(drainCancelled, shouldCancel: shouldCancel) {
+            // The SPEC-019 structured idle timeout ends the row as it ends the
+            // serial generate loop.
+            result = try await Self.withDrainAndClientCancellation(
+                drainCancelled,
+                shouldCancel: { shouldCancel() || idleCancellation.isFired }
+            ) {
                 try await scheduler.submit(ContinuousBatchSchedulerRequest(
                     id: schedulerRequestID,
                     conversationKey: request.conversationKey ?? "",
                     promptTokens: prepared.promptTokens,
                     maxOutputTokens: maxOutputTokens,
                     stopTokenSequences: prepared.stopTokenSequences,
                     samplerSeed: ContinuousBatchRowSampler.requestSeed(requestID: schedulerRequestID),
                     temperature: request.temperature,
                     topP: request.topP,
                     presencePenalty: request.presencePenalty,
                     frequencyPenalty: request.frequencyPenalty,
                     cachedPromptTokens: lease?.cachedPromptTokens ?? 0,
                     retainedPagedKVSequence: lease?.reusableCache?.retainedPagedKVSequence,
                     recurrentCheckpointPositions: prepared.recurrentCheckpointPositions,
                     retainedRecurrentCheckpoints: Self.retainedRecurrentCheckpoints(for: lease)
                 ), tokenSink: { event in
-                    let eventTokens = event.replayTokens ?? [event.token]
-                    guard !eventTokens.isEmpty else { return }
-                    let allTokens = streamState.appendTokens(eventTokens)
-                    let candidate = Self.streamingSafePrefix(
-                        detokenizer.decode(allTokens),
+                    guard !idleCancellation.isFired else { return }
+                    if streamState.step(
+                        eventTokens: event.replayTokens ?? [event.token],
+                        decode: detokenizer.decode,
                         stopTokenFilter: stopTokenFilter,
-                        requestStops: requestStops
-                    )
-                    let delta = streamState.delta(to: candidate.text)
-                    guard !delta.isEmpty else { return }
-                    if let error = structuredAccumulator.append(delta) {
-                        streamState.record(error)
-                        return
+                        requestStops: requestStops,
+                        structuredAccumulator: structuredAccumulator,
+                        idleState: idleState,
+                        onChunk: onChunk
+                    ) {
+                        Task { await scheduler.stopEarly(requestID: schedulerRequestID) }
                     }
-                    idleState.noteContent()
-                    onChunk(.content(delta))
                 })
             }
         } catch {
             if let lease {
                 await conversationCache.abort(lease)
             }
             // SPEC-038 AC-25: one shared scheduler-error map, so the
             // streaming and non-streaming paths cannot drift.
             throw (error as? ContinuousBatchSchedulerError)?.asAPIError() ?? error
         }
         do {
             if let error = streamState.error() {
                 throw error
             }
             try drainCancelled.check()
             try Task.checkCancellation()
             if shouldCancel() { throw CancellationError() }
             guard result.terminalStatus == .stop || result.terminalStatus == .length else {
                 throw Self.terminalFailureError(code: result.errorCode ?? "continuous_batching_request_failed")
             }
             let completionEndedAt = Date()
-            // The serial path discards the model's end-of-generation token
-            // before counting it; bill and cache the batched row the same way.
-            // Harmony `<|return|>`/`<|call|>` are excluded from this set, as
-            // they are from the serial stop set: the parser reads and counts them.
-            let generatedTokens = Self.droppingTrailingModelStop(
-                result.generatedTokens,
-                terminalStatus: result.terminalStatus,
-                modelStopTokenIDs: prepared.modelStopTokenIDs
-            )
-            let completionTokenCount = result.completionTokens
-                - (result.generatedTokens.count - generatedTokens.count)
-            let completion = try await container.perform { context in
-                let decoded = context.tokenizer.decode(tokenIds: result.outputTokens)
-                guard decoded.utf8.count <= ToolCallParser.SPEC018_ARGUMENTS_PER_RESPONSE_BYTE_CAP else {
-                    throw APIError(
-                        status: 502,
-                        message: "Model response exceeded 2097152 bytes",
-                        type: "upstream_provider_error",
-                        code: "response_byte_cap_exceeded",
-                        inferenceRan: true,
-                        settlementRan: true
-                    )
-                }
-                let filtered = Self.applyOutputFilters(
-                    decoded,
-                    stopTokenFilter: stopTokenFilter,
-                    requestStops: requestStops
-                )
-                let parserFinishReason = result.terminalStatus == .length && !filtered.hitStop
-                    ? "length"
-                    : (filtered.hitStop ? "request_stop" : "stop")
-                let parsed = try Self.parseGeneratedOutput(
-                    filteredText: filtered.text,
-                    generatedTokenIDs: generatedTokens,
-                    decode: { context.tokenizer.decode(tokenIds: $0) },
+            let finalized = try await container.perform { context in
+                try Self.finalizeContinuousBatchRow(
                     request: request,
-                    mode: .complete(finishReason: parserFinishReason),
-                    defaultCompletionTokens: completionTokenCount,
+                    result: result,
+                    modelStopTokenIDs: prepared.modelStopTokenIDs,
+                    serialStopTokenCount: streamState.serialStopTokenCount,
+                    promptTokenIDs: preparedPromptTokenIDs,
+                    decode: { context.tokenizer.decode(tokenIds: $0) },
                     stopTokenFilter: stopTokenFilter,
-                    requestStops: requestStops,
-                    globalHitStop: filtered.hitStop
-                )
-                let finishReason: String
-                if !parsed.toolCalls.isEmpty {
-                    finishReason = "tool_calls"
-                } else if result.terminalStatus == .length, !filtered.hitStop, !parsed.hitStop {
-                    finishReason = "length"
-                } else {
-                    finishReason = "stop"
-                }
-                let kvCacheBytesReused = Self.cachedPromptUTF8Bytes(
-                    promptTokenIds: preparedPromptTokenIDs,
-                    cachedPromptTokens: result.cachedPromptTokens,
-                    decode: { context.tokenizer.decode(tokenIds: $0) }
-                )
-                return try Self.validateStructuredCompletion(CompletionResult(
-                    content: parsed.content,
-                    finishReason: finishReason,
-                    promptTokens: prepared.promptTokens.count,
-                    cachedPromptTokens: result.cachedPromptTokens,
-                    kvCacheBytesReused: kvCacheBytesReused,
-                    completionTokens: parsed.completionTokens,
-                    generatedCompletionTokens: parsed.generatedCompletionTokens,
-                    ttftMilliseconds: nil,
                     generationMilliseconds: Int64(completionEndedAt.timeIntervalSince(completionStartedAt) * 1000),
-                    toolCalls: parsed.toolCalls.isEmpty ? nil : parsed.toolCalls,
-                    modelHashObserved: Self.validObservedModelHash(snapshot.modelHash),
-                    settlementDisposition: result.settlementDisposition
-                ), request: request)
+                    modelHash: snapshot.modelHash
+                )
             }
             // #1690 E2E-F13: the stream held back an incomplete UTF-8 tail
-            // and any stop-string prefix; send the remainder as the final
-            // text renders it, so the buyer's bytes equal the receipt's.
-            if completion.toolCalls?.isEmpty != false {
-                let remainder = streamState.delta(to: completion.content)
-                if !remainder.isEmpty {
-                    if let error = structuredAccumulator.append(remainder) {
-                        throw error
-                    }
-                    idleState.noteContent()
-                    onChunk(.content(remainder))
-                }
-            }
-            let validated = try Self.validateStructuredStreamingCompletion(
-                completion,
+            // and any stop-string prefix; the serial stream's end sends the
+            // remainder as the final text renders it, so the buyer's bytes
+            // equal the receipt's.
+            let validated = try Self.finishContinuousBatchStream(
+                finalized,
+                state: streamState,
                 request: request,
-                buyerVisibleContent: structuredAccumulator.content
+                structuredAccumulator: structuredAccumulator,
+                idleState: idleState,
+                onChunk: onChunk
             )
-            if let lease, let retainedCache = result.retainedCache,
+            let generatedTokens = finalized.generatedTokens
+            if !finalized.truncatedAtSerialStop,
+               let lease, let retainedCache = result.retainedCache,
                Self.retainedCacheIsCommittable(
                    retainedCache,
                    modelHasRecurrentLayers: prepared.modelHasRecurrentLayers
                ) {
                 await conversationCache.commit(
                     lease,
                     cache: ConversationCacheLayers(
                         retainedCache.layers,
                         retainedPagedKVSequence: retainedCache.retainedSequence,
                         discardRetainedPagedKVSequence: { retained, key in
                             await scheduler.discardRetainedCache(retained, conversationKey: key)
                         },
                         recurrentCheckpoints: retainedCache.recurrentCheckpoints
                     ),
                     fullTokens: preparedPromptTokenIDs + generatedTokens.map(Int32.init)
                 )
                 await scheduler.acknowledgeRetainedCacheDelivery(retainedCache)
-            } else if let lease, let serialCache = result.serialConversationCache,
+            } else if !finalized.truncatedAtSerialStop,
+                      let lease, let serialCache = result.serialConversationCache,
                       let fullTokens = Self.serialConversationCacheCommitTokens(
                           canonicalTokens: preparedPromptTokenIDs + generatedTokens.map(Int32.init),
                           coveredTokenCount: serialCache.tokenCount
                       ) {
                 // SPEC-038 FR-CB4 hybrid first turn: the next keyed turn serial-
                 // routes (AC-26) and reuses this entry from its checkpoints.
                 await conversationCache.commit(
                     lease,
                     cache: ConversationCacheLayers(
                         serialCache.layers,
                         recurrentCheckpoints: serialCache.recurrentCheckpoints
                     ),
                     fullTokens: fullTokens
                 )
             } else if let retainedCache = result.retainedCache {
                 await scheduler.cancelRetainedCacheDelivery(
                     retainedCache,
                     conversationKey: result.conversationKey
                 )
                 if let lease {
                     await conversationCache.abort(lease)
                 }
             } else if let lease {
                 await conversationCache.abort(lease)
             }
             return validated
         } catch {
             if let retainedCache = result.retainedCache {
                 await scheduler.cancelRetainedCacheDelivery(
                     retainedCache,
                     conversationKey: result.conversationKey
                 )
             }
             if let lease {
                 await conversationCache.abort(lease)
             }
             throw error
         }
     }
 
     /// SPEC-038 AC-25: a non-terminal scheduler *result*, as distinct from a
     /// thrown scheduler error. Most carried codes are pre-inference, so they
     /// take the `inferenceRan: false` shape. The one that is not is
     /// post-token delivery backpressure — the row was decoding and the buyer
     /// may already hold partial output — so it reuses the single
     /// `.deliveryBackpressure` mapping rather than a second, divergent copy.
     private nonisolated static func terminalFailureError(code: String) -> APIError {
         if code == ContinuousBatchSchedulerError.deliveryBackpressureCode,
            let mapped = ContinuousBatchSchedulerError.deliveryBackpressure.asAPIError() {
             return mapped
         }
         return attachedPagedKVUnavailableError(code: code)
     }
 
     private nonisolated static func attachedPagedKVUnavailableError(code: String) -> APIError {
         APIError(
             status: 503,
             message: "Inference engine unavailable",
             type: "server_error",
             code: code,
@@ -4895,147 +5060,143 @@ actor ModelRuntime: ModelRuntimeServing {
                                 stopTokenFilter: stopTokenFilter,
                                 promptTokenCount: promptTokenIds.count,
                                 completionStartedAt: completionStartedAt,
                                 modelHash: snapshot.modelHash,
                                 specDecodeGeneration: snapshot.specDecodeGeneration,
                                 shouldCancel: shouldCancel,
                                 drainCancelled: drainCancelled,
                                 blockingInferenceExecutor: blockingInferenceExecutor
                             )
                         } catch let error as DrainCancelledError {
                             throw error
                         } catch let error as CancellationError {
                             throw error
                         } catch let error as SpeculativeGenerationFailure {
                             // FR-12 permits one pre-output retry on the existing
                             // non-speculative target path. This branch happens
                             // before any buyer-visible response exists for the
                             // non-streaming endpoint.
                             Self.logSpeculativeFallback(error)
                         }
                     }
                     let lease = await conversationCache.begin(
                         conversationKey: request.conversationKey,
                         incomingTokens: promptTokenIds,
                         modelID: request.model,
                         kvBits: kvBitsOverride,
                         cold: coldContext
                     )
                         do {
                             let generationContext = Self.harmonyTerminalPreservingContext(from: context, modelID: request.model)
                             let kvCache: [KVCache]
                             var iteratorInput: LMInput
                             if let reusableCache = lease?.reusableCache, let lcp = lease?.lcp {
                                 kvCache = reusableCache.layers
                                 iteratorInput = LMInput(tokens: MLXArray(Array(promptTokenIds[lcp...])))
                             } else {
                                 // SPEC-037 FR-KVP1 / SPEC-024-R001: eligible persist and
                                 // keyed serial reuse allocate KVCacheSimple; keyless traffic
                                 // keeps the rotating cap. TokenIterator still gets the
                                 // original `parameters` (its maxKVSize is ignored once the
                                 // cache is passed explicitly).
                                 kvCache = Self.serveCache(
                                     model: generationContext.model, baseParameters: parameters,
                                     forceSimpleKV: Self.forceSimpleKVCache(
                                         eligible: coldContext?.eligible == true,
                                         conversationKey: request.conversationKey))
                                 iteratorInput = lmInput
                             }
                             let recurrent = Self.prefillRecurrentCheckpoints(
                                 lease: lease, cache: kvCache, promptTokenIds: promptTokenIds,
                                 context: generationContext, prefillStepSize: parameters.prefillStepSize)
                             if let resumeAt = recurrent.resumeAt {
                                 iteratorInput = LMInput(tokens: MLXArray(Array(promptTokenIds[resumeAt...])))
                             }
 
                             let iterator = try TokenIterator(input: iteratorInput, model: generationContext.model, cache: kvCache, parameters: parameters)
                             var serialToolObserver = NativeToolCallStreamEmitter(
                                 modelID: request.model,
                                 allowedFunctionNames: Self.toolFunctionNames(from: request.promptSource.tools)
                             )
+                            let serialToolStopApplies = Self.serialToolStopApplies(request)
                             let result: BlockingGenerateResult = try await blockingInferenceExecutor.run { inferenceCancellation in
                                 BlockingGenerateResult(generate(input: iteratorInput, context: generationContext, iterator: iterator) { tokens in
                                     if !tokens.isEmpty {
                                         firstToken.recordIfMissing()
                                         ModelLivenessTracker.shared.recordProgress()
                                     }
                                     if Task.isCancelled || inferenceCancellation.isCancelled || shouldCancel() || drainCancelled.isFired {
                                         return GenerateDisposition.stop
                                     }
                                     if HarmonyResponseParser.isHarmonyModelID(request.model),
                                        tokens.last.map(Self.isHarmonyTerminalToken) == true {
                                         return GenerateDisposition.stop
                                     }
-                                    if request.stopsAfterFirstCompleteToolCall,
-                                       !HarmonyResponseParser.isHarmonyModelID(request.model),
-                                       Self.hasEnabledTools(request.promptSource.tools)
+                                    if serialToolStopApplies,
+                                       Self.observeSerialToolStop(
+                                           &serialToolObserver,
+                                           decoded: generationContext.tokenizer.decode(tokenIds: tokens),
+                                           stopTokenFilter: stopTokenFilter,
+                                           requestStops: request.stop
+                                       )
                                     {
-                                        let decoded = generationContext.tokenizer.decode(tokenIds: tokens)
-                                        let candidate = Self.streamingSafePrefix(
-                                            decoded,
-                                            stopTokenFilter: stopTokenFilter,
-                                            requestStops: request.stop
-                                        )
-                                        _ = serialToolObserver.observe(candidate.text)
-                                        if serialToolObserver.hasCompletedValidToolCall {
-                                            return GenerateDisposition.stop
-                                        }
+                                        return GenerateDisposition.stop
                                     }
                                     return GenerateDisposition.more
                                 })
                             }
                             try drainCancelled.check()
                             try Task.checkCancellation()
                             if shouldCancel() {
                                 throw CancellationError()
                             }
                             let resultTokenIDs = result.tokenIds
 
                         guard result.output.utf8.count <= ToolCallParser.SPEC018_ARGUMENTS_PER_RESPONSE_BYTE_CAP else {
                             throw APIError(
                                 status: 502,
                                 message: "Model response exceeded 2097152 bytes",
                                 type: "upstream_provider_error",
                                 code: "response_byte_cap_exceeded",
                                 inferenceRan: true,
                                 settlementRan: true
                             )
                         }
 
                         let filtered = Self.applyOutputFilters(
                             result.output,

exec
/bin/bash -lc "git diff --no-ext-diff --unified=45 origin/main...52fcb7e4 -- phase3-binary/Sources/macprovider-cli/ModelRuntime.swift | rg -n -C 12 'SerialStreamingTextEmitter|textEmitter|toolStreamer|structuredAccumulator.append|streamToolsIncrementally' | tail -300" in /Users/augstar/macprovider-1646-rest
 succeeded in 0ms:
1439-                 onChunk(.content(completion.content))
1440-             }
1441-             return try Self.validateStructuredStreamingCompletion(
1442-                 completion,
1443-                 request: request,
1444-                 buyerVisibleContent: structuredAccumulator.content
1445-             )
1446-         }
1447-         guard let container = snapshot.container else {
--
1486-                                 conversationKey: request.conversationKey))
1487-                         iteratorInput = lmInput
1488-                     }
1489-                     let recurrent = Self.prefillRecurrentCheckpoints(
1490-                         lease: lease, cache: kvCache, promptTokenIds: promptTokenIds,
1491-                         context: generationContext, prefillStepSize: parameters.prefillStepSize)
1492-                     if let resumeAt = recurrent.resumeAt {
1493-                         iteratorInput = LMInput(tokens: MLXArray(Array(promptTokenIds[resumeAt...])))
1494-                     }
1495- 
1496--                    var emittedText = ""
1497-                     var stoppedByRequestStop = false
1498:-                    var toolStreamer = NativeToolCallStreamEmitter(
1499--                        modelID: request.model,
1500--                        allowedFunctionNames: Self.toolFunctionNames(from: request.promptSource.tools)
1501--                    )
1502:+                    var textEmitter = SerialStreamingTextEmitter(request: request)
1503-                     var streamingParseError: APIError?
1504-                     var harmonyObservedFinalTokenCount = 0
1505-                     var harmonyObservedTokenCount = 0
1506- 
1507-                     // SPEC-037 FR-KVP2.5: speculative-decode routing is determined
1508-                     // BEFORE conversationCache.begin() (block above, ahead of the
1509-                     // lease acquisition) — a speculative-routed request acquires no
1510-                     // lease, triggers no promotion, commits nothing, and leaves no
1511-                     // busy key. This non-speculative path therefore never re-checks
1512-                     // speculativeRoute; the post-begin speculative block that origin
1513-                     // carried here would double-run and (on its success return) leak
1514-                     // the lease as a stuck busy key, so it is intentionally dropped.
1515-                     let isHarmonyResponse = HarmonyResponseParser.isHarmonyModelID(request.model)
1516-                     var harmonyFinalDetokenizer = NaiveStreamingDetokenizer(tokenizer: context.tokenizer)
1517-                     var harmonyStreamingParser = HarmonyResponseParser.StreamingParser(
1518-                         decode: { context.tokenizer.decode(tokenIds: $0) },
1519-                         decodeFinalToken: { tokenID in
1520-                             harmonyFinalDetokenizer.append(token: tokenID)
1521-                             return harmonyFinalDetokenizer.next()
1522-                         },
1523-                         allowedFunctionNames: Self.toolFunctionNames(from: request.promptSource.tools),
1524-                         stopCandidates: stopTokenFilter.tokens + request.stop
1525-                     )
1526:-                    let streamToolsIncrementally = Self.hasEnabledTools(request.promptSource.tools) && !isHarmonyResponse
1527-                     let iterator = try TokenIterator(input: iteratorInput, model: generationContext.model, cache: kvCache, parameters: parameters)
1528-                     do {
1529-                         let result: BlockingGenerateResult = try await blockingInferenceExecutor.run { inferenceCancellation in
1530-                             BlockingGenerateResult(generate(input: iteratorInput, context: generationContext, iterator: iterator) { tokens in
1531-                                 EgressPerfTraceKey.current?.recordDecodeCallbackEntry()
1532-                                 // Round-2 code LOW: only start the decode timer
1533-                                 // on a callback that actually carries a token.
1534-                                 // An empty first callback would otherwise start
1535-                                 // the clock during prefill and inflate the
1536-                                 // measured decode window. Mirrors the
1537-                                 // `if !tokens.isEmpty { firstToken.recordIfMissing() }`
1538-                                 // guards elsewhere in this file.
--
1576-                                         return .stop
1577-                                     } catch {
1578-                                         streamingParseError = Self.malformedHarmonyResponseError()
1579-                                         return .stop
1580-                                     }
1581-                                 }
1582-                                 let decoded = context.tokenizer.decode(tokenIds: tokens)
1583-                                 let candidate = Self.streamingSafePrefix(
1584-                                     decoded,
1585-                                     stopTokenFilter: stopTokenFilter,
1586-                                     requestStops: request.stop
1587-                                 )
1588:-                                    if streamToolsIncrementally {
1589:-                                        for event in toolStreamer.observe(candidate.text) {
1590--                                        onChunk(event)
1591--                                    }
1592:-                                    if !toolStreamer.suppressesAssistantContent {
1593:-                                        let safe = toolStreamer.visibleContentPrefix(of: candidate.text)
1594--                                        let delta = Self.delta(from: emittedText, to: safe)
1595--                                        if !delta.isEmpty {
1596:-                                            if structuredAccumulator.append(delta) != nil {
1597--                                                return .stop
1598--                                            }
1599--                                            idleState.noteContent()
1600--                                            emittedText = safe
1601--                                            onChunk(.content(delta))
1602--                                        }
1603--                                    }
1604:-                                    if request.stopsAfterFirstCompleteToolCall, toolStreamer.hasCompletedValidToolCall {
1605--                                        return .stop
1606--                                    }
1607--                                    if candidate.hitStop {
1608--                                        stoppedByRequestStop = true
1609--                                        return .stop
1610--                                    }
1611:+                                switch textEmitter.step(
1612-+                                    candidate: candidate,
1613-+                                    structuredAccumulator: structuredAccumulator,
1614-+                                    idleState: idleState,
1615-+                                    onChunk: onChunk
1616-+                                ) {
1617-+                                case .more:
1618-                                     return .more
1619--                                }
1620--
1621--                                let delta = Self.delta(from: emittedText, to: candidate.text)
1622--                                if !delta.isEmpty {
1623:-                                    if structuredAccumulator.append(delta) != nil {
1624--                                        return .stop
1625--                                    }
1626--                                    idleState.noteContent()
1627--                                    emittedText = candidate.text
1628--                                    onChunk(.content(delta))
1629--                                }
1630--
1631--                                if candidate.hitStop {
1632-+                                case .requestStop:
1633-                                     stoppedByRequestStop = true
1634-                                     return .stop
1635-+                                case .toolCallComplete, .structuredError:
--
1671-                         let parsed = try Self.parseGeneratedOutput(
1672-                             filteredText: final.text,
1673-                             generatedTokenIDs: resultTokenIDs,
1674-                             decode: { context.tokenizer.decode(tokenIds: $0) },
1675-                             request: request,
1676-                             mode: .complete(finishReason: parserFinishReason),
1677-                             defaultCompletionTokens: result.generationTokenCount,
1678-                             stopTokenFilter: stopTokenFilter,
1679-                             requestStops: request.stop,
1680-                             globalHitStop: final.hitStop || stoppedByRequestStop
1681-                         )
1682--                        let finalDelta = Self.delta(from: emittedText, to: parsed.content)
1683:-                        if streamToolsIncrementally {
1684:-                            for event in toolStreamer.observe(final.text) {
1685--                                onChunk(event)
1686--                            }
1687--                            if parsed.toolCalls.isEmpty,
1688--                               !parsed.content.isEmpty,
1689:-                               !toolStreamer.suppressesAssistantContent
1690--                            {
1691--                                let contentDelta = Self.delta(from: emittedText, to: parsed.content)
1692--                                if !contentDelta.isEmpty {
1693:-                                    if let error = structuredAccumulator.append(contentDelta) {
1694--                                        throw error
1695--                                    }
1696--                                    idleState.noteContent()
1697--                                    onChunk(.content(contentDelta))
1698--                                }
1699--                            }
1700--                        } else if !finalDelta.isEmpty {
1701:-                            if let error = structuredAccumulator.append(finalDelta) {
1702--                                throw error
1703--                            }
1704--                            idleState.noteContent()
1705--                            onChunk(.content(finalDelta))
1706--                        }
1707--                        if let error = structuredAccumulator.error {
1708--                            throw error
1709--                        }
1710:+                        try textEmitter.finish(
1711-+                            finalText: final.text,
1712-+                            parsed: parsed,
1713-+                            structuredAccumulator: structuredAccumulator,
1714-+                            idleState: idleState,
1715-+                            onChunk: onChunk
1716-+                        )
1717- 
1718-                         let finishReason: String
1719-                         if !parsed.toolCalls.isEmpty {
1720-                             finishReason = "tool_calls"
1721-                         } else if let maxTokens = request.maxTokens,
1722-                            result.generationTokenCount >= maxTokens,
--
2253-         default:
2254-             return false
2255-         }
2256-     }
2257- }
2258- 
2259-+/// The serial streaming path's buyer-visible text step for non-Harmony output:
2260-+/// incremental tool-call deltas (SPEC-018), assistant-content suppression once
2261-+/// a tool call opens, the SPEC-019 structured-content accumulator, and the
2262-+/// serial-tool-turn stop. The serial `stream` path and the continuous-batching
2263-+/// stream sink (SPEC-038 AC-6c) both drive this one type, so a batched
2264-+/// tool-bearing or structured-output row emits the serial SSE sequence.
2265:+struct SerialStreamingTextEmitter {
2266-+    enum Step: Equatable {
2267-+        case more
2268-+        /// A buyer `stop` string matched in the decoded text.
2269-+        case requestStop
2270-+        /// A serial tool turn completed its first valid tool call.
2271-+        case toolCallComplete
2272-+        /// The structured-output accumulator refused the delta (its error is
2273-+        /// held by the accumulator).
2274-+        case structuredError
2275-+    }
2276-+
2277:+    private let streamToolsIncrementally: Bool
2278-+    private let stopsAfterFirstCompleteToolCall: Bool
2279:+    private var toolStreamer: NativeToolCallStreamEmitter
2280-+    private(set) var emittedText = ""
2281-+
2282-+    init(request: ChatCompletionRequest) {
2283:+        streamToolsIncrementally = ModelRuntime.hasEnabledTools(request.promptSource.tools)
2284-+            && !HarmonyResponseParser.isHarmonyModelID(request.model)
2285-+        stopsAfterFirstCompleteToolCall = request.stopsAfterFirstCompleteToolCall
2286:+        toolStreamer = NativeToolCallStreamEmitter(
2287-+            modelID: request.model,
2288-+            allowedFunctionNames: ModelRuntime.toolFunctionNames(from: request.promptSource.tools)
2289-+        )
2290-+    }
2291-+
2292-+    /// One decoded prefix of the generation (`streamingSafePrefix` of every
2293-+    /// token so far).
2294-+    mutating func step(
2295-+        candidate: (text: String, hitStop: Bool),
2296-+        structuredAccumulator: StructuredStreamingContentAccumulator,
2297-+        idleState: StructuredStreamingIdleState,
2298-+        onChunk: (StreamChunk) -> Void
2299-+    ) -> Step {
2300:+        if streamToolsIncrementally {
2301:+            for event in toolStreamer.observe(candidate.text) {
2302-+                onChunk(event)
2303-+            }
2304:+            if !toolStreamer.suppressesAssistantContent {
2305:+                let safe = toolStreamer.visibleContentPrefix(of: candidate.text)
2306-+                let delta = ModelRuntime.streamDelta(from: emittedText, to: safe)
2307-+                if !delta.isEmpty {
2308:+                    if structuredAccumulator.append(delta) != nil {
2309-+                        return .structuredError
2310-+                    }
2311-+                    idleState.noteContent()
2312-+                    emittedText = safe
2313-+                    onChunk(.content(delta))
2314-+                }
2315-+            }
2316:+            if stopsAfterFirstCompleteToolCall, toolStreamer.hasCompletedValidToolCall {
2317-+                return .toolCallComplete
2318-+            }
2319-+            return candidate.hitStop ? .requestStop : .more
2320-+        }
2321-+
2322-+        let delta = ModelRuntime.streamDelta(from: emittedText, to: candidate.text)
2323-+        if !delta.isEmpty {
2324:+            if structuredAccumulator.append(delta) != nil {
2325-+                return .structuredError
2326-+            }
2327-+            idleState.noteContent()
2328-+            emittedText = candidate.text
2329-+            onChunk(.content(delta))
2330-+        }
2331-+        return candidate.hitStop ? .requestStop : .more
2332-+    }
2333-+
2334-+    /// The end of generation: remaining tool-call deltas over the final
2335-+    /// filtered text, then any content the stream held back.
2336-+    mutating func finish(
2337-+        finalText: String,
2338-+        parsed: ModelRuntime.ParsedGeneratedOutput,
2339-+        structuredAccumulator: StructuredStreamingContentAccumulator,
2340-+        idleState: StructuredStreamingIdleState,
2341-+        onChunk: (StreamChunk) -> Void
2342-+    ) throws {
2343-+        let finalDelta = ModelRuntime.streamDelta(from: emittedText, to: parsed.content)
2344:+        if streamToolsIncrementally {
2345:+            for event in toolStreamer.observe(finalText) {
2346-+                onChunk(event)
2347-+            }
2348-+            if parsed.toolCalls.isEmpty,
2349-+               !parsed.content.isEmpty,
2350:+               !toolStreamer.suppressesAssistantContent
2351-+            {
2352-+                let contentDelta = ModelRuntime.streamDelta(from: emittedText, to: parsed.content)
2353-+                if !contentDelta.isEmpty {
2354:+                    if let error = structuredAccumulator.append(contentDelta) {
2355-+                        throw error
2356-+                    }
2357-+                    idleState.noteContent()
2358-+                    onChunk(.content(contentDelta))
2359-+                }
2360-+            }
2361-+        } else if !finalDelta.isEmpty {
2362:+            if let error = structuredAccumulator.append(finalDelta) {
2363-+                throw error
2364-+            }
2365-+            idleState.noteContent()
2366-+            onChunk(.content(finalDelta))
2367-+        }
2368-+        if let error = structuredAccumulator.error {
2369-+            throw error
2370-+        }
2371-+    }
2372-+}
2373-+
2374- // `internal` (not `private`) so the allowlist fail-closed behavior is unit-testable via

exec
/bin/bash -lc "nl -ba phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift | sed -n '1585,1645p;710,790p' && rg -n \"finishTerminalDelivery|withSettlementDisposition|pendingTerminalDeliveries|remainingWaiterIDs|settlementDisposition\" phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift | head -80 && nl -ba phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift | sed -n '2860,3025p'" in /Users/augstar/macprovider-1646-rest
 succeeded in 0ms:
   710	        lock.lock()
   711	        precondition(inUse > 0, "token delivery capacity release must balance acquisition")
   712	        inUse -= 1
   713	        lock.unlock()
   714	    }
   715	}
   716	
   717	final class ContinuousBatchTokenDelivery: @unchecked Sendable {
   718	    private let lock = NSLock()
   719	    private let bufferLimit: Int
   720	    private let timeoutNanoseconds: UInt64
   721	    private let sink: ContinuousBatchSchedulerTokenSink
   722	    private let capacity: ContinuousBatchTokenDeliveryCapacity
   723	    private var queue: [ContinuousBatchSchedulerTokenEvent] = []
   724	    private var drainCompletion: (@Sendable (Bool) -> Void)?
   725	    private var accepting = true
   726	    private var draining = false
   727	    private var timedOut = false
   728	    private var ownsCapacity = false
   729	    private var drainGeneration: UUID?
   730	    private var deliveryTask: Task<Void, Never>?
   731	    private var timeoutTask: Task<Void, Never>?
   732	    /// Test seam: runs after the drain loop sees an empty queue and before it
   733	    /// decides whether to finish, the window an `offer()` can land in.
   734	    var afterDrainSawEmptyQueueForTest: (@Sendable () -> Void)?
   735	
   736	    init(
   737	        bufferLimit: Int,
   738	        timeoutNanoseconds: UInt64,
   739	        capacity: ContinuousBatchTokenDeliveryCapacity,
   740	        sink: @escaping ContinuousBatchSchedulerTokenSink
   741	    ) {
   742	        self.bufferLimit = max(1, bufferLimit)
   743	        self.timeoutNanoseconds = timeoutNanoseconds
   744	        self.capacity = capacity
   745	        self.sink = sink
   746	    }
   747	
   748	    /// Non-blocking offer. The scheduler fails only this waiter when its
   749	    /// consumer cannot keep up with the bounded delivery buffer.
   750	    func offer(_ event: ContinuousBatchSchedulerTokenEvent) -> Bool {
   751	        var generationToStart: UUID?
   752	        lock.lock()
   753	        guard accepting, queue.count < bufferLimit else {
   754	            lock.unlock()
   755	            return false
   756	        }
   757	        if !draining {
   758	            guard capacity.tryAcquire() else {
   759	                lock.unlock()
   760	                return false
   761	            }
   762	            ownsCapacity = true
   763	            draining = true
   764	            let generation = UUID()
   765	            drainGeneration = generation
   766	            generationToStart = generation
   767	        }
   768	        queue.append(event)
   769	        lock.unlock()
   770	        if let generationToStart {
   771	            startDrain(generation: generationToStart)
   772	        }
   773	        return true
   774	    }
   775	
   776	    /// Stops new events while allowing the already-bounded queue to drain in
   777	    /// order outside scheduler isolation.
   778	    func finish() {
   779	        stop(afterStopping: {})
   780	    }
   781	
   782	    /// Stops new delivery. Cooperative sinks acknowledge immediately; a sink
   783	    /// that ignores cancellation is detached from scheduler state at the same
   784	    /// hard deadline used by terminal delivery and completes this waiter as a
   785	    /// non-settling failure. Its live-task capacity remains quarantined until
   786	    /// the sink actually returns, preventing unbounded detached-task growth.
   787	    func stop(afterStopping completion: @escaping @Sendable () -> Void) {
   788	        lock.lock()
   789	        accepting = false
   790	        queue.removeAll()
  1585	            delivery.finish(afterDraining: { delivered in
  1586	                Task {
  1587	                    await self.finishTerminalDelivery(
  1588	                        requestID: request.id,
  1589	                        waiterID: waiterID,
  1590	                        delivered: delivered
  1591	                    )
  1592	                }
  1593	            })
  1594	            return
  1595	        }
  1596	        if dedupeTombstones.contains(request.id) {
  1597	            delivery.finish()
  1598	            scheduleDiscardUnacceptedRetainedCache(for: request)
  1599	            continuation.resume(throwing: ContinuousBatchSchedulerError.idempotencyWindowExpired)
  1600	            return
  1601	        }
  1602	        if draining {
  1603	            delivery.finish()
  1604	            scheduleDiscardUnacceptedRetainedCache(for: request)
  1605	            continuation.resume(throwing: ContinuousBatchSchedulerError.drained)
  1606	            return
  1607	        }
  1608	        if knownRequests[request.id] != nil {
  1609	            // Same shape as the `pendingTerminalDeliveries` guard above:
  1610	            // the duplicate never attached and never received an event.
  1611	            let deferredWaiterCount = deferredTerminalCompletions[request.id]?.waiters.count ?? 0
  1612	            guard requestWaiters[request.id, default: []].count + deferredWaiterCount
  1613	                    < configuration.duplicateWaiterLimit else {
  1614	                record(.backpressureRejected)
  1615	                delivery.finish()
  1616	                scheduleDiscardUnacceptedRetainedCache(for: request)
  1617	                continuation.resume(throwing: ContinuousBatchSchedulerError.backpressure)
  1618	                return
  1619	            }
  1620	            scheduleDiscardUnacceptedRetainedCache(for: request)
  1621	            requestWaiters[request.id, default: []].append(Waiter(
  1622	                id: waiterID,
  1623	                continuation: continuation,
  1624	                delivery: delivery
  1625	            ))
  1626	            if let row = activeDecode[request.id], let token = row.outputTokens.last {
  1627	                let replay = ContinuousBatchSchedulerTokenEvent(
  1628	                    requestID: row.request.id,
  1629	                    tokenIndex: row.outputTokens.count - 1,
  1630	                    token: token,
  1631	                    replayTokens: row.outputTokens,
  1632	                    snapshot: row.snapshot
  1633	                )
  1634	                // First offer to this waiter's own fresh delivery, as
  1635	                // above: the attach is rolled back and the caller has seen
  1636	                // no output, so this stays the pre-admission classification
  1637	                // even though the request it tried to join is decoding.
  1638	                if !delivery.offer(replay) {
  1639	                    var retained = requestWaiters[request.id] ?? []
  1640	                    retained.removeAll { $0.id == waiterID }
  1641	                    if retained.isEmpty {
  1642	                        requestWaiters.removeValue(forKey: request.id)
  1643	                        cancel(requestID: request.id)
  1644	                    } else {
  1645	                        requestWaiters[request.id] = retained
287:    let settlementDisposition: ContinuousBatchSettlementDisposition
293:    func withSettlementDisposition(
308:            settlementDisposition: disposition,
327:            settlementDisposition: settlementDisposition,
345:            && lhs.settlementDisposition == rhs.settlementDisposition
1160:        var remainingWaiterIDs: Set<UUID>
1207:    private var pendingTerminalDeliveries: [String: PendingTerminalDelivery] = [:]
1376:        if pendingTerminalDeliveries[requestID] != nil {
1418:            || !activePrompt.isEmpty || !activeDecode.isEmpty || !pendingTerminalDeliveries.isEmpty
1470:            && pendingTerminalDeliveries.isEmpty
1478:        for requestID in pendingTerminalDeliveries.keys.sorted() {
1479:            guard let pending = pendingTerminalDeliveries[requestID] else { continue }
1481:            where pending.remainingWaiterIDs.contains(waiter.id)
1503:                + pendingTerminalDeliveries.values.reduce(0) { $0 + $1.waiters.count }
1541:            continuation.resume(returning: terminal.withSettlementDisposition(.nonSettlingReplay))
1544:        if var pending = pendingTerminalDeliveries[request.id] {
1583:            pending.remainingWaiterIDs.insert(waiterID)
1584:            pendingTerminalDeliveries[request.id] = pending
1587:                    await self.finishTerminalDelivery(
1609:            // Same shape as the `pendingTerminalDeliveries` guard above:
1795:        if let waiter = pendingTerminalDeliveries[requestID]?.waiters.first(where: { $0.id == waiterID }) {
1824:        if var pending = pendingTerminalDeliveries[requestID],
1825:           pending.remainingWaiterIDs.contains(waiterID),
1828:            pending.remainingWaiterIDs.remove(waiterID)
1832:                pendingTerminalDeliveries.removeValue(forKey: requestID)
1845:                    settlementDisposition: .notEligible,
1855:            } else if pending.remainingWaiterIDs.isEmpty {
1856:                pendingTerminalDeliveries.removeValue(forKey: requestID)
1859:                pendingTerminalDeliveries[requestID] = pending
2745:            settlementDisposition: .notEligible,
2783:            settlementDisposition: isSuccessful ? .eligibleOwner : .notEligible,
2812:            settlementDisposition: isSuccessful ? .eligibleOwner : .notEligible,
2821:        guard terminalResults[requestID] == nil, pendingTerminalDeliveries[requestID] == nil else { return }
2851:        pendingTerminalDeliveries[requestID] = PendingTerminalDelivery(
2854:            remainingWaiterIDs: Set(waiters.map(\.id))
2859:                    await self.finishTerminalDelivery(
2869:    private func finishTerminalDelivery(requestID: String, waiterID: UUID, delivered: Bool) async {
2874:        guard var pending = pendingTerminalDeliveries[requestID],
2875:              pending.remainingWaiterIDs.remove(waiterID) != nil else {
2879:        CBTrace.log(requestID, "sch_ftd delivered=\(delivered) remaining=\(pending.remainingWaiterIDs.count)")
2881:        guard pending.remainingWaiterIDs.isEmpty else {
2882:            pendingTerminalDeliveries[requestID] = pending
2885:        pendingTerminalDeliveries.removeValue(forKey: requestID)
2906:                settlementDisposition: .notEligible,
2933:        terminalResults[requestID] = result.withSettlementDisposition(
2934:            result.settlementDisposition == .eligibleOwner ? .nonSettlingReplay : .notEligible
2936:        let settlementOwnerID = result.settlementDisposition == .eligibleOwner
2953:                    settlementDisposition: .notEligible,
2959:                    : (result.settlementDisposition == .eligibleOwner ? .nonSettlingReplay : .notEligible)
2960:                var waiterResult = result.withSettlementDisposition(disposition)
  2860	                        requestID: requestID,
  2861	                        waiterID: waiter.id,
  2862	                        delivered: delivered
  2863	                    )
  2864	                }
  2865	            })
  2866	        }
  2867	    }
  2868	
  2869	    private func finishTerminalDelivery(requestID: String, waiterID: UUID, delivered: Bool) async {
  2870	        guard !stoppingWaiterIDs.contains(waiterID) else {
  2871	            CBTrace.log(requestID, "sch_ftd_skip_stopping")
  2872	            return
  2873	        }
  2874	        guard var pending = pendingTerminalDeliveries[requestID],
  2875	              pending.remainingWaiterIDs.remove(waiterID) != nil else {
  2876	            CBTrace.log(requestID, "sch_ftd_skip_no_pending")
  2877	            return
  2878	        }
  2879	        CBTrace.log(requestID, "sch_ftd delivered=\(delivered) remaining=\(pending.remainingWaiterIDs.count)")
  2880	        pending.deliveryOutcomes[waiterID] = delivered
  2881	        guard pending.remainingWaiterIDs.isEmpty else {
  2882	            pendingTerminalDeliveries[requestID] = pending
  2883	            return
  2884	        }
  2885	        pendingTerminalDeliveries.removeValue(forKey: requestID)
  2886	        await finalizePendingTerminal(requestID: requestID, pending: pending)
  2887	    }
  2888	
  2889	    private func finalizePendingTerminal(requestID: String, pending: PendingTerminalDelivery) async {
  2890	        let result: ContinuousBatchSchedulerResult
  2891	        if pending.deliveryOutcomes.values.contains(true) {
  2892	            result = pending.result
  2893	        } else {
  2894	            result = ContinuousBatchSchedulerResult(
  2895	                requestID: pending.result.requestID,
  2896	                conversationKey: pending.result.conversationKey,
  2897	                generatedTokens: [],
  2898	                outputTokens: [],
  2899	                promptTokens: pending.result.promptTokens,
  2900	                completionTokens: 0,
  2901	                emittedTokens: pending.result.emittedTokens,
  2902	                cachedPromptTokens: pending.result.cachedPromptTokens,
  2903	                terminalStatus: .requestFailed,
  2904	                errorCode: "continuous_batching_stream_delivery_timed_out",
  2905	                snapshot: pending.result.snapshot,
  2906	                settlementDisposition: .notEligible,
  2907	                retainedCache: nil
  2908	            )
  2909	        }
  2910	        finalizeTerminalResult(
  2911	            requestID: requestID,
  2912	            result: result,
  2913	            waiters: pending.waiters,
  2914	            deliveryOutcomes: pending.deliveryOutcomes
  2915	        )
  2916	        if !pending.deliveryOutcomes.values.contains(true),
  2917	           let retainedCache = pending.result.retainedCache {
  2918	            await discardRetainedCache(
  2919	                retainedCache.retainedSequence,
  2920	                conversationKey: pending.result.conversationKey
  2921	            )
  2922	        }
  2923	    }
  2924	
  2925	    private func finalizeTerminalResult(
  2926	        requestID: String,
  2927	        result: ContinuousBatchSchedulerResult,
  2928	        waiters: [Waiter],
  2929	        deliveryOutcomes: [UUID: Bool]? = nil
  2930	    ) {
  2931	        backend.finish(requestID: requestID)
  2932	        terminalResultOrder.append(requestID)
  2933	        terminalResults[requestID] = result.withSettlementDisposition(
  2934	            result.settlementDisposition == .eligibleOwner ? .nonSettlingReplay : .notEligible
  2935	        )
  2936	        let settlementOwnerID = result.settlementDisposition == .eligibleOwner
  2937	            ? waiters.first(where: { deliveryOutcomes?[$0.id] != false })?.id
  2938	            : nil
  2939	        for waiter in waiters {
  2940	            if deliveryOutcomes?[waiter.id] == false {
  2941	                waiter.continuation.resume(returning: ContinuousBatchSchedulerResult(
  2942	                    requestID: result.requestID,
  2943	                    conversationKey: result.conversationKey,
  2944	                    generatedTokens: [],
  2945	                    outputTokens: [],
  2946	                    promptTokens: result.promptTokens,
  2947	                    completionTokens: 0,
  2948	                    emittedTokens: result.emittedTokens,
  2949	                    cachedPromptTokens: result.cachedPromptTokens,
  2950	                    terminalStatus: .requestFailed,
  2951	                    errorCode: "continuous_batching_stream_delivery_timed_out",
  2952	                    snapshot: result.snapshot,
  2953	                    settlementDisposition: .notEligible,
  2954	                    retainedCache: nil
  2955	                ))
  2956	            } else {
  2957	                let disposition: ContinuousBatchSettlementDisposition = waiter.id == settlementOwnerID
  2958	                    ? .eligibleOwner
  2959	                    : (result.settlementDisposition == .eligibleOwner ? .nonSettlingReplay : .notEligible)
  2960	                var waiterResult = result.withSettlementDisposition(disposition)
  2961	                if disposition == .eligibleOwner, let retainedCache = waiterResult.retainedCache {
  2962	                    deliveredRetainedOwners[waiter.id] = DeliveredRetainedOwner(
  2963	                        retained: retainedCache.retainedSequence,
  2964	                        conversationKey: result.conversationKey
  2965	                    )
  2966	                    waiterResult = waiterResult.withRetainedCache(retainedCache.withDeliveryID(waiter.id))
  2967	                }
  2968	                waiter.continuation.resume(returning: waiterResult)
  2969	            }
  2970	            CBTrace.log(requestID, "sch_resumed")
  2971	        }
  2972	        while terminalResultOrder.count > configuration.terminalResultLimit {
  2973	            let evictedID = terminalResultOrder.removeFirst()
  2974	            terminalResults.removeValue(forKey: evictedID)
  2975	            knownRequests.removeValue(forKey: evictedID)
  2976	            cancelledIDs.remove(evictedID)
  2977	            if dedupeTombstones.insert(evictedID).inserted {
  2978	                dedupeTombstoneOrder.append(evictedID)
  2979	            }
  2980	        }
  2981	        while dedupeTombstoneOrder.count > configuration.dedupeTombstoneLimit {
  2982	            dedupeTombstones.remove(dedupeTombstoneOrder.removeFirst())
  2983	        }
  2984	    }
  2985	
  2986	    private func record(_ diagnostic: ContinuousBatchSchedulerDiagnostic) {
  2987	        diagnostics.append(diagnostic)
  2988	        if diagnostics.count > configuration.diagnosticLimit {
  2989	            diagnostics.removeFirst(diagnostics.count - configuration.diagnosticLimit)
  2990	        }
  2991	    }
  2992	
  2993	    @discardableResult
  2994	    private func release(_ handle: PagedKVBlockTableHandle) async -> Bool {
  2995	        do {
  2996	            try await allocator.release(handle)
  2997	            return true
  2998	        } catch {
  2999	            cleanupFailedClosed = true
  3000	            record(.cleanupFailed)
  3001	            return false
  3002	        }
  3003	    }
  3004	
  3005	    @discardableResult
  3006	    private func endDecodeStep(_ handle: PagedKVBlockTableHandle) async -> Bool {
  3007	        do {
  3008	            try await allocator.endDecodeStep(handle)
  3009	            return true
  3010	        } catch {
  3011	            cleanupFailedClosed = true
  3012	            record(.cleanupFailed)
  3013	            return false
  3014	        }
  3015	    }
  3016	
  3017	    private var occupiedSlots: Int {
  3018	        admittingRequests.count + activePrompt.count + activeDecode.count
  3019	    }
  3020	
  3021	    private func schedulerConversationKey(for request: ContinuousBatchSchedulerRequest) -> String {
  3022	        let trimmed = request.conversationKey.trimmingCharacters(in: .whitespacesAndNewlines)
  3023	        return trimmed.isEmpty ? "continuous-batching:\(request.id)" : trimmed
  3024	    }
  3025	

exec
/bin/bash -lc "nl -ba phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift | sed -n '2805,2870p;1690,1865p'" in /Users/augstar/macprovider-1646-rest
 succeeded in 0ms:
  1690	            delivery: delivery
  1691	        ))
  1692	        waiting.append(request)
  1693	        beginQueueWait(requestID: request.id)
  1694	        ensurePump()
  1695	    }
  1696	
  1697	    /// Starts the bounded admission clock for a request that just entered the
  1698	    /// waiting queue.
  1699	    private func beginQueueWait(requestID: String) {
  1700	        let timeout = configuration.queueWaitTimeoutNanoseconds
  1701	        guard timeout > 0 else { return }
  1702	        let now = DispatchTime.now().uptimeNanoseconds
  1703	        let (candidate, overflow) = now.addingReportingOverflow(timeout)
  1704	        queueWaitDeadlines[requestID] = overflow ? UInt64.max : candidate
  1705	        armQueueWaitTimeout(requestID: requestID)
  1706	    }
  1707	
  1708	    private func armQueueWaitTimeout(requestID: String) {
  1709	        guard let deadline = queueWaitDeadlines[requestID] else { return }
  1710	        let now = DispatchTime.now().uptimeNanoseconds
  1711	        let remaining = deadline > now ? deadline - now : 0
  1712	        queueWaitTimeoutTasks.removeValue(forKey: requestID)?.cancel()
  1713	        queueWaitTimeoutTasks[requestID] = Task { [weak self] in
  1714	            if remaining > 0 {
  1715	                try? await Task.sleep(nanoseconds: remaining)
  1716	            }
  1717	            guard !Task.isCancelled else { return }
  1718	            await self?.expireQueueWait(requestID: requestID)
  1719	        }
  1720	    }
  1721	
  1722	    /// Stops the timer while the request is out of `waiting` for an admission
  1723	    /// attempt. The deadline is retained so a re-queue resumes the same clock.
  1724	    private func suspendQueueWaitTimeout(requestID: String) {
  1725	        queueWaitTimeoutTasks.removeValue(forKey: requestID)?.cancel()
  1726	    }
  1727	
  1728	    /// Test hook: cancels a queued request's timeout task but keeps its
  1729	    /// absolute deadline, reproducing "deadline passed, timer not yet run"
  1730	    /// deterministically. Production code never calls it.
  1731	    func cancelQueueWaitTimerForTest(requestID: String) {
  1732	        suspendQueueWaitTimeout(requestID: requestID)
  1733	    }
  1734	
  1735	    private func endQueueWait(requestID: String) {
  1736	        queueWaitTimeoutTasks.removeValue(forKey: requestID)?.cancel()
  1737	        queueWaitDeadlines.removeValue(forKey: requestID)
  1738	    }
  1739	
  1740	    /// Bounded admission wait expiry. The request never reached a slot, so it
  1741	    /// owns no row, no block-table handle and no terminal result: the only
  1742	    /// state it leaves behind is the non-receipt diagnostic. It can never be
  1743	    /// settlement-eligible because no result is produced for it at all.
  1744	    ///
  1745	    /// Internal rather than private so a `@testable` test can drive the stale
  1746	    /// wake directly: it happens only when the timeout task reaches the actor
  1747	    /// in the same turn the pump pulls the request into admission, which
  1748	    /// cannot be forced from outside the actor.
  1749	    func expireQueueWait(requestID: String) async {
  1750	        // A timeout task can reach here after `suspendQueueWaitTimeout`
  1751	        // cancelled it: cancellation does not unschedule a task that already
  1752	        // woke. Do not touch `queueWaitDeadlines` until the request is
  1753	        // confirmed still queued and actually past its deadline. Clearing it
  1754	        // for a request that is mid-admission would strip the absolute
  1755	        // deadline, and a `capacityExceeded` bounce would then re-arm with no
  1756	        // deadline at all — the unbounded wait this bound exists to remove.
  1757	        guard let deadline = queueWaitDeadlines[requestID],
  1758	              DispatchTime.now().uptimeNanoseconds >= deadline,
  1759	              let index = waiting.firstIndex(where: { $0.id == requestID }) else { return }
  1760	        let request = waiting.remove(at: index)
  1761	        endQueueWait(requestID: requestID)
  1762	        record(.queueWaitTimedOut)
  1763	        // SPEC-038 AC-25: the durable replay claim was taken at submit, before
  1764	        // this request ever reached a slot. Nothing ran, nothing was cached,
  1765	        // nothing can settle, so the claim guards no execution — holding it
  1766	        // would answer a same-ID retry of a 503 this provider itself marked
  1767	        // `retryable: true` with a 409 instead, and churn a claim file for
  1768	        // work that never happened. Released before the waiters are resumed
  1769	        // so a retry cannot race ahead of the release.
  1770	        if let fingerprint = knownRequests[requestID] {
  1771	            replayAuthority.release(ContinuousBatchSchedulerReplayKey(
  1772	                requestID: requestID,
  1773	                fingerprintSHA256: fingerprint.sha256
  1774	            ))
  1775	        }
  1776	        knownRequests.removeValue(forKey: requestID)
  1777	        requestAdmissionSequences.removeValue(forKey: requestID)
  1778	        cancelledIDs.remove(requestID)
  1779	        let waiters = requestWaiters.removeValue(forKey: requestID) ?? []
  1780	        await discardUnacceptedRetainedCache(for: request)
  1781	        for waiter in waiters {
  1782	            waiter.delivery.finish()
  1783	            waiter.continuation.resume(throwing: ContinuousBatchSchedulerError.queueWaitTimedOut)
  1784	        }
  1785	    }
  1786	
  1787	    private func cancelWaiter(requestID: String, waiterID: UUID) async {
  1788	        CBTrace.log(requestID, "sch_cancel_waiter")
  1789	        guard stoppingWaiterIDs.insert(waiterID).inserted else { return }
  1790	        if let delivered = deliveredRetainedOwners.removeValue(forKey: waiterID) {
  1791	            stoppingWaiterIDs.remove(waiterID)
  1792	            await discardRetainedCache(delivered.retained, conversationKey: delivered.conversationKey)
  1793	            return
  1794	        }
  1795	        if let waiter = pendingTerminalDeliveries[requestID]?.waiters.first(where: { $0.id == waiterID }) {
  1796	            waiter.delivery.stop(afterStopping: {
  1797	                Task { await self.finishStoppedWaiter(requestID: requestID, waiterID: waiterID) }
  1798	            })
  1799	            return
  1800	        }
  1801	        guard var waiters = requestWaiters[requestID],
  1802	              let index = waiters.firstIndex(where: { $0.id == waiterID }) else {
  1803	            stoppingWaiterIDs.remove(waiterID)
  1804	            return
  1805	        }
  1806	        let waiter = waiters.remove(at: index)
  1807	        if waiters.isEmpty {
  1808	            requestWaiters.removeValue(forKey: requestID)
  1809	        } else {
  1810	            requestWaiters[requestID] = waiters
  1811	        }
  1812	        stoppingActiveWaiters[waiterID] = StoppingActiveWaiter(
  1813	            requestID: requestID,
  1814	            waiter: waiter,
  1815	            error: CancellationError()
  1816	        )
  1817	        waiter.delivery.stop(afterStopping: {
  1818	            Task { await self.finishStoppedWaiter(requestID: requestID, waiterID: waiterID) }
  1819	        })
  1820	    }
  1821	
  1822	    private func finishStoppedWaiter(requestID: String, waiterID: UUID) async {
  1823	        guard stoppingWaiterIDs.remove(waiterID) != nil else { return }
  1824	        if var pending = pendingTerminalDeliveries[requestID],
  1825	           pending.remainingWaiterIDs.contains(waiterID),
  1826	           let index = pending.waiters.firstIndex(where: { $0.id == waiterID }) {
  1827	            let waiter = pending.waiters.remove(at: index)
  1828	            pending.remainingWaiterIDs.remove(waiterID)
  1829	            pending.deliveryOutcomes.removeValue(forKey: waiterID)
  1830	            waiter.continuation.resume(throwing: CancellationError())
  1831	            if pending.waiters.isEmpty {
  1832	                pendingTerminalDeliveries.removeValue(forKey: requestID)
  1833	                let failedResult = ContinuousBatchSchedulerResult(
  1834	                    requestID: pending.result.requestID,
  1835	                    conversationKey: pending.result.conversationKey,
  1836	                    generatedTokens: [],
  1837	                    outputTokens: [],
  1838	                    promptTokens: pending.result.promptTokens,
  1839	                    completionTokens: 0,
  1840	                    emittedTokens: pending.result.emittedTokens,
  1841	                    cachedPromptTokens: pending.result.cachedPromptTokens,
  1842	                    terminalStatus: .requestFailed,
  1843	                    errorCode: "continuous_batching_stream_delivery_cancelled",
  1844	                    snapshot: pending.result.snapshot,
  1845	                    settlementDisposition: .notEligible,
  1846	                    retainedCache: nil
  1847	                )
  1848	                finalizeTerminalResult(requestID: requestID, result: failedResult, waiters: pending.waiters)
  1849	                if let retainedCache = pending.result.retainedCache {
  1850	                    await discardRetainedCache(
  1851	                        retainedCache.retainedSequence,
  1852	                        conversationKey: pending.result.conversationKey
  1853	                    )
  1854	                }
  1855	            } else if pending.remainingWaiterIDs.isEmpty {
  1856	                pendingTerminalDeliveries.removeValue(forKey: requestID)
  1857	                await finalizePendingTerminal(requestID: requestID, pending: pending)
  1858	            } else {
  1859	                pendingTerminalDeliveries[requestID] = pending
  1860	            }
  1861	            return
  1862	        }
  1863	        guard let stopping = stoppingActiveWaiters.removeValue(forKey: waiterID) else { return }
  1864	        stopping.waiter.continuation.resume(throwing: stopping.error)
  1865	        if !stoppingActiveWaiters.values.contains(where: { $0.requestID == requestID }),
  2805	            promptTokens: row.request.promptTokens.count,
  2806	            completionTokens: isSuccessful ? row.generatedTokens.count : 0,
  2807	            emittedTokens: row.outputTokens.count,
  2808	            cachedPromptTokens: row.request.cachedPromptTokens,
  2809	            terminalStatus: status,
  2810	            errorCode: errorCode,
  2811	            snapshot: row.snapshot,
  2812	            settlementDisposition: isSuccessful ? .eligibleOwner : .notEligible,
  2813	            retainedCache: isSuccessful ? retainedCache : nil
  2814	        )
  2815	        complete(requestID: row.request.id, result: result)
  2816	    }
  2817	
  2818	    private func complete(requestID: String, result: ContinuousBatchSchedulerResult) {
  2819	        CBTrace.log(requestID, "sch_complete status=\(result.terminalStatus) waiters=\(requestWaiters[requestID]?.count ?? 0) stopping=\(stoppingActiveWaiters.values.contains(where: { $0.requestID == requestID }))")
  2820	        endQueueWait(requestID: requestID)
  2821	        guard terminalResults[requestID] == nil, pendingTerminalDeliveries[requestID] == nil else { return }
  2822	        requestAdmissionSequences.removeValue(forKey: requestID)
  2823	        let waiters = requestWaiters.removeValue(forKey: requestID) ?? []
  2824	        if stoppingActiveWaiters.values.contains(where: { $0.requestID == requestID }) {
  2825	            deferredTerminalCompletions[requestID] = DeferredTerminalCompletion(
  2826	                result: result,
  2827	                waiters: waiters
  2828	            )
  2829	            return
  2830	        }
  2831	        beginTerminalDelivery(requestID: requestID, result: result, waiters: waiters)
  2832	    }
  2833	
  2834	    private func beginTerminalDelivery(
  2835	        requestID: String,
  2836	        result: ContinuousBatchSchedulerResult,
  2837	        waiters: [Waiter]
  2838	    ) {
  2839	        guard !waiters.isEmpty else {
  2840	            finalizeTerminalResult(requestID: requestID, result: result, waiters: [])
  2841	            if let retainedCache = result.retainedCache {
  2842	                Task {
  2843	                    await self.discardRetainedCache(
  2844	                        retainedCache.retainedSequence,
  2845	                        conversationKey: result.conversationKey
  2846	                    )
  2847	                }
  2848	            }
  2849	            return
  2850	        }
  2851	        pendingTerminalDeliveries[requestID] = PendingTerminalDelivery(
  2852	            result: result,
  2853	            waiters: waiters,
  2854	            remainingWaiterIDs: Set(waiters.map(\.id))
  2855	        )
  2856	        for waiter in waiters {
  2857	            waiter.delivery.finish(afterDraining: { delivered in
  2858	                Task {
  2859	                    await self.finishTerminalDelivery(
  2860	                        requestID: requestID,
  2861	                        waiterID: waiter.id,
  2862	                        delivered: delivered
  2863	                    )
  2864	                }
  2865	            })
  2866	        }
  2867	    }
  2868	
  2869	    private func finishTerminalDelivery(requestID: String, waiterID: UUID, delivered: Bool) async {
  2870	        guard !stoppingWaiterIDs.contains(waiterID) else {

exec
/bin/bash -lc 'rg -n "isHarmonyModelID|currentModelID|request.model|modelAlias|model.*catalog|gpt-oss" phase3-binary/Sources/macprovider-cli | head -240' in /Users/augstar/macprovider-1646-rest
 succeeded in 0ms:
phase3-binary/Sources/macprovider-cli/ControlSocket.swift:52:    case statusResponse(currentModelID: String, runtimeState: SwapState)
phase3-binary/Sources/macprovider-cli/ControlSocket.swift:72:        currentModelID: String,
phase3-binary/Sources/macprovider-cli/ControlSocket.swift:177:        case let .statusResponse(currentModelID, runtimeState):
phase3-binary/Sources/macprovider-cli/ControlSocket.swift:180:                "current_model_id": currentModelID,
phase3-binary/Sources/macprovider-cli/ControlSocket.swift:253:            currentModelID,
phase3-binary/Sources/macprovider-cli/ControlSocket.swift:261:                "current_model_id": currentModelID,
phase3-binary/Sources/macprovider-cli/ControlSocket.swift:460:                currentModelID: try stringField("current_model_id", in: object),
phase3-binary/Sources/macprovider-cli/ControlSocket.swift:559:                currentModelID: try stringField("current_model_id", in: object),
phase3-binary/Sources/macprovider-cli/ControlSocket.swift:1473:                    try await connection.send(.statusResponse(currentModelID: snapshot.modelID ?? "", runtimeState: state))
phase3-binary/Sources/macprovider-cli/ControlSocket.swift:1545:                        currentModelID: snapshot.modelID ?? "",
phase3-binary/Sources/macprovider-cli/ModelPreparationPrivateStore.swift:420:            version: "model_catalog_root_identity.v1",
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:526:    @Flag(name: .customLong("json"), help: "Emit the strict model_catalog_economics.v1 JSON contract.")
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:588:            writeStderr("models catalog-economics is JSON-only in this release; pass --json")
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:598:        let currentModelID = await readCurrentModelID(config: modelsConfig)
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:618:            currentModelID: currentModelID,
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:630:            writeStderr("models catalog-economics warning: \(warning)")
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:633:            writeStderr("models catalog-economics warning: \(warning)")
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:645:        return status.currentModelID
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:787:            // Preserve every configured supported model for the catalog. The
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:797:            if !models.contains(where: { modelIDKey($0) == modelIDKey(status.currentModelID) }) {
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:798:                models.insert(status.currentModelID, at: 0)
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:802:                    currentModelID: status.currentModelID,
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:810:                printModelsTable(currentModelID: status.currentModelID, supportedModels: models)
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:816:                    currentModelID: nil,
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:824:                printModelsTable(currentModelID: nil, supportedModels: models)
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:988:                    fromModelID: status.currentModelID,
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:1023:                        fromModelID: status.currentModelID,
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:1128:        let data = try ControlSocketCodec.encode(.statusResponse(currentModelID: status.currentModelID, runtimeState: status.runtimeState))
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:1297:        incumbentModelID = status.currentModelID
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:1298:        if modelIDKey(status.currentModelID) == modelIDKey(recommendation.targetModelID) {
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:1311:            incumbentModelID: status.currentModelID,
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:1344:                        fromModelID: status.currentModelID,
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:1454:                          modelIDKey(verifiedStatus.currentModelID) == modelIDKey(recommendation.targetModelID) else {
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:1598:    let currentModelID: String
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:1704:              let catalogKey = serveConfig["model_catalog_key"] as? String,
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:1706:              let catalogModelID = serveConfig["model_catalog_model_id"] as? String,
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:1708:              let catalogRevision = serveConfig["model_catalog_revision"] as? String,
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:1710:              let catalogSHA = serveConfig["model_catalog_sha256"] as? String,
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:1712:              let catalogVersion = serveConfig["model_catalog_version"] as? String,
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:1714:              let catalogHash = serveConfig["model_catalog_hash"] as? String,
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:1748:            modelCatalogKey: catalogKey,
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:1749:            modelCatalogModelID: catalogModelID,
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:1750:            modelCatalogRevision: catalogRevision,
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:1751:            modelCatalogSHA256: catalogSHA,
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:1752:            modelCatalogVersion: catalogVersion,
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:1753:            modelCatalogHash: catalogHash
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:1978:              row.modelID == catalogModelID,
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:2216:            currentModelID: String,
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:2221:            currentModelID: String,
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:2269:                      modelIDKey(status.currentModelID) == modelIDKey(initialStatus.currentModelID) else {
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:2288:                        guard modelIDKey(status.currentModelID) == modelIDKey(record.targetModelID) else {
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:2294:                        guard modelIDKey(status.currentModelID) == modelIDKey(record.targetModelID) else {
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:2300:                        if modelIDKey(status.currentModelID) == modelIDKey(record.targetModelID) {
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:2303:                        } else if modelIDKey(status.currentModelID) == modelIDKey(record.fromModelID) {
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:2310:                        guard modelIDKey(status.currentModelID) == modelIDKey(record.fromModelID) else {
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:2316:                        guard modelIDKey(status.currentModelID) == modelIDKey(record.fromModelID) else {
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:2333:                          modelIDKey(confirmedStatus.currentModelID) == modelIDKey(status.currentModelID) else {
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:2380:            && modelIDKey(status.currentModelID) == modelIDKey(targetModelID)
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:2454:    ) async throws -> (currentModelID: String, runtimeState: SwapState) {
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:2467:                currentModelID,
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:2475:            return (currentModelID, runtimeState)
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:2634:        guard case let .statusResponse(currentModelID, runtimeState) = frame else {
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:2638:        return (connection, ModelsStatus(currentModelID: currentModelID, runtimeState: runtimeState))
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:2655:private func printModelsTable(currentModelID: String?, supportedModels: [String]) {
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:2662:    if let currentModelID, !rows.contains(where: { modelIDKey($0) == modelIDKey(currentModelID) }) {
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:2663:        rows.insert(currentModelID, at: 0)
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:2666:        let state = currentModelID.map { modelIDKey(modelID) == modelIDKey($0) } == true ? "warm" : "idle"
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:2684:    currentModelID: String?,
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:2693:            currentModelID: currentModelID,
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:2712:    currentModelID: String?,
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:2720:    if let currentModelID {
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:2721:        let currentKey = modelIDKey(currentModelID)
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:2724:            effectiveModels[index] = currentModelID
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:2726:            effectiveModels.insert(currentModelID, at: 0)
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:2734:        let state = currentModelID.map { modelIDKey(modelID) == modelIDKey($0) } == true ? "warm" : "idle"
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:2763:        currentModelID: currentModelID,
phase3-binary/Sources/macprovider-cli/Stage2HillClimb.swift:342:    // 64-token Stage 2 cap would make gpt-oss-20b fail tuning after Stage 1
phase3-binary/Sources/macprovider-cli/Stage2HillClimb.swift:568:        // Reasoning models (gpt-oss-20b / Harmony) suppress their
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:30:    static let trustedPrepareDetail = "Download and verify this model from the trusted catalog. Preparation does not offer it to the network, change the running model, or guarantee earnings."
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:44:        data.appendLengthPrefixedUTF8("macprovider.model_catalog.root_identity.v2")
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:64:        data.appendLengthPrefixedUTF8("macprovider.model_catalog.artifact_identity.v1")
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:469:        guard identityVersion == "model_catalog_root_identity.v1" else {
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:521:        guard version == "model_catalog_root_identity.v1" else {
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:850:        schema: String = "model_catalog_preparation_tuple.v1",
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:862:        guard schema == "model_catalog_preparation_tuple.v1" else { throw ModelPreparationContractError.malformed("schema") }
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:950:        schema: String = "model_catalog_reservation.v4",
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:963:        guard schema == "model_catalog_reservation.v4" else { throw ModelPreparationContractError.malformed("schema") }
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:1087:        schema: String = "model_catalog_failed_dispatch.v1",
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:1100:        guard schema == "model_catalog_failed_dispatch.v1" else { throw ModelPreparationContractError.malformed("schema") }
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:1175:        schema: String = "model_catalog_terminal_history.v1",
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:1189:        guard schema == "model_catalog_terminal_history.v1" else { throw ModelPreparationContractError.malformed("schema") }
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:1317:        case "model_catalog_terminal_history.v1":
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:1319:        case "model_catalog_failed_dispatch.v1":
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:1346:        schema: String = "model_catalog_reservations_history.v1",
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:1350:        guard schema == "model_catalog_reservations_history.v1" else { throw ModelPreparationContractError.malformed("schema") }
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:1551:        schema: String = "model_catalog_active_attempt.v1",
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:1568:        guard schema == "model_catalog_active_attempt.v1" else { throw ModelPreparationContractError.malformed("schema") }
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:1671:        schema: String = "model_catalog_transaction_cancel_ack.v1",
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:1677:        guard schema == "model_catalog_transaction_cancel_ack.v1" else { throw ModelPreparationContractError.malformed("schema") }
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:1807:        schema: String = "model_catalog_transaction_event.v1",
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:1818:        guard schema == "model_catalog_transaction_event.v1" else { throw ModelPreparationContractError.malformed("schema") }
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:1901:        schema: String = "model_catalog_cancel_marker.v1",
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:1911:        guard schema == "model_catalog_cancel_marker.v1" else { throw ModelPreparationContractError.malformed("schema") }
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:1971:        schema: String = "model_catalog_staging_source.v1",
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:1981:        guard schema == "model_catalog_staging_source.v1" else { throw ModelPreparationContractError.malformed("schema") }
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:2069:    init(schema: String = "model_catalog_staging_sources.v1", entries: [ModelPreparationStagingSourceEntry]) throws {
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:2070:        guard schema == "model_catalog_staging_sources.v1" else { throw ModelPreparationContractError.malformed("schema") }
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:2109:        schema: String = "model_catalog_publication_receipt.v1",
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:2116:        guard schema == "model_catalog_publication_receipt.v1" else { throw ModelPreparationContractError.malformed("schema") }
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:2163:    init(schema: String = "model_catalog_published_inventory.v1", root: ModelPreparationRootLocator, targets: [ModelPreparationCleanupTarget], generatedAt: String) throws {
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:2164:        guard schema == "model_catalog_published_inventory.v1" else { throw ModelPreparationContractError.malformed("schema") }
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:2252:        schema: String = "model_catalog_cleanup_record.v2",
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:2272:        guard schema == "model_catalog_cleanup_record.v2" else { throw ModelPreparationContractError.malformed("schema") }
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:2470:        schema: String = "model_catalog_private_state_envelope.v1",
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:2478:        guard schema == "model_catalog_private_state_envelope.v1" else { throw ModelPreparationContractError.malformed("schema") }
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:3067:        case "model_catalog_preparation_tuple.v1":
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:3069:        case "model_catalog_reservation.v4":
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:3071:        case "model_catalog_failed_dispatch.v1":
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:3073:        case "model_catalog_terminal_history.v1":
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:3075:        case "model_catalog_reservations_history.v1":
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:3077:        case "model_catalog_active_attempt.v1":
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:3079:        case "model_catalog_transaction_cancel_ack.v1":
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:3081:        case "model_catalog_transaction_event.v1":
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:3083:        case "model_catalog_cancel_marker.v1":
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:3085:        case "model_catalog_staging_source.v1":
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:3087:        case "model_catalog_staging_sources.v1":
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:3089:        case "model_catalog_publication_receipt.v1":
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:3091:        case "model_catalog_published_inventory.v1":
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:3093:        case "model_catalog_cleanup_record.v2":
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:3095:        case "model_catalog_private_state_envelope.v1":
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:3104:        case "model_catalog_reservation.v4":
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:3109:        case "model_catalog_cleanup_record.v2":
phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift:3120:        case "model_catalog_staging_sources.v1":
phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift:579:    /// When `--candidate-models` is set, `--recommend` probes only catalog rows
phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift:581:    /// `--max-model-size` / `--min-model-size` trim signed catalog rows by the
phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift:621:                    "warning: --max-model-size/--min-model-size skipped catalog rows with no parseable size token: \(skippedUnparsed.sorted().joined(separator: ", "))\n".utf8
phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift:626:            throw ValidationError("model-size filters removed every signed catalog candidate")
phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift:1594:                updated.why = "\(candidate.model) is the strongest verified installed candidate from signed catalog estimates and current hardware fit."
phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift:1597:                updated.why = "\(candidate.model) is a verified installed alternative from signed catalog estimates and current hardware fit."
phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift:1645:            throw ValidationError("prefetch models are absent from the signed catalog: \(missingRows.joined(separator: ", "))")
phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift:1657:            throw ValidationError("each prefetch model must match exactly one signed catalog row")
phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift:1758:            modelCatalogKey: selected.catalogKey,
phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift:1762:            modelCatalogVersion: catalogVersion,
phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift:1763:            modelCatalogHash: catalogHash
phase3-binary/Sources/macprovider-cli/AutotuneArtifactFeed.swift:186:        // model's `artifacts` is non-empty); a release whose catalog has no
phase3-binary/Sources/macprovider-cli/AutotuneArtifactFeed.swift:412:        for key in models.keys.sorted() where catalog.rows[key] == nil {
phase3-binary/Sources/macprovider-cli/AutotuneArtifactFeed.swift:413:            throw ArtifactFeedError.integrity("artifact feed model \(key) is absent from the candidate catalog")
phase3-binary/Sources/macprovider-cli/HarmonyResponseParser.swift:12:    static func isHarmonyModelID(_ modelID: String) -> Bool {
phase3-binary/Sources/macprovider-cli/HarmonyResponseParser.swift:13:        modelID.range(of: "gpt-oss", options: [.caseInsensitive, .diacriticInsensitive]) != nil
phase3-binary/Sources/macprovider-cli/ProviderContextCommand.swift:421:    /// configured artifact for the configured model, else the signed-catalog
phase3-binary/Sources/macprovider-cli/ProviderContextCommand.swift:980:    /// configured model's alias, a target's catalog ids). A warm switch serves
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:1062:        guard !HarmonyResponseParser.isHarmonyModelID(request.model),
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:1151:    private var currentModelID: String?
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:1183:    /// artifact SHA. FR-KVP4 requires model_sha256 AND catalog revision as SEPARATE
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:1273:        currentModelID
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:1289:        currentContainer != nil || (testCompletion != nil && currentModelID != nil)
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:2010:        guard HarmonyResponseParser.isHarmonyModelID(modelID) else {
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:2029:        HarmonyResponseParser.isHarmonyModelID(modelID)
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:2067:        self.currentModelID = modelID
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:2345:        self.currentModelID = modelID
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:2491:            modelID: currentModelID,
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:2527:                modelID: currentModelID,
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:2542:            modelID: currentModelID,
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:2812:        guard currentModelID == prepared.request.expectedIncumbentModelID else {
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:2816:                actual: currentModelID
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:2882:              currentModelID == fromModelID || currentModelID == targetModelID else {
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:2944:        guard currentModelID == expectedTarget else { return false }
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:3033:        guard currentModelID == request.expectedIncumbentModelID else {
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:3036:                actual: currentModelID
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:3139:            modelID: currentModelID,
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:3352:            modelID: currentModelID,
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:3377:    /// they batch. Kept gated: Harmony (gpt-oss) models with tools or
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:3386:        if HarmonyResponseParser.isHarmonyModelID(request.model),
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:3556:        currentModelID = modelID
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:3680:        targetModelID == modelID || targetModelID == catalogModelIDAlias
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:3790:            ? modelIDAliasList(catalogModelIDAlias)
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4024:                modelID: request.model,
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4363:                        for: Self.harmonyTerminalPreservingContext(from: context, modelID: request.model)
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4389:            modelID: request.model,
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4592:                    for: Self.harmonyTerminalPreservingContext(from: context, modelID: request.model)
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4619:            modelID: request.model,
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:5084:                        modelID: request.model,
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:5089:                            let generationContext = Self.harmonyTerminalPreservingContext(from: context, modelID: request.model)
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:5117:                                modelID: request.model,
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:5130:                                    if HarmonyResponseParser.isHarmonyModelID(request.model),
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:5173:                            modelID: request.model,
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:5176:                        let parserFinishReason = HarmonyResponseParser.isHarmonyModelID(request.model)
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:5600:                    let generationContext = Self.harmonyTerminalPreservingContext(from: context, modelID: request.model)
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:5716:                        modelID: request.model,
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:5756:                    let isHarmonyResponse = HarmonyResponseParser.isHarmonyModelID(request.model)
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:5868:                            modelID: request.model,
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:5991:        guard let container = currentContainer, let servedModelID = currentModelID else { return }
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:6025:                // e.g. gpt-oss/gemma-4/nemotron). Tell the operator ONCE at attach
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:6119:            requestModel: request.model,
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:6120:            servedModelID: snapshot.modelID ?? request.model,
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:6920:        guard HarmonyResponseParser.isHarmonyModelID(request.model) else {
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:7049:            && !HarmonyResponseParser.isHarmonyModelID(request.model)
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:7077:            modelID: request.model,
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:7110:            modelID: request.model
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:7113:            chat: try ToolPromptRenderer.renderMessages(structuredMessages, modelID: request.model),
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:7537:            && !HarmonyResponseParser.isHarmonyModelID(request.model)
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:7540:            modelID: request.model,
phase3-binary/Sources/macprovider-cli/ModelArtifactDiagnostics.swift:27:    var modelID: String { catalogRow.modelID }
phase3-binary/Sources/macprovider-cli/ModelArtifactDiagnostics.swift:42:            return "unknown_model: \(key) is not a row in the signed candidate catalog"
phase3-binary/Sources/macprovider-cli/ModelArtifactDiagnostics.swift:74:            ? rateCard.value.rowForRecommendation(modelKey: catalogKey).map {
phase3-binary/Sources/macprovider-cli/ModelArtifactDiagnostics.swift:75:                rateCard.value.servedModelKey(modelKey: catalogKey, rateCardKey: $0.key)
phase3-binary/Sources/macprovider-cli/ModelArtifactDiagnostics.swift:79:        let primary = feed?.feed.models[catalogKey]?.primary
phase3-binary/Sources/macprovider-cli/ModelArtifactDiagnostics.swift:704:        abstract: "Check a model's local bytes against its signed catalog row.",
phase3-binary/Sources/macprovider-cli/ModelArtifactDiagnostics.swift:731:        let configuredPath = appConfig.modelCatalogKey == row.catalogKey ? appConfig.modelArtifactPath : nil
phase3-binary/Sources/macprovider-cli/ModelArtifactDiagnostics.swift:772:        modelRevision = catalog["model_revision"] as? String
phase3-binary/Sources/macprovider-cli/ModelArtifactDiagnostics.swift:787:        guard let modelHash, let catalogArtifactSHA256 else { return nil }
phase3-binary/Sources/macprovider-cli/ModelArtifactDiagnostics.swift:788:        return modelHash == catalogArtifactSHA256
phase3-binary/Sources/macprovider-cli/ModelArtifactDiagnostics.swift:797:            "catalog_model_id": nullable(catalogModelID),
phase3-binary/Sources/macprovider-cli/ModelArtifactDiagnostics.swift:822:            "catalog model_id:       \(catalogModelID ?? "none")",
phase3-binary/Sources/macprovider-cli/ModelArtifactDiagnostics.swift:837:        abstract: "Show the served model's buyer key, catalog row, artifact, and hash identity."
phase3-binary/Sources/macprovider-cli/ModelArtifactDiagnostics.swift:872:// MARK: - models prepare --profile catalog
phase3-binary/Sources/macprovider-cli/ModelArtifactDiagnostics.swift:940:        var command = "malibu-cli models prepare \(shellWord(catalogKey)) --repair-cache"
phase3-binary/Sources/macprovider-cli/ModelArtifactDiagnostics.swift:1156:        lines.append("model:     \(row.catalogKey) (\(row.modelID)@\(row.revision))")
phase3-binary/Sources/macprovider-cli/ModelArtifactDiagnostics.swift:1182:/// `models prepare --profile catalog` entry point, kept out of the Lane A
phase3-binary/Sources/macprovider-cli/ModelArtifactDiagnostics.swift:1197:        let configuredPath = appConfig.modelCatalogKey == row.catalogKey ? appConfig.modelArtifactPath : nil
phase3-binary/Sources/macprovider-cli/KVDiskCacheStore.swift:1105:                modelSHA256: snapshot.identity.modelSHA256, catalogRevision: snapshot.identity.catalogRevision,
phase3-binary/Sources/macprovider-cli/KVDiskCacheStore.swift:1485:                    modelSHA256: manifest.modelSHA256, catalogRevision: manifest.catalogRevision,
phase3-binary/Sources/macprovider-cli/KVDiskCacheStore.swift:1531:    private func identityFields(modelSHA256: String, catalogRevision: String, kvBits: Int?) -> [String: String] {
phase3-binary/Sources/macprovider-cli/KVDiskCacheStore.swift:1545:                         modelSHA256: String, catalogRevision: String, kvBits: Int?) {
phase3-binary/Sources/macprovider-cli/KVDiskCacheStore.swift:1551:        for (k, v) in identityFields(modelSHA256: modelSHA256, catalogRevision: catalogRevision, kvBits: kvBits) {
phase3-binary/Sources/macprovider-cli/ProviderCommand.swift:499:        let modelIDs = Set([proof.model, catalog["model_id"] as? String, catalog["catalog_key"] as? String].compactMap { $0 })
phase3-binary/Sources/macprovider-cli/ProviderCommand.swift:635:                "Verified: provider \(proof.providerID ?? "<unknown>") · model \(proof.model ?? "<unknown>") (artifact \(artifact)) · context \(proof.maxContextTokens.map(String.init) ?? "<unknown>") · slots \(proof.slots.map(String.init) ?? "<unknown>") · catalog release \(proof.catalogReleaseID ?? "<unknown>") · public feed \(proof.feedGeneratedAt ?? "<unknown>")\(lag)"
phase3-binary/Sources/macprovider-cli/HTTPServer.swift:274:        "model_catalog_json_v1",
phase3-binary/Sources/macprovider-cli/HTTPServer.swift:275:        "model_catalog_economics_v1",
phase3-binary/Sources/macprovider-cli/HTTPServer.swift:276:        "model_catalog_economics.v1",
phase3-binary/Sources/macprovider-cli/HTTPServer.swift:283:        "models catalog-economics.v1",
phase3-binary/Sources/macprovider-cli/HTTPServer.swift:284:        "model_catalog_error.v1",
phase3-binary/Sources/macprovider-cli/HTTPServer.swift:556:        Task.detached { @Sendable [providerStatus, modelRuntime, warmSwapEnabled, writer, providerID, coordinatorURL, catalogStatus, credentialStatusRuntime, admissionIdentityStatusRuntime, lifecycleStateStore, lifecycleLeaseStore, compatibilitySetManifest] in
phase3-binary/Sources/macprovider-cli/HTTPServer.swift:653:                try request.validateModelMatches(modelID, aliases: modelIDAliasList(catalogModelIDAlias))
phase3-binary/Sources/macprovider-cli/HTTPServer.swift:745:                        modelID: request.model,
phase3-binary/Sources/macprovider-cli/HTTPServer.swift:785:                                ReceiptAudit.emitIssued(providerID: providerID, requestID: auditRequestID, modelID: request.model, tokensOut: tokensOut, ttftMs: ttftMs, unixTs: unixTsSeconds)
phase3-binary/Sources/macprovider-cli/HTTPServer.swift:842:                                    ReceiptAudit.emitIssued(providerID: providerID, requestID: auditRequestID, modelID: request.model, tokensOut: 0, ttftMs: ttftMs, unixTs: unixTs)
phase3-binary/Sources/macprovider-cli/HTTPServer.swift:881:                                    ReceiptAudit.emitIssued(providerID: providerID, requestID: auditRequestID, modelID: request.model, tokensOut: 0, ttftMs: ttftMs, unixTs: unixTs)
phase3-binary/Sources/macprovider-cli/HTTPServer.swift:934:                                ReceiptAudit.emitIssued(providerID: providerID, requestID: auditRequestID, modelID: request.model, tokensOut: 0, ttftMs: ttftMs, unixTs: unixTs)
phase3-binary/Sources/macprovider-cli/HTTPServer.swift:1087:                        model: request.model,

exec
/bin/bash -lc "sed -n '620,690p;730,820p' phase3-binary/Sources/macprovider-cli/HTTPServer.swift && sed -n '1960,2045p;3635,3705p;3770,3810p' phase3-binary/Sources/macprovider-cli/ModelRuntime.swift" in /Users/augstar/macprovider-1646-rest
 succeeded in 0ms:
            )
            return
        }

        var body = bodyBuffer ?? context.channel.allocator.buffer(capacity: 0)
        let data = Data(body.readBytes(length: body.readableBytes) ?? [])
        let writer = ResponseWriter(context: context, retryAfterSeconds: queueWaitRetryAfterSeconds)
        let modelRuntime = modelRuntime
        let warmSwapEnabled = warmSwapEnabled
        let receiptBuilder = receiptBuilder
        let providerID = providerID
        let requestAcceptedAt = Date()
        let rawInboundRequestID = requestHead?.headers.first(name: "X-Request-ID")
        let inboundRequestID = rawInboundRequestID.flatMap(ChatCompletionRequest.normalizedRequestID)
        let auditRequestID = inboundRequestID ?? UUID().uuidString
        let settlementMetadata = Self.settlementMetadata(from: requestHead?.headers.first(name: Self.settlementMetadataHeaderName))
        var parsedRequest: ChatCompletionRequest?

        do {
            if rawInboundRequestID != nil, inboundRequestID == nil {
                throw APIError(
                    status: 400,
                    message: "X-Request-ID must be non-empty, at most 512 bytes, and contain no control characters",
                    code: "invalid_request_id"
                )
            }
            try Self.validateContentEncoding(requestHead?.headers["Content-Encoding"] ?? [])
            let request = try ChatCompletionRequest.parse(data: data)
                .withConversationKey(requestHead?.headers.first(name: "X-MacProvider-Provider-Conversation"))
                .withRequestID(inboundRequestID)
                .withIngestProvenance(.directHTTP)  // SPEC-037 FR-KVP11: operator direct-HTTP path
            parsedRequest = request
            if !warmSwapEnabled {
                try request.validateModelMatches(modelID, aliases: modelIDAliasList(catalogModelIDAlias))
            }

            // SPEC-038 AC-25: arm the disconnect flag before either inference
            // path starts, so a close that races the handoff is still seen.
            let disconnect = ClientDisconnectState()
            inflightDisconnects.append(disconnect)

            if request.stream {
                if settlementMetadata == nil {
                    ReceiptAudit.emitOmitted(providerID: providerID, requestID: auditRequestID, reason: .streamingRequest)
                }
                handleStreamingChatCompletions(
                    request: request,
                    writer: writer,
                    disconnect: disconnect,
                    modelRuntime: modelRuntime,
                    warmSwapEnabled: warmSwapEnabled,
                    receiptBuilder: receiptBuilder,
                    providerID: providerID,
                    requestID: auditRequestID,
                    settlementMetadata: settlementMetadata,
                    idlePrewarmer: idlePrewarmer
                )
                return
            }

            let providerStatus = providerStatus
            let idlePrewarmer = idlePrewarmer
            Task.detached { @Sendable [modelRuntime, providerStatus, request, writer, warmSwapEnabled, receiptBuilder, providerID, auditRequestID, settlementMetadata, idlePrewarmer, requestAcceptedAt, disconnect] in
                var startedAt = requestAcceptedAt
                var providerRequestStarted = false
                // SPEC-015 §M.2.2 atomic-read invariant — capture
                // the pre-snapshot for warm-swap validation, then
                // call `completeWithServedSnapshot` which returns
                // the actor-isolated snapshot the runtime used to
                // drive generation. Binding `model_hash` to the
                // SERVED snapshot (not the pre-snapshot) closes the
                            ReceiptAudit.emitOmitted(providerID: providerID, requestID: auditRequestID, reason: .writeFailed)
                        }
                        writer.close()
                        return
                    }
                    let modelHashSource = Self.resolveModelHashSource(
                        warmSwapEnabled: warmSwapEnabled,
                        snapshot: servedSnapshot,
                        settlementMetadata: settlementMetadata
                    )
                    let unixTsSeconds = Int64(Date().timeIntervalSince1970)
                    await providerStatus.finishRequest(startedAt: startedAt, completion: completion, failed: false)
                    KVCacheTelemetry.emitRequestCompleted(
                        providerID: providerID,
                        requestID: auditRequestID,
                        modelID: request.model,
                        stream: false,
                        completion: completion
                    )
                    let response = Self.chatCompletionResponse(request: request, completion: completion)
                    let ttftMs = completion.ttftMilliseconds ?? Self.elapsedMilliseconds(since: startedAt)
                    let terminalStateTSUnixMS = Int64(Date().timeIntervalSince1970 * 1000)
                    // SPEC-015 §M.2.2 — bind the receipt's
                    // `model_hash` to the runtime-served snapshot
                    // returned above by
                    // `completeWithServedSnapshot`. That snapshot
                    // was captured atomically inside the actor turn
                    // that drove generation (validation, in-flight
                    // registration, container.perform), closing the
                    // interleaving gap a separately-sampled
                    // `currentSnapshot()` would leave open.
                    let receipt = try Self.receiptHeaderResult(
                        providerID: providerID,
                        receiptBuilder: receiptBuilder,
                        request: request,
                        outputContent: completion.content,
                        outputToolCalls: completion.toolCalls,
                        finishReason: completion.finishReason,
                        promptTokens: Int64(completion.promptTokens),
                        ttftMs: ttftMs,
                        tokensOut: Int64(completion.generatedCompletionTokens),
                        unixTsSeconds: unixTsSeconds,
                        modelHashSource: modelHashSource,
                        requestID: auditRequestID,
                        settlementMetadata: settlementMetadata,
                        runtimeSettlementEligible: modelRuntime.isSettlementReceiptEligible,
                        settlementRuntimeSource: modelRuntime.settlementRuntimeSource,
                        settlementDisposition: completion.settlementDisposition,
                        terminalStateTSUnixMS: terminalStateTSUnixMS
                    )
                    switch receipt {
                    case .issued(let header):
                        let tokensOut = Int64(completion.generatedCompletionTokens)
                        writer.writeJSON(status: .ok, body: response, extraHeaders: Self.receiptExtraHeaders(header: header, settlementMetadata: settlementMetadata, terminalStateTSUnixMS: terminalStateTSUnixMS)) { delivered in
                            if delivered {
                                ReceiptAudit.emitIssued(providerID: providerID, requestID: auditRequestID, modelID: request.model, tokensOut: tokensOut, ttftMs: ttftMs, unixTs: unixTsSeconds)
                            } else {
                                ReceiptAudit.emitOmitted(providerID: providerID, requestID: auditRequestID, reason: .writeFailed)
                            }
                        }
                    case .omitted(let reason):
                        ReceiptAudit.emitOmitted(providerID: providerID, requestID: auditRequestID, reason: reason)
                        writer.writeJSON(status: .ok, body: response)
                    }
	                } catch is CancellationError {
	                    CBTrace.log(auditRequestID, "http_catch_cancellation")
	                    // SPEC-038 AC-25 (`:620`) and #1690: the buyer closed
	                    // the connection, a buyer cancel and never a provider
	                    // failure. A non-streaming request has emitted nothing
	                    // buyer-visible yet, so this is always the
	                    // before-first-token case: one terminal outcome,
	                    // non-settling, no receipt. The scheduler slot and any
	                    // block-table reservation are already released —
	                    // `shouldCancel` unwinds `submit()` through its
	                    // `withTaskCancellationHandler`, which runs
	                    // `cancelWaiter`.
	                    if providerRequestStarted {
	                        await providerStatus.finishRequest(startedAt: startedAt, completion: nil, failed: false)
	                    }
	                    ReceiptAudit.emitOmitted(providerID: providerID, requestID: auditRequestID, reason: .preTokenCancel)
	                    if disconnect.isDisconnected {
	                        // Nothing is written to the closed socket.
	                        writer.close()
	                    } else {
	                        writer.writeAPIError(Self.buyerCancelledError())
	                    }
	                } catch is DrainCancelledError {
	                    CBTrace.log(auditRequestID, "http_catch_drain")
	                    if providerRequestStarted {
	                        await providerStatus.finishRequest(startedAt: startedAt, completion: nil, failed: true)
	                    }
        }
        let expertKeys = [
            "num_experts",
            "n_routed_experts",
            "num_local_experts",
            "num_experts_per_tok",
            "moe_intermediate_size",
        ]
        return expertKeys.contains { key in
            if let value = object[key] as? Int { return value > 1 }
            if let value = object[key] as? NSNumber { return value.intValue > 1 }
            return false
        }
    }

    private nonisolated static func pagedKVModelIDLooksLikeExpertModel(_ modelID: String?) -> Bool {
        guard let modelID else { return false }
        let lower = modelID.lowercased()
        if lower.contains("mixtral") || lower.contains("moe") { return true }
        return lower.range(of: #"(^|[-_/])a[0-9]+b($|[-_/])"#, options: .regularExpression) != nil
    }

    nonisolated static func logPagedKVAttachDecision(_ decision: PagedKVAttachDecision) {
        switch decision {
        case .disabled, .attached:
            return
        case .fallback(let reason):
            FileHandle.standardError.write(Data(("event=paged_kv_attach status=fallback reason=\(reason.rawValue)\n").utf8))
        case .rejected(let reason):
            FileHandle.standardError.write(Data(("event=paged_kv_attach status=rejected reason=\(reason.rawValue)\n").utf8))
        }
    }

    nonisolated static func enforcePagedKVPreflight(_ decision: PagedKVAttachDecision) throws {
        if case .rejected = decision {
            throw APIError(
                status: 503,
                message: "Inference engine unavailable",
                type: "server_error",
                code: "internal_error",
                inferenceRan: false,
                settlementRan: false
            )
        }
    }

    private nonisolated static func harmonyTerminalPreservingContext(
        from context: ModelContext,
        modelID: String
    ) -> ModelContext {
        guard HarmonyResponseParser.isHarmonyModelID(modelID) else {
            return context
        }
        var generationContext = context
        generationContext.configuration.eosTokenIds.remove(HarmonyResponseParser.returnTokenID)
        generationContext.configuration.eosTokenIds.remove(HarmonyResponseParser.callTokenID)
        generationContext.configuration.extraEOSTokens.remove("<|return|>")
        generationContext.configuration.extraEOSTokens.remove("<|call|>")
        generationContext.configuration.stopStrings?.remove("<|return|>")
        generationContext.configuration.stopStrings?.remove("<|call|>")
        generationContext.tokenizer = HarmonyTerminalPreservingTokenizer(base: context.tokenizer)
        return generationContext
    }

    private nonisolated static func isHarmonyTerminalToken(_ tokenID: Int) -> Bool {
        tokenID == HarmonyResponseParser.returnTokenID || tokenID == HarmonyResponseParser.callTokenID
    }

    static func isHarmonyTerminalFinish(modelID: String, generatedTokenIDs: [Int]) -> Bool {
        HarmonyResponseParser.isHarmonyModelID(modelID)
            && generatedTokenIDs.last.map(isHarmonyTerminalToken) == true
    }

    init(
        modelID: String?,
        modelLoadPath: String? = nil,
        draftModelID: String? = nil,
        draftModelLoadPath: String? = nil,
        numDraftTokens: Int = 3,
        speculativeCacheWrapValidated: Bool = false,
        maxContextTokensOverride: Int? = nil,
        kvBitsOverride: Int? = nil,
        pagedKVConfig: PagedKVConfig = .defaults(),
        prefillStepSize: Int = 512,
        maxBatch: Int = 1,
        continuousBatchingMode: ContinuousBatchingMode = .off,
                modelCapabilities: modelCapabilities,
                observedRuntimeIdentity: pagedKVObservedRuntimeIdentity,
                hardwareSizingProof: pagedKVHardwareSizingProof,
                schedulerBackendInstalled: false
            )
        }
        Self.logPagedKVAttachDecision(pagedKVAttachDecision)
        currentDraftModelID = draftModelID
        currentDraftTargetModelID = draftModelID == nil ? nil : modelID
        currentDraftContainer = draftContainer
        state = .ready
        targetModelID = nil
        if let draftFailureReason {
            Self.logDraftSwapFailure(
                targetModelID: modelID,
                draftModelID: configuredDraftModelID,
                reason: draftFailureReason
            )
        }
        await providerStatus?.completeTargetSwap(
            modelID: modelID,
            modelHash: modelHash,
            modelHashAlgorithm: currentModelHashAlgorithm,
            weightsManifestSHA256: weightsManifestSHA256,
            maxContextTokens: adoptionKnobs?.maxContext,
            maxContextSource: adoptionKnobs?.contextSource,
            maxConcurrency: adoptionKnobs?.maxBatch,
            specDecodeDraftModelID: speculativeCacheWrapValidated ? draftModelID : nil,
            specDecodeNumDraftTokens: speculativeCacheWrapValidated && draftModelID != nil ? numDraftTokens : nil
        )
        signal(SwapSignal(targetModelID: target, outcome: .completed(newModelID: modelID, newModelHash: modelHash)))
    }

    private func failSwap(reason: String) {
        guard state == .loading || state == .draining else {
            return
        }
        let target = targetModelID ?? ""
        state = .failed
        signal(SwapSignal(targetModelID: target, outcome: .failed(reason: reason)))
        state = .ready
        targetModelID = nil
    }

    private func isConfiguredCatalogModel(_ targetModelID: String) -> Bool {
        targetModelID == modelID || targetModelID == catalogModelIDAlias
    }

    private func targetAuthority(for targetModelID: String) -> ModelRuntimeTargetAuthority? {
        if let authority = targetAuthorities[targetModelID]
            ?? targetAuthorities[targetModelID.lowercased(with: nil)] {
            return authority
        }
        guard isConfiguredCatalogModel(targetModelID),
              let artifactSHA256 = verifiedCatalogArtifactSHA256,
              let catalogRevision = verifiedModelCatalogRevision else {
            return nil
        }
        return ModelRuntimeTargetAuthority(
            modelArgument: configuredModelLoadPath ?? targetModelID,
            artifactSHA256: artifactSHA256,
            catalogRevision: catalogRevision
        )
    }

    private nonisolated static func logDraftSwapFailure(targetModelID: String?, draftModelID: String?, reason: String) {
        let payload: [String: Any] = [
            "draft_model_id": redactedOperatorModelID(draftModelID) ?? NSNull(),
            "event": "spec_decode_draft_swap_failed",
            "reason": reason,
            "spec_decode_enabled": false,
    private func cancelAllInFlightForDrainTimeout() {
        let cancels = Array(inFlightCancellations.values)
        inFlightCancellations.removeAll()
        for cancel in cancels {
            cancel()
        }
    }

    private func removeSignalContinuation(_ id: UUID) {
        signalContinuations.removeValue(forKey: id)
    }

    func acquireRequestHandle(_ request: ChatCompletionRequest) throws -> RequestHandle {
        let snapshot = requestStartSnapshot()
        try Self.validateReady(snapshot.state)
        // Accept the coordinator-advertised catalog id as an alias only while the
        // configured model is the one currently loaded (mirrors
        // coordinatorWireModelID's servedModelID == loadedModelID guard). After a
        // warm-swap to a different model the alias must not apply.
        let aliases = (snapshot.modelID != nil && snapshot.modelID == self.modelID)
            ? modelIDAliasList(catalogModelIDAlias)
            : []
        try request.validateModelMatches(snapshot.modelID, aliases: aliases)
        try Self.validateToolChoiceScope(request)
        let drainCancelled = DrainCancelToken()
        let registrationID = registerInFlight { drainCancelled.fire() }
        return RequestHandle(
            snapshot: snapshot,
            registrationID: registrationID,
            drainCancelled: drainCancelled
        )
    }

    func preflight(_ request: ChatCompletionRequest, with handle: RequestHandle) async throws {
        // SPEC-025 §5.2: the streaming path runs preflight (prompt prepare inside
        // container.perform — real model-thread work) before stream() brackets
        // active inference. Bracket it here too so a pre-first-token wedge during
        // preflight is observable (active_inference true) rather than reading idle.
        ModelLivenessTracker.shared.beginInference()
        defer { ModelLivenessTracker.shared.endInference() }
        _ = try applyContinuousBatchingPolicy(request: request, snapshot: handle.snapshot)

exec
/bin/bash -lc 'rg -n "modelIDAliasList|catalogModelIDAlias|model_id_alias|catalog_model_id" phase3-binary/Sources/macprovider-cli/ModelRuntime.swift phase3-binary/Sources/macprovider-cli/ProviderContextCommand.swift phase3-binary/Sources/macprovider-cli/*.swift | head -160' in /Users/augstar/macprovider-1646-rest
 succeeded in 0ms:
phase3-binary/Sources/macprovider-cli/ModelArtifactDiagnostics.swift:539:            "- catalog_model_id: \(row.modelID)",
phase3-binary/Sources/macprovider-cli/ModelArtifactDiagnostics.swift:591:            "catalog_model_id": row.modelID,
phase3-binary/Sources/macprovider-cli/ModelArtifactDiagnostics.swift:797:            "catalog_model_id": nullable(catalogModelID),
phase3-binary/Sources/macprovider-cli/ModelArtifactDiagnostics.swift:914:            "catalog_model_id": row.modelID,
phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:1706:              let catalogModelID = serveConfig["model_catalog_model_id"] as? String,
phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift:1871:            catalogModelIDAlias: catalogModelIDForCoordinator,
phase3-binary/Sources/macprovider-cli/ConfigApplier.swift:581:            "model_catalog_model_id": recommendation.modelCatalogModelID.map(Self.yamlScalar),
phase3-binary/Sources/macprovider-cli/ConfigApplier.swift:683:        "model_catalog_model_id",
phase3-binary/Sources/macprovider-cli/ConfigApplier.swift:709:            "model_catalog_model_id",
phase3-binary/Sources/macprovider-cli/HTTPServer.swift:112:    let catalogModelIDAlias: String?
phase3-binary/Sources/macprovider-cli/HTTPServer.swift:127:        catalogModelIDAlias: String? = nil,
phase3-binary/Sources/macprovider-cli/HTTPServer.swift:142:        self.catalogModelIDAlias = catalogModelIDAlias
phase3-binary/Sources/macprovider-cli/HTTPServer.swift:186:                            catalogModelIDAlias: catalogModelIDAlias,
phase3-binary/Sources/macprovider-cli/HTTPServer.swift:324:    private let catalogModelIDAlias: String?
phase3-binary/Sources/macprovider-cli/HTTPServer.swift:367:        catalogModelIDAlias: String? = nil,
phase3-binary/Sources/macprovider-cli/HTTPServer.swift:386:        self.catalogModelIDAlias = catalogModelIDAlias
phase3-binary/Sources/macprovider-cli/HTTPServer.swift:653:                try request.validateModelMatches(modelID, aliases: modelIDAliasList(catalogModelIDAlias))
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:1159:    // relay_serve_model_id_alias.
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:1160:    private let catalogModelIDAlias: String?
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:2053:        catalogModelIDAlias: String? = nil,
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:2066:        self.catalogModelIDAlias = catalogModelIDAlias
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:2318:        catalogModelIDAlias: String? = nil,
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:2344:        self.catalogModelIDAlias = catalogModelIDAlias
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:3680:        targetModelID == modelID || targetModelID == catalogModelIDAlias
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:3790:            ? modelIDAliasList(catalogModelIDAlias)
phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift:3049:        {"model":\(core.model.jsonEscaped),"model_artifact_path":\((core.modelArtifactPath ?? "").jsonEscaped),"model_artifact_sha256":\((core.modelArtifactSHA256 ?? "").jsonEscaped),"model_catalog_key":\((core.modelCatalogKey ?? "").jsonEscaped),"model_catalog_model_id":\((core.modelCatalogModelID ?? "").jsonEscaped),"model_catalog_revision":\((core.modelCatalogRevision ?? "").jsonEscaped),"model_catalog_sha256":\((core.modelCatalogSHA256 ?? "").jsonEscaped),"model_catalog_version":\((core.modelCatalogVersion ?? "").jsonEscaped),"model_catalog_hash":\((core.modelCatalogHash ?? "").jsonEscaped),"kv_bits":\(kvBits),"max_context_override":\(core.knobs.maxContext),"max_concurrency_override":\(core.knobs.maxBatch),"donor_mode":\(donorMode)}
phase3-binary/Sources/macprovider-cli/OpenAICompatibleLoopbackRuntime.swift:751:    private let catalogModelIDAlias: String?
phase3-binary/Sources/macprovider-cli/OpenAICompatibleLoopbackRuntime.swift:775:        catalogModelIDAlias: String? = nil,
phase3-binary/Sources/macprovider-cli/OpenAICompatibleLoopbackRuntime.swift:798:        self.catalogModelIDAlias = catalogModelIDAlias.flatMap { value in
phase3-binary/Sources/macprovider-cli/OpenAICompatibleLoopbackRuntime.swift:840:        catalogModelIDAlias: String? = nil,
phase3-binary/Sources/macprovider-cli/OpenAICompatibleLoopbackRuntime.swift:872:            catalogModelIDAlias: catalogModelIDAlias,
phase3-binary/Sources/macprovider-cli/OpenAICompatibleLoopbackRuntime.swift:888:        catalogModelIDAlias: String? = nil,
phase3-binary/Sources/macprovider-cli/OpenAICompatibleLoopbackRuntime.swift:923:            catalogModelIDAlias: catalogModelIDAlias,
phase3-binary/Sources/macprovider-cli/OpenAICompatibleLoopbackRuntime.swift:963:        try request.validateModelMatches(servedModelRef, aliases: modelIDAliasList(catalogModelIDAlias))
phase3-binary/Sources/macprovider-cli/OpenAICompatibleLoopbackRuntime.swift:992:        try request.validateModelMatches(servedModelRef, aliases: modelIDAliasList(catalogModelIDAlias))
phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:9:func modelIDAliasList(_ value: String?) -> [String] {
phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:27:    private let catalogModelIDAlias: String?
phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:46:        catalogModelIDAlias: String? = nil,
phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:61:        self.catalogModelIDAlias = catalogModelIDAlias
phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:254:        let task = Task { [weak self, modelRuntime, providerStatus, loadedModelID, catalogModelIDAlias, warmSwapEnabled, sendFrame, tier2Session, state, settlementMetadata, streamInterval, relayBlindRuntime] in
phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:263:                catalogModelIDAlias: catalogModelIDAlias,
phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:412:        catalogModelIDAlias: String?,
phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:457:                    ? modelIDAliasList(catalogModelIDAlias)
phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:499:                    ? modelIDAliasList(catalogModelIDAlias)
phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift:960:    /// (`model_catalog_key` + `model_catalog_model_id`) is a Trusted Pool
phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift:999:            FileHandle.standardError.write(Data("loopback model_catalog_key/model_catalog_model_id is not a recommendable row of the signed candidate catalog\n".utf8))
phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift:2068:        let catalogModelIDAlias: String? = resolved.modelCatalogModelID.flatMap { value in
phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift:2121:            configuredModelIDs: [resolved.model, catalogModelIDAlias].compactMap { $0 },
phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift:2127:            configuredModelIDs: [resolved.model, catalogModelIDAlias].compactMap { $0 },
phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift:2133:            configuredModelIDs: [resolved.model, catalogModelIDAlias].compactMap { $0 },
phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift:2188:                        catalogModelIDAlias: catalogModelIDAlias
phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift:2198:                        catalogModelIDAlias: catalogModelIDAlias
phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift:2208:                        catalogModelIDAlias: catalogModelIDAlias
phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift:2237:                    catalogModelIDAlias: catalogModelIDAlias,
phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift:2819:            catalogModelIDAlias: catalogModelIDAlias,
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:1159:    // relay_serve_model_id_alias.
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:1160:    private let catalogModelIDAlias: String?
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:2053:        catalogModelIDAlias: String? = nil,
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:2066:        self.catalogModelIDAlias = catalogModelIDAlias
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:2318:        catalogModelIDAlias: String? = nil,
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:2344:        self.catalogModelIDAlias = catalogModelIDAlias
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:3680:        targetModelID == modelID || targetModelID == catalogModelIDAlias
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:3790:            ? modelIDAliasList(catalogModelIDAlias)

exec
/bin/bash -lc "sed -n '1,35p;2050,2145p' phase3-binary/Sources/macprovider-cli/InferenceRelay.swift phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift" in /Users/augstar/macprovider-1646-rest
 succeeded in 0ms:
import Foundation
import MacProviderCore

/// Normalizes an optional catalog-alias string into the `aliases:` array shape
/// expected by `ChatCompletionRequest.validateModelMatches`. Trims whitespace
/// and newlines to match the normalization applied to
/// `catalogModelIDForCoordinator` in CoordinatorClient (see lines 324-327);
/// returns `[]` for nil/empty so the default no-alias behavior is preserved.
func modelIDAliasList(_ value: String?) -> [String] {
    guard let value else { return [] }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? [] : [trimmed]
}

actor InferenceRelay {
    typealias SendFrame = @Sendable (sending [String: Any]) async throws -> Void
    typealias TrustDemotion = @Sendable (_ reason: String) async -> Void

    private struct ActiveRequest {
        let task: Task<Void, Never>
        let state: RelayRequestState
    }

    private let modelRuntime: any ModelRuntimeServing
    private let providerStatus: ProviderStatus
    private let loadedModelID: String?
    private let catalogModelIDAlias: String?
    private let warmSwapEnabled: Bool
    private let fallbackMaxActiveRequests: Int
    private let maxBodyBytes: Int
    private let sendFrame: SendFrame
    private let tier2Session: Tier2ProviderSession?
    private let receiptBuilder: ReceiptBuilder?
    private let receiptProviderID: String?
    private let demoteAutoupdateTrust: TrustDemotion?

    @Option(help: "Log level: trace, debug, info, notice, warning, error, critical.")
    var logLevel: String?

    @Option(help: "Comma-separated list of HuggingFace model IDs (or local paths) this provider can serve. Overrides MACPROVIDER_SUPPORTED_MODELS and config key supported_models. When unset, only the configured model is advertised.")
    var supportedModels: String?

    @Flag(name: .customLong("publish-supported-models"), inversion: .prefixedNo, help: "Opt into publishing the supported model list to the network status service. Default off.")
    var publishSupportedModels: Bool?

    @Flag(name: .customLong("enable-warm-swap"), inversion: .prefixedNo, help: "Opt into switching models without a full provider restart. Default off. When off, no model-control socket is opened.")
    var enableWarmSwap: Bool?

    @Flag(name: .customLong("enable-receipts"), inversion: .prefixedNo, help: "Opt into signed non-streaming request receipts. Default off for staged rollout.")
    var enableReceipts: Bool?

    @Flag(name: .customLong("relay-blind-enabled"), inversion: .prefixedNo, help: "Opt into the default-off relay-blind request encryption pilot.")
    var relayBlindEnabled: Bool?

    @Option(name: .customLong("relay-blind-state-directory"), help: "Absolute operator-owned 0700 directory outside the repository for relay-blind keys and execution journal.")
    var relayBlindStateDirectory: String?

    @Option(help: "Drain timeout in seconds for an in-flight model switch. Default 30. Only meaningful when --enable-warm-swap is set.")
    var swapDrainTimeoutSeconds: Int?

    @Option(help: "Control socket path. Overrides MACPROVIDER_CTL_SOCKET_PATH and config ctl_socket_path. Default $TMPDIR/macprovider-cli/ctl.sock. Only meaningful when --enable-warm-swap is set.")
    var ctlSocketPath: String?

    // Phase 1E reads/writes this path for the cooldown soft guard; Phase 1C only plumbs it.
    @Option(help: "CLI-side cooldown state file. Overrides MACPROVIDER_SWITCH_STATE_PATH and config switch_state_path. Default $HOME/Library/Application Support/macprovider-cli/last-switch.ts. Cooldown soft guard lands in Phase 1E.")
    var switchStatePath: String?

    @Option(name: [.customLong("provider-token"), .customLong("token")], help: "Deprecated inline provider token. This is rejected because argv is visible to same-user process inspection; use MACPROVIDER_PROVIDER_TOKEN, provider_token in a 0600 config file, or --token-file.")
    var providerToken: String?

    @Option(help: "Read provider authentication token from a 0600 file. Overrides MACPROVIDER_PROVIDER_TOKEN and config key provider_token without exposing the token in process arguments.")
    var tokenFile: String?

    @Option(help: "Provider credential store: keychain or protected_file. Defaults to keychain. Overrides MACPROVIDER_CREDENTIAL_STORE and config key credential_store.")
    var credentialStore: String?

    @Option(help: "Records the installation origin for diagnostics. This never transfers lifecycle, credential, identity, or update authority away from the launchd-managed CLI. Overrides MACPROVIDER_MANAGED_BY and config key managed_by.")
    var managedBy: String?

    @Option(help: "KV-cache quantization precision in bits (4 or 8). When set, forwarded to mlx-swift GenerateParameters.kvBits — quantizes the KV cache to reduce per-token memory footprint at a small accuracy cost. Unset (default) keeps the mlx-swift default of no KV quantization. Overrides MACPROVIDER_KV_BITS and config key kv_bits.")
    var kvBits: Int?

    @Option(help: "Maximum prompt context length (tokens) this provider will accept. Prompts whose tokenized length exceeds this cap are rejected with HTTP 413 context_length_exceeded. Also wired to mlx-swift GenerateParameters.maxKVSize, capping KV-cache allocation. Unset defers to the per-tier default (8GB:20000, 16GB:50000, 32GB:120000, 64GB+:200000). Overrides MACPROVIDER_MAX_CONTEXT_OVERRIDE and config key max_context_override.")
    var maxContext: Int?

    @Option(help: "Maximum concurrent in-flight inferences. Defaults to 1 (single-slot, the only safe value while mlx-swift parallel generation remains unproven). Lifting this above 1 is an autotune knob — the binary itself does not enforce safety beyond the AsyncSemaphore. Overrides MACPROVIDER_MAX_CONCURRENCY_OVERRIDE and config key max_concurrency_override.")
    var maxBatch: Int?

    @Flag(name: .customLong("idle-prewarm"), inversion: .prefixedNo, help: "Enable provider-side idle MLX Metal prewarm. Default on.")
    var idlePrewarm: Bool?

    @Option(name: .customLong("idle-prewarm-idle-threshold-s"), help: "Seconds of no real requests before idle prewarm may fire. Default 30; range 5...3600.")
    var idlePrewarmIdleThresholdSeconds: Double?

    @Option(name: .customLong("idle-prewarm-tick-s"), help: "Idle prewarm check interval in seconds. Default 5; range 1...60.")
    var idlePrewarmTickSeconds: Double?

    @Option(name: .customLong("idle-prewarm-max-tokens"), help: "Synthetic warmup max tokens. Default 1; range 1...8.")
    var idlePrewarmMaxTokens: Int?

    @Option(name: .customLong("idle-prewarm-prompt"), help: "Synthetic warmup prompt. Default 'warm'; range 1...64 UTF-8 bytes.")
    var idlePrewarmPrompt: String?

    @Flag(name: .customLong("idle-prewarm-on-battery"), inversion: .prefixedNo, help: "Allow idle prewarm while running on battery. Default off.")
    var idlePrewarmRunOnBattery: Bool?

    @Option(help: "Number of content-token deltas to accumulate before emitting one SSE/WS frame. Default 1 (one frame per token, current behaviour). Set to 4 to match upstream production batching — reduces WS send calls by ~75% with first-chunk latency ≤ N token periods. Overrides MACPROVIDER_STREAM_INTERVAL and config key stream_interval.")
    var streamInterval: Int?

    @Option(
        name: .customLong("prefill-step-size"),
        help: "Chunked prefill window (mlx-swift GenerateParameters.prefillStepSize). Default 512. Larger values (e.g. 2048, 4096) reduce TTFT on long cold prefills. Overrides MACPROVIDER_PREFILL_STEP_SIZE and config key prefill_step_size."
    )
    var prefillStepSize: Int?

    @Option(help: "Continuous batching mode: off, canary, or on. Default off. Strict on fails closed unless the requested tuple is both advertised by the local paged-KV engine and listed under config key continuous_batching_accepted_tuples; canary serial-routes with reason tuple_acceptance_coverage_unavailable instead. Overrides MACPROVIDER_CONTINUOUS_BATCHING and config key continuous_batching.")
    var continuousBatching: String?

    @Option(help: "Bounded continuous-batching waiting queue limit. Default 2 * active slots. Overrides MACPROVIDER_CONTINUOUS_BATCH_QUEUE_LIMIT and config key continuous_batch_queue_limit.")
    var continuousBatchQueueLimit: Int?

    @Option(help: "Bounded continuous-batching admission wait in milliseconds. Default 30000. A request still queued when it expires is rejected pre-admission and never settles. Overrides MACPROVIDER_CONTINUOUS_BATCH_QUEUE_WAIT_TIMEOUT_MS and config key continuous_batch_queue_wait_timeout_ms.")
    var continuousBatchQueueWaitTimeoutMS: Int?

    @Flag(name: .customLong("continuous-batching-cached-turns"), inversion: .prefixedNo, help: "Let a positive-cached follow-up turn with a usable retained paged-KV handoff (plus a recurrent checkpoint on hybrid models) batch instead of serial-routing. Default off. Inert while continuous batching is off. Overrides MACPROVIDER_CONTINUOUS_BATCHING_CACHED_TURNS and config key continuous_batching_cached_turns.")
    var continuousBatchingCachedTurns: Bool?

    // SPEC-037 FR-KVP11 — encrypted KV survival disk-tier CLI flags (MEDIUM-5). Each is
    // an Optional so absence defers to the environment / YAML / default; the resolver
    // (KVDiskCacheConfigResolver) applies CLI-wins precedence and fails closed on any
    // invalid value. --kv-disk-cache-allow-buyer-keys reaching the resolver as true is

codex
The committed tests pass for the row-finalize suite (9 discovered tests) and the scheduler/routing selection (95 tests, 4 pre-existing metallib skips). I found one replay-specific money-path defect to validate against the scheduler’s duplicate-waiter contract: a replay can feed the entire accumulated row to a fresh tool-stop parser, losing the original first-call token boundary.
exec
/bin/bash -lc "rg -n \"func validateModelMatches|validateModelMatches\\(\" phase3-binary/Sources MacProviderCore | head -60" in /Users/augstar/macprovider-1646-rest
 succeeded in 0ms:
rg: MacProviderCore: No such file or directory (os error 2)
phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift:299:    public func validateModelMatches(_ loadedModel: String?, aliases: [String] = []) throws {
phase3-binary/Sources/macprovider-cli/HTTPServer.swift:653:                try request.validateModelMatches(modelID, aliases: modelIDAliasList(catalogModelIDAlias))
phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:460:                    try request.validateModelMatches(preparedModelID, aliases: relayAliases)
phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:501:                try request.validateModelMatches(validationModelID, aliases: relayAliases)
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:3792:        try request.validateModelMatches(snapshot.modelID, aliases: aliases)
phase3-binary/Sources/macprovider-cli/OpenAICompatibleLoopbackRuntime.swift:963:        try request.validateModelMatches(servedModelRef, aliases: modelIDAliasList(catalogModelIDAlias))
phase3-binary/Sources/macprovider-cli/OpenAICompatibleLoopbackRuntime.swift:992:        try request.validateModelMatches(servedModelRef, aliases: modelIDAliasList(catalogModelIDAlias))

exec
/bin/bash -lc "sed -n '280,325p' phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift && sed -n '2040,2080p' phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift && git status -sb" in /Users/augstar/macprovider-1646-rest
 succeeded in 57ms:
## campaign/1646-remaining...origin/main [ahead 2]
 M phase3-binary/Package.resolved
?? audits/2026-09-25-cb-tools-structured/

exec
/bin/bash -lc "git diff -- Package.resolved | sed -n '1,160p' && git diff --numstat -- Package.resolved" in /Users/augstar/macprovider-1646-rest
 succeeded in 43ms:
exec
/bin/bash -lc "git status --porcelain=v2 && git diff --raw -- Package.resolved && git ls-files -v Package.resolved && stat -f '%m %z %N' Package.resolved" in /Users/augstar/macprovider-1646-rest
 exited 1 in 190ms:
1 .M N... 100644 100644 100644 8d3b0b6fd9c44023cc538cc2b217e0d36a8dd6e0 8d3b0b6fd9c44023cc538cc2b217e0d36a8dd6e0 phase3-binary/Package.resolved
? audits/2026-09-25-cb-tools-structured/
stat: Package.resolved: stat: No such file or directory

exec
/bin/bash -lc "git diff -- phase3-binary/Package.resolved | sed -n '1,200p'; stat -f '%m %z %N' phase3-binary/Package.resolved" in /Users/augstar/macprovider-1646-rest
 succeeded in 96ms:
diff --git a/phase3-binary/Package.resolved b/phase3-binary/Package.resolved
index 8d3b0b6fd..bb1482bc9 100644
--- a/phase3-binary/Package.resolved
+++ b/phase3-binary/Package.resolved
@@ -1,14 +1,5 @@
 {
   "pins" : [
-    {
-      "identity" : "async-http-client",
-      "kind" : "remoteSourceControl",
-      "location" : "https://github.com/swift-server/async-http-client.git",
-      "state" : {
-        "revision" : "f95c908967e98c68c5ce3fd61a7974e7e869e303",
-        "version" : "1.36.1"
-      }
-    },
     {
       "identity" : "eventsource",
       "kind" : "remoteSourceControl",
@@ -36,15 +27,6 @@
         "version" : "3.31.4"
       }
     },
-    {
-      "identity" : "swift-algorithms",
-      "kind" : "remoteSourceControl",
-      "location" : "https://github.com/apple/swift-algorithms.git",
-      "state" : {
-        "revision" : "87e50f483c54e6efd60e885f7f5aa946cee68023",
-        "version" : "1.2.1"
-      }
-    },
     {
       "identity" : "swift-argument-parser",
       "kind" : "remoteSourceControl",
@@ -63,15 +45,6 @@
         "version" : "1.7.2"
       }
     },
-    {
-      "identity" : "swift-async-algorithms",
-      "kind" : "remoteSourceControl",
-      "location" : "https://github.com/apple/swift-async-algorithms.git",
-      "state" : {
-        "revision" : "3da39bbc4e687d4192af7c9cf4eab805745a0b9c",
-        "version" : "1.1.5"
-      }
-    },
     {
       "identity" : "swift-atomics",
       "kind" : "remoteSourceControl",
@@ -81,15 +54,6 @@
         "version" : "1.3.1"
       }
     },
-    {
-      "identity" : "swift-certificates",
-      "kind" : "remoteSourceControl",
-      "location" : "https://github.com/apple/swift-certificates.git",
-      "state" : {
-        "revision" : "c8aece90ea05f9866bd392a5bf13b5cae56c0e03",
-        "version" : "1.20.0"
-      }
-    },
     {
       "identity" : "swift-collections",
       "kind" : "remoteSourceControl",
@@ -108,33 +72,6 @@
         "version" : "4.5.1"
       }
     },
-    {
-      "identity" : "swift-distributed-tracing",
-      "kind" : "remoteSourceControl",
-      "location" : "https://github.com/apple/swift-distributed-tracing.git",
-      "state" : {
-        "revision" : "dc4030184203ffafbb2ec614352487235d747fe0",
-        "version" : "1.4.1"
-      }
-    },
-    {
-      "identity" : "swift-http-structured-headers",
-      "kind" : "remoteSourceControl",
-      "location" : "https://github.com/apple/swift-http-structured-headers.git",
-      "state" : {
-        "revision" : "933538faa42c432d385f02e07df0ace7c5ecfc47",
-        "version" : "1.7.0"
-      }
-    },
-    {
-      "identity" : "swift-http-types",
-      "kind" : "remoteSourceControl",
-      "location" : "https://github.com/apple/swift-http-types.git",
-      "state" : {
-        "revision" : "db774a277f60063a32d854f2980299caf06da041",
-        "version" : "1.6.0"
-      }
-    },
     {
       "identity" : "swift-huggingface",
       "kind" : "remoteSourceControl",
@@ -153,15 +90,6 @@
         "version" : "2.4.2"
       }
     },
-    {
-      "identity" : "swift-log",
-      "kind" : "remoteSourceControl",
-      "location" : "https://github.com/apple/swift-log.git",
-      "state" : {
-        "revision" : "3ffafb9722d5d918c614feb496c8789a3b59d222",
-        "version" : "1.15.0"
-      }
-    },
     {
       "identity" : "swift-nio",
       "kind" : "remoteSourceControl",
@@ -171,42 +99,6 @@
         "version" : "2.101.3"
       }
     },
-    {
-      "identity" : "swift-nio-extras",
-      "kind" : "remoteSourceControl",
-      "location" : "https://github.com/apple/swift-nio-extras.git",
-      "state" : {
-        "revision" : "3078359149adac3dd1255621a041e361e3f0edd1",
-        "version" : "1.35.0"
-      }
-    },
-    {
-      "identity" : "swift-nio-http2",
-      "kind" : "remoteSourceControl",
-      "location" : "https://github.com/apple/swift-nio-http2.git",
-      "state" : {
-        "revision" : "0f3e54e29c944c2e835ad52159da7d9e1c94ac69",
-        "version" : "1.46.0"
-      }
-    },
-    {
-      "identity" : "swift-nio-ssl",
-      "kind" : "remoteSourceControl",
-      "location" : "https://github.com/apple/swift-nio-ssl.git",
-      "state" : {
-        "revision" : "03827c1a9fdb2b6b00a4e93ede8861520263af8c",
-        "version" : "2.37.4"
-      }
-    },
-    {
-      "identity" : "swift-nio-transport-services",
-      "kind" : "remoteSourceControl",
-      "location" : "https://github.com/apple/swift-nio-transport-services.git",
-      "state" : {
-        "revision" : "67787bb645a5e67d2edcdfbe48a216cc549222d5",
-        "version" : "1.28.0"
-      }
-    },
     {
       "identity" : "swift-numerics",
       "kind" : "remoteSourceControl",
@@ -216,24 +108,6 @@
         "version" : "1.1.1"
       }
     },
-    {
-      "identity" : "swift-service-context",
-      "kind" : "remoteSourceControl",
-      "location" : "https://github.com/apple/swift-service-context.git",
-      "state" : {
-        "revision" : "d0997351b0c7779017f88e7a93bc30a1878d7f29",
-        "version" : "1.3.0"
-      }
-    },
-    {
-      "identity" : "swift-service-lifecycle",
-      "kind" : "remoteSourceControl",
-      "location" : "https://github.com/swift-server/swift-service-lifecycle.git",
-      "state" : {
-        "revision" : "7f9326b0326ff86e3646295ea6e891f68c471c5e",
-        "version" : "2.12.0"
-      }
-    },
     {
       "identity" : "swift-syntax",
       "kind" : "remoteSourceControl",
@@ -261,15 +135,6 @@
         "version" : "1.3.4"
       }
     },
-    {
-      "identity" : "swift-xet",
-      "kind" : "remoteSourceControl",
-      "location" : "https://github.com/huggingface/swift-xet.git",
-      "state" : {
-        "revision" : "341bfd4172f6a57119bfd49bafa11cf5d21fab75",
-        "version" : "0.2.3"
-      }
-    },
     {
       "identity" : "yams",
1790334948 4651 phase3-binary/Package.resolved

exec
/bin/bash -lc 'git diff -R -- phase3-binary/Package.resolved' in /Users/augstar/macprovider-1646-rest
 succeeded in 0ms:
diff --git b/phase3-binary/Package.resolved a/phase3-binary/Package.resolved
index bb1482bc9..8d3b0b6fd 100644
--- b/phase3-binary/Package.resolved
+++ a/phase3-binary/Package.resolved
@@ -1,5 +1,14 @@
 {
   "pins" : [
+    {
+      "identity" : "async-http-client",
+      "kind" : "remoteSourceControl",
+      "location" : "https://github.com/swift-server/async-http-client.git",
+      "state" : {
+        "revision" : "f95c908967e98c68c5ce3fd61a7974e7e869e303",
+        "version" : "1.36.1"
+      }
+    },
     {
       "identity" : "eventsource",
       "kind" : "remoteSourceControl",
@@ -27,6 +36,15 @@
         "version" : "3.31.4"
       }
     },
+    {
+      "identity" : "swift-algorithms",
+      "kind" : "remoteSourceControl",
+      "location" : "https://github.com/apple/swift-algorithms.git",
+      "state" : {
+        "revision" : "87e50f483c54e6efd60e885f7f5aa946cee68023",
+        "version" : "1.2.1"
+      }
+    },
     {
       "identity" : "swift-argument-parser",
       "kind" : "remoteSourceControl",
@@ -45,6 +63,15 @@
         "version" : "1.7.2"
       }
     },
+    {
+      "identity" : "swift-async-algorithms",
+      "kind" : "remoteSourceControl",
+      "location" : "https://github.com/apple/swift-async-algorithms.git",
+      "state" : {
+        "revision" : "3da39bbc4e687d4192af7c9cf4eab805745a0b9c",
+        "version" : "1.1.5"
+      }
+    },
     {
       "identity" : "swift-atomics",
       "kind" : "remoteSourceControl",
@@ -54,6 +81,15 @@
         "version" : "1.3.1"
       }
     },
+    {
+      "identity" : "swift-certificates",
+      "kind" : "remoteSourceControl",
+      "location" : "https://github.com/apple/swift-certificates.git",
+      "state" : {
+        "revision" : "c8aece90ea05f9866bd392a5bf13b5cae56c0e03",
+        "version" : "1.20.0"
+      }
+    },
     {
       "identity" : "swift-collections",
       "kind" : "remoteSourceControl",
@@ -72,6 +108,33 @@
         "version" : "4.5.1"
       }
     },
+    {
+      "identity" : "swift-distributed-tracing",
+      "kind" : "remoteSourceControl",
+      "location" : "https://github.com/apple/swift-distributed-tracing.git",
+      "state" : {
+        "revision" : "dc4030184203ffafbb2ec614352487235d747fe0",
+        "version" : "1.4.1"
+      }
+    },
+    {
+      "identity" : "swift-http-structured-headers",
+      "kind" : "remoteSourceControl",
+      "location" : "https://github.com/apple/swift-http-structured-headers.git",
+      "state" : {
+        "revision" : "933538faa42c432d385f02e07df0ace7c5ecfc47",
+        "version" : "1.7.0"
+      }
+    },
+    {
+      "identity" : "swift-http-types",
+      "kind" : "remoteSourceControl",
+      "location" : "https://github.com/apple/swift-http-types.git",
+      "state" : {
+        "revision" : "db774a277f60063a32d854f2980299caf06da041",
+        "version" : "1.6.0"
+      }
+    },
     {
       "identity" : "swift-huggingface",
       "kind" : "remoteSourceControl",
@@ -90,6 +153,15 @@
         "version" : "2.4.2"
       }
     },
+    {
+      "identity" : "swift-log",
+      "kind" : "remoteSourceControl",
+      "location" : "https://github.com/apple/swift-log.git",
+      "state" : {
+        "revision" : "3ffafb9722d5d918c614feb496c8789a3b59d222",
+        "version" : "1.15.0"
+      }
+    },
     {
       "identity" : "swift-nio",
       "kind" : "remoteSourceControl",
@@ -99,6 +171,42 @@
         "version" : "2.101.3"
       }
     },
+    {
+      "identity" : "swift-nio-extras",
+      "kind" : "remoteSourceControl",
+      "location" : "https://github.com/apple/swift-nio-extras.git",
+      "state" : {
+        "revision" : "3078359149adac3dd1255621a041e361e3f0edd1",
+        "version" : "1.35.0"
+      }
+    },
+    {
+      "identity" : "swift-nio-http2",
+      "kind" : "remoteSourceControl",
+      "location" : "https://github.com/apple/swift-nio-http2.git",
+      "state" : {
+        "revision" : "0f3e54e29c944c2e835ad52159da7d9e1c94ac69",
+        "version" : "1.46.0"
+      }
+    },
+    {
+      "identity" : "swift-nio-ssl",
+      "kind" : "remoteSourceControl",
+      "location" : "https://github.com/apple/swift-nio-ssl.git",
+      "state" : {
+        "revision" : "03827c1a9fdb2b6b00a4e93ede8861520263af8c",
+        "version" : "2.37.4"
+      }
+    },
+    {
+      "identity" : "swift-nio-transport-services",
+      "kind" : "remoteSourceControl",
+      "location" : "https://github.com/apple/swift-nio-transport-services.git",
+      "state" : {
+        "revision" : "67787bb645a5e67d2edcdfbe48a216cc549222d5",
+        "version" : "1.28.0"
+      }
+    },
     {
       "identity" : "swift-numerics",
       "kind" : "remoteSourceControl",
@@ -108,6 +216,24 @@
         "version" : "1.1.1"
       }
     },
+    {
+      "identity" : "swift-service-context",
+      "kind" : "remoteSourceControl",
+      "location" : "https://github.com/apple/swift-service-context.git",
+      "state" : {
+        "revision" : "d0997351b0c7779017f88e7a93bc30a1878d7f29",
+        "version" : "1.3.0"
+      }
+    },
+    {
+      "identity" : "swift-service-lifecycle",
+      "kind" : "remoteSourceControl",
+      "location" : "https://github.com/swift-server/swift-service-lifecycle.git",
+      "state" : {
+        "revision" : "7f9326b0326ff86e3646295ea6e891f68c471c5e",
+        "version" : "2.12.0"
+      }
+    },
     {
       "identity" : "swift-syntax",
       "kind" : "remoteSourceControl",
@@ -135,6 +261,15 @@
         "version" : "1.3.4"
       }
     },
+    {
+      "identity" : "swift-xet",
+      "kind" : "remoteSourceControl",
+      "location" : "https://github.com/huggingface/swift-xet.git",
+      "state" : {
+        "revision" : "341bfd4172f6a57119bfd49bafa11cf5d21fab75",
+        "version" : "0.2.3"
+      }
+    },
     {
       "identity" : "yams",
       "kind" : "remoteSourceControl",

2026-09-25T11:20:47.678200Z ERROR codex_core::tools::router: error=apply_patch verification failed: invalid patch: The first line of the patch must be '*** Begin Patch'
exec
/bin/bash -lc 'command -v apply_patch || true' in /Users/augstar/macprovider-1646-rest
 succeeded in 0ms:
/Users/augstar/.codex/tmp/arg0/codex-arg0LpItBW/apply_patch

exec
/bin/bash -lc 'git diff -R -- phase3-binary/Package.resolved | apply_patch' in /Users/augstar/macprovider-1646-rest
 exited 1 in 0ms:
Invalid patch: The first line of the patch must be '*** Begin Patch'

exec
/bin/bash -lc 'git restore --worktree -- phase3-binary/Package.resolved && git status -sb' in /Users/augstar/macprovider-1646-rest
 succeeded in 101ms:
## campaign/1646-remaining...origin/main [ahead 2]
?? audits/2026-09-25-cb-tools-structured/

exec
/bin/bash -lc "ps -Ao pid,etime,command | rg '/Users/augstar/macprovider-1646-rest/phase3-binary.*swift-test|/Users/augstar/macprovider-1646-rest/phase3-binary.*swift-driver' || true; git status -sb" in /Users/augstar/macprovider-1646-rest
 succeeded in 58ms:
## campaign/1646-remaining...origin/main [ahead 2]
?? audits/2026-09-25-cb-tools-structured/

exec
/bin/bash -lc "git diff --check origin/main...52fcb7e4 && nl -ba phase3-binary/Sources/macprovider-cli/ModelRuntime.swift | sed -n '4014,4054p;4073,4110p;4418,4438p;4648,4668p' && nl -ba phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift | sed -n '1618,1638p;1788,1808p;1808,1824p' && nl -ba phase3-binary/Tests/macprovider-cliTests/ContinuousBatchSchedulerTests.swift | sed -n '1800,1825p'" in /Users/augstar/macprovider-1646-rest
 succeeded in 12ms:
  1800	        XCTAssertEqual(events.map(\.replayTokens), [nil])
  1801	        XCTAssertEqual(events.first?.snapshot.modelSHA256, Self.modelSHA)
  1802	        XCTAssertEqual(result.terminalStatus, .batchFailed)
  1803	        XCTAssertEqual(result.outputTokens, [])
  1804	        XCTAssertEqual(result.completionTokens, 0)
  1805	        XCTAssertEqual(result.emittedTokens, 1)
  1806	        XCTAssertEqual(result.snapshot?.modelSHA256, Self.modelSHA)
  1807	    }
  1808	
  1809	    /// SPEC-038 AC-6c: a serial tool turn asks its decoding row to end; the
  1810	    /// row finishes as a normal `.stop` at its next token instead of running
  1811	    /// to `max_tokens`.
  1812	    func testStopEarlyEndsDecodingRowAsStopAtNextToken() async throws {
  1813	        let secondDecodeGate = AsyncGate()
  1814	        let recorder = TokenEventRecorder()
  1815	        let backend = SecondDecodeGateBackend(secondDecodeGate: secondDecodeGate)
  1816	        let scheduler = try await makeScheduler(maxActiveRows: 1, backend: backend)
  1817	        let submitted = Task {
  1818	            try await scheduler.submit(
  1819	                .init(id: "tool-turn", conversationKey: "", promptTokens: [1], maxOutputTokens: 8),
  1820	                tokenSink: { recorder.append($0) }
  1821	            )
  1822	        }
  1823	        try await eventually { recorder.events().count == 1 }
  1824	        await scheduler.stopEarly(requestID: "tool-turn")
  1825	        await secondDecodeGate.open()

exec
/bin/bash -lc "sed -n '7230,7315p' phase3-binary/Sources/macprovider-cli/ModelRuntime.swift" in /Users/augstar/macprovider-1646-rest
 succeeded in 0ms:
        timeout: TimeInterval = structuredStreamingIdleTimeoutSeconds,
        pollNanoseconds: UInt64 = 100_000_000,
        onIdleTimeout: @escaping @Sendable () throws -> T,
        operation: @escaping @Sendable (_ idleCancellation: DrainCancelToken) async throws -> T
    ) async throws -> T {
        guard idleState.enabled else {
            return try await operation(DrainCancelToken())
        }
        let idleCancellation = DrainCancelToken()
        return try await withThrowingTaskGroup(of: StructuredStreamingIdleRaceResult<T>.self) { group in
            group.addTask {
                do {
                    let result = try await operation(idleCancellation)
                    idleState.markOperationStopped()
                    if idleState.timedOut {
                        await Self.waitForStructuredStreamingIdleFinish(idleState)
                        throw DrainCancelledError()
                    }
                    return .operation(result)
                } catch {
                    idleState.markOperationStopped()
                    if idleState.timedOut {
                        await Self.waitForStructuredStreamingIdleFinish(idleState)
                        throw DrainCancelledError()
                    }
                    throw error
                }
            }
            group.addTask {
                while !idleState.isFinished {
                    try await Task.sleep(nanoseconds: pollNanoseconds)
                    if idleState.hasTimedOut(timeout: timeout) {
                        idleState.markTimedOut()
                        idleCancellation.fire()
                        // AC-V2-9 buffer-as-of-close: if the operation
                        // task does not stop within the wait budget we
                        // cannot guarantee a clean snapshot ("close"
                        // event happened, but the accumulator may
                        // still be in flux). Fail closed with
                        // provider_timeout rather than emit a possibly-
                        // stale validation result.
                        let stoppedCleanly = await Self.waitForStructuredStreamingOperationStopped(idleState)
                        if !stoppedCleanly {
                            throw Self.structuredStreamingProviderTimeoutError()
                        }
                        return .idle(try onIdleTimeout())
                    }
                }
                throw DrainCancelledError()
            }
            do {
                while let result = try await group.next() {
                    switch result {
                    case .operation(let value):
                        idleState.markFinished()
                        group.cancelAll()
                        return value
                    case .idle(let value):
                        idleState.markFinished()
                        group.cancelAll()
                        return value
                    }
                }
                throw DrainCancelledError()
            } catch {
                idleState.markFinished()
                group.cancelAll()
                throw error
            }
        }
    }

    private static func waitForStructuredStreamingOperationStopped(
        _ idleState: StructuredStreamingIdleState,
        maxNanoseconds: UInt64 = 100_000_000,
        pollNanoseconds: UInt64 = 10_000_000
    ) async -> Bool {
        var waited: UInt64 = 0
        while !idleState.operationStopped && waited < maxNanoseconds {
            try? await Task.sleep(nanoseconds: pollNanoseconds)
            waited += pollNanoseconds
        }
        return idleState.operationStopped
    }

    private static func waitForStructuredStreamingIdleFinish(

exec
/bin/bash -lc "nl -ba phase3-binary/Tests/macprovider-cliTests/ContinuousBatchSchedulerTests.swift | sed -n '1820,1845p'" in /Users/augstar/macprovider-1646-rest
 succeeded in 0ms:
  1820	                tokenSink: { recorder.append($0) }
  1821	            )
  1822	        }
  1823	        try await eventually { recorder.events().count == 1 }
  1824	        await scheduler.stopEarly(requestID: "tool-turn")
  1825	        await secondDecodeGate.open()
  1826	        let result = try await submitted.value
  1827	
  1828	        XCTAssertEqual(result.terminalStatus, .stop)
  1829	        XCTAssertNil(result.errorCode)
  1830	        XCTAssertEqual(result.generatedTokens, [7, 8])
  1831	        XCTAssertEqual(result.outputTokens, [7, 8])
  1832	        XCTAssertEqual(result.completionTokens, 2)
  1833	        XCTAssertEqual(result.settlementDisposition, .eligibleOwner)
  1834	        // A stop request for a row that is not decoding is ignored.
  1835	        await scheduler.stopEarly(requestID: "tool-turn")
  1836	        await scheduler.stopEarly(requestID: "unknown")
  1837	    }
  1838	
  1839	    func testTerminalResultWaitsForAcceptedTokenDelivery() async throws {
  1840	        let sinkGate = AsyncGate()
  1841	        let recorder = TokenEventRecorder()
  1842	        let completion = CompletionFlag()
  1843	        let duplicateRecorder = TokenEventRecorder()
  1844	        let duplicateCompletion = CompletionFlag()
  1845	        let backend = ScriptedBackend(scripts: ["ordered": [7]])

codex
Audit found one MEDIUM issue:

- `ModelRuntime.swift:4029-4047`, `4103-4107`; `ContinuousBatchScheduler.swift:1627-1632`  
  A duplicate/replayed tool request receives the full accumulated `replayTokens`, but the fresh parser records that full length as the serial stop point—or receives no token events on terminal replay. Since finalization only truncates when `serialStopTokenCount` is present, post-stop tokens can be included in `completionTokens`/receipts and cache commits. The existing scheduler test confirms stop-after-next-token behavior (`generatedTokens == [7, 8]`).

  Fix: derive or persist the canonical serial tool-stop boundary from `result.generatedTokens` once per row, and use it for every waiter/replay before billing and cache settlement.

No issues found with per-row parser/accumulator isolation, SPEC-018 caps, or Harmony tool routing.

Validation: row tests passed (9 tests); scheduler/routing selection passed (95 tests, 4 existing metallib skips); diff check passed.

VERDICT: FAIL (0/0/1)
tokens used
223 689

```

## Concise summary

Provider completed successfully. Review the raw output for details.

## Action items

- Review the response and extract decisions you want to apply.
- Capture follow-up implementation tasks if needed.
