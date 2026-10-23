import XCTest
@testable import MacProviderCore

final class GrammarAutomatonTests: XCTestCase {
    func testCompositionAndEmptyLanguages() throws {
        let grammar = ByteGrammar.sequence([
            .literal("{"), .optional(.literal(" ")),
            .choice([.literal("true"), .literal("false")]),
            .zeroOrMore(.literal(" ")), .literal("}")
        ])
        let dfa = try grammar.compile()
        for string in ["{true}", "{ false   }"] {
            let state = try XCTUnwrap(dfa.transition(state: 0, bytes: Array(string.utf8)))
            XCTAssertTrue(dfa.accepting(state: state))
            XCTAssertNil(dfa.transition(state: state, bytes: [0]))
        }
        XCTAssertNil(dfa.transition(state: 0, bytes: Array("{null}".utf8)))
        XCTAssertFalse(dfa.accepting(state: 0))
        XCTAssertTrue(try ByteGrammar.sequence([]).compile().accepting(state: 0))
        XCTAssertFalse(try ByteGrammar.choice([]).compile().accepting(state: 0))
        let impossible = try ByteGrammar.sequence([.literal("a"), .choice([])]).compile()
        XCTAssertNil(impossible.transition(state: 0, bytes: [97]))
    }
    func testNullableLoopTerminatesAndMatchesBytes() throws {
        let dfa = try ByteGrammar.zeroOrMore(.optional(.bytes([0, 255]))).compile()
        XCTAssertTrue(dfa.accepting(state: 0))
        XCTAssertNotNil(dfa.transition(state: 0, bytes: [0, 255, 255]))
        XCTAssertNil(dfa.transition(state: 0, bytes: [1]))
        XCTAssertNil(dfa.transition(state: -1, bytes: []))
    }
    func testBudgetsFailWithPublicAPIError() throws {
        let grammar = ByteGrammar.literal("hello")
        for limits in [GrammarCompileLimits(maxNodes: 1), .init(maxStates: 1),
                       .init(maxWork: 1), .init(maxSeconds: 0), .init(maxDepth: -1)] {
            XCTAssertThrowsError(try grammar.compile(limits: limits)) { error in
                XCTAssertEqual((error as? APIError)?.status, 400)
                XCTAssertEqual((error as? APIError)?.code, "unsupported_output_grammar")
            }
        }
        XCTAssertThrowsError(try ByteGrammar.optional(grammar).compile(limits: .init(maxDepth: 0)))
    }
    func testAmbiguousAlternativesPreserveAllPaths() throws {
        let dfa = try ByteGrammar.sequence([
            .choice([.literal("a"), .literal("ab")]), .literal("c")
        ]).compile()
        for value in ["ac", "abc"] {
            XCTAssertTrue(dfa.accepting(state: try XCTUnwrap(dfa.transition(state: 0, bytes: Array(value.utf8)))))
        }
        XCTAssertNil(dfa.transition(state: 0, bytes: Array("abbc".utf8)))
    }
}
