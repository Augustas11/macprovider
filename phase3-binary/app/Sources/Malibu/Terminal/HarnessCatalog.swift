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

@MainActor
final class HarnessCatalog: ObservableObject {
    @Published private(set) var executables: [TerminalHarness: URL] = [:]
    @Published private(set) var detected = false
    private var detection: Task<[TerminalHarness: URL], Never>?
    private let resolver: @Sendable (String) async -> URL?

    init(resolver: @escaping @Sendable (String) async -> URL? = HarnessCatalog.resolve) {
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
                var result: [TerminalHarness: URL] = [:]
                for harness in TerminalHarness.allCases where harness != .shell {
                    if let executable = await resolver(harness.command) { result[harness] = executable }
                }
                return result
            }
        }
        if let detection { executables = await detection.value }
        detected = true
    }

    nonisolated static func resolve(_ command: String) async -> URL? {
        guard TerminalHarness.allCases.contains(where: { $0 != .shell && $0.command == command }) else { return nil }
        return await Task.detached(priority: .utility) {
            let process = Process()
            let pipe = Pipe()
            var outputBytes = Data()
            var overflowed = false
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", "command -v " + command]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard let environment = try? ProcessEnvironmentSanitizer.sanitized() else { return nil }
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
            let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard path.hasPrefix("/"), !path.contains("\n"), !path.contains("\r"),
                  FileManager.default.isExecutableFile(atPath: path) else { return nil }
            return URL(fileURLWithPath: path).resolvingSymlinksInPath()
        }.value
    }
}
