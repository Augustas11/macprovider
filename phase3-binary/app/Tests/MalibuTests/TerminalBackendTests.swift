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
            return command == "claude" ? HarnessExecutable(url: URL(fileURLWithPath: "/bin/echo"), loginPath: "/usr/bin:/bin") : nil
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
                                                 endpoint: try ManagedPrivacyEndpoint(localToken: key), home: home,
                                                 inheritedEnvironment: ["HOME": home.path, "PATH": "/usr/bin:/bin", "ANTHROPIC_AUTH_TOKEN": "inherited-secret", "DYLD_INSERT_LIBRARIES": "/bad"])
        let expected = Set(["HOME", "PATH", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "CLAUDE_CONFIG_DIR", "TERM"] + ClaudeCodeLauncher.modelEnvironmentKeys)
        XCTAssertEqual(Set(plan.environment.keys), expected)
        XCTAssertEqual(plan.environment["ANTHROPIC_BASE_URL"], "http://127.0.0.1:11435/")
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
                                                 endpoint: try ManagedPrivacyEndpoint(localToken: "do-not-display-this-key"), home: home,
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
            XCTAssertThrowsError(try ClaudeCodeLauncher.prepare(executable: URL(fileURLWithPath: "/bin/echo"), model: model, endpoint: try ManagedPrivacyEndpoint(localToken: "key"), home: home))
        }
        let destination = home.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("Library"), withDestinationURL: destination)
        XCTAssertThrowsError(try ClaudeCodeLauncher.prepare(executable: URL(fileURLWithPath: "/bin/echo"), model: toolModel, endpoint: try ManagedPrivacyEndpoint(localToken: "key"), home: home))
    }

    @MainActor
    func testManagedHarnessTabsHaveIndependentOneTimeKeyHandoffs() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let key = "isolated-local-token"
        let store = ConnectedAppsStore(home: home, keyExists: { true }, readKey: { key })
        store.app = .crush
        store.models = [toolModel]
        store.modelID = toolModel.id
        store.executable = URL(fileURLWithPath: "/bin/echo")
        store.preview()
        XCTAssertTrue(store.canSetup, store.status)
        store.setup()
        XCTAssertTrue(store.status.hasPrefix("Configured."), store.status)

        let first = try store.prepareEmbeddedLaunch(.crush, isolated: true, endpoint: ManagedPrivacyEndpoint(localToken: key))
        let second = try store.prepareEmbeddedLaunch(.crush, isolated: true, endpoint: ManagedPrivacyEndpoint(localToken: key))
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

    func testLoginPathValidationRejectsUnsafeEntries() {
        for path in [".:/usr/bin:/bin", "/usr/bin::/bin", "bin:/usr/bin", "/usr/bin:/bin:", "", "/usr/bin\n/bin"] {
            XCTAssertNil(HarnessCatalog.validatedLoginPath(path), path)
            XCTAssertNil(HarnessCatalog.parseResolution("/bin/echo\n" + path + "\n"), path)
        }
        XCTAssertEqual(HarnessCatalog.validatedLoginPath("/opt/homebrew/bin:/usr/bin:/bin"), "/opt/homebrew/bin:/usr/bin:/bin")
        XCTAssertNil(HarnessCatalog.parseResolution("startup noise\n/bin/echo\n/usr/bin:/bin\n"))
    }

    func testLoginProbePathReachesEnvNodeClaudeAndManagedLaunchers() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appendingPathComponent("login-bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let harness = bin.appendingPathComponent("claude")
        try Data("#!/usr/bin/env node\n".utf8).write(to: harness)
        try Data("#!/bin/sh\nprintf 'login-node-ran\\n'\n".utf8).write(to: bin.appendingPathComponent("node"))
        XCTAssertEqual(chmod(harness.path, 0o700), 0)
        XCTAssertEqual(chmod(bin.appendingPathComponent("node").path, 0o700), 0)
        let path = bin.path + ":/usr/bin:/bin"
        try Data(("export PATH=" + ConnectedAppConfiguration.shell(path) + "\n").utf8).write(to: home.appendingPathComponent(".zprofile"))
        let inherited = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let detected = await HarnessCatalog.resolve("claude", environment: inherited)
        let resolution = try XCTUnwrap(detected)
        XCTAssertEqual(resolution.url.resolvingSymlinksInPath(), harness.resolvingSymlinksInPath())
        XCTAssertEqual(resolution.loginPath, path)
        let claude = try ClaudeCodeLauncher.prepare(executable: resolution.url, model: toolModel, endpoint: try ManagedPrivacyEndpoint(localToken: "private-key"),
                                                   loginPath: resolution.loginPath, home: home, inheritedEnvironment: inherited)
        let managedHandoff = home.appendingPathComponent("managed.key")
        try Data("private-key".utf8).write(to: managedHandoff)
        let managed = home.appendingPathComponent("managed.command")
        try ConnectedAppConfiguration.launcher(app: .crush, executable: resolution.url,
            config: home.appendingPathComponent("crush.json"), model: toolModel, keyHandoff: managedHandoff).write(to: managed)
        let managedEnvironment = try HarnessCatalog.launchEnvironment(loginPath: resolution.loginPath, inherited: inherited)
        for (script, environment) in [(claude.arguments[0], claude.environment), (managed.path, managedEnvironment)] {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [script]
            process.environment = environment
            process.standardOutput = output
            process.standardError = output
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertEqual(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), "login-node-ran\n")
        }
    }

    func testManagedHandoffIgnoresRepositoryCatAndRmAndAbortsOnReadFailure() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        for command in ["cat", "rm"] {
            let planted = home.appendingPathComponent(command)
            try Data("#!/bin/sh\nprintf 'intercepted' > intercepted\nexit 0\n".utf8).write(to: planted)
            XCTAssertEqual(chmod(planted.path, 0o700), 0)
        }
        let handoff = home.appendingPathComponent("buyer.key")
        let launcher = home.appendingPathComponent("Launch.command")
        try ConnectedAppConfiguration.launcher(app: .crush, executable: URL(fileURLWithPath: "/bin/echo"),
            config: home.appendingPathComponent("crush.json"), model: toolModel, keyHandoff: handoff).write(to: launcher)
        for kind in ["readable", "unreadable", "fifo"] {
            let readable = kind == "readable"
            if kind == "fifo" { XCTAssertEqual(mkfifo(handoff.path, 0o600), 0) }
            else {
                try Data("never-output-this-key".utf8).write(to: handoff)
                if kind == "unreadable" { XCTAssertEqual(chmod(handoff.path, 0), 0) }
            }
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [launcher.path]
            process.environment = ["PATH": ".:/usr/bin:/bin"]
            process.currentDirectoryURL = home
            process.standardOutput = output
            process.standardError = output
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus == 0, readable)
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTAssertFalse(text.contains("never-output-this-key"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("intercepted").path))
            if kind == "fifo" { try FileManager.default.removeItem(at: handoff) }
            else { XCTAssertFalse(FileManager.default.fileExists(atPath: handoff.path)) }
        }
    }

    private var toolModel: ConnectedModel {
        ConnectedModel(id: "vendor/tool-model", contextWindow: 32768, maxOutputTokens: nil, supportsTools: true)
    }
    private func temporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("malibu-terminal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Foundation normalizes /private/var back to the /var symlink on macOS;
        // retain POSIX realpath so production no-follow traversal sees real ancestors.
        let resolved = try XCTUnwrap(realpath(home.path, nil))
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }
    private func permissions(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue & 0o777
    }
}

private actor ResolverCounter {
    private(set) var commands: [String] = []
    func record(_ command: String) { commands.append(command) }
}
