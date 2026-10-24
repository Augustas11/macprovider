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

    /// A 350k-token prompt in 2048-token chunks, each a bounded blocking
    /// "GPU eval". The cancel lands during chunk 3; the prefill stops before
    /// chunk 5, the wrapper throws `CancellationError` only after the
    /// operation has unwound, and the serial gate's single slot is free again.
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
                        if chunks.increment() == 3 { cancelled.raise() }
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                }
            }
            XCTFail("a cancelled prefill must not complete")
        } catch is CancellationError {
        }

        XCTAssertTrue(unwound.value, "the wrapper returns only after the prefill has unwound")
        XCTAssertGreaterThanOrEqual(chunks.value, 3)
        XCTAssertLessThanOrEqual(chunks.value, 4, "prefill must stop within one chunk of the cancel")
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
                    if chunks.increment() == 2 { drain.fire() }
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
            XCTFail("a drained prefill must not complete")
        } catch is DrainCancelledError {
        }
        XCTAssertLessThanOrEqual(chunks.value, 3)
    }
}
