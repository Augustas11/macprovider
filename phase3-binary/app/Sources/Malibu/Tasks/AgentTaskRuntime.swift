import Foundation

/// App lifetime ownership keeps schedules running when their screen is closed.
@MainActor
final class AgentTaskRuntime {
    static let shared = AgentTaskRuntime()
    let agents = AgentStore()
    let tasks = TaskStore()
    private var taskSession: AgentSession?
    lazy var scheduler = TaskScheduler(store: tasks, execute: { [weak self] task in
        guard let self, let definition = self.agents.agents.first(where: { $0.id == task.agentID }) else {
            throw ChatFailure.unavailable
        }
        let session = AgentSession(); self.taskSession = session
        defer { self.taskSession = nil }
        do { return try await session.run(agent: definition, prompt: task.prompt, preapprovedTools: task.preapprovedTools) }
        catch {
            let underlying: Error = error as? MCPFailure == .denied ? TaskRunFailure.unapprovedTool : error
            throw TaskExecutionFailure(underlying: underlying, transcript: session.transcript)
        }
    }, partialTranscript: { [weak self] in self?.taskSession?.transcript ?? "" }, cancel: { [weak self] in self?.taskSession?.cancel() })
    func start() { scheduler.start() }
    func stop() { scheduler.stop(); taskSession?.cancel(); AgentSession.terminateAll() }
}
