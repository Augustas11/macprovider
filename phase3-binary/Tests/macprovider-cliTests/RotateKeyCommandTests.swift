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

    // #1690 E2E-F9: serve's receipt builder caches its signing key. Rotating
    // through the runtime's signing store must make the very next receipt
    // carry and verify under the new key; swapping only the underlying store
    // leaves the cached builder on the retired key.
    func testRotationThroughServeSigningStoreSignsNextReceiptWithNewKey() async throws {
        var config = AppConfig.defaults()
        config.enableReceipts = true
        config.providerID = "provider-rotate"
        let underlying = InMemoryReceiptKeyStore()
        let runtime = try ServeCommand.makeReceiptRuntime(config: config, keyStore: underlying)
        let builder = try XCTUnwrap(runtime.builder)
        let signingStore = try XCTUnwrap(runtime.signingKeyStore)
        let original = try XCTUnwrap(underlying.loadCurrent(providerId: "provider-rotate"))

        // The F9 mechanism: an underlying-only swap is invisible to the builder.
        try underlying.swapToCurrent(providerId: "provider-rotate", newKey: Curve25519.Signing.PrivateKey())
        XCTAssertEqual(try Self.receiptPublicKey(builder), original.publicKey.rawRepresentation)

        try await RotateKeyCommand.rotateActiveProvider(
            providerID: "provider-rotate",
            keyStore: signingStore,
            coordinatorClient: MockRotatingCoordinatorClient { _, commitKey in
                try await commitKey()
            }
        )

        let rotated = try XCTUnwrap(underlying.loadCurrent(providerId: "provider-rotate"))
        XCTAssertNotEqual(rotated.rawRepresentation, original.rawRepresentation)
        XCTAssertEqual(try Self.receiptPublicKey(builder), rotated.publicKey.rawRepresentation)
    }

    /// Builds one v0.3 receipt, checks it self-verifies, and returns the
    /// public key it names.
    private static func receiptPublicKey(_ builder: ReceiptBuilder) throws -> Data {
        let receipt = try builder.build(
            providerId: "provider-rotate",
            input: ReceiptInput(
                modelId: "fixture-model",
                request: PromptCanonicalizerTests.fixtureRequest(),
                outputContent: "answer",
                outputToolCalls: nil,
                finishReason: "stop",
                ttftMs: 1,
                tokensOut: 1,
                unixTsSeconds: 1_800_000_000,
                modelHash: nil
            )
        )
        let pieces = receipt.split(separator: ".")
        let tupleData = try XCTUnwrap(Data(base64Encoded: String(pieces[0])))
        let signature = try XCTUnwrap(Data(base64Encoded: String(pieces[1])))
        let tuple = try XCTUnwrap(JSONSerialization.jsonObject(with: tupleData) as? [String: Any])
        let publicKeyData = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(tuple["provider_pubkey"] as? String)))
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
        XCTAssertTrue(publicKey.isValidSignature(signature, for: tupleData))
        return publicKeyData
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
