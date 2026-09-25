import XCTest
@testable import macprovider_cli

/// #1690 E2E-F13: a token boundary inside a multi-byte UTF-8 character must
/// not put U+FFFD on the buyer's stream, and the streamed bytes must equal
/// the final text the receipt hashes.
final class StreamingUTF8BoundaryTests: XCTestCase {
    /// Replays per-token full decodes the way the native streaming paths do:
    /// hold back an incomplete tail, append the scalar-exact delta, then
    /// flush the remainder against the final decode.
    private static func stream(decodes: [String], final: String) -> (chunks: [String], text: String) {
        var emitted = ""
        var chunks: [String] = []
        for decoded in decodes {
            let delta = ModelRuntime.streamDelta(from: emitted, to: ModelRuntime.withoutIncompleteUTF8Tail(decoded))
            if !delta.isEmpty {
                chunks.append(delta)
                emitted += delta
            }
        }
        let remainder = ModelRuntime.streamDelta(from: emitted, to: final)
        if !remainder.isEmpty {
            chunks.append(remainder)
            emitted += remainder
        }
        return (chunks, emitted)
    }

    func testMultiByteCharacterSplitAcrossTokensIsNeverStreamedLossy() {
        // "été 灯塔": é (2 bytes) and 灯 (3 bytes) each split across tokens;
        // a prefix decode renders the partial bytes as a trailing U+FFFD.
        let decodes = ["\u{FFFD}", "ét", "ét\u{FFFD}", "été ", "été \u{FFFD}", "été \u{FFFD}", "été 灯", "été 灯塔"]
        let result = Self.stream(decodes: decodes, final: "été 灯塔")
        XCTAssertFalse(result.chunks.contains { $0.unicodeScalars.contains("\u{FFFD}") }, "\(result.chunks)")
        XCTAssertEqual(Array(result.text.utf8), Array("été 灯塔".utf8))
    }

    func testTrailingIncompleteSequenceIsFlushedAsTheFinalTextRendersIt() {
        // Generation ended inside a character: the final decode keeps the
        // replacement character, and so does the stream, byte for byte.
        let result = Self.stream(decodes: ["ab", "ab\u{FFFD}"], final: "ab\u{FFFD}")
        XCTAssertEqual(Array(result.text.utf8), Array("ab\u{FFFD}".utf8))
        // A replacement character inside valid text is streamed once completed.
        let inner = Self.stream(decodes: ["a\u{FFFD}", "a\u{FFFD}b"], final: "a\u{FFFD}b")
        XCTAssertEqual(Array(inner.text.utf8), Array("a\u{FFFD}b".utf8))
    }

    func testCombiningMarkAfterEmittedBaseIsAppendedScalarExact() {
        // Character-based comparison treats "e" + U+0301 as one Character and
        // would stall or drop the mark; the delta is exact on scalars.
        XCTAssertEqual(ModelRuntime.streamDelta(from: "cafe", to: "cafe\u{301} noir"), "\u{301} noir")
        let result = Self.stream(decodes: ["cafe", "cafe\u{301}", "cafe\u{301} noir"], final: "cafe\u{301} noir")
        XCTAssertEqual(Array(result.text.utf8), Array("cafe\u{301} noir".utf8))
        XCTAssertEqual(ModelRuntime.streamDelta(from: "abc", to: "abd"), "")
    }
}
