import Foundation

/// Text that reaches an operator's terminal or log collector (#1616).
///
/// Several recovery-diagnostics surfaces print strings that did not originate
/// in this process: a coordinator error summary, a URLError description, a
/// filesystem path derived from wherever the binary happens to live. Any of
/// those can carry control bytes, and `JSONSerialization` emits C1 bytes such
/// as U+009B — the single-byte CSI a naive ESC filter misses — raw rather than
/// as an escape, so JSON output is not a safe harbour either.
///
/// The rule is the same everywhere: keep printable ASCII, drop the rest, and
/// bound the length so an unexpectedly long value cannot flood the output.
enum OperatorDisplayText {
    /// Default bound for short diagnostic reasons.
    static let defaultLimit = 240
    /// Bound for filesystem paths, which are legitimately longer than a reason
    /// but still must not be unbounded.
    static let pathLimit = 1024

    static func sanitized(_ value: String?, limit: Int = defaultLimit) -> String? {
        guard let value else { return nil }
        let kept = value.unicodeScalars.filter { $0.value >= 0x20 && $0.value < 0x7F }
        let collapsed = String(String.UnicodeScalarView(kept))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.isEmpty { return nil }
        return String(collapsed.prefix(limit))
    }
}
