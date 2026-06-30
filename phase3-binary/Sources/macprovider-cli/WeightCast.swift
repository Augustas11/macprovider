import Foundation
import MLX
import MLXLMCommon
import MLXNN

/// fp16 → bf16 weight conversion, gated by `MACPROVIDER_BF16_WEIGHTS`.
///
/// Background: of the d-inference PR #482 optimizations, item #4 (bf16 weight
/// cast) applies to our dense Qwen / Llama model set. Quantized layers (the
/// bulk of *-4bit checkpoints) are skipped via an explicit filter that
/// rejects any descent into a `Quantized` module — the upstream default
/// `Module.filterValidParameters` only rejects "invalid" parameter keys and
/// would otherwise still cast `QuantizedLinear.scales` / `.biases` (both
/// fp16 in 4-bit checkpoints) to bf16, which the dequant path is not
/// designed to handle. Non-floating tensors (e.g. token IDs in embeddings)
/// are also skipped — the map closure inspects `dtype` directly.
///
/// Default OFF in this branch per spec; flip default in a follow-up after
/// live evidence on M-series.
enum WeightCast {
    /// `1`, `true`, or `yes` (case-insensitive) enables the cast at load time.
    static let envFlag = "MACPROVIDER_BF16_WEIGHTS"

    static func isEnabledByEnvironment(
        _ env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let raw = env[envFlag]?.trimmingCharacters(in: .whitespaces).lowercased() else {
            return false
        }
        return raw == "1" || raw == "true" || raw == "yes"
    }

    /// `apply` / `filterMap` filter that accepts every key the default
    /// `Module.filterValidParameters` would accept EXCEPT those whose parent
    /// module is a `Quantized` layer. Rejecting the quantized parent prunes
    /// the entire subtree (its `weight`, `scales`, `biases`), so the bf16
    /// cast never lands on a dequant-path tensor.
    static let nonQuantizedParameterFilter: @Sendable (Module, String, ModuleItem) -> Bool = {
        (module, key, item) in
        if module is any Quantized { return false }
        return Module.filterValidParameters(module, key, item)
    }

    /// In-place cast of all fp16 floating parameters in `model` to bf16.
    /// Returns a histogram (before, after) for diagnostics.
    @discardableResult
    static func castFloat16ToBFloat16(
        _ model: any LanguageModel
    ) -> (before: DTypeHistogram, after: DTypeHistogram) {
        let before = DTypeHistogram(model: model)
        model.apply(filter: nonQuantizedParameterFilter) { array in
            array.dtype == .float16 ? array.asType(.bfloat16) : array
        }
        let after = DTypeHistogram(model: model)
        return (before, after)
    }

    /// Run the cast if the env flag is set, emit a one-line diagnostic on
    /// stderr summarizing the dtype shift, and return whether work happened.
    @discardableResult
    static func applyIfEnabled(
        to model: any LanguageModel,
        env: [String: String] = ProcessInfo.processInfo.environment,
        logger: @Sendable (String) -> Void = { line in
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
    ) -> Bool {
        guard isEnabledByEnvironment(env) else { return false }
        let (before, after) = castFloat16ToBFloat16(model)
        logger(
            "event=bf16_weight_cast before=\(before.summary) after=\(after.summary)"
        )
        return true
    }
}

/// Count of MLXArray parameters bucketed by dtype.
///
/// Only the floating dtypes we plausibly encounter on a loaded LLM are tracked
/// explicitly; everything else lands in `other`. Counts are *parameter tensors*,
/// not element counts — sufficient to see "all fp16 → bf16" at a glance.
struct DTypeHistogram: Sendable, Equatable {
    var float16: Int = 0
    var bfloat16: Int = 0
    var float32: Int = 0
    var other: Int = 0

    init() {}

    init(model: any LanguageModel) {
        // `apply` is invoked for its side-effect of walking parameters; the
        // returned array is identical to the input, so weights are untouched.
        // Use the same non-quantized filter the cast uses so the histogram
        // reflects the actual cast surface (quantized scales/biases are
        // excluded from BOTH the cast and this diagnostic).
        final class Box { var h = DTypeHistogram() }
        let box = Box()
        model.apply(filter: WeightCast.nonQuantizedParameterFilter) { array in
            switch array.dtype {
            case .float16: box.h.float16 += 1
            case .bfloat16: box.h.bfloat16 += 1
            case .float32: box.h.float32 += 1
            default: box.h.other += 1
            }
            return array
        }
        self = box.h
    }

    var summary: String {
        "fp16=\(float16),bf16=\(bfloat16),fp32=\(float32),other=\(other)"
    }
}
