import Darwin
import Foundation
import XCTest
@testable import Malibu

final class HarnessCatalogProcessTests: XCTestCase {
    func testTimeoutTerminatesLoginStartupChild() async throws {
        try await assertStartupChildTerminates(overflow: false)
    }

    func testOutputOverflowTerminatesLoginStartupChild() async throws {
        try await assertStartupChildTerminates(overflow: true)
    }

    private func assertStartupChildTerminates(overflow: Bool) async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("probe-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let pidFile = home.appendingPathComponent("child.pid")
        // Ignore TERM as well as HUP to exercise the final group escalation.
        var script = """
        /bin/sh -c 'trap "" HUP TERM; echo $$ > "$1"; exec /bin/sleep 600' child "$HOME/child.pid" &
        while [[ ! -s "$HOME/child.pid" ]]; do /bin/sleep 0.01; done
        """
        script += overflow ? "\nwhile true; do printf '%0200d\\n' 0; done\n" : "\nwait\n"
        try Data(script.utf8).write(to: home.appendingPathComponent(".zprofile"))
        let result = await HarnessCatalog.resolve("claude", environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"])
        XCTAssertNil(result)
        let pid = try XCTUnwrap(pid_t(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { _ = kill(pid, SIGKILL) }
        for _ in 0..<100 {
            if kill(pid, 0) == -1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(kill(pid, 0), -1, "Login startup sleep survived probe cleanup")
        XCTAssertEqual(errno, ESRCH)
    }
}
