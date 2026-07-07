import Foundation

/// Model-family KV-quantization family classification.
///
/// Reflects the validated families from upstream `KVQuantEngineScheme`
/// (Darkbloom watch clone `BatchScheduler+KVQuantScheme.swift`):
///
/// - `gemma4`: Gemma 4 MoE — K8V8 affine g128, kernel path, validated upstream.
/// - `gptOSS`: GPT-OSS MoE  — K8V8 affine g64, dequant path, validated upstream.
/// - `unknown`: No validated scheme; fp16 KV default preserved.
public enum KVQuantFamily: Equatable, Sendable {
    case gemma4
    case gptOSS
    case unknown
}

/// Family-based KV-quantization defaults for catalog models.
///
/// Maps model repo IDs to the recommended `GenerateParameters.kvBits` value
/// that autotune would discover in a sweep, based on upstream validation in
/// Darkbloom watch (`BatchScheduler+KVQuantScheme.swift`):
///
/// | Family   | Scheme              | Cache path | Recommended kvBits | KV bytes vs fp16 |
/// |----------|---------------------|------------|-------------------|------------------|
/// | Gemma 4  | K8V8 affine g128    | kernel     | 8                 | ~51.6 %          |
/// | GPT-OSS  | K8V8 affine g64     | dequant    | 8                 | ~53.1 %          |
/// | Others   | not validated       | —          | nil (fp16)        | 100 %            |
///
/// An explicit operator override (`kv_bits` yaml / `MACPROVIDER_KV_BITS` env /
/// `--kv-bits` CLI) always takes precedence and is **not** modified here.
public enum KVQuantRecommendation {

    /// Classify a model repo identifier into a KV-quant family.
    ///
    /// Matching is case-insensitive and prefix-free: the repo ID is
    /// lowercased and checked for the canonical family substring.
    ///
    /// - `"gemma-4"` → `.gemma4`   (matches `google/gemma-4-*`, `mlx-community/gemma-4-*`)
    /// - `"gpt-oss"` → `.gptOSS`   (matches `openai/gpt-oss-*`, `mlx-community/gpt-oss-*`)
    public static func classify(modelID: String) -> KVQuantFamily {
        let lower = modelID.lowercased()
        if lower.contains("gemma-4") { return .gemma4 }
        if lower.contains("gpt-oss") { return .gptOSS }
        return .unknown
    }

    /// Recommended `GenerateParameters.kvBits` for a catalog model.
    ///
    /// Returns `nil` for families without upstream validation. Apply this
    /// value only when the operator has not set an explicit override.
    ///
    /// ```swift
    /// let effectiveKVBits = config.kvBitsOverride
    ///     ?? KVQuantRecommendation.recommendedKVBits(for: config.model)
    /// ```
    public static func recommendedKVBits(for modelID: String) -> Int? {
        switch classify(modelID: modelID) {
        case .gemma4, .gptOSS:
            return 8
        case .unknown:
            return nil
        }
    }
}
