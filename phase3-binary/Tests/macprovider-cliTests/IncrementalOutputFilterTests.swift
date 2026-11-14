import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

/// #2317: the incremental decode and output filter against the whole-text
/// reference functions, one piece at a time, on seeded random streams.
final class IncrementalOutputFilterTests: XCTestCase {
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private let stopTokens = StopTokenFilter(tokens: [
        "<|eot_id|>", "<|im_end|>", "<|endoftext|>", "</s>", "<｜end▁of▁sentence｜>",
    ])

    private let requestStopSets: [[String]] = [
        [],
        ["END"],
        ["END", "\n\n###"],
        // Contains stop-token text: never matches once the token is stripped,
        // but matches while the token is still partial.
        ["<|e", "im_end|>x"],
        // Appears only where a stripped stop token left the joiner.
        [ControlTextShield.markString],
        ["ab", "é!", "日本"],
    ]

    /// Pieces that split stop tokens, reasoning tags, tool markers and
    /// multi-byte text across boundaries, plus empty pieces.
    private let pieces: [String] = [
        "", "", "a", "b", "ab", " ", "  ", "\n", "\r", "\r\n", "the", " quick", " fox", ".", ",", "!",
        "E", "N", "D", "END", "EN", "#", "##", "\n\n###",
        "<|eot_id|>", "<|eo", "t_id|>", "<|im_end|>", "<|im", "_end|>", "<|", "|>", "</s>", "</", "s>",
        "<|endoftext|>", "<｜end▁of▁sentence｜>", "<｜end", "▁of▁sentence｜>",
        "<think>", "</think>", "</th", "ink>", "</", "think>",
        "<tool_call>", "</tool_call>", "{\"name\": \"lookup\"", ", \"arguments\": {\"q\": \"x\"}}",
        "é", "e", "\u{301}", "日本", "日", "本", "🇺", "🇸", "🇺🇸", "👍", "\u{1F3FD}", "\u{200D}", "가", "\u{1100}", "\u{1161}",
        "\u{FFFD}", ControlTextShield.markString, "x", "y", "z", " im_end|>x",
    ]

    /// MiniMax (#2189) reasoning tags and the namespace token, whole and
    /// split, with whitespace.
    private let miniMaxPieces: [String] = [
        "<mm:think>", "</mm:think>", "<mm:", "think>", "</mm:th", "ink>", "]<]minimax[>[", "]<]mini", "max[>[",
        "]<]minimax[>[<invoke name=\"f\">", "]<]minimax[>[<x>", "]<]minimax[>[</x>", " ", "\n", "  \n", "END",
    ]

    private func randomStream(_ rng: inout SeededGenerator, count: Int, extra: [String] = []) -> [String] {
        (0..<count).map { _ in
            // Mostly prose so the filter commits; markup often enough to hit
            // every edge.
            if Int.random(in: 0..<3, using: &rng) == 0 {
                return (pieces + extra).randomElement(using: &rng)!
            }
            return ["the", " cat", " sat", " on", " a", " mat", ",", ".", "\n", " 42", " und", " 中文", " ok"].randomElement(using: &rng)!
        }
    }

    /// Texts a decoder would report: the joined pieces, sometimes with a
    /// transient incomplete-UTF-8 tail or a trailing space a cleanup rule
    /// rewrites at the next step.
    private func texts(of stream: [String], _ rng: inout SeededGenerator) -> [String] {
        var joined = ""
        var result: [String] = []
        for piece in stream {
            joined += piece
            switch Int.random(in: 0..<12, using: &rng) {
            case 0: result.append(joined + "\u{FFFD}")
            case 1 where joined.hasSuffix(" ") == false: result.append(joined + " ")
            default: break
            }
            result.append(joined)
        }
        return result
    }

    private func assertDifferential(
        mode: ModelRuntime.IncrementalStreamFilter.Mode,
        seed: UInt64,
        streams: Int,
        length: Int,
        extra: [String] = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var rng = SeededGenerator(state: seed)
        var restarts = 0
        var scanned = 0
        var scannedBeforeStream = 0
        var wholeTextBytes = 0
        var steps = 0
        for streamIndex in 0..<streams {
            let stops = requestStopSets[streamIndex % requestStopSets.count]
            let filter = ModelRuntime.IncrementalStreamFilter(stopTokenFilter: stopTokens, requestStops: stops, mode: mode)
            for (step, text) in texts(of: randomStream(&rng, count: length, extra: extra), &rng).enumerated() {
                let expected: (text: String, hitStop: Bool)
                switch mode {
                case .streamingSafePrefix(let reasoningOpen):
                    expected = ModelRuntime.streamingSafePrefix(
                        text, stopTokenFilter: stopTokens, requestStops: stops, reasoningOpen: reasoningOpen)
                case .outputFilters:
                    expected = ModelRuntime.applyOutputFilters(text, stopTokenFilter: stopTokens, requestStops: stops)
                }
                let actual = filter.update(text)
                // Work is bounded until a request stop hits; after it the
                // (stopping) row re-filters its uncommitted tail.
                if !expected.hitStop {
                    wholeTextBytes += text.utf8.count
                    steps += 1
                    scanned = scannedBeforeStream + filter.scannedUTF8
                }
                guard actual.text == expected.text, actual.hitStop == expected.hitStop else {
                    XCTFail(
                        "mode \(mode) seed \(seed) stream \(streamIndex) step \(step) stops \(stops.debugDescription): "
                            + "\(actual.text.debugDescription)/\(actual.hitStop) != \(expected.text.debugDescription)/\(expected.hitStop) "
                            + "for \(text.debugDescription)",
                        file: file, line: line)
                    return
                }
            }
            restarts += filter.restartCount
            scannedBeforeStream = scanned
        }
        // The streams commit: work per step is bounded, not the text so far.
        XCTAssertLessThan(scanned / max(1, steps), 1_200, "whole text \(wholeTextBytes / max(1, steps)) bytes per step", file: file, line: line)
        // Restarts follow only the simulated rewrites, never every step.
        XCTAssertLessThan(restarts, streams * length / 4, file: file, line: line)
    }

    func testSafePrefixMatchesReferenceOnRandomStreams() {
        assertDifferential(mode: .streamingSafePrefix(reasoningOpen: .whole), seed: 2317, streams: 36, length: 400)
    }

    func testReasoningSafePrefixMatchesReferenceOnRandomStreams() {
        assertDifferential(mode: .streamingSafePrefix(reasoningOpen: .afterThink), seed: 23_171, streams: 36, length: 400)
    }

    func testMiniMaxSafePrefixMatchesReferenceOnRandomStreams() {
        assertDifferential(
            mode: .streamingSafePrefix(reasoningOpen: .afterMiniMaxThink), seed: 23_174, streams: 36, length: 400, extra: miniMaxPieces)
    }

    /// The MiniMax split twin against its reference at every step.
    func testMiniMaxSplitMatchesReferenceOnRandomStreams() {
        var rng = SeededGenerator(state: 23_175)
        var restarts = 0
        for streamIndex in 0..<36 {
            var split = IncrementalMiniMaxReasoningSplit()
            var answerOnly = IncrementalMiniMaxReasoningSplit(keepsReasoning: false)
            for (step, text) in texts(of: randomStream(&rng, count: 400, extra: miniMaxPieces), &rng).enumerated() {
                let expected = ReasoningOutput.MiniMax.splitStreamingPrefix(text)
                guard split.splitStreamingPrefix(text) == expected else {
                    return XCTFail("stream \(streamIndex) step \(step) differs for \(text.debugDescription)")
                }
                // The tool-stop split keeps the answer and drops the reasoning.
                let answer = answerOnly.splitStreamingPrefix(text)
                guard answer.answer == expected.answer, answer.closed == expected.closed, answer.reasoning.isEmpty else {
                    return XCTFail("answer-only stream \(streamIndex) step \(step) differs for \(text.debugDescription)")
                }
            }
            restarts += split.restartCount
        }
        XCTAssertLessThan(restarts, 36 * 400 / 4)
    }

    func testOutputFiltersMatchReferenceOnRandomStreams() {
        assertDifferential(mode: .outputFilters, seed: 23_172, streams: 36, length: 400)
    }

    /// Long streams that never stop, so the committed prefix spans many cuts.
    func testLongStreamsMatchReferenceAcrossManyCommits() {
        var rng = SeededGenerator(state: 23_173)
        let modes: [ModelRuntime.IncrementalStreamFilter.Mode] = [
            .streamingSafePrefix(reasoningOpen: .whole), .streamingSafePrefix(reasoningOpen: .afterThink), .outputFilters,
        ]
        for (index, mode) in modes.enumerated() {
            let stops = index == 1 ? [] : ["never-matches"]
            let filter = ModelRuntime.IncrementalStreamFilter(stopTokenFilter: stopTokens, requestStops: stops, mode: mode)
            var stream = randomStream(&rng, count: 2_500)
            if index == 1 { stream.insert("</think>", at: 1_200) }
            for (step, text) in texts(of: stream, &rng).enumerated() {
                let expected: (text: String, hitStop: Bool)
                switch mode {
                case .streamingSafePrefix(let reasoningOpen):
                    expected = ModelRuntime.streamingSafePrefix(
                        text, stopTokenFilter: stopTokens, requestStops: stops, reasoningOpen: reasoningOpen)
                case .outputFilters:
                    expected = ModelRuntime.applyOutputFilters(text, stopTokenFilter: stopTokens, requestStops: stops)
                }
                let actual = filter.update(text)
                guard actual.text == expected.text, actual.hitStop == expected.hitStop else {
                    return XCTFail("mode \(mode) step \(step) differs for \(text.suffix(80).debugDescription)")
                }
            }
            XCTAssertLessThan(filter.scannedUTF8 / 2_500, 1_500, "mode \(mode)")
        }
    }

    func testEdgeCasesAtTheCommittedBoundary() {
        let prose = String(repeating: "word ", count: 80)
        let cases: [(pieces: [String], stops: [String], reasoningOpen: Bool)] = [
            // A stop token split across pieces long after a commit.
            ([prose, "<|eo", "t_id|>", "tail"], ["END"], false),
            // A request stop that matches only while a stop token is partial.
            ([prose, "<|e", "ot_id|>", "more"], ["<|e"], false),
            // A request stop only the joiner of a stripped token makes.
            ([prose, "a<|im_end|>", "b"], [ControlTextShield.markString], false),
            // A reasoning close tag straddling the tail, then a stop after it.
            ([prose, "</th", "ink>", prose, "EN", "D"], ["END"], true),
            // A request stop inside the reasoning does not end it.
            ([prose, "END", "</think>", "answer END"], ["END"], true),
            // A request stop longer than the raw holdback: held back and
            // matched across committed text.
            ([prose] + Array(repeating: "xy", count: 70) + ["z"], [String(repeating: "xy", count: 60) + "z"], false),
            ([prose, "</think>", prose] + Array(repeating: "xy", count: 70), [String(repeating: "xy", count: 60) + "!"], true),
            // Multi-byte text split by a transient replacement character.
            ([prose, "日本", "\u{FFFD}"], [], false),
            ([prose, "\u{FFFD}\u{FFFD}"], [], false),
        ]
        for (index, testCase) in cases.enumerated() {
            let filter = ModelRuntime.IncrementalStreamFilter(
                stopTokenFilter: stopTokens, requestStops: testCase.stops, reasoningOpen: .init(testCase.reasoningOpen))
            var text = ""
            for piece in testCase.pieces {
                text += piece
                let expected = ModelRuntime.streamingSafePrefix(
                    text, stopTokenFilter: stopTokens, requestStops: testCase.stops, reasoningOpen: .init(testCase.reasoningOpen))
                let actual = filter.update(text)
                XCTAssertEqual(actual.text, expected.text, "case \(index)")
                XCTAssertEqual(actual.hitStop, expected.hitStop, "case \(index)")
            }
        }
    }

    /// A stop token followed by a combining mark is not a Character match;
    /// a cut between them would strip it in the committed half. Fed one
    /// scalar at a time so cuts land on every offset of the pattern.
    func testNoCutInsideAGraphemeCluster() {
        let unit = "ab</s>\u{301}cd 🇺🇸 e\u{301}\u{200D}x "
        let scalars = Array(String(repeating: unit, count: 40).unicodeScalars)
        for reasoningOpen in [false, true] {
            let filter = ModelRuntime.IncrementalStreamFilter(
                stopTokenFilter: stopTokens, requestStops: [], reasoningOpen: .init(reasoningOpen))
            var view = String.UnicodeScalarView()
            for (step, scalar) in scalars.enumerated() {
                view.append(scalar)
                let text = String(view)
                let expected = ModelRuntime.streamingSafePrefix(
                    text, stopTokenFilter: stopTokens, requestStops: [], reasoningOpen: .init(reasoningOpen))
                let actual = filter.update(text)
                guard actual.text == expected.text, actual.hitStop == expected.hitStop else {
                    return XCTFail("reasoningOpen \(reasoningOpen) step \(step)")
                }
            }
        }
    }

    /// Feeds `text` one scalar per step and compares with the reference.
    private func assertScalarSteps(
        _ text: String, filter stopTokenFilter: StopTokenFilter, stops: [String], reasoningOpen: Bool,
        _ label: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let filter = ModelRuntime.IncrementalStreamFilter(stopTokenFilter: stopTokenFilter, requestStops: stops, reasoningOpen: .init(reasoningOpen))
        var view = String.UnicodeScalarView()
        for (step, scalar) in text.unicodeScalars.enumerated() {
            view.append(scalar)
            let prefix = String(view)
            let expected = ModelRuntime.streamingSafePrefix(
                prefix, stopTokenFilter: stopTokenFilter, requestStops: stops, reasoningOpen: .init(reasoningOpen))
            let actual = filter.update(prefix)
            guard actual.text == expected.text, actual.hitStop == expected.hitStop else {
                return XCTFail("\(label) reasoningOpen \(reasoningOpen) step \(step)", file: file, line: line)
            }
        }
    }

    /// Every scalar `breaksAround` admits breaks from its neighbours in
    /// this runtime, between neighbours that break on both sides: a newer
    /// Unicode version's Prepend, Extend or SpacingMark scalar fails here.
    func testBreaksAroundAgreesWithTheRuntimeGraphemeBreaks() {
        let lefts = ["a", " ", "\n", "中", "\u{0915}", "\u{0915}\u{094D}\u{0915}", "\u{1F600}", "\u{1F600}\u{200D}\u{1F600}", "é"]
        let rights = ["a", " ", "\r", "中", "\u{0915}", "\u{1F600}", "ab"]
        var admitted = 0
        for value in UInt32(0x80)...0x10FFFF {
            guard let scalar = Unicode.Scalar(value), ModelRuntime.IncrementalStreamFilter.breaksAround(scalar) else { continue }
            admitted += 1
            var view = String.UnicodeScalarView()
            view.append(scalar)
            let middle = String(view)
            for left in lefts {
                for right in rights where (left + middle + right).count != left.count + 1 + right.count {
                    return XCTFail("U+\(String(value, radix: 16, uppercase: true)) joins \(left.debugDescription) or \(right.debugDescription)")
                }
            }
        }
        XCTAssertGreaterThan(admitted, 100_000)
        // Hangul beside ASCII: GB6–GB8 join Hangul only to Hangul.
        for hangul in ["가", "\u{1100}", "\u{1161}", "\u{11A8}", "각"] {
            for ascii in [" ", ".", "a", "\n"] {
                XCTAssertEqual((hangul + ascii + hangul).count, 3)
                XCTAssertTrue(ModelRuntime.IncrementalStreamFilter.breaksBetween(hangul.unicodeScalars.last!, ascii.unicodeScalars.first!))
                XCTAssertTrue(ModelRuntime.IncrementalStreamFilter.breaksBetween(ascii.unicodeScalars.first!, hangul.unicodeScalars.first!))
            }
        }
        XCTAssertFalse(ModelRuntime.IncrementalStreamFilter.breaksBetween("\u{1100}", "\u{1161}"))
        XCTAssertFalse(ModelRuntime.IncrementalStreamFilter.breaksBetween("\r", "\n"))
        // Any scalar beside ASCII: a break `breaksBetween` admits holds in
        // contexts that read further back or ahead (GB9b, GB9c, GB11,
        // GB12–GB13), over planes 0–1 and the Extend scalars of plane 14.
        let contexts = [("", ""), ("\u{0600}", ""), ("\u{1F1FA}", ""), ("\u{0915}\u{094D}", ""), ("\u{1F600}\u{200D}", ""),
                        ("\u{0301}", ""), ("", "\u{0301}"), ("", "\u{200D}"), ("", "\u{1F1F8}"), ("", "\u{0915}"), ("", "a")]
        var flags = 0
        for value in Array(UInt32(0x80)...0x1FFFF) + Array(UInt32(0xE0000)...0xE01EF) {
            guard let scalar = Unicode.Scalar(value) else { continue }
            var view = String.UnicodeScalarView()
            view.append(scalar)
            let middle = String(view)
            for ascii: Unicode.Scalar in ["a", "<"] {
                let asciiText = String(Character(ascii))
                if ModelRuntime.IncrementalStreamFilter.breaksBetween(ascii, scalar) {
                    if (0x1F1E6...0x1F1FF).contains(value) { flags += 1 }
                    for (before, after) in contexts
                    where (before + asciiText).count + (middle + after).count != (before + asciiText + middle + after).count {
                        return XCTFail("U+\(String(value, radix: 16, uppercase: true)) joins \(asciiText.debugDescription) before it")
                    }
                }
                if ModelRuntime.IncrementalStreamFilter.breaksBetween(scalar, ascii) {
                    for (before, after) in contexts
                    where (before + middle).count + (asciiText + after).count != (before + middle + asciiText + after).count {
                        return XCTFail("U+\(String(value, radix: 16, uppercase: true)) joins \(asciiText.debugDescription) after it")
                    }
                }
            }
        }
        XCTAssertEqual(flags, 26 * 2)
        XCTAssertTrue(ModelRuntime.IncrementalStreamFilter.breaksBetween("<", "\u{0600}"))
        XCTAssertFalse(ModelRuntime.IncrementalStreamFilter.breaksBetween("\u{0600}", "<"))
        XCTAssertFalse(ModelRuntime.IncrementalStreamFilter.breaksBetween(">", "\u{0301}"))
    }

    /// U+113D1 (Unicode 16 Prepend) joins the stop token's `<` into one
    /// Character, so the reference keeps the token; a frozen Prepend table
    /// let the incremental filter cut there and strip it.
    func testNewerUnicodePrependScalarBlocksTheCut() {
        let text = String(repeating: "a", count: 63) + "\u{113D1}<|im_end|>" + String(repeating: "b", count: 100)
        let filter = StopTokenFilter(tokens: ["<|im_end|>"])
        for reasoningOpen in [false, true] {
            assertScalarSteps(text, filter: filter, stops: ["STOP"], reasoningOpen: reasoningOpen, "U+113D1")
        }
    }

    /// A token whose canonical decomposition is longer than its own scalars
    /// (8 × U+1F82, 4 scalars each in NFD) must not span a cut.
    func testCutMarginCoversTheCanonicalDecomposition() {
        let token = "ᾂᾂᾂᾂᾂᾂᾂᾂab"
        let filter = StopTokenFilter(tokens: ["<|im_end|>", token])
        let decomposed = token.decomposedStringWithCanonicalMapping
        XCTAssertEqual(decomposed.unicodeScalars.count, 34)
        for count in 0...130 {
            let text = "<|im_" + String(repeating: "w", count: count) + decomposed + "end|>" + String(repeating: "q", count: 200)
            assertScalarSteps(text, filter: filter, stops: [], reasoningOpen: false, "N=\(count)")
        }
    }

    // MARK: - Decoder

    /// A local decoder in the shape of the Hugging Face ones: byte pieces
    /// joined and UTF-8 decoded (an incomplete tail renders U+FFFD), the
    /// cleanup rules, and the leading-space strip of a Metaspace decoder.
    private static let vocabulary: [[UInt8]] = {
        var pieces: [[UInt8]] = ["the", " cat", " sat", " .", " ,", " ", "a", "\n", " n't", " 's", "<|eot_id|>", "END", "</think>", "<think>"]
            .map { Array($0.utf8) }
        for character in ["é", "日", "👍", "🇺🇸"] {
            let bytes = Array(character.utf8)
            pieces.append(bytes)
            for split in 1..<bytes.count {
                pieces.append(Array(bytes[..<split]))
                pieces.append(Array(bytes[split...]))
            }
        }
        return pieces
    }()

    private static func fakeDecode(_ ids: [Int]) -> String {
        var text = String(decoding: ids.flatMap { vocabulary[$0] }, as: UTF8.self)
        for (pattern, replacement) in [(" .", "."), (" ,", ","), (" n't", "n't"), (" 's", "'s")] {
            text = text.replacingOccurrences(of: pattern, with: replacement)
        }
        if text.hasPrefix(" ") { text.removeFirst() }
        return text
    }

    func testWindowedDecoderMatchesWholeDecodeAndFeedsTheFilter() {
        var rng = SeededGenerator(state: 2_317_000)
        for streamIndex in 0..<24 {
            let stops = requestStopSets[streamIndex % requestStopSets.count]
            let reasoningOpen = streamIndex % 2 == 1
            let decoder = ModelRuntime.WindowedTextDecoder(decode: Self.fakeDecode, lookbackScalars: 16)
            let filter = ModelRuntime.IncrementalStreamFilter(
                stopTokenFilter: stopTokens, requestStops: stops, reasoningOpen: .init(reasoningOpen))
            var ids: [Int] = []
            var previous = ""
            var wholeDecodedTokens = 0
            defer {
                // The window advances: far fewer tokens decoded than whole decodes.
                XCTAssertLessThan(decoder.decodedTokenCount, wholeDecodedTokens / 4, "stream \(streamIndex)")
                // A whole-list decode is the exception, not a per-step cost:
                // these streams take none (one is allowed per stream).
                XCTAssertLessThanOrEqual(decoder.fallbackCount, 1, "stream \(streamIndex)")
            }
            for step in 0..<400 {
                // One to three tokens per event, as batched rows deliver them.
                for _ in 0..<Int.random(in: 1...3, using: &rng) {
                    ids.append(Int.random(in: 0..<Self.vocabulary.count, using: &rng))
                }
                let output = decoder.update(cumulativeTokens: ids)
                wholeDecodedTokens += ids.count
                let whole = Self.fakeDecode(ids)
                guard output.text == whole else {
                    return XCTFail("stream \(streamIndex) step \(step): \(output.text.debugDescription) != \(whole.debugDescription)")
                }
                XCTAssertTrue(
                    previous.utf8.prefix(output.unchangedPrefixUTF8).elementsEqual(whole.utf8.prefix(output.unchangedPrefixUTF8)),
                    "stream \(streamIndex) step \(step): unchanged prefix hint")
                previous = whole
                let expected = ModelRuntime.streamingSafePrefix(
                    whole, stopTokenFilter: stopTokens, requestStops: stops, reasoningOpen: .init(reasoningOpen))
                let actual = filter.update(output.text, unchangedPrefixUTF8: output.unchangedPrefixUTF8)
                guard actual.text == expected.text, actual.hitStop == expected.hitStop else {
                    return XCTFail("stream \(streamIndex) step \(step): filter differs for \(whole.debugDescription)")
                }
            }
        }
    }

    // MARK: - Tool stop

    func testSerialToolStopMatchesReferenceOnRandomStreams() {
        var rng = SeededGenerator(state: 2_317_317)
        let dsml = DeepseekV4Encoding.dsmlToken
        let glmCall = ["<tool_call>", "lookup", "<arg_key>", "q", "</arg_key>", "<arg_value>", "x", "</arg_value>", "</tool_call>"]
        // #2259: a malformed first call does not hide a complete one after it.
        let glmMalformedFirst = ["<tool_call>", "lookup<arg_key>q</arg_key>", "</tool_call>", " then "] + glmCall
        let cases: [(model: String, grammar: ToolCallGrammar, call: [String])] = [
            ("mlx-community/Qwen3-8B-4bit", .qwen, ["<tool", "_call>", "\n{\"name\": \"lookup\", ", "\"arguments\": {\"q\": \"x\"}}", "\n</tool_call>"]),
            ("zai-org/GLM-5.3", .glm, glmCall),
            ("zai-org/GLM-5.3", .glm, glmMalformedFirst),
            ("mlx-community/gemma-4-12b-it-4bit", .gemma4, ["<|tool_call>", "call:lookup", "{q:<|\"|>x<|\"|>}", "<tool_call|>"]),
            ("LiquidAI/LFM2-8B-A1B-MLX-4bit", .lfm2, ["<|tool_call_start|>", "[lookup(q=\"x\")]", "<|tool_call_end|>"]),
            ("mlx-community/DeepSeek-V4-Flash-4bit", .dsml,
             ["<\(dsml)tool_calls>", "\n<\(dsml)invoke name=\"lookup\">", "\n<\(dsml)parameter name=\"q\" string=\"true\">x</\(dsml)parameter>",
              "\n</\(dsml)invoke>", "\n</\(dsml)tool_calls>"]),
            ("mlx-community/Llama-3.3-70B-Instruct-4bit", .llama3, ["<|python_tag|>", "{\"name\": \"lookup\", ", "\"parameters\": {\"q\": \"x\"}}"]),
        ]
        for testCase in cases {
            var stops = 0
            for streamIndex in 0..<12 {
                let requestStops = requestStopSets[streamIndex % requestStopSets.count]
                let reasoningOpen = streamIndex % 3 == 0
                var stream = randomStream(&rng, count: 200) + ["<div>", "\n  <a href=\"x\">", "</a>", "</div>"]
                stream.shuffle(using: &rng)
                if reasoningOpen { stream.insert("</think>", at: Int.random(in: 0..<stream.count, using: &rng)) }
                stream.insert(contentsOf: testCase.call, at: Int.random(in: 0..<stream.count, using: &rng))
                var reference = NativeToolCallStreamEmitter(modelID: testCase.model, grammar: testCase.grammar, allowedFunctionNames: ["lookup"])
                var incremental = NativeToolCallStreamEmitter(modelID: testCase.model, grammar: testCase.grammar, allowedFunctionNames: ["lookup"])
                let filter = ModelRuntime.IncrementalStreamFilter(
                    stopTokenFilter: stopTokens, requestStops: requestStops, reasoningOpen: .init(reasoningOpen))
                var stopText = IncrementalToolStopText(observer: incremental)
                var text = ""
                for (step, piece) in stream.enumerated() {
                    text += piece
                    let expected = ModelRuntime.observeSerialToolStop(
                        &reference, decoded: text, stopTokenFilter: stopTokens, requestStops: requestStops, reasoningOpen: .init(reasoningOpen))
                    let actual = ModelRuntime.observeSerialToolStop(
                        &incremental, decoded: text, filter: filter, stopText: &stopText, reasoningOpen: .init(reasoningOpen))
                    guard actual == expected else {
                        return XCTFail("\(testCase.grammar) stream \(streamIndex) step \(step)")
                    }
                    if expected {
                        stops += 1
                        break
                    }
                }
            }
            // The streams do reach the stop (a call outside the reasoning).
            XCTAssertGreaterThan(stops, 0, "\(testCase.grammar)")
        }
    }

    /// A long GLM call body on a reasoning row through the serial tool
    /// stop: the cut search and the end-delimiter search read a bounded
    /// amount per step.
    func testSerialToolStopWorkPerStepIsBoundedOnALongGLMBody() {
        func perStep(bodyBytes: Int) -> Double {
            var observer = NativeToolCallStreamEmitter(modelID: "zai-org/GLM-5.3", grammar: .glm, allowedFunctionNames: ["read"])
            let filter = ModelRuntime.IncrementalStreamFilter(stopTokenFilter: stopTokens, requestStops: [], reasoningOpen: .afterThink)
            var stopText = IncrementalToolStopText(observer: observer)
            var text = String(repeating: "thinking. ", count: 50) + "</think>" + String(repeating: "Reading now. ", count: 40)
                + "<tool_call>read<arg_key>path</arg_key><arg_value>"
            let unit = "<div class=\"row\">\n  <a href=\"/x\">link</a> if a < b\n</div>\n"
            var steps = 0
            while text.utf8.count < bodyBytes {
                text += unit
                steps += 1
                XCTAssertFalse(ModelRuntime.observeSerialToolStop(
                    &observer, decoded: text, filter: filter, stopText: &stopText, reasoningOpen: .afterThink))
            }
            return Double(stopText.scannedUTF8 + observer.incrementalScannedUTF8) / Double(steps)
        }
        let short = perStep(bodyBytes: 100_000)
        let long = perStep(bodyBytes: 400_000)
        XCTAssertLessThan(long, 512)
        XCTAssertLessThan(long, short * 1.25 + 16)
    }

    /// Answers with no grapheme-safe cut and no `<` (skin-toned emoji,
    /// unbroken Hangul, flags, ZWJ chains) through the tool stop text: the
    /// cut search decodes a bounded window per step and skips the marker
    /// search, and the result is the whole answer.
    func testToolStopTextWorkPerStepIsBoundedWithoutCuts() {
        for unit in ["👍🏽", "가나다라", "🇺🇸", "👨‍👩‍👧‍👦\u{200D}"] {
            for grammar in [ToolCallGrammar.glm, .qwen] {
                func perStep(answerBytes: Int) -> Double {
                    let observer = NativeToolCallStreamEmitter(modelID: "m", grammar: grammar, allowedFunctionNames: ["get"])
                    var stopText = IncrementalToolStopText(observer: observer)
                    let head = "thinking</think>"
                    var text = head
                    var steps = 0
                    while text.utf8.count < answerBytes {
                        text += unit
                        steps += 1
                        let observed = stopText.observedText(text, reasoningOpen: .afterThink)
                        if steps % 997 == 0 { XCTAssertEqual(observed, String(text.dropFirst(head.count))) }
                    }
                    XCTAssertEqual(stopText.restartCount, 0)
                    return Double(stopText.scannedUTF8) / Double(steps)
                }
                let short = perStep(answerBytes: 16_000)
                let long = perStep(answerBytes: 64_000)
                XCTAssertLessThan(long, 1_024, "\(unit) \(grammar)")
                XCTAssertLessThan(long, short * 1.25 + 16, "\(unit) \(grammar)")
            }
        }
    }

    /// Marker-free text full of `<` (indented HTML, XML) commits: work per
    /// step stays bounded, for the emitter's tool text and the tool stop.
    func testDenseMarkupWithoutMarkersCommits() {
        let units = [
            "  <div class=\"card\">\n    <a href=\"/p\">post</a>\n  </div>\n",
            "<?xml version=\"1.0\"?>\n<config>\n  <item key=\"a\" value=\"1\"/>\n</config>\n",
        ]
        for unit in units {
            for qwenBareCalls in [false, true] {
                func perStep(bytes: Int) -> (Double, Int) {
                    let markers = NativeToolCallStreamEmitter(
                        modelID: "m", grammar: qwenBareCalls ? .qwen : .glm, allowedFunctionNames: ["read"]).markerTexts
                    var toolText = IncrementalToolText(markers: markers, bracesMatter: false, qwenBareCalls: qwenBareCalls)
                    var text = "Here is the page:\n"
                    var steps = 0
                    while text.utf8.count < bytes {
                        text += unit
                        steps += 1
                        _ = toolText.reduce(text)
                    }
                    return (Double(toolText.scannedUTF8) / Double(steps), toolText.maxUncommittedUTF8)
                }
                let short = perStep(bytes: 100_000)
                let long = perStep(bytes: 400_000)
                XCTAssertLessThan(long.0, 2_048, unit)
                XCTAssertLessThan(long.0, short.0 * 1.25 + 16, unit)
                XCTAssertLessThan(long.1, ModelRuntime.incrementalTailReportUTF8, unit)
            }
            var stray = IncrementalStrayTagRemoval()
            var text = "Here is the page:\n"
            while text.utf8.count < 100_000 {
                text += unit
                _ = stray.removingStrayTags(text)
            }
            XCTAssertLessThan(stray.maxUncommittedUTF8, ModelRuntime.incrementalTailReportUTF8, unit)
        }
    }

    // MARK: - Complexity

    /// 20k pieces: the filter's scanned bytes and the decoder's decoded
    /// tokens per step stay bounded by a constant, not by the output length.
    func testWorkPerPieceDoesNotGrowWithOutputLength() {
        func work(pieces count: Int, reasoningOpen: Bool) -> (filterPerStep: Double, decodePerStep: Double) {
            var rng = SeededGenerator(state: 9_2317)
            let filter = ModelRuntime.IncrementalStreamFilter(
                stopTokenFilter: stopTokens, requestStops: ["END", "\n\n###"], reasoningOpen: .init(reasoningOpen))
            let decoder = ModelRuntime.WindowedTextDecoder(decode: Self.fakeDecode, lookbackScalars: 64)
            let ascii = (0..<Self.vocabulary.count).filter { Self.vocabulary[$0].allSatisfy { $0 < 0x80 } && Self.vocabulary[$0] != Array("END".utf8) }
            var ids: [Int] = []
            if reasoningOpen { ids.append(Self.vocabulary.firstIndex(of: Array("</think>".utf8))!) }
            for _ in 0..<count {
                ids.append(ascii.randomElement(using: &rng)!)
                let output = decoder.update(cumulativeTokens: ids)
                XCTAssertFalse(filter.update(output.text, unchangedPrefixUTF8: output.unchangedPrefixUTF8).hitStop)
            }
            return (Double(filter.scannedUTF8) / Double(count), Double(decoder.decodedTokenCount) / Double(count))
        }
        // Korean prose commits at its spaces: every ASCII scalar here sits
        // between two Hangul syllables.
        func koreanWork(pieces count: Int) -> Double {
            var rng = SeededGenerator(state: 9_2318)
            let filter = ModelRuntime.IncrementalStreamFilter(
                stopTokenFilter: stopTokens, requestStops: ["END"], reasoningOpen: .whole)
            let words = [" 안녕하세요", " 반갑습니다", " 오늘은", " 날씨가", " 좋네요"]
            var text = "가"
            for _ in 0..<count {
                text += words.randomElement(using: &rng)!
                XCTAssertFalse(filter.update(text).hitStop)
            }
            return Double(filter.scannedUTF8) / Double(count)
        }
        let koreanShort = koreanWork(pieces: 2_000)
        let koreanLong = koreanWork(pieces: 20_000)
        XCTAssertLessThan(koreanLong, 3_000)
        XCTAssertLessThan(koreanLong, koreanShort * 1.25)
        for reasoningOpen in [false, true] {
            let short = work(pieces: 2_000, reasoningOpen: reasoningOpen)
            let long = work(pieces: 20_000, reasoningOpen: reasoningOpen)
            // The whole-text filter scans the whole output every step:
            // about 40 KB per step at the end of a 20k-piece stream.
            XCTAssertLessThan(long.filterPerStep, 1_500, "reasoningOpen \(reasoningOpen)")
            XCTAssertLessThan(long.filterPerStep, short.filterPerStep * 1.25, "reasoningOpen \(reasoningOpen)")
            XCTAssertLessThan(long.decodePerStep, 200, "reasoningOpen \(reasoningOpen)")
            XCTAssertLessThan(long.decodePerStep, short.decodePerStep * 1.25, "reasoningOpen \(reasoningOpen)")
        }
    }

    /// 200 back-to-back special tokens under a 256-token filter: no cut is
    /// safe there, and the cut search is one token-position pass per step,
    /// not one strip per candidate cut.
    func testBackToBackSpecialTokensCostOneCutPassPerStep() {
        let tokens = (0..<250).map { "<|reserved_special_token_\($0)|>" }
            + ["<|begin_of_text|>", "<|end_of_text|>", "<|eot_id|>", "<|eom_id|>", "<|python_tag|>", "<|finetune_right_pad_id|>"]
        let filter = StopTokenFilter(tokens: tokens)
        let incremental = ModelRuntime.IncrementalStreamFilter(stopTokenFilter: filter, requestStops: [], reasoningOpen: .whole)
        var text = ""
        var wholeText = 0
        for step in 0..<200 {
            text += "<|reserved_special_token_5|>"
            wholeText += text.utf8.count
            let expected = ModelRuntime.streamingSafePrefix(text, stopTokenFilter: filter, requestStops: [], reasoningOpen: .whole)
            let actual = incremental.update(text)
            guard actual.text == expected.text, actual.hitStop == expected.hitStop else {
                return XCTFail("step \(step)")
            }
        }
        // The uncommitted tail once, plus one bounded region per step; 64
        // whole-region strips per step would add about 8 KB each.
        XCTAssertLessThan(incremental.scannedUTF8, wholeText + 200 * 1_024)
    }

    // MARK: - Round 2 regressions

    /// Feeds `text` one scalar per step to both split functions.
    private func assertSplitScalarSteps(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        var split = IncrementalReasoningSplit()
        var view = String.UnicodeScalarView()
        for (step, scalar) in text.unicodeScalars.enumerated() {
            view.append(scalar)
            let prefix = String(view)
            guard split.splitStreamingPrefix(prefix) == ReasoningOutput.splitStreamingPrefix(prefix) else {
                return XCTFail("split step \(step)", file: file, line: line)
            }
        }
    }

    private func assertStrayScalarSteps(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        var removal = IncrementalStrayTagRemoval()
        var view = String.UnicodeScalarView()
        for (step, scalar) in text.unicodeScalars.enumerated() {
            view.append(scalar)
            let prefix = String(view)
            guard removal.removingStrayTags(prefix) == ReasoningOutput.removingStrayTags(prefix, streaming: true) else {
                return XCTFail("stray step \(step)", file: file, line: line)
            }
        }
    }

    /// `<` after a Prepend scalar (U+0600, U+113D1) is not a grapheme start:
    /// the whole-text search does not match a tag there, so a search may not
    /// resume between them.
    func testSearchesResumeOnlyAtGraphemeBreaks() {
        for prepend in ["\u{0600}", "\u{113D1}"] {
            assertSplitScalarSteps(String(repeating: "a", count: 100) + prepend + "</think>" + String(repeating: "b", count: 64) + "c")
            assertStrayScalarSteps(String(repeating: "a", count: 100) + prepend + "<tool_call><think>" + String(repeating: "b", count: 57) + "c")
            for reasoningOpen in [false, true] {
                assertScalarSteps("abc" + prepend + "</think>answer", filter: stopTokens, stops: ["STOPHERE"],
                                  reasoningOpen: reasoningOpen, "prepend \(prepend.unicodeScalars.first!.value)")
            }
        }
        // A match followed by a soft hyphen or a combining mark: the cached
        // hit is checked between breaks, not dropped for a rescan from 0.
        for joiner in ["\u{AD}", "\u{301}", "\u{200D}"] {
            assertSplitScalarSteps("x" + "</think>" + joiner + String(repeating: "y", count: 200))
            assertSplitScalarSteps(String(repeating: "w", count: 150) + "</think>" + joiner + "z" + "</think>" + "q")
        }
    }

    /// `removingTags` removes until removal changes nothing: a tag followed
    /// by U+200D (which a Character-wise `contains` misses) goes too, so
    /// the result does not depend on which other tags the text holds.
    func testTagRemovalIsLocal() {
        XCTAssertEqual(ReasoningOutput.removingTags("a</think>\u{200D}b"), ReasoningOutput.removingTags("a</think>\u{200D}b<think>"))
        assertStrayScalarSteps("</think>\u{200D}" + String(repeating: "a", count: 200) + " </think>")
        assertStrayScalarSteps("Hello <think>\u{200D}" + String(repeating: "word ", count: 40) + "<think>tail zzzzzzzzzz")
    }

    /// GLM markup that a Character-wise search misses (`<arg_key>` before
    /// U+200D) but the markup stripping removes must hold the tool-text cut.
    func testGLMMarkupBeforeAJoinerHoldsTheCut() {
        var toolText = IncrementalToolText(
            markers: NativeToolCallStreamEmitter(modelID: "zai-org/GLM-5.3", grammar: .glm, allowedFunctionNames: ["read"]).markerTexts,
            bracesMatter: false, qwenBareCalls: false)
        let text = "Hi <arg_key>\u{200D} there " + String(repeating: "x", count: 110)
        var view = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            view.append(scalar)
            let reduced = toolText.reduce(String(view))
            XCTAssertFalse(reduced.kept.unicodeScalars.contains("<"))
        }
        XCTAssertEqual(toolText.reduce(text).kept, "")
    }

    /// The incremental windows assume short markers and tags.
    func testMarkersAndTagsFitTheTextWindows() {
        for grammar in ToolCallGrammar.allCases {
            let markers = NativeToolCallStreamEmitter(modelID: "m", grammar: grammar, allowedFunctionNames: []).markerTexts
            XCTAssertLessThan(markers.map(\.unicodeScalars.count).max() ?? 0, IncrementalToolText.markerFreeTail, "\(grammar)")
            // The cut rule compares marker scalars: no other text may match
            // a marker canonically (no decomposition, no K ; ` singletons).
            for marker in markers + [ReasoningOutput.openTag, ReasoningOutput.closeTag] {
                XCTAssertEqual(Array(marker.decomposedStringWithCanonicalMapping.unicodeScalars), Array(marker.unicodeScalars), marker)
                XCTAssertEqual(Array(marker.precomposedStringWithCanonicalMapping.unicodeScalars), Array(marker.unicodeScalars), marker)
                XCTAssertFalse(marker.unicodeScalars.contains { "K;`".unicodeScalars.contains($0) }, marker)
                XCTAssertTrue(marker.hasPrefix("<"), marker)
            }
        }
        XCTAssertTrue(Set(ToolCallParser.glmCallMarkup).isSubset(of: NativeToolCallStreamEmitter(
            modelID: "m", grammar: .glm, allowedFunctionNames: []).markerTexts))
        for tag in [ReasoningOutput.openTag, ReasoningOutput.closeTag] {
            XCTAssertLessThanOrEqual(tag.count * 2, IncrementalStrayTagRemoval.tagFreeTail)
        }
    }

    /// Dense stop tokens never commit: the row reports its uncommitted tail.
    func testDenseStopTokensReportTheUncommittedTail() {
        let filter = ModelRuntime.IncrementalStreamFilter(stopTokenFilter: stopTokens, requestStops: [], reasoningOpen: .whole)
        var text = ""
        for _ in 0..<600 {
            text += "<|eot_id|>"
            _ = filter.update(text)
        }
        XCTAssertGreaterThan(filter.maxUncommittedUTF8, ModelRuntime.incrementalTailReportUTF8)
        var stray = IncrementalStrayTagRemoval()
        text = ""
        for _ in 0..<600 {
            text += "<think>"
            _ = stray.removingStrayTags(text)
        }
        XCTAssertGreaterThan(stray.maxUncommittedUTF8, ModelRuntime.incrementalTailReportUTF8)
    }

    /// Random streams over an alphabet with ZWJ, Prepend, format and
    /// combining scalars, tags and stop tokens: the three filter modes and
    /// the split and stray-tag twins against their references.
    func testFuzzWithJoinersAndPrependScalars() {
        var rng = SeededGenerator(state: 2_317_2)
        let alphabet = [
            "a", "b", " ", "\n", ".", "<", ">", "/", "|", "\u{200D}", "\u{200C}", "\u{0600}", "\u{113D1}", "\u{AD}", "\u{301}",
            "\u{FE0F}", "\u{1F3FD}", "👍", "가", "\u{1100}", "\u{1161}", "\u{0915}", "\u{094D}", "🇺", "\r",
            "<think>", "</think>", "</th", "ink>", "<tool_call>", "<|eot_id|>", "<|eo", "t_id|>", "STOP", "word ", "prose here ",
            "<div>", "</div>", "</", "<a ", "href=\"x\">", "<?xml", " version=\"1.0\"?>", "\n  <item/>", "<th", "<tool", "<|", "< ",
            "<mm:think>", "</mm:think>", "</mm:th", "]<]minimax[>[", "]<]mini", "max[>[", "  ",
        ]
        var mismatches = 0
        for stream in 0..<30 {
            let stops = stream % 2 == 0 ? ["STOP"] : []
            let modes: [ModelRuntime.IncrementalStreamFilter.Mode] = [
                .outputFilters, .streamingSafePrefix(reasoningOpen: .whole), .streamingSafePrefix(reasoningOpen: .afterThink),
                .streamingSafePrefix(reasoningOpen: .afterMiniMaxThink),
            ]
            let filters = modes.map { ModelRuntime.IncrementalStreamFilter(stopTokenFilter: stopTokens, requestStops: stops, mode: $0) }
            var split = IncrementalReasoningSplit()
            var miniMaxSplit = IncrementalMiniMaxReasoningSplit()
            var stray = IncrementalStrayTagRemoval()
            var text = ""
            for _ in 0..<500 {
                // Mostly prose so the twins commit.
                text += Int.random(in: 0..<3, using: &rng) == 0
                    ? alphabet.randomElement(using: &rng)! : ["word ", "prose here ", "ok. "].randomElement(using: &rng)!
                for (mode, filter) in zip(modes, filters) {
                    let expected: (text: String, hitStop: Bool)
                    switch mode {
                    case .streamingSafePrefix(let reasoningOpen):
                        expected = ModelRuntime.streamingSafePrefix(text, stopTokenFilter: stopTokens, requestStops: stops, reasoningOpen: reasoningOpen)
                    case .outputFilters:
                        expected = ModelRuntime.applyOutputFilters(text, stopTokenFilter: stopTokens, requestStops: stops)
                    }
                    let actual = filter.update(text)
                    if actual.text != expected.text || actual.hitStop != expected.hitStop { mismatches += 1 }
                }
                if split.splitStreamingPrefix(text) != ReasoningOutput.splitStreamingPrefix(text) { mismatches += 1 }
                if miniMaxSplit.splitStreamingPrefix(text) != ReasoningOutput.MiniMax.splitStreamingPrefix(text) { mismatches += 1 }
                if stray.removingStrayTags(text) != ReasoningOutput.removingStrayTags(text, streaming: true) { mismatches += 1 }
            }
        }
        XCTAssertEqual(mismatches, 0)
    }

    /// A held-back tail (the text shrinking by a scalar, then growing
    /// again) keeps the delimiter scan's recorded matches: no restart.
    func testDelimiterScanKeepsItsStateWhenTheTextShrinksByAScalar() {
        for last in [false, true] {
            var scan = IncrementalDelimiterScan(needle: "</tool_call>", last: last)
            let head = "<tool_call>read<arg_key>p</arg_key><arg_value>"
            var text = head + "v</arg_value></tool_call>"
            for step in 0..<300 {
                text += step % 50 == 0 ? "</tool_call>" : "x日"
                for candidate in [String(text.unicodeScalars.dropLast()), text] {
                    let found = scan.find(in: candidate, origin: 0)
                    let reference = candidate.range(of: "</tool_call>", options: last ? .backwards : [])
                    XCTAssertEqual(found?.lower, reference.map { candidate.utf8.distance(from: candidate.utf8.startIndex, to: $0.lowerBound) })
                    XCTAssertEqual(found?.upper, reference.map { candidate.utf8.distance(from: candidate.utf8.startIndex, to: $0.upperBound) })
                }
            }
            XCTAssertEqual(scan.restartCount, 0, "last \(last)")
        }
    }
}
