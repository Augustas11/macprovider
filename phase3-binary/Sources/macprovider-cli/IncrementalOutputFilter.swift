import Foundation
import MacProviderCore
import MLXLMCommon

/// #2317: streaming output filtering whose work per generated token does not
/// grow with the output. `streamingSafePrefix` and `applyOutputFilters` stay
/// the reference: every result here is the one they return for the whole
/// text, and the differential tests in `IncrementalOutputFilterTests` check
/// it piece by piece.
extension ModelRuntime {
    /// Uncommitted text above which a row is reported as not committing.
    static let incrementalTailReportUTF8 = 4_096

    /// One line per row whose incremental decode or filter fell back to
    /// whole-text work (#2317), or whose uncommitted tail (the text each
    /// step still processes whole) grew past `incrementalTailReportUTF8`;
    /// silent otherwise.
    static func logIncrementalOutputFallbacks(path: String, decodeFallbacks: Int, filterRestarts: Int, maxUncommittedUTF8: Int) {
        guard decodeFallbacks > 0 || filterRestarts > 0 || maxUncommittedUTF8 > incrementalTailReportUTF8 else { return }
        FileHandle.standardError.write(Data(
            ("event=incremental_output_fallback path=\(path) decode_fallbacks=\(decodeFallbacks) "
                + "filter_restarts=\(filterRestarts) max_uncommitted_bytes=\(maxUncommittedUTF8)\n").utf8))
    }

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

        /// At least 64 scalars, and twice the longest control text the
        /// tokenizer's shield marks (0 without one).
        static func lookbackScalars(controlTextLength: Int) -> Int {
            max(64, 2 * controlTextLength + 8)
        }

        static func lookbackScalars(for tokenizer: any MLXLMCommon.Tokenizer) -> Int {
            lookbackScalars(controlTextLength: ControlTokenTable.of(tokenizer)?.matcher.maxLength ?? 0)
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

        init(decode: @escaping ([Int]) -> String, lookbackScalars: Int) {
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
    /// - a grapheme break falls between the neighbouring scalars whatever
    ///   surrounds them (`breaksBetween`, so Character, Foundation and
    ///   canonical-equivalence matching agree on either side);
    /// - no stop-token occurrence (overlapping ones included) covers either
    ///   neighbouring scalar;
    /// - at least twice the longest token's scalars in its canonical
    ///   decomposition (plus `</think>`) of raw
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
        /// The longest uncommitted raw tail seen, in UTF-8 bytes.
        var maxUncommittedUTF8: Int { counter.maxTail }

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
            guard count > 0 else { return true }
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
            var maxTail = 0
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
                // Matching is by canonical equivalence: an occurrence can be
                // as long as the token's full decomposition.
                let longestToken = filter.tokens.map {
                    max($0.unicodeScalars.count, $0.decomposedStringWithCanonicalMapping.unicodeScalars.count)
                }.max() ?? 0
                tokenMargin = 2 * longestToken + 4
                rawHoldback = tokenMargin + (watchesCloseTag ? ReasoningOutput.closeTag.unicodeScalars.count : 0) + 8
            }

            func process(_ raw: String) -> Result {
                let tailStart = raw.utf8.index(raw.utf8.startIndex, offsetBy: cut)
                let tail = String(raw[tailStart...])
                counter.maxTail = max(counter.maxTail, tail.utf8.count)
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
                if let earliest = ModelRuntime.earliestRequestStop(in: window, requestStops: requestStops) {
                    return Result(text: committedFixed + window[..<earliest], hitStop: true, closeEnd: nil)
                }
                let text: String
                if holdback {
                    let safe = ModelRuntime.withoutStopCandidatePrefixTail(window, candidates: candidates)
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

            /// The highest cut among the last `cutAttempts` positions before
            /// the holdback that `breaksBetween` its neighbours and that no
            /// stop-token occurrence (overlapping ones included, touching
            /// ones too) covers. One token-position pass over the candidate
            /// region plus the margin on both sides.
            private func commitIfPossible(_ tail: String) {
                let scalars = Array(tail.unicodeScalars)
                guard scalars.count >= rawHoldback + Self.commitChunk else { return }
                let highest = scalars.count - rawHoldback
                let lowest = max(tokenMargin, highest - Self.cutAttempts + 1)
                guard highest >= lowest else { return }
                var covered = [Bool](repeating: false, count: highest - lowest + 1)
                if !filter.tokens.isEmpty {
                    let regionStart = lowest - tokenMargin
                    let regionEnd = min(scalars.count, highest + tokenMargin)
                    var view = String.UnicodeScalarView()
                    view.append(contentsOf: scalars[regionStart..<regionEnd])
                    let around = String(view)
                    counter.value += around.utf8.count
                    let occurrences = filter.occurrenceUTF8Ranges(in: around)
                    if !occurrences.isEmpty {
                        // UTF-8 offset of each region scalar, and of its end.
                        var starts: [Int] = []
                        starts.reserveCapacity(regionEnd - regionStart + 1)
                        var offset = 0
                        for scalar in scalars[regionStart..<regionEnd] {
                            starts.append(offset)
                            offset += UTF8.width(scalar)
                        }
                        starts.append(offset)
                        for occurrence in occurrences {
                            // Scalars [first, end) of the occurrence: cuts
                            // first...end touch it.
                            let first = Self.lowerBound(starts, occurrence.lowerBound) + regionStart
                            let end = Self.lowerBound(starts, occurrence.upperBound) + regionStart
                            let from = max(first, lowest)
                            let to = min(end, highest)
                            if from <= to {
                                for index in from...to { covered[index - lowest] = true }
                            }
                        }
                    }
                }
                var index = highest
                while index >= lowest {
                    if !covered[index - lowest],
                       IncrementalStreamFilter.breaksBetween(scalars[index - 1], scalars[index]) {
                        commit(scalars, at: index)
                        return
                    }
                    index -= 1
                }
            }

            private static func lowerBound(_ sorted: [Int], _ value: Int) -> Int {
                var low = 0
                var high = sorted.count
                while low < high {
                    let middle = (low + high) / 2
                    if sorted[middle] < value { low = middle + 1 } else { high = middle }
                }
                return low
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
        /// aside. Marks, format and control scalars, Hangul and regional
        /// indicators are excluded by property; Prepend, Extend and
        /// SpacingMark come from the running Swift runtime's own grapheme
        /// breaking, so the check follows its Unicode version. Conservative:
        /// false only delays a cut.
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
            if isHangul(scalar) { return false }
            if (0x1F1E6...0x1F1FF).contains(value) { return false } // regional indicators
            return breaksBesideASCII(scalar)
        }

        /// True when a grapheme break falls between `before` and `after`
        /// whatever surrounds them. Beyond two `breaksAround` scalars (not
        /// CR LF): a scalar after ASCII that does not join it (Extend, ZWJ,
        /// SpacingMark), and a scalar before ASCII that does not join it
        /// (Prepend). The rules that read further context (GB9c, GB11,
        /// GB12–GB13) join only scalars that are not ASCII, and an ASCII
        /// scalar is neither Prepend, Extend nor SpacingMark, so Korean
        /// prose, flags or Prepend runs break at their ASCII neighbours.
        static func breaksBetween(_ before: Unicode.Scalar, _ after: Unicode.Scalar) -> Bool {
            if before == "\r", after == "\n" { return false }
            if breaksAround(before), breaksAround(after) { return true }
            if before.isASCII {
                switch after.properties.generalCategory {
                case .nonspacingMark, .spacingMark, .enclosingMark: return false
                default: return after != "\u{200D}" && pairsWithASCII(after, asciiFirst: true)
                }
            }
            if after.isASCII { return pairsWithASCII(before, asciiFirst: false) }
            return false
        }

        /// Whether `scalar` and an ASCII letter stay two Characters, in the
        /// given order, under the runtime's grapheme breaking.
        private static func pairsWithASCII(_ scalar: Unicode.Scalar, asciiFirst: Bool) -> Bool {
            var view = String.UnicodeScalarView()
            view.append(scalar)
            let alone = String(view)
            return (asciiFirst ? "a" + alone : alone + "a").count == 2
        }

        private static func isHangul(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar.value {
            case 0x1100...0x11FF, 0xA960...0xA97F, 0xAC00...0xD7FF: return true
            default: return false
            }
        }

        /// Prepend joins what follows; Extend, ZWJ and SpacingMark join what
        /// precedes.
        private static func breaksBesideASCII(_ scalar: Unicode.Scalar) -> Bool {
            var view = String.UnicodeScalarView()
            view.append(scalar)
            let alone = String(view)
            return (alone + "a").count == 2 && ("a" + alone).count == 2
        }
    }
}

// MARK: - Emitter text steps (#2317)

/// Shared by the emitter's incremental steps below. Each keeps work per call
/// bounded by the text after a committed point plus a margin; the committed
/// bytes are re-verified with one `memcmp`, and a text that changed inside
/// them restarts the step from the first byte (counted in `restartCount`).
enum IncrementalEmitterText {
    /// Committed points stay this many bytes behind the end, so an input that
    /// shrinks by a held-back tail does not restart the step.
    static let margin = 64

    static func index(_ text: String, utf8Offset offset: Int) -> String.Index {
        text.utf8.index(text.utf8.startIndex, offsetBy: offset)
    }

    static func offset(_ text: String, _ index: String.Index) -> Int {
        text.utf8.distance(from: text.utf8.startIndex, to: index)
    }

    /// The scalar boundary at or before `offset`.
    static func scalarIndex(_ text: String, atOrBefore offset: Int) -> String.Index {
        var offset = max(0, min(offset, text.utf8.count))
        let utf8 = text.utf8
        while offset > 0, offset < utf8.count, utf8[utf8.index(utf8.startIndex, offsetBy: offset)] & 0xC0 == 0x80 {
            offset -= 1
        }
        return index(text, utf8Offset: offset)
    }

    /// True when a `<` among the last `window` scalars before `end` starts a
    /// run through `end` that is a prefix of one of `markers` (scalar
    /// strings no other text matches canonically, see the tests): a marker
    /// could still complete across `end`. Any other `<` (HTML, XML, a
    /// comparison) cannot.
    /// Whether `text` holds a `<` before `end` (a byte search).
    static func containsLessThan(_ text: Substring, before end: String.Index) -> Bool {
        let count = text.utf8.distance(from: text.utf8.startIndex, to: end)
        return text.utf8.withContiguousStorageIfAvailable { memchr($0.baseAddress, Int32(UInt8(ascii: "<")), count) != nil }
            ?? text.utf8[..<end].contains(UInt8(ascii: "<"))
    }

    /// Whether `text` holds a `<` at or after UTF-8 offset `offset`.
    static func containsLessThan(_ text: String, fromUTF8 offset: Int) -> Bool {
        let start = max(0, min(offset, text.utf8.count))
        return text.utf8.withContiguousStorageIfAvailable {
            memchr($0.baseAddress.map { $0 + start }, Int32(UInt8(ascii: "<")), $0.count - start) != nil
        } ?? text.utf8.dropFirst(start).contains(UInt8(ascii: "<"))
    }

    static func endsInsideMarker(_ scalars: [Unicode.Scalar], before end: Int, window: Int, markers: [[Unicode.Scalar]]) -> Bool {
        var start = end - 1
        while start >= max(0, end - window) {
            defer { start -= 1 }
            guard scalars[start] == "<" else { continue }
            let run = end - start
            for marker in markers where marker.count >= run {
                var matched = 0
                while matched < run, scalars[start + matched] == marker[matched] { matched += 1 }
                if matched == run { return true }
            }
        }
        return false
    }

    /// The last scalar boundary at or before `offset` (and at or after
    /// `floor`) where a grapheme break falls whatever surrounds it, so a
    /// search started there sees the Characters a search of the whole text
    /// sees. `floor` itself is always allowed.
    static func breakIndex(_ text: String, atOrBefore offset: Int, floor: String.Index) -> String.Index {
        breakIndex(text[...], atOrBefore: offset, floor: floor)
    }

    /// `offset` counts from the start of `text`.
    static func breakIndex(_ text: Substring, atOrBefore offset: Int, floor: String.Index) -> String.Index {
        let scalars = text.unicodeScalars
        let utf8 = text.utf8
        var index = utf8.index(utf8.startIndex, offsetBy: max(0, min(offset, utf8.count)))
        while index > floor, index < utf8.endIndex, utf8[index] & 0xC0 == 0x80 {
            index = utf8.index(before: index)
        }
        while index > floor, index < scalars.endIndex,
              !ModelRuntime.IncrementalStreamFilter.breaksBetween(scalars[scalars.index(before: index)], scalars[index]) {
            index = scalars.index(before: index)
        }
        return index
    }
}

/// The first occurrence of `needle` in a growing text, as
/// `text.range(of: needle)` finds it. A search resumes at a grapheme break
/// that holds whatever surrounds it (`breakIndex`), never merely at a
/// scalar boundary: `<` does not always begin a grapheme (after a Prepend
/// scalar such as U+0600 the whole-text search does not match there).
struct IncrementalFirstMatch {
    let needle: String
    private var previous = ""
    private var found: (lower: Int, upper: Int)?
    /// No occurrence starts before this UTF-8 offset of `previous`.
    private var scanned = 0
    private(set) var restartCount = 0

    init(needle: String) { self.needle = needle }

    mutating func find(in text: String) -> Range<String.Index>? {
        // An occurrence ending at the scanned bound also reads the scalar
        // after it.
        let verified = found?.upper ?? (scanned > 0 ? scanned + needle.utf8.count + 8 : 0)
        if verified > 0, !ModelRuntime.IncrementalStreamFilter.sharesPrefix(previous, text, utf8Count: verified) {
            restartCount += 1
            found = nil
            scanned = 0
        }
        previous = text
        if let cached = found {
            let lower = IncrementalEmitterText.index(text, utf8Offset: cached.lower)
            let upper = IncrementalEmitterText.index(text, utf8Offset: cached.upper)
            // The scalars after the match that join its last grapheme: the
            // whole-text match there can change only through them.
            let scalars = text.unicodeScalars
            var end = upper
            while end < scalars.endIndex,
                  !ModelRuntime.IncrementalStreamFilter.breaksBetween(scalars[scalars.index(before: end)], scalars[end]) {
                end = scalars.index(after: end)
            }
            if end == upper { return lower..<upper }
            // Search again between breaks around the match: no occurrence
            // starts before it, and the breaks make the window's search the
            // whole text's.
            let start = IncrementalEmitterText.breakIndex(text, atOrBefore: cached.lower, floor: text.startIndex)
            if let range = text.range(of: needle, range: start..<end) {
                found = (IncrementalEmitterText.offset(text, range.lowerBound), IncrementalEmitterText.offset(text, range.upperBound))
                return range
            }
            found = nil
            scanned = cached.lower
        }
        // An occurrence holds the needle's leading `<` at or after `scanned`:
        // without one there, the grapheme-safe start (a walk back over a run
        // with no safe break) and the search are skipped.
        if needle.unicodeScalars.first == "<", !IncrementalEmitterText.containsLessThan(text, fromUTF8: scanned) {
            scanned = max(scanned, text.utf8.count - needle.utf8.count - IncrementalEmitterText.margin)
            return nil
        }
        let start = IncrementalEmitterText.breakIndex(text, atOrBefore: scanned, floor: text.startIndex)
        if let range = text.range(of: needle, range: start..<text.endIndex) {
            found = (IncrementalEmitterText.offset(text, range.lowerBound), IncrementalEmitterText.offset(text, range.upperBound))
            return range
        }
        scanned = max(scanned, text.utf8.count - needle.utf8.count - IncrementalEmitterText.margin)
        return nil
    }
}

/// The first or last occurrence of `needle` in `text[origin...]` (searched
/// as its own string), as `range(of:)` / `range(of:options: .backwards)`
/// finds it there, for a text that grows between calls (#2317). `needle`
/// must not overlap itself. An occurrence that starts at least `margin`
/// bytes before the end and is followed by a grapheme break stays a match
/// while the verified prefix is unchanged; the rest is searched again from
/// a grapheme break at or before that point.
struct IncrementalDelimiterScan {
    let needle: String
    let last: Bool
    private let margin: Int
    private var previous = ""
    private var origin = -1
    /// Occurrences starting before this UTF-8 offset are recorded.
    private var settled = 0
    private var recorded: (lower: Int, upper: Int)?
    /// UTF-8 bytes searched, summed over calls (test hook).
    private(set) var scannedUTF8 = 0
    private(set) var restartCount = 0

    init(needle: String, last: Bool) {
        self.needle = needle
        self.last = last
        margin = 2 * needle.utf8.count + 8
    }

    /// UTF-8 offsets in `text`.
    mutating func find(in text: String, origin: Int) -> (lower: Int, upper: Int)? {
        // Recorded occurrences and the scalar after each lie before
        // `settled + needle + 8`, which stays below the end by about a
        // needle length: a text that shrinks by a held-back tail keeps them.
        let verified = min(previous.utf8.count, settled + needle.utf8.count + 8)
        if origin != self.origin
            || (self.origin >= 0 && !ModelRuntime.IncrementalStreamFilter.sharesPrefix(previous, text, utf8Count: verified)) {
            if self.origin >= 0 { restartCount += 1 }
            self.origin = origin
            settled = origin
            recorded = nil
        }
        previous = text
        if !last, let recorded { return recorded }
        let utf8 = text.utf8
        let originIndex = utf8.index(utf8.startIndex, offsetBy: origin)
        let candidate = text[originIndex...]
        let start = IncrementalEmitterText.breakIndex(candidate, atOrBefore: settled - origin, floor: candidate.startIndex)
        scannedUTF8 += utf8.distance(from: start, to: utf8.endIndex)
        var newSettled = max(settled, utf8.count - margin)
        var latest: (lower: Int, upper: Int)?
        var from = start
        let scalars = candidate.unicodeScalars
        while from < candidate.endIndex, let range = candidate.range(of: needle, range: from..<candidate.endIndex) {
            let found = (lower: utf8.distance(from: utf8.startIndex, to: range.lowerBound),
                         upper: utf8.distance(from: utf8.startIndex, to: range.upperBound))
            latest = found
            if found.lower < newSettled {
                // Settled once a break follows it: the scalars that could
                // still join its last grapheme are in place.
                if range.upperBound < candidate.endIndex,
                   ModelRuntime.IncrementalStreamFilter.breaksBetween(scalars[scalars.index(before: range.upperBound)], scalars[range.upperBound]) {
                    if recorded == nil || last { recorded = found }
                } else {
                    newSettled = found.lower
                }
            }
            if !last { break }
            from = range.upperBound
        }
        settled = newSettled
        return latest ?? recorded
    }
}

/// Incremental twin of `ReasoningOutput.splitStreamingPrefix`.
struct IncrementalReasoningSplit {
    private var close = IncrementalFirstMatch(needle: ReasoningOutput.closeTag)

    var restartCount: Int { close.restartCount }

    mutating func splitStreamingPrefix(_ text: String) -> ReasoningOutput.Split {
        var text = text
        text.makeContiguousUTF8()
        if let range = close.find(in: text) {
            let answer = text[range.upperBound...].drop(while: { $0.isWhitespace })
            return ReasoningOutput.Split(reasoning: String(text[..<range.lowerBound]), answer: String(answer), closed: true)
        }
        return ReasoningOutput.Split(reasoning: ReasoningOutput.withoutPartialCloseTag(text), answer: "", closed: false)
    }

    /// `splitStreamingPrefix(text).answer` when closed, else nil, without
    /// copying the reasoning (the tool-stop path reads only the answer).
    mutating func closedAnswer(_ text: String) -> Substring? {
        var text = text
        text.makeContiguousUTF8()
        guard let range = close.find(in: text) else { return nil }
        return text[range.upperBound...].drop(while: { $0.isWhitespace })
    }
}

/// Incremental twin of `ReasoningOutput.removingStrayTags(_:streaming: true)`.
///
/// Removing every `<think>` and `</think>` until none is left has one result
/// whatever the order (neither tag overlaps itself or the other), so the
/// committed head's result is kept and only the text after it is processed.
/// A cut is committed where both neighbouring scalars always break graphemes
/// and neither the raw text nor the committed result ends in the start of a
/// tag (`endsInsideMarker`): no tag can then span the cut.
struct IncrementalStrayTagRemoval {
    private var call = IncrementalFirstMatch(needle: ToolCallParser.toolCallOpen)
    private var previous = ""
    private var cut = 0
    private var committed = ""
    private var restarts = 0
    /// At least twice the longest tag's Characters (see the tests).
    static let tagFreeTail = 16
    /// What may not span a cut: the think tags, and the call start the
    /// whole-text function stops at.
    static let tags = [ReasoningOutput.openTag, ReasoningOutput.closeTag, ToolCallParser.toolCallOpen].map { Array($0.unicodeScalars) }

    var restartCount: Int { restarts + call.restartCount }
    /// The longest uncommitted text before a call, in UTF-8 bytes.
    private(set) var maxUncommittedUTF8 = 0

    mutating func removingStrayTags(_ input: String) -> String {
        var text = input
        text.makeContiguousUTF8()
        if cut > 0, !ModelRuntime.IncrementalStreamFilter.sharesPrefix(previous, text, utf8Count: cut) {
            restarts += 1
            cut = 0
            committed = ""
        }
        previous = text
        let callRange = call.find(in: text)
        let callStart = callRange?.lowerBound ?? text.endIndex
        if IncrementalEmitterText.offset(text, callStart) < cut {
            restarts += 1
            cut = 0
            committed = ""
        }
        let tail = String(text[IncrementalEmitterText.index(text, utf8Offset: cut)..<callStart])
        maxUncommittedUTF8 = max(maxUncommittedUTF8, tail.utf8.count)
        // Every tag starts with `<` (see the tests): without one the tail
        // has no tag and no partial tag.
        let tailHasLessThan = IncrementalEmitterText.containsLessThan(tail, fromUTF8: 0)
        let processed = tailHasLessThan ? ReasoningOutput.removingTags(tail) : tail
        var head = committed + processed
        if callRange == nil {
            // A held tail starts with `<`, which the committed text's last
            // Characters never hold, so it lies in the processed tail.
            let held = tailHasLessThan ? ReasoningOutput.partialTagLength(processed) : 0
            if held > 0 { head = String(head.dropLast(held)) }
            commitIfPossible(tail)
        }
        return head + text[callStart...]
    }

    private mutating func commitIfPossible(_ tail: String) {
        let hold = IncrementalEmitterText.margin
        // The cuts tried and the tag window before them lie in the last
        // `hold + 64 + tagFreeTail` scalars; only those are decoded.
        // `scalars` holds the tail's scalars from `windowStart` on.
        let unicodeScalars = tail.unicodeScalars
        var windowStart = unicodeScalars.endIndex
        var taken = 0
        while windowStart > unicodeScalars.startIndex, taken < hold + 64 + Self.tagFreeTail + 1 {
            unicodeScalars.formIndex(before: &windowStart)
            taken += 1
        }
        let scalars = Array(unicodeScalars[windowStart...])
        guard windowStart > unicodeScalars.startIndex || scalars.count >= 2 * hold else { return }
        var index = scalars.count - hold
        var attempts = 0
        while index > 0, attempts < 64 {
            defer { index -= 1; attempts += 1 }
            guard ModelRuntime.IncrementalStreamFilter.breaksBetween(scalars[index - 1], scalars[index]),
                  !IncrementalEmitterText.endsInsideMarker(scalars, before: index, window: Self.tagFreeTail, markers: Self.tags)
            else { continue }
            // One whole-segment pass per call: a cut that fails here waits
            // for the next call.
            let segment = String(Substring(unicodeScalars[..<unicodeScalars.index(windowStart, offsetBy: index)]))
            let processed = IncrementalEmitterText.containsLessThan(segment, fromUTF8: 0) ? ReasoningOutput.removingTags(segment) : segment
            // After removals the committed result's end may not hold the
            // start of a tag either.
            let joined = Array((String(committed.suffix(Self.tagFreeTail)) + processed).suffix(Self.tagFreeTail).unicodeScalars)
            guard !IncrementalEmitterText.endsInsideMarker(joined, before: joined.count, window: joined.count, markers: Self.tags) else {
                return
            }
            committed += processed
            cut += segment.utf8.count
            return
        }
    }
}

/// What a serial tool-stop observer reads (#2317): the answer after
/// `</think>` on reasoning rows (`IncrementalReasoningSplit`), reduced by
/// `IncrementalToolText` as the stream emitter reduces it.
struct IncrementalToolStopText {
    private var reasoningSplit = IncrementalReasoningSplit()
    private var toolText: IncrementalToolText

    init(observer: NativeToolCallStreamEmitter) {
        toolText = IncrementalToolText(
            markers: observer.markerTexts, bracesMatter: observer.bareBracesMayOpenCall, qwenBareCalls: observer.bareQwenCallsMayOpen)
    }

    var restartCount: Int { reasoningSplit.restartCount + toolText.restartCount }
    var maxUncommittedUTF8: Int { toolText.maxUncommittedUTF8 }
    /// Bytes the tool-text cut search read (test hook).
    var scannedUTF8: Int { toolText.scannedUTF8 }

    /// Nil while the reasoning is open: a call inside it is not a call
    /// (SPEC-018 §3.12).
    mutating func observedText(_ text: String, reasoningOpen: Bool) -> String? {
        var text = text
        if reasoningOpen {
            guard let answer = reasoningSplit.closedAnswer(text) else { return nil }
            text = String(answer)
        }
        return toolText.reduce(text).reduced
    }
}

/// What the tool-call stream emitter sees of the streamed text (#2317). The
/// committed prose before `cut` holds no tool marker, no `<` within 24
/// scalars of the cut whose run to the cut is the start of a marker, no `{`
/// for Llama 3, and on Qwen rows does not open like a bare call.
/// `visibleContentPrefix` and `observe` then give on `x + rest` (x: the
/// committed text's last scalar, a non-blank Character that always breaks
/// graphemes and is neither `<` nor `{`) what they give on the whole text,
/// minus the committed text before x. Above the response byte cap the whole
/// text is used (`llama3CallStart` reads its length).
struct IncrementalToolText {
    private let markers: [String]
    private let markerScalars: [[Unicode.Scalar]]
    /// Every marker starts with `<`, so text without that scalar holds none.
    private let markersStartWithLessThan: Bool
    private let bracesMatter: Bool
    private let qwenBareCalls: Bool
    private var previous = ""
    private var cut = 0
    /// No cut is possible while the text's first `frozenThrough` bytes stay
    /// as they are: its lead may open a Qwen bare call, or a marker or
    /// (Llama 3) a `{` lies before every later cut. Skips the per-step cut
    /// search over a tool-call body.
    private var frozenThrough: Int?
    /// The text's first `markerFreeThrough` bytes hold no marker (a
    /// negative marker search, not repeated while they stay as they are).
    private var markerFreeThrough = 0
    private(set) var restartCount = 0
    /// UTF-8 bytes the cut search decoded or searched for markers, summed
    /// over calls (test hook; byte copies and `<` byte scans not counted).
    private(set) var scannedUTF8 = 0
    /// The longest uncommitted text seen, in UTF-8 bytes.
    private(set) var maxUncommittedUTF8 = 0
    /// Longer than every marker's scalars (see the tests).
    static let markerFreeTail = 24

    init(markers: [String], bracesMatter: Bool, qwenBareCalls: Bool) {
        self.markers = markers
        markerScalars = markers.map { Array($0.unicodeScalars) }
        markersStartWithLessThan = markerScalars.allSatisfy { $0.first == "<" }
        self.bracesMatter = bracesMatter
        self.qwenBareCalls = qwenBareCalls
    }

    /// `kept + reduced` is `text`; the streamer gets `reduced`.
    mutating func reduce(_ input: String) -> (kept: Substring, reduced: String) {
        var text = input
        text.makeContiguousUTF8()
        if cut > 0, !ModelRuntime.IncrementalStreamFilter.sharesPrefix(previous, text, utf8Count: cut) {
            restartCount += 1
            cut = 0
            frozenThrough = nil
            markerFreeThrough = 0
        }
        if let frozen = frozenThrough, !ModelRuntime.IncrementalStreamFilter.sharesPrefix(previous, text, utf8Count: frozen) {
            frozenThrough = nil
        }
        if markerFreeThrough > cut, !ModelRuntime.IncrementalStreamFilter.sharesPrefix(previous, text, utf8Count: markerFreeThrough) {
            markerFreeThrough = cut
        }
        previous = text
        maxUncommittedUTF8 = max(maxUncommittedUTF8, text.utf8.count - cut)
        guard text.utf8.count <= ToolCallParser.SPEC018_ARGUMENTS_PER_RESPONSE_BYTE_CAP else {
            return (text[text.startIndex..<text.startIndex], text)
        }
        let cutIndex = IncrementalEmitterText.index(text, utf8Offset: cut)
        let reducedStart = cut > 0 ? text.unicodeScalars.index(before: cutIndex) : cutIndex
        let result = (text[..<reducedStart], String(text[reducedStart...]))
        if frozenThrough == nil {
            commitIfPossible(text[cutIndex...])
        }
        return result
    }

    /// The streamer finds markers with `range(of:)` and the GLM markup
    /// stripping removes them with `replacingOccurrences`; either may match
    /// where a Character-wise `contains` does not (`<arg_key>` before
    /// U+200D), so text counts as marker-free only for both.
    private func containsMarker(_ text: String) -> Bool {
        markers.contains { text.range(of: $0) != nil || text.replacingOccurrences(of: $0, with: "") != text }
    }

    /// `containsMarker(head)` for a prefix `head` of the text after the cut,
    /// searching only past the part already known to be marker-free (from a
    /// grapheme break far enough back that no marker can straddle it).
    private mutating func headContainsMarker(_ head: String) -> Bool {
        let known = markerFreeThrough - cut
        let longest = markers.map(\.utf8.count).max() ?? 0
        let from = IncrementalEmitterText.breakIndex(head, atOrBefore: known - 2 * longest - 16, floor: head.startIndex)
        let searched = head[from...]
        scannedUTF8 += searched.utf8.count
        let mayHoldMarker = !markersStartWithLessThan || searched.unicodeScalars.contains("<")
        if mayHoldMarker, containsMarker(String(searched)) { return true }
        markerFreeThrough = max(markerFreeThrough, cut + head.utf8.count)
        return false
    }

    private mutating func commitIfPossible(_ tail: Substring) {
        let hold = IncrementalEmitterText.margin
        // A first scalar that is not whitespace, `{` or `<` starts a first
        // Character that is neither blank nor the start of a bare call
        // (`Character.isWhitespace` reads the first scalar), so the
        // Character-wise lead check, O(n) on a text that is one long
        // grapheme, is skipped.
        if cut == 0, let first = tail.unicodeScalars.first,
           first.properties.isWhitespace || first == "{" || first == "<" {
            // On Qwen rows the whole text's lead decides the bare-call hold.
            let lead = tail.drop(while: { $0.isWhitespace })
            if lead.isEmpty { return }
            if qwenBareCalls, NativeToolCallStreamEmitter.mayOpenQwenBareCalls(String(tail)) {
                frozenThrough = tail.utf8.distance(from: tail.utf8.startIndex, to: lead.startIndex) + 1
                return
            }
        }
        // The cuts tried and the marker window before them lie in the last
        // `hold + 64 + markerFreeTail` scalars; only those are decoded
        // (Llama 3 reads the whole text for its first `{`). `scalars` holds
        // the tail's scalars from `windowStart` on.
        let unicodeScalars = tail.unicodeScalars
        var windowStart = unicodeScalars.endIndex
        if bracesMatter {
            windowStart = unicodeScalars.startIndex
        } else {
            var taken = 0
            while windowStart > unicodeScalars.startIndex, taken < hold + 64 + Self.markerFreeTail + 1 {
                unicodeScalars.formIndex(before: &windowStart)
                taken += 1
            }
        }
        let scalars = Array(unicodeScalars[windowStart...])
        scannedUTF8 += tail.utf8.distance(from: windowStart, to: tail.endIndex)
        guard windowStart > unicodeScalars.startIndex || scalars.count >= 2 * hold else { return }
        /// The tail's text before window scalar `index`.
        func prefix(through index: Int) -> String {
            String(Substring(unicodeScalars[..<unicodeScalars.index(windowStart, offsetBy: index)]))
        }
        // Llama 3: no cut past the first `{`.
        let brace = bracesMatter ? scalars.firstIndex(of: "{") : nil
        var index = min(scalars.count - hold, brace ?? scalars.count)
        var attempts = 0
        while index > 0, attempts < 64 {
            defer { index -= 1; attempts += 1 }
            let last = scalars[index - 1]
            guard !last.properties.isWhitespace, last != "<", last != "{",
                  ModelRuntime.IncrementalStreamFilter.breaksAround(last),
                  ModelRuntime.IncrementalStreamFilter.breaksBetween(last, scalars[index]),
                  !IncrementalEmitterText.endsInsideMarker(scalars, before: index, window: Self.markerFreeTail, markers: markerScalars)
            else { continue }
            // One marker search per call: a marker in the segment holds
            // every later cut too.
            let segment = prefix(through: index)
            guard !headContainsMarker(segment) else {
                frozenThrough = cut + segment.utf8.count
                return
            }
            cut += segment.utf8.count
            return
        }
        // A marker before every cut tried here holds every later cut too
        // (later cuts lie further on), as in a tool-call body whose `<` are
        // too dense for any cut to reach the marker search.
        // Without a `<` before it the head holds no marker (a run of
        // Characters with no grapheme-safe cut, such as skin-toned emoji).
        let firstTried = min(scalars.count - hold, brace ?? scalars.count) - 64
        let headEnd = firstTried > 0 ? unicodeScalars.index(windowStart, offsetBy: firstTried) : tail.startIndex
        if firstTried > 0, !markersStartWithLessThan || IncrementalEmitterText.containsLessThan(tail, before: headEnd) {
            let head = String(Substring(unicodeScalars[..<headEnd]))
            if headContainsMarker(head) {
                frozenThrough = cut + head.utf8.count
                return
            }
        }
        // The search window sits below the first `{`, where growth does not
        // move it: it fails the same way until the text changes.
        if let brace, brace <= scalars.count - hold {
            frozenThrough = cut + prefix(through: brace + 1).utf8.count
        }
    }
}
