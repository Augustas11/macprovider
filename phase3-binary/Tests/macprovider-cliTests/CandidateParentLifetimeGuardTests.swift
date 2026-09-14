import Darwin
import Foundation
import XCTest
@testable import macprovider_cli

final class CandidateParentLifetimeGuardTests: XCTestCase {
    func testCandidateArgumentsOptIntoParentGuardWithoutChangingManualArguments() throws {
        let arguments = try CandidateProviderRunner.serveArguments(model: "fixture", port: 18080,
            kvBits: nil, maxContext: nil, maxBatch: nil, parentPID: getpid())
        XCTAssertTrue(arguments.contains("--candidate-parent-pid"))
        XCTAssertTrue(arguments.contains(String(getpid())))
        let manual = try CandidateProviderRunner.serveArguments(model: "fixture", port: 18080,
            kvBits: nil, maxContext: nil, maxBatch: nil)
        XCTAssertFalse(manual.contains("--candidate-parent-pid"))
        XCTAssertThrowsError(try ServeCommand.parse(["--candidate-parent-pid", "123"]))
        XCTAssertThrowsError(try ServeCommand.parse(["--candidate-parent-pid", "123", "--no-join"]))
        XCTAssertNoThrow(try ServeCommand.parse(["--candidate-parent-pid", "123", "--no-join", "--autotune-candidate"]))
    }

    func testActualParentDeathTerminatesGuardedChild() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CandidateParentGuardTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let process = helper(role: "parent", root: root)
        try process.run()
        var parentPID: Int32?
        var childPID: Int32?
        defer {
            if let parentPID, kill(parentPID, 0) == 0 { kill(parentPID, SIGKILL) }
            if let childPID, kill(childPID, 0) == 0 { kill(childPID, SIGKILL) }
            if process.isRunning { process.terminate() }
        }
        let readyDeadline = Date().addingTimeInterval(15)
        while Date() < readyDeadline {
            parentPID = (try? String(contentsOf: root.appendingPathComponent("parent.pid"))).flatMap(Int32.init)
            childPID = (try? String(contentsOf: root.appendingPathComponent("child.pid"))).flatMap(Int32.init)
            if parentPID != nil && childPID != nil { break }
            usleep(50_000)
        }
        let owner = try XCTUnwrap(parentPID, "guard parent helper did not start")
        let child = try XCTUnwrap(childPID, "guard child helper did not start")
        XCTAssertEqual(kill(child, 0), 0)
        XCTAssertEqual(kill(owner, SIGKILL), 0)
        let stoppedDeadline = Date().addingTimeInterval(10)
        while Date() < stoppedDeadline, kill(child, 0) == 0 { usleep(50_000) }
        XCTAssertNotEqual(kill(child, 0), 0, "guarded child survived actual parent death")
    }

    // Executed only by a fresh xctest subprocess; no forked Swift/libdispatch
    // state and no model download are involved in this OS-parent relation test.
    func testSubprocessEntry() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let role = environment["MACPROVIDER_GUARD_TEST_ROLE"],
              let path = environment["MACPROVIDER_GUARD_TEST_ROOT"] else { return }
        let root = URL(fileURLWithPath: path)
        if role == "parent" {
            try String(getpid()).write(to: root.appendingPathComponent("parent.pid"), atomically: true, encoding: .utf8)
            let child = helper(role: "child", root: root, parentPID: getpid())
            try child.run()
            child.waitUntilExit()
            _exit(child.terminationStatus)
        }
        guard role == "child", let parent = environment["MACPROVIDER_GUARD_TEST_PARENT"].flatMap(Int32.init) else { _exit(71) }
        let lifetime = CandidateParentLifetimeGuard(expectedParentPID: parent)
        try String(getpid()).write(to: root.appendingPathComponent("child.pid"), atomically: true, encoding: .utf8)
        _ = withExtendedLifetime(lifetime) { sleep(30) }
        _exit(72)
    }

    private func helper(role: String, root: URL, parentPID: Int32? = nil) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xctest", "-XCTest", "macprovider_cliTests.CandidateParentLifetimeGuardTests/testSubprocessEntry", Bundle(for: Self.self).bundlePath]
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": root.path, "TMPDIR": root.path,
            "MACPROVIDER_GUARD_TEST_ROLE": role, "MACPROVIDER_GUARD_TEST_ROOT": root.path,
            "MACPROVIDER_GUARD_TEST_PARENT": String(parentPID ?? 0)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }
}
