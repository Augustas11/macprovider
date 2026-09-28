// NativeMTPUpstreamQualificationTests.swift
// SPEC-048 Phase 0: keep the pinned upstream MTP surface explicit.

import MLX
import MLXLMCommon
import MLXNN
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
        XCTAssertEqual(boundary.processedTokenCount, 3)
    }

    func testPublicPackedVerificationAPIUsesExplicitMixedRaggedRows() throws {
        let model = PackedVerificationModel()
        let cache = PackedVerificationCache(offsets: [12, 1, 8])
        let rowMaps = [
            MTPPackedVerificationRowMap(
                rowIndex: 91, queryOffset: 12, inputCount: 1, proposalCount: 0),
            MTPPackedVerificationRowMap(
                rowIndex: 4, queryOffset: 1, inputCount: 3, proposalCount: 2),
            MTPPackedVerificationRowMap(
                rowIndex: 7, queryOffset: 8, inputCount: 2, proposalCount: 1),
        ]
        let tokens = MLXArray([
            30, 999, 999,
            40, 41, 42,
            50, 51, 999,
        ]).reshaped(3, 3)

        let output = try verifyMTPPackedTargets(
            model: model,
            tokens: tokens,
            rowMaps: rowMaps,
            cache: [cache])

        XCTAssertEqual(model.callCount, 1)
        XCTAssertEqual(model.receivedTokens, [30, 999, 999, 40, 41, 42, 50, 51, 999])
        XCTAssertEqual(model.receivedMask, [1, 0, 0, 1, 1, 1, 1, 1, 0])
        XCTAssertEqual(model.receivedEmitFlag, true)
        XCTAssertNil(model.receivedOpaqueState)
        XCTAssertEqual(model.observedActiveLengths, [1, 3, 2])
        XCTAssertEqual(model.observedActiveRowMaps, rowMaps)

        XCTAssertEqual(cache.packedPrepareCallCount, 1)
        XCTAssertEqual(cache.preparedRowMaps, rowMaps)
        XCTAssertEqual(cache.baseTokenColumns, [0, 0, 0])
        XCTAssertEqual(cache.proposalColumnRanges, [1 ..< 1, 1 ..< 3, 1 ..< 2])
        XCTAssertEqual(cache.stagedCommitCandidatePositions, [[], [2, 3], [9]])
        XCTAssertEqual(cache.prepareCallCount, 1)
        XCTAssertEqual(cache.preparedLengths, [1, 3, 2])
        XCTAssertEqual(cache.finalizeCallCount, 1)
        XCTAssertNil(cache.activeLengths)
        XCTAssertNil(cache.activeRowMaps)

        XCTAssertEqual(output.rows.map(\.map.rowIndex), [91, 4, 7])
        XCTAssertEqual(output.rows[0].proposalLogits.shape, [0, 3])
        XCTAssertEqual(output.rows[0].proposalLogits.size, 0)
        XCTAssertEqual(output.rows[0].bonusLogits.asArray(Float.self), [0, 1, 2])
        XCTAssertEqual(output.rows[0].lastHidden?.asArray(Float.self), [0, 1])

        XCTAssertEqual(output.rows[1].proposalLogits.shape, [2, 3])
        XCTAssertEqual(
            output.rows[1].proposalLogits.asArray(Float.self),
            [100, 101, 102, 110, 111, 112])
        XCTAssertEqual(output.rows[1].bonusLogits.asArray(Float.self), [120, 121, 122])
        XCTAssertEqual(
            output.rows[1].lastHidden?.asArray(Float.self),
            [100, 101, 110, 111, 120, 121])

        XCTAssertEqual(output.rows[2].proposalLogits.shape, [1, 3])
        XCTAssertEqual(output.rows[2].proposalLogits.asArray(Float.self), [200, 201, 202])
        XCTAssertEqual(output.rows[2].bonusLogits.asArray(Float.self), [210, 211, 212])
        XCTAssertEqual(
            output.rows[2].lastHidden?.asArray(Float.self),
            [200, 201, 210, 211])
    }

    func testPublicPackedVerificationRejectsIncapableOrEmptyCache() throws {
        let model = PackedVerificationModel()
        let rowMaps = [
            MTPPackedVerificationRowMap(
                rowIndex: 0, queryOffset: 0, inputCount: 2, proposalCount: 1)
        ]
        let tokens = MLXArray([1, 2]).reshaped(1, 2)
        let incapable = KVCacheSimple()

        XCTAssertThrowsError(
            try verifyMTPPackedTargets(
                model: model,
                tokens: tokens,
                rowMaps: rowMaps,
                cache: [incapable])
        ) { error in
            XCTAssertEqual(error as? MTPPackedVerificationError, .unsupportedCache(cacheIndex: 0))
        }
        XCTAssertEqual(model.callCount, 0)
        XCTAssertEqual(incapable.offset, 0)

        XCTAssertThrowsError(
            try verifyMTPPackedTargets(
                model: model,
                tokens: tokens,
                rowMaps: rowMaps,
                cache: [])
        ) { error in
            XCTAssertEqual(error as? MTPPackedVerificationError, .emptyCache)
        }
        XCTAssertEqual(model.callCount, 0)
    }

    func testPinnedForkExposesMTPKVCacheTransactionSymbols() {
        let storageType: Any.Type = MTPKVCacheStorage.self
        let transactionType: Any.Type = MTPKVCacheTransaction.self
        let positionType: Any.Type = MTPKVCacheTransactionPosition.self
        let commitType: Any.Type = MTPKVCacheTransactionCommit.self
        let modeType: Any.Type = MTPKVCacheTransactionMode.self
        let errorType: Any.Type = MTPKVCacheTransactionError.self
        let packedCacheType: Any.Type = (any MTPPackedVerificationCache).self
        let packedRowMapType: Any.Type = MTPPackedVerificationRowMap.self
        let packedOutputType: Any.Type = MTPPackedVerificationOutput.self
        let packedErrorType: Any.Type = MTPPackedVerificationError.self

        XCTAssertNotNil(storageType)
        XCTAssertNotNil(transactionType)
        XCTAssertNotNil(positionType)
        XCTAssertNotNil(commitType)
        XCTAssertNotNil(modeType)
        XCTAssertNotNil(errorType)
        XCTAssertNotNil(packedCacheType)
        XCTAssertNotNil(packedRowMapType)
        XCTAssertNotNil(packedOutputType)
        XCTAssertNotNil(packedErrorType)
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

private let packedOutputStateKey = LMOutput.Key<Int>("tests.mtp.packed.output")

private final class PackedVerificationCache: MTPPackedVerificationCache {
    private(set) var preparedRowMaps: [MTPPackedVerificationRowMap]?
    private(set) var activeRowMaps: [MTPPackedVerificationRowMap]?
    private(set) var baseTokenColumns: [Int] = []
    private(set) var proposalColumnRanges: [Range<Int>] = []
    private(set) var stagedCommitCandidatePositions: [[Int]] = []
    private(set) var packedPrepareCallCount = 0
    private(set) var preparedLengths: [Int]?
    private(set) var activeLengths: [Int]?
    private(set) var prepareCallCount = 0
    private(set) var finalizeCallCount = 0
    var batchOffset: MLXArray
    var offset: Int { batchOffset.asArray(Int.self).max() ?? 0 }
    var maxSize: Int? { nil }
    var state: [MLXArray] = []
    var metaState: [String] = [""]
    var isTrimmable: Bool { false }

    init(offsets: [Int]) {
        self.batchOffset = MLXArray(offsets)
    }

    func innerState() -> [MLXArray] { [] }

    func update(keys: MLXArray, values: MLXArray) -> (MLXArray, MLXArray) {
        (keys, values)
    }

    func isTrimmable(after positions: Int) -> Bool { false }

    @discardableResult
    func trim(_ n: Int) -> Int { 0 }

    func makeMask(
        n: Int,
        windowSize: Int?,
        returnArray: Bool
    ) -> MLXFast.ScaledDotProductAttentionMaskMode {
        .none
    }

    func prepareMTPPackedVerification(rowMaps: [MTPPackedVerificationRowMap]) throws {
        packedPrepareCallCount += 1
        preparedRowMaps = rowMaps
        activeRowMaps = rowMaps
        baseTokenColumns = rowMaps.map { _ in 0 }
        proposalColumnRanges = rowMaps.map { 1 ..< $0.inputCount }
        stagedCommitCandidatePositions = rowMaps.map { map in
            (1 ..< map.inputCount).map { map.queryOffset + $0 }
        }
    }

    func prepare(lengths: [Int]?) {
        prepareCallCount += 1
        preparedLengths = lengths
        activeLengths = lengths
    }

    func finalize() {
        finalizeCallCount += 1
        activeLengths = nil
        activeRowMaps = nil
    }

    func copy() -> any KVCache {
        PackedVerificationCache(offsets: batchOffset.asArray(Int.self))
    }
}

private final class PackedVerificationModel: Module, LanguageModel, KVCacheDimensionProvider {
    var kvHeads: [Int] { [] }
    private(set) var callCount = 0
    private(set) var receivedTokens: [Int] = []
    private(set) var receivedMask: [Int] = []
    private(set) var receivedEmitFlag: Bool?
    private(set) var receivedOpaqueState: Int?
    private(set) var observedActiveLengths: [Int]?
    private(set) var observedActiveRowMaps: [MTPPackedVerificationRowMap]?

    func prepare(
        _ input: LMInput,
        cache: [KVCache],
        state: LMOutput.State?,
        prefill: PrefillParameters
    ) throws -> PrepareResult {
        .tokens(input.text)
    }

    func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
        MLXArray.zeros([inputs.dim(0), inputs.dim(1), 3])
    }

    func callAsFunction(
        _ input: LMInput.Text,
        cache: [KVCache]?,
        state: LMOutput.State?
    ) -> LMOutput {
        callCount += 1
        receivedTokens = input.tokens.asArray(Int.self)
        receivedMask = input.mask?.asArray(Int.self) ?? []
        receivedEmitFlag = state?[mtpEmitFlagKey]
        receivedOpaqueState = state?[packedOutputStateKey]
        observedActiveLengths = (cache?.first as? PackedVerificationCache)?.activeLengths
        observedActiveRowMaps = (cache?.first as? PackedVerificationCache)?.activeRowMaps

        let batchSize = input.tokens.dim(0)
        let width = input.tokens.dim(1)
        let vocabularySize = 3
        var logits = [Float]()
        logits.reserveCapacity(batchSize * width * vocabularySize)
        for row in 0 ..< batchSize {
            for column in 0 ..< width {
                for vocabularyIndex in 0 ..< vocabularySize {
                    logits.append(Float(row * 100 + column * 10 + vocabularyIndex))
                }
            }
        }

        let hidden = (0 ..< (batchSize * width * 2)).map { flatIndex in
            let row = flatIndex / (width * 2)
            let remainder = flatIndex % (width * 2)
            let column = remainder / 2
            let feature = remainder % 2
            return Float(row * 100 + column * 10 + feature)
        }
        var outputState = LMOutput.State()
        outputState[packedOutputStateKey] = 42
        outputState[mtpLastHiddenStatesKey] = MLXArray(hidden, [batchSize, width, 2])

        return LMOutput(
            logits: MLXArray(logits, [batchSize, width, vocabularySize]),
            state: outputState)
    }
}
