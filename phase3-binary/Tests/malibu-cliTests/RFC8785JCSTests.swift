import Foundation
import XCTest
@testable import malibu_cli

final class RFC8785JCSTests: XCTestCase {
    func testStringValuesAreNormalizedToNFCBeforeEscaping() throws {
        let decomposed = "Cafe\u{0301}"
        let precomposed = "Caf\u{00e9}"

        XCTAssertEqual(try RFC8785JCS.canonicalString(.string(decomposed)), "\"\(precomposed)\"")
        XCTAssertEqual(
            try RFC8785JCS.canonicalString(.string(decomposed)),
            try RFC8785JCS.canonicalString(.string(precomposed))
        )
    }

    func testASCIIStringNormalizationIsNoOp() throws {
        XCTAssertEqual(
            try RFC8785JCS.canonicalString(.string("plain ASCII")),
            "\"plain ASCII\""
        )
    }

    func testDoubleFormattingMatchesRFC8785ECMAScriptRules() throws {
        let cases: [(Double, String)] = [
            (0.0, "0"),
            (-0.0, "0"),
            (1.0, "1"),
            (1.1, "1.1"),
            (1e-7, "1e-7"),
            (1e-6, "0.000001"),
            (1e20, "100000000000000000000"),
            (1e21, "1e+21"),
            (333333333.33333329, "333333333.3333333"),
            (4.5, "4.5"),
            (2e-3, "0.002"),
            (1e-27, "1e-27"),
            (1.2345678901234568e30, "1.2345678901234568e+30"),
        ]

        for (input, expected) in cases {
            XCTAssertEqual(
                try RFC8785JCS.canonicalString(.double(input)),
                expected,
                "Unexpected canonical form for \(input)"
            )
        }
    }

    func testNonFiniteDoublesAreRejected() {
        XCTAssertThrowsError(try RFC8785JCS.canonicalString(.double(.nan))) { error in
            XCTAssertEqual(error as? RFC8785JCS.Error, .nonFiniteDouble)
        }
        XCTAssertThrowsError(try RFC8785JCS.canonicalString(.double(.infinity))) { error in
            XCTAssertEqual(error as? RFC8785JCS.Error, .nonFiniteDouble)
        }
        XCTAssertThrowsError(try RFC8785JCS.canonicalString(.double(-.infinity))) { error in
            XCTAssertEqual(error as? RFC8785JCS.Error, .nonFiniteDouble)
        }
    }

    func testExistingIntegerBooleanNullArrayAndObjectBehaviorIsUnchanged() throws {
        let value = RFC8785JCS.Value.object([
            "z": .array([.int(1), .bool(false), .null]),
            "a": .string("line\nquote\"slash\\"),
            "m": .object([
                "b": .int(2),
                "a": .bool(true),
            ]),
        ])

        XCTAssertEqual(
            try RFC8785JCS.canonicalString(value),
            #"{"a":"line\nquote\"slash\\","m":{"a":true,"b":2},"z":[1,false,null]}"#
        )
    }

    func testReplacementCharacterIsEmittedAsRawUTF8PerRFC8785() throws {
        XCTAssertEqual(
            try RFC8785JCS.canonicalString(.string("hi\u{FFFD}")),
            "\"hi\u{FFFD}\""
        )
        XCTAssertEqual(
            try RFC8785JCS.canonicalString(.rawString("k\u{FFFD}")),
            "\"k\u{FFFD}\""
        )
    }

    func testControlCharactersBeyondU001FAreEmittedAsRawUTF8() throws {
        XCTAssertEqual(
            try RFC8785JCS.canonicalString(.string("x\u{007F}y")),
            "\"x\u{007F}y\""
        )
        XCTAssertEqual(
            try RFC8785JCS.canonicalString(.string("x\u{0080}y")),
            "\"x\u{0080}y\""
        )
    }

    func testAdditionalRFC8785ECMAScriptDoubleVectors() throws {
        let cases: [(Double, String)] = [
            (-1.1, "-1.1"),
            (0.000001, "0.000001"),
            (9.999999999999997e22, "9.999999999999997e+22"),
            (1.7976931348623157e308, "1.7976931348623157e+308"),
            (5e-324, "5e-324"),
            (-0.1, "-0.1"),
            (100.0, "100"),
            (0.5, "0.5"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(
                try RFC8785JCS.canonicalString(.double(input)),
                expected,
                "Unexpected canonical form for \(input)"
            )
        }
    }

    func testTupleTierASCIIFieldsHashUnchangedByNFCStep() throws {
        let value = RFC8785JCS.Value.object([
            "model_id": .string("mlx-community/Qwen2.5-Coder-7B-Instruct-4bit"),
            "output_hash": .string("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
            "prompt_hash": .string("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
            "provider_pubkey": .string("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="),
            "tokens_out": .int(42),
            "ttft_ms": .int(1234),
            "unix_ts": .int(1_771_234_567),
        ])

        XCTAssertEqual(
            try RFC8785JCS.canonicalString(value),
            #"{"model_id":"mlx-community/Qwen2.5-Coder-7B-Instruct-4bit","output_hash":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","prompt_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","provider_pubkey":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","tokens_out":42,"ttft_ms":1234,"unix_ts":1771234567}"#
        )
    }
}
