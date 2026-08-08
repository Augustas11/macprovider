import Darwin
import XCTest
@testable import Malibu

final class LogTailReaderTests: XCTestCase {
    func testRingBufferKeepsLastTwoHundredLines() {
        var buffer = LogTailBuffer(capacity: 200)
        buffer.append(contentsOf: (0..<250).map { "line-\($0)" })

        XCTAssertEqual(buffer.lines.count, 200)
        XCTAssertEqual(buffer.lines.first, "line-50")
        XCTAssertEqual(buffer.lines.last, "line-249")
    }

    func testSensitiveLinesAreRedacted() {
        var buffer = LogTailBuffer(capacity: 20)
        buffer.append(contentsOf: [
            "normal line",
            "provider_token: secret",
            "identity_signature abc",
            "Authorization: Bearer secret",
            "Bearer eyJhbGciOiJIUzI1NiJ9.secret.payload",
            "token_sha256=abc123",
            "-----BEGIN PRIVATE KEY-----",
            "signed_payload={\"provider_id\":\"p\"}",
            "providerToken: secret",
            "identitySignature abc",
            "privateKey=secret",
            "signedPayload={\"provider_id\":\"p\"}",
            "payloadToSign={\"provider_id\":\"p\"}",
            "tokenHash=abc123"
        ])

        XCTAssertEqual(buffer.lines, [
            "normal line",
            "[redacted]",
            "[redacted]",
            "[redacted]",
            "[redacted]",
            "[redacted]",
            "[redacted]",
            "[redacted]",
            "[redacted]",
            "[redacted]",
            "[redacted]",
            "[redacted]",
            "[redacted]",
            "[redacted]"
        ])
    }

    @MainActor
    func testReaderStartsFromBoundedTailWindow() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appendingPathComponent("provider.log")
        let lines = (0..<50).map { "line-\($0)" }.joined(separator: "\n") + "\n"
        try lines.data(using: .utf8)?.write(to: logURL)

        let reader = LogTailReader(fileURL: logURL, capacity: 10, maxReadBytes: 80)
        await reader.readAvailable()

        XCTAssertLessThanOrEqual(reader.lines.count, 10)
        XCTAssertFalse(reader.lines.contains("line-0"))
        XCTAssertEqual(reader.lines.last, "line-49")
    }

    @MainActor
    func testReaderCapsUnterminatedFragment() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appendingPathComponent("provider.log")
        try Data(String(repeating: "x", count: 100).utf8).write(to: logURL)

        let reader = LogTailReader(
            fileURL: logURL,
            capacity: 10,
            maxReadBytes: 100,
            maxPendingFragmentCharacters: 16
        )
        await reader.readAvailable()
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\nfinished\n".utf8))
        try handle.close()
        await reader.readAvailable()

        XCTAssertEqual(reader.lines.first?.count, 16)
        XCTAssertEqual(reader.lines.last, "finished")
    }

    @MainActor
    func testReaderRejectsSymlinkHardlinkAndFIFO() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("source.log")
        try Data("secret-line\n".utf8).write(to: source)

        let symlink = directory.appendingPathComponent("symlink.log")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
        let hardlink = directory.appendingPathComponent("hardlink.log")
        XCTAssertEqual(Darwin.link(source.path, hardlink.path), 0)
        let fifo = directory.appendingPathComponent("fifo.log")
        XCTAssertEqual(Darwin.mkfifo(fifo.path, mode_t(0o600)), 0)

        for path in [symlink, hardlink, fifo] {
            let reader = LogTailReader(fileURL: path, capacity: 10)
            await reader.readAvailable()
            XCTAssertTrue(reader.lines.isEmpty, "unsafe log path was read: \(path.path)")
        }
    }
}
