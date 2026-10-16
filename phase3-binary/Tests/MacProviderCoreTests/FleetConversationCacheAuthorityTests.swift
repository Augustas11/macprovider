import Foundation
import XCTest
@testable import MacProviderCore

final class FleetConversationCacheAuthorityTests: XCTestCase {
    func testRawChatBodyCannotMintFleetGrant() throws {
        let body: [String: Any] = [
            "model": "test-model",
            "messages": [["role": "user", "content": "hello"]],
            "fleet_cache": ["conversation_key": "conv:caller", "generation": 99],
        ]
        let request = try ChatCompletionRequest.parse(
            data: JSONSerialization.data(withJSONObject: body)
        )

        XCTAssertNil(request.fleetCacheGrant)
        XCTAssertNil(request.conversationKey)
    }

    func testPurgePersistsFloorBeforeTeardownAndRejectsDelayedGrantAfterRestart() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("revocations.json")
        do {
            let authority = FleetConversationCacheAuthority(storageURL: url)
            let oldGrant = try authority.authorize(conversationKey: "conv:opaque-1", generation: 7)
            XCTAssertTrue(oldGrant.isValid)

            let sawRevokedBeforePurge = LockedFlag()
            let purged = try await authority.revokeAndPurge(
                conversationKey: "conv:opaque-1",
                through: 7
            ) { _ in
                sawRevokedBeforePurge.set(!oldGrant.isValid)
                return true
            }

            XCTAssertTrue(purged)
            XCTAssertTrue(sawRevokedBeforePurge.value)
            XCTAssertFalse(oldGrant.isValid)
            XCTAssertThrowsError(try authority.authorize(conversationKey: "conv:opaque-1", generation: 7))
            XCTAssertTrue(try authority.authorize(conversationKey: "conv:opaque-1", generation: 8).isValid)
        }
        let restarted = FleetConversationCacheAuthority(storageURL: url)
        XCTAssertThrowsError(try restarted.authorize(conversationKey: "conv:opaque-1", generation: 7))
        XCTAssertTrue(try restarted.authorize(conversationKey: "conv:opaque-1", generation: 8).isValid)
    }

    func testFailedCacheTeardownDoesNotUndoDurableRevocation() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("revocations.json")
        do {
            let authority = FleetConversationCacheAuthority(storageURL: url)
            let grant = try authority.authorize(conversationKey: "conv:opaque-2", generation: 11)

            let purged = try await authority.revokeAndPurge(
                conversationKey: "conv:opaque-2",
                through: 11,
                purge: { _ in false }
            )

            XCTAssertFalse(purged)
            XCTAssertFalse(grant.isValid)
        }
        let restarted = FleetConversationCacheAuthority(storageURL: url)
        XCTAssertThrowsError(try restarted.authorize(conversationKey: "conv:opaque-2", generation: 11))
    }

    func testMalformedMetadataFailsClosed() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("revocations.json")
        try Data("not-json".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        let authority = FleetConversationCacheAuthority(storageURL: url)
        XCTAssertThrowsError(try authority.authorize(conversationKey: "conv:opaque-3", generation: 1)) {
            XCTAssertEqual($0 as? FleetConversationCacheAuthority.AuthorityError, .metadataUnavailable)
        }
    }

    func testSecondLiveAuthorityForSameJournalFailsClosed() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("revocations.json")
        let first = FleetConversationCacheAuthority(storageURL: url)
        let second = FleetConversationCacheAuthority(storageURL: url)

        XCTAssertTrue(first.isAvailable)
        XCTAssertFalse(second.isAvailable)
        XCTAssertThrowsError(try second.authorize(conversationKey: "conv:opaque", generation: 1))
    }

    func testBoundsAndGenerationValidation() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = FleetConversationCacheAuthority(
            storageURL: root.appendingPathComponent("revocations.json")
        )

        XCTAssertThrowsError(try authority.authorize(conversationKey: "account:raw", generation: 1))
        XCTAssertThrowsError(try authority.authorize(conversationKey: "conv:opaque", generation: 0))
        XCTAssertThrowsError(try authority.authorize(
            conversationKey: "conv:" + String(repeating: "x", count: 252),
            generation: 1
        ))
    }

    func testJournalBoundsCoverCoordinatorScopeCapacity() {
        XCTAssertEqual(FleetConversationCacheAuthority.maxRevocationScopes, 100_000)

        // Control bytes are rejected by the authority, so a valid key expands
        // by at most 2x during JSON escaping. This checks the configured bound
        // without constructing or encoding a 100,000-record journal in tests.
        let conservativeBytesPerRecord =
            (FleetConversationCacheAuthority.maxConversationKeyBytes * 2) + 128
        XCTAssertGreaterThanOrEqual(
            FleetConversationCacheAuthority.maxMetadataBytes,
            FleetConversationCacheAuthority.maxRevocationScopes * conservativeBytesPerRecord
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleet-cache-authority-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ value: Bool) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}
