// NativeMTPUpstreamQualificationTests.swift
// SPEC-048 Phase 0: keep the pinned upstream MTP surface explicit.

import MLX
import MLXLMCommon
import XCTest

final class NativeMTPUpstreamQualificationTests: XCTestCase {
    func testPublicTransactionFacadeExposesRowOwnedPositionMetadata() throws {
        let leaf = KVCacheSimple()
        let storage = try MTPKVCacheStorage(cache: [leaf])
        let position = MTPKVCacheTransactionPosition(rowIndex: 7, queryOffset: 42)
        let transaction = try XCTUnwrap(
            storage.beginTransaction(maximumPositions: 1, position: position))

        XCTAssertEqual(transaction.position, position)
        XCTAssertEqual(transaction.position.rowIndex, 7)
        XCTAssertEqual(transaction.position.queryOffset, 42)
        XCTAssertEqual(transaction.maximumPositions, 1)
        XCTAssertEqual(transaction.mode, .staged)

        let (keys, values) = Self.transactionKV(0 ..< 1)
        _ = transaction.cache[0].update(keys: keys, values: values)
        _ = try transaction.commit(retaining: 1)

        XCTAssertEqual(transaction.position, position)
        XCTAssertEqual(storage.processedTokenCount, 1)

        let next = try XCTUnwrap(storage.beginTransaction(maximumPositions: 1))
        XCTAssertEqual(next.position.rowIndex, 0)
        XCTAssertEqual(next.position.queryOffset, 1)
        _ = try next.rollback()
    }

    func testStagedProposalAndTargetVerificationRepresentation() throws {
        let leaf = KVCacheSimple()
        let storage = try MTPKVCacheStorage(cache: [leaf])
        let transaction = try XCTUnwrap(storage.beginTransaction(maximumPositions: 3))

        var targetState = LMOutput.State()
        targetState[mtpCacheCheckpointIndexKey] = 1
        transaction.configureTargetStateForWrite(&targetState)
        XCTAssertNil(targetState[mtpCacheCheckpointIndexKey])

        let (keys, values) = Self.transactionKV(10 ..< 13)
        _ = transaction.cache[0].update(keys: keys, values: values)

        XCTAssertEqual(transaction.writtenPositions, 3)
        XCTAssertTrue(storage.transactionIsOpen)
        XCTAssertEqual(leaf.offset, 3)

        _ = try transaction.rollback()
        XCTAssertFalse(storage.transactionIsOpen)
        XCTAssertEqual(storage.processedTokenCount, 0)
        XCTAssertEqual(leaf.offset, 0)
    }

    func testContiguousPrefixCommitDiscardsRejectedTail() throws {
        let first = KVCacheSimple()
        let second = KVCacheSimple()
        let storage = try MTPKVCacheStorage(cache: [first, second])
        let transaction = try XCTUnwrap(storage.beginTransaction(maximumPositions: 4))

        let (keys, values) = Self.transactionKV(0 ..< 4)
        for cache in transaction.cache {
            _ = cache.update(keys: keys, values: values)
        }

        let commit = try transaction.commit(retaining: 2)

        XCTAssertEqual(commit.committedPositions, 2)
        XCTAssertEqual(commit.discardedPositions, 2)
        XCTAssertEqual(commit.emittedLengths, [2, 2])
        XCTAssertEqual(storage.processedTokenCount, 2)
        XCTAssertEqual(first.offset, 2)
        XCTAssertEqual(second.offset, 2)
        XCTAssertFalse(storage.transactionIsOpen)

        var state: LMOutput.State? = Self.transactionSharedKVState(span: 4)
        XCTAssertTrue(commit.reconcileSharedKVState(&state))
        let sharedKV = try XCTUnwrap(state?[mtpSharedKVStatesKey])
        XCTAssertEqual(try XCTUnwrap(sharedKV["full_attention"]).0.dim(-2), 2)
        XCTAssertEqual(try XCTUnwrap(sharedKV["sliding_attention"]).0.dim(-2), 2)
        XCTAssertEqual(state?[mtpSharedKVOffsetsKey]?["full_attention"], 2)
    }

    func testRollbackAndRewindRestoreExactCachePosition() throws {
        let leaf = KVCacheSimple()
        let storage = try MTPKVCacheStorage(cache: [leaf])

        let rolledBack = try XCTUnwrap(storage.beginTransaction(maximumPositions: 2))
        let (rollbackKeys, rollbackValues) = Self.transactionKV(0 ..< 2)
        _ = rolledBack.cache[0].update(keys: rollbackKeys, values: rollbackValues)
        let rollback = try rolledBack.rollback()

        XCTAssertEqual(rollback.committedPositions, 0)
        XCTAssertEqual(rollback.discardedPositions, 2)
        XCTAssertEqual(storage.processedTokenCount, 0)
        XCTAssertEqual(leaf.offset, 0)
        XCTAssertFalse(storage.transactionIsOpen)

        let committed = try XCTUnwrap(storage.beginTransaction(maximumPositions: 3))
        let (commitKeys, commitValues) = Self.transactionKV(2 ..< 5)
        _ = committed.cache[0].update(keys: commitKeys, values: commitValues)
        _ = try committed.commit(retaining: 3)

        XCTAssertEqual(storage.processedTokenCount, 3)
        XCTAssertEqual(leaf.offset, 3)
        XCTAssertEqual(storage.rewindLastTransaction(2), 2)
        XCTAssertEqual(storage.processedTokenCount, 1)
        XCTAssertEqual(leaf.offset, 1)
        XCTAssertEqual(storage.rewindCommittedLookahead(1), 1)
        XCTAssertEqual(storage.processedTokenCount, 0)
        XCTAssertEqual(leaf.offset, 0)
    }

    func testInvalidSourceAndPositionFailuresLeaveTransactionRecoverable() throws {
        let leaf = KVCacheSimple()
        let storage = try MTPKVCacheStorage(cache: [leaf])

        XCTAssertNil(storage.beginTransaction(maximumPositions: 0))

        let transaction = try XCTUnwrap(storage.beginTransaction(maximumPositions: 2))
        let (keys, values) = Self.transactionKV(0 ..< 2)
        _ = transaction.cache[0].update(keys: keys, values: values)

        XCTAssertThrowsError(try transaction.commit(retaining: 3)) { error in
            XCTAssertEqual(
                error as? MTPKVCacheTransactionError,
                .invalidRetainedPositions(retaining: 3, written: 2))
        }
        XCTAssertTrue(storage.transactionIsOpen)

        let commit = try transaction.commit(retaining: 1)
        XCTAssertEqual(commit.committedPositions, 1)
        XCTAssertEqual(storage.processedTokenCount, 1)
        XCTAssertFalse(storage.transactionIsOpen)

        var missingSourceState: LMOutput.State? = Self.transactionSharedKVState(
            span: 2,
            includeSources: false)
        XCTAssertFalse(
            reconcileMTPSharedKVState(
                &missingSourceState,
                discarding: 1,
                emittedLength: { _ in Int.max }))
        let unchanged = try XCTUnwrap(missingSourceState?[mtpSharedKVStatesKey])
        XCTAssertEqual(try XCTUnwrap(unchanged["full_attention"]).0.dim(-2), 2)

        var outOfRangeState: LMOutput.State? = Self.transactionSharedKVState(span: 1)
        outOfRangeState?[mtpSharedKVSourceIndicesKey]?["sliding_attention"] = 9
        XCTAssertFalse(commit.reconcileSharedKVState(&outOfRangeState))
        let outOfRangeSharedKV = try XCTUnwrap(outOfRangeState?[mtpSharedKVStatesKey])
        XCTAssertEqual(try XCTUnwrap(outOfRangeSharedKV["sliding_attention"]).0.dim(-2), 1)
    }

    func testCacheBoundaryRefusalsDoNotMutateStorage() throws {
        let unsupported = try MTPKVCacheStorage(cache: [MambaCache()])
        XCTAssertNil(unsupported.beginTransaction(maximumPositions: 1))
        XCTAssertNil(
            unsupported.beginTransaction(
                maximumPositions: 2,
                nativeRewindDepth: 1,
                unconditionallyRetainedPositions: 1))
        XCTAssertFalse(unsupported.transactionIsOpen)
        XCTAssertEqual(unsupported.processedTokenCount, 0)

        let attention = RotatingKVCache(maxSize: 4, keep: 0)
        let recurrent = MambaCache()
        let (keys, values) = Self.transactionKV(0 ..< 3)
        _ = attention.update(keys: keys, values: values)
        let boundary = try MTPKVCacheStorage(cache: [attention, recurrent])

        XCTAssertNil(
            boundary.beginTransaction(
                maximumPositions: 2,
                nativeRewindDepth: 1,
                unconditionallyRetainedPositions: 1))
        XCTAssertEqual(attention.offset, 3)
        XCTAssertFalse(boundary.transactionIsOpen)
        XCTAssertEqual(boundary.processedTokenCount, 0)
    }

    func testPinnedForkExposesMTPKVCacheTransactionSymbols() {
        let storageType: Any.Type = MTPKVCacheStorage.self
        let transactionType: Any.Type = MTPKVCacheTransaction.self
        let positionType: Any.Type = MTPKVCacheTransactionPosition.self
        let commitType: Any.Type = MTPKVCacheTransactionCommit.self
        let modeType: Any.Type = MTPKVCacheTransactionMode.self
        let errorType: Any.Type = MTPKVCacheTransactionError.self

        XCTAssertNotNil(storageType)
        XCTAssertNotNil(transactionType)
        XCTAssertNotNil(positionType)
        XCTAssertNotNil(commitType)
        XCTAssertNotNil(modeType)
        XCTAssertNotNil(errorType)
    }

    func testPinnedForkStillExposesSerialMTPSymbols() {
        let drafterProtocol: Any.Type = (any MTPDrafterModel).self
        let iteratorType: Any.Type = MTPSpeculativeTokenIterator.self
        let factoryType: Any.Type = MTPDrafterModelFactory.self

        XCTAssertNotNil(drafterProtocol)
        XCTAssertNotNil(iteratorType)
        XCTAssertNotNil(factoryType)
    }

    func testPinnedMLXStillExposesMXFP8QuantizationMode() {
        XCTAssertEqual(QuantizationMode.mxfp8.rawValue, "mxfp8")
    }

    private static func transactionKV(_ positions: Range<Int>) -> (MLXArray, MLXArray) {
        let values = positions.flatMap { Array(repeating: Float($0), count: 2) }
        let keys = MLXArray(values, [1, 1, positions.count, 2])
        let vals = MLXArray(values.map { -$0 }, [1, 1, positions.count, 2])
        return (keys, vals)
    }

    private static func transactionSharedKVState(
        span: Int,
        includeSources: Bool = true
    ) -> LMOutput.State {
        let keys = MLXArray(Array(0 ..< span).map(Float.init), [1, 1, span, 1])
        let values = -keys
        var state = LMOutput.State()
        state[mtpSharedKVStatesKey] = [
            "full_attention": (keys, values),
            "sliding_attention": (keys, values),
        ]
        if includeSources {
            state[mtpSharedKVSourceIndicesKey] = [
                "full_attention": 0,
                "sliding_attention": 1,
            ]
        }
        state[mtpSharedKVOffsetsKey] = ["full_attention": span]
        return state
    }
}
