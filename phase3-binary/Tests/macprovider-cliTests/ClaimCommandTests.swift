import ArgumentParser
import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

final class ClaimCommandTests: XCTestCase {
    func testClaim_WithFreshLocalClaimURL_MakesZeroNetworkCalls() async throws {
        let fixture = try makeFixture(prefix: "claim-fresh")
        let claimURL = "https://portal.example/claim?ot=FRESH"
        try fixture.claimURLFile.write(pairOT: "FRESH", claimURL: claimURL, expiresAt: fixture.now.addingTimeInterval(600))
        let refreshCalls = LockedBox(0)
        let stdout = LockedBox("")

        try await makeRunner(
            fixture: fixture,
            noBrowser: true,
            refresher: refreshCountingRefresher(refreshCalls),
            stdout: { line in
                stdout.update { $0 += line }
            }
        ).run()

        XCTAssertEqual(refreshCalls.get(), 0)
        XCTAssertEqual(stdout.get(), claimURL)
    }

    func testClaim_WithExpiredClaimURL_CallsRefresh_PersistsResponse_Opens() async throws {
        let fixture = try makeFixture(prefix: "claim-expired")
        try fixture.claimURLFile.write(
            pairOT: "OLD",
            claimURL: "https://portal.example/claim?ot=OLD",
            expiresAt: fixture.now.addingTimeInterval(-1)
        )
        let refreshCalls = LockedBox(0)
        let opened = LockedBox([String]())
        let claimURL = "https://portal.example/claim?ot=NEW"

        try await makeRunner(
            fixture: fixture,
            browserOpener: BrowserOpener(hasControllingTTY: { true }, environment: { _ in nil }, spawn: { url in opened.update { $0.append(url) } }),
            refresher: ClaimRefresher { _ in
                refreshCalls.update { $0 += 1 }
                return ClaimRefreshResponse(pairOT: "NEW", claimURL: claimURL, expiresIn: 600)
            }
        ).run()

        XCTAssertEqual(refreshCalls.get(), 1)
        XCTAssertEqual(opened.get(), [claimURL])
        let record = try XCTUnwrap(fixture.claimURLFile.read())
        XCTAssertEqual(record.pairOT, "NEW")
        XCTAssertEqual(record.claimURL, claimURL)
    }

    func testClaim_WithinPostFirstConnectWindow_PreservesFile_NoRefresh() async throws {
        let fixture = try makeFixture(prefix: "claim-first-connect")
        let claimURL = "https://portal.example/claim?ot=HANDOFF"
        let firstConnectOpens = LockedBox(0)
        let cliOpens = LockedBox(0)
        let controller = PairingController(
            claimURLFile: fixture.claimURLFile,
            browserOpener: BrowserOpener(hasControllingTTY: { true }, environment: { _ in nil }, spawn: { _ in firstConnectOpens.update { $0 += 1 } }),
            now: { fixture.now },
            output: { _ in },
            logOutput: { _ in }
        )
        try controller.handlePairingMaterial(pairOT: "HANDOFF", claimURL: claimURL)
        let beforeAttributes = try FileManager.default.attributesOfItem(atPath: fixture.claimURLFile.fileURL.path)
        let beforeBody = try String(contentsOf: fixture.claimURLFile.fileURL, encoding: .utf8)
        let refreshCalls = LockedBox(0)

        try await makeRunner(
            fixture: fixture,
            browserOpener: BrowserOpener(hasControllingTTY: { true }, environment: { _ in nil }, spawn: { _ in cliOpens.update { $0 += 1 } }),
            refresher: refreshCountingRefresher(refreshCalls)
        ).run()

        let afterAttributes = try FileManager.default.attributesOfItem(atPath: fixture.claimURLFile.fileURL.path)
        let afterBody = try String(contentsOf: fixture.claimURLFile.fileURL, encoding: .utf8)
        XCTAssertEqual(firstConnectOpens.get(), 1)
        XCTAssertEqual(cliOpens.get(), 1)
        XCTAssertEqual(refreshCalls.get(), 0)
        XCTAssertEqual(afterBody, beforeBody)
        XCTAssertEqual(afterAttributes[.modificationDate] as? Date, beforeAttributes[.modificationDate] as? Date)
    }

    func testClaim_WithMigrationStubFile_TriggersRefresh() async throws {
        let fixture = try makeFixture(prefix: "claim-stub")
        try fixture.claimURLFile.writeMigrationStub()
        let refreshCalls = LockedBox(0)
        let stdout = LockedBox("")
        let claimURL = "https://portal.example/claim?ot=STUB"

        try await makeRunner(
            fixture: fixture,
            noBrowser: true,
            refresher: ClaimRefresher { _ in
                refreshCalls.update { $0 += 1 }
                return ClaimRefreshResponse(pairOT: "STUB", claimURL: claimURL, expiresIn: 600)
            },
            stdout: { line in
                stdout.update { $0 += line }
            }
        ).run()

        XCTAssertEqual(refreshCalls.get(), 1)
        XCTAssertEqual(stdout.get(), claimURL)
        XCTAssertEqual(try fixture.claimURLFile.read()?.pairOT, "STUB")
    }

    func testClaim_WithInvalidFreshLocalClaimURL_TriggersRefresh() async throws {
        let fixture = try makeFixture(prefix: "claim-invalid-local")
        try fixture.claimURLFile.write(
            pairOT: "LOCAL",
            claimURL: "https://portal.example/claim?ot=OTHER",
            expiresAt: fixture.now.addingTimeInterval(600)
        )
        let refreshCalls = LockedBox(0)
        let stdout = LockedBox("")
        let claimURL = "https://portal.example/claim?ot=FIXED"

        try await makeRunner(
            fixture: fixture,
            noBrowser: true,
            refresher: ClaimRefresher { _ in
                refreshCalls.update { $0 += 1 }
                return ClaimRefreshResponse(pairOT: "FIXED", claimURL: claimURL, expiresIn: 600)
            },
            stdout: { line in
                stdout.update { $0 += line }
            }
        ).run()

        XCTAssertEqual(refreshCalls.get(), 1)
        XCTAssertEqual(stdout.get(), claimURL)
        XCTAssertEqual(try fixture.claimURLFile.read()?.pairOT, "FIXED")
    }

    func testClaim_OnRefresh401_ExitsNonZero_StderrMessage() async throws {
        let fixture = try makeFixture(prefix: "claim-401")
        let stderr = LockedBox("")
        let runner = makeRunner(
            fixture: fixture,
            refresher: ClaimRefresher { _ in throw ClaimRefreshError.unauthorized },
            stderr: { line in stderr.update { $0 += line } }
        )

        do {
            try await runner.run()
            XCTFail("expected 401 exit")
        } catch {
            XCTAssertEqual(error as? ExitCode, ExitCode(1))
        }
        XCTAssertTrue(stderr.get().contains("error: provider token rejected by coordinator — has this Mac been unbound?"))
    }

    func testClaim_OnRefresh429_HonoursRetryAfter_StderrMessage() async throws {
        let fixture = try makeFixture(prefix: "claim-429")
        let stderr = LockedBox("")
        let runner = makeRunner(
            fixture: fixture,
            refresher: ClaimRefresher { _ in throw ClaimRefreshError.rateLimited(seconds: 37) },
            stderr: { line in stderr.update { $0 += line } }
        )

        do {
            try await runner.run()
            XCTFail("expected 429 exit")
        } catch {
            XCTAssertEqual(error as? ExitCode, ExitCode(2))
        }
        XCTAssertTrue(stderr.get().contains("error: rate limit exceeded; retry in 37 seconds"))
    }

    func testClaim_WithInvalidRefreshResponse_DoesNotPersist() async throws {
        let fixture = try makeFixture(prefix: "claim-invalid-refresh")
        let stderr = LockedBox("")
        let runner = makeRunner(
            fixture: fixture,
            refresher: ClaimRefresher { _ in
                ClaimRefreshResponse(pairOT: "BAD\nTOKEN", claimURL: "https://portal.example/claim?ot=OTHER", expiresIn: 600)
            },
            stderr: { line in stderr.update { $0 += line } }
        )

        do {
            try await runner.run()
            XCTFail("expected invalid refresh response exit")
        } catch {
            XCTAssertEqual(error as? ExitCode, ExitCode(3))
        }
        XCTAssertTrue(stderr.get().contains("error: failed to refresh claim URL"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.claimURLFile.fileURL.path))
    }

    func testClaimCommand_IsRegisteredOnRootCLI() throws {
        let command = try MacProviderCLI.parseAsRoot(["claim", "--no-browser"])

        XCTAssertTrue(command is ClaimCommand)
    }

    func testClaimRefreshRedirectGuardStripsAuthorizationOnCrossOriginHTTPSRedirect() throws {
        let redirected = decideRedirect(
            originalURL: URL(string: "https://coordinator.example/v1/provider/claim/refresh")!,
            redirectTo: URL(string: "https://other.example/v1/provider/claim/refresh")!
        )

        XCTAssertEqual(redirected?.url?.host, "other.example")
        XCTAssertNil(redirected?.value(forHTTPHeaderField: "Authorization"))
    }

    func testClaimRefreshRedirectGuardStripsAuthorizationOnSameHostDifferentPortRedirect() throws {
        let redirected = decideRedirect(
            originalURL: URL(string: "https://coordinator.example/v1/provider/claim/refresh")!,
            redirectTo: URL(string: "https://coordinator.example:4443/v1/provider/claim/refresh")!
        )

        XCTAssertEqual(redirected?.url?.port, 4443)
        XCTAssertNil(redirected?.value(forHTTPHeaderField: "Authorization"))
    }

    func testClaimRefreshRedirectGuardRejectsNonHTTPSRedirect() throws {
        let redirected = decideRedirect(
            originalURL: URL(string: "https://coordinator.example/v1/provider/claim/refresh")!,
            redirectTo: URL(string: "http://coordinator.example/v1/provider/claim/refresh")!
        )

        XCTAssertNil(redirected)
    }

    private func refreshCountingRefresher(_ calls: LockedBox<Int>) -> ClaimRefresher {
        ClaimRefresher { _ in
            calls.update { $0 += 1 }
            throw ClaimRefreshError.httpStatus(500)
        }
    }

    private func decideRedirect(originalURL: URL, redirectTo newURL: URL) -> URLRequest? {
        let session = URLSession.shared
        let task = session.dataTask(with: originalURL)
        var request = URLRequest(url: newURL)
        request.setValue("Bearer provider-token", forHTTPHeaderField: "Authorization")
        let response = HTTPURLResponse(
            url: originalURL,
            statusCode: 302,
            httpVersion: nil,
            headerFields: ["Location": newURL.absoluteString]
        )!
        let waiter = expectation(description: "redirect completion")
        var redirected: URLRequest?
        ClaimRefreshRedirectGuard().urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: request
        ) { result in
            redirected = result
            waiter.fulfill()
        }
        wait(for: [waiter], timeout: 1)
        return redirected
    }

    private func makeFixture(prefix: String) throws -> ClaimFixture {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let configURL = dir.appendingPathComponent("config.yaml")
        try """
        coordinator_url: wss://coordinator.example/ws/provider
        provider_token: provider-token

        """.write(to: configURL, atomically: true, encoding: .utf8)
        var config = AppConfig.defaults(configPath: configURL.path)
        config.coordinatorURL = "wss://coordinator.example/ws/provider"
        config.providerToken = "provider-token"
        return ClaimFixture(
            directory: dir,
            config: config,
            claimURLFile: ClaimURLFile(directory: dir),
            now: Date(timeIntervalSince1970: 1_788_888_000)
        )
    }

    private func makeRunner(
        fixture: ClaimFixture,
        noBrowser: Bool = false,
        browserOpener: BrowserOpener = BrowserOpener(hasControllingTTY: { false }),
        refresher: ClaimRefresher,
        stdout: @escaping ClaimCommandRunner.Output = { _ in },
        stderr: @escaping ClaimCommandRunner.Output = { _ in }
    ) -> ClaimCommandRunner {
        ClaimCommandRunner(
            config: fixture.config,
            noBrowser: noBrowser,
            claimURLFile: fixture.claimURLFile,
            browserOpener: browserOpener,
            refresher: refresher,
            now: { fixture.now },
            environment: { _ in nil },
            stdout: stdout,
            stderr: stderr
        )
    }
}

private struct ClaimFixture {
    let directory: URL
    let config: AppConfig
    let claimURLFile: ClaimURLFile
    let now: Date
}
