import Foundation
import XCTest
@testable import macprovider_cli

/// SPEC-038-R011: the served-slot gates resize in place, keeping holders'
/// permits, so a live change never admits above the new limit.
final class AsyncSemaphoreResizeTests: XCTestCase {
    func testLoweringKeepsHoldersAndAdmitsNobodyAboveTheNewLimit() async throws {
        let gate = AsyncSemaphore(value: 3)
        let counter = Counter()
        let release = Release()
        var holders: [Task<Void, Error>] = []
        for _ in 0..<3 {
            holders.append(Task { try await gate.withPermit { await counter.enter(); await release.wait(); await counter.leave() } })
        }
        try await waitUntil { await counter.current == 3 }
        await gate.resize(to: 1)
        let late = Task { try await gate.withPermit { await counter.enter(); await counter.leave() } }
        try await Task.sleep(nanoseconds: 50_000_000)
        let peakBeforeRelease = await counter.peak
        XCTAssertEqual(peakBeforeRelease, 3, "lowering never admits a new holder while above the limit")
        await release.open()
        for task in holders { try await task.value }
        try await late.value
        let peak = await counter.peak
        XCTAssertEqual(peak, 3)
        let limit = await gate.currentLimit()
        XCTAssertEqual(limit, 1)
    }

    func testRaisingAdmitsWaitersAtOnce() async throws {
        let gate = AsyncSemaphore(value: 1)
        let counter = Counter()
        let release = Release()
        let first = Task { try await gate.withPermit { await counter.enter(); await release.wait(); await counter.leave() } }
        try await waitUntil { await counter.current == 1 }
        let second = Task { try await gate.withPermit { await counter.enter(); await release.wait(); await counter.leave() } }
        try await Task.sleep(nanoseconds: 50_000_000)
        let beforeResize = await counter.current
        XCTAssertEqual(beforeResize, 1)
        await gate.resize(to: 2)
        try await waitUntil { await counter.current == 2 }
        await release.open()
        try await first.value
        try await second.value
    }

    private func waitUntil(_ condition: @escaping () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("condition not met")
    }
}

private actor Counter {
    private(set) var current = 0
    private(set) var peak = 0
    func enter() { current += 1; peak = max(peak, current) }
    func leave() { current -= 1 }
}

private actor Release {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
