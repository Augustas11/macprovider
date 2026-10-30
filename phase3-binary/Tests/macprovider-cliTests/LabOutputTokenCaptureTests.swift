#if DEBUG || MACPROVIDER_LAB_HARNESS
import Darwin
import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

final class LabOutputTokenCaptureTests: XCTestCase {
    func testUnsetAndEmptyPathAreNoOp() throws {
        let request = try request()
        XCTAssertNoThrow(try LabOutputTokenCapture.record(request: request, tokenIDs: [4, 2], environment: [:]))
        XCTAssertNoThrow(try LabOutputTokenCapture.record(request: request, tokenIDs: [4, 2],
            environment: ["MACPROVIDER_LAB_TOKEN_CAPTURE": ""]))
    }

    func testRelativeAndNulPathsFailClosed() throws {
        let request = try request()
        for path in ["relative.jsonl", "/private/tmp/capture\0ignored.jsonl"] {
            XCTAssertThrowsError(try LabOutputTokenCapture.record(request: request, tokenIDs: [7],
                environment: ["MACPROVIDER_LAB_TOKEN_CAPTURE": path]))
        }
    }

    func testCreatesPrivateFileWithExactIDsAndCompatibleSchema() throws {
        let root = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("tokens.jsonl")
        let ids = [42, 0, 9001, 42, 3]
        try LabOutputTokenCapture.record(request: request().withRequestID("capture-exact"), tokenIDs: ids,
            environment: environment(file))
        try LabOutputTokenCapture.record(request: request(), tokenIDs: [], environment: environment(file))
        var info = stat()
        XCTAssertEqual(lstat(file.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o7777, 0o600)
        XCTAssertEqual(info.st_nlink, 1)
        let records = try records(file)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(Set(records[0].keys), Set(["schema", "request_id", "model", "output_token_ids"]))
        XCTAssertEqual(records[0]["schema"] as? String, "macprovider.lab-output-tokens.v1")
        XCTAssertEqual(records[0]["request_id"] as? String, "capture-exact")
        XCTAssertEqual(records[0]["model"] as? String, "lab/model")
        XCTAssertEqual(records[0]["output_token_ids"] as? [Int], ids)
        XCTAssertTrue(records[1]["request_id"] is NSNull)
        XCTAssertEqual(records[1]["output_token_ids"] as? [Int], [])
    }

    func testRejectsSymlinkWithoutChangingItsTarget() throws {
        let root = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target")
        let file = root.appendingPathComponent("tokens.jsonl")
        let original = Data("private retained bytes".utf8)
        try original.write(to: target)
        XCTAssertEqual(chmod(target.path, 0o600), 0)
        XCTAssertEqual(symlink(target.path, file.path), 0)
        XCTAssertThrowsError(try LabOutputTokenCapture.record(request: request(), tokenIDs: [7], environment: environment(file)))
        XCTAssertEqual(try Data(contentsOf: target), original)
    }

    func testRejectsPublicPermissionsAndHardlinksWithoutAppending() throws {
        let root = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("tokens.jsonl")
        let original = Data("retained bytes".utf8)
        try original.write(to: file)
        XCTAssertEqual(chmod(file.path, 0o644), 0)
        XCTAssertThrowsError(try LabOutputTokenCapture.record(request: request(), tokenIDs: [7], environment: environment(file)))
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(chmod(file.path, 0o600), 0)
        XCTAssertEqual(link(file.path, root.appendingPathComponent("hardlink").path), 0)
        XCTAssertThrowsError(try LabOutputTokenCapture.record(request: request(), tokenIDs: [7], environment: environment(file)))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testRejectsNonRegularFifoWithoutBlockingOrWriting() throws {
        let root = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fifo = root.appendingPathComponent("tokens.fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try LabOutputTokenCapture.record(request: request(), tokenIDs: [7], environment: environment(fifo)))
    }

    func testConcurrentAppendsRemainCompleteExactRecords() async throws {
        let root = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("tokens.jsonl")
        let request = try request()
        let env = environment(file)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<32 {
                group.addTask {
                    try LabOutputTokenCapture.record(request: request.withRequestID("concurrent-\(index)"),
                        tokenIDs: [index, 0, index, 9001], environment: env)
                }
            }
            try await group.waitForAll()
        }
        let captured = try records(file)
        XCTAssertEqual(captured.count, 32)
        XCTAssertEqual(Set(captured.compactMap { $0["request_id"] as? String }).count, 32)
        for record in captured {
            let id = try XCTUnwrap(record["request_id"] as? String)
            let index = try XCTUnwrap(Int(id.replacingOccurrences(of: "concurrent-", with: "")))
            XCTAssertEqual(record["output_token_ids"] as? [Int], [index, 0, index, 9001])
        }
    }

    private func request() throws -> ChatCompletionRequest {
        try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: [
            "model": "lab/model", "messages": [["role": "user", "content": "hello"]],
        ]))
    }

    private func privateDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        return url
    }

    private func environment(_ file: URL) -> [String: String] {
        ["MACPROVIDER_LAB_TOKEN_CAPTURE": file.path]
    }

    private func records(_ file: URL) throws -> [[String: Any]] {
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.hasSuffix("\n"))
        return try text.split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }
}
#endif
