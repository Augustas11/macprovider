import Foundation
import MacProviderCore
import MLX
import MLXLMCommon
import Tokenizers
import XCTest
@testable import macprovider_cli

final class GrammarConstraintTests: XCTestCase {
    func testSerialProcessorAndBatchCursorEnforceTheSameLanguage() throws {
        try Device.withDefaultDevice(.cpu) {
            let pieces: [Int: [UInt8]] = [0: Array("o".utf8), 1: Array("k".utf8), 2: Array("x".utf8), 3: []]
            let serial = try GrammarConstraintState(grammar: .literal("ok"), tokens: pieces, eosTokenIDs: [3])
            let batch = try GrammarConstraintState(grammar: .literal("ok"), tokens: pieces, eosTokenIDs: [3])
            var processor = GrammarLogitProcessor(constraint: serial)
            processor.prompt(MLXArray([Int32(99)]))
            for token in [0, 1, 3] {
                let logits = MLXArray([Float](repeating: 0, count: 4))
                let serialMask = processor.process(logits: logits).asArray(Float.self)
                let batchMask = batch.mask(logits: logits).asArray(Float.self)
                XCTAssertEqual(serialMask, batchMask)
                XCTAssertEqual(serialMask[token], 0)
                XCTAssertTrue(serialMask[2].isInfinite && serialMask[2] < 0)
                processor.didSample(token: MLXArray(Int32(token)))
                batch.didSample(token: token)
            }
            try serial.validate()
            try batch.validate()
        }
    }

    func testReasoningMayContinueUntilCloseButCrossingInvalidPrefixIsMasked() throws {
        try Device.withDefaultDevice(.cpu) {
            let pieces: [Int: [UInt8]] = [0: Array("thought".utf8), 1: Array("</thi".utf8),
                2: Array("nk>o".utf8), 3: Array("k".utf8), 4: Array("nk>x".utf8), 5: []]
            let state = try GrammarConstraintState(grammar: .literal("ok"), tokens: pieces,
                                                   eosTokenIDs: [5], reasoningOpen: true)
            let logits = MLXArray([Float](repeating: 0, count: 6))
            XCTAssertEqual(state.mask(logits: logits).asArray(Float.self)[0], 0)
            state.didSample(token: 0)
            state.didSample(token: 1)
            let crossing = state.mask(logits: logits).asArray(Float.self)
            XCTAssertEqual(crossing[2], 0)
            XCTAssertEqual(crossing[4], -.infinity)
            XCTAssertEqual(crossing[5], -.infinity)
            state.didSample(token: 2)
            XCTAssertEqual(state.mask(logits: logits).asArray(Float.self)[0], -.infinity)
            state.didSample(token: 3)
            state.didSample(token: 5)
            try state.validate()
        }
    }

    func testIllegalSampleFailsClosedWithRequestError() throws {
        let state = try GrammarConstraintState(grammar: .literal("a"), tokens: [0: [97], 1: [120]], eosTokenIDs: [2])
        state.didSample(token: 1)
        XCTAssertThrowsError(try state.validate()) { error in
            XCTAssertEqual((error as? APIError)?.code, "unsupported_output_grammar")
            XCTAssertEqual((error as? APIError)?.status, 400)
        }
    }

    func testCompileCapIsJSONSerializableHTTP400Error() throws {
        XCTAssertThrowsError(try GrammarConstraintState(grammar: .literal(String(repeating: "a", count: 5000)),
                                                        tokens: [0: [97]], eosTokenIDs: [1])) { error in
            guard let api = error as? APIError else { return XCTFail("Expected APIError: \(error)") }
            XCTAssertEqual(api.status, 400)
            XCTAssertEqual(api.code, "unsupported_output_grammar")
            let body = try? JSONSerialization.data(withJSONObject: api.envelope)
            XCTAssertNotNil(body)
            let decoded = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let envelope = decoded?["error"] as? [String: Any]
            XCTAssertEqual(envelope?["code"] as? String, "unsupported_output_grammar")
        }
    }

    func testGPT2VocabularyMetadataUsesRealByteAlphabetAndIDs() async throws {
        // GPT-2's published byte alphabet: ! -> 0, © -> 102, Ã -> 127,
        // Ċ -> 198, Ġ -> 220; é is represented by byte tokens Ã and ©.
        let fixture = #"{"model":{"type":"BPE","vocab":{"!":0,"©":102,"Ã":127,"Ċ":198,"Ġ":220},"merges":[]},"decoder":{"type":"ByteLevel"},"added_tokens":[{"id":50256,"content":"<|endoftext|>","special":true}]}"#
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("grammar-tokenizer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(fixture.utf8).write(to: directory.appendingPathComponent("tokenizer.json"))
        try Data(#"{"tokenizer_class":"GPT2Tokenizer","eos_token":"<|endoftext|>","bos_token":"<|endoftext|>","unk_token":"<|endoftext|>"}"#.utf8)
            .write(to: directory.appendingPathComponent("tokenizer_config.json"))
        let actual = try await AutoTokenizer.from(modelFolder: directory)
        XCTAssertEqual(actual.convertIdToToken(220), "Ġ")
        XCTAssertEqual(actual.decode(tokens: [127, 102]), "é")
        XCTAssertEqual(actual.decode(tokens: [220, 198]), " \n")
        let tokenizer = GrammarVocabularyFixtureTokenizer(base: actual)
        let pieces = try GrammarConstraintState.vocabulary(data: Data(fixture.utf8), tokenizer: tokenizer)
        XCTAssertEqual(pieces[220], [32])
        XCTAssertEqual(pieces[198], [10])
        XCTAssertEqual(pieces[127], [0xc3])
        XCTAssertEqual(pieces[102], [0xa9])
        XCTAssertEqual(pieces[50256], Array("<|endoftext|>".utf8))
        let state = try GrammarConstraintState(grammar: .literal("é"), tokens: pieces, eosTokenIDs: [50256])
        state.didSample(token: 127)
        state.didSample(token: 102)
        state.didSample(token: 50256)
        try state.validate()
    }

    func testHarmonyKnownSpecialIDsParseAnAcceptedFrame() throws {
        let pieces: [Int: String] = [200006: "<|start|>", 200005: "<|channel|>", 200008: "<|message|>",
                                    200002: "<|return|>", 1000: "assistant", 1001: "final", 1002: "ok"]
        let ids = [200006, 1000, 200005, 1001, 200008, 1002, 200002]
        let frame = ids.compactMap { pieces[$0] }.joined()
        let bytes = pieces.mapValues { Array($0.utf8) }
        let state = try GrammarConstraintState(grammar: .literal(frame), tokens: bytes, eosTokenIDs: [200002])
        for id in ids { state.didSample(token: id) }
        try state.validate()
        let parsed = HarmonyResponseParser.parse(tokenIDs: ids, decode: { ids in
            ids.compactMap { pieces[$0] }.joined()
        })
        XCTAssertEqual(parsed.status, .parsed)
        XCTAssertEqual(parsed.content, "ok")
        XCTAssertTrue(parsed.toolCalls.isEmpty)
    }
}

/// Adapt the real local Swift Tokenizers decoder to the runtime protocol.
private struct GrammarVocabularyFixtureTokenizer: MLXLMCommon.Tokenizer {
    let base: any Tokenizers.Tokenizer
    var bosToken: String? { nil }
    var eosToken: String? { "<|endoftext|>" }
    var unknownToken: String? { nil }
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { base.encode(text: text, addSpecialTokens: addSpecialTokens) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        base.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }
    func convertTokenToId(_ token: String) -> Int? { base.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { base.convertIdToToken(id) }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] { [] }
}
