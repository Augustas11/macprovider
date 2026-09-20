import ArgumentParser
import Foundation
import MLX
import MLXLMCommon

/// Lockstep batched decode over stock `KVCacheSimple`.
///
/// This is the throughput ceiling for SPEC-038 continuous batching on the
/// pinned `mlx-swift-lm` tag: one shared forward, contiguous KV, tokens kept
/// as GPU arrays for the timed window (no per-step `asArray` / actor hop).
/// Dynamic join/leave still needs paging; this path proves whether batching
/// can beat production serial `generate()` on a given tuple.
enum ContiguousBatchedDecode {
    struct Result {
        let rows: Int
        let decodeTokensPerRow: Int
        let decodeStart: Date
        let decodeEnd: Date
        let compiled: Bool

        var perRowTokensPerSecond: Double {
            let wall = max(decodeEnd.timeIntervalSince(decodeStart), 0.000_001)
            return Double(decodeTokensPerRow) / wall
        }

        var aggregateTokensPerSecond: Double {
            perRowTokensPerSecond * Double(rows)
        }

        var rowSamples: [MSBAggregateThroughputInput] {
            (0 ..< rows).map { _ in
                MSBAggregateThroughputInput(
                    decodedTokens: decodeTokensPerRow,
                    decodeStartedAt: decodeStart,
                    decodeEndedAt: decodeEnd
                )
            }
        }
    }

    /// Prefill `[B, S]` then generate `decodeSteps` tokens per row.
    /// The first token from prefill logits is the untimed TTFT boundary;
    /// the timed window is the next `decodeSteps` decode forwards.
    static func run(
        container: ModelContainer,
        prompts: [[Int]],
        decodeSteps: Int,
        compiled: Bool
    ) async throws -> Result {
        let rows = prompts.count
        guard rows >= 1, decodeSteps >= 1 else {
            throw ContiguousBatchedDecodeError.invalidArguments
        }
        let sequenceLength = prompts[0].count
        guard sequenceLength >= 1, prompts.allSatisfy({ $0.count == sequenceLength }) else {
            throw ContiguousBatchedDecodeError.raggedPrompts
        }

        nonisolated(unsafe) var decodeStart = Date()
        nonisolated(unsafe) var decodeEnd = decodeStart

        await container.perform { context in
            let cache = context.model.newCache(parameters: nil)
            let flat = prompts.flatMap { $0.map(Int32.init) }
            let promptArray = MLXArray(flat).reshaped([rows, sequenceLength])
            let prefillLogits = context.model(promptArray, cache: cache)
            eval(prefillLogits)
            eval(cache)

            var current = argMax(prefillLogits[0..., -1, 0...], axis: -1).reshaped([rows, 1])
            eval(current)

            let step = CompiledDecodeStep(model: context.model, cache: cache, enabled: compiled)
            // Untimed TTFT-boundary decode: consume the first generated token
            // so the timed window is decode-only, matching decode-bench.
            let warmLogits = step.step(current)
            current = argMax(warmLogits[0..., -1, 0...], axis: -1).reshaped([rows, 1])
            eval(current)

            decodeStart = Date()
            for _ in 0 ..< decodeSteps {
                let logits = step.step(current)
                current = argMax(logits[0..., -1, 0...], axis: -1).reshaped([rows, 1])
                eval(current)
            }
            Stream().synchronize()
            decodeEnd = Date()
        }

        return Result(
            rows: rows,
            decodeTokensPerRow: decodeSteps,
            decodeStart: decodeStart,
            decodeEnd: decodeEnd,
            compiled: compiled
        )
    }
}

enum ContiguousBatchedDecodeError: Error, Equatable {
    case invalidArguments
    case raggedPrompts
}

enum MSBThroughputEngine: String, Codable, ExpressibleByArgument, CaseIterable {
    case contiguous
    case paged
}
