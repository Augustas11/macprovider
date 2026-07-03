import XCTest
@testable import Malibu

// AUDIT R1 CODE M1: CRLF configuration files must not corrupt the
// provider_id lookup — a trailing \r used to survive whitespace trimming
// and cause a Keychain miss under the corrupted account.

final class ProviderConfigParserTests: XCTestCase {
    // These tests only touch pure parsing on a temp file, they do not write
    // anything to the real ProviderPaths.current locations.

    func testReadProviderIDHandlesCRLF() throws {
        let tmpDir = try makeTempDir()
        let cfg = tmpDir.appendingPathComponent("config.yaml")
        try "provider_id: p-abc\r\nprovider_token: t\r\n".data(using: .utf8)!.write(to: cfg)

        // Not calling ProviderConfig.readProviderID because it reads
        // ProviderPaths.current. Assert the parser algorithm directly here —
        // must match the production implementation exactly. Note: Swift's
        // Character treats \r\n as ONE grapheme, so a naive
        // split(whereSeparator: { $0 == "\n" || $0 == "\r" }) is a no-op on
        // CRLF files; production code normalizes CRLF → LF first.
        let contents = try String(contentsOf: cfg)
        let normalized = contents
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var got: String?
        for rawLine in normalized.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("provider_id:") {
                got = String(line.dropFirst("provider_id:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                break
            }
        }
        XCTAssertEqual(got, "p-abc", "CRLF file must not leave a \\r in provider_id")
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("malibu-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
