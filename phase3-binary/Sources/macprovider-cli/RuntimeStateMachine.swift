import Foundation

public enum SwapState: String, Sendable, Equatable {
    case ready
    case loading
    case draining
    case failed
}

public struct SwapSignal: Sendable {
    public enum Outcome: Sendable {
        case completed(newModelID: String, newModelHash: String?)
        case failed(reason: String)
    }

    public let targetModelID: String
    public let outcome: Outcome
}

public actor RuntimeStateMachine {
    private var state: SwapState = .ready
    private var targetModelID: String?
    private var signalContinuations: [AsyncStream<SwapSignal>.Continuation] = []

    public init() {}

    public func current() -> SwapState { state }

    public func currentTargetModelID() -> String? { targetModelID }

    public func transitionToLoading(target: String) throws {
        guard state == .ready else {
            throw RuntimeStateMachineError.notReady(current: state)
        }
        state = .loading
        targetModelID = target
    }

    public func transitionToDraining() throws {
        guard state == .loading else {
            throw RuntimeStateMachineError.notReady(current: state)
        }
        state = .draining
    }

    public func completeSwap(newModelID: String, newModelHash: String?) {
        let target = targetModelID ?? newModelID
        state = .ready
        targetModelID = nil
        signal(SwapSignal(targetModelID: target, outcome: .completed(newModelID: newModelID, newModelHash: newModelHash)))
    }

    public func failSwap(reason: String) {
        let target = targetModelID ?? ""
        state = .failed
        signal(SwapSignal(targetModelID: target, outcome: .failed(reason: reason)))
        state = .ready
        targetModelID = nil
    }

    public func signalStream() -> AsyncStream<SwapSignal> {
        let pair = AsyncStream<SwapSignal>.makeStream(of: SwapSignal.self)
        signalContinuations.append(pair.continuation)
        return pair.stream
    }

    private func signal(_ signal: SwapSignal) {
        for continuation in signalContinuations {
            continuation.yield(signal)
        }
    }
}

public enum RuntimeStateMachineError: Error, Equatable {
    case notReady(current: SwapState)
}
