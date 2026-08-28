import MacProviderCore
import XCTest

final class ClaimURLFileTests: XCTestCase {
    func testClaimURLFile_WrittenWithMode0600_BeforeOpen_SurvivesOpenKilled() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("claim-url-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = ClaimURLFile(directory: dir)
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)

        try file.write(pairOT: "PAIRSECRET", claimURL: "https://portal.example/claim?ot=PAIRSECRET", expiresAt: expiry)

        let body = try String(contentsOf: file.fileURL, encoding: .utf8)
        XCTAssertTrue(body.contains("pair_ot=PAIRSECRET"))
        XCTAssertTrue(body.contains("claim_url=https://portal.example/claim?ot=PAIRSECRET"))
        let attrs = try FileManager.default.attributesOfItem(atPath: file.fileURL.path)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(mode, 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.fileURL.path + ".tmp"))
    }

    func testClaimURLFile_ReadAndMigrationStub() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("claim-url-read-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = ClaimURLFile(directory: dir)
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)

        try file.write(pairOT: "PAIR", claimURL: "https://portal.example/claim?ot=PAIR", expiresAt: expiry)
        let record = try XCTUnwrap(file.read())
        XCTAssertEqual(record.pairOT, "PAIR")
        XCTAssertEqual(record.claimURL, "https://portal.example/claim?ot=PAIR")

        try file.writeMigrationStub()
        XCTAssertNil(try file.read())
        XCTAssertEqual(try String(contentsOf: file.fileURL, encoding: .utf8), "needs_refresh=true\n")
    }
}
