import Foundation
import XCTest
@testable import MacProviderCore
@testable import malibu_cli

/// Issue #767 — a build below the coordinator's `required_binary_version` is
/// closed with 4004 `version_unsupported`. Before this, the close fell through
/// the close-code switch and the reconnect loop retried forever, so an operator
/// saw an unexplained flap instead of an upgrade directive.
final class VersionFloorRejectionTests: XCTestCase {
    private func makeStatus() -> ProviderStatus {
        ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
    }

    private func makeConfig() -> AppConfig {
        var config = AppConfig.defaults(configPath: "/tmp/macprovider-version-floor-test.yaml")
        config.coordinatorURL = "wss://127.0.0.1:8444/ws/provider"
        config.providerID = "mp-0123456789abcdef0123456789abcdef"
        config.model = "model-a"
        return config
    }

    // MARK: - close-code classification

    func testVersionUnsupportedCloseIsTypedWithTheRequiredTarget() async throws {
        let socket = VersionFloorFakeSocket(
            closeCodeRawValue: 4004,
            closeReasonText: "version_unsupported: binary_version 1.8.32 below required 1.8.33"
        )
        let runtime = try await ModelRuntime(modelID: nil)
        let client = try XCTUnwrap(CoordinatorClient(
            config: makeConfig(),
            modelRuntime: runtime,
            providerStatus: makeStatus(),
            attestationGenerator: VersionFloorNoAttestationGenerator(),
            webSocketFactory: { _ in socket },
            sleepAssertionFactory: { nil }
        ))

        do {
            try await client.connectAndRunOnceForTest()
            XCTFail("a 4004 version_unsupported close must throw")
        } catch let CoordinatorAuthError.rejected(code, message) {
            XCTAssertEqual(code, "version_unsupported")
            XCTAssertTrue(message.contains("below required 1.8.33"), message)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testRequiredBinaryVersionParsedFromCloseReason() {
        XCTAssertEqual(
            CoordinatorClient.requiredBinaryVersion(
                from: "version_unsupported: binary_version 1.8.32 below required 1.8.33"
            ),
            "1.8.33"
        )
        // Degrade gracefully rather than printing a wrong or hostile target.
        XCTAssertNil(CoordinatorClient.requiredBinaryVersion(from: "version_unsupported"))
        XCTAssertNil(CoordinatorClient.requiredBinaryVersion(from: "version_unsupported: below required "))
        XCTAssertNil(
            CoordinatorClient.requiredBinaryVersion(
                from: "version_unsupported: below required rm -rf /"
            )
        )
    }

    func testVersionFloorRejectionOnlyMatchesTheFloorClose() {
        let matched = CoordinatorClient.versionFloorRejection(
            for: CoordinatorAuthError.rejected(
                code: "version_unsupported",
                message: "version_unsupported: binary_version 1.8.32 below required 1.9.0"
            )
        )
        XCTAssertEqual(matched?.requiredVersion, "1.9.0")
        XCTAssertEqual(matched?.currentVersion, CoordinatorClient.binaryVersion)

        XCTAssertNil(CoordinatorClient.versionFloorRejection(
            for: CoordinatorAuthError.rejected(code: "invalid_token", message: "invalid_token")
        ))
        XCTAssertNil(CoordinatorClient.versionFloorRejection(for: VersionFloorTestError.closedByCoordinator))
    }

    func testVersionUnsupportedLifecycleClassification() {
        let classification = CoordinatorClient.lifecycleClassification(
            for: CoordinatorAuthError.rejected(
                code: "version_unsupported",
                message: "version_unsupported: binary_version 1.8.32 below required 1.8.33"
            )
        )
        XCTAssertEqual(classification.state, .catalogIncompatible)
        XCTAssertEqual(classification.reasonCode, "binary_version_unsupported")
    }

    // MARK: - the reconnect loop must STOP

    /// The load-bearing acceptance: a below-floor build must not hammer the
    /// coordinator. One attempt, then the loop returns and never retries.
    func testVersionFloorRejectionStopsTheReconnectLoop() async throws {
        let attempts = VersionFloorAttemptCounter()
        let runtime = try await ModelRuntime(modelID: nil)
        let client = try XCTUnwrap(CoordinatorClient(
            config: makeConfig(),
            modelRuntime: runtime,
            providerStatus: makeStatus(),
            reconnectInitialBackoffNanoseconds: 1_000_000,
            attestationGenerator: VersionFloorNoAttestationGenerator(),
            sleepAssertionFactory: { nil },
            connectAndRunOverride: {
                _ = await attempts.record()
                throw CoordinatorAuthError.rejected(
                    code: "version_unsupported",
                    message: "version_unsupported: binary_version 1.8.32 below required 1.9.0"
                )
            }
        ))
        await client.suppressSignedRecoveryDiscoveryForTest()

        await client.start()
        try await waitUntil(timeoutNanoseconds: 2_000_000_000) {
            await client.coordinatorVersionFloorRejection() != nil
        }
        // Give the loop ample time to make a second attempt if it were going to.
        try await Task.sleep(nanoseconds: 200_000_000)
        await client.stop()

        let count = await attempts.current()
        XCTAssertEqual(count, 1, "a below-floor build must not retry; it made \(count) attempts")
        let recorded = await client.coordinatorVersionFloorRejection()
        let rejection = try XCTUnwrap(recorded)
        XCTAssertEqual(rejection.requiredVersion, "1.9.0")
        XCTAssertEqual(rejection.currentVersion, CoordinatorClient.binaryVersion)
    }

    /// A non-floor rejection must keep the ordinary retry behavior — the new
    /// terminal branch must not swallow transient failures.
    func testOtherRejectionsStillRetry() async throws {
        let attempts = VersionFloorAttemptCounter()
        let runtime = try await ModelRuntime(modelID: nil)
        let client = try XCTUnwrap(CoordinatorClient(
            config: makeConfig(),
            modelRuntime: runtime,
            providerStatus: makeStatus(),
            reconnectInitialBackoffNanoseconds: 1_000_000,
            attestationGenerator: VersionFloorNoAttestationGenerator(),
            sleepAssertionFactory: { nil },
            connectAndRunOverride: {
                _ = await attempts.record()
                throw VersionFloorTestError.closedByCoordinator
            }
        ))
        await client.suppressSignedRecoveryDiscoveryForTest()

        await client.start()
        try await waitUntil(timeoutNanoseconds: 2_000_000_000) {
            await attempts.current() >= 3
        }
        await client.stop()

        let recorded = await client.coordinatorVersionFloorRejection()
        XCTAssertNil(recorded, "a transport failure must not be recorded as a version-floor rejection")
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64,
        _ condition: @Sendable () async -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("condition not met within timeout")
    }
}

enum VersionFloorTestError: Error {
    case closedByCoordinator
}

actor VersionFloorAttemptCounter {
    private var count = 0

    func record() -> Int {
        count += 1
        return count
    }

    func current() -> Int {
        count
    }
}

/// Minimal local fakes — CoordinatorClientTests' own fakes are file-private.
struct VersionFloorNoAttestationGenerator: Tier2AttestationTokenGenerating, @unchecked Sendable {
    func makeAttestationToken(
        challengeBase64URL: String?,
        authAttemptID: String,
        providerID: String,
        binaryVersion: String,
        snapshot: ProviderSnapshot,
        providerECDHPublicKey: String
    ) async -> [String: Any]? {
        nil
    }
}

/// A socket that immediately fails every receive and reports the close
/// diagnostics the coordinator would have sent.
final class VersionFloorFakeSocket: ProviderWebSocketTask, @unchecked Sendable {
    let closeCodeRawValueForDiagnostics: Int?
    let closeReasonTextForDiagnostics: String?

    init(closeCodeRawValue: Int?, closeReasonText: String?) {
        self.closeCodeRawValueForDiagnostics = closeCodeRawValue
        self.closeReasonTextForDiagnostics = closeReasonText
    }

    func resume() {}

    func send(_ message: URLSessionWebSocketTask.Message) async throws {}

    func receive() async throws -> URLSessionWebSocketTask.Message {
        throw VersionFloorTestError.closedByCoordinator
    }

    func cancel(with _: URLSessionWebSocketTask.CloseCode, reason _: Data?) {}
}
