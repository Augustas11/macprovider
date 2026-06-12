import Foundation

/// Pure, network-free heuristic for "does this MLX model fit this Mac's RAM?"
///
/// Mirrors the install.sh `hf_check_model` fit math (SPEC-003 v0.9 FR-D2.1
/// step 4) so a model accepted at install time is judged the same way at
/// `models switch` time. Both surfaces use the same headroom constants and
/// the same name-parsing rules — drift between them would mean a model the
/// installer accepted could be rejected by `models switch` (or vice versa).
public enum ModelFit {
    /// Headroom above weight size for the "comfortable fit" tier. Covers
    /// macOS (3–4 GB), the Metal/mlx runtime, the binary, and a KV cache for
    /// typical context lengths. The 6 GB value is calibrated against the
    /// existing installer RAM-tier defaults: 7B (~4 GB weights) → 16 GB Mac
    /// is comfortable (4 + 6 = 10 ≤ 16), 7B on 8 GB Mac is not.
    public static let comfortableHeadroomGB: Int = 6

    /// Headroom for the "tight fit" tier — model loads but the box is close
    /// to swapping under any concurrent load. Below this threshold the model
    /// is rejected outright as "won't fit".
    public static let tightHeadroomGB: Int = 2

    public enum Verdict: Sendable, Equatable {
        case fits(estGB: Int, ramGB: Int)
        case tight(estGB: Int, ramGB: Int)
        case wontFit(estGB: Int, ramGB: Int)
        case unknown(reason: String)
    }

    /// Detected physical RAM rounded up to whole GB. Uses Foundation's
    /// `ProcessInfo.physicalMemory` (which wraps `host_info(HOST_BASIC_INFO)`
    /// on Darwin) so callers don't need to drop to `sysctl`.
    public static func detectRAMGB() -> Int {
        let bytes = ProcessInfo.processInfo.physicalMemory
        let oneGB: UInt64 = 1_073_741_824
        return Int((bytes + oneGB - 1) / oneGB)
    }

    /// Estimate weight size in GB from a HuggingFace repo name. Returns nil
    /// if the name doesn't carry a `<N>B` parameter-count suffix — callers
    /// treat nil as "skip fit check, surface a 'could not estimate' note".
    ///
    /// Parameters are parsed from the first `[0-9]+(\.[0-9]+)?B` substring
    /// (case-insensitive). Quantization is inferred from substrings:
    ///   4bit / -q4 / _q4  → 0.5 bytes/param
    ///   8bit / -q8 / _q8  → 1.0 bytes/param
    ///   bf16 / fp16 / -f16 → 2.0 bytes/param
    ///   anything else      → 2.0 bytes/param (assume full-precision fallback)
    public static func estimateWeightSizeGB(modelID: String) -> Int? {
        guard let params = parseParamsBillions(from: modelID) else {
            return nil
        }
        let bytesPerParam = inferBytesPerParam(from: modelID)
        let gb = max(1.0, params * bytesPerParam)
        return Int(gb.rounded())
    }

    /// Verdict for a (modelID, ramGB) pair. RAM is supplied explicitly so
    /// tests don't depend on host RAM. Production callers pass
    /// `detectRAMGB()`.
    public static func evaluate(modelID: String, ramGB: Int) -> Verdict {
        guard let estGB = estimateWeightSizeGB(modelID: modelID) else {
            return .unknown(reason: "could not estimate weight size from \"\(modelID)\"")
        }
        if ramGB >= estGB + comfortableHeadroomGB {
            return .fits(estGB: estGB, ramGB: ramGB)
        }
        if ramGB >= estGB + tightHeadroomGB {
            return .tight(estGB: estGB, ramGB: ramGB)
        }
        return .wontFit(estGB: estGB, ramGB: ramGB)
    }

    // MARK: - Internals (internal for testability)

    static func parseParamsBillions(from modelID: String) -> Double? {
        // Round-2 (codex code MAJOR): match Mixture-of-Experts "NxMB" shape
        // (e.g. "Mixtral-8x7B" — 8 experts of 7B each, total ~56B params)
        // BEFORE the single-N pattern. Otherwise the old regex captured
        // only the "7B" half and undercounted memory by N×, letting the
        // switch fit guard pass a model that would OOM the host.
        if let moe = matchFirst(pattern: #"([0-9]+)x([0-9]+(\.[0-9]+)?)[Bb]"#, in: modelID),
           let experts = Double(moe.captures[1]),
           let perExpert = Double(moe.captures[2]) {
            return experts * perExpert
        }

        // Regex compiled at first use; NSRegularExpression isn't Sendable so
        // we just rebuild it per call (tiny cost vs. avoiding shared mutable
        // state under StrictConcurrency).
        guard let match = matchFirst(pattern: #"[0-9]+(\.[0-9]+)?[Bb]"#, in: modelID) else {
            return nil
        }
        // Drop the trailing B/b from the full match.
        let raw = match.fullMatch
        return Double(raw.dropLast())
    }

    private struct RegexMatch {
        let fullMatch: Substring
        let captures: [String]
    }

    private static func matchFirst(pattern: String, in input: String) -> RegexMatch? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let nsRange = NSRange(input.startIndex..., in: input)
        guard let match = regex.firstMatch(in: input, range: nsRange),
              let fullRange = Range(match.range, in: input) else {
            return nil
        }
        var captures: [String] = [String(input[fullRange])]
        for groupIndex in 1..<match.numberOfRanges {
            if let r = Range(match.range(at: groupIndex), in: input) {
                captures.append(String(input[r]))
            } else {
                captures.append("")
            }
        }
        return RegexMatch(fullMatch: input[fullRange], captures: captures)
    }

    static func inferBytesPerParam(from modelID: String) -> Double {
        let lower = modelID.lowercased()
        if lower.contains("4bit") || lower.contains("-q4") || lower.contains("_q4") {
            return 0.5
        }
        if lower.contains("8bit") || lower.contains("-q8") || lower.contains("_q8") {
            return 1.0
        }
        if lower.contains("bf16") || lower.contains("fp16") || lower.contains("-f16") {
            return 2.0
        }
        return 2.0
    }
}
