import Foundation
import MLXLMCommon
import MacProviderCore
@testable import macprovider_cli
import XCTest

/// #2317: the windowed decode against the whole-list decode of real
/// `tokenizer.json` decoders (swift-transformers), at the lookback the
/// provider derives for each tokenizer: ByteLevel with and without cleanup,
/// Metaspace with both prepend schemes, the SentencePiece
/// Replace/ByteFallback/Fuse/Strip sequence, and a GLM control-token table
/// whose longest control text sets a lookback above the 64-scalar floor.
final class IncrementalOutputFilterTokenizerFixtureTests: XCTestCase {
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

    private static let template = "{%- for m in messages -%}{{ m.content }}{%- endfor -%}"

    /// GPT-2 byte-level pieces: printable ASCII, space (Ġ), newline (Ċ),
    /// whole words with a leading space, `Ġ.` for the cleanup rule, and the
    /// single bytes of é (C3 A9) and 日 (E6 97 A5).
    private static let byteLevelVocabulary: [String: Int] = {
        var vocab: [String: Int] = [:]
        for code in 33...126 { vocab[String(UnicodeScalar(UInt8(code)))] = code }
        for (piece, id) in [
            ("Ġ", 200), ("Ċ", 201), ("Ã", 220), ("©", 221), ("æ", 222), ("Ĺ", 223), ("¥", 224),
            ("Ġthe", 230), ("Ġcat", 231), ("Ġ.", 232), ("Ġ,", 233), ("Ġn't", 234), ("ĠĠ", 235),
        ] { vocab[piece] = id }
        return vocab
    }()

    /// SentencePiece pieces with byte fallback for é and 日.
    private static let metaspaceVocabulary: [String: Int] = {
        var vocab: [String: Int] = ["<unk>": 0, "▁": 3, "▁the": 4, "▁cat": 5, "a": 6, ".": 7, ",": 8, "▁▁": 9, "b": 10]
        for (index, byte) in [0xC3, 0xA9, 0xE6, 0x97, 0xA5, 0x0A].enumerated() {
            vocab[String(format: "<0x%02X>", byte)] = 20 + index
        }
        return vocab
    }()

    private struct Fixture {
        let name: String
        let modelType: String
        let vocabulary: [String: Int]
        let added: [(String, Int, Bool)]
        let decoder: [String: Any]
        let byteFallback: Bool
        let cleanUp: Bool
    }

    private static let glmAdded: [(String, Int, Bool)] = PromptControlTokenTests.added + [("<|reserved_special_token_100|>", 1040, true)]

    private static let fixtures: [Fixture] = [
        Fixture(name: "byte-level", modelType: "qwen3", vocabulary: byteLevelVocabulary,
                added: [("<|im_end|>", 1000, true), ("<think>", 1001, false), ("</think>", 1002, false)],
                decoder: ["type": "ByteLevel"], byteFallback: false, cleanUp: false),
        Fixture(name: "byte-level cleanup", modelType: "llama", vocabulary: byteLevelVocabulary,
                added: [("<|eot_id|>", 1000, true)],
                decoder: ["type": "ByteLevel"], byteFallback: false, cleanUp: true),
        Fixture(name: "metaspace always", modelType: "llama", vocabulary: metaspaceVocabulary,
                added: [("</s>", 1, true)],
                decoder: ["type": "Metaspace", "replacement": "▁", "prepend_scheme": "always", "split": true],
                byteFallback: true, cleanUp: false),
        Fixture(name: "metaspace first", modelType: "llama", vocabulary: metaspaceVocabulary,
                added: [("</s>", 1, true)],
                decoder: ["type": "Metaspace", "replacement": "▁", "prepend_scheme": "first", "split": true],
                byteFallback: true, cleanUp: false),
        Fixture(name: "sentencepiece strip", modelType: "llama", vocabulary: metaspaceVocabulary,
                added: [("</s>", 1, true)],
                decoder: ["type": "Sequence", "decoders": [
                    ["type": "Replace", "pattern": ["String": "▁"], "content": " "],
                    ["type": "ByteFallback"], ["type": "Fuse"],
                    ["type": "Strip", "content": " ", "start": 1, "stop": 0],
                ]],
                byteFallback: true, cleanUp: false),
        Fixture(name: "glm control table", modelType: "glm5_next", vocabulary: byteLevelVocabulary,
                added: glmAdded, decoder: ["type": "ByteLevel"], byteFallback: false, cleanUp: false),
    ]

    private func load(_ fixture: Fixture) async throws -> (any MLXLMCommon.Tokenizer, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var model: [String: Any] = ["type": "BPE", "vocab": fixture.vocabulary, "merges": [String]()]
        if fixture.byteFallback {
            model["byte_fallback"] = true
            model["unk_token"] = "<unk>"
        }
        let data: [String: Any] = [
            "model": model,
            "added_tokens": fixture.added.map { content, id, special in
                ["id": id, "content": content, "special": special, "lstrip": false, "rstrip": false,
                 "normalized": false, "single_word": false] as [String: Any]
            },
            "decoder": fixture.decoder,
        ]
        try JSONSerialization.data(withJSONObject: data).write(to: directory.appendingPathComponent("tokenizer.json"))
        let config: [String: Any] = [
            "tokenizer_class": "PreTrainedTokenizerFast", "clean_up_tokenization_spaces": fixture.cleanUp,
            "chat_template": Self.template,
        ]
        try JSONSerialization.data(withJSONObject: config).write(to: directory.appendingPathComponent("tokenizer_config.json"))
        try JSONSerialization.data(withJSONObject: ["model_type": fixture.modelType])
            .write(to: directory.appendingPathComponent("config.json"))
        return (try await ChatTemplateCompatTokenizerLoader().load(from: directory), directory)
    }

    func testWindowedDecodeMatchesWholeDecodeOfRealDecoders() async throws {
        var rng = SeededGenerator(state: 2_317_555)
        for fixture in Self.fixtures {
            let (tokenizer, directory) = try await load(fixture)
            defer { try? FileManager.default.removeItem(at: directory) }
            let detokenizer = ModelRuntime.StreamingDetokenizer(tokenizer: tokenizer)
            if fixture.name == "glm control table" {
                // The 30-scalar reserved token sets the lookback: 2 × 30 + 8.
                XCTAssertEqual(detokenizer.decodeLookbackScalars, 68)
            } else {
                XCTAssertEqual(detokenizer.decodeLookbackScalars, 64, fixture.name)
            }
            let ids = Array(fixture.vocabulary.values.filter { $0 != 0 }) + fixture.added.map(\.1)
            var steps = 0
            var fallbacks = 0
            var decoded = 0
            for stream in 0..<6 {
                let decoder = detokenizer.makeWindowedDecoder()
                var generated: [Int] = []
                for step in 0..<300 {
                    for _ in 0..<Int.random(in: 1...3, using: &rng) {
                        generated.append(ids.randomElement(using: &rng)!)
                    }
                    let output = decoder.update(cumulativeTokens: generated)
                    let whole = detokenizer.decode(generated)
                    steps += 1
                    guard output.text == whole else {
                        return XCTFail("\(fixture.name) stream \(stream) step \(step): \(output.text.suffix(80).debugDescription) != \(whole.suffix(80).debugDescription)")
                    }
                }
                fallbacks += decoder.fallbackCount
                decoded += decoder.decodedTokenCount
            }
            // A fallback follows only a text whose end is not yet stable
            // (an incomplete byte sequence, a cleanup-rule tail).
            // These streams take none; at most one per stream is allowed.
            XCTAssertLessThanOrEqual(fallbacks, 6, fixture.name)
            // The window, not the whole list, is decoded per step.
            XCTAssertLessThan(decoded / steps, 200, fixture.name)
        }
    }
}
