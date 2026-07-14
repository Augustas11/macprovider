import XCTest
@testable import Malibu

final class ProviderCredentialHandoffRunnerTests: XCTestCase {
    func testHandoffImportsThenVerifiesWithFreshInvocation() async throws {
        let recorder = HandoffInvocationRecorder(exitCodes: [0, 0])
        let executable = URL(fileURLWithPath: "/tmp/macprovider-cli")
        let config = URL(fileURLWithPath: "/tmp/config with spaces.yaml")

        try await ProviderCredentialHandoffRunner.migrate(
            configURL: config,
            executableURL: executable,
            run: { executable, arguments in
                await recorder.run(executable: executable, arguments: arguments)
            }
        )

        let invocations = await recorder.invocations
        XCTAssertEqual(invocations.count, 2)
        XCTAssertEqual(invocations[0].executable, executable)
        XCTAssertEqual(invocations[0].arguments, ["credentials", "import", "--config", config.path])
        XCTAssertEqual(invocations[1].arguments, ["credentials", "verify", "--config", config.path])
    }

    func testHandoffDoesNotVerifyAfterImportFailure() async throws {
        let recorder = HandoffInvocationRecorder(exitCodes: [17])

        do {
            try await ProviderCredentialHandoffRunner.migrate(
                configURL: URL(fileURLWithPath: "/tmp/config.yaml"),
                executableURL: URL(fileURLWithPath: "/tmp/macprovider-cli"),
                run: { executable, arguments in
                    await recorder.run(executable: executable, arguments: arguments)
                }
            )
            XCTFail("expected import failure")
        } catch let error as ProviderCredentialHandoffRunner.Error {
            XCTAssertEqual(error, .importFailed(17))
        }

        let invocationCount = await recorder.invocations.count
        XCTAssertEqual(invocationCount, 1)
    }

    func testHandoffReportsFreshProcessVerificationFailure() async throws {
        let recorder = HandoffInvocationRecorder(exitCodes: [0, 23])

        do {
            try await ProviderCredentialHandoffRunner.migrate(
                configURL: URL(fileURLWithPath: "/tmp/config.yaml"),
                executableURL: URL(fileURLWithPath: "/tmp/macprovider-cli"),
                run: { executable, arguments in
                    await recorder.run(executable: executable, arguments: arguments)
                }
            )
            XCTFail("expected verification failure")
        } catch let error as ProviderCredentialHandoffRunner.Error {
            XCTAssertEqual(error, .freshProcessVerificationFailed(23))
        }

        let invocationCount = await recorder.invocations.count
        XCTAssertEqual(invocationCount, 2)
    }

    func testResolveInstalledExecutableUsesManifestCustomPath() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("credential-handoff-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let executable = home.appendingPathComponent("custom/bin/macprovider-cli")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(atPath: executable.path, contents: Data("test".utf8)))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let manifest = home.appendingPathComponent(
            "Library/Application Support/macprovider/install_manifest.json"
        )
        try FileManager.default.createDirectory(
            at: manifest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONSerialization.data(withJSONObject: ["binary_path": executable.path])
            .write(to: manifest)

        XCTAssertEqual(
            try ProviderCredentialHandoffRunner.resolveInstalledExecutable(home: home),
            executable.standardizedFileURL
        )
    }

    func testResolveInstalledExecutableRejectsRelativeManifestPath() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("credential-handoff-relative-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let manifest = home.appendingPathComponent(
            "Library/Application Support/macprovider/install_manifest.json"
        )
        try FileManager.default.createDirectory(
            at: manifest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONSerialization.data(withJSONObject: ["binary_path": "relative/macprovider-cli"])
            .write(to: manifest)

        XCTAssertThrowsError(
            try ProviderCredentialHandoffRunner.resolveInstalledExecutable(home: home)
        ) { error in
            XCTAssertEqual(
                error as? ProviderCredentialHandoffRunner.Error,
                .invalidCLI("install manifest binary_path is not absolute")
            )
        }
    }

    func testProcessRunnerTimesOutAndTerminatesChild() async throws {
        do {
            _ = try await ProviderCredentialHandoffRunner.runProcess(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["2"],
                timeout: 0.05
            )
            XCTFail("expected timeout")
        } catch let error as ProviderCredentialHandoffRunner.Error {
            XCTAssertEqual(error, .timedOut)
        }
    }
}

private actor HandoffInvocationRecorder {
    struct Invocation: Equatable {
        let executable: URL
        let arguments: [String]
    }

    private(set) var invocations: [Invocation] = []
    private var exitCodes: [Int32]

    init(exitCodes: [Int32]) {
        self.exitCodes = exitCodes
    }

    func run(executable: URL, arguments: [String]) -> Int32 {
        invocations.append(Invocation(executable: executable, arguments: arguments))
        return exitCodes.isEmpty ? 0 : exitCodes.removeFirst()
    }
}
