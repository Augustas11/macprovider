import MacProviderCore
import XCTest
@testable import macprovider_cli

final class ModelsBrowseFilterTests: XCTestCase {

    private let summaries: [HFModelSummary] = [
        HFModelSummary(id: "mlx-community/Llama-3.2-3B-Instruct-4bit"),     // 2 GB
        HFModelSummary(id: "mlx-community/Qwen2.5-7B-Instruct-4bit"),      // 4 GB
        HFModelSummary(id: "mlx-community/Qwen2.5-14B-Instruct-4bit"),     // 7 GB
        HFModelSummary(id: "mlx-community/Llama-3.3-70B-Instruct-4bit"),   // 35 GB
        HFModelSummary(id: "mlx-community/SomeName-no-size-marker"),       // unparseable
    ]

    func testNoFiltersIncludesAll() throws {
        let rows = filterAndAnnotate(summaries: summaries, ramGB: 16, fitsOnly: false, maxGB: nil)
        XCTAssertEqual(rows.count, 5)
        // The unparseable one comes through with estimate nil and verdict .unknown.
        let unknown = try XCTUnwrap(rows.first { $0.id.contains("SomeName") })
        XCTAssertNil(unknown.estimateGB)
    }

    func testFitsOnlyDropsTightAndWontFit() {
        // On 16 GB Mac: 3B fits, 7B fits, 14B is tight (14+2 not >= 14+6 -> wait 7+6=13 <= 16 -> fits? Let me recompute)
        // Actually: comfortableHeadroomGB = 6, tightHeadroomGB = 2.
        // 3B 4bit = 2 GB -> fits (16 >= 2+6).
        // 7B 4bit = 4 GB -> fits (16 >= 4+6).
        // 14B 4bit = 7 GB -> fits (16 >= 7+6).
        // 70B 4bit = 35 GB -> wontFit.
        // Unknown -> verdict .unknown, not .fits, dropped by fitsOnly.
        let rows = filterAndAnnotate(summaries: summaries, ramGB: 16, fitsOnly: true, maxGB: nil)
        let ids = Set(rows.map(\.id))
        XCTAssertTrue(ids.contains("mlx-community/Llama-3.2-3B-Instruct-4bit"))
        XCTAssertTrue(ids.contains("mlx-community/Qwen2.5-7B-Instruct-4bit"))
        XCTAssertTrue(ids.contains("mlx-community/Qwen2.5-14B-Instruct-4bit"))
        XCTAssertFalse(ids.contains("mlx-community/Llama-3.3-70B-Instruct-4bit"))
        XCTAssertFalse(ids.contains("mlx-community/SomeName-no-size-marker"))
    }

    func testFitsOnlyOn8GBKeepsOnlySmallModels() {
        // On 8 GB Mac: 3B (2 GB) fits, 7B (4 GB) is tight (8 < 4+6), so only 3B.
        let rows = filterAndAnnotate(summaries: summaries, ramGB: 8, fitsOnly: true, maxGB: nil)
        XCTAssertEqual(rows.map(\.id), ["mlx-community/Llama-3.2-3B-Instruct-4bit"])
    }

    func testMaxGBDropsLargeAndKeepsUnparseable() {
        // maxGB=5 should drop 14B (7 GB) and 70B (35 GB). Unparseable has no
        // estimate, so the size guard doesn't trip.
        let rows = filterAndAnnotate(summaries: summaries, ramGB: 32, fitsOnly: false, maxGB: 5)
        let ids = Set(rows.map(\.id))
        XCTAssertTrue(ids.contains("mlx-community/Llama-3.2-3B-Instruct-4bit"))
        XCTAssertTrue(ids.contains("mlx-community/Qwen2.5-7B-Instruct-4bit"))
        XCTAssertFalse(ids.contains("mlx-community/Qwen2.5-14B-Instruct-4bit"))
        XCTAssertFalse(ids.contains("mlx-community/Llama-3.3-70B-Instruct-4bit"))
        XCTAssertTrue(ids.contains("mlx-community/SomeName-no-size-marker"))
    }

    func testFitsOnlyAndMaxGBCompose() {
        // Drop unknown (fitsOnly), drop >5 GB (maxGB). Leaves 3B, 7B.
        let rows = filterAndAnnotate(summaries: summaries, ramGB: 32, fitsOnly: true, maxGB: 5)
        XCTAssertEqual(Set(rows.map(\.id)), [
            "mlx-community/Llama-3.2-3B-Instruct-4bit",
            "mlx-community/Qwen2.5-7B-Instruct-4bit",
        ])
    }

    func testPreservesUpstreamOrder() {
        // HF returns sorted by downloads; we must not reorder.
        let ordered = [
            HFModelSummary(id: "mlx-community/Qwen2.5-7B-Instruct-4bit"),
            HFModelSummary(id: "mlx-community/Llama-3.2-3B-Instruct-4bit"),
        ]
        let rows = filterAndAnnotate(summaries: ordered, ramGB: 16, fitsOnly: false, maxGB: nil)
        XCTAssertEqual(rows.map(\.id), ordered.map(\.id))
    }

    func testVerdictLabelStrings() {
        XCTAssertEqual(verdictLabel(.fits(estGB: 4, ramGB: 16)), "fits")
        XCTAssertEqual(verdictLabel(.tight(estGB: 4, ramGB: 8)), "tight")
        XCTAssertEqual(verdictLabel(.wontFit(estGB: 35, ramGB: 8)), "wont_fit")
        XCTAssertEqual(verdictLabel(.unknown(reason: "x")), "unknown")
    }

    // Round-2 (codex security NIT): HF-returned id is user content. Embedded
    // tab/newline would corrupt the tab-separated rendering; ESC sequences
    // could paint over the terminal.
    func testSanitizeForTableReplacesControlChars() {
        XCTAssertEqual(sanitizeForTable("safe-name"), "safe-name")
        XCTAssertEqual(sanitizeForTable("a\tb"), "a\u{FFFD}b")
        XCTAssertEqual(sanitizeForTable("a\nb"), "a\u{FFFD}b")
        XCTAssertEqual(sanitizeForTable("\u{001B}[31mRED"), "\u{FFFD}[31mRED")
        XCTAssertEqual(sanitizeForTable("DEL\u{007F}suffix"), "DEL\u{FFFD}suffix")
        // Unicode above the C1 range is preserved (printable + extended).
        XCTAssertEqual(sanitizeForTable("mlx-community/Käse-7B"), "mlx-community/Käse-7B")
    }

    // R3 (Codex code + security MINOR): C1 controls (U+0080-U+009F) — most
    // notably U+009B Control Sequence Introducer — can paint terminal
    // escape sequences on some emulators. R2 only sanitized C0+DEL; R3
    // extends to the C1 range.
    func testSanitizeForTableReplacesC1Controls() {
        // U+009B CSI is the dangerous one: behaves as the start of an
        // ANSI escape sequence on emulators that honor 8-bit C1.
        XCTAssertEqual(sanitizeForTable("evil\u{009B}31mRED"), "evil\u{FFFD}31mRED")
        // Boundary cases.
        XCTAssertEqual(sanitizeForTable("\u{0080}"), "\u{FFFD}")
        XCTAssertEqual(sanitizeForTable("\u{009F}"), "\u{FFFD}")
        // Just above the C1 range MUST pass through.
        XCTAssertEqual(sanitizeForTable("\u{00A0}safe"), "\u{00A0}safe")
    }
}
