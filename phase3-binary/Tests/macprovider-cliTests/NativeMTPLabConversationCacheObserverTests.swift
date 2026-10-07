#if DEBUG || MACPROVIDER_LAB_HARNESS
import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

final class NativeMTPLabConversationCacheObserverTests: XCTestCase {
    private enum TestError: Error {
        case unexpectedLoad
    }

    func testObserverBuildsMissAndNotApplicableEventsWithoutRawCacheMaterial() {
        let rawKey = "secret-conversation-key"
        let missLease = ConversationCacheLease(
            key: rawKey,
            keyHash: "hash-only",
            incomingTokens: [1, 2, 3],
            modelID: "fixture-model",
            kvBits: nil,
            reusableCache: nil,
            cachedPromptTokens: 0,
            lcp: 0,
            trimBy: 0
        )

        let miss = NativeMTPLabConversationCacheObserver.event(
            requestID: "req-miss",
            surface: "serial_complete",
            keyPresent: true,
            cacheOnly: true,
            leaseAllowed: true,
            lease: missLease,
            modelHasRecurrentLayers: false,
            monotonicNanoseconds: 42
        )
        let notAttempted = NativeMTPLabConversationCacheObserver.event(
            requestID: "req-no-attempt",
            surface: "serial_stream",
            keyPresent: true,
            cacheOnly: false,
            leaseAllowed: false,
            lease: nil,
            modelHasRecurrentLayers: false,
            monotonicNanoseconds: 43
        )

        XCTAssertEqual(miss.eventSource, "native_mtp_lab_conversation_cache_observer_v1")
        XCTAssertEqual(miss.state, "miss")
        XCTAssertTrue(miss.leaseObserved)
        XCTAssertTrue(miss.leaseAllowed)
        XCTAssertEqual(miss.cachedTokens, 0)
        XCTAssertEqual(miss.payload["record_type"] as? String, "conversation_cache_begin")
        XCTAssertEqual(miss.payload["conversation_cache_lease"] as? String, "miss")
        XCTAssertEqual(miss.payload["conversation_key_cache_only"] as? Bool, true)
        XCTAssertFalse(miss.payload.values.contains { ($0 as? String) == rawKey })

        XCTAssertEqual(notAttempted.state, "not_applicable")
        XCTAssertFalse(notAttempted.leaseObserved)
        XCTAssertFalse(notAttempted.leaseAllowed)
        XCTAssertEqual(notAttempted.surface, "serial_stream")
    }

    func testObserverReportsUsableRetainedHandoffAndCheckpointCount() async throws {
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 16)
        let handle = try await allocator.allocate(
            conversationKey: "conv",
            initialCapacityTokens: 40,
            maxLogicalTokens: 48,
            initialTokens: 40
        )
        let retained = try await allocator.retain(handle)
        defer { Task { try? await allocator.discardRetained(retained) } }
        let checkpoint = RecurrentStateCheckpoint(tokenCount: 36, states: [1: []])
        let lease = ConversationCacheLease(
            key: "conv",
            keyHash: "hash-only",
            incomingTokens: [],
            modelID: "fixture-model",
            kvBits: nil,
            reusableCache: ConversationCacheLayers(
                [],
                retainedPagedKVSequence: retained,
                recurrentCheckpoints: [checkpoint]
            ),
            cachedPromptTokens: 36,
            lcp: 36,
            trimBy: 4,
            recurrentCheckpoint: checkpoint
        )

        let event = NativeMTPLabConversationCacheObserver.event(
            requestID: "req-hit",
            surface: "attached_stream",
            keyPresent: true,
            cacheOnly: false,
            leaseAllowed: true,
            lease: lease,
            modelHasRecurrentLayers: true,
            monotonicNanoseconds: 99
        )

        XCTAssertEqual(event.state, "hit")
        XCTAssertEqual(event.cachedTokens, 36)
        XCTAssertEqual(event.lcp, 36)
        XCTAssertEqual(event.trimBy, 4)
        XCTAssertTrue(event.retainedHandoff)
        XCTAssertTrue(event.usableRetainedHandoff)
        XCTAssertEqual(event.recurrentCheckpointCount, 1)
        XCTAssertEqual(event.payload["conversation_cache_retained_handoff"] as? Bool, true)
        XCTAssertEqual(event.payload["conversation_cache_usable_retained_handoff"] as? Bool, true)
        XCTAssertEqual(event.payload["conversation_cache_recurrent_checkpoint_count"] as? Int, 1)

        let serialFormatLease = ConversationCacheLease(
            key: "conv",
            keyHash: "hash-only",
            incomingTokens: [],
            modelID: "fixture-model",
            kvBits: nil,
            reusableCache: ConversationCacheLayers([], recurrentCheckpoints: [checkpoint]),
            cachedPromptTokens: 36,
            lcp: 36,
            trimBy: 0,
            recurrentCheckpoint: checkpoint
        )
        let captureEquivalentHit = NativeMTPLabConversationCacheObserver.event(
            requestID: "req-capture-hit",
            surface: "serial_complete",
            keyPresent: true,
            cacheOnly: false,
            leaseAllowed: true,
            lease: serialFormatLease,
            modelHasRecurrentLayers: true,
            monotonicNanoseconds: 100
        )
        XCTAssertEqual(captureEquivalentHit.state, "hit")
        XCTAssertTrue(captureEquivalentHit.retainedHandoff)
        XCTAssertFalse(captureEquivalentHit.usableRetainedHandoff)
    }

    func testObserverInstallIsRuntimeOwnedAndSnapshotsEvents() async {
        let runtime = ModelRuntime(
            modelID: "fixture-model",
            warmSwapEnabled: false,
            loader: { _ in throw TestError.unexpectedLoad }
        )
        let observer = NativeMTPLabConversationCacheObserver()

        let installed = await runtime.installLabNativeMTPConversationCacheObserver(observer)
        observer.record(NativeMTPLabConversationCacheObserver.event(
            requestID: "req-1",
            surface: "attached_complete",
            keyPresent: false,
            cacheOnly: false,
            leaseAllowed: false,
            lease: nil,
            modelHasRecurrentLayers: false,
            monotonicNanoseconds: 7
        ))
        let cleared = await runtime.installLabNativeMTPConversationCacheObserver(nil)

        XCTAssertTrue(installed)
        XCTAssertTrue(cleared)
        XCTAssertEqual(observer.snapshot().map(\.requestID), ["req-1"])
    }
}
#endif
