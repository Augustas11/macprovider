import XCTest
@testable import MacProviderCore

final class GrammarTokenTableTests: XCTestCase {
    func testTokenReachabilityIsBoundedAndPrunesDeadPrefixes() throws {
        let dfa = try ByteGrammar.choice([.literal("ab"), .literal("cd")]).compile()
        let table = try GrammarTokenTable(tokens: [0: [97], 1: [99], 2: [100]], eosTokenIDs: [3])
        let productive = try table.productiveStates(automaton: dfa)
        XCTAssertTrue(productive.contains(0))
        XCTAssertFalse(productive.contains(try XCTUnwrap(dfa.transition(state: 0, bytes: [97]))))
        XCTAssertTrue(productive.contains(try XCTUnwrap(dfa.transition(state: 0, bytes: [99]))))
        XCTAssertThrowsError(try table.productiveStates(automaton: dfa, maxWork: 1))
        let complete = try GrammarTokenTable(tokens: Dictionary(uniqueKeysWithValues: (0..<256).map { ($0, [UInt8($0)]) }), eosTokenIDs: [256])
        XCTAssertTrue(try complete.productiveStates(automaton: dfa).contains(0))
    }

    func testPiecesMaySplitUTF8AndEOSRequiresAcceptance() throws {
        let dfa = try ByteGrammar.literal("é").compile()
        let table = try GrammarTokenTable(tokens: [0: [0xc3], 1: [0xa9], 2: [0xc3, 0xa9],
                                                   3: [0xc3, 0xa9, 0x21], 4: []], eosTokenIDs: [4])
        let first = try table.allowedTokens(state: 0, automaton: dfa)
        XCTAssertEqual(Set(first.keys), [0, 2])
        let middle = try XCTUnwrap(first[0])
        XCTAssertEqual(Set(try table.allowedTokens(state: middle, automaton: dfa).keys), [1])
        let end = try XCTUnwrap(first[2])
        XCTAssertEqual(try table.allowedTokens(state: end, automaton: dfa), [4: end])
    }
    func testEOSCanConsumeOnlyACompleteTerminalWrapper() throws {
        let dfa = try ByteGrammar.literal("a<end>").compile()
        let table = try GrammarTokenTable(tokens: [0: [97], 1: Array("<end>".utf8)], eosTokenIDs: [1])
        let first = try table.allowedTokens(state: 0, automaton: dfa)
        XCTAssertNil(first[1])
        let afterA = try XCTUnwrap(first[0])
        let terminal = try XCTUnwrap(table.allowedTokens(state: afterA, automaton: dfa)[1])
        XCTAssertTrue(dfa.accepting(state: terminal))
        XCTAssertEqual(try table.allowedTokens(state: terminal, automaton: dfa)[1], terminal)
        let bounded = try GrammarTokenTable(tokens: [1: Array("<end>".utf8)], eosTokenIDs: [1],
                                            limits: .init(maxScanBytes: 4))
        XCTAssertThrowsError(try bounded.allowedTokens(state: afterA, automaton: dfa))
    }
    func testExplicitTokenizerDecoderModes() throws {
        XCTAssertEqual(try GrammarTokenBytes.decode(piece: "ĠHiĊ", encoding: .byteLevel), Array(" Hi\n".utf8))
        XCTAssertEqual(try GrammarTokenBytes.decode(piece: "Ã", encoding: .byteLevel), [0xc3])
        XCTAssertEqual(try GrammarTokenBytes.decode(piece: "©", encoding: .byteLevel), [0xa9])
        XCTAssertEqual(try GrammarTokenBytes.decode(piece: "▁hi", encoding: .sentencePiece), Array(" hi".utf8))
        XCTAssertEqual(try GrammarTokenBytes.decode(piece: "<0xFF>", encoding: .sentencePiece), [255])
        XCTAssertEqual(try GrammarTokenBytes.decode(piece: "▁", encoding: .raw), Array("▁".utf8))
        XCTAssertThrowsError(try GrammarTokenBytes.decode(piece: "☃", encoding: .byteLevel))
    }
    func testEmptyPiecesAndBoundsRejected() throws {
        XCTAssertThrowsError(try GrammarTokenTable(tokens: [0: []], eosTokenIDs: []))
        XCTAssertThrowsError(try GrammarTokenTable(tokens: [-1: [1]], eosTokenIDs: []))
        XCTAssertThrowsError(try GrammarTokenTable(tokens: [0: [1, 2]], eosTokenIDs: [], limits: .init(maxBytes: 1)))
        let table = try GrammarTokenTable(tokens: [0: [1, 2]], eosTokenIDs: [], limits: .init(maxScanBytes: 1))
        let dfa = try ByteGrammar.literal("x").compile()
        XCTAssertThrowsError(try table.allowedTokens(state: 0, automaton: dfa))
        XCTAssertThrowsError(try table.allowedTokens(state: -1, automaton: dfa))
    }
}
