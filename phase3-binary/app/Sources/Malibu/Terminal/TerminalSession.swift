import AppKit
import SwiftTerm
import SwiftUI
import Darwin

/// Owns an ephemeral PTY. Keeping views here preserves scrollback when switching tabs.
@MainActor
final class TerminalSession: NSObject, ObservableObject, Identifiable, LocalProcessTerminalViewDelegate {
    let id = UUID()
    let harness: TerminalHarness
    @Published var workingDirectory = FileManager.default.homeDirectoryForCurrentUser
    @Published private(set) var started = false
    @Published private(set) var message: String?
    private(set) var terminalView: LocalProcessTerminalView?
    private var processGroup: pid_t = 0
    private var leaderIdentity: ProcessIdentity?
    private var groupMembers: [pid_t: ProcessIdentity] = [:]
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
            let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
            view.processDelegate = self
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
                groupMembers = Self.members(of: processGroup)
                if !groupMembers.isEmpty { break }
                usleep(1_000)
            }
            if groupMembers.isEmpty, let leaderIdentity { groupMembers[processGroup] = leaderIdentity }
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
        let group = processGroup
        signalOwnedProcessGroup(SIGHUP)
        cleanup()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if group > 1, self.processGroup == group { self.signalOwnedProcessGroup(SIGKILL) }
            self.processGroup = 0
            self.groupMonitor?.cancel()
            self.terminalView = nil
            Self.active[self.id] = nil
        }
    }

    static func terminateAll() async {
        let sessions = Array(active.values)
        for session in sessions { session.close() }
        if !sessions.isEmpty { try? await Task.sleep(for: .seconds(3.1)) }
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

    /// Start times prevent a recycled PID/PGID from being treated as our child.
    private static func members(of group: pid_t) -> [pid_t: ProcessIdentity] {
        guard group > 1 else { return [:] }
        let required = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), nil, 0)
        guard required > 0 else { return [:] }
        var pids = [pid_t](repeating: 0, count: Int(required) / MemoryLayout<pid_t>.stride + 32)
        let count = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), &pids,
                                 Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard count > 0 else { return [:] }
        var result: [pid_t: ProcessIdentity] = [:]
        for pid in pids.prefix(Int(count) / MemoryLayout<pid_t>.stride) where pid > 1 {
            var info = proc_bsdinfo()
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.stride)) > 0,
               info.pbi_pgid == UInt32(group) {
                result[pid] = ProcessIdentity(seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
            }
        }
        return result
    }

    @discardableResult
    private func refreshGroupOwnership() -> Bool {
        let current = Self.members(of: processGroup)
        let overlappingMember = current.contains(where: { groupMembers[$0.key] == $0.value })
        let leader = Self.identity(of: processGroup)
        // A fast leader can fork and exit between observations. Its surviving
        // session retains the PGID; a reused leader identity cannot inherit it.
        let originalSession = !current.isEmpty && (leader == nil || leader == leaderIdentity)
            && current.keys.allSatisfy { getsid($0) == processGroup }
        // If setsid is delayed past the startup barrier, the exact child PID
        // remains ours. Never discard it just because its group is pending.
        let pendingLeader = current.isEmpty && leaderIdentity != nil && leader == leaderIdentity
            && getpgid(processGroup) != processGroup
        if pendingLeader { return true }
        guard overlappingMember || originalSession else {
            processGroup = 0
            groupMembers = [:]
            groupMonitor?.cancel()
            Self.active[id] = nil
            return false
        }
        groupMembers = current
        return true
    }

    private func signalOwnedProcessGroup(_ signal: Int32) {
        guard refreshGroupOwnership(), processGroup > 1 else { return }
        if getpgid(processGroup) == processGroup || Self.identity(of: processGroup) == nil {
            _ = kill(-processGroup, signal)
        } else if Self.identity(of: processGroup) == leaderIdentity {
            // Before setsid, signal only the identity-checked child, never
            // its inherited group (which may be Malibu's own process group).
            _ = kill(processGroup, signal)
        }
    }

    private func monitorGroup() {
        groupMonitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, self.refreshGroupOwnership() else { return }
            }
        }
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
    func processTerminated(source: SwiftTerm.TerminalView, exitCode: Int32?) {
        // A leader may exit while its tools remain in the group. Keep ownership
        // of known surviving members through close's three-second escalation.
        refreshGroupOwnership()
        cleanup()
        message = "Session ended."
    }

    /// Used to verify group termination with isolated test children.
    func adoptTestProcessGroup(_ group: pid_t) {
        precondition(group > 1 && group != getpgrp())
        processGroup = group
        leaderIdentity = Self.identity(of: group)
        groupMembers = Self.members(of: group)
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
