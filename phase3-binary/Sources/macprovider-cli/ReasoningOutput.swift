import Foundation
import MacProviderCore

/// SPEC-018 §3.12: when the rendered generation prompt ends inside an open
/// `<think>`, the output up to the first `</think>` is reasoning. Stop
/// strings, JSON-mode validation and tool parsing see only the text after it.
/// The runtime keeps the raw `reasoning</think>answer` text through its stop
/// filters and splits it here, so every serving path splits the same way.
enum ReasoningOutput {
    static let openTag = "<think>"
    static let closeTag = "</think>"

    struct Split: Equatable {
        /// Reasoning text, without the closing tag.
        let reasoning: String
        /// Post-think text with leading whitespace removed.
        let answer: String
        /// The closing tag was generated.
        let closed: Bool
    }

    /// Splits complete (final) output. Without a closing tag the whole output
    /// is reasoning: the model never reached its answer.
    static func split(_ text: String) -> Split {
        guard let close = text.range(of: closeTag) else {
            return Split(reasoning: text, answer: "", closed: false)
        }
        let answer = text[close.upperBound...].drop(while: { $0.isWhitespace })
        return Split(reasoning: String(text[..<close.lowerBound]), answer: String(answer), closed: true)
    }

    /// Splits a streaming prefix. An unclosed reasoning prefix holds back a
    /// suffix that could still become `</think>`.
    static func splitStreamingPrefix(_ text: String) -> Split {
        let split = split(text)
        guard !split.closed else { return split }
        var held = 0
        for length in stride(from: min(closeTag.count - 1, text.count), through: 1, by: -1)
        where text.hasSuffix(String(closeTag.prefix(length))) {
            held = length
            break
        }
        return Split(reasoning: String(text.dropLast(held)), answer: "", closed: false)
    }

    /// Applies `filter` (stop strings, hold-back) to the post-think text only;
    /// the reasoning keeps just the model stop-token stripping. Returns the
    /// raw shape `reasoning</think>answer` so the caller can split it later.
    static func filtering(
        _ text: String,
        stopTokenFilter: StopTokenFilter,
        reasoningOpen: Bool,
        filter: (String) -> (text: String, hitStop: Bool)
    ) -> (text: String, hitStop: Bool) {
        guard reasoningOpen else { return filter(text) }
        guard let close = text.range(of: closeTag) else {
            return (stopTokenFilter.stripping(from: text, joiner: ControlTextShield.markString), false)
        }
        let head = stopTokenFilter.stripping(from: String(text[..<close.upperBound]), joiner: ControlTextShield.markString)
        let tail = filter(String(text[close.upperBound...]))
        return (head + tail.text, tail.hitStop)
    }

    /// True when the decoded tail of a rendered prompt leaves a think block
    /// open for the generation (for example GLM-5.3's `<|assistant|><think>`).
    static func promptLeavesThinkOpen(_ promptTail: String) -> Bool {
        guard let open = promptTail.range(of: openTag, options: .backwards) else { return false }
        return promptTail.range(of: closeTag, range: open.upperBound..<promptTail.endIndex) == nil
            && promptTail[open.upperBound...].allSatisfy(\.isWhitespace)
    }

    /// Tokens up to and including the one that completes `</think>`: the
    /// smallest prefix whose decode contains the tag (monotone, so a binary
    /// search). All tokens when the tag never closed.
    static func reasoningTokenCount(tokenIDs: [Int], decode: ([Int]) -> String) -> Int {
        guard !tokenIDs.isEmpty, decode(tokenIDs).contains(closeTag) else { return tokenIDs.count }
        var low = 1
        var high = tokenIDs.count
        while low < high {
            let mid = (low + high) / 2
            if decode(Array(tokenIDs.prefix(mid))).contains(closeTag) {
                high = mid
            } else {
                low = mid + 1
            }
        }
        return low
    }
}
