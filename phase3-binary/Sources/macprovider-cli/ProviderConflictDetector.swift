import Darwin
import Foundation

enum ProviderConflict: Equatable {
    case none
    case launchdManaged(pid: Int32?)
    case foreground(pid: Int32, argv: [String])
}

struct ProviderConflictDetector {
    static let launchdLabel = "live.streamvc.macprovider"

    private let launchctlList: () throws -> String
    private let processList: () throws -> [(pid: Int32, argv: [String])]

    init(
        launchctlList: @escaping () throws -> String = ProviderConflictDetector.defaultLaunchctlList,
        processList: @escaping () throws -> [(pid: Int32, argv: [String])] = ProviderConflictDetector.defaultProcessList
    ) {
        self.launchctlList = launchctlList
        self.processList = processList
    }

    func detect() throws -> ProviderConflict {
        let launchd = Self.parseLaunchdManagedPID(from: try launchctlList())
        if launchd.found {
            return .launchdManaged(pid: launchd.pid)
        }

        for process in try processList() {
            if Self.isForegroundServe(argv: process.argv) {
                return .foreground(pid: process.pid, argv: process.argv)
            }
        }

        return .none
    }

    static func parseLaunchdManagedPID(from output: String) -> (found: Bool, pid: Int32?) {
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let fields = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.contains(Substring(launchdLabel)) else {
                continue
            }
            guard let first = fields.first else {
                return (true, nil)
            }
            if first == "-" {
                return (true, nil)
            }
            return (true, Int32(first))
        }
        return (false, nil)
    }

    static func isForegroundServe(argv: [String]) -> Bool {
        guard !argv.contains("autotune") else {
            return false
        }

        for index in argv.indices {
            guard URL(fileURLWithPath: argv[index]).lastPathComponent == "macprovider-cli" else {
                continue
            }
            let serveIndex = argv.index(after: index)
            if argv.indices.contains(serveIndex), argv[serveIndex] == "serve" {
                return true
            }
        }
        return false
    }

    static func defaultLaunchctlList() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["list"]
        let stdout = Pipe()
        process.standardOutput = stdout
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw NSError(
                domain: "macprovider.provider-conflict-detector",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "/bin/launchctl list exited with status \(process.terminationStatus)"]
            )
        }
        return String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    static func defaultProcessList() throws -> [(pid: Int32, argv: [String])] {
        let byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCount > 0 else {
            return []
        }

        let capacity = Int(byteCount) / MemoryLayout<pid_t>.stride
        var pids = [pid_t](repeating: 0, count: capacity)
        let filledBytes = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.stride))
        }
        let pidCount = max(0, Int(filledBytes) / MemoryLayout<pid_t>.stride)

        var processes: [(pid: Int32, argv: [String])] = []
        for pid in pids.prefix(pidCount) where pid > 0 {
            guard let argv = processArguments(pid: pid), !argv.isEmpty else {
                continue
            }
            processes.append((pid: Int32(pid), argv: argv))
        }
        return processes
    }

    private static func processArguments(pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            return nil
        }

        var buffer = [CChar](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else {
            return nil
        }

        let argc = buffer.withUnsafeBytes { rawBuffer -> Int32 in
            rawBuffer.load(as: Int32.self)
        }
        guard argc > 0 else {
            return []
        }

        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 {
            index += 1
        }
        while index < size, buffer[index] == 0 {
            index += 1
        }

        var argv: [String] = []
        while index < size, argv.count < Int(argc) {
            if buffer[index] == 0 {
                index += 1
                continue
            }
            let start = index
            while index < size, buffer[index] != 0 {
                index += 1
            }
            buffer.withUnsafeBufferPointer { pointer in
                if let baseAddress = pointer.baseAddress {
                    argv.append(String(cString: baseAddress.advanced(by: start)))
                }
            }
            index += 1
        }
        return argv
    }
}

enum ProviderDrainResult: Equatable {
    case drained
    case portStillOpen(port: Int)
}

enum ProviderRestoreResult: Equatable {
    case restored
    case skipped
}

struct ProviderDrainer {
    typealias LaunchctlRunner = (String, [String]) throws -> Void
    typealias SignalSender = (Int32, Int32) -> Int32
    typealias ProcessRunningProbe = (Int32) -> Bool
    typealias PortProbe = (Int) -> Bool
    typealias ForegroundRestarter = ([String]) throws -> Void
    typealias LaunchdRestoreGuardStarter = (_ launchdDomain: String, _ plistPath: String) throws -> ProviderLaunchdRestoreGuard

    static let launchctlPath = "/bin/launchctl"
    static let launchdLabel = ProviderConflictDetector.launchdLabel

    private let uid: uid_t
    private let plistURL: URL
    private let launchctlRunner: LaunchctlRunner
    private let signalSender: SignalSender
    private let processIsRunning: ProcessRunningProbe
    private let portIsOpen: PortProbe
    private let foregroundRestarter: ForegroundRestarter
    private let launchdRestoreGuardStarter: LaunchdRestoreGuardStarter
    private let warningWriter: (String) -> Void

    init(
        uid: uid_t = getuid(),
        plistURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/live.streamvc.macprovider.plist"),
        launchctlRunner: @escaping LaunchctlRunner = ProviderDrainer.defaultLaunchctlRunner,
        signalSender: @escaping SignalSender = { Darwin.kill($0, $1) },
        processIsRunning: @escaping ProcessRunningProbe = ProviderDrainer.defaultProcessIsRunning,
        portIsOpen: @escaping PortProbe = MacProviderPortProbe.isOpen,
        foregroundRestarter: @escaping ForegroundRestarter = ProviderDrainer.defaultForegroundRestarter,
        launchdRestoreGuardStarter: @escaping LaunchdRestoreGuardStarter = ProviderLaunchdRestoreGuard.start,
        warningWriter: @escaping (String) -> Void = ProviderDrainer.defaultWarningWriter
    ) {
        self.uid = uid
        self.plistURL = plistURL
        self.launchctlRunner = launchctlRunner
        self.signalSender = signalSender
        self.processIsRunning = processIsRunning
        self.portIsOpen = portIsOpen
        self.foregroundRestarter = foregroundRestarter
        self.launchdRestoreGuardStarter = launchdRestoreGuardStarter
        self.warningWriter = warningWriter
    }

    func drain(_ conflict: ProviderConflict, port: Int, graceSeconds: TimeInterval) throws -> ProviderDrainResult {
        switch conflict {
        case .none:
            return .drained
        case .launchdManaged:
            try launchctlRunner(Self.launchctlPath, ["bootout", launchdServiceTarget])
        case .foreground(let pid, _):
            guard signalSender(pid, SIGTERM) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }

        let portFreed = waitForDrainCompletion(conflict, port: port, graceSeconds: graceSeconds)
        if case .foreground(let pid, _) = conflict, processIsRunning(pid) {
            warningWriter("warning: foreground provider pid \(pid) did not exit within \(graceSeconds)s grace; SIGKILL is disabled in v1")
        }
        return portFreed ? .drained : .portStillOpen(port: port)
    }

    func restore(_ conflict: ProviderConflict, restartForeground: Bool = false) throws -> ProviderRestoreResult {
        switch conflict {
        case .none:
            return .skipped
        case .launchdManaged:
            try launchctlRunner(Self.launchctlPath, ["bootstrap", launchdDomain, plistURL.path])
            return .restored
        case .foreground(_, let argv):
            guard restartForeground else {
                return .skipped
            }
            try foregroundRestarter(argv)
            return .restored
        }
    }

    func startLaunchdCrashRestoreGuard(for conflict: ProviderConflict) throws -> ProviderLaunchdRestoreGuard? {
        guard case .launchdManaged = conflict else {
            return nil
        }
        return try launchdRestoreGuardStarter(launchdDomain, plistURL.path)
    }

    private var launchdDomain: String {
        "gui/\(uid)"
    }

    private var launchdServiceTarget: String {
        "\(launchdDomain)/\(Self.launchdLabel)"
    }

    private func waitForDrainCompletion(_ conflict: ProviderConflict, port: Int, graceSeconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(max(0, graceSeconds))
        while Date() <= deadline {
            let portOpen = portIsOpen(port)
            let foregroundStillRunning: Bool
            if case .foreground(let pid, _) = conflict {
                foregroundStillRunning = processIsRunning(pid)
            } else {
                foregroundStillRunning = false
            }
            if !portOpen && !foregroundStillRunning {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return !portIsOpen(port)
    }

    static func defaultLaunchctlRunner(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw NSError(
                domain: "macprovider.provider-drainer",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "\(executable) exited with status \(process.terminationStatus)"]
            )
        }
    }

    static func defaultProcessIsRunning(_ pid: Int32) -> Bool {
        if Darwin.kill(pid, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    static func defaultForegroundRestarter(_ argv: [String]) throws {
        guard let executable = argv.first, !executable.isEmpty else {
            return
        }

        let process = Process()
        if executable.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = Array(argv.dropFirst())
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = argv
        }
        try process.run()
    }

    static func defaultWarningWriter(_ warning: String) {
        FileHandle.standardError.write(Data(("\(warning)\n").utf8))
    }
}

final class ProviderLaunchdRestoreGuard {
    static let dismissToken = "__macprovider_launchd_restore_guard_dismiss__"
    static let restoreScript = """
        trap '' HUP INT QUIT TERM
        while IFS= read -r line; do
          [ "$line" = "$4" ] && exit 0
        done
        "$1" bootstrap "$2" "$3" >/dev/null 2>&1 || true
        """

    private let lock = NSLock()
    private var dismissed = false
    private let dismissHandler: () -> Void

    init(dismissHandler: @escaping () -> Void) {
        self.dismissHandler = dismissHandler
    }

    func dismiss() {
        lock.lock()
        if dismissed {
            lock.unlock()
            return
        }
        dismissed = true
        lock.unlock()
        dismissHandler()
    }

    static func start(launchdDomain: String, plistPath: String) throws -> ProviderLaunchdRestoreGuard {
        try start(
            launchdDomain: launchdDomain,
            plistPath: plistPath,
            launchctlPath: "/bin/launchctl"
        )
    }

    static func start(
        launchdDomain: String,
        plistPath: String,
        launchctlPath: String
    ) throws -> ProviderLaunchdRestoreGuard {
        let process = Process()
        let stdin = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            restoreScript,
            "macprovider-launchd-restore-guard",
            launchctlPath,
            launchdDomain,
            plistPath,
            dismissToken,
        ]
        process.standardInput = stdin.fileHandleForReading
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()

        return ProviderLaunchdRestoreGuard {
            try? stdin.fileHandleForWriting.write(
                contentsOf: Data("\(dismissToken)\n".utf8)
            )
            try? stdin.fileHandleForWriting.close()
            process.waitUntilExit()
        }
    }
}
