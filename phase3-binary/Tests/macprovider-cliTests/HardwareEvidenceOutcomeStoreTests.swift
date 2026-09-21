import Darwin
import Foundation
import XCTest
@testable import macprovider_cli

/// Issue #1616 — the reason onboarding failed must survive the process that
/// printed it, and must be safe to render in an operator's terminal.
final class HardwareEvidenceOutcomeStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hw-evidence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var storeURL: URL { directory.appendingPathComponent("last-hardware-evidence.json") }

    private static let esc = "\u{1B}"
    private static let csi = "\u{9B}"
    private static let del = "\u{7F}"

    func testRecordsEachSubmissionOutcomeAndReadsItBack() throws {
        let now = Date(timeIntervalSince1970: 1_786_000_000)

        HardwareEvidenceOutcomeStore.record(.submitted, at: now, to: storeURL)
        var stored = try HardwareEvidenceOutcomeStore.read(from: storeURL)
        XCTAssertEqual(stored.outcome, "submitted")
        XCTAssertNil(stored.reason)
        XCTAssertFalse(stored.recordedAt.isEmpty)

        HardwareEvidenceOutcomeStore.record(
            .failed("rate_limited: retry in 420 seconds"),
            at: now,
            to: storeURL
        )
        stored = try HardwareEvidenceOutcomeStore.read(from: storeURL)
        XCTAssertEqual(stored.outcome, "failed")
        XCTAssertEqual(stored.reason, "rate_limited: retry in 420 seconds")

        HardwareEvidenceOutcomeStore.record(.skipped("provider_id missing"), at: now, to: storeURL)
        stored = try HardwareEvidenceOutcomeStore.read(from: storeURL)
        XCTAssertEqual(stored.outcome, "skipped")
        XCTAssertEqual(stored.reason, "provider_id missing")
    }

    func testRecordIsOwnerOnly() throws {
        HardwareEvidenceOutcomeStore.record(.submitted, to: storeURL)
        var st = stat()
        XCTAssertEqual(lstat(storeURL.path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
    }

    /// Doctor prints the reason to a terminal. C0 and C1 control bytes are
    /// dropped, including the single-byte CSI (U+009B) that a naive ESC filter
    /// misses, so a coordinator- or error-derived string cannot emit escape
    /// sequences.
    func testSanitizeStripsControlCharactersAndBoundsLength() {
        XCTAssertEqual(HardwareEvidenceOutcomeStore.sanitize("rate_limited"), "rate_limited")
        XCTAssertEqual(
            HardwareEvidenceOutcomeStore.sanitize("a\(Self.esc)[31mred\(Self.esc)[0m"),
            "a[31mred[0m"
        )
        XCTAssertEqual(HardwareEvidenceOutcomeStore.sanitize("a\(Self.csi)31mb"), "a31mb")
        XCTAssertEqual(
            HardwareEvidenceOutcomeStore.sanitize("line\nbreak\tand\(Self.del)del"),
            "linebreakanddel"
        )
        XCTAssertNil(HardwareEvidenceOutcomeStore.sanitize(nil))
        XCTAssertNil(HardwareEvidenceOutcomeStore.sanitize("   "))
        XCTAssertNil(HardwareEvidenceOutcomeStore.sanitize("\(Self.esc)\(Self.csi)"))

        let long = String(repeating: "x", count: 1_000)
        XCTAssertEqual(
            HardwareEvidenceOutcomeStore.sanitize(long)?.count,
            HardwareEvidenceOutcomeStore.maximumReasonLength
        )
    }

    func testReadRejectsGroupOrWorldWritableRecords() throws {
        HardwareEvidenceOutcomeStore.record(.submitted, to: storeURL)
        XCTAssertEqual(chmod(storeURL.path, 0o666), 0)
        XCTAssertThrowsError(try HardwareEvidenceOutcomeStore.read(from: storeURL)) { error in
            XCTAssertEqual(error as? HardwareEvidenceOutcomeStore.StoreError, .unsafePath)
        }
    }

    func testReadRejectsASymlink() throws {
        let target = directory.appendingPathComponent("target.json")
        try Data("{}".utf8).write(to: target)
        let link = directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try HardwareEvidenceOutcomeStore.read(from: link)) { error in
            XCTAssertEqual(error as? HardwareEvidenceOutcomeStore.StoreError, .unsafePath)
        }
    }

    func testReadRejectsMalformedRecord() throws {
        try Data("not json".utf8).write(to: storeURL)
        XCTAssertEqual(chmod(storeURL.path, 0o600), 0)
        XCTAssertThrowsError(try HardwareEvidenceOutcomeStore.read(from: storeURL)) { error in
            XCTAssertEqual(error as? HardwareEvidenceOutcomeStore.StoreError, .malformed)
        }
    }

    /// A record written by an older build predates the write-side filter, so
    /// the read side must sanitize too rather than trusting the file. The
    /// escape arrives JSON-encoded (``), which is the only way a control
    /// character can legally sit inside a JSON string — a raw control byte is
    /// rejected as malformed one layer earlier.
    func testReadSanitizesLegacyRecords() throws {
        let raw = "{\"outcome\":\"failed\",\"reason\":\"boom\\u001b[2J\",\"recorded_at\":\"2026-09-19T00:00:00Z\"}"
        try Data(raw.utf8).write(to: storeURL)
        XCTAssertEqual(chmod(storeURL.path, 0o600), 0)
        let stored = try HardwareEvidenceOutcomeStore.read(from: storeURL)
        XCTAssertEqual(stored.reason, "boom[2J")
    }

    /// A diagnostics breadcrumb must never break the submission it describes.
    func testRecordToAnUnwritableLocationIsSilent() {
        let unwritable = URL(fileURLWithPath: "/proc/definitely-not-writable/record.json")
        HardwareEvidenceOutcomeStore.record(.submitted, to: unwritable)
    }
}
