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
    /// True only when the two challenge rows have DIFFERENT serial reference tokens, so
    /// that a shared forward which swapped or leaked one row's logits into the other would
    /// register as a divergence. A non-distinguishing challenge (identical references) can
    /// never prove isolation, so `proven` requires this to hold.
    let challengeDistinguishing: Bool

    static let failClosed = PagedKVRuntimeMoEProbeResult(
        proven: false,
        rowsDecodedInSharedForward: 0,
        rowFailures: 0,
        crossRowDivergences: 0,
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

            return await container.perform { context in
                let model = context.model
                let stockLayout = model.newCache(parameters: nil)
                let nLayers = stockLayout.filter { $0 is KVCacheSimple }.count
                guard nLayers > 0,
                      stockLayout.allSatisfy({ $0 is KVCacheSimple || $0 is MambaCache })
                else { return .failClosed(nNew: nNew) }

                let stock = Self.greedyGenerate(model: model, promptTokens: promptTokens, nNew: nNew) {
                    model.newCache(parameters: nil)
                }

                PagedKVCache.resetGatherDiagnostics()
                let paged = Self.greedyGenerate(model: model, promptTokens: promptTokens, nNew: nNew) {
                    stockLayout.map { cache in
                        if cache is MambaCache { return MambaCache() as KVCache }
                        return PagedKVCache(
                            blockSizeTokens: blockSizeTokens,
                            maxPhysicalBlocks: maxPhysicalBlocks,
                            poolEpoch: 1,
                            binding: binding
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
    /// then run a batched `[B,1]` shared-forward decode step. Recurrent mixed-cache
    /// layouts additionally remove one peer, join a fresh peer, and run a second batched
    /// `[B,1]` shared-forward step. Each sampled token is compared to an independent
    /// serial `KVCacheSimple` reference for the exact row continuation being decoded.
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
        cacheKinds: [PagedKVSharedForwardBackend.CacheKind]? = nil
    ) async -> PagedKVRuntimeMoEProbeResult {
        guard layerCount > 0, promptA.count >= 1, promptB.count >= 1 else {
            return .failClosed
        }
        do {
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
            let firstSteps = needsRecurrentMembershipProbe ? 2 : 1
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

            _ = try await backend.prefill(rows: [rowA.prefill, rowB.prefill])
            let firstOutcomes: [ContinuousBatchDecodeOutcome]
            if needsRecurrentMembershipProbe {
                firstOutcomes = try await backend.decodeLockstepWindow(rows: [rowA.decode, rowB.decode], steps: firstSteps)
            } else {
                firstOutcomes = try await backend.decode(rows: [rowA.decode, rowB.decode])
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
                    challengeDistinguishing: false
                )
            }

            let referenceA1 = try await Self.serialContinuationReferences(container: container, prompt: promptA, nNew: firstSteps)
            let referenceB1 = try await Self.serialContinuationReferences(container: container, prompt: promptB, nNew: firstSteps)
            let firstCrossRowDivergences = Self.divergenceCount(
                decodedByID: first.tokens,
                referencesByID: [
                    "moe-probe-a": referenceA1,
                    "moe-probe-b": referenceB1,
                ]
            )
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
                    challengeDistinguishing: firstChallengeDistinguishing
                )
            }

            backend.finish(requestID: "moe-probe-b")
            let rowBRejoin = try await Self.makeMoEProbeRow(requestID: "moe-probe-b-rejoin", prompt: promptB, allocator: allocator)
            _ = try await backend.prefill(rows: [rowBRejoin.prefill])
            let rowASecond = try await Self.makeMoEProbeContinuationRow(
                requestID: "moe-probe-a",
                prompt: promptA,
                generatedTokens: firstA,
                currentToken: firstA[firstA.count - 1],
                handle: rowA.handle,
                allocator: allocator
            )
            let secondOutcomes = try await backend.decode(rows: [rowASecond.decode, rowBRejoin.decode])
            try await allocator.endDecodeStep(rowA.handle)
            try await allocator.endDecodeStep(rowBRejoin.handle)

            let second = Self.decodedTokensByID(from: secondOutcomes)

            // Serial reference: the greedy next token after each full prompt, computed
            // independently through stock KVCacheSimple, plus the row's own runner-up and
            // full logits. The second A reference includes A's full first-window
            // continuation, so it validates retained recurrent row state across the
            // B leave / B' join churn.
            let referenceA2 = try await Self.serialContinuationReferences(container: container, prompt: promptA + firstA, nNew: 1)

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
                    "moe-probe-b-rejoin": Array(referenceB1.prefix(1)),
                ]
            )

            // The challenge only proves isolation if the two rows have DIFFERENT serial
            // argmax tokens: with identical references a shared forward that swapped/leaked
            // one row's logits into the other would still match both references and hide
            // the leak. Require distinct references for both shared forwards and fail
            // closed otherwise.
            let challengeDistinguishing = firstChallengeDistinguishing
                && Self.challengeDistinguishing([referenceA2, Array(referenceB1.prefix(1))])
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
                challengeDistinguishing: challengeDistinguishing
            )
        } catch {
            PagedKVRuntimeDiagnostics.log("moe-isolation-probe threw, failing closed: \(error)")
            return .failClosed
        }
    }

    // MARK: - Harness (ported from PagedKVParityTests)

    private static func greedyGenerate(
        model: any LanguageModel,
        promptTokens: [Int],
        nNew: Int,
        makeCache: () -> [KVCache]
    ) -> [Int] {
        let cache = makeCache()
        var out: [Int] = []
        out.reserveCapacity(nNew)
        var y = MLXArray(promptTokens.map { Int32($0) }).reshaped([1, promptTokens.count])
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

    private struct MoEProbeRow {
        let handle: PagedKVBlockTableHandle
        let prefill: ContinuousBatchPrefillInput
        let decode: ContinuousBatchDecodeInput
    }

    private struct DecodedProbeTokens {
        let rowsDecoded: Int
        let rowFailures: Int
        let tokens: [String: [Int]]
    }

    /// Prefill commits `prompt` minus its last token; the batched decode then writes the
    /// final prompt token and samples `decodeSteps` tokens. Mirrors the scheduler's own
    /// prefill/decode split so the probe exercises the real serving contract.
    private static func makeMoEProbeRow(
        requestID: String,
        prompt: [Int],
        allocator: PagedKVBlockAllocator,
        decodeSteps: Int = 1
    ) async throws -> MoEProbeRow {
        let promptLength = prompt.count
        let prefixLength = promptLength - 1
        let targetKVTokenCount = prefixLength + max(1, decodeSteps)
        let handle = try await allocator.allocate(
            conversationKey: requestID,
            maxTokens: max(targetKVTokenCount + 1, 1),
            initialTokens: 0
        )
        if prefixLength > 0 {
            _ = try await allocator.extend(handle, by: prefixLength)
        }
        let prefillBinding = try await allocator.binding(for: handle)
        let prefill = ContinuousBatchPrefillInput(
            requestID: requestID,
            promptTokens: Array(prompt.prefix(prefixLength)),
            binding: prefillBinding,
            promptTokenOffset: 0,
            committedKVTokenCount: 0,
            targetKVTokenCount: prefixLength,
            isFinalChunk: true
        )

        _ = try await allocator.extend(handle, by: max(1, decodeSteps))
        try await allocator.beginDecodeStep(handle)
        let decodeBinding = try await allocator.binding(for: handle)
        let decode = ContinuousBatchDecodeInput(
            requestID: requestID,
            currentToken: prompt[promptLength - 1],
            generatedTokens: [],
            promptTokens: prompt,
            samplerSeed: 0,
            temperature: 0,
            topP: 1,
            presencePenalty: 0,
            frequencyPenalty: 0,
            binding: decodeBinding,
            blockTable: decodeBinding.currentTable,
            committedKVTokenCount: prefixLength,
            targetKVTokenCount: targetKVTokenCount,
            samplerStep: 0
        )
        return MoEProbeRow(handle: handle, prefill: prefill, decode: decode)
    }

    private static func makeMoEProbeContinuationRow(
        requestID: String,
        prompt: [Int],
        generatedTokens: [Int],
        currentToken: Int,
        handle: PagedKVBlockTableHandle,
        allocator: PagedKVBlockAllocator
    ) async throws -> MoEProbeRow {
        let committedKVTokenCount = prompt.count - 1 + generatedTokens.count
        _ = try await allocator.extend(handle, by: 1)
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
            targetKVTokenCount: committedKVTokenCount + 1,
            samplerStep: generatedTokens.count
        )
        return MoEProbeRow(
            handle: handle,
            prefill: ContinuousBatchPrefillInput(
                requestID: requestID,
                promptTokens: [],
                binding: binding,
                promptTokenOffset: committedKVTokenCount,
                committedKVTokenCount: committedKVTokenCount,
                targetKVTokenCount: committedKVTokenCount,
                isFinalChunk: true
            ),
            decode: decode
        )
    }

    /// The stock serial next-token distributions for a greedy continuation. Each step
    /// records the argmax (`top1`), immediate runner-up (`top2`), and full last-position
    /// logits so the batched isolation check can measure any candidate token against
    /// that step's serial distribution.
    private static func serialContinuationReferences(
        container: ModelContainer,
        prompt: [Int],
        nNew: Int
    ) async throws -> [SerialReference] {
        try await container.perform { context in
            var tokens = prompt
            var references: [SerialReference] = []
            references.reserveCapacity(nNew)
            for _ in 0 ..< nNew {
                let reference = Self.serialReference(model: context.model, prompt: tokens)
                references.append(reference)
                tokens.append(reference.top1)
            }
            return references
        }
    }

    /// The stock serial next-token distribution for a prompt: the greedy argmax (`top1`),
    /// the immediate runner-up (`top2`), and the full last-position logits so the batched
    /// isolation check can measure the logit gap of any candidate token against `top1`.
    private static func serialReference(
        container: ModelContainer,
        prompt: [Int]
    ) async throws -> SerialReference {
        await container.perform { context in
            Self.serialReference(model: context.model, prompt: prompt)
        }
    }

    private static func serialReference(model: any LanguageModel, prompt: [Int]) -> SerialReference {
        let cache = model.newCache(parameters: nil)
        let y = MLXArray(prompt.map { Int32($0) }).reshaped([1, prompt.count])
        let logits = model(y, cache: cache)
        let vocab = logits.dim(logits.ndim - 1)
        let flat = logits.reshaped([-1, vocab])
        let row = flat[flat.dim(0) - 1]
        let order = argSort(row, axis: -1) // ascending; last entries are the largest
        let n = order.dim(0)
        let top1 = n >= 1 ? Int(order[n - 1].item(Int32.self)) : 0
        let top2 = n >= 2 ? Int(order[n - 2].item(Int32.self)) : top1
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
