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
            let process = Process()
            let pipe = Pipe()
            var outputBytes = Data()
            var overflowed = false
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", "printf '%s\\n%s\\n' \"$(command -v " + command + ")\" \"$PATH\""]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard let environment = try? ProcessEnvironmentSanitizer.sanitized(from: inherited) else { return nil }
            process.environment = environment
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
            do { try process.run() } catch { return nil }
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning && Date() < deadline && !overflowed {
                drain()
                usleep(10_000)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
                return nil
            }
            process.waitUntilExit()
            drain()
            guard process.terminationStatus == 0, !overflowed,
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
