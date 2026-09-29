#if DEBUG || MACPROVIDER_LAB_HARNESS
import Foundation
import MLX

struct NativeMTPParityCoordinate: Sendable, Hashable {
    let packedRoundID: UInt64
    let verificationColumn: Int
}

/// Lab-only target-logit evidence retained outside the timed R015 interval.
/// MLX arrays are evaluated by the producing model-container closure before
/// they reach this collector; the unchecked conformance only permits the
/// lock-protected references to cross into the post-run oracle.
struct NativeMTPParityCapturedPosition: @unchecked Sendable {
    let nativeToken: Int
    let nativeTargetLogits: MLXArray
    let coordinate: NativeMTPParityCoordinate?
    let otherRowPackedArgmaxes: Set<Int>
}

struct NativeMTPParityTrace: @unchecked Sendable {
    let promptTokens: [Int]
    let positions: [NativeMTPParityCapturedPosition]
}

final class NativeMTPParityTraceCollector: @unchecked Sendable {
    static let shared = NativeMTPParityTraceCollector()

    private struct State {
        var promptTokens: [Int]?
        var positions: [NativeMTPParityCapturedPosition] = []
        var stagedTargetLogits: [(MLXArray, NativeMTPParityCoordinate)] = []
        var observedCoordinates: Set<NativeMTPParityCoordinate> = []
    }

    private let lock = NSLock()
    private var states: [String: State] = [:]
    private var packedArgmaxes: [NativeMTPParityCoordinate: [String: Int]] = [:]
    private var nextPackedRoundID: UInt64 = 1

    private init() {}

    func allocatePackedRoundID() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let value = nextPackedRoundID
        nextPackedRoundID &+= 1
        return value
    }

    func begin(requestID: String) {
        lock.lock()
        states[requestID] = State()
        lock.unlock()
    }

    func recordPrompt(requestID: String, tokens: [Int]) {
        lock.lock()
        if states[requestID] != nil {
            states[requestID]?.promptTokens = tokens
        }
        lock.unlock()
    }

    func recordPrefillToken(
        requestID: String,
        token: Int,
        targetLogits: MLXArray,
        packedRoundID: UInt64
    ) {
        lock.lock()
        if states[requestID] != nil {
            let coordinate = NativeMTPParityCoordinate(
                packedRoundID: packedRoundID,
                verificationColumn: 0
            )
            states[requestID]?.positions.append(
                NativeMTPParityCapturedPosition(
                    nativeToken: token,
                    nativeTargetLogits: targetLogits,
                    coordinate: coordinate,
                    otherRowPackedArgmaxes: []
                )
            )
            states[requestID]?.observedCoordinates.insert(coordinate)
            packedArgmaxes[coordinate, default: [:]][requestID] = token
        }
        lock.unlock()
    }

    /// Snapshot cross-row evidence only after every row in the backend batch
    /// has recorded the coordinate. This prevents the first serial-prefill row
    /// from missing argmaxes recorded later in the same batch.
    func sealPackedCoordinates(_ coordinates: Set<NativeMTPParityCoordinate>) {
        lock.lock()
        defer { lock.unlock() }
        for coordinate in coordinates {
            let argmaxes = packedArgmaxes[coordinate] ?? [:]
            for requestID in argmaxes.keys {
                guard var state = states[requestID] else { continue }
                var otherArgmaxes = argmaxes
                otherArgmaxes.removeValue(forKey: requestID)
                state.positions = state.positions.map { position in
                    guard position.coordinate == coordinate else { return position }
                    return NativeMTPParityCapturedPosition(
                        nativeToken: position.nativeToken,
                        nativeTargetLogits: position.nativeTargetLogits,
                        coordinate: position.coordinate,
                        otherRowPackedArgmaxes: Set(otherArgmaxes.values)
                    )
                }
                states[requestID] = state
            }
        }
    }

    func stageVerification(
        requestID: String,
        packedRoundID: UInt64,
        targetLogits: [MLXArray],
        targetArgmaxes: [Int]
    ) {
        lock.lock()
        if states[requestID] != nil, targetLogits.count == targetArgmaxes.count {
            let staged = zip(targetLogits, targetArgmaxes).enumerated().map {
                (
                    $0.element.0,
                    NativeMTPParityCoordinate(
                        packedRoundID: packedRoundID,
                        verificationColumn: $0.offset
                    ),
                    $0.element.1
                )
            }
            states[requestID]?.stagedTargetLogits = staged.map { ($0.0, $0.1) }
            for (_, coordinate, targetArgmax) in staged {
                states[requestID]?.observedCoordinates.insert(coordinate)
                packedArgmaxes[coordinate, default: [:]][requestID] = targetArgmax
            }
        }
        lock.unlock()
    }

    /// Publish only logits whose corresponding tokens survived acceptance,
    /// terminal truncation, and backend commit. Unused staged logits are
    /// discarded, so every retained position is one-for-one with an emitted
    /// native token.
    func commitVerification(requestID: String, tokens: [Int]) {
        lock.lock()
        defer { lock.unlock() }
        guard var state = states[requestID],
              tokens.count <= state.stagedTargetLogits.count
        else {
            states.removeValue(forKey: requestID)
            return
        }
        state.positions.append(contentsOf: zip(tokens, state.stagedTargetLogits).map {
            var otherArgmaxes = packedArgmaxes[$0.1.1] ?? [:]
            otherArgmaxes.removeValue(forKey: requestID)
            return NativeMTPParityCapturedPosition(
                nativeToken: $0.0,
                nativeTargetLogits: $0.1.0,
                coordinate: $0.1.1,
                otherRowPackedArgmaxes: Set(otherArgmaxes.values)
            )
        })
        state.stagedTargetLogits.removeAll(keepingCapacity: false)
        states[requestID] = state
    }

    func take(requestID: String) -> NativeMTPParityTrace? {
        lock.lock()
        defer { lock.unlock() }
        guard let state = states[requestID],
              let promptTokens = state.promptTokens,
              state.stagedTargetLogits.isEmpty
        else {
            if let discarded = states.removeValue(forKey: requestID) {
                removePackedEvidence(
                    requestID: requestID,
                    coordinates: discarded.observedCoordinates
                )
            }
            return nil
        }
        states.removeValue(forKey: requestID)
        removePackedEvidence(requestID: requestID, coordinates: state.observedCoordinates)
        return NativeMTPParityTrace(
            promptTokens: promptTokens,
            positions: state.positions
        )
    }

    func cancel(requestID: String) {
        lock.lock()
        if let state = states.removeValue(forKey: requestID) {
            removePackedEvidence(requestID: requestID, coordinates: state.observedCoordinates)
        }
        lock.unlock()
    }

    private func removePackedEvidence(
        requestID: String,
        coordinates: Set<NativeMTPParityCoordinate>
    ) {
        for coordinate in coordinates {
            packedArgmaxes[coordinate]?.removeValue(forKey: requestID)
            if packedArgmaxes[coordinate]?.isEmpty == true {
                packedArgmaxes.removeValue(forKey: coordinate)
            }
        }
    }
}
#endif
