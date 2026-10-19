import Darwin
import XCTest
@testable import Malibu

final class AgentToolTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentToolTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private var deadline: ContinuousClock.Instant { .now.advanced(by: .seconds(5)) }
    private func call(_ name: String, _ args: [String: String]) throws -> ChatToolCall {
        ChatToolCall(id: "test-call", name: name,
                     arguments: String(data: try JSONSerialization.data(withJSONObject: args), encoding: .utf8)!)
    }
    private func write(_ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: root.appendingPathComponent(name))
    }
    func testReadListAndSearchUseSelectedFolder() async throws {
        try write("notes.txt", "hello\nfind this\n")
        let workspace = try AgentWorkspace(url: root)
        let read = try await workspace.execute(call("read_file", ["path": "notes.txt"]), deadline: deadline)
        XCTAssertEqual(read, "hello\nfind this\n")
        let first = try await workspace.execute(call("list_files", ["path": "."]), deadline: deadline)
        let second = try await workspace.execute(call("list_files", ["path": "."]), deadline: deadline)
        XCTAssertEqual(first, "notes.txt"); XCTAssertEqual(second, first, "Repeated directory reads must not share offsets")
        let matches = try await workspace.execute(call("search_files", ["path": ".", "query": "find"]), deadline: deadline)
        XCTAssertEqual(matches, "notes.txt:2: find this")
    }
    func testSelectedRootAliasResolvesBeforeNoFollowTraversal() async throws {
        let selected = root.appendingPathComponent("selected")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
        try Data("selected root".utf8).write(to: selected.appendingPathComponent("note.txt"))
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: selected)
        let workspace = try AgentWorkspace(url: alias)
        let result = try await workspace.execute(call("read_file", ["path": "note.txt"]), deadline: deadline)
        XCTAssertEqual(result, "selected root")
    }
    func testRejectsTraversalSymlinksAndSpecialFiles() async throws {
        try write("safe.txt", "safe")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "/etc")
        let fifo = root.appendingPathComponent("pipe").path
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)
        let workspace = try AgentWorkspace(url: root)
        for path in ["../outside", "/etc/passwd", "link/passwd", "pipe", "a/../safe.txt", "./safe.txt", "a//b"] {
            do {
                _ = try await workspace.execute(call("read_file", ["path": path]), deadline: deadline)
                XCTFail("Accepted unsafe path \(path)")
            } catch { XCTAssertEqual(error as? ChatFailure, .unsafePath) }
        }
    }
    func testIntermediateSymlinkSwapCannotEscape() async throws {
        let child = root.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let workspace = try AgentWorkspace(url: root, beforeOpen: { component in
            guard component == "child" else { return }
            try? FileManager.default.removeItem(at: child)
            try? FileManager.default.createSymbolicLink(atPath: child.path, withDestinationPath: "/etc")
        })
        do {
            _ = try await workspace.execute(call("read_file", ["path": "child/passwd"]), deadline: deadline)
            XCTFail("Symlink swap escaped the selected directory")
        } catch { XCTAssertEqual(error as? ChatFailure, .unsafePath) }
    }
    func testRootSelectionRemainsBoundToOriginalDirectoryAfterRename() async throws {
        try write("safe.txt", "original")
        let workspace = try AgentWorkspace(url: root)
        let moved = root.appendingPathExtension("moved")
        try FileManager.default.moveItem(at: root, to: moved)
        defer { try? FileManager.default.removeItem(at: moved) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try write("safe.txt", "replacement")
        let result = try await workspace.execute(call("read_file", ["path": "safe.txt"]), deadline: deadline)
        XCTAssertEqual(result, "original")
    }
    func testSizeDeadlineAndCancellationAreEnforced() async throws {
        try write("large.txt", String(repeating: "x", count: AgentWorkspace.fileByteLimit + 1))
        let workspace = try AgentWorkspace(url: root)
        do {
            _ = try await workspace.execute(call("read_file", ["path": "large.txt"]), deadline: deadline)
            XCTFail("Accepted oversized file")
        } catch { XCTAssertEqual(error as? ChatFailure, .limit) }
        do {
            _ = try await workspace.execute(call("list_files", ["path": "."]), deadline: .now.advanced(by: .seconds(-1)))
            XCTFail("Accepted expired tool")
        } catch { XCTAssertEqual(error as? ChatFailure, .timeout) }
        let request = try call("list_files", ["path": "."])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await workspace.execute(request, deadline: .now.advanced(by: .seconds(5)))
        }
        do { _ = try await task.value; XCTFail("Ignored cancellation") } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testStrictSchemaAndClosedToolRegistry() throws {
        for invalid in [
            ChatToolCall(id: "1", name: "shell", arguments: "{\"command\":\"pwd\"}"),
            ChatToolCall(id: "1", name: "read_file", arguments: "{\"path\":\"x\",\"extra\":\"y\"}"),
            ChatToolCall(id: "1", name: "read_file", arguments: "{\"path\":3}"),
            ChatToolCall(id: "1", name: "read_file", arguments: "{\"path\":\"a\",\"path\":\"b\"}"),
            ChatToolCall(id: "1", name: "search_files", arguments: "{\"path\":\".\",\"query\":\"\"}")
        ] { XCTAssertThrowsError(try AgentWorkspace.arguments(for: invalid)) }
        let names = AgentWorkspace.schemas.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertEqual(Set(names), ["read_file", "list_files", "search_files", "finish_answer"])
    }
}
