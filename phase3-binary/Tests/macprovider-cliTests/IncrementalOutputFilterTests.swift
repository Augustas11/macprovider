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

    private func randomStream(_ rng: inout SeededGenerator, count: Int) -> [String] {
        (0..<count).map { _ in
            // Mostly prose so the filter commits; markup often enough to hit
            // every edge.
            if Int.random(in: 0..<3, using: &rng) == 0 {
                return pieces.randomElement(using: &rng)!
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
            for (step, text) in texts(of: randomStream(&rng, count: length), &rng).enumerated() {
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
        assertDifferential(mode: .streamingSafePrefix(reasoningOpen: false), seed: 2317, streams: 36, length: 400)
    }

    func testReasoningSafePrefixMatchesReferenceOnRandomStreams() {
        assertDifferential(mode: .streamingSafePrefix(reasoningOpen: true), seed: 23_171, streams: 36, length: 400)
    }

    func testOutputFiltersMatchReferenceOnRandomStreams() {
        assertDifferential(mode: .outputFilters, seed: 23_172, streams: 36, length: 400)
    }

    /// Long streams that never stop, so the committed prefix spans many cuts.
    func testLongStreamsMatchReferenceAcrossManyCommits() {
        var rng = SeededGenerator(state: 23_173)
        let modes: [ModelRuntime.IncrementalStreamFilter.Mode] = [
            .streamingSafePrefix(reasoningOpen: false), .streamingSafePrefix(reasoningOpen: true), .outputFilters,
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
                stopTokenFilter: stopTokens, requestStops: testCase.stops, reasoningOpen: testCase.reasoningOpen)
            var text = ""
            for piece in testCase.pieces {
                text += piece
                let expected = ModelRuntime.streamingSafePrefix(
                    text, stopTokenFilter: stopTokens, requestStops: testCase.stops, reasoningOpen: testCase.reasoningOpen)
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
                stopTokenFilter: stopTokens, requestStops: [], reasoningOpen: reasoningOpen)
            var view = String.UnicodeScalarView()
            for (step, scalar) in scalars.enumerated() {
                view.append(scalar)
                let text = String(view)
                let expected = ModelRuntime.streamingSafePrefix(
                    text, stopTokenFilter: stopTokens, requestStops: [], reasoningOpen: reasoningOpen)
                let actual = filter.update(text)
                guard actual.text == expected.text, actual.hitStop == expected.hitStop else {
                    return XCTFail("reasoningOpen \(reasoningOpen) step \(step)")
                }
            }
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
                stopTokenFilter: stopTokens, requestStops: stops, reasoningOpen: reasoningOpen)
            var ids: [Int] = []
            var previous = ""
            var wholeDecodedTokens = 0
            defer {
                // The window advances: far fewer tokens decoded than whole decodes.
                XCTAssertLessThan(decoder.decodedTokenCount, wholeDecodedTokens / 4, "stream \(streamIndex)")
                XCTAssertLessThan(decoder.fallbackCount, 40, "stream \(streamIndex)")
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
                    whole, stopTokenFilter: stopTokens, requestStops: stops, reasoningOpen: reasoningOpen)
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
        let model = "mlx-community/Qwen3-8B-4bit"
        let call = ["<tool", "_call>", "\n{\"name\": \"lookup\", ", "\"arguments\": {\"q\": \"x\"}}", "\n</tool_call>"]
        for streamIndex in 0..<24 {
            let stops = requestStopSets[streamIndex % requestStopSets.count]
            let reasoningOpen = streamIndex % 3 == 0
            var stream = randomStream(&rng, count: 200)
            if reasoningOpen { stream.insert("</think>", at: Int.random(in: 0..<stream.count, using: &rng)) }
            stream.insert(contentsOf: call, at: Int.random(in: 0..<stream.count, using: &rng))
            var reference = NativeToolCallStreamEmitter(modelID: model, allowedFunctionNames: ["lookup"], schemas: nil)
            var incremental = NativeToolCallStreamEmitter(modelID: model, allowedFunctionNames: ["lookup"], schemas: nil)
            let filter = ModelRuntime.IncrementalStreamFilter(
                stopTokenFilter: stopTokens, requestStops: stops, reasoningOpen: reasoningOpen)
            var text = ""
            for (step, piece) in stream.enumerated() {
                text += piece
                let expected = ModelRuntime.observeSerialToolStop(
                    &reference, decoded: text, stopTokenFilter: stopTokens, requestStops: stops, reasoningOpen: reasoningOpen)
                let actual = ModelRuntime.observeSerialToolStop(
                    &incremental, decoded: text, filter: filter, reasoningOpen: reasoningOpen)
                XCTAssertEqual(actual, expected, "stream \(streamIndex) step \(step)")
                if expected { break }
            }
        }
    }

    // MARK: - Complexity

    /// 20k pieces: the filter's scanned bytes and the decoder's decoded
    /// tokens per step stay bounded by a constant, not by the output length.
    func testWorkPerPieceDoesNotGrowWithOutputLength() {
        func work(pieces count: Int, reasoningOpen: Bool) -> (filterPerStep: Double, decodePerStep: Double) {
            var rng = SeededGenerator(state: 9_2317)
            let filter = ModelRuntime.IncrementalStreamFilter(
                stopTokenFilter: stopTokens, requestStops: ["END", "\n\n###"], reasoningOpen: reasoningOpen)
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
}
