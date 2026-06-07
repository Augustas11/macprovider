import Foundation

public enum SwapState: String, Sendable, Equatable {
    case ready
    case loading
    case draining
    case failed
}

public struct SwapSignal: Sendable {
    public enum Outcome: Sendable {
        case loadFinished
        case completed(newModelID: String, newModelHash: String?)
        case failed(reason: String)
    }

    public let targetModelID: String
    public let outcome: Outcome
}

public enum RuntimeStateMachineError: Error, Equatable {
    case notReady(current: SwapState)
}
