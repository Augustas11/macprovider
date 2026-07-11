import Foundation
import XCTest
@testable import Malibu

final class CLIUpdateRunnerTests: XCTestCase {
    func testNonzeroRollbackMarkerIsExposedDistinctly() async throws {
        do {
            try await CLIUpdateRunner.runForTest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "echo rollback_restored >&2; exit 6"],
                onLogLine: { _ in },
                readinessCheck: { true }
            )
            XCTFail("rollback failure unexpectedly returned success")
        } catch let error as CLIUpdateRunner.Error {
            XCTAssertEqual(
                error.localizedDescription,
                "Provider update failed; the previous release was restored (rollback_restored, exit 6)."
            )
        }
    }

    func testZeroExitStillRequiresBuyerServingReadiness() async throws {
        do {
            try await CLIUpdateRunner.runForTest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "exit 0"],
                onLogLine: { _ in },
                readinessCheck: { false }
            )
            XCTFail("unready provider update unexpectedly returned success")
        } catch let error as CLIUpdateRunner.Error {
            XCTAssertEqual(
                error.localizedDescription,
                "Provider update installed but did not reach buyer-serving readiness."
            )
        }
    }

    func testNonzeroRollbackFailureIsExposedDistinctly() async throws {
        do {
            try await CLIUpdateRunner.runForTest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "echo rollback_failed >&2; exit 7"],
                onLogLine: { _ in },
                readinessCheck: { true }
            )
            XCTFail("rollback failure unexpectedly returned success")
        } catch let error as CLIUpdateRunner.Error {
            XCTAssertEqual(
                error.localizedDescription,
                "Provider update and rollback both failed (rollback_failed, exit 7)."
            )
        }
    }

    func testReadinessSuccessCompletesUpdate() async throws {
        try await CLIUpdateRunner.runForTest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit 0"],
            onLogLine: { _ in },
            readinessCheck: { true }
        )
    }
}
