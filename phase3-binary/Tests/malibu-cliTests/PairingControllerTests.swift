import MacProviderCore
import XCTest

final class PairingControllerTests: XCTestCase {
    func testOwnershipEventBound_DeletesClaimURL_WritesOwnerTxt_Within5s() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pairing-owner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let claimFile = ClaimURLFile(directory: dir)
        try claimFile.write(pairOT: "PAIR", claimURL: "https://portal.example/claim?ot=PAIR", expiresAt: Date().addingTimeInterval(600))
        let controller = PairingController(claimURLFile: claimFile, browserOpener: BrowserOpener(hasControllingTTY: { false }))
        let start = Date()

        try controller.handleOwnershipEvent(OwnershipEventFrame(providerID: "provider-a", githubLogin: "octo", event: .bound))

        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: claimFile.fileURL.path))
        XCTAssertEqual(try String(contentsOf: claimFile.ownerURL, encoding: .utf8), "github_login=octo\n")
        let attrs = try FileManager.default.attributesOfItem(atPath: claimFile.ownerURL.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testPairOT_NeverAppearsInLogs_OutsideClaimURL() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pairing-logs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pairOT = "PAIRSECRET"
        let claimURL = "https://portal.example/claim?ot=\(pairOT)"
        let output = LockedBox("")
        let logOutput = LockedBox("")
        let controller = PairingController(
            claimURLFile: ClaimURLFile(directory: dir),
            browserOpener: BrowserOpener(hasControllingTTY: { false }),
            output: { line in output.update { $0 += line } },
            logOutput: { line in logOutput.update { $0 += line } }
        )

        try controller.handlePairingMaterial(pairOT: pairOT, claimURL: claimURL)

        XCTAssertFalse(output.get().replacingOccurrences(of: claimURL, with: "").contains(pairOT))
        XCTAssertTrue(output.get().contains(claimURL))
        XCTAssertFalse(logOutput.get().contains(pairOT))
        XCTAssertTrue(logOutput.get().contains("ot=REDACTED"))
    }

    func testPairingMaterial_EmitsFallbackLineBeforeFailedBrowserOpen() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pairing-open-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pairOT = "PAIRSECRET"
        let claimURL = "https://portal.example/claim?ot=\(pairOT)"
        let output = LockedBox("")
        let controller = PairingController(
            claimURLFile: ClaimURLFile(directory: dir),
            browserOpener: BrowserOpener(
                hasControllingTTY: { true },
                environment: { _ in nil },
                spawn: { _ in throw BrowserOpenError.spawnFailed(errno: 9) }
            ),
            output: { line in output.update { $0 += line } },
            logOutput: { _ in }
        )

        XCTAssertThrowsError(try controller.handlePairingMaterial(pairOT: pairOT, claimURL: claimURL))

        XCTAssertTrue(output.get().contains("malibu-cli claim"))
        XCTAssertTrue(output.get().contains(claimURL))
        XCTAssertTrue(FileManager.default.fileExists(atPath: URL(fileURLWithPath: dir.path).appendingPathComponent("claim_url").path))
    }

    func testNeedsClaimSignal_WritesStub_NoAutoOpen() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pairing-stub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let opened = LockedBox(false)
        let controller = PairingController(
            claimURLFile: ClaimURLFile(directory: dir),
            browserOpener: BrowserOpener(hasControllingTTY: { true }, spawn: { _ in opened.set(true) })
        )

        try controller.handleNeedsClaim()

        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: dir.path).appendingPathComponent("claim_url"), encoding: .utf8), "needs_refresh=true\n")
        XCTAssertFalse(opened.get())
    }
}
