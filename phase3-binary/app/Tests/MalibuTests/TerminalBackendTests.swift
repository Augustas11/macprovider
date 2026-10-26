import Darwin
import Foundation
import XCTest
@testable import Malibu

final class TerminalBackendTests: XCTestCase {
    @MainActor
    func testHarnessDetectionCachesMissingAndInstalledExecutables() async {
        let counter = ResolverCounter()
        let catalog = HarnessCatalog { command in
            await counter.record(command)
            return command == "claude" ? URL(fileURLWithPath: "/bin/echo") : nil
        }
        await catalog.detect()
        await catalog.detect()
        XCTAssertTrue(catalog.isInstalled(.shell))
        XCTAssertTrue(catalog.isInstalled(.claudeCode))
        XCTAssertFalse(catalog.isInstalled(.codex))
        let commands = await counter.commands
        XCTAssertEqual(commands, ["claude", "codex", "opencode", "crush", "goose"])
        XCTAssertEqual(TerminalHarness.allCases.map(\.title), ["Shell", "Claude Code", "Codex", "OpenCode", "Crush", "Goose"])
    }

    func testResolverRefusesCommandsOutsideTheFixedCatalog() async {
        let result = await HarnessCatalog.resolve("claude; touch /tmp/not-allowed")
        XCTAssertNil(result)
    }

    func testClaudeLaunchEnvironmentAndProtectedHandoff() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let key = "test-buyer-key"
        let plan = try ClaudeCodeLauncher.prepare(executable: URL(fileURLWithPath: "/bin/echo"), model: toolModel,
                                                 key: key, home: home,
                                                 inheritedEnvironment: ["HOME": home.path, "PATH": "/usr/bin:/bin", "ANTHROPIC_AUTH_TOKEN": "inherited-secret", "DYLD_INSERT_LIBRARIES": "/bad"])
        let expected = Set(["HOME", "PATH", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "CLAUDE_CONFIG_DIR", "TERM"] + ClaudeCodeLauncher.modelEnvironmentKeys)
        XCTAssertEqual(Set(plan.environment.keys), expected)
        XCTAssertEqual(plan.environment["ANTHROPIC_BASE_URL"], "https://api.malibu.tech")
        XCTAssertEqual(plan.environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"], "1")
        XCTAssertEqual(plan.environment["TERM"], "xterm-256color")
        for name in ClaudeCodeLauncher.modelEnvironmentKeys { XCTAssertEqual(plan.environment[name], toolModel.id) }
        XCTAssertNil(plan.environment["ANTHROPIC_AUTH_TOKEN"])
        XCTAssertFalse(plan.arguments.joined().contains(key))
        XCTAssertEqual(try String(contentsOf: plan.keyHandoff, encoding: .utf8), key)
        XCTAssertEqual(try permissions(plan.keyHandoff), 0o600)
        XCTAssertEqual(try permissions(plan.keyHandoff.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(try permissions(plan.configurationDirectory), 0o700)
        XCTAssertTrue(plan.configurationDirectory.path.hasPrefix(home.appendingPathComponent("Library/Application Support/Malibu/clients/claude-code").path + "/"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path))
        let script = try String(contentsOfFile: try XCTUnwrap(plan.arguments.first), encoding: .utf8)
        XCTAssertFalse(script.contains(key))
        XCTAssertTrue(script.contains("export ANTHROPIC_AUTH_TOKEN"))
    }

    func testClaudeLauncherConsumesKeyOnceWithoutWritingItToOutput() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let plan = try ClaudeCodeLauncher.prepare(executable: URL(fileURLWithPath: "/bin/echo"), model: toolModel,
                                                 key: "do-not-display-this-key", home: home,
                                                 inheritedEnvironment: ["HOME": home.path, "PATH": "/usr/bin:/bin"])
        let process = Process()
        let output = Pipe()
        process.executableURL = plan.executable
        process.arguments = plan.arguments
        process.environment = plan.environment
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(text, "--model vendor/tool-model\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.keyHandoff.path))
        let repeated = Process()
        repeated.executableURL = plan.executable
        repeated.arguments = plan.arguments
        repeated.environment = plan.environment
        repeated.standardOutput = FileHandle.nullDevice
        repeated.standardError = FileHandle.nullDevice
        try repeated.run()
        repeated.waitUntilExit()
        XCTAssertNotEqual(repeated.terminationStatus, 0)
    }

    func testClaudeRefusesMissingToolsContextAndUnsafeStorage() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        for model in [ConnectedModel(id: "plain", contextWindow: 32768, maxOutputTokens: nil),
                      ConnectedModel(id: "short", contextWindow: 8192, maxOutputTokens: nil, supportsTools: true)] {
            XCTAssertThrowsError(try ClaudeCodeLauncher.prepare(executable: URL(fileURLWithPath: "/bin/echo"), model: model, key: "key", home: home))
        }
        let destination = home.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("Library"), withDestinationURL: destination)
        XCTAssertThrowsError(try ClaudeCodeLauncher.prepare(executable: URL(fileURLWithPath: "/bin/echo"), model: toolModel, key: "key", home: home))
    }

    @MainActor
    func testManagedHarnessTabsHaveIndependentOneTimeKeyHandoffs() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let key = "isolated-test-buyer-key"
        let store = ConnectedAppsStore(home: home, keyExists: { true }, readKey: { key })
        store.app = .crush
        store.models = [toolModel]
        store.modelID = toolModel.id
        store.executable = URL(fileURLWithPath: "/bin/echo")
        store.preview()
        XCTAssertTrue(store.canSetup, store.status)
        store.setup()
        XCTAssertTrue(store.status.hasPrefix("Configured."), store.status)

        let first = try store.prepareEmbeddedLaunch(.crush, isolated: true)
        let second = try store.prepareEmbeddedLaunch(.crush, isolated: true)
        let firstDirectory = try XCTUnwrap(first.cleanupDirectory)
        let secondDirectory = try XCTUnwrap(second.cleanupDirectory)
        XCTAssertNotEqual(firstDirectory, secondDirectory)
        XCTAssertNotEqual(first.handoff, second.handoff)
        XCTAssertNotEqual(first.launcher, second.launcher)
        for plan in [first, second] {
            XCTAssertEqual(try String(contentsOf: plan.handoff, encoding: .utf8), key)
            XCTAssertEqual(try permissions(plan.handoff), 0o600)
            XCTAssertEqual(try permissions(plan.handoff.deletingLastPathComponent()), 0o700)
            let script = try String(contentsOf: plan.launcher, encoding: .utf8)
            XCTAssertTrue(script.contains("KEY_FILE=" + ConnectedAppConfiguration.shell(plan.handoff.path)))
            XCTAssertFalse(script.contains(key))
        }
        // Closing one tab must not delete or consume the sibling's credential.
        try FileManager.default.removeItem(at: firstDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.launcher.path))
        XCTAssertEqual(try String(contentsOf: second.handoff, encoding: .utf8), key)
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [second.launcher.path]
        process.environment = try ProcessEnvironmentSanitizer.sanitized(from: ["HOME": home.path, "PATH": "/usr/bin:/bin"])
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.handoff.path))
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertFalse(text.contains(key))
    }

    private var toolModel: ConnectedModel {
        ConnectedModel(id: "vendor/tool-model", contextWindow: 32768, maxOutputTokens: nil, supportsTools: true)
    }
    private func temporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("malibu-terminal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return home
    }
    private func permissions(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue & 0o777
    }
}

private actor ResolverCounter {
    private(set) var commands: [String] = []
    func record(_ command: String) { commands.append(command) }
}
