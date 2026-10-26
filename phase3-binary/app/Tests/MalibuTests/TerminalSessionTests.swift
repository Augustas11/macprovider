import Darwin
import SwiftTerm
import XCTest
@testable import Malibu

@MainActor
final class TerminalSessionTests: XCTestCase {
    func testHarnessDoesNotCreateProcessWithoutBuyerKey() {
        let session = TerminalSession(harness: .claudeCode)
        session.start(executable: URL(fileURLWithPath: "/bin/sleep"), model: nil, hasKey: { false }, readKey: {
            XCTFail("A missing key must not be read")
            return ""
        })
        XCTAssertFalse(session.started)
        XCTAssertNil(session.terminalView)
        XCTAssertEqual(session.message, "Add a buyer key in Other apps")
    }

    func testTabsAreCappedAtEightAndCloseUpdatesSelection() {
        let tabs = TerminalTabs()
        for _ in 0..<8 { XCTAssertNotNil(tabs.add(.shell)) }
        XCTAssertNil(tabs.add(.shell))
        XCTAssertEqual(tabs.sessions.count, 8)
        let last = tabs.sessions.last!
        tabs.close(last)
        XCTAssertEqual(tabs.sessions.count, 7)
        XCTAssertEqual(tabs.selection, tabs.sessions.last?.id)
        XCTAssertNotNil(tabs.add(.shell))
        for session in tabs.sessions { tabs.close(session) }
    }

    func testProductionStartCanImmediatelyCloseItsSleepChild() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = folder.appendingPathComponent("sleep-shell")
        try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let session = TerminalSession(harness: .shell)
        session.start(executable: executable, model: nil)
        XCTAssertTrue(session.started)
        let pid = session.terminalView?.process.shellPid ?? 0
        XCTAssertGreaterThan(pid, 1)
        session.close()
        try await Task.sleep(for: .seconds(3.3))
        if pid > 1 { XCTAssertEqual(kill(-pid, 0), -1) }
    }

    func testWindowWorkspacePreservesTabsAcrossDestinationRecreation() {
        let workspace = TerminalWorkspace()
        let navigation = MalibuNavigation()
        let tab = workspace.tabs.add(.shell)!
        navigation.show(.terminal)
        _ = TerminalScreen(workspace: workspace)
        navigation.show(.chat)
        navigation.show(.terminal)
        _ = TerminalScreen(workspace: workspace)
        XCTAssertTrue(workspace.tabs.sessions.first === tab)
        workspace.tabs.close(tab)
    }

    func testCloseEscalatesWhenLeaderExitsButSleepIgnoresHangup() async throws {
        let view = LocalProcessTerminalView(frame: .init(x: 0, y: 0, width: 640, height: 400))
        view.startProcess(executable: "/bin/sh", args: ["-c", "trap 'exit 0' HUP; /bin/sh -c 'trap \"\" HUP; exec /bin/sleep 30' & wait"],
                          environment: ["TERM=xterm-256color", "PATH=/usr/bin:/bin"])
        let pid = view.process.shellPid
        guard pid > 1 else { XCTFail("PTY did not start"); return }
        defer { _ = kill(-pid, SIGKILL) }
        try await Task.sleep(for: .milliseconds(200))
        let session = TerminalSession(harness: .shell)
        session.adoptTestProcessGroup(pid)
        session.close()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(kill(-pid, 0), 0, "The HUP-ignoring child must survive until escalation")
        try await Task.sleep(for: .seconds(3.2))
        XCTAssertEqual(kill(-pid, 0), -1)
    }

    func testCloseTerminatesAnIsolatedSleepProcessGroup() async throws {
        let view = LocalProcessTerminalView(frame: .init(x: 0, y: 0, width: 640, height: 400))
        view.startProcess(executable: "/bin/sleep", args: ["30"],
                          environment: ["TERM=xterm-256color", "PATH=/usr/bin:/bin"])
        let pid = view.process.shellPid
        XCTAssertGreaterThan(pid, 1)
        guard pid > 1 else { return }
        defer { _ = kill(-pid, SIGKILL) }
        // forkpty establishes the child's process group before exec.
        for _ in 0..<50 {
            if getpgid(pid) == pid { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(getpgid(pid), pid)
        let session = TerminalSession(harness: .shell)
        session.adoptTestProcessGroup(pid)
        session.close()
        try await Task.sleep(for: .seconds(3.3))
        XCTAssertEqual(kill(-pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }
}
