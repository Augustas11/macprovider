import XCTest
@testable import Malibu

@MainActor
final class ProviderLogTailTests: XCTestCase {
    func testMergedTailIncludesStderrAndStdout() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let stderr = root.appendingPathComponent("macprovider.err.log")
        let stdout = root.appendingPathComponent("macprovider.out.log")
        try "stderr-line\n".data(using: .utf8)?.write(to: stderr)
        try "stdout-line\n".data(using: .utf8)?.write(to: stdout)

        let paths = ProviderPaths(
            configFile: root.appendingPathComponent("config.yaml"),
            controlSocket: root.appendingPathComponent("agent.sock"),
            cliLogFile: root.appendingPathComponent("malibu-cli.log"),
            launchdStdoutLog: stdout,
            launchdStderrLog: stderr,
            appSupport: root.appendingPathComponent("Malibu"),
            appMarkerFile: root.appendingPathComponent(".installed-by-app"),
            onboardingStateFile: root.appendingPathComponent("onboarding.json"),
            downloadsDirectory: root.appendingPathComponent("Downloads")
        )

        let tail = ProviderLogTail(capacity: 20)
        tail.start(paths: paths)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(tail.lines.contains("stderr-line"))
        XCTAssertTrue(tail.lines.contains("stdout-line"))
    }
}
