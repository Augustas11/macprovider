import XCTest
@testable import macprovider_cli

final class NativeMTPAdaptationTests: XCTestCase {
    func testDepthAdaptationPreservesOvershootAcrossThirtyTwoTokenBoundary() throws {
        let config = try makeConfig(maxDepth: 4)
        var state = NativeMTPDepthAdaptationState(config: config, initialDepth: 2)

        recordRounds(&state, count: 31, accepted: 0, proposed: 1, committed: 1)
        XCTAssertEqual(state.currentDepth, 2)
        XCTAssertEqual(state.committedTokens, 31)

        state.recordRound(
            NativeMTPRoundWork(
                acceptedProposalPrefixCount: 0,
                proposalCount: 2,
                committedTokenCount: 2
            )
        )
        XCTAssertEqual(state.currentDepth, 2)
        XCTAssertEqual(state.committedTokens, 1)
        XCTAssertEqual(state.proposed, 1)

        recordRounds(&state, count: 31, accepted: 0, proposed: 1, committed: 1)
        XCTAssertEqual(state.currentDepth, 1)
        XCTAssertEqual(state.committedTokens, 0)
    }

    func testDepthAdaptationHandlesMultipleBoundaryCrossingsWithBoundedRounds() throws {
        let config = try makeConfig(maxDepth: 4)
        var state = NativeMTPDepthAdaptationState(config: config, initialDepth: 1)

        for _ in 0..<13 {
            state.recordRound(
                NativeMTPRoundWork(
                    acceptedProposalPrefixCount: 0,
                    proposalCount: 4,
                    committedTokenCount: 5
                )
            )
        }

        XCTAssertEqual(state.currentDepth, 0)
        XCTAssertEqual(state.committedTokens, 1)
        XCTAssertNil(state.runtimeFailureReason)
    }

    func testRoundSpanExceededFailsRowClosed() throws {
        let config = try makeConfig(maxDepth: 4)
        var state = NativeMTPDepthAdaptationState(config: config, initialDepth: 2)

        state.recordRound(
            NativeMTPRoundWork(
                acceptedProposalPrefixCount: 0,
                proposalCount: 4,
                committedTokenCount: 6
            )
        )

        XCTAssertEqual(state.currentDepth, 0)
        XCTAssertEqual(state.runtimeFailureReason, .roundSpanExceeded)
        state.recordCommittedTokens(accepted: 4, proposed: 4, committed: 5)
        XCTAssertEqual(state.currentDepth, 0)
    }

    func testDepthAdaptationRequiresTwoSuccessiveLowOrHighEpochs() throws {
        let config = try makeConfig(maxDepth: 3)
        var state = NativeMTPDepthAdaptationState(config: config, initialDepth: 1)

        recordRounds(&state, count: 32, accepted: 0, proposed: 1, committed: 1)
        XCTAssertEqual(state.currentDepth, 1)
        recordRounds(&state, count: 32, accepted: 0, proposed: 1, committed: 1)
        XCTAssertEqual(state.currentDepth, 0)

        recordRounds(&state, count: 32, accepted: 0, proposed: 0, committed: 1)
        XCTAssertEqual(state.currentDepth, 1)

        recordRounds(&state, count: 32, accepted: 1, proposed: 1, committed: 1)
        XCTAssertEqual(state.currentDepth, 1)
        recordRounds(&state, count: 32, accepted: 1, proposed: 1, committed: 1)
        XCTAssertEqual(state.currentDepth, 2)
    }

    func testDepthAdaptationResetsStreaksAndHonorsMaximumBounds() throws {
        let config = try makeConfig(maxDepth: 2)
        var state = NativeMTPDepthAdaptationState(config: config, initialDepth: 2)

        recordRounds(&state, count: 32, accepted: 1, proposed: 1, committed: 1)
        recordRounds(&state, count: 32, accepted: 1, proposed: 1, committed: 1)
        XCTAssertEqual(state.currentDepth, 2)

        recordRounds(&state, count: 32, accepted: 0, proposed: 1, committed: 1)
        recordRounds(&state, count: 32, accepted: 1, proposed: 2, committed: 1)
        recordRounds(&state, count: 32, accepted: 0, proposed: 1, committed: 1)
        XCTAssertEqual(state.currentDepth, 2)
    }

    func testDepthZeroCooldownRetriesAtOneAfterOneEpoch() throws {
        let config = try makeConfig(maxDepth: 4)
        var state = NativeMTPDepthAdaptationState(config: config, initialDepth: 2)

        state.forceDepthZero()
        XCTAssertEqual(state.currentDepth, 0)
        recordRounds(&state, count: 31, accepted: 0, proposed: 0, committed: 1)
        XCTAssertEqual(state.currentDepth, 0)
        recordRounds(&state, count: 1, accepted: 0, proposed: 0, committed: 1)
        XCTAssertEqual(state.currentDepth, 1)
    }

    func testRowCounterSaturationFailsClosedUntilServedGenerationReset() throws {
        let config = try makeConfig(maxDepth: 4)
        var state = NativeMTPDepthAdaptationState(
            config: config,
            initialDepth: 2,
            accepted: UInt64.max,
            proposed: 0,
            committedTokens: 31
        )

        state.recordRound(
            NativeMTPRoundWork(
                acceptedProposalPrefixCount: 1,
                proposalCount: 1,
                committedTokenCount: 1
            )
        )
        XCTAssertEqual(state.runtimeFailureReason, .counterSaturation)
        XCTAssertEqual(state.currentDepth, 0)

        state.resetAfterServedGenerationReload(initialDepth: 2)
        XCTAssertNil(state.runtimeFailureReason)
        XCTAssertEqual(state.currentDepth, 2)
    }

    func testScaledRatioClampsInsteadOfTrappingOnHugeProduct() {
        XCTAssertEqual(
            NativeMTPDepthAdaptationState.scaledRatio(
                numerator: UInt64.max,
                denominator: 1,
                scale: 1_000_000
            ),
            UInt64.max
        )
    }

    func testAdaptationConfigFailsClosedForInvalidBounds() {
        XCTAssertThrowsError(
            try NativeMTPAdaptationConfig(
                qualifiedMaximumDepth: 17,
                decreaseThresholdPPM: 300_000,
                increaseThresholdPPM: 700_000,
                maxVerificationPositionsPerCommittedMilli: 4_000
            )
        ) { XCTAssertEqual($0 as? NativeMTPAdaptationError, .invalidMaximumDepth) }
        XCTAssertThrowsError(
            try NativeMTPAdaptationConfig(
                qualifiedMaximumDepth: 4,
                decreaseThresholdPPM: 700_000,
                increaseThresholdPPM: 300_000,
                maxVerificationPositionsPerCommittedMilli: 4_000
            )
        ) { XCTAssertEqual($0 as? NativeMTPAdaptationError, .invalidThresholds) }
        XCTAssertThrowsError(
            try NativeMTPAdaptationConfig(
                qualifiedMaximumDepth: 4,
                decreaseThresholdPPM: 300_000,
                increaseThresholdPPM: 700_000,
                maxVerificationPositionsPerCommittedMilli: 4_001
            )
        ) { XCTAssertEqual($0 as? NativeMTPAdaptationError, .invalidCircuitBreakerMaximum) }
    }

    func testCircuitBreakerNewRequestsStartAtTupleDepthBoundedByTwoAndMaximum() throws {
        var state = NativeMTPTupleCircuitBreakerState(config: try makeConfig(maxDepth: 8), initialDepth: 6)
        XCTAssertEqual(state.requestInitialDepth, 2)

        state = NativeMTPTupleCircuitBreakerState(config: try makeConfig(maxDepth: 1), initialDepth: 1)
        XCTAssertEqual(state.requestInitialDepth, 1)
    }

    func testCircuitBreakerClosesAtSixtyFourShortEligibleRequestsAndCoolsDownExactly() throws {
        let config = try makeConfig(maxDepth: 4, maxVerificationMilli: 1_000)
        var state = NativeMTPTupleCircuitBreakerState(config: config, initialDepth: 2)

        for _ in 0..<63 {
            state.recordEligibleRequest(
                committedTokens: 1,
                accepted: 1,
                proposed: 1,
                packedTargetVerificationPositions: 2
            )
        }
        XCTAssertEqual(state.status, .healthy)
        XCTAssertEqual(state.requestInitialDepth, 2)

        state.recordEligibleRequest(
            committedTokens: 1,
            accepted: 1,
            proposed: 1,
            packedTargetVerificationPositions: 2
        )
        XCTAssertEqual(state.status, .cooldown(remainingEligibleRequests: 64))
        XCTAssertEqual(state.requestInitialDepth, 0)
        XCTAssertEqual(state.directive.forcedDepth, 0)

        for remaining in stride(from: UInt64(63), through: 1, by: -1) {
            state.recordEligibleRequest(
                committedTokens: 1,
                accepted: 1,
                proposed: 1,
                packedTargetVerificationPositions: 0
            )
            XCTAssertEqual(state.status, .cooldown(remainingEligibleRequests: remaining))
        }

        state.recordEligibleRequest(
            committedTokens: 1,
            accepted: 1,
            proposed: 1,
            packedTargetVerificationPositions: 0
        )
        XCTAssertEqual(state.status, .healthy)
        XCTAssertEqual(state.requestInitialDepth, 1)
    }

    func testCircuitBreakerClosesAtTokenWindowAndDisablesAfterSecondViolatingWindow() throws {
        let config = try makeConfig(maxDepth: 4, maxVerificationMilli: 4_000)
        var state = NativeMTPTupleCircuitBreakerState(config: config, initialDepth: 2)

        state.recordEligibleRequest(
            committedTokens: 1_024,
            accepted: 1,
            proposed: 10,
            packedTargetVerificationPositions: 0
        )
        XCTAssertEqual(state.status, .cooldown(remainingEligibleRequests: 64))

        for _ in 0..<64 {
            state.recordEligibleRequest(
                committedTokens: 1,
                accepted: 1,
                proposed: 1,
                packedTargetVerificationPositions: 0
            )
        }
        XCTAssertEqual(state.status, .healthy)

        state.recordEligibleRequest(
            committedTokens: 1_024,
            accepted: 1,
            proposed: 10,
            packedTargetVerificationPositions: 0
        )
        XCTAssertEqual(state.status, .disabled)
        XCTAssertEqual(state.requestInitialDepth, 0)

        state.recordEligibleRequest(
            committedTokens: 1_024,
            accepted: 10,
            proposed: 10,
            packedTargetVerificationPositions: 0
        )
        XCTAssertEqual(state.status, .disabled)
    }

    func testCircuitBreakerCleanWindowClearsViolationStreak() throws {
        let config = try makeConfig(maxDepth: 4, maxVerificationMilli: 1_000)
        var state = NativeMTPTupleCircuitBreakerState(config: config, initialDepth: 2)

        for _ in 0..<64 {
            state.recordEligibleRequest(
                committedTokens: 1,
                accepted: 1,
                proposed: 1,
                packedTargetVerificationPositions: 2
            )
        }
        XCTAssertEqual(state.status, .cooldown(remainingEligibleRequests: 64))

        for _ in 0..<64 {
            state.recordEligibleRequest(
                committedTokens: 1,
                accepted: 1,
                proposed: 1,
                packedTargetVerificationPositions: 0
            )
        }
        XCTAssertEqual(state.status, .healthy)

        for _ in 0..<64 {
            state.recordEligibleRequest(
                committedTokens: 16,
                accepted: 16,
                proposed: 16,
                packedTargetVerificationPositions: 0
            )
        }
        XCTAssertEqual(state.status, .healthy)

        for _ in 0..<60 {
            state.recordEligibleRequest(
                committedTokens: 1,
                accepted: 1,
                proposed: 1,
                packedTargetVerificationPositions: 2
            )
        }
        XCTAssertEqual(state.status, .healthy)

        state.recordEligibleRequest(
            committedTokens: 1,
            accepted: 1,
            proposed: 1,
            packedTargetVerificationPositions: 2
        )
        XCTAssertEqual(state.status, .cooldown(remainingEligibleRequests: 64))
    }

    func testCircuitBreakerMaintainsRollingSuffixAfterNonViolatingClose() throws {
        let config = try makeConfig(maxDepth: 4, maxVerificationMilli: 4_000)
        var state = NativeMTPTupleCircuitBreakerState(config: config, initialDepth: 2)

        for _ in 0..<64 {
            state.recordEligibleRequest(
                committedTokens: 16,
                accepted: 16,
                proposed: 16,
                packedTargetVerificationPositions: 0
            )
        }
        XCTAssertEqual(state.status, .healthy)
        XCTAssertEqual(state.window.eligibleRequests, 64)
        XCTAssertEqual(state.window.committedTokens, 1_024)

        state.recordEligibleRequest(
            committedTokens: 16,
            accepted: 16,
            proposed: 16,
            packedTargetVerificationPositions: 0
        )
        XCTAssertEqual(state.status, .healthy)
        XCTAssertEqual(state.window.eligibleRequests, 64)
        XCTAssertEqual(state.window.committedTokens, 1_024)
        XCTAssertEqual(state.window.accepted, 1_024)
        XCTAssertEqual(state.window.proposed, 1_024)
    }

    func testCircuitBreakerNormalizesSingleOversizedSampleIntoBoundedSuffix() throws {
        let config = try makeConfig(maxDepth: 4, maxVerificationMilli: 4_000)
        var state = NativeMTPTupleCircuitBreakerState(config: config, initialDepth: 2)

        state.recordEligibleRequest(
            committedTokens: 2_048,
            accepted: 1_024,
            proposed: 2_048,
            packedTargetVerificationPositions: 4_096
        )

        XCTAssertEqual(state.status, .healthy)
        XCTAssertEqual(state.window.eligibleRequests, 1)
        XCTAssertEqual(state.window.committedTokens, 1_024)
        XCTAssertEqual(state.window.accepted, 512)
        XCTAssertEqual(state.window.proposed, 1_024)
        XCTAssertEqual(state.window.packedTargetVerificationPositions, 2_048)
    }

    func testCircuitBreakerDirectiveForcesActiveRowsToDepthZero() throws {
        let config = try makeConfig(maxDepth: 4, maxVerificationMilli: 1_000)
        var breaker = NativeMTPTupleCircuitBreakerState(config: config, initialDepth: 2)
        var row = NativeMTPDepthAdaptationState(config: config, initialDepth: 2)

        for _ in 0..<64 {
            breaker.recordEligibleRequest(
                committedTokens: 1,
                accepted: 1,
                proposed: 1,
                packedTargetVerificationPositions: 2
            )
        }

        row.applyTupleDirective(breaker.directive)
        XCTAssertEqual(row.currentDepth, 0)
        XCTAssertEqual(row.observedDirectiveGeneration, breaker.directive.generation)
    }

    func testTupleCounterSaturationDisablesTupleAndPublishesRuntimeFailureDirective() throws {
        let config = try makeConfig(maxDepth: 4)
        var breaker = NativeMTPTupleCircuitBreakerState(config: config, initialDepth: 2)
        var row = NativeMTPDepthAdaptationState(config: config, initialDepth: 2)

        breaker.recordEligibleRequest(
            committedTokens: 0,
            accepted: UInt64.max,
            proposed: 0,
            packedTargetVerificationPositions: 0
        )
        breaker.recordEligibleRequest(
            committedTokens: 0,
            accepted: 1,
            proposed: 0,
            packedTargetVerificationPositions: 0
        )

        XCTAssertEqual(breaker.status, .disabled)
        XCTAssertEqual(breaker.runtimeFailureReason, .counterSaturation)
        XCTAssertEqual(breaker.directive.runtimeFailureReason, .counterSaturation)

        row.applyTupleDirective(breaker.directive)
        XCTAssertEqual(row.currentDepth, 0)
        XCTAssertEqual(row.runtimeFailureReason, .counterSaturation)
    }

    private func makeConfig(
        maxDepth: Int,
        maxVerificationMilli: UInt64 = 4_000
    ) throws -> NativeMTPAdaptationConfig {
        try NativeMTPAdaptationConfig(
            qualifiedMaximumDepth: maxDepth,
            decreaseThresholdPPM: 300_000,
            increaseThresholdPPM: 700_000,
            maxVerificationPositionsPerCommittedMilli: maxVerificationMilli
        )
    }

    private func recordRounds(
        _ state: inout NativeMTPDepthAdaptationState,
        count: Int,
        accepted: UInt64,
        proposed: UInt64,
        committed: UInt64
    ) {
        for _ in 0..<count {
            state.recordRound(
                NativeMTPRoundWork(
                    acceptedProposalPrefixCount: accepted,
                    proposalCount: proposed,
                    committedTokenCount: committed
                )
            )
        }
    }
}
