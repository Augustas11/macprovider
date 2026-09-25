import CryptoKit
import Foundation
import MLX
import MLXLMCommon

/// SPEC-038 FR-CB6 / AC-6b: token selection for each row of the shared batched
/// forward.
///
/// Each row samples with exactly the sampler the serial path builds for the same
/// request (`GenerateParameters(temperature:topP:).sampler()` — argmax at
/// temperature 0, nucleus when `0 < topP < 1`, categorical otherwise), applied to
/// that row's own logits. Randomness is row-local: every (request, step) gets its
/// own seed derived from the request's `samplerSeed` and the step index, so no
/// random state is shared across rows or carried between steps. The serial path
/// ignores presence/frequency penalties (it never passes them to MLX), so rows
/// ignore them too — batched output follows the same distribution as serial.
enum ContinuousBatchRowSampler {
    struct Row: Equatable {
        let temperature: Double
        let topP: Double
        let samplerSeed: Int
        let samplerStep: Int
    }

    /// Parameters the batched path can sample exactly as the serial path does.
    /// Anything else is a row failure, never a silent reinterpretation.
    static func supports(temperature: Double, topP: Double) -> Bool {
        temperature.isFinite && temperature >= 0 && topP.isFinite && topP >= 0 && topP <= 1
    }

    /// Per-request sampler seed derived from the scheduler request ID, so
    /// concurrent requests draw independent streams and a replay of the same
    /// request ID (same idempotency fingerprint) reproduces the same sampling.
    static func requestSeed(requestID: String) -> Int {
        let digest = SHA256.hash(data: Data(requestID.utf8))
        return digest.prefix(8).reduce(0) { ($0 << 8) | Int($1) }
    }

    /// splitmix64 over (request seed, step): adjacent steps and seeds map to
    /// unrelated 64-bit seeds.
    static func stepSeed(samplerSeed: Int, samplerStep: Int) -> UInt64 {
        var z = UInt64(bitPattern: Int64(samplerSeed))
            &+ 0x9E37_79B9_7F4A_7C15 &* (UInt64(bitPattern: Int64(samplerStep)) &+ 1)
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Samples one token per row. `logits` is `[rows, vocab]`; the result is
    /// `[rows]` in row order. An all-greedy batch keeps the single batched argmax.
    static func sample(logits: MLXArray, rows: [Row]) -> MLXArray {
        if rows.allSatisfy({ $0.temperature == 0 }) {
            return argMax(logits, axis: -1).asType(.uint32)
        }
        let perRow: [MLXArray] = rows.enumerated().map { index, row in
            let rowLogits = logits[index ..< index + 1]
            if row.temperature == 0 {
                return argMax(rowLogits, axis: -1).reshaped([1]).asType(.uint32)
            }
            let parameters = GenerateParameters(
                temperature: Float(row.temperature),
                topP: Float(row.topP),
                seed: stepSeed(samplerSeed: row.samplerSeed, samplerStep: row.samplerStep)
            )
            return parameters.sampler().sample(logits: rowLogits).reshaped([1]).asType(.uint32)
        }
        return concatenated(perRow, axis: 0)
    }
}
