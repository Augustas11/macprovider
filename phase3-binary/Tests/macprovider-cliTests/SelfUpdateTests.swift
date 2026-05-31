import Foundation
import XCTest
@testable import macprovider_cli

final class SelfUpdateTests: XCTestCase {
    func testDefaultReleaseRepositoryMatchesPublicInstaller() {
        XCTAssertEqual(
            SelfUpdate.defaultReleasesAPIURL,
            "https://api.github.com/repos/Augustas11/macprovider/releases/latest"
        )
    }

    func testSemverComparison() {
        XCTAssertEqual(SelfUpdate.compareSemver("1.2.0", "1.2.1"), .orderedAscending)
        XCTAssertEqual(SelfUpdate.compareSemver("v1.2.1", "1.2.1"), .orderedSame)
        XCTAssertEqual(SelfUpdate.compareSemver("1.3.0", "1.2.9"), .orderedDescending)
        XCTAssertEqual(SelfUpdate.compareSemver("1.2", "1.2.0"), .orderedSame)
    }

    func testValidatedUpdateDrainsBeforeReplacingAndRestartingLaunchd() async throws {
        let recorder = UpdateActionRecorder()
        let binary = URL(fileURLWithPath: "/tmp/macprovider-cli-test")
        let update = SelfUpdate(
            currentVersion: "1.2.0",
            releasesAPIURL: nil,
            drainBeforeReplace: {
                recorder.append("drain_status:starting")
                recorder.append("drain_status:in_progress")
                recorder.append("drain_status:complete")
            },
            replaceBinary: { _ in
                recorder.append("replace")
            },
            restartLaunchd: {
                recorder.append("launchctl_bootstrap")
            }
        )

        try await update.applyValidatedUpdateForTest(newBinary: binary)

        XCTAssertEqual(recorder.snapshot(), [
            "drain_status:starting",
            "drain_status:in_progress",
            "drain_status:complete",
            "replace",
            "launchctl_bootstrap",
        ])
    }
}

private final class UpdateActionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var actions: [String] = []

    func append(_ action: String) {
        lock.lock()
        defer { lock.unlock() }
        actions.append(action)
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return actions
    }
}
