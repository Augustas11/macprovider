import Darwin
import SwiftTerm
import XCTest
@testable import Malibu

@MainActor
final class TerminalSessionTests: XCTestCase {
    override func tearDown() async throws {
        await TerminalSession.terminateAll()
        TerminalSession.resetTerminationForTesting()
        try await super.tearDown()
    }

    func testQuitRejectsLaunchDuringSuspendedCleanup() async throws {
        let view = EmbeddedProcessTerminalView(frame: .init(x: 0, y: 0, width: 640, height: 400))
        view.startProcess(executable: "/bin/sh", args: ["-c", "trap '' HUP TERM; exec /bin/sleep 600"], environment: ["PATH=/usr/bin:/bin"])
        let pid = view.process.shellPid
        XCTAssertGreaterThan(pid, 1)
        guard pid > 1 else { return }
        defer { _ = kill(-pid, SIGKILL) }
        try await Task.sleep(for: .milliseconds(150))
        let owner = TerminalSession(harness: .shell)
        owner.adoptTestProcessGroup(pid)
        let quit = Task { await TerminalSession.terminateAll() }
        while !TerminalSession.isTerminating { await Task.yield() }
        XCTAssertEqual(kill(pid, 0), 0, "Quit cleanup must still be pending")
        let late = TerminalSession(harness: .shell)
        late.start(executable: URL(fileURLWithPath: "/bin/sleep"), model: nil)
        XCTAssertFalse(late.started)
        XCTAssertNil(late.terminalView)
        XCTAssertTrue(late.message?.contains("quitting") == true)
        await quit.value
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testRepeatedNormalExitTabsReturnDescriptorCountToBaseline() async throws {
        try await assertDescriptorsReturnToBaseline(forceClose: false)
    }

    func testRepeatedForcedCloseTabsReturnDescriptorCountToBaseline() async throws {
        try await assertDescriptorsReturnToBaseline(forceClose: true)
    }

    private func openDescriptorCount() -> Int {
        let bytes = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
        var entries = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.stride + 32)
        let count = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, &entries, Int32(entries.count * MemoryLayout<proc_fdinfo>.stride))
        return Int(count) / MemoryLayout<proc_fdinfo>.stride
    }

    private func assertDescriptorsReturnToBaseline(forceClose: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = folder.appendingPathComponent("test-shell")
        try Data((forceClose ? "#!/bin/sh\nexec /bin/sleep 600\n" : "#!/bin/sh\nexit 0\n").utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let tabs = TerminalTabs()
        // Warm up lazy AppKit/Dispatch resources before recording the baseline.
        for iteration in 0..<9 {
            let baseline = openDescriptorCount()
            let session = try XCTUnwrap(tabs.add(.shell))
            session.start(executable: executable, model: nil)
            XCTAssertTrue(session.started)
            let view = try XCTUnwrap(session.terminalView)
            if !forceClose {
                for _ in 0..<200 {
                    if !view.process.running && view.process.childfd == -1 { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                XCTAssertFalse(view.process.running)
                XCTAssertEqual(view.process.childfd, -1)
                if iteration > 0 { XCTAssertEqual(openDescriptorCount(), baseline, "Normal exit leaked a descriptor") }
            }
            tabs.close(session)
            // A repeated shutdown must never close an unrelated reused fd.
            view.process.closeIO()
            try await Task.sleep(for: .milliseconds(3200))
            if iteration > 0 { XCTAssertEqual(openDescriptorCount(), baseline, "Tab \(iteration) leaked a descriptor") }
            let sentinel = Darwin.open("/dev/null", O_RDONLY)
            XCTAssertGreaterThanOrEqual(sentinel, 0)
            view.process.closeIO()
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertNotEqual(fcntl(sentinel, F_GETFD), -1, "Repeated shutdown closed a reused descriptor")
            _ = Darwin.close(sentinel)
        }
    }

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

    func testPTYAdapterPreservesDirectoryArgumentsEnvironmentInputAndResize() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("malibu-'$()-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let originalDirectory = FileManager.default.currentDirectoryPath
        let view = EmbeddedProcessTerminalView(frame: .init(x: 0, y: 0, width: 640, height: 400))
        let ended = expectation(description: "PTY reports exit")
        view.onTermination = { status in
            XCTAssertEqual(status, 0)
            ended.fulfill()
        }
        let argument = "literal ' $() ; argument"
        view.startProcess(executable: "/bin/sh", args: ["-c", "read -r line; printf '%s\\n' \"$PWD\" \"$1\" \"$ADAPTER_TEST\" \"$line\" > result", "adapter-test", argument],
                          environment: ["TERM=xterm-256color", "PATH=/usr/bin:/bin", "ADAPTER_TEST=isolated"],
                          currentDirectory: folder.path)
        let pid = view.process.shellPid
        guard pid > 1 else { XCTFail("PTY did not start"); return }
        defer { _ = kill(-pid, SIGKILL) }
        XCTAssertEqual(FileManager.default.currentDirectoryPath, originalDirectory)
        view.getTerminal().resize(cols: 93, rows: 31)
        view.sizeChanged(source: view, newCols: 93, newRows: 31)
        var size = winsize()
        XCTAssertEqual(ioctl(view.process.childfd, TIOCGWINSZ, &size), 0)
        XCTAssertEqual(size.ws_col, 93)
        XCTAssertEqual(size.ws_row, 31)
        view.send(source: view, data: Array("typed input\n".utf8)[...])
        await fulfillment(of: [ended], timeout: 5)
        let result = try String(contentsOf: folder.appendingPathComponent("result"), encoding: .utf8)
        XCTAssertEqual(result, "\(folder.resolvingSymlinksInPath().path)\n\(argument)\nisolated\ntyped input\n")
    }

    func testQuitTerminatesActiveSession() async throws {
        let view = EmbeddedProcessTerminalView(frame: .init(x: 0, y: 0, width: 640, height: 400))
        view.startProcess(executable: "/bin/sleep", args: ["30"], environment: ["PATH=/usr/bin:/bin"])
        let pid = view.process.shellPid
        guard pid > 1 else { XCTFail("PTY did not start"); return }
        defer { _ = kill(-pid, SIGKILL) }
        for _ in 0..<50 {
            if getpgid(pid) == pid { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let session = TerminalSession(harness: .shell)
        session.adoptTestProcessGroup(pid)
        await TerminalSession.terminateAll()
        XCTAssertEqual(kill(-pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
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
        let view = EmbeddedProcessTerminalView(frame: .init(x: 0, y: 0, width: 640, height: 400))
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
        let view = EmbeddedProcessTerminalView(frame: .init(x: 0, y: 0, width: 640, height: 400))
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
    func testCloseTerminatesForegroundAndBackgroundJobControlGroups() async throws {
        try await assertJobControlChildrenTerminate(onQuit: false)
    }

    func testQuitTerminatesForegroundAndBackgroundJobControlGroups() async throws {
        try await assertJobControlChildrenTerminate(onQuit: true)
    }

    private func assertJobControlChildrenTerminate(onQuit: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let backgroundFile = folder.appendingPathComponent("background")
        let foregroundFile = folder.appendingPathComponent("foreground")
        let view = EmbeddedProcessTerminalView(frame: .init(x: 0, y: 0, width: 640, height: 400))
        // A trailing wait prevents zsh from exec-optimizing the foreground
        // command into its own PID/PGID; both jobs must exercise job control.
        let command = """
        /bin/sh -c 'trap "" HUP; echo $$ > "$1"; exec /bin/sleep 30' child "$1/background" &
        /bin/sh -c 'trap "" HUP; echo $$ > "$1"; exec /bin/sleep 30' child "$1/foreground"
        wait
        """
        view.startProcess(executable: "/bin/zsh", args: ["-f", "-i", "-m", "-c", command, "fixture", folder.path],
                          environment: ["TERM=xterm-256color", "PATH=/usr/bin:/bin"])
        let shell = view.process.shellPid
        guard shell > 1 else { XCTFail("PTY did not start"); return }
        var children: [pid_t] = []
        defer {
            for pid in children { _ = kill(pid, SIGKILL) }
            _ = kill(-shell, SIGKILL)
        }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: backgroundFile.path),
               FileManager.default.fileExists(atPath: foregroundFile.path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        children = try [backgroundFile, foregroundFile].map {
            let value = try String(contentsOf: $0, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            return try XCTUnwrap(pid_t(value))
        }
        XCTAssertNotEqual(getpgid(children[0]), shell)
        XCTAssertNotEqual(getpgid(children[1]), shell)
        XCTAssertNotEqual(getpgid(children[0]), getpgid(children[1]))
        for pid in children { XCTAssertEqual(getsid(pid), shell) }
        let session = TerminalSession(harness: .shell)
        session.adoptTestProcessGroup(shell)
        if onQuit {
            await TerminalSession.terminateAll()
        } else {
            session.close()
            try await Task.sleep(for: .milliseconds(300))
            for pid in children { XCTAssertEqual(kill(pid, 0), 0, "HUP-resistant job survives until escalation") }
            try await Task.sleep(for: .seconds(3.2))
        }
        for pid in children {
            XCTAssertEqual(kill(pid, 0), -1, "Job-control child must die even after its shell exits")
            XCTAssertEqual(errno, ESRCH)
        }
    }

}
