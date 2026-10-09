import ArgumentParser
import Foundation
import XCTest
@testable import macprovider_cli

final class RestartCommandTests: XCTestCase {
    func testRestartKickstartsTheProviderAndWaitsForANewPID() async throws {
        let pids = LockedBox([100, 100, 200])
        let kicked = LockedBox([String]())
        let out = LockedBox("")
        let runner = RestartCommandRunner(
            domain: "gui/501",
            currentPID: { _ in
                var pid = 0
                pids.update { pid = $0.count > 1 ? $0.removeFirst() : $0[0] }
                return pid
            },
            kickstart: { domain in kicked.update { $0.append(domain) } },
            sleep: { _ in },
            stdout: { line in out.update { $0 += line } }
        )
        try await runner.run()
        XCTAssertEqual(kicked.get(), ["gui/501"])
        XCTAssertTrue(out.get().contains("gui/501/live.malibu.provider (pid 100 -> 200)"))
    }

    func testRestartRefusesWhenTheServiceIsNotRunning() async {
        let kicked = LockedBox(0)
        let runner = RestartCommandRunner(domain: "gui/501", currentPID: { _ in nil }, kickstart: { _ in kicked.update { $0 += 1 } }, sleep: { _ in })
        do {
            try await runner.run()
            XCTFail("expected not-running error")
        } catch {
            XCTAssertTrue(String(describing: error).contains("not running"))
        }
        XCTAssertEqual(kicked.get(), 0)
    }

    func testRestartFailsWhenNoNewProcessAppears() async {
        let runner = RestartCommandRunner(domain: "system", currentPID: { _ in 7 }, kickstart: { _ in }, sleep: { _ in }, attempts: 3)
        do {
            try await runner.run()
            XCTFail("expected timeout error")
        } catch {
            XCTAssertTrue(String(describing: error).contains("no new serve process"))
        }
    }

    func testRestartIsRegisteredAndUsesKickstart() throws {
        XCTAssertTrue(try MacProviderCLI.parseAsRoot(["restart"]) is RestartCommand)
        XCTAssertEqual(CredentialRestartProver.kickstartCommand(domain: "gui/501").arguments, ["kickstart", "-k", "gui/501/live.malibu.provider"])
    }
}
