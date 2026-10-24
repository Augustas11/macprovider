import Foundation
import MLX
import MLXLMCommon
import MacProviderCore

/// A row-owned pool proof is deliberately disjoint from paged-gather proof.
/// The block allocator used by the scheduler bounds logical admission only;
/// DeepSeek's window, compression pools and indexer never claim paged storage.
struct DeepseekV4RowPoolParityProof: Equatable, Sendable {
    let layerCount: Int
    let tokensPerRow: Int
    let exactParity: Bool
    let raggedOffsets: Bool
    let membershipTransitionParity: Bool
    let topologyVerified: Bool

    var established: Bool {
        layerCount > 0
            && tokensPerRow >= PagedKVRuntimeParityProbe.sharedForwardParityTokens
            && exactParity && raggedOffsets && membershipTransitionParity && topologyVerified
    }
}

enum DeepseekV4RuntimeParityProbe {
    private enum ProbeError: Error { case invalidResult }

    static func run(
        container: ModelContainer,
        blockSizeTokens: Int,
        maxPhysicalBlocks: Int,
        cacheKinds: [PagedKVSharedForwardBackend.CacheKind],
        promptA: [Int],
        promptB: [Int]
    ) async -> (PagedKVRuntimeParityProbeResult?, PagedKVRuntimeMoEProbeResult?) {
        let count = PagedKVRuntimeParityProbe.sharedForwardParityTokens
        do {
            guard !promptA.isEmpty, !promptB.isEmpty, promptA.count != promptB.count else {
                throw ProbeError.invalidResult
            }
            let topologyVerified = try await container.perform { context in
                PagedKVSharedForwardBackend.CacheKind.kinds(from: try context.model.newCache(parameters: nil)) == cacheKinds
            }
            guard topologyVerified else { throw ProbeError.invalidResult }
            let references = try await container.perform { context in
                try [serialTokens(model: context.model, prompt: promptA, count: count + 2),
                     serialTokens(model: context.model, prompt: promptB, count: count + 2)]
            }
            let backend = DeepseekV4ContinuousBatchBackend(container: container)
            let allocator = try PagedKVBlockAllocator(
                blockSizeTokens: blockSizeTokens, maxPhysicalBlocks: maxPhysicalBlocks
            )
            let a = try await prefill(id: "pool-probe-a", prompt: promptA, count: count + 2,
                                      backend: backend, allocator: allocator)
            let b = try await prefill(id: "pool-probe-b", prompt: promptB, count: count + 2,
                                      backend: backend, allocator: allocator)
            var generated: [String: [Int]] = [a.id: [a.first], b.id: [b.first]]
            for _ in 1..<count {
                try Task.checkCancellation()
                try await decode(rows: [a, b], generated: &generated, backend: backend, allocator: allocator)
            }
            let steadyParity = generated[a.id] == Array(references[0].prefix(count))
                && generated[b.id] == Array(references[1].prefix(count))
            backend.finish(requestID: a.id)
            try await allocator.release(a.handle)
            let c = try await prefill(id: "pool-probe-c", prompt: promptA, count: count + 2,
                                      backend: backend, allocator: allocator)
            generated[c.id] = [c.first]
            // Reorder the survivor and newcomer; neither position in the batch
            // nor a removed row's former position may become cache identity.
            try await decode(rows: [c, b], generated: &generated, backend: backend, allocator: allocator)
            try await decode(rows: [b, c], generated: &generated, backend: backend, allocator: allocator)
            let membershipParity = generated[b.id] == references[1]
                && generated[c.id] == Array(references[0].prefix(3))
            backend.finish(requestID: b.id)
            backend.finish(requestID: c.id)
            try await allocator.release(b.handle)
            try await allocator.release(c.handle)
            let proof = DeepseekV4RowPoolParityProof(
                layerCount: cacheKinds.count, tokensPerRow: count,
                exactParity: steadyParity, raggedOffsets: promptA.count != promptB.count,
                membershipTransitionParity: membershipParity, topologyVerified: topologyVerified
            )
            let distinguishing = references[0] != references[1]
            return (
                PagedKVRuntimeParityProbeResult(
                    established: proof.established, nLayers: cacheKinds.count, nNew: count,
                    gatherKernelCalls: 0, maxLogicalBlocks: 0, nonIdentityPermutation: false,
                    rowPoolProof: proof
                ),
                PagedKVRuntimeMoEProbeResult(
                    proven: proof.established && distinguishing, rowsDecodedInSharedForward: 2,
                    rowFailures: 0, crossRowDivergences: steadyParity && membershipParity ? 0 : 1,
                    sharedForwardParityProven: proof.established, parityTokensCompared: count,
                    challengeDistinguishing: distinguishing
                )
            )
        } catch {
            return (.failClosed(nNew: count), .failClosed)
        }
    }

    private struct Row {
        let id: String
        let prompt: [Int]
        let handle: PagedKVBlockTableHandle
        let first: Int
    }

    /// Keep exactly the reference partition: 2048-token chunks of all but
    /// the final prompt token, followed by that token alone.
    private static func prefill(
        id: String, prompt: [Int], count: Int,
        backend: DeepseekV4ContinuousBatchBackend, allocator: PagedKVBlockAllocator
    ) async throws -> Row {
        let handle = try await allocator.allocate(
            conversationKey: id, maxTokens: prompt.count + count + 1, initialTokens: 0
        )
        var offset = 0
        var first: Int?
        while offset < prompt.count {
            let end = offset == prompt.count - 1 ? prompt.count : min(offset + 2048, prompt.count - 1)
            _ = try await allocator.extend(handle, by: end - offset)
            let binding = try await allocator.binding(for: handle)
            let outputs = try await backend.prefill(rows: [ContinuousBatchPrefillInput(
                requestID: id, promptTokens: Array(prompt[offset..<end]), binding: binding,
                promptTokenOffset: offset, committedKVTokenCount: offset,
                targetKVTokenCount: end, isFinalChunk: end == prompt.count
            )])
            guard outputs.count == 1, outputs[0].requestID == id, outputs[0].failureCode == nil else {
                throw ProbeError.invalidResult
            }
            if end == prompt.count { first = outputs[0].sampledToken }
            offset = end
        }
        guard let first else { throw ProbeError.invalidResult }
        return Row(id: id, prompt: prompt, handle: handle, first: first)
    }

    private static func decode(
        rows: [Row], generated: inout [String: [Int]],
        backend: DeepseekV4ContinuousBatchBackend, allocator: PagedKVBlockAllocator
    ) async throws {
        var inputs: [ContinuousBatchDecodeInput] = []
        for row in rows {
            guard let tokens = generated[row.id], let current = tokens.last else { throw ProbeError.invalidResult }
            let committed = row.prompt.count + tokens.count - 1
            _ = try await allocator.extend(row.handle, by: 1)
            try await allocator.beginDecodeStep(row.handle)
            let binding = try await allocator.binding(for: row.handle)
            inputs.append(ContinuousBatchDecodeInput(
                requestID: row.id, currentToken: current, generatedTokens: tokens, promptTokens: row.prompt,
                samplerSeed: 0, temperature: 0, topP: 1, presencePenalty: 0, frequencyPenalty: 0,
                binding: binding, blockTable: binding.currentTable,
                committedKVTokenCount: committed, targetKVTokenCount: committed + 1,
                samplerStep: tokens.count
            ))
        }
        let outcomes = try await backend.decode(rows: inputs)
        for row in rows { try await allocator.endDecodeStep(row.handle) }
        guard outcomes.count == rows.count else { throw ProbeError.invalidResult }
        var seen = Set<String>()
        for outcome in outcomes {
            guard case .output(let output) = outcome, output.tokens.count == 1,
                  rows.contains(where: { $0.id == output.requestID }), seen.insert(output.requestID).inserted
            else { throw ProbeError.invalidResult }
            generated[output.requestID, default: []].append(contentsOf: output.tokens)
        }
    }

    private static func serialTokens(model: any LanguageModel, prompt: [Int], count: Int) throws -> [Int] {
        let caches = try model.newCache(parameters: nil)
        var offset = 0
        while offset < prompt.count - 1 {
            try Task.checkCancellation()
            let end = min(offset + 2048, prompt.count - 1)
            _ = model(MLXArray(prompt[offset..<end].map(Int32.init)).reshaped([1, end - offset]), cache: caches)
            eval(caches.flatMap(\.state))
            offset = end
        }
        var current = prompt[prompt.count - 1]
        var tokens: [Int] = []
        for _ in 0..<count {
            try Task.checkCancellation()
            let logits = model(MLXArray([Int32(current)]).reshaped([1, 1]), cache: caches)
            let vocab = logits.dim(logits.ndim - 1)
            let flat = logits.reshaped([-1, vocab])
            current = Int(argMax(flat[flat.dim(0) - 1], axis: -1).item(Int32.self))
            eval(caches.flatMap(\.state))
            tokens.append(current)
        }
        return tokens
    }
}
