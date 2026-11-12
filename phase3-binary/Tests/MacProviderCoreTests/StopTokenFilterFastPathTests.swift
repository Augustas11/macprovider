import Foundation
import XCTest
@testable import MacProviderCore

/// `StopTokenFilter.stripping` skips the per-token string searches when a byte
/// scan shows no stop token can occur. These tests hold it to the result of
/// the full removal.
final class StopTokenFilterFastPathTests: XCTestCase {
    private static let llamaLikeTokens: [String] =
        ["<|begin_of_text|>", "<|end_of_text|>", "<|eot_id|>", "<|eom_id|>", "<|python_tag|>", "<|MASK|>", "</s>", "[gMASK]", "▁<pad>", "é|>", ";;", "`end`"]
        + (0..<40).map { "<|reserved_special_token_\($0)|>" }

    private struct Generator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 33
        }
        mutating func pick<T>(_ items: [T]) -> T { items[Int(next() % UInt64(items.count))] }
    }

    /// Pieces that sit on every boundary the byte scan could get wrong:
    /// whole tokens, token halves that join into a token, scalars that
    /// compare equal to ASCII, and scalars that fuse with a neighbour into one
    /// Character.
    private static let pieces: [String] =
        llamaLikeTokens
        + ["<", "<|", "|>", "<|eot", "_id|>", "<|reserved_special_token_", "7|>", "<|MAS", "\u{212A}|>", "<|MAS\u{212A}|>",
           "\u{037E}", "\u{037E}\u{037E}", ";", "\u{1FEF}end\u{1FEF}", "`end", "e\u{301}|>", "\u{E9}", "e", "\u{301}", "\u{FE0F}",
           "\u{200D}", "\u{200B}", "\u{0600}", "\r", "\n", "\r\n", " ", "a < b", "x<y|>z", "Kelvin", "</", "s>", "[g", "MASK]",
           "▁", "<pad>", "日本語", "🙂", "👨\u{200D}👩\u{200D}👧", "\u{FFFD}", "plain words here"]

    func testStrippingMatchesFullRemovalOnRandomTexts() {
        let filter = StopTokenFilter(tokens: Self.llamaLikeTokens)
        var generator = Generator(state: 0x5eed)
        for round in 0..<20_000 {
            var text = ""
            for _ in 0..<Int(generator.next() % 9) {
                text += generator.pick(Self.pieces)
            }
            // Half the time hand over a bridged NSString, as the tokenizer's
            // decode does.
            let input = round % 2 == 0 ? text : (NSString(string: text) as String)
            for joiner in ["", "\u{2060}"] {
                let expected = filter.strippingEveryToken(from: input, joiner: joiner)
                let actual = filter.stripping(from: input, joiner: joiner)
                XCTAssertEqual(
                    Array(actual.unicodeScalars), Array(expected.unicodeScalars),
                    "text=\(Array(text.unicodeScalars).map { String($0.value, radix: 16) }) joiner=\(joiner.unicodeScalars.count)"
                )
                if Array(actual.unicodeScalars) != Array(expected.unicodeScalars) { return }
            }
        }
    }

    func testByteScanNeverMissesATokenTheStringSearchFinds() {
        let filter = StopTokenFilter(tokens: Self.llamaLikeTokens)
        var generator = Generator(state: 0xfeed)
        var found = 0
        for _ in 0..<20_000 {
            var text = ""
            for _ in 0..<Int(generator.next() % 7) {
                text += generator.pick(Self.pieces)
            }
            if filter.tokens.contains(where: { text.contains($0) }) {
                found += 1
                XCTAssertTrue(filter.mayContainToken(text), "\(Array(text.unicodeScalars))")
            }
        }
        XCTAssertGreaterThan(found, 1_000, "the generator must produce texts that hold tokens")
    }

    func testTextWithoutAnyTokenIsReturnedUnchanged() {
        let filter = StopTokenFilter(tokens: Self.llamaLikeTokens)
        let text = String(repeating: "if a < b && c > d { print(\"<|not a token\") } ", count: 200)
        XCTAssertFalse(filter.mayContainToken(text))
        XCTAssertEqual(filter.stripping(from: text, joiner: "\u{2060}"), text)
    }

    func testTokenIsStillRemovedAndJoined() {
        let filter = StopTokenFilter(tokens: ["<|eot_id|>", "<|MASK|>"])
        XCTAssertEqual(filter.stripping(from: "one<|eot_id|>two"), "onetwo")
        XCTAssertEqual(filter.stripping(from: "one<|eot_id|>two", joiner: "+"), "one+two")
        XCTAssertEqual(filter.stripping(from: "one<|MASK|>two<|eot_id|>", joiner: "+"), "one+two")
        // U+212A KELVIN SIGN compares equal to "K": the string search removes
        // it, so the byte scan must not rule the token out.
        XCTAssertEqual(
            filter.stripping(from: "one<|MAS\u{212A}|>two", joiner: "+"),
            filter.strippingEveryToken(from: "one<|MAS\u{212A}|>two", joiner: "+")
        )
    }

    func testEmptyFilterReturnsTextUnchanged() {
        let filter = StopTokenFilter(tokens: [])
        XCTAssertFalse(filter.mayContainToken("<|eot_id|>"))
        XCTAssertEqual(filter.stripping(from: "<|eot_id|>", joiner: "+"), "<|eot_id|>")
    }

    /// The byte scan is sound only if no scalar outside ASCII is canonically
    /// equivalent to a byte-exact ASCII character. Check every scalar.
    func testNoNonASCIIScalarEqualsAByteExactASCIICharacter() {
        var equalToASCII = [UInt32: UInt8]()
        for value in UInt32(0x80)...0x10FFFF {
            guard let scalar = Unicode.Scalar(value) else { continue }
            let composed = String(Character(scalar)).precomposedStringWithCanonicalMapping.unicodeScalars
            if composed.count == 1, let first = composed.first, first.value < 0x80 {
                equalToASCII[value] = UInt8(first.value)
            }
        }
        XCTAssertEqual(equalToASCII, [0x212A: UInt8(ascii: "K"), 0x037E: UInt8(ascii: ";"), 0x1FEF: UInt8(ascii: "`")])
        for byte in equalToASCII.values {
            XCTAssertFalse(StopTokenFilter.isByteExactASCII(byte))
        }
        for (value, byte) in equalToASCII {
            XCTAssertEqual(String(Unicode.Scalar(value)!), String(Unicode.Scalar(byte)))
        }
    }
}
