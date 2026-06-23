import CryptoKit
import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

final class RotateKeyCommandTests: XCTestCase {
    func testRotateKeyCommitsCandidateAfterReconnectAcceptance() async throws {
        let store = InMemoryReceiptKeyStore()
        let providerID = "provider-rotate"
        let original = try store.loadOrGenerate(providerId: providerID)
        let capturedCurrentBeforeCommit = LockedKeyBox()

        try await RotateKeyCommand.rotateActiveProvider(
            providerID: providerID,
            keyStore: store,
            coordinatorClient: MockRotatingCoordinatorClient { candidate, commitKey in
                capturedCurrentBeforeCommit.set(try store.loadCurrent(providerId: providerID))
                XCTAssertNotEqual(candidate.rawRepresentation, original.rawRepresentation)
                try await commitKey()
            }
        )

        XCTAssertEqual(capturedCurrentBeforeCommit.get()?.rawRepresentation, original.rawRepresentation)
        let current = try XCTUnwrap(store.loadCurrent(providerId: providerID))
        XCTAssertNotEqual(current.rawRepresentation, original.rawRepresentation)
        XCTAssertEqual(store.previousKeyForTest(providerId: providerID)?.rawRepresentation, original.rawRepresentation)
    }

    func testRotateKeyLeavesKeychainUnchangedWhenReconnectRejected() async throws {
        let store = InMemoryReceiptKeyStore()
        let providerID = "provider-rotate"
        let original = try store.loadOrGenerate(providerId: providerID)

        do {
            try await RotateKeyCommand.rotateActiveProvider(
                providerID: providerID,
                keyStore: store,
                coordinatorClient: MockRotatingCoordinatorClient { _, _ in
                    throw CoordinatorAuthError.rejected(code: "bad_request", message: "rejected")
                }
            )
            XCTFail("rotate should fail when reconnect is rejected")
        } catch let ReceiptKeyRotationError.reconnectFailed(message) {
            XCTAssertTrue(message.contains("rejected"), message)
        }

        XCTAssertEqual(try store.loadCurrent(providerId: providerID)?.rawRepresentation, original.rawRepresentation)
        XCTAssertNil(store.previousKeyForTest(providerId: providerID))
    }

    func testRequestRotationPreservesCommittedUnconfirmedControlResult() async throws {
        let socketPath = try makeSocketPath()
        let server = ControlSocketServer(
            socketPath: socketPath,
            modelRuntime: try await ModelRuntime(modelID: nil),
            receiptRotator: {
                throw CoordinatorReceiptRotationCommittedRecoveryFailed(underlying: "state_update timeout")
            },
            receiptRotationProviderID: "provider-a",
            idleTimeoutSeconds: 0.2
        )
        try await server.start()
        defer { Task { await server.stop() } }

        var config = AppConfig.defaults(configPath: "/tmp/macprovider-test.yaml")
        config.providerID = "provider-a"
        config.ctlSocketPath = socketPath.path

        do {
            try await RotateKeyCommand.requestRotation(config: config)
            XCTFail("rotation should preserve committed-unconfirmed result")
        } catch let error as ReceiptKeyRotationError {
            XCTAssertEqual(error, .committedButPublicationUnconfirmed("receipt key rotation committed locally, but coordinator publication recovery failed: state_update timeout"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testRotateKeyRequiresProviderID() async throws {
        await XCTAssertThrowsErrorAsync(
            try await RotateKeyCommand.rotateActiveProvider(
                providerID: "   ",
                keyStore: InMemoryReceiptKeyStore(),
                coordinatorClient: MockRotatingCoordinatorClient { _, _ in
                    XCTFail("client should not be used without provider_id")
                }
            )
        ) { error in
            XCTAssertEqual(error as? ReceiptKeyRotationError, .missingProviderID)
        }
    }
    private func makeSocketPath() throws -> URL {
        let dir = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("mpcs-\(getpid())-\(Int.random(in: 0 ... 999_999))")
        return dir.appendingPathComponent("ctl.sock")
    }

}

private final class MockRotatingCoordinatorClient: ReceiptKeyRotatingCoordinatorClient, @unchecked Sendable {
    private let body: @Sendable (
        Curve25519.Signing.PrivateKey,
        @escaping @Sendable () async throws -> Void
    ) async throws -> Void

    init(_ body: @escaping @Sendable (
        Curve25519.Signing.PrivateKey,
        @escaping @Sendable () async throws -> Void
    ) async throws -> Void) {
        self.body = body
    }

    func reconnectWithNewKey(
        _ newKey: Curve25519.Signing.PrivateKey,
        commitKey: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await body(newKey, commitKey)
    }
}

private final class LockedKeyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var key: Curve25519.Signing.PrivateKey?

    func set(_ key: Curve25519.Signing.PrivateKey?) {
        lock.lock()
        self.key = key
        lock.unlock()
    }

    func get() -> Curve25519.Signing.PrivateKey? {
        lock.lock()
        defer { lock.unlock() }
        return key
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> Void,
    _ handler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error to be thrown", file: file, line: line)
    } catch {
        handler(error)
    }
}
