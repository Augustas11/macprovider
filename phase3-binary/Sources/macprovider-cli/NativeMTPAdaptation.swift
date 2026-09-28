import Foundation

enum NativeMTPAdaptationError: Error, Equatable {
    case invalidMaximumDepth
    case invalidThresholds
    case invalidCircuitBreakerMaximum
}

enum NativeMTPRuntimeFailureReason: String, Sendable, Equatable {
    case counterSaturation = "counter_saturation"
    case roundSpanExceeded = "round_span_exceeded"
}

struct NativeMTPAdaptationConfig: Sendable, Equatable {
    static let epochCommittedTokens: UInt64 = 32
    static let breakerRequestWindow: UInt64 = 64
    static let breakerCommittedTokenWindow: UInt64 = 1_024
    static let breakerCooldownRequests: UInt64 = 64
    static let maximumCircuitBreakerPositionsPerCommittedMilli: UInt64 = 4_000

    let qualifiedMaximumDepth: Int
    let decreaseThresholdPPM: UInt64
    let increaseThresholdPPM: UInt64
    let maxVerificationPositionsPerCommittedMilli: UInt64

    init(
        qualifiedMaximumDepth: Int,
        decreaseThresholdPPM: UInt64,
        increaseThresholdPPM: UInt64,
        maxVerificationPositionsPerCommittedMilli: UInt64
    ) throws {
        guard (0...16).contains(qualifiedMaximumDepth) else {
            throw NativeMTPAdaptationError.invalidMaximumDepth
        }
        guard decreaseThresholdPPM < increaseThresholdPPM,
              increaseThresholdPPM <= 1_000_000 else {
            throw NativeMTPAdaptationError.invalidThresholds
        }
        guard maxVerificationPositionsPerCommittedMilli
                <= Self.maximumCircuitBreakerPositionsPerCommittedMilli else {
            throw NativeMTPAdaptationError.invalidCircuitBreakerMaximum
        }

        self.qualifiedMaximumDepth = qualifiedMaximumDepth
        self.decreaseThresholdPPM = decreaseThresholdPPM
        self.increaseThresholdPPM = increaseThresholdPPM
        self.maxVerificationPositionsPerCommittedMilli = maxVerificationPositionsPerCommittedMilli
    }
}

struct NativeMTPAdaptationDirective: Sendable, Equatable {
    let generation: UInt64
    let forcedDepth: Int?
    let runtimeFailureReason: NativeMTPRuntimeFailureReason?
}

struct NativeMTPRoundWork: Sendable, Equatable {
    let acceptedProposalPrefixCount: UInt64
    let proposalCount: UInt64
    let committedTokenCount: UInt64
}

struct NativeMTPDepthAdaptationState: Sendable, Equatable {
    private let config: NativeMTPAdaptationConfig
    private(set) var currentDepth: Int
    private(set) var accepted: UInt64 = 0
    private(set) var proposed: UInt64 = 0
    private(set) var committedTokens: UInt64 = 0
    private(set) var runtimeFailureReason: NativeMTPRuntimeFailureReason?
    private(set) var observedDirectiveGeneration: UInt64 = 0
    private var lowEpochs: UInt8 = 0
    private var highEpochs: UInt8 = 0

    init(config: NativeMTPAdaptationConfig, initialDepth: Int? = nil) {
        self.config = config
        self.currentDepth = min(max(initialDepth ?? min(2, config.qualifiedMaximumDepth), 0), config.qualifiedMaximumDepth)
    }

    init(
        config: NativeMTPAdaptationConfig,
        initialDepth: Int? = nil,
        accepted: UInt64,
        proposed: UInt64,
        committedTokens: UInt64
    ) {
        self.config = config
        self.currentDepth = min(max(initialDepth ?? min(2, config.qualifiedMaximumDepth), 0), config.qualifiedMaximumDepth)
        self.accepted = accepted
        self.proposed = proposed
        self.committedTokens = min(committedTokens, NativeMTPAdaptationConfig.epochCommittedTokens - 1)
    }

    mutating func forceDepthZero() {
        currentDepth = 0
        accepted = 0
        proposed = 0
        committedTokens = 0
        lowEpochs = 0
        highEpochs = 0
    }

    mutating func resetAfterServedGenerationReload(initialDepth: Int? = nil) {
        runtimeFailureReason = nil
        observedDirectiveGeneration = 0
        currentDepth = min(max(initialDepth ?? min(2, config.qualifiedMaximumDepth), 0), config.qualifiedMaximumDepth)
        accepted = 0
        proposed = 0
        committedTokens = 0
        lowEpochs = 0
        highEpochs = 0
    }

    mutating func applyTupleDirective(_ directive: NativeMTPAdaptationDirective) {
        guard directive.generation > observedDirectiveGeneration else { return }
        observedDirectiveGeneration = directive.generation
        if let failure = directive.runtimeFailureReason {
            failClosed(failure)
            return
        }
        if let forcedDepth = directive.forcedDepth {
            currentDepth = min(max(forcedDepth, 0), config.qualifiedMaximumDepth)
            accepted = 0
            proposed = 0
            committedTokens = 0
            lowEpochs = 0
            highEpochs = 0
        }
    }

    mutating func recordCommittedTokens(
        accepted acceptedDelta: UInt64,
        proposed proposedDelta: UInt64,
        committed committedDelta: UInt64
    ) {
        recordRound(
            NativeMTPRoundWork(
                acceptedProposalPrefixCount: acceptedDelta,
                proposalCount: proposedDelta,
                committedTokenCount: committedDelta
            )
        )
    }

    mutating func recordRound(_ round: NativeMTPRoundWork) {
        guard runtimeFailureReason == nil else { return }
        guard isBoundedRound(round) else {
            failClosed(.roundSpanExceeded)
            return
        }

        var remainingCommitted = round.committedTokenCount
        var remainingAccepted = min(round.acceptedProposalPrefixCount, round.committedTokenCount)
        var remainingProposed = round.proposalCount

        if remainingCommitted == 0 {
            addToEpoch(accepted: remainingAccepted, proposed: remainingProposed, committed: 0)
            return
        }

        while remainingCommitted > 0, runtimeFailureReason == nil {
            let capacity = NativeMTPAdaptationConfig.epochCommittedTokens - committedTokens
            let chunkCommitted = min(remainingCommitted, capacity)
            let chunkAccepted = min(remainingAccepted, chunkCommitted)
            let chunkProposed: UInt64
            if chunkCommitted == remainingCommitted {
                chunkProposed = remainingProposed
            } else {
                chunkProposed = min(remainingProposed, chunkCommitted)
            }

            addToEpoch(accepted: chunkAccepted, proposed: chunkProposed, committed: chunkCommitted)

            remainingCommitted -= chunkCommitted
            remainingAccepted -= chunkAccepted
            remainingProposed -= chunkProposed

            if committedTokens >= NativeMTPAdaptationConfig.epochCommittedTokens {
                evaluateEpoch()
            }
        }
    }

    private func isBoundedRound(_ round: NativeMTPRoundWork) -> Bool {
        let maximumProposal = UInt64(config.qualifiedMaximumDepth)
        let maximumCommitted = maximumProposal + 1
        return round.proposalCount <= maximumProposal
            && round.acceptedProposalPrefixCount <= round.proposalCount
            && round.committedTokenCount <= maximumCommitted
    }

    private mutating func addToEpoch(accepted acceptedDelta: UInt64, proposed proposedDelta: UInt64, committed committedDelta: UInt64) {
        let acceptedAdd = Self.adding(accepted, acceptedDelta)
        let proposedAdd = Self.adding(proposed, proposedDelta)
        let committedAdd = Self.adding(committedTokens, committedDelta)
        guard !acceptedAdd.saturated, !proposedAdd.saturated, !committedAdd.saturated else {
            failClosed(.counterSaturation)
            return
        }
        accepted = acceptedAdd.value
        proposed = proposedAdd.value
        committedTokens = committedAdd.value
    }

    private mutating func evaluateEpoch() {
        let epochAccepted = accepted
        let epochProposed = proposed
        let depthAtEpochClose = currentDepth
        accepted = 0
        proposed = 0
        committedTokens = 0

        if depthAtEpochClose == 0 {
            currentDepth = min(1, config.qualifiedMaximumDepth)
            lowEpochs = 0
            highEpochs = 0
            return
        }

        guard epochProposed > 0 else {
            lowEpochs = 0
            highEpochs = 0
            return
        }

        let acceptancePPM = Self.scaledRatio(
            numerator: min(epochAccepted, epochProposed),
            denominator: epochProposed,
            scale: 1_000_000
        )
        if acceptancePPM < config.decreaseThresholdPPM {
            lowEpochs = min(lowEpochs + 1, 2)
            highEpochs = 0
            if lowEpochs >= 2 {
                currentDepth = max(0, currentDepth - 1)
                lowEpochs = 0
            }
        } else if acceptancePPM > config.increaseThresholdPPM {
            highEpochs = min(highEpochs + 1, 2)
            lowEpochs = 0
            if highEpochs >= 2 {
                currentDepth = min(config.qualifiedMaximumDepth, currentDepth + 1)
                highEpochs = 0
            }
        } else {
            lowEpochs = 0
            highEpochs = 0
        }
    }

    private mutating func failClosed(_ reason: NativeMTPRuntimeFailureReason) {
        runtimeFailureReason = reason
        forceDepthZero()
    }

    static func adding(_ lhs: UInt64, _ rhs: UInt64) -> (value: UInt64, saturated: Bool) {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? (UInt64.max, true) : (sum, false)
    }

    static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        adding(lhs, rhs).value
    }

    static func scaledRatio(numerator: UInt64, denominator: UInt64, scale: UInt64) -> UInt64 {
        guard denominator > 0 else { return 0 }
        let product = numerator.multipliedFullWidth(by: scale)
        guard product.high < denominator else { return UInt64.max }
        return denominator.dividingFullWidth(product).quotient
    }
}

enum NativeMTPCircuitBreakerStatus: Sendable, Equatable {
    case healthy
    case cooldown(remainingEligibleRequests: UInt64)
    case disabled
}

struct NativeMTPCircuitBreakerWindow: Sendable, Equatable {
    let eligibleRequests: UInt64
    let committedTokens: UInt64
    let accepted: UInt64
    let proposed: UInt64
    let packedTargetVerificationPositions: UInt64
}

struct NativeMTPCircuitBreakerSample: Sendable, Equatable {
    let committedTokens: UInt64
    let accepted: UInt64
    let proposed: UInt64
    let packedTargetVerificationPositions: UInt64
}

struct NativeMTPTupleCircuitBreakerState: Sendable, Equatable {
    private let config: NativeMTPAdaptationConfig
    private(set) var status: NativeMTPCircuitBreakerStatus = .healthy
    private(set) var currentDepth: Int
    private(set) var directive = NativeMTPAdaptationDirective(
        generation: 0,
        forcedDepth: nil,
        runtimeFailureReason: nil
    )
    private(set) var runtimeFailureReason: NativeMTPRuntimeFailureReason?
    private(set) var window = NativeMTPCircuitBreakerWindow(
        eligibleRequests: 0,
        committedTokens: 0,
        accepted: 0,
        proposed: 0,
        packedTargetVerificationPositions: 0
    )
    private var samples: [NativeMTPCircuitBreakerSample] = []
    private var violatingWindows: UInt8 = 0

    init(config: NativeMTPAdaptationConfig, initialDepth: Int? = nil) {
        self.config = config
        self.currentDepth = min(max(initialDepth ?? min(2, config.qualifiedMaximumDepth), 0), config.qualifiedMaximumDepth)
    }

    var requestInitialDepth: Int {
        switch status {
        case .healthy:
            return min(2, config.qualifiedMaximumDepth, currentDepth)
        case .cooldown, .disabled:
            return 0
        }
    }

    mutating func reloadAfterFreshSelfTest(initialDepth: Int? = nil) {
        status = .healthy
        currentDepth = min(max(initialDepth ?? min(2, config.qualifiedMaximumDepth), 0), config.qualifiedMaximumDepth)
        runtimeFailureReason = nil
        violatingWindows = 0
        samples.removeAll(keepingCapacity: true)
        refreshWindow()
        publishDirective(forcedDepth: nil, runtimeFailureReason: nil)
    }

    mutating func recordEligibleRequest(
        committedTokens committedDelta: UInt64,
        accepted acceptedDelta: UInt64,
        proposed proposedDelta: UInt64,
        packedTargetVerificationPositions verificationDelta: UInt64
    ) {
        guard status != .disabled else { return }

        if case .cooldown(let remaining) = status {
            let nextRemaining = remaining > 0 ? remaining - 1 : 0
            if nextRemaining == 0 {
                status = .healthy
                currentDepth = min(1, config.qualifiedMaximumDepth)
                publishDirective(forcedDepth: currentDepth, runtimeFailureReason: nil)
            } else {
                status = .cooldown(remainingEligibleRequests: nextRemaining)
                currentDepth = 0
            }
            return
        }

        appendSample(Self.boundedSample(
            committedTokens: committedDelta,
            accepted: acceptedDelta,
            proposed: proposedDelta,
            packedTargetVerificationPositions: verificationDelta
        ))
        guard runtimeFailureReason == nil else { return }
        if window.eligibleRequests >= NativeMTPAdaptationConfig.breakerRequestWindow
            || window.committedTokens >= NativeMTPAdaptationConfig.breakerCommittedTokenWindow {
            evaluateClosedWindow()
        }
    }

    private mutating func appendSample(_ sample: NativeMTPCircuitBreakerSample) {
        samples.append(sample)
        refreshWindow()
        guard runtimeFailureReason == nil else { return }

        while samples.count > NativeMTPAdaptationConfig.breakerRequestWindow {
            samples.removeFirst()
            refreshWindow()
            guard runtimeFailureReason == nil else { return }
        }
        while window.committedTokens > NativeMTPAdaptationConfig.breakerCommittedTokenWindow, samples.count > 1 {
            samples.removeFirst()
            refreshWindow()
            guard runtimeFailureReason == nil else { return }
        }
    }

    private mutating func refreshWindow() {
        var next = NativeMTPCircuitBreakerWindow(
            eligibleRequests: 0,
            committedTokens: 0,
            accepted: 0,
            proposed: 0,
            packedTargetVerificationPositions: 0
        )
        for sample in samples {
            guard add(sample, into: &next) else {
                failClosed(.counterSaturation)
                return
            }
        }
        window = next
    }

    private func add(_ sample: NativeMTPCircuitBreakerSample, into window: inout NativeMTPCircuitBreakerWindow) -> Bool {
        let requestCount = NativeMTPDepthAdaptationState.adding(window.eligibleRequests, 1)
        let committed = NativeMTPDepthAdaptationState.adding(window.committedTokens, sample.committedTokens)
        let accepted = NativeMTPDepthAdaptationState.adding(window.accepted, sample.accepted)
        let proposed = NativeMTPDepthAdaptationState.adding(window.proposed, sample.proposed)
        let positions = NativeMTPDepthAdaptationState.adding(
            window.packedTargetVerificationPositions,
            sample.packedTargetVerificationPositions
        )
        guard !requestCount.saturated,
              !committed.saturated,
              !accepted.saturated,
              !proposed.saturated,
              !positions.saturated else {
            return false
        }
        window = NativeMTPCircuitBreakerWindow(
            eligibleRequests: requestCount.value,
            committedTokens: committed.value,
            accepted: accepted.value,
            proposed: proposed.value,
            packedTargetVerificationPositions: positions.value
        )
        return true
    }

    private static func boundedSample(
        committedTokens: UInt64,
        accepted: UInt64,
        proposed: UInt64,
        packedTargetVerificationPositions: UInt64
    ) -> NativeMTPCircuitBreakerSample {
        let limit = NativeMTPAdaptationConfig.breakerCommittedTokenWindow
        guard committedTokens > limit else {
            return NativeMTPCircuitBreakerSample(
                committedTokens: committedTokens,
                accepted: accepted,
                proposed: proposed,
                packedTargetVerificationPositions: packedTargetVerificationPositions
            )
        }
        return NativeMTPCircuitBreakerSample(
            committedTokens: limit,
            accepted: NativeMTPDepthAdaptationState.scaledRatio(
                numerator: accepted,
                denominator: committedTokens,
                scale: limit
            ),
            proposed: NativeMTPDepthAdaptationState.scaledRatio(
                numerator: proposed,
                denominator: committedTokens,
                scale: limit
            ),
            packedTargetVerificationPositions: NativeMTPDepthAdaptationState.scaledRatio(
                numerator: packedTargetVerificationPositions,
                denominator: committedTokens,
                scale: limit
            )
        )
    }

    private mutating func evaluateClosedWindow() {
        let verificationMilli = NativeMTPDepthAdaptationState.scaledRatio(
            numerator: window.packedTargetVerificationPositions,
            denominator: max(1, window.committedTokens),
            scale: 1_000
        )
        let acceptanceViolates: Bool
        if window.proposed == 0 {
            acceptanceViolates = false
        } else {
            let acceptancePPM = NativeMTPDepthAdaptationState.scaledRatio(
                numerator: min(window.accepted, window.proposed),
                denominator: window.proposed,
                scale: 1_000_000
            )
            acceptanceViolates = acceptancePPM < config.decreaseThresholdPPM
        }
        let violates = verificationMilli > config.maxVerificationPositionsPerCommittedMilli || acceptanceViolates

        if violates {
            violatingWindows = min(violatingWindows + 1, 2)
            if violatingWindows >= 2 {
                failClosed(nil)
            } else {
                status = .cooldown(remainingEligibleRequests: NativeMTPAdaptationConfig.breakerCooldownRequests)
                currentDepth = 0
                samples.removeAll(keepingCapacity: true)
                refreshWindow()
                publishDirective(forcedDepth: 0, runtimeFailureReason: nil)
            }
        } else {
            violatingWindows = 0
            status = .healthy
        }
    }

    private mutating func failClosed(_ reason: NativeMTPRuntimeFailureReason?) {
        runtimeFailureReason = reason
        status = .disabled
        currentDepth = 0
        samples.removeAll(keepingCapacity: true)
        window = NativeMTPCircuitBreakerWindow(
            eligibleRequests: 0,
            committedTokens: 0,
            accepted: 0,
            proposed: 0,
            packedTargetVerificationPositions: 0
        )
        publishDirective(forcedDepth: 0, runtimeFailureReason: reason)
    }

    private mutating func publishDirective(forcedDepth: Int?, runtimeFailureReason: NativeMTPRuntimeFailureReason?) {
        let generation = NativeMTPDepthAdaptationState.adding(directive.generation, 1)
        if generation.saturated {
            directive = NativeMTPAdaptationDirective(
                generation: UInt64.max,
                forcedDepth: 0,
                runtimeFailureReason: .counterSaturation
            )
            status = .disabled
            currentDepth = 0
            self.runtimeFailureReason = .counterSaturation
            return
        }
        directive = NativeMTPAdaptationDirective(
            generation: generation.value,
            forcedDepth: forcedDepth,
            runtimeFailureReason: runtimeFailureReason
        )
    }
}
