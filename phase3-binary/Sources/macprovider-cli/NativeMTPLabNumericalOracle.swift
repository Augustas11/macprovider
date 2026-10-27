import Foundation

/// One ordinary/native request pair. Full vectors survive only until the
/// comparison finishes; native stop-held tokens retain compact results only.
final class NativeMTPLabNumericalOracle: @unchecked Sendable {
    enum Role: Equatable, Sendable { case ordinary, native }
    enum Terminal: String, Equatable, Sendable {
        case eos, stopSequence, maxTokens, toolBoundary, other

        static func classify(
            status: ContinuousBatchSchedulerTerminalStatus,
            stopCause: ContinuousBatchSchedulerStopCause?, toolBoundaryTokenCount: Int?
        ) -> Terminal {
            guard status == .stop || status == .length else { return .other }
            // The canonical parser boundary is the final response boundary,
            // even if a later sampled token also hit an explicit stop or cap.
            if toolBoundaryTokenCount != nil { return .toolBoundary }
            switch stopCause {
            case .modelStop: return .eos
            case .requestStop: return .stopSequence
            case nil: return status == .length ? .maxTokens : .other
            }
        }
    }
    struct Binding: Sendable {
        let oracle: NativeMTPLabNumericalOracle
        let role: Role
    }
    enum ConfigurationError: Error { case invalidPositionLimit }
    struct Failure: Equatable, Sendable {
        let position: Int?
        let reason: String
    }
    struct Position: Equatable, Sendable {
        let position: Int
        let ordinaryToken: Int
        let nativeToken: Int
        let tokenExact: Bool
        let top1Exact: Bool
        let finite: Bool
        let maxAbsDifference: Float?
        let ordinaryTop1: Int?
        let nativeTop1: Int?
        let ordinaryGap: Float?
        let nativeGap: Float?
        var passed: Bool {
            tokenExact && top1Exact && finite && maxAbsDifference.map { $0 <= 0.05 } == true
        }
    }
    struct Summary: Sendable {
        let requestID: String?
        let positions: [Position]
        let selectedPositions: [Position]
        let ordinarySelectedCount: Int
        let nativeSelectedCount: Int
        let firstFailure: Failure?
        let ordinaryFinished: Bool
        let nativeFinished: Bool
        let ordinaryTerminal: Terminal?
        let nativeTerminal: Terminal?
        let retainedVectors: Int
        var passed: Bool {
            ordinaryFinished && nativeFinished && firstFailure == nil && !selectedPositions.isEmpty
                && selectedPositions.allSatisfy(\.passed)
        }
    }
    private struct Vector {
        let token: Int
        let logits: [Float]
    }
    private struct PendingComparison {
        let sampledToken: Int
        let position: Position?
        let error: String?
    }
    private let lock = NSLock()
    private var requestID: String?
    private var limit = 0
    private var ordinaryPending: [Int: Vector] = [:]
    private var references: [Int: Vector] = [:]
    private var nativeRound: [Int: Vector] = [:]
    private var nativeReady: [Int: PendingComparison] = [:]
    private var ordinaryCount = 0
    private var nativeCount = 0
    private var ordinarySelectedCount = 0
    private var nativeSelectedCount = 0
    private var ordinarySelectedTokens: [Int: Int] = [:]
    private var nativeSelectedTokens: [Int: Int] = [:]
    private var ordinaryFinished = false
    private var nativeFinished = false
    private var ordinaryTerminal: Terminal?
    private var nativeTerminal: Terminal?
    private var positions: [Position] = []
    private var selectedPositions: [Position] = []
    private var firstFailure: Failure?

    func beginPair(requestID: String, maxPositions: Int = 40) throws {
        guard (1 ... 256).contains(maxPositions) else { throw ConfigurationError.invalidPositionLimit }
        lock.lock()
        defer { lock.unlock() }
        self.requestID = requestID
        limit = maxPositions
        ordinaryPending.removeAll()
        references.removeAll()
        nativeRound.removeAll()
        nativeReady.removeAll()
        ordinaryCount = 0
        nativeCount = 0
        ordinarySelectedCount = 0
        nativeSelectedCount = 0
        ordinarySelectedTokens.removeAll()
        nativeSelectedTokens.removeAll()
        ordinaryFinished = false
        nativeFinished = false
        ordinaryTerminal = nil
        nativeTerminal = nil
        positions.removeAll()
        selectedPositions.removeAll()
        firstFailure = nil
    }

    func wantsCapture(requestID: String, position: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return self.requestID == requestID && firstFailure == nil && (0 ..< limit).contains(position)
    }

    /// Called only after the production sampler selected this token. Native
    /// verify vectors remain tentative until the ordinary acceptance walk ends.
    func capture(
        role: Role, requestID: String, position: Int, tokenID: Int, logits: [Float],
        speculative: Bool = false
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard self.requestID == requestID, firstFailure == nil, (0 ..< limit).contains(position) else { return }
        let vector = Vector(token: tokenID, logits: logits)
        switch role {
        case .ordinary:
            guard ordinaryPending[position] == nil, references[position] == nil else {
                fail(position, "duplicate_ordinary_position")
                return
            }
            ordinaryPending[position] = vector
        case .native:
            guard nativeRound[position] == nil, nativeReady[position] == nil, position >= nativeSelectedCount else {
                fail(position, "duplicate_native_position")
                return
            }
            if speculative {
                // Current supported verify blocks are at most eight columns.
                guard nativeRound.count < 8 else {
                    fail(position, "native_block_capacity")
                    return
                }
                nativeRound[position] = vector
            } else {
                nativeReady[position] = compare(vector, position: position)
            }
        }
    }

    /// A nil prefix aborts the round. A successful prefix includes the first
    /// mismatch's target replacement, or the bonus after complete acceptance.
    func resolveNativeRound(requestID: String, acceptedTokenIDs: [Int]?) {
        lock.lock()
        defer { lock.unlock() }
        guard self.requestID == requestID else { return }
        defer { nativeRound.removeAll() }
        guard firstFailure == nil, let acceptedTokenIDs else { return }
        guard let start = nativeRound.keys.min() else { return }
        for (offset, token) in acceptedTokenIDs.enumerated() {
            let position = start + offset
            guard position < limit else { break }
            guard let vector = nativeRound[position], vector.token == token else {
                fail(position, "missing_or_invalid_committed_candidate")
                return
            }
            nativeReady[position] = compare(vector, position: position)
        }
    }

    /// Called for actual applied tokens before logical scheduler advancement,
    /// including EOS and held stop-sequence tokens. Speculative suffixes never
    /// reach this hook. A tool parser's already-recorded boundary excludes its
    /// extra closing scheduler step at the call site.
    @discardableResult
    func select(role: Role, requestID: String, position: Int, tokenID: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard self.requestID == requestID else { return true }
        guard firstFailure == nil else { return false }
        let expected = role == .ordinary ? ordinarySelectedCount : nativeSelectedCount
        guard position == expected else {
            fail(position, "duplicate_or_missing_selection")
            return false
        }
        if role == .ordinary { ordinarySelectedCount += 1 } else { nativeSelectedCount += 1 }
        guard position < limit else { return true }
        switch role {
        case .ordinary:
            guard let vector = ordinaryPending.removeValue(forKey: position), vector.token == tokenID,
                  !vector.logits.isEmpty, vector.logits.allSatisfy(\.isFinite)
            else {
                fail(position, "missing_or_invalid_ordinary_vector")
                return false
            }
            ordinarySelectedTokens[position] = tokenID
            references[position] = vector
        case .native:
            guard let candidate = nativeReady.removeValue(forKey: position) else {
                fail(position, "missing_native_vector")
                return false
            }
            guard candidate.sampledToken == tokenID, let result = candidate.position else {
                fail(position, candidate.error ?? "native_selected_token_mismatch")
                return false
            }
            nativeSelectedTokens[position] = tokenID
            selectedPositions.append(result)
            guard result.passed else {
                fail(position, !result.tokenExact ? "token_mismatch" : !result.finite ? "nonfinite_logits"
                    : !result.top1Exact ? "top1_mismatch" : "logit_difference")
                return false
            }
        }
        return true
    }

    /// Buyer-visible ordinals remain separate from applied-token positions:
    /// withheld EOS/stop selections count only in selectedPositions.
    @discardableResult
    func emit(role: Role, requestID: String, ordinal: Int, tokenID: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard self.requestID == requestID else { return true }
        guard firstFailure == nil else { return false }
        let expected = role == .ordinary ? ordinaryCount : nativeCount
        guard ordinal == expected else {
            fail(ordinal, "duplicate_or_missing_emission")
            return false
        }
        if role == .ordinary { ordinaryCount += 1 } else { nativeCount += 1 }
        guard ordinal < limit else { return true }
        switch role {
        case .ordinary:
            guard ordinarySelectedTokens[ordinal] == tokenID else {
                fail(ordinal, "missing_or_invalid_ordinary_selection")
                return false
            }
        case .native:
            guard nativeSelectedTokens[ordinal] == tokenID, ordinal < selectedPositions.count else {
                fail(ordinal, "missing_or_invalid_native_selection")
                return false
            }
            positions.append(selectedPositions[ordinal])
        }
        return true
    }

    func finishRequest(
        role: Role, requestID: String, emittedCount: Int, completed: Bool = true,
        terminal: Terminal = .other, selectedTokenIDs: [Int]? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard self.requestID == requestID else { return }
        if !completed { fail(nil, "request_did_not_complete") }
        if firstFailure == nil, let selectedTokenIDs {
            let count = role == .ordinary ? ordinarySelectedCount : nativeSelectedCount
            let selected = role == .ordinary ? ordinarySelectedTokens : nativeSelectedTokens
            if count != selectedTokenIDs.count || selectedTokenIDs.prefix(limit).enumerated().contains(where: {
                selected[$0.offset] != $0.element
            }) {
                fail(nil, "selected_token_provenance_mismatch")
            }
        }
        switch role {
        case .ordinary:
            ordinaryFinished = true
            ordinaryTerminal = terminal
            if firstFailure == nil, ordinarySelectedCount == 0 || ordinaryCount != emittedCount
                || ordinaryCount > ordinarySelectedCount
                || references.count != min(ordinarySelectedCount, limit) {
                fail(nil, "ordinary_emission_count_mismatch")
            }
            ordinaryPending.removeAll()
        case .native:
            nativeFinished = true
            nativeTerminal = terminal
            if firstFailure == nil,
               !ordinaryFinished || nativeCount != emittedCount
                || ordinaryCount != emittedCount
                || positions.count != min(emittedCount, limit)
                || ordinarySelectedCount != nativeSelectedCount
                || selectedPositions.count != min(nativeSelectedCount, limit) {
                fail(nil, "native_emission_count_mismatch")
            }
            if firstFailure == nil, ordinaryTerminal != nativeTerminal {
                fail(nil, "terminal_mismatch")
            }
            references.removeAll()
            ordinaryPending.removeAll()
            nativeRound.removeAll()
            nativeReady.removeAll()
            ordinarySelectedTokens.removeAll()
            nativeSelectedTokens.removeAll()
        }
    }

    func summary() -> Summary {
        lock.lock()
        defer { lock.unlock() }
        return Summary(
            requestID: requestID, positions: positions, selectedPositions: selectedPositions,
            ordinarySelectedCount: ordinarySelectedCount, nativeSelectedCount: nativeSelectedCount,
            firstFailure: firstFailure,
            ordinaryFinished: ordinaryFinished, nativeFinished: nativeFinished,
            ordinaryTerminal: ordinaryTerminal, nativeTerminal: nativeTerminal,
            retainedVectors: references.count + ordinaryPending.count + nativeRound.count)
    }

    private func fail(_ position: Int?, _ reason: String) {
        if firstFailure == nil { firstFailure = Failure(position: position, reason: reason) }
        ordinaryPending.removeAll()
        references.removeAll()
        nativeRound.removeAll()
        nativeReady.removeAll()
        ordinarySelectedTokens.removeAll()
        nativeSelectedTokens.removeAll()
    }

    private func compare(_ vector: Vector, position: Int) -> PendingComparison {
        guard ordinaryFinished, let reference = references[position] else {
            return PendingComparison(sampledToken: vector.token, position: nil, error: "missing_ordinary_reference")
        }
        guard !vector.logits.isEmpty, vector.logits.count == reference.logits.count else {
            return PendingComparison(sampledToken: vector.token, position: nil, error: "vocabulary_shape_mismatch")
        }
        let finite = vector.logits.allSatisfy(\.isFinite) && reference.logits.allSatisfy(\.isFinite)
        func top(_ values: [Float]) -> (Int, Float) {
            var index = 0
            var best = -Float.infinity
            var second = -Float.infinity
            for (i, value) in values.enumerated() {
                if value > best {
                    (index, second, best) = (i, best, value)
                } else if value > second { second = value }
            }
            return (index, values.count > 1 ? best - second : 0)
        }
        let a = finite ? top(reference.logits) : nil
        let b = finite ? top(vector.logits) : nil
        let delta = finite ? zip(reference.logits, vector.logits).reduce(Float(0)) {
            max($0, abs($1.0 - $1.1))
        } : nil
        return PendingComparison(
            sampledToken: vector.token,
            position: Position(
                position: position, ordinaryToken: reference.token, nativeToken: vector.token,
                tokenExact: vector.token == reference.token,
                top1Exact: finite && a?.0 == b?.0, finite: finite, maxAbsDifference: delta,
                ordinaryTop1: a?.0, nativeTop1: b?.0, ordinaryGap: a?.1, nativeGap: b?.1),
            error: nil)
    }
}
