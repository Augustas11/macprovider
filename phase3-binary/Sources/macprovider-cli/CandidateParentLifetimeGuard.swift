import Darwin
import Dispatch

/// Only CLI-owned, non-joining candidate children opt into this guard. The child
/// observes its own kernel parent relation; no recovery process signals a saved
/// PID that could have been reassigned to an unrelated process.
final class CandidateParentLifetimeGuard {
    private let timer: DispatchSourceTimer

    init(expectedParentPID: Int32) {
        guard expectedParentPID > 1, getppid() == expectedParentPID else { _exit(70) }
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: .milliseconds(250))
        timer.setEventHandler {
            if getppid() != expectedParentPID {
                // A candidate has no coordinator/session ownership to restore.
                // Process exit releases its model/GPU resources even if a Swift
                // executor is blocked inside model loading or generation.
                _exit(70)
            }
        }
        timer.resume()
    }

    deinit { timer.cancel() }
}
