import Foundation
import MLX
import MLXLMCommon
import MacProviderCore

/// On-device, load-time self-measurement of the paged-attention runtime.
///
/// SPEC-039 proves — in gated real-model XCTest fixtures
/// (`Tests/macprovider-cliTests/PagedKVParityTests.swift`) — that the packaged
/// Metal gather reconstructs logical K/V bit-for-bit against stock
/// `KVCacheSimple`, and that a batched `[B,1]` shared forward keeps MoE rows
/// isolated. These probes port that proven harness into PRODUCTION code so the
/// attach gate is fed GENUINELY MEASURED evidence on the resident model instead
/// of a hardcoded placeholder. Every probe fails CLOSED: any thrown error, any
/// divergence, or any degenerate layout yields a non-established result, and the
/// attach gate then correctly refuses.
///
/// These probes run only at model load / warm-swap adoption, BEFORE the runtime
/// is marked ready and BEFORE any buyer request is served — a single-threaded
/// window. Reading `PagedKVCache`'s `nonisolated(unsafe)` global gather
/// diagnostics is safe only in that window; the caches built here are never
/// injected into the concurrent serve path.
struct PagedKVRuntimeParityProbeResult: Sendable, Equatable {
    let established: Bool
    let nLayers: Int
    let nNew: Int
    let gatherKernelCalls: Int
    let maxLogicalBlocks: Int
    let nonIdentityPermutation: Bool

    static func failClosed(nNew: Int) -> PagedKVRuntimeParityProbeResult {
        PagedKVRuntimeParityProbeResult(
            established: false,
            nLayers: 0,
            nNew: nNew,
            gatherKernelCalls: 0,
            maxLogicalBlocks: 0,
            nonIdentityPermutation: false
        )
    }
}

struct PagedKVRuntimeMoEProbeResult: Sendable, Equatable {
    let proven: Bool
    let rowsDecodedInSharedForward: Int
    let rowFailures: Int
    let crossRowDivergences: Int
    /// Exact serial-vs-production shared-forward token parity over the full
    /// final-prefill + decode lifecycle. This catches one-row divergences where
    /// row isolation is intact but the prompt/decode partition changed logits.
    let sharedForwardParityProven: Bool
    let parityTokensCompared: Int
    /// True only when the two challenge rows have DIFFERENT serial reference tokens, so
    /// that a shared forward which swapped or leaked one row's logits into the other would
    /// register as a divergence. A non-distinguishing challenge (identical references) can
    /// never prove isolation, so `proven` requires this to hold.
    let challengeDistinguishing: Bool

    init(
        proven: Bool,
        rowsDecodedInSharedForward: Int,
        rowFailures: Int,
        crossRowDivergences: Int,
        sharedForwardParityProven: Bool = false,
        parityTokensCompared: Int = 0,
        challengeDistinguishing: Bool
    ) {
        self.proven = proven
        self.rowsDecodedInSharedForward = rowsDecodedInSharedForward
        self.rowFailures = rowFailures
        self.crossRowDivergences = crossRowDivergences
        self.sharedForwardParityProven = sharedForwardParityProven
        self.parityTokensCompared = parityTokensCompared
        self.challengeDistinguishing = challengeDistinguishing
    }

    static let failClosed = PagedKVRuntimeMoEProbeResult(
        proven: false,
        rowsDecodedInSharedForward: 0,
        rowFailures: 0,
        crossRowDivergences: 0,
        sharedForwardParityProven: false,
        parityTokensCompared: 0,
        challengeDistinguishing: false
    )
}

enum PagedKVRuntimeParityProbe {
    /// SPEC-038 FR-CB6 "accepted numerical tolerance" for the load-time batched isolation
    /// self-test: the maximum logit gap below a row's OWN serial argmax at which that row's
    /// batched greedy token — when it is the row's own serial runner-up — counts as a
    /// floating-point tie rather than a divergence. Batched vs serial differ only in fp
    /// accumulation order (batched matmuls / MoE routing); observed reorder ties on MoE are
    /// a few tenths of a logit, while a leaked other-row token lands many logits below a
    /// row's own argmax — so this bound admits genuine ties without admitting leaks. It is
    /// paired with a hard "must be this row's own runner-up" rank gate and an explicit
    /// other-row-token guard, so relaxing exact argmax does not relax cross-row isolation.
    static let batchedArgmaxLogitTolerance: Float = 1.0
    static let sharedForwardParityPromptTokens = 513
    static let sharedForwardParityTokens = 48

    /// A row's stock serial next-token distribution: greedy argmax, runner-up, and the full
    /// last-position logits (so a candidate token's gap below the argmax can be measured).
    struct SerialReference: Sendable {
        let top1: Int
        let top2: Int
        let logits: [Float]
    }

    /// SPEC-038 FR-CB6 conformance test for one batched row's greedy token against that
    /// row's own serial distribution. Conformant iff the token is the row's own serial
    /// argmax, or its own serial runner-up within `tolerance` logits of its serial argmax
    /// (an own-distribution numerical tie). An explicit leak guard rejects a token equal to
    /// the OTHER row's serial argmax even if it happens to also be this row's runner-up, so
    /// admitting numerical ties never admits a cross-row leak. Pure and side-effect-free so
    /// the isolation-preserving behavior is unit-tested without a model.
    static func batchedTokenIsConformant(
        decoded: Int,
        own: SerialReference,
        otherRowSerialTop1: Int?,
        tolerance: Float
    ) -> Bool {
        if decoded == own.top1 { return true }
        if let other = otherRowSerialTop1, decoded == other { return false }
        guard decoded == own.top2,
              own.logits.indices.contains(decoded),
              own.logits.indices.contains(own.top1)
        else { return false }
        return (own.logits[own.top1] - own.logits[decoded]) <= tolerance
    }

    /// AC-1/AC-2 self-test: greedy-generate `nNew` tokens on a fixed canned prompt
    /// through stock `KVCacheSimple` vs `PagedKVCache` (whose `update()` round-trips
    /// logical K/V through the REAL Metal gather over a reversed, boundary-crossing
    /// physical block order). `established` is token-for-token argmax equality AND
    /// equal token count. The gather diagnostics (call count, max logical blocks,
    /// non-identity permutation) are reported for the measurement seam to gate on.
    static func runParityProbe(
        container: ModelContainer,
        modelID: String,
        blockSizeTokens: Int,
        maxPhysicalBlocks: Int,
        promptTokens: [Int],
        nNew: Int
    ) async -> PagedKVRuntimeParityProbeResult {
        guard nNew > 0, blockSizeTokens > 0, maxPhysicalBlocks > 0, !promptTokens.isEmpty else {
            return .failClosed(nNew: nNew)
        }
        do {
            // Metadata-only binding: `PagedKVCache.update()` holds K/V in-tensor and never
            // touches the allocator, so one value-type binding is reused for every layer
            // (mirrors the proven parity harness). No `PagedKVDescriptor` is constructed
            // here — its memberwise init is internal to `MacProviderCore` and invisible
            // from this module; the cache's descriptor-free primitives init is used
            // instead (this probe measures gather CORRECTNESS, not identity — identity
            // binding is the attach gate's job).
            let allocator = try PagedKVBlockAllocator(
                blockSizeTokens: blockSizeTokens,
                maxPhysicalBlocks: maxPhysicalBlocks
            )
            let handle = try await allocator.allocate(
                conversationKey: "paged-kv-parity-probe",
                maxTokens: blockSizeTokens * maxPhysicalBlocks,
                initialTokens: 0
            )
            let binding = try await allocator.binding(for: handle)

            return try await container.perform { context in
                let model = context.model
                let stockLayout = try model.newCache(parameters: nil)
                guard let kinds = PagedKVSharedForwardBackend.CacheKind.kinds(from: stockLayout) else {
                    return .failClosed(nNew: nNew)
                }
                let nLayers = kinds.filter(\.usesPagedKVCache).count
                guard nLayers > 0 else { return .failClosed(nNew: nNew) }

                let stock = try Self.greedyGenerate(model: model, promptTokens: promptTokens, nNew: nNew) {
                    try model.newCache(parameters: nil)
                }

                PagedKVCache.resetGatherDiagnostics()
                let paged = try Self.greedyGenerate(model: model, promptTokens: promptTokens, nNew: nNew) {
                    zip(stockLayout, kinds).map { _, kind in
                        if case .recurrentMamba = kind { return MambaCache() as KVCache }
                        let window: Int?
                        if case .slidingWindow(let windowTokens) = kind {
                            window = windowTokens
                        } else {
                            window = nil
                        }
                        return PagedKVCache(
                            blockSizeTokens: blockSizeTokens,
                            maxPhysicalBlocks: maxPhysicalBlocks,
                            poolEpoch: 1,
                            binding: binding,
                            attentionWindowTokens: window
                        )
                    }
                }
                let calls = PagedKVCache.gatherKernelCalls
                let maxBlocks = PagedKVCache.maxLogicalBlocksObserved
                let nonIdentity = PagedKVCache.observedNonIdentityPermutation

                let established = stock.count == paged.count && Self.firstDivergence(stock, paged) == nil
                return PagedKVRuntimeParityProbeResult(
                    established: established,
                    nLayers: nLayers,
                    nNew: nNew,
                    gatherKernelCalls: calls,
                    maxLogicalBlocks: maxBlocks,
                    nonIdentityPermutation: nonIdentity
                )
            }
        } catch {
            PagedKVRuntimeDiagnostics.log("parity-probe threw, failing closed: \(error)")
            return .failClosed(nNew: nNew)
        }
    }

    /// AC-3 MoE input-isolation self-test: prefill two distinct prompts as two rows,
    /// sample each row's first token from the final prompt position, then run a batched
    /// `[B,1]` shared-forward decode step. Recurrent mixed-cache
    /// layouts additionally remove one peer, join a fresh peer, and run a second batched
    /// `[B,1]` shared-forward step. Each sampled token is compared to an independent
    /// production `TokenIterator` reference for the exact row continuation being decoded.
    ///
    /// `PagedKVSharedForwardBackend.decode` returns ALL `.rowFailure` if the multi-row
    /// path is degenerate (a single-row fallback or a carried `LMOutput.State`), so
    /// two `.output` outcomes is itself proof the real `[B,1]` shared forward ran. The
    /// second shared step proves retained recurrent row state survives peer leave/join
    /// membership churn, but only runs for `.recurrentMamba` cache layouts. `proven`
    /// requires every required shared forward to decode both rows, zero row failures,
    /// zero divergences, and distinguishing serial references.
    static func runMoEInputIsolationProbe(
        container: ModelContainer,
        blockSizeTokens: Int,
        maxPhysicalBlocks: Int,
        poolEpoch: Int,
        layerCount: Int,
        promptA: [Int],
        promptB: [Int],
        parityPromptA: [Int]? = nil,
        parityPromptB: [Int]? = nil,
        cacheKinds: [PagedKVSharedForwardBackend.CacheKind]? = nil
    ) async -> PagedKVRuntimeMoEProbeResult {
        guard layerCount > 0, promptA.count >= 1, promptB.count >= 1 else {
            return .failClosed
        }
        do {
            let sharedForwardParityProven = try await Self.runSharedForwardExactParityProbe(
                container: container,
                blockSizeTokens: blockSizeTokens,
                maxPhysicalBlocks: maxPhysicalBlocks,
                poolEpoch: poolEpoch,
                layerCount: layerCount,
                promptA: parityPromptA ?? promptA,
                promptB: parityPromptB ?? promptB,
                cacheKinds: cacheKinds,
                nNew: sharedForwardParityTokens
            )
            let backend = PagedKVSharedForwardBackend(
                container: container,
                blockSizeTokens: blockSizeTokens,
                maxPhysicalBlocks: maxPhysicalBlocks,
                poolEpoch: poolEpoch,
                layerCount: layerCount,
                cacheKinds: cacheKinds
            )
            let allocator = try PagedKVBlockAllocator(
                blockSizeTokens: blockSizeTokens,
                maxPhysicalBlocks: maxPhysicalBlocks
            )

            let needsRecurrentMembershipProbe = cacheKinds?.contains(.recurrentMamba) == true
            // Production hybrid scheduling splits and writes recurrent state back at
            // every token boundary. Exercise one shared decode before the leave/join
            // transition instead of the non-production multi-token packed-cache window.
            let firstSteps = 1
            let rowA = try await Self.makeMoEProbeRow(
                requestID: "moe-probe-a",
                prompt: promptA,
                allocator: allocator,
                decodeSteps: firstSteps
            )
            let rowB = try await Self.makeMoEProbeRow(
                requestID: "moe-probe-b",
                prompt: promptB,
                allocator: allocator,
                decodeSteps: firstSteps
            )

            let firstPrefill = try await backend.prefill(rows: [rowA.prefill, rowB.prefill])
            let firstPrefillTokens = Self.sampledTokensByID(from: firstPrefill)
            guard let initialA = firstPrefillTokens["moe-probe-a"],
                  let initialB = firstPrefillTokens["moe-probe-b"]
            else {
                return PagedKVRuntimeMoEProbeResult(
                    proven: false,
                    rowsDecodedInSharedForward: 0,
                    rowFailures: firstPrefill.filter { $0.failureCode != nil }.count,
                    crossRowDivergences: 0,
                    sharedForwardParityProven: sharedForwardParityProven,
                    parityTokensCompared: Self.sharedForwardParityTokens,
                    challengeDistinguishing: false
                )
            }
            let rowAFirst = try await Self.makeMoEProbeContinuationRow(
                requestID: "moe-probe-a",
                prompt: promptA,
                generatedTokens: [initialA],
                currentToken: initialA,
                handle: rowA.handle,
                allocator: allocator,
                decodeSteps: firstSteps
            )
            let rowBFirst = try await Self.makeMoEProbeContinuationRow(
                requestID: "moe-probe-b",
                prompt: promptB,
                generatedTokens: [initialB],
                currentToken: initialB,
                handle: rowB.handle,
                allocator: allocator,
                decodeSteps: firstSteps
            )
            let firstOutcomes: [ContinuousBatchDecodeOutcome]
            if needsRecurrentMembershipProbe {
                firstOutcomes = try await backend.decodeLockstepWindow(
                    rows: [rowAFirst.decode, rowBFirst.decode],
                    steps: firstSteps
                )
            } else {
                firstOutcomes = try await backend.decode(rows: [rowAFirst.decode, rowBFirst.decode])
            }
            try await allocator.endDecodeStep(rowA.handle)
            try await allocator.endDecodeStep(rowB.handle)

            let first = Self.decodedTokensByID(from: firstOutcomes)
            guard let firstA = first.tokens["moe-probe-a"],
                  let firstB = first.tokens["moe-probe-b"],
                  firstA.count == firstSteps,
                  firstB.count == firstSteps
            else {
                return PagedKVRuntimeMoEProbeResult(
                    proven: false,
                    rowsDecodedInSharedForward: first.rowsDecoded,
                    rowFailures: first.rowFailures,
                    crossRowDivergences: 0,
                    sharedForwardParityProven: sharedForwardParityProven,
                    parityTokensCompared: Self.sharedForwardParityTokens,
                    challengeDistinguishing: false
                )
            }

            let serialReferenceCount = firstSteps + (needsRecurrentMembershipProbe ? 2 : 1)
            let serialA = try await Self.serialContinuationReferences(
                container: container,
                prompt: promptA,
                nNew: serialReferenceCount,
                useProductionIterator: needsRecurrentMembershipProbe
            )
            let serialB = try await Self.serialContinuationReferences(
                container: container,
                prompt: promptB,
                nNew: serialReferenceCount,
                useProductionIterator: needsRecurrentMembershipProbe
            )
            guard serialA.count == serialReferenceCount,
                  serialB.count == serialReferenceCount
            else {
                return PagedKVRuntimeMoEProbeResult(
                    proven: false,
                    rowsDecodedInSharedForward: first.rowsDecoded,
                    rowFailures: first.rowFailures,
                    crossRowDivergences: 0,
                    sharedForwardParityProven: sharedForwardParityProven,
                    parityTokensCompared: Self.sharedForwardParityTokens,
                    challengeDistinguishing: false
                )
            }
            let referenceA1 = Array(serialA.dropFirst().prefix(firstSteps))
            let referenceB1 = Array(serialB.dropFirst().prefix(firstSteps))
            PagedKVRuntimeDiagnostics.log(
                "moe-isolation first prefill=[\(initialA),\(initialB)] serial=[\(serialA[0].top1),\(serialB[0].top1)] "
                    + "decodeA=\(firstA) serialA=\(referenceA1.map(\.top1)) "
                    + "decodeB=\(firstB) serialB=\(referenceB1.map(\.top1))"
            )
            let prefillDivergences = [
                (initialA, serialA[0]),
                (initialB, serialB[0]),
            ].filter { decoded, reference in
                !Self.batchedTokenIsConformant(
                    decoded: decoded,
                    own: reference,
                    otherRowSerialTop1: nil,
                    tolerance: Self.batchedArgmaxLogitTolerance
                )
            }.count
            let firstCrossRowDivergences = Self.divergenceCount(
                decodedByID: first.tokens,
                referencesByID: [
                    "moe-probe-a": referenceA1,
                    "moe-probe-b": referenceB1,
                ]
            ) + prefillDivergences
            let firstChallengeDistinguishing = Self.challengeDistinguishing([referenceA1, referenceB1])

            guard needsRecurrentMembershipProbe else {
                let proven = firstChallengeDistinguishing
                    && first.rowsDecoded == 2
                    && first.rowFailures == 0
                    && firstCrossRowDivergences == 0
                return PagedKVRuntimeMoEProbeResult(
                    proven: proven,
                    rowsDecodedInSharedForward: first.rowsDecoded,
                    rowFailures: first.rowFailures,
                    crossRowDivergences: firstCrossRowDivergences,
                    sharedForwardParityProven: sharedForwardParityProven,
                    parityTokensCompared: Self.sharedForwardParityTokens,
                    challengeDistinguishing: firstChallengeDistinguishing
                )
            }

            backend.finish(requestID: "moe-probe-b")
            let rowBRejoin = try await Self.makeMoEProbeRow(requestID: "moe-probe-b-rejoin", prompt: promptB, allocator: allocator)
            let rejoinPrefill = try await backend.prefill(rows: [rowBRejoin.prefill])
            guard let rejoinInitialB = Self.sampledTokensByID(from: rejoinPrefill)["moe-probe-b-rejoin"] else {
                return PagedKVRuntimeMoEProbeResult(
                    proven: false,
                    rowsDecodedInSharedForward: first.rowsDecoded,
                    rowFailures: first.rowFailures + rejoinPrefill.filter { $0.failureCode != nil }.count,
                    crossRowDivergences: firstCrossRowDivergences,
                    sharedForwardParityProven: sharedForwardParityProven,
                    parityTokensCompared: Self.sharedForwardParityTokens,
                    challengeDistinguishing: false
                )
            }
            let rowASecond = try await Self.makeMoEProbeContinuationRow(
                requestID: "moe-probe-a",
                prompt: promptA,
                generatedTokens: [initialA] + firstA,
                currentToken: firstA[firstA.count - 1],
                handle: rowA.handle,
                allocator: allocator
            )
            let rowBRejoinDecode = try await Self.makeMoEProbeContinuationRow(
                requestID: "moe-probe-b-rejoin",
                prompt: promptB,
                generatedTokens: [rejoinInitialB],
                currentToken: rejoinInitialB,
                handle: rowBRejoin.handle,
                allocator: allocator
            )
            let secondOutcomes = try await backend.decode(rows: [rowASecond.decode, rowBRejoinDecode.decode])
            try await allocator.endDecodeStep(rowA.handle)
            try await allocator.endDecodeStep(rowBRejoin.handle)

            let second = Self.decodedTokensByID(from: secondOutcomes)

            // The second A reference includes A's full first-window continuation, so it
            // validates retained recurrent row state across the B leave / B' join churn.
            let referenceA2 = Array(serialA.dropFirst(firstSteps + 1).prefix(1))
            let referenceB2 = Array(serialB.dropFirst().prefix(1))
            let secondA = second.tokens["moe-probe-a"] ?? []
            let secondB = second.tokens["moe-probe-b-rejoin"] ?? []
            PagedKVRuntimeDiagnostics.log(
                "moe-isolation rejoin decodeA=\(secondA) "
                    + "serialA=\(referenceA2.map(\.top1)) "
                    + "decodeB=\(secondB) "
                    + "serialB=\(referenceB2.map(\.top1))"
            )

            // SPEC-038 FR-CB6 requires the batched temperature-0 output to match the serial
            // path "within the accepted numerical tolerance" — NOT bit-exactly. Batched and
            // serial differ only in floating-point ACCUMULATION ORDER (batched matmuls / MoE
            // expert routing vs a single row), which can flip greedy argmax between two
            // near-tied tokens of the SAME row's own distribution. Such a numerical tie is
            // conformant; a token the row's own distribution did not nearly choose — most
            // importantly the OTHER row's token — is a genuine divergence/leak and must fail.
            //
            // A row's batched token is conformant iff:
            //   (a) it equals the row's own serial argmax (exact), or
            //   (b) it equals the row's own serial RUNNER-UP and is within
            //       `batchedArgmaxLogitTolerance` logits of the row's serial argmax
            //       (a genuine own-distribution near-tie),
            // AND, as an explicit leak guard, it is not the OTHER row's serial argmax.
            var crossRowDivergences = firstCrossRowDivergences
            crossRowDivergences += Self.divergenceCount(
                decodedByID: second.tokens,
                referencesByID: [
                    "moe-probe-a": referenceA2,
                    "moe-probe-b-rejoin": referenceB2,
                ]
            )

            // The challenge only proves isolation if the two rows have DIFFERENT serial
            // argmax tokens: with identical references a shared forward that swapped/leaked
            // one row's logits into the other would still match both references and hide
            // the leak. Require distinct references for both shared forwards and fail
            // closed otherwise.
            let challengeDistinguishing = firstChallengeDistinguishing
                && Self.challengeDistinguishing([referenceA2, referenceB2])
            let rowsDecoded = min(first.rowsDecoded, second.rowsDecoded)
            let rowFailures = first.rowFailures + second.rowFailures
            let proven = challengeDistinguishing
                && first.rowsDecoded == 2
                && second.rowsDecoded == 2
                && rowFailures == 0
                && crossRowDivergences == 0
            return PagedKVRuntimeMoEProbeResult(
                proven: proven,
                rowsDecodedInSharedForward: rowsDecoded,
                rowFailures: rowFailures,
                crossRowDivergences: crossRowDivergences,
                sharedForwardParityProven: sharedForwardParityProven,
                parityTokensCompared: Self.sharedForwardParityTokens,
                challengeDistinguishing: challengeDistinguishing
            )
        } catch {
            PagedKVRuntimeDiagnostics.log("moe-isolation-probe threw, failing closed: \(error)")
            return .failClosed
        }
    }

    // MARK: - Harness (ported from PagedKVParityTests)

    private static func runSharedForwardExactParityProbe(
        container: ModelContainer,
        blockSizeTokens: Int,
        maxPhysicalBlocks: Int,
        poolEpoch: Int,
        layerCount: Int,
        promptA: [Int],
        promptB: [Int],
        cacheKinds: [PagedKVSharedForwardBackend.CacheKind]?,
        nNew: Int
    ) async throws -> Bool {
        guard nNew > 0 else { return false }
        let serial = try await container.perform { context in
            (
                try Self.greedyGenerate(
                    model: context.model,
                    promptTokens: promptA,
                    nNew: nNew,
                    makeCache: { try context.model.newCache(parameters: nil) }
                ),
                try Self.greedyGenerate(
                    model: context.model,
                    promptTokens: promptB,
                    nNew: nNew,
                    makeCache: { try context.model.newCache(parameters: nil) }
                )
            )
        }
        let (serialA, serialB) = serial
        let oneRow = try await sharedForwardGeneratedTokens(
            container: container,
            blockSizeTokens: blockSizeTokens,
            maxPhysicalBlocks: maxPhysicalBlocks,
            poolEpoch: poolEpoch,
            layerCount: layerCount,
            cacheKinds: cacheKinds,
            rows: [("shared-parity-a", promptA)],
            nNew: nNew
        )
        guard oneRow["shared-parity-a"] == serialA else { return false }
        let twoRow = try await sharedForwardGeneratedTokens(
            container: container,
            blockSizeTokens: blockSizeTokens,
            maxPhysicalBlocks: maxPhysicalBlocks,
            poolEpoch: poolEpoch,
            layerCount: layerCount,
            cacheKinds: cacheKinds,
            rows: [
                ("shared-parity-a", promptA),
                ("shared-parity-b", promptB),
            ],
            nNew: nNew
        )
        return twoRow["shared-parity-a"] == serialA && twoRow["shared-parity-b"] == serialB
    }

    private static func sharedForwardGeneratedTokens(
        container: ModelContainer,
        blockSizeTokens: Int,
        maxPhysicalBlocks: Int,
        poolEpoch: Int,
        layerCount: Int,
        cacheKinds: [PagedKVSharedForwardBackend.CacheKind]?,
        rows: [(id: String, prompt: [Int])],
        nNew: Int
    ) async throws -> [String: [Int]] {
        guard let promptCount = rows.first?.prompt.count,
              promptCount > 0,
              rows.allSatisfy({ $0.prompt.count == promptCount })
        else { return [:] }
        let backend = PagedKVSharedForwardBackend(
            container: container,
            blockSizeTokens: blockSizeTokens,
            maxPhysicalBlocks: maxPhysicalBlocks,
            poolEpoch: poolEpoch,
            layerCount: layerCount,
            cacheKinds: cacheKinds
        )
        let allocator = try PagedKVBlockAllocator(
            blockSizeTokens: blockSizeTokens,
            maxPhysicalBlocks: maxPhysicalBlocks
        )
        var handles: [String: PagedKVBlockTableHandle] = [:]
        for row in rows {
            let maxTokens = row.prompt.count + nNew
            let handle = try await allocator.allocate(
                conversationKey: row.id,
                maxTokens: max(maxTokens, 1),
                initialTokens: 0
            )
            handles[row.id] = handle
        }
        var generated: [String: [Int]] = [:]
        let prefillStepSize = ContinuousBatchSchedulerConfiguration.defaultPromptChunkTokens
        var promptOffset = 0
        while promptOffset < promptCount {
            var prefillInputs: [ContinuousBatchPrefillInput] = []
            prefillInputs.reserveCapacity(rows.count)
            for row in rows {
                guard let handle = handles[row.id] else { return [:] }
                let end = min(row.prompt.count, promptOffset + prefillStepSize)
                let chunk = Array(row.prompt[promptOffset..<end])
                _ = try await allocator.extend(handle, by: chunk.count)
                let binding = try await allocator.binding(for: handle)
                let isFinalChunk = end == row.prompt.count
                prefillInputs.append(ContinuousBatchPrefillInput(
                    requestID: row.id,
                    promptTokens: chunk,
                    binding: binding,
                    promptTokenOffset: promptOffset,
                    committedKVTokenCount: promptOffset,
                    targetKVTokenCount: end,
                    isFinalChunk: isFinalChunk,
                    sampleFirstToken: isFinalChunk,
                    samplerSeed: 0,
                    temperature: 0,
                    topP: 1,
                    samplerStep: 0
                ))
            }
            let prefillOutputs = try await backend.prefill(rows: prefillInputs)
            let finalRequestIDs = Set(prefillInputs.filter(\.isFinalChunk).map(\.requestID))
            for output in prefillOutputs where finalRequestIDs.contains(output.requestID) {
                guard let token = output.sampledToken else { return [:] }
                generated[output.requestID] = [token]
            }
            promptOffset += prefillInputs.first?.promptTokens.count ?? 0
        }
        guard nNew > 1 else {
            for row in rows {
                backend.finish(requestID: row.id)
            }
            return generated
        }

        let hybrid = cacheKinds?.contains(.recurrentMamba) == true
        var remaining = nNew - 1
        while remaining > 0 {
            let window = hybrid ? 1 : remaining
            var decodeInputs: [ContinuousBatchDecodeInput] = []
            for row in rows {
                guard let handle = handles[row.id],
                      let rowGenerated = generated[row.id],
                      let currentToken = rowGenerated.last
                else { return [:] }
                let committed = row.prompt.count - 1 + rowGenerated.count
                _ = try await allocator.extend(handle, by: window)
                try await allocator.beginDecodeStep(handle)
                let binding = try await allocator.binding(for: handle)
                decodeInputs.append(ContinuousBatchDecodeInput(
                    requestID: row.id,
                    currentToken: currentToken,
                    generatedTokens: rowGenerated,
                    promptTokens: row.prompt,
                    samplerSeed: 0,
                    temperature: 0,
                    topP: 1,
                    presencePenalty: 0,
                    frequencyPenalty: 0,
                    binding: binding,
                    blockTable: binding.currentTable,
                    committedKVTokenCount: committed,
                    targetKVTokenCount: committed + window,
                    samplerStep: rowGenerated.count
                ))
            }
            let outcomes = try await backend.decodeLockstepWindow(rows: decodeInputs, steps: window)
            for row in rows {
                if let handle = handles[row.id] {
                    try await allocator.endDecodeStep(handle)
                }
            }
            for outcome in outcomes {
                guard case .output(let output) = outcome,
                      output.tokens.count == window
                else { return [:] }
                generated[output.requestID, default: []].append(contentsOf: output.tokens)
            }
            remaining -= window
        }
        for row in rows {
            backend.finish(requestID: row.id)
        }
        return generated
    }

    private static func greedyGenerate(
        model: any LanguageModel,
        promptTokens: [Int],
        nNew: Int,
        prefillStepSize: Int = ContinuousBatchSchedulerConfiguration.defaultPromptChunkTokens,
        makeCache: () throws -> [KVCache]
    ) throws -> [Int] {
        let cache = try makeCache()
        var out: [Int] = []
        out.reserveCapacity(nNew)
        let chunkSize = max(1, prefillStepSize)
        var promptOffset = 0
        while promptTokens.count - promptOffset > chunkSize {
            let end = promptOffset + chunkSize
            let chunk = MLXArray(promptTokens[promptOffset..<end].map { Int32($0) })
                .reshaped([1, chunkSize])
            _ = model(chunk, cache: cache)
            eval(cache.flatMap { $0.state })
            promptOffset = end
        }
        let remainder = Array(promptTokens[promptOffset...])
        var y = MLXArray(remainder.map { Int32($0) }).reshaped([1, remainder.count])
        for _ in 0 ..< nNew {
            let logits = model(y, cache: cache)
            let next = lastTokenArgmax(logits)
            eval(cache.flatMap { $0.state })
            out.append(Int(next))
            y = MLXArray([next]).reshaped([1, 1])
        }
        return out
    }

    private static func lastTokenArgmax(_ logits: MLXArray) -> Int32 {
        let v = logits.dim(logits.ndim - 1)
        let flat = logits.reshaped([-1, v])
        let row = flat[flat.dim(0) - 1]
        return argMax(row, axis: -1).item(Int32.self)
    }

    private static func firstDivergence(_ a: [Int], _ b: [Int]) -> Int? {
        for i in 0 ..< min(a.count, b.count) where a[i] != b[i] { return i }
        return a.count == b.count ? nil : min(a.count, b.count)
    }

    private struct MoEPrefillRow {
        let handle: PagedKVBlockTableHandle
        let prefill: ContinuousBatchPrefillInput
    }

    private struct MoEDecodeRow {
        let handle: PagedKVBlockTableHandle
        let decode: ContinuousBatchDecodeInput
    }

    private struct DecodedProbeTokens {
        let rowsDecoded: Int
        let rowFailures: Int
        let tokens: [String: [Int]]
    }

    /// Builds the production-lifecycle prefill used by the isolation challenge. The
    /// full prompt is committed and the first generated token is sampled from its final
    /// position, matching the scheduler and serial `TokenIterator` partition exactly.
    private static func makeMoEProbeRow(
        requestID: String,
        prompt: [Int],
        allocator: PagedKVBlockAllocator,
        decodeSteps: Int = 1
    ) async throws -> MoEPrefillRow {
        let promptLength = prompt.count
        let targetKVTokenCount = promptLength + max(1, decodeSteps)
        let handle = try await allocator.allocate(
            conversationKey: requestID,
            maxTokens: max(targetKVTokenCount + 1, 1),
            initialTokens: 0
        )
        _ = try await allocator.extend(handle, by: promptLength)
        let prefillBinding = try await allocator.binding(for: handle)
        let prefill = ContinuousBatchPrefillInput(
            requestID: requestID,
            promptTokens: prompt,
            binding: prefillBinding,
            promptTokenOffset: 0,
            committedKVTokenCount: 0,
            targetKVTokenCount: promptLength,
            isFinalChunk: true,
            sampleFirstToken: true
        )
        return MoEPrefillRow(handle: handle, prefill: prefill)
    }

    private static func makeMoEProbeContinuationRow(
        requestID: String,
        prompt: [Int],
        generatedTokens: [Int],
        currentToken: Int,
        handle: PagedKVBlockTableHandle,
        allocator: PagedKVBlockAllocator,
        decodeSteps: Int = 1
    ) async throws -> MoEDecodeRow {
        let committedKVTokenCount = prompt.count - 1 + generatedTokens.count
        _ = try await allocator.extend(handle, by: max(1, decodeSteps))
        try await allocator.beginDecodeStep(handle)
        let binding = try await allocator.binding(for: handle)
        let decode = ContinuousBatchDecodeInput(
            requestID: requestID,
            currentToken: currentToken,
            generatedTokens: generatedTokens,
            promptTokens: prompt,
            samplerSeed: 0,
            temperature: 0,
            topP: 1,
            presencePenalty: 0,
            frequencyPenalty: 0,
            binding: binding,
            blockTable: binding.currentTable,
            committedKVTokenCount: committedKVTokenCount,
            targetKVTokenCount: committedKVTokenCount + max(1, decodeSteps),
            samplerStep: generatedTokens.count
        )
        return MoEDecodeRow(
            handle: handle,
            decode: decode
        )
    }

    private static func sampledTokensByID(
        from outputs: [ContinuousBatchPrefillOutput]
    ) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: outputs.compactMap { output in
            guard output.failureCode == nil, let token = output.sampledToken else { return nil }
            return (output.requestID, token)
        })
    }

    /// Serial references for a greedy continuation. Recurrent hybrids must use the
    /// production `TokenIterator` because `model.prepare` may establish recurrent state
    /// differently from a direct full-prompt forward even when the first argmax agrees.
    /// Iterator references intentionally require exact token equality: the iterator does
    /// not expose processed logits, so manufacturing a runner-up from another forward
    /// would make the tolerance test unsound. Attention-only layouts retain the existing
    /// full-distribution oracle so legitimate batched accumulation near-ties remain
    /// eligible under FR-CB6.
    private static func serialContinuationReferences(
        container: ModelContainer,
        prompt: [Int],
        nNew: Int,
        useProductionIterator: Bool
    ) async throws -> [SerialReference] {
        try await container.perform { context in
            guard useProductionIterator else {
                var promptAndGenerated = prompt
                var references: [SerialReference] = []
                references.reserveCapacity(nNew)
                for _ in 0 ..< nNew {
                    let reference = try Self.serialReference(
                        model: context.model,
                        prompt: promptAndGenerated
                    )
                    references.append(reference)
                    promptAndGenerated.append(reference.top1)
                }
                return references
            }
            let parameters = GenerateParameters(
                maxTokens: nNew,
                temperature: 0,
                topP: 1
            )
            let cache = try context.model.newCache(parameters: parameters)
            // `TokenIterator` owns the batch-axis insertion; production processor
            // output is a one-dimensional prompt token vector.
            let tokens = MLXArray(prompt.map(Int32.init))
            let input = LMInput(text: LMInput.Text(tokens: tokens))
            var iterator = try TokenIterator(
                input: input,
                model: context.model,
                cache: cache,
                parameters: parameters
            )
            var references: [SerialReference] = []
            references.reserveCapacity(nNew)
            for _ in 0 ..< nNew {
                guard let token = iterator.next() else { break }
                references.append(SerialReference(top1: token, top2: token, logits: []))
            }
            return references
        }
    }

    private static func serialReference(
        model: any LanguageModel,
        prompt: [Int]
    ) throws -> SerialReference {
        let cache = try model.newCache(parameters: nil)
        let tokens = MLXArray(prompt.map(Int32.init)).reshaped([1, prompt.count])
        let logits = model(tokens, cache: cache)
        let vocab = logits.dim(logits.ndim - 1)
        let flat = logits.reshaped([-1, vocab])
        let row = flat[flat.dim(0) - 1]
        let order = argSort(row, axis: -1)
        let count = order.dim(0)
        let top1 = count >= 1 ? Int(order[count - 1].item(Int32.self)) : 0
        let top2 = count >= 2 ? Int(order[count - 2].item(Int32.self)) : top1
        return SerialReference(top1: top1, top2: top2, logits: row.asArray(Float.self))
    }

    private static func decodedTokensByID(from outcomes: [ContinuousBatchDecodeOutcome]) -> DecodedProbeTokens {
        var rowsDecoded = 0
        var rowFailures = 0
        var decodedTokenByID: [String: [Int]] = [:]
        for outcome in outcomes {
            switch outcome {
            case .output(let output):
                rowsDecoded += 1
                decodedTokenByID[output.requestID] = output.tokens
            case .rowFailure:
                rowFailures += 1
            }
        }
        return DecodedProbeTokens(
            rowsDecoded: rowsDecoded,
            rowFailures: rowFailures,
            tokens: decodedTokenByID
        )
    }

    private static func divergenceCount(
        decodedByID: [String: [Int]],
        referencesByID: [String: [SerialReference]]
    ) -> Int {
        var divergences = 0
        for (requestID, refs) in referencesByID {
            guard let decoded = decodedByID[requestID],
                  decoded.count == refs.count
            else {
                divergences += max(1, refs.count)
                continue
            }
            for index in refs.indices {
                let otherTop1 = referencesByID
                    .filter { $0.key != requestID }
                    .compactMap { $0.value.indices.contains(index) ? $0.value[index].top1 : nil }
                    .first
                if !Self.batchedTokenIsConformant(
                    decoded: decoded[index],
                    own: refs[index],
                    otherRowSerialTop1: otherTop1,
                    tolerance: Self.batchedArgmaxLogitTolerance
                ) {
                    divergences += 1
                }
            }
        }
        return divergences
    }

    private static func challengeDistinguishing(_ referencesByRow: [[SerialReference]]) -> Bool {
        guard let first = referencesByRow.first, !first.isEmpty else { return false }
        for step in first.indices {
            let top1s = referencesByRow.compactMap { row in
                row.indices.contains(step) ? row[step].top1 : nil
            }
            guard top1s.count == referencesByRow.count, Set(top1s).count == top1s.count else {
                return false
            }
        }
        return true
    }
}
