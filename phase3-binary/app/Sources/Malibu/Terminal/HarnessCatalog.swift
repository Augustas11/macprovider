import Darwin
import Foundation

/// Only fixed app-owned command names reach the login-shell resolver.
enum TerminalHarness: String, CaseIterable, Identifiable {
    case shell, claudeCode, codex, openCode, crush, goose

    var id: String { rawValue }
    var title: String {
        switch self {
        case .shell: return "Shell"
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .openCode: return "OpenCode"
        case .crush: return "Crush"
        case .goose: return "Goose"
        }
    }
    var command: String {
        switch self {
        case .shell: return "zsh"
        case .claudeCode: return "claude"
        case .codex: return "codex"
        case .openCode: return "opencode"
        case .crush: return "crush"
        case .goose: return "goose"
        }
    }
    var connectedApp: ConnectedApp? {
        switch self {
        case .codex: return .codex
        case .openCode: return .openCode
        case .crush: return .crush
        case .goose: return .goose
        default: return nil
        }
    }
}

struct HarnessExecutable: Sendable {
    let url: URL
    let loginPath: String
}

@MainActor
final class HarnessCatalog: ObservableObject {
    @Published private(set) var executables: [TerminalHarness: HarnessExecutable] = [:]
    @Published private(set) var detected = false
    private var detection: Task<[TerminalHarness: HarnessExecutable], Never>?
    private let resolver: @Sendable (String) async -> HarnessExecutable?

    init(resolver: @escaping @Sendable (String) async -> HarnessExecutable? = HarnessCatalog.resolve) {
        self.resolver = resolver
    }

    func isInstalled(_ harness: TerminalHarness) -> Bool {
        harness == .shell || executables[harness] != nil
    }

    /// Concurrent callers share the same detection, including negative results.
    func detect() async {
        if detected { return }
        if detection == nil {
            let resolver = resolver
            detection = Task {
                var result: [TerminalHarness: HarnessExecutable] = [:]
                for harness in TerminalHarness.allCases where harness != .shell {
                    if let executable = await resolver(harness.command) { result[harness] = executable }
                }
                return result
            }
        }
        if let detection { executables = await detection.value }
        detected = true
    }

    nonisolated static func resolve(_ command: String) async -> HarnessExecutable? {
        await resolve(command, environment: ProcessInfo.processInfo.environment)
    }

    nonisolated static func resolve(_ command: String, environment inherited: [String: String]) async -> HarnessExecutable? {
        guard TerminalHarness.allCases.contains(where: { $0 != .shell && $0.command == command }) else { return nil }
        return await Task.detached(priority: .utility) {
            let pipe = Pipe()
            var outputBytes = Data()
            var overflowed = false
            guard let environment = try? ProcessEnvironmentSanitizer.sanitized(from: inherited) else { return nil }
            let descriptor = pipe.fileHandleForReading.fileDescriptor
            _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
            defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
            func drain() {
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = Darwin.read(descriptor, &buffer, buffer.count)
                    if count <= 0 { return }
                    guard outputBytes.count + count <= 16_384 else { overflowed = true; return }
                    outputBytes.append(contentsOf: buffer.prefix(count))
                }
            }
            // Establish the process group atomically at spawn, before any
            // login startup script can launch children.
            var attributes: posix_spawnattr_t?
            var actions: posix_spawn_file_actions_t?
            guard posix_spawnattr_init(&attributes) == 0 else { return nil }
            defer { posix_spawnattr_destroy(&attributes) }
            guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
            defer { posix_spawn_file_actions_destroy(&actions) }
            guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
                  posix_spawnattr_setpgroup(&attributes, 0) == 0,
                  posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
                  posix_spawn_file_actions_adddup2(&actions, pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO) == 0,
                  posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) == 0,
                  posix_spawn_file_actions_addclose(&actions, descriptor) == 0,
                  posix_spawn_file_actions_addclose(&actions, pipe.fileHandleForWriting.fileDescriptor) == 0 else { return nil }
            let arguments = ["/bin/zsh", "-lc", "printf '%s\\n%s\\n' \"$(command -v " + command + ")\" \"$PATH\""]
            let argv = arguments.map { strdup($0) } + [nil]
            let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
            defer {
                for pointer in argv { free(pointer) }
                for pointer in envp { free(pointer) }
            }
            var pid: pid_t = 0
            let spawned = argv.withUnsafeBufferPointer { args in
                envp.withUnsafeBufferPointer { env in
                    posix_spawn(&pid, "/bin/zsh", &actions, &attributes,
                                UnsafeMutablePointer(mutating: args.baseAddress!),
                                UnsafeMutablePointer(mutating: env.baseAddress!))
                }
            }
            guard spawned == 0 else { return nil }
            try? pipe.fileHandleForWriting.close()
            let deadline = Date().addingTimeInterval(5)
            // WNOWAIT preserves the leader's identity until group cleanup is
            // complete, including when it exits before an overflowing child.
            var info = siginfo_t()
            var exited = false
            while Date() < deadline && !overflowed {
                drain()
                if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 && info.si_pid == pid {
                    exited = true
                    break
                }
                usleep(10_000)
            }
            drain()
            // Successful startup scripts can also leave background children.
            // Keep the unreaped leader's PID reserved through both signals.
            _ = kill(-pid, SIGTERM)
            usleep(100_000)
            _ = kill(-pid, SIGKILL)
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            guard exited, status == 0, !overflowed,
                  let output = String(data: outputBytes, encoding: .utf8) else { return nil }
            // Login startup text cannot become an executable path.
            return parseResolution(output)

        }.value
    }
    nonisolated static func validatedLoginPath(_ path: String) -> String? {
        guard ProcessEnvironmentSanitizer.isSafeValue(path) else { return nil }
        let entries = path.split(separator: ":", omittingEmptySubsequences: false)
        guard !entries.isEmpty, entries.allSatisfy({ $0.hasPrefix("/") }) else { return nil }
        return path
    }

    nonisolated static func parseResolution(_ output: String) -> HarnessExecutable? {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count == 3, lines[2].isEmpty else { return nil }
        let path = String(lines[0])
        guard path.hasPrefix("/"), ProcessEnvironmentSanitizer.isSafeValue(path),
              FileManager.default.isExecutableFile(atPath: path),
              let loginPath = validatedLoginPath(String(lines[1])) else { return nil }
        return HarnessExecutable(url: URL(fileURLWithPath: path).resolvingSymlinksInPath(), loginPath: loginPath)
    }

    nonisolated static func launchEnvironment(loginPath: String,
                                             inherited: [String: String] = ProcessInfo.processInfo.environment,
                                             extra: [String: String] = [:]) throws -> [String: String] {
        guard let path = validatedLoginPath(loginPath) else { throw ConnectedAppsError.invalidConfiguration }
        var environment = extra
        environment["PATH"] = path
        return try ProcessEnvironmentSanitizer.sanitized(from: inherited, extraEnvironment: environment)
    }

}
