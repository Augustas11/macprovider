import Foundation
import MacProviderCore
import MLXLMCommon

/// #2317: streaming output filtering whose work per generated token does not
/// grow with the output. `streamingSafePrefix` and `applyOutputFilters` stay
/// the reference: every result here is the one they return for the whole
/// text, and the differential tests in `IncrementalOutputFilterTests` check
/// it piece by piece.
extension ModelRuntime {
    /// Detokenizes a growing token list with the tokenizer's own whole-list
    /// `decode`, but over a bounded window: the text of the tokens before the
    /// window is kept, and each step decodes only a lookback segment plus the
    /// tokens after it. The text is `decode(allTokens)` as long as the decode
    /// of the tokens after a lookback of `lookbackScalars` scalars (and at
    /// least four tokens) does not depend on earlier tokens. That holds for
    /// the Hugging Face ByteLevel, Metaspace, Replace/ByteFallback/Fuse/Strip
    /// and WordPiece decoders, the tokenization-space cleanup, and the
    /// control-text shield when the lookback covers its longest control text.
    /// A window decode that does not start with the lookback's own decode
    /// (a decoder that rewrote earlier text) falls back to one whole decode
    /// and restarts the window from the first token.
    final class WindowedTextDecoder: @unchecked Sendable {
        struct Output {
            let text: String
            /// UTF-8 bytes at the start of `text` that equal the previous
            /// output's (a hint for `IncrementalStreamFilter.update`).
            let unchangedPrefixUTF8: Int
        }

        static let minimumLookbackScalars = 64

        /// A lookback that covers the tokenizer's longest control text twice.
        static func lookbackScalars(for tokenizer: any MLXLMCommon.Tokenizer) -> Int {
            let control = ControlTokenTable.of(tokenizer)?.matcher.maxLength ?? 0
            return max(minimumLookbackScalars, 2 * control + 8)
        }

        private let decode: ([Int]) -> String
        private let lookbackScalars: Int
        private var tokens: [Int] = []
        /// The window starts at `anchor`; `head` is the exact text of
        /// `tokens[..<read]` and `anchorText` the decode of
        /// `tokens[anchor..<read]`.
        private var anchor = 0
        private var read = 0
        private var head = ""
        private var anchorText = ""
        /// `text` after `head`.
        private var added = ""
        private(set) var text = ""
        /// Whole-list decodes after a window mismatch (test observability).
        private(set) var fallbackCount = 0
        /// Tokens decoded through `decode`, summed over calls (test hook).
        private(set) var decodedTokenCount = 0

        init(decode: @escaping ([Int]) -> String, lookbackScalars: Int = WindowedTextDecoder.minimumLookbackScalars) {
            self.decode = decode
            self.lookbackScalars = max(1, lookbackScalars)
        }

        convenience init(tokenizer: any MLXLMCommon.Tokenizer) {
            self.init(decode: { tokenizer.decode(tokenIds: $0) }, lookbackScalars: WindowedTextDecoder.lookbackScalars(for: tokenizer))
        }

        /// `generatedTokenIDs` is the whole generated list so far.
        func update(cumulativeTokens generatedTokenIDs: [Int]) -> Output {
            if generatedTokenIDs.count < tokens.count {
                restart()
                tokens = []
            }
            return append(Array(generatedTokenIDs.dropFirst(tokens.count)))
        }

        func append(_ newTokens: [Int]) -> Output {
            tokens.append(contentsOf: newTokens)
            let previousText = text
            let previousAdded = added
            let window = decodeCounted(Array(tokens[anchor...]))
            let unchanged: Int
            if window.utf8.starts(with: anchorText.utf8) {
                // `anchorText` is valid UTF-8, so its end is a scalar boundary
                // of `window` as well.
                let start = window.utf8.index(window.utf8.startIndex, offsetBy: anchorText.utf8.count)
                added = String(window[start...])
                text = head + added
                unchanged = head.utf8.count + Self.commonPrefixUTF8(previousAdded, added)
            } else {
                fallbackCount += 1
                restart()
                text = decodeCounted(tokens)
                added = text
                unchanged = Self.commonPrefixUTF8(previousText, text)
            }
            advanceIfStable()
            return Output(text: text, unchangedPrefixUTF8: unchanged)
        }

        private func restart() {
            anchor = 0
            read = 0
            head = ""
            anchorText = ""
            added = ""
        }

        private func decodeCounted(_ ids: [Int]) -> String {
            decodedTokenCount += ids.count
            return decode(ids)
        }

        /// Moves the window once the text after `head` is long enough and its
        /// end can no longer be rewritten by a later token.
        private func advanceIfStable() {
            guard tokens.count - read >= 4, Self.isStableEnd(text) else { return }
            var scalars = 0
            for _ in added.unicodeScalars {
                scalars += 1
                if scalars >= lookbackScalars { break }
            }
            guard scalars >= lookbackScalars else { return }
            anchorText = anchor == read && read == 0 ? text : decodeCounted(Array(tokens[read...]))
            anchor = read
            read = tokens.count
            head = text
            added = ""
        }

        /// No incomplete UTF-8 tail and no tail a cleanup rule could rewrite.
        static func isStableEnd(_ text: String) -> Bool {
            guard let last = text.unicodeScalars.last, last != "\u{FFFD}" else { return false }
            var view = String.UnicodeScalarView()
            view.append(contentsOf: text.unicodeScalars.suffix(8))
            let tail = String(view)
            return SerialStreamingTextEmitter.cleanupStablePrefix(of: tail, includesDecoderPendingPrefixes: true) == tail
        }

        static func commonPrefixUTF8(_ lhs: String, _ rhs: String) -> Int {
            var count = 0
            for (left, right) in zip(lhs.utf8, rhs.utf8) {
                guard left == right else { break }
                count += 1
            }
            return count
        }
    }

    /// The incremental counterpart of `streamingSafePrefix` (with or without
    /// an open reasoning block) and of the three-argument
    /// `applyOutputFilters`. Feed it the whole decoded text after every
    /// step; it returns what the reference function returns for that text.
    ///
    /// Committed: a raw prefix up to a cut, its stop-token-stripped text, and
    /// the last few Characters of both. A cut is placed only where
    /// - both neighbouring scalars always form a grapheme break whatever
    ///   surrounds them (so Character, Foundation and canonical-equivalence
    ///   matching agree on either side), and are not CR LF;
    /// - no stop-token occurrence (overlapping ones included) covers either
    ///   neighbouring scalar;
    /// - at least twice the longest token's scalars (plus `</think>`) of raw
    ///   text follow, so no later token can complete a stop token across it.
    /// Stripping then splits at the cut (the joiner decisions on either side
    /// see a non-empty neighbour in both texts), so the stripped text is the
    /// committed stripped text plus the stripped tail. Request stops and the
    /// stop-candidate holdback run over the committed Characters' overlap
    /// plus the stripped tail: no request stop lies wholly inside committed
    /// text (it was searched before it was committed), and the overlap is
    /// longer than any candidate.
    ///
    /// Fallbacks to the whole text, all still exact: a raw text that changed
    /// before the cut (the state restarts from the first byte), a reasoning
    /// close tag found within two token lengths of the cut (its head is
    /// stripped whole once), and an incomplete-UTF-8 trim that reaches the
    /// start of the overlap (trimmed over the whole safe text).
    final class IncrementalStreamFilter: @unchecked Sendable {
        enum Mode: Equatable {
            /// `streamingSafePrefix(_:stopTokenFilter:requestStops:reasoningOpen:)`.
            case streamingSafePrefix(reasoningOpen: Bool)
            /// `applyOutputFilters(_:stopTokenFilter:requestStops:)`.
            case outputFilters
        }

        private let stopTokenFilter: StopTokenFilter
        private let requestStops: [String]
        private let mode: Mode
        private var previousRaw = ""
        /// Reasoning rows: the text up to the first `</think>`.
        private var thinking: Stream?
        /// The text after `</think>` on reasoning rows; all text otherwise.
        private var answer: Stream?
        private var closeEnd: Int?
        private var head = ""
        private let counter = WorkCounter()

        /// UTF-8 bytes the filter has stripped or searched, summed over
        /// calls (test hook for the complexity guard).
        var scannedUTF8: Int { counter.value }
        /// Whole-text restarts (test observability).
        private(set) var restartCount = 0

        init(stopTokenFilter: StopTokenFilter, requestStops: [String], mode: Mode) {
            self.stopTokenFilter = stopTokenFilter
            self.requestStops = requestStops.filter { !$0.isEmpty }
            self.mode = mode
            start()
        }

        convenience init(stopTokenFilter: StopTokenFilter, requestStops: [String], reasoningOpen: Bool) {
            self.init(stopTokenFilter: stopTokenFilter, requestStops: requestStops, mode: .streamingSafePrefix(reasoningOpen: reasoningOpen))
        }

        /// `unchangedPrefixUTF8`: bytes of `text` known to equal the previous
        /// text's (from `WindowedTextDecoder`). Without it the committed
        /// bytes are compared.
        func update(_ text: String, unchangedPrefixUTF8: Int? = nil) -> (text: String, hitStop: Bool) {
            var raw = text
            raw.makeContiguousUTF8()
            let needed = dependentPrefixUTF8
            if needed > 0 {
                let unchanged = raw.utf8.count >= needed
                    && (unchangedPrefixUTF8.map { $0 >= needed } ?? Self.sharesPrefix(previousRaw, raw, utf8Count: needed))
                if !unchanged {
                    restartCount += 1
                    start()
                }
            }
            previousRaw = raw
            return compute(raw)
        }

        private var dependentPrefixUTF8: Int {
            if closeEnd != nil { return answer?.cut ?? 0 }
            return (thinking ?? answer)?.cut ?? 0
        }

        private func start() {
            closeEnd = nil
            head = ""
            switch mode {
            case .streamingSafePrefix(reasoningOpen: true):
                thinking = Stream(origin: 0, filter: stopTokenFilter, requestStops: [], holdback: false, watchesCloseTag: true, counter: counter)
                answer = nil
            case .streamingSafePrefix(reasoningOpen: false):
                thinking = nil
                answer = Stream(origin: 0, filter: stopTokenFilter, requestStops: requestStops, holdback: true, watchesCloseTag: false, counter: counter)
            case .outputFilters:
                thinking = nil
                answer = Stream(origin: 0, filter: stopTokenFilter, requestStops: requestStops, holdback: false, watchesCloseTag: false, counter: counter)
            }
        }

        private func compute(_ raw: String) -> (text: String, hitStop: Bool) {
            guard let thinking else {
                let result = answer!.process(raw)
                return (result.text, result.hitStop)
            }
            // Until the answer commits, the first scalar after `</think>` can
            // still change whether (Character-wise) the tag matched there.
            if closeEnd == nil || answer?.cut == closeEnd {
                let scan = thinking.process(raw)
                if scan.closeEnd != closeEnd {
                    if closeEnd != nil {
                        restartCount += 1
                        start()
                        return compute(raw)
                    }
                    guard let found = scan.closeEnd else { return (scan.text, false) }
                    closeEnd = found
                    head = thinking.strippedHead(raw, through: found)
                    answer = Stream(origin: found, filter: stopTokenFilter, requestStops: requestStops, holdback: true, watchesCloseTag: false, counter: counter)
                }
                if closeEnd == nil { return (scan.text, false) }
            }
            let result = answer!.process(raw)
            return (head + result.text, result.hitStop)
        }

        static func sharesPrefix(_ lhs: String, _ rhs: String, utf8Count count: Int) -> Bool {
            guard lhs.utf8.count >= count, rhs.utf8.count >= count else { return false }
            if let equal = lhs.utf8.withContiguousStorageIfAvailable({ left in
                rhs.utf8.withContiguousStorageIfAvailable { right in
                    memcmp(left.baseAddress!, right.baseAddress!, count) == 0
                }
            }), let equal {
                return equal
            }
            return lhs.utf8.prefix(count).elementsEqual(rhs.utf8.prefix(count))
        }

        final class WorkCounter {
            var value = 0
        }

        /// The filter over `raw[origin...]` for one of the modes above.
        final class Stream {
            struct Result {
                let text: String
                let hitStop: Bool
                /// UTF-8 end of the first `</think>`, when watched and found.
                let closeEnd: Int?
            }

            private let filter: StopTokenFilter
            private let requestStops: [String]
            private let holdback: Bool
            private let watchesCloseTag: Bool
            private let counter: WorkCounter
            private let candidates: [String]
            /// Characters of committed stripped / raw text kept for searches.
            private let strippedOverlapCount: Int
            private let rawOverlapCount: Int
            /// Scalars around a cut that must hold no stop token.
            private let tokenMargin: Int
            /// Raw scalars that must follow a cut.
            private let rawHoldback: Int
            private static let commitChunk = 64
            private static let cutAttempts = 64

            private let origin: Int
            private(set) var cut: Int
            private var committedFixed = ""
            private var committedOverlap = ""
            private var rawOverlap = ""

            init(origin: Int, filter: StopTokenFilter, requestStops: [String], holdback: Bool, watchesCloseTag: Bool, counter: WorkCounter) {
                self.filter = filter
                self.requestStops = requestStops
                self.holdback = holdback
                self.watchesCloseTag = watchesCloseTag
                self.counter = counter
                self.origin = origin
                self.cut = origin
                candidates = filter.tokens + requestStops
                let longestCandidate = candidates.map(\.count).max() ?? 0
                strippedOverlapCount = requestStops.isEmpty && !holdback ? 0 : longestCandidate + 4
                rawOverlapCount = watchesCloseTag ? ReasoningOutput.closeTag.count + 4 : 0
                let longestToken = filter.tokens.map(\.unicodeScalars.count).max() ?? 0
                tokenMargin = 2 * longestToken + 4
                rawHoldback = tokenMargin + (watchesCloseTag ? ReasoningOutput.closeTag.unicodeScalars.count : 0) + 8
            }

            func process(_ raw: String) -> Result {
                let tailStart = raw.utf8.index(raw.utf8.startIndex, offsetBy: cut)
                let tail = String(raw[tailStart...])
                if watchesCloseTag {
                    let searched = rawOverlap + tail
                    counter.value += searched.utf8.count
                    if let close = searched.range(of: ReasoningOutput.closeTag) {
                        let end = searched.utf8.distance(from: searched.utf8.startIndex, to: close.upperBound)
                        return Result(text: "", hitStop: false, closeEnd: cut - rawOverlap.utf8.count + end)
                    }
                }
                let strippedTail = filter.stripping(from: tail, joiner: ControlTextShield.markString)
                let window = committedOverlap + strippedTail
                counter.value += tail.utf8.count + window.utf8.count
                var earliest: String.Index?
                for stop in requestStops {
                    if let range = window.range(of: stop), earliest == nil || range.lowerBound < earliest! {
                        earliest = range.lowerBound
                    }
                }
                if let earliest {
                    return Result(text: committedFixed + window[..<earliest], hitStop: true, closeEnd: nil)
                }
                let text: String
                if holdback {
                    let held = ModelRuntime.longestSuffixPrefixLength(in: window, candidates: candidates)
                    let safe = held > 0 ? String(window.dropLast(held)) : window
                    let trimmed = ModelRuntime.withoutIncompleteUTF8Tail(safe)
                    text = trimmed.isEmpty && !committedFixed.isEmpty
                        ? ModelRuntime.withoutIncompleteUTF8Tail(committedFixed + safe)
                        : committedFixed + trimmed
                } else {
                    text = committedFixed + window
                }
                commitIfPossible(tail)
                return Result(text: text, hitStop: false, closeEnd: nil)
            }

            /// The stripped text of `raw[origin..<end]`, where `end` is past
            /// the cut (a found `</think>`).
            func strippedHead(_ raw: String, through end: Int) -> String {
                let utf8 = raw.utf8
                let endIndex = utf8.index(utf8.startIndex, offsetBy: end)
                let cutIndex = utf8.index(utf8.startIndex, offsetBy: cut)
                let segment = String(raw[cutIndex..<endIndex])
                let committed = committedFixed + committedOverlap
                // Within two token lengths of the cut, a stop token ending at
                // `end` could cover it in the shorter text: strip it whole.
                guard cut > origin, segment.unicodeScalars.count > tokenMargin else {
                    let whole = String(raw[..<endIndex])
                    counter.value += whole.utf8.count
                    return filter.stripping(from: whole, joiner: ControlTextShield.markString)
                }
                counter.value += segment.utf8.count
                return committed + filter.stripping(from: segment, joiner: ControlTextShield.markString)
            }

            private func commitIfPossible(_ tail: String) {
                let scalars = Array(tail.unicodeScalars)
                guard scalars.count >= rawHoldback + Self.commitChunk else { return }
                var index = scalars.count - rawHoldback
                var attempts = 0
                while index >= tokenMargin, attempts < Self.cutAttempts {
                    if isSafeCut(scalars, at: index) {
                        commit(scalars, at: index)
                        return
                    }
                    index -= 1
                    attempts += 1
                }
            }

            private func isSafeCut(_ scalars: [Unicode.Scalar], at index: Int) -> Bool {
                let before = scalars[index - 1]
                let after = scalars[index]
                guard IncrementalStreamFilter.breaksAround(before), IncrementalStreamFilter.breaksAround(after),
                      !(before == "\r" && after == "\n")
                else { return false }
                guard !filter.tokens.isEmpty else { return true }
                var view = String.UnicodeScalarView()
                view.append(contentsOf: scalars[(index - tokenMargin)..<min(scalars.count, index + tokenMargin)])
                let around = String(view)
                counter.value += around.utf8.count
                if filter.stripping(from: around, joiner: ControlTextShield.markString) == around { return true }
                // Some token occurs nearby: the cut is still safe when no
                // occurrence (overlapping ones included) covers either scalar.
                let scalarsView = around.unicodeScalars
                let cutIndex = scalarsView.index(scalarsView.startIndex, offsetBy: tokenMargin)
                let beforeIndex = scalarsView.index(before: cutIndex)
                for token in filter.tokens {
                    var from = around.startIndex
                    while from < around.endIndex, let range = around.range(of: token, range: from..<around.endIndex) {
                        counter.value += token.utf8.count
                        if range.lowerBound <= cutIndex, range.upperBound > beforeIndex { return false }
                        from = around.unicodeScalars.index(after: range.lowerBound)
                    }
                }
                return true
            }

            private func commit(_ scalars: [Unicode.Scalar], at index: Int) {
                var view = String.UnicodeScalarView()
                view.append(contentsOf: scalars[..<index])
                let segment = String(view)
                counter.value += segment.utf8.count
                let combined = committedOverlap + filter.stripping(from: segment, joiner: ControlTextShield.markString)
                let keep = combined.suffix(strippedOverlapCount)
                committedFixed += combined[..<keep.startIndex]
                committedOverlap = String(keep)
                if watchesCloseTag {
                    rawOverlap = String((rawOverlap + segment).suffix(rawOverlapCount))
                }
                cut += segment.utf8.count
            }
        }

        /// True when a grapheme break falls before and after `scalar` in
        /// every context (Unicode grapheme cluster rules GB3–GB13), CR LF
        /// aside: ASCII, and scalars of property Other that are not Hangul,
        /// regional indicators, emoji modifiers or listed Prepend /
        /// SpacingMark / Extend letters. Conservative: false only delays a cut.
        static func breaksAround(_ scalar: Unicode.Scalar) -> Bool {
            let value = scalar.value
            if value < 0x80 { return true }
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark, .format, .control,
                 .surrogate, .privateUse, .unassigned:
                return false
            default:
                break
            }
            switch value {
            case 0x1100...0x11FF, 0xA960...0xA97F, 0xAC00...0xD7FF: return false // Hangul
            case 0x1F1E6...0x1F1FF: return false // regional indicators
            case 0x1F3FB...0x1F3FF, 0xFF9E, 0xFF9F: return false // Extend
            case 0x0E33, 0x0EB3: return false // SpacingMark
            case 0x0D4E, 0x111C2, 0x111C3, 0x1193F, 0x11941, 0x11A3A, 0x11A84...0x11A89, 0x11D46, 0x11F02:
                return false // Prepend
            default:
                return true
            }
        }
    }
}
