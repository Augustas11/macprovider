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
    /// Incremental twin: `IncrementalReasoningSplit`.
    static func splitStreamingPrefix(_ text: String) -> Split {
        let split = split(text)
        guard !split.closed else { return split }
        return Split(reasoning: withoutPartialCloseTag(text), answer: "", closed: false)
    }

    /// `text` without a suffix that could still become `</think>`.
    static func withoutPartialCloseTag(_ text: String) -> String {
        var held = 0
        for length in stride(from: text.prefix(closeTag.count - 1).count, through: 1, by: -1)
        where text.hasSuffix(String(closeTag.prefix(length))) {
            held = length
            break
        }
        return String(text.dropLast(held))
    }

    /// GLM answer text with stray think tags removed (#2189). The template
    /// opens `<think>` in the prompt, so the first `</think>` closes the
    /// reasoning (`split`); a `<think>` or `</think>` the model writes after
    /// that is markup, never content. Only the text before the first
    /// `<tool_call>` is touched: from there the tool parser decides, and call
    /// arguments stay byte-exact. A streaming prefix also holds back a tail
    /// that could still become a tag, so the visible text only grows.
    /// Incremental twin for streaming: `IncrementalStrayTagRemoval`.
    static func removingStrayTags(_ text: String, streaming: Bool) -> String {
        let callStart = text.range(of: ToolCallParser.toolCallOpen)?.lowerBound ?? text.endIndex
        var head = String(text[..<callStart])
        guard head.unicodeScalars.contains("<") else { return text }
        head = removingTags(head)
        if streaming, callStart == text.endIndex {
            let held = partialTagLength(head)
            if held > 0 { head = String(head.dropLast(held)) }
        }
        return head + text[callStart...]
    }

    /// Every `<think>` and `</think>` removed, repeatedly: removing one tag
    /// can join the text around it into another. Removal alone decides when
    /// to stop (a Character-wise `contains` would miss a tag Foundation
    /// removes, such as one followed by U+200D), so the result depends only
    /// on the text, not on which tag a check saw first.
    static func removingTags(_ text: String) -> String {
        var text = text
        while true {
            let next = text.replacingOccurrences(of: closeTag, with: "").replacingOccurrences(of: openTag, with: "")
            if next == text { return text }
            text = next
        }
    }

    /// The longest suffix of `text` that could still become a think tag.
    static func partialTagLength(_ text: String) -> Int {
        stride(from: text.prefix(closeTag.count - 1).count, through: 1, by: -1).first(where: { length in
            let tail = String(text.suffix(length))
            return closeTag.hasPrefix(tail) || openTag.hasPrefix(tail)
        }) ?? 0
    }

    /// Applies `filter` (stop strings, hold-back) to the post-think text only
    /// (`StopScope`); the reasoning keeps just the model stop-token
    /// stripping. Returns the raw shape `reasoning</think>answer` so the
    /// caller can split it later.
    static func filtering(
        _ text: String,
        stopTokenFilter: StopTokenFilter,
        reasoningOpen: StopScope,
        filter: (String) -> (text: String, hitStop: Bool)
    ) -> (text: String, hitStop: Bool) {
        guard let closeTag = reasoningOpen.closeTag(for: text) else { return filter(text) }
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

    /// MiniMax M3 adaptive reasoning (#2189). The prompt leaves no block
    /// open: the model writes `<mm:think>…</mm:think>` when it reasons,
    /// usually to open its reply, and `</mm:think>` (or nothing) when it does
    /// not. As the `MiniMaxAI/MiniMax-M3.1-Flash` template reads an assistant
    /// turn, the text between the tags is reasoning wherever a block occurs
    /// and the text outside them is the answer; tools, JSON mode and content
    /// see only the answer. A `</mm:think>` outside a block and a
    /// `<mm:think>` inside one are dropped. Whitespace that starts the
    /// answer or follows a close tag is dropped from it. Request stops run
    /// over the text after the first `</mm:think>` when the reply leads with
    /// a tag (`StopScope.afterMiniMaxThink`), as on rows whose prompt leaves
    /// `<think>` open; over the whole output when it leads with answer text.
    enum MiniMax {
        static let openTag = "<mm:think>"
        static let closeTag = "</mm:think>"

        enum Lead: Equatable {
            /// Only whitespace, or a proper prefix of a tag after it.
            case undecided
            /// Reasoning starts at this index (after `<mm:think>`).
            case thinking(String.Index)
            /// `</mm:think>` with nothing before it: the answer follows.
            case noThinking(String.Index)
            /// Answer text first.
            case answer
        }

        static func lead(_ text: String) -> Lead {
            let rest = text.drop(while: \.isWhitespace)
            if rest.hasPrefix(openTag) { return .thinking(text.index(rest.startIndex, offsetBy: openTag.count)) }
            if rest.hasPrefix(closeTag) { return .noThinking(text.index(rest.startIndex, offsetBy: closeTag.count)) }
            if rest.isEmpty || openTag.hasPrefix(rest) || closeTag.hasPrefix(rest) { return .undecided }
            return .answer
        }

        /// The split of a scanned prefix: text between tags goes to
        /// `append`, each tag to `apply`. The namespace token outside a block
        /// ends the scan (`verbatim`): a tool call follows, and its values
        /// may hold either tag as text.
        struct Scan {
            private(set) var inside = false
            private(set) var opened = false
            private(set) var verbatim = false
            private(set) var reasoning = ""
            private(set) var answer = ""
            private var dropsWhitespace = true

            mutating func append<S: StringProtocol>(_ text: S) {
                if inside {
                    reasoning += text
                    return
                }
                var rest = Substring(text)
                if dropsWhitespace {
                    rest = rest.drop(while: \.isWhitespace)
                    if rest.isEmpty { return }
                    dropsWhitespace = false
                }
                answer += rest
            }

            mutating func apply(tag: String) {
                if tag == openTag {
                    if !inside { opened = true }
                    inside = true
                } else if tag == closeTag {
                    inside = false
                    dropsWhitespace = true
                } else {
                    append(tag)
                    verbatim = true
                }
            }

            var split: Split { Split(reasoning: reasoning, answer: answer, closed: !inside) }
        }

        /// The first tag in `text`, or the namespace token when it comes
        /// first outside a block.
        static func nextTag(in text: Substring, inside: Bool) -> (range: Range<String.Index>, tag: String)? {
            let open = text.range(of: openTag)
            let close = text.range(of: closeTag)
            var next: (range: Range<String.Index>, tag: String)?
            if let open, close.map({ open.lowerBound < $0.lowerBound }) ?? true {
                next = (open, openTag)
            } else if let close {
                next = (close, closeTag)
            }
            if !inside, let namespace = text.range(of: ToolCallParser.miniMaxNamespace),
               next.map({ namespace.lowerBound < $0.range.lowerBound }) ?? true {
                return (namespace, ToolCallParser.miniMaxNamespace)
            }
            return next
        }

        /// `text` without a suffix that could still become a tag.
        static func withoutPartialTags(_ text: Substring) -> Substring {
            let held = (1..<closeTag.count).last(where: { length in
                let tail = String(text.suffix(length))
                return tail.count == length && (openTag.hasPrefix(tail) || closeTag.hasPrefix(tail))
            }) ?? 0
            return text.dropLast(held)
        }

        static func scan(_ text: String, streaming: Bool) -> Scan {
            var scan = Scan()
            var rest = text[...]
            while !scan.verbatim, let next = nextTag(in: rest, inside: scan.inside) {
                scan.append(rest[..<next.range.lowerBound])
                scan.apply(tag: next.tag)
                rest = rest[next.range.upperBound...]
            }
            scan.append(streaming && !scan.verbatim ? withoutPartialTags(rest) : rest)
            return scan
        }

        /// Splits complete (final) output. A block that never closed (for
        /// example `finish_reason` length) runs to the end.
        static func split(_ text: String) -> Split {
            scan(text, streaming: false).split
        }

        /// Splits a streaming prefix: a suffix that could still become a tag
        /// is held, so reasoning and answer only grow. Incremental twin:
        /// `IncrementalMiniMaxReasoningSplit`.
        static func splitStreamingPrefix(_ text: String) -> Split {
            scan(text, streaming: true).split
        }

        /// True when the final output opened a reasoning block.
        static func reasoned(_ text: String) -> Bool {
            scan(text, streaming: false).opened
        }

        /// The tokens of each block, from the one that starts its text
        /// through the one that completes its `</mm:think>` (to the end when
        /// it never closed), summed; a token two blocks share counts once.
        /// None without a block. Prefix decode lengths are monotone, so each
        /// bound is a binary search.
        static func reasoningTokenCount(tokenIDs: [Int], decode: ([Int]) -> String) -> Int {
            guard !tokenIDs.isEmpty else { return 0 }
            let text = decode(tokenIDs)
            var scan = Scan()
            var rest = text[...]
            // UTF-8 offsets of each block's open and close (nil: never closed).
            var blocks: [(open: Int, close: Int?)] = []
            while !scan.verbatim, let next = nextTag(in: rest, inside: scan.inside) {
                scan.append(rest[..<next.range.lowerBound])
                let wasInside = scan.inside
                scan.apply(tag: next.tag)
                if scan.inside, !wasInside {
                    blocks.append((text.utf8.distance(from: text.startIndex, to: next.range.lowerBound), nil))
                }
                if wasInside, !scan.inside {
                    blocks[blocks.count - 1].close = text.utf8.distance(from: text.startIndex, to: next.range.upperBound)
                }
                rest = rest[next.range.upperBound...]
            }
            /// The fewest tokens whose decode is longer than `bytes` UTF-8 bytes.
            func tokens(past bytes: Int) -> Int {
                var low = 1
                var high = tokenIDs.count
                while low < high {
                    let mid = (low + high) / 2
                    if decode(Array(tokenIDs.prefix(mid))).utf8.count > bytes { high = mid } else { low = mid + 1 }
                }
                return low
            }
            var count = 0
            var counted = 0
            for block in blocks {
                let before = max(counted, tokens(past: block.open) - 1)
                let end = block.close.map { tokens(past: $0 - 1) } ?? tokenIDs.count
                count += max(0, end - before)
                counted = max(counted, end)
            }
            return count
        }
    }

    /// Which output text request stops run over (SPEC-018 §3.12). A Bool
    /// literal reads as `reasoningOpen`.
    enum StopScope: Equatable, ExpressibleByBooleanLiteral {
        /// The whole output.
        case whole
        /// The prompt left `<think>` open: the text after the first `</think>`.
        case afterThink
        /// MiniMax (#2189): the text after the first `</mm:think>` unless the
        /// reply leads with answer text (`MiniMax.lead`), then the whole
        /// output. An undecided lead is still reasoning.
        case afterMiniMaxThink

        init(booleanLiteral value: Bool) { self.init(value) }

        init(_ reasoningOpen: Bool) { self = reasoningOpen ? .afterThink : .whole }

        /// The tag that ends the stop-free reasoning region of `text`, or nil
        /// when stops run over all of it.
        func closeTag(for text: String) -> String? {
            switch self {
            case .whole: return nil
            case .afterThink: return ReasoningOutput.closeTag
            case .afterMiniMaxThink: return MiniMax.lead(text) == .answer ? nil : MiniMax.closeTag
            }
        }
    }

    /// Tokens up to and including the one that completes `</think>`: the
    /// smallest prefix whose decode contains the tag (monotone, so a binary
    /// search). All tokens when the tag never closed.
    static func reasoningTokenCount(tokenIDs: [Int], decode: ([Int]) -> String, closeTag: String = ReasoningOutput.closeTag) -> Int {
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
