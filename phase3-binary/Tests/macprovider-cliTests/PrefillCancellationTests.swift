import Foundation
import MLXLMCommon
@testable import macprovider_cli
import XCTest

/// SPEC-001 FR-26 / SPEC-001-R013: a buyer cancel stops a serial request
/// during prefill within one chunk, not only between decode tokens. The serial
/// paths run under `withDrainAndClientCancellation`, which cancels the
/// operation's task when `shouldCancel` turns true; the model's chunked prefill
/// (`PrefillParameters.forEachChunk`, DeepSeek-V4 `prepare`) checks task
/// cancellation before every chunk.
final class PrefillCancellationTests: XCTestCase {
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        var value: Bool { lock.lock(); defer { lock.unlock() }; return raised }
        func raise() { lock.lock(); raised = true; lock.unlock() }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        @discardableResult
        func increment() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
    }

    /// Blocks the current chunk until the cancel has reached the operation's
    /// task, standing in for a GPU eval that is still running when it lands.
    private static func holdChunkUntilTaskCancelled() {
        let deadline = Date().addingTimeInterval(10)
        while !Task.isCancelled, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
    }

    /// A 350k-token prompt in 2048-token chunks. The cancel lands during
    /// chunk 3; the prefill stops before chunk 4, the wrapper throws
    /// `CancellationError` only after the operation has unwound, and the
    /// serial gate's single slot is free again.
    func testClientCancelStopsChunkedPrefillWithinOneChunkAndReleasesTheSlot() async throws {
        let gate = AsyncSemaphore(value: 1)
        let drain = DrainCancelToken()
        let cancelled = Flag()
        let chunks = Counter()
        let unwound = Flag()

        do {
            _ = try await ModelRuntime.withDrainAndClientCancellation(drain, shouldCancel: { cancelled.value }) {
                try await gate.withPermit {
                    defer { unwound.raise() }
                    return try PrefillParameters(stepSize: 2048).forEachChunk(total: 350_000) { _ in
                        if chunks.increment() == 3 {
                            cancelled.raise()
                            Self.holdChunkUntilTaskCancelled()
                        }
                    }
                }
            }
            XCTFail("a cancelled prefill must not complete")
        } catch is CancellationError {
        }

        XCTAssertTrue(unwound.value, "the wrapper returns only after the prefill has unwound")
        XCTAssertEqual(chunks.value, 3, "prefill must stop at the chunk boundary after the cancel")
        let reacquired = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { try await gate.withPermit { true } }
            group.addTask {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return false
            }
            let first = try await group.next() ?? false
            group.cancelAll()
            return first
        }
        XCTAssertTrue(reacquired, "the cancelled request's serial slot is released")
    }

    /// A cancel that arrives before the first chunk runs no chunk at all.
    func testCancelBeforePrefillRunsNoChunk() async throws {
        let drain = DrainCancelToken()
        let chunks = Counter()
        do {
            _ = try await ModelRuntime.withDrainAndClientCancellation(drain, shouldCancel: { true }) {
                // Give the cancel watcher time to fire before the prefill starts.
                try await Task.sleep(nanoseconds: 200_000_000)
                return try PrefillParameters(stepSize: 2048).forEachChunk(total: 8192) { _ in
                    chunks.increment()
                }
            }
            XCTFail("a cancelled prefill must not complete")
        } catch is CancellationError {
        }
        XCTAssertEqual(chunks.value, 0)
    }

    /// Without a cancel the wrapper is transparent: the prefill runs every
    /// chunk and the operation's result is returned.
    func testUncancelledPrefillRunsEveryChunk() async throws {
        let drain = DrainCancelToken()
        let chunks = Counter()
        let processed = try await ModelRuntime.withDrainAndClientCancellation(drain, shouldCancel: { false }) {
            try PrefillParameters(stepSize: 2048).forEachChunk(total: 8193) { _ in
                chunks.increment()
            }
        }
        XCTAssertEqual(processed, 8192)
        XCTAssertEqual(chunks.value, 4)
    }

    /// A drain still ends the operation with `DrainCancelledError`, not a
    /// buyer cancel.
    func testDrainStillEndsTheOperationAsADrain() async throws {
        let drain = DrainCancelToken()
        let chunks = Counter()
        do {
            _ = try await ModelRuntime.withDrainAndClientCancellation(drain, shouldCancel: { false }) {
                try PrefillParameters(stepSize: 2048).forEachChunk(total: 350_000) { _ in
                    if chunks.increment() == 2 {
                        drain.fire()
                        Self.holdChunkUntilTaskCancelled()
                    }
                }
            }
            XCTFail("a drained prefill must not complete")
        } catch is DrainCancelledError {
        }
        XCTAssertEqual(chunks.value, 2)
    }

    /// A drain that coincides with a buyer cancel is reported as the drain.
    func testDrainTakesPrecedenceOverACoincidingCancel() async throws {
        let drain = DrainCancelToken()
        drain.fire()
        do {
            _ = try await ModelRuntime.withDrainAndClientCancellation(drain, shouldCancel: { true }) {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return 0
            }
            XCTFail("a drained operation must not complete")
        } catch is DrainCancelledError {
        }
    }

    /// The serial paths bridge a cancel only while the request prefills. After
    /// the operation marks its prefill done, a cancel no longer interrupts it,
    /// so the decode loop handles it exactly as before (same terminal, same
    /// receipt). A cancel that interrupted the prefill makes the mark throw, so
    /// decode never starts.
    func testPrefillScopeInterruptsOnlyWhilePrefilling() throws {
        let interrupted = PrefillCancelScope()
        XCTAssertFalse(interrupted.interruptsPrefill(cancelled: false))
        XCTAssertTrue(interrupted.interruptsPrefill(cancelled: true))
        XCTAssertThrowsError(try interrupted.markPrefillDone()) { XCTAssertTrue($0 is CancellationError) }

        let decoding = PrefillCancelScope()
        try decoding.markPrefillDone()
        XCTAssertFalse(decoding.interruptsPrefill(cancelled: true), "a cancel after prefill is left to the decode loop")
        decoding.reopenForPrefill()
        XCTAssertTrue(decoding.interruptsPrefill(cancelled: true), "a fallback that prefills again is interruptible again")
    }

    /// Through the wrapper: after the mark, the operation runs to completion
    /// even though the cancel flag is raised, and its result is returned.
    func testCancelAfterPrefillDoesNotInterruptTheOperation() async throws {
        let drain = DrainCancelToken()
        let scope = PrefillCancelScope()
        let cancelled = Flag()
        let value = try await ModelRuntime.withDrainAndClientCancellation(
            drain, shouldCancel: { scope.interruptsPrefill(cancelled: cancelled.value) }
        ) {
            try scope.markPrefillDone()
            cancelled.raise()
            try await Task.sleep(nanoseconds: 100_000_000)
            try Task.checkCancellation()
            return 7
        }
        XCTAssertEqual(value, 7)
    }

    /// A request waiting for another request's conversation key stops waiting
    /// when cancelled, takes no lease, and leaves the key's turn order intact.
    func testCancelledWaiterForABusyConversationKeyTakesNoLease() async throws {
        let cache = makeConversationCacheForTest(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
        let tokens = (0..<64).map(Int32.init)
        let ownerLease = await cache.begin(conversationKey: "conv:busy", incomingTokens: tokens,
                                           modelID: "model-a", kvBits: nil)
        let owner = try XCTUnwrap(ownerLease)
        let waiter = Task {
            await cache.begin(conversationKey: "conv:busy", incomingTokens: tokens, modelID: "model-a", kvBits: nil)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        waiter.cancel()
        let cancelledLease = await waiter.value
        XCTAssertNil(cancelledLease, "a cancelled waiter takes no lease")

        let next = Task {
            await cache.begin(conversationKey: "conv:busy", incomingTokens: tokens, modelID: "model-a", kvBits: nil)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        await cache.abort(owner)
        let nextResult = await next.value
        let nextLease = try XCTUnwrap(nextResult, "the next waiter still gets the turn")
        await cache.abort(nextLease)
    }
}
