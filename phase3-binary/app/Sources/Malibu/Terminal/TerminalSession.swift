import AppKit
import SwiftTerm
import SwiftUI
import Darwin

/// Owns an ephemeral PTY. Keeping views here preserves scrollback when switching tabs.
@MainActor
final class TerminalSession: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    let harness: TerminalHarness
    @Published var workingDirectory = FileManager.default.homeDirectoryForCurrentUser
    @Published private(set) var started = false
    @Published private(set) var message: String?
    private(set) var terminalView: EmbeddedProcessTerminalView?
    private var processGroup: pid_t = 0
    private var leaderIdentity: ProcessIdentity?
    private var sessionMembers: [pid_t: ProcessIdentity] = [:]
    private var groupMonitor: Task<Void, Never>?
    private var handoff: URL?
    private var cleanupDirectory: URL?
    private static var active: [UUID: TerminalSession] = [:]
    private var closing = false

    init(harness: TerminalHarness) { self.harness = harness; super.init() }

    /// Keys are checked before any launcher or PTY is created.
    func start(executable: URL?, model: ConnectedModel?,
               hasKey: () -> Bool = { ConnectedBuyerKeychain.exists() },
               readKey: () throws -> String = { try ConnectedBuyerKeychain.read() }) {
        guard !started, !closing else { return }
        guard harness == .shell || hasKey() else {
            message = "Add a buyer key in Other apps"
            return
        }
        do {
            let command: URL
            let arguments: [String]
            let environment: [String: String]
            if harness == .shell {
                let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
                command = executable ?? URL(fileURLWithPath: FileManager.default.isExecutableFile(atPath: shell) ? shell : "/bin/zsh")
                arguments = ["-l"]
                environment = try ProcessEnvironmentSanitizer.sanitized(extraEnvironment: ["TERM": "xterm-256color"])
            } else {
                guard let executable else { message = "Not installed"; return }
                if harness == .claudeCode {
                    guard let model else { message = "Choose a gateway model first."; return }
                    let plan = try ClaudeCodeLauncher.prepare(executable: executable, model: model, key: readKey())
                    command = plan.executable
                    arguments = plan.arguments
                    environment = plan.environment
                    handoff = plan.keyHandoff
                    cleanupDirectory = plan.cleanupDirectory
                } else {
                    guard let app = harness.connectedApp else { return }
                    let prepared = try ConnectedAppsStore().prepareEmbeddedLaunch(app, isolated: true)
                    command = URL(fileURLWithPath: "/bin/sh")
                    arguments = [prepared.launcher.path]
                    handoff = prepared.handoff
                    cleanupDirectory = prepared.cleanupDirectory
                    environment = try ProcessEnvironmentSanitizer.sanitized(extraEnvironment: ["TERM": "xterm-256color"])
                }
            }
            let view = EmbeddedProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
            view.onTermination = { [weak self] exitCode in
                self?.processTerminated(exitCode: exitCode)
            }
            view.startProcess(executable: command.path, args: arguments,
                              environment: environment.map { "\($0.key)=\($0.value)" },
                              currentDirectory: workingDirectory.path)
            guard view.process.running, view.process.shellPid > 1 else {
                cleanup()
                message = "The terminal could not start."
                return
            }
            processGroup = view.process.shellPid
            leaderIdentity = Self.identity(of: processGroup)
            // forkpty returns in the parent before the child's setsid. Bound
            // this short startup barrier before exposing a running session.
            for _ in 0..<100 {
                sessionMembers = Self.members(ofSession: processGroup)
                if !sessionMembers.isEmpty { break }
                usleep(1_000)
            }
            if sessionMembers.isEmpty, let leaderIdentity { sessionMembers[processGroup] = leaderIdentity }
            monitorGroup()
            terminalView = view
            started = true
            message = harness == .shell ? nil : "Configured. Client compatibility has not been verified."
            Self.active[id] = self
        } catch {
            cleanup()
            message = "Set up this harness in Other apps before launching."
        }
    }

    func chooseFolder() {
        guard !started else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = workingDirectory
        if panel.runModal() == .OK, let url = panel.url { workingDirectory = url }
    }

    func close() {
        guard !closing else { return }
        closing = true
        signalOwnedSession(SIGHUP)
        cleanup()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            // Keep ownership through escalation, including jobs whose shell has
            // exited and jobs in a different foreground/background process group.
            while self.refreshSessionOwnership() {
                self.signalOwnedSession(SIGKILL)
                try? await Task.sleep(for: .milliseconds(50))
            }
            self.terminalView = nil
        }
    }

    static func terminateAll() async {
        let sessions = Array(active.values)
        for session in sessions { session.close() }
        // App termination must not discard owners before their final children die.
        while sessions.contains(where: { active[$0.id] != nil }) {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func cleanup() {
        if let handoff { ConnectedBuyerKeychain.removeLaunchHandoff(handoff) }
        if let cleanupDirectory { try? FileManager.default.removeItem(at: cleanupDirectory) }
        handoff = nil
        cleanupDirectory = nil
    }

    private struct ProcessIdentity: Equatable {
        let seconds: UInt64
        let microseconds: UInt64
    }

    private static func identity(of pid: pid_t) -> ProcessIdentity? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.stride)) > 0 else { return nil }
        return ProcessIdentity(seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
    }

    /// A PTY owns a session, not just the shell's process group. Interactive
    /// shells give each foreground and background job a separate process group.
    private static func members(ofSession session: pid_t) -> [pid_t: ProcessIdentity] {
        guard session > 1 else { return [:] }
        let required = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard required > 0 else { return [:] }
        var pids = [pid_t](repeating: 0, count: Int(required) / MemoryLayout<pid_t>.stride + 128)
        let count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids,
                                 Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard count > 0 else { return [:] }
        var result: [pid_t: ProcessIdentity] = [:]
        for pid in pids.prefix(Int(count) / MemoryLayout<pid_t>.stride) where pid > 1 {
            guard let before = identity(of: pid), getsid(pid) == session,
                  identity(of: pid) == before else { continue }
            result[pid] = before
        }
        return result
    }

    @discardableResult
    private func refreshSessionOwnership() -> Bool {
        let current = Self.members(ofSession: processGroup)
        let leader = Self.identity(of: processGroup)
        let overlappingMember = current.contains(where: { sessionMembers[$0.key] == $0.value })
        // A SID cannot be recycled while an identity-checked member remains.
        // Require that anchor or the original leader before adopting new PIDs.
        let originalSession = !current.isEmpty && leaderIdentity != nil && leader == leaderIdentity
        var owned = (overlappingMember || originalSession) ? current : [:]
        // Retain exact identities through a delayed setsid, or a session change.
        for (pid, identity) in sessionMembers where Self.identity(of: pid) == identity {
            owned[pid] = identity
        }
        if let leaderIdentity, leader == leaderIdentity { owned[processGroup] = leaderIdentity }
        sessionMembers = owned
        guard !owned.isEmpty else {
            processGroup = 0
            groupMonitor?.cancel()
            Self.active[id] = nil
            return false
        }
        return true
    }

    private func signalOwnedSession(_ signal: Int32) {
        guard refreshSessionOwnership() else { return }
        // Signal each identity rather than a negative PGID: a group leader may
        // disappear/recycle between enumeration and delivery. This also covers
        // every job-control group without ever signaling Malibu's parent group.
        for (pid, identity) in sessionMembers where Self.identity(of: pid) == identity {
            _ = kill(pid, signal)
        }
    }

    private func monitorGroup() {
        groupMonitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, self.refreshSessionOwnership() else { return }
            }
        }
    }

    private func processTerminated(exitCode: Int32?) {
        // A leader may exit while job-control children remain in other groups.
        // Keep their identities through close's three-second escalation.
        refreshSessionOwnership()
        cleanup()
        message = "Session ended."
    }

    /// Used to verify group termination with isolated test children.
    func adoptTestProcessGroup(_ group: pid_t) {
        precondition(group > 1 && group != getpgrp())
        processGroup = group
        leaderIdentity = Self.identity(of: group)
        sessionMembers = Self.members(ofSession: group)
        monitorGroup()
        Self.active[id] = self
    }
}

@MainActor
final class TerminalTabs: ObservableObject {
    static let limit = 8
    @Published private(set) var sessions: [TerminalSession] = []
    @Published var selection: UUID?

    @discardableResult
    func add(_ harness: TerminalHarness) -> TerminalSession? {
        guard sessions.count < Self.limit else { return nil }
        let session = TerminalSession(harness: harness)
        sessions.append(session)
        selection = session.id
        return session
    }

    func close(_ session: TerminalSession) {
        session.close()
        sessions.removeAll { $0.id == session.id }
        if selection == session.id { selection = sessions.last?.id }
    }
}

/// Window-owned state survives removing the Terminal destination from SwiftUI.
@MainActor
final class TerminalWorkspace: ObservableObject {
    let tabs = TerminalTabs()
    let catalog = HarnessCatalog()
    let models = ConnectedAppsStore()
}
