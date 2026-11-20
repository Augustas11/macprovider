#if DEBUG || MACPROVIDER_LAB_HARNESS
import Foundation
import MLX
import MLXLMCommon

/// Issue #2443 lab hook: the top-k logits the serial route's sampler sees at
/// chosen decode indices, with the exact prompt and generated token ids before
/// each one, so `scripts/lab/parity-grid/decode_topk.py` can feed mlx-lm the
/// same ids. Off unless `MACPROVIDER_LAB_DECODE_TOPK` names an absolute file;
/// the call sites exist only in MACPROVIDER_LAB_HARNESS builds.
///
/// - `MACPROVIDER_LAB_DECODE_TOPK_INDICES`: comma-separated decode indices
///   (0 is the first generated token). Required.
/// - `MACPROVIDER_LAB_DECODE_TOPK_K`: entries per record, 2...64, default 5.
///
/// The processor passes logits through unchanged. A recorded index evaluates
/// its logits once; other steps add no evaluation.
enum LabDecodeTopK {
    static let pathKey = "MACPROVIDER_LAB_DECODE_TOPK"
    static let indicesKey = "MACPROVIDER_LAB_DECODE_TOPK_INDICES"
    static let kKey = "MACPROVIDER_LAB_DECODE_TOPK_K"
    static let schema = "macprovider.lab-decode-topk.v1"

    struct Configuration: Sendable, Equatable {
        let path: String
        let indices: Set<Int>
        let k: Int
    }

    struct ConfigurationError: Error, CustomStringConvertible {
        let description: String
    }

    static func configuration(environment: [String: String]) throws -> Configuration? {
        guard let path = environment[pathKey], !path.isEmpty else { return nil }
        guard (path as NSString).isAbsolutePath, !path.utf8.contains(0) else {
            throw ConfigurationError(description: "\(pathKey) must be an absolute path")
        }
        let rawIndices = (environment[indicesKey] ?? "").split(separator: ",", omittingEmptySubsequences: false)
        let indices = rawIndices.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard !rawIndices.isEmpty, indices.count == rawIndices.count,
              indices.allSatisfy({ (0...(1 << 20)).contains($0) }) else {
            throw ConfigurationError(description: "\(indicesKey) must list decode indices 0...1048576")
        }
        var k = 5
        if let rawK = environment[kKey] {
            guard let parsed = Int(rawK), (2...64).contains(parsed) else {
                throw ConfigurationError(description: "\(kKey) must be 2...64")
            }
            k = parsed
        }
        return Configuration(path: path, indices: Set(indices), k: k)
    }

    /// `components` with the recorder appended when the hook is configured;
    /// unchanged otherwise. `promptTokenIDs` is the complete prompt, including
    /// any prefix a reused cache already holds.
    static func appending(
        to components: GenerationComponents,
        promptTokenIDs: [Int],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> GenerationComponents {
        guard let configuration = try configuration(environment: environment) else { return components }
        return components.appendingLogitProcessor {
            Recorder(configuration: configuration, promptTokenIDs: promptTokenIDs)
        }
    }

    struct Recorder: LogitProcessor {
        let configuration: Configuration
        let promptTokenIDs: [Int]
        private let lastIndex: Int
        private var step = 0
        private var sampled: [MLXArray] = []

        init(configuration: Configuration, promptTokenIDs: [Int]) {
            self.configuration = configuration
            self.promptTokenIDs = promptTokenIDs
            self.lastIndex = configuration.indices.max() ?? 0
        }

        mutating func prompt(_ prompt: MLXArray) {}

        func process(logits: MLXArray) -> MLXArray {
            guard configuration.indices.contains(step) else { return logits }
            do {
                try LabOutputTokenCapture.appendRecord(record(logits: logits), path: configuration.path)
            } catch {
                FileHandle.standardError.write(Data("lab decode top-k: index \(step) not recorded: \(error)\n".utf8))
            }
            return logits
        }

        mutating func didSample(token: MLXArray) {
            if step < lastIndex { sampled.append(token) }
            step += 1
        }

        /// One record for the current step. `logits` is the sampler's
        /// `[rows, vocab]` input; row 0 is recorded.
        func record(logits: MLXArray) -> [String: Any] {
            let row = logits.reshaped([-1, logits.dim(-1)])[0]
            let values = row.asType(.float32)
            let k = min(configuration.k, row.dim(0))
            let order = argSort(-values)[0 ..< k]
            let top = take(values, order)
            let generated = sampled.isEmpty
                ? MLXArray([Int32]()) : concatenated(sampled.map { $0.reshaped([-1]).asType(.int32) })
            eval(order, top, generated)
            return [
                "schema": LabDecodeTopK.schema,
                "decode_index": step,
                "prompt_token_ids": promptTokenIDs,
                "generated_token_ids": generated.asArray(Int32.self).map(Int.init),
                "top_ids": order.asArray(Int32.self).map(Int.init),
                "top_logits": top.asArray(Float.self).map(Double.init),
                "dtype": String(describing: row.dtype),
            ]
        }
    }
}
#endif
