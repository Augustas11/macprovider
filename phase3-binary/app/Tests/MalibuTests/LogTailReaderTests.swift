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
        let privateKeyMarker = "-----BEGIN " + "PRIVATE KEY-----"
        buffer.append(contentsOf: [
            "normal line",
            "provider_token: secret",
            "identity_signature abc",
            "Authorization: Bearer secret",
            #"{"Authorization":"Basic secret"}"#,
            "Authorization = Basic secret",
            "Bearer eyJhbGciOiJIUzI1NiJ9.secret.payload",
            "token_sha256=abc123",
            privateKeyMarker,
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
            "[redacted]",
            "[redacted]",
            "[redacted]"
        ])
    }

    func testSecretDetectionUsesOriginalLineBeforeIdentifierScrubbing() {
        XCTAssertEqual(
            LogTailBuffer.redactedForTest(
                "provider_token: secret-value",
                usernameCandidates: ["provider"]
            ),
            "[redacted]"
        )
        XCTAssertEqual(
            LogTailBuffer.redactedForTest(
                "api_key=secret-value",
                usernameCandidates: ["api"]
            ),
            "[redacted]"
        )
        XCTAssertEqual(
            LogTailBuffer.redactedForTest(
                "password=secret-value",
                usernameCandidates: ["word"]
            ),
            "[redacted]"
        )
    }

    func testV2RedactionScrubsFreeTextHostnameCandidates() {
        let redacted = LogTailBuffer.redactedForTest(
            "watchdog running on provider-host.example.net and provider-host",
            usernameCandidates: [],
            hostnameCandidates: ["provider-host.example.net", "provider-host"]
        )

        XCTAssertEqual(redacted, "watchdog running on [host] and [host]")
    }

    func testV2RedactionScrubsPrivateContextWithoutDroppingNonSecretLine() {
        let username = NSUserName().isEmpty ? "provider" : NSUserName()
        var buffer = LogTailBuffer(capacity: 20)
        buffer.append(contentsOf: [
            "path=/Users/\(username)/Library/Application Support/Malibu/provider.log username=\(username) hostname=provider-mac.local ip=10.1.2.3 text=\u{001B}[31mred\u{009B}",
            "key:/Users/\(username)/Library/Application Support/Malibu/provider.log",
            "acl_write_rejected:/Users/\(username)",
            "file:///Users/\(username)/Library/Application Support/Malibu/provider.log",
            #"json path=\/Users\/\#(username)\/Library\/Application Support\/Malibu\/provider.log"#,
            #"json private=\/private\/var\/folders\/malibu\/provider.log"#,
            #"json file=file:\/\/\/Users\/\#(username)\/Library\/Application Support\/Malibu\/provider.log"#,
            "listen [fd00:1234::1]:11435",
            "mesh fd00::1 2001:db8::1 ::1 fe80::1234%en0",
            "punctuated fd00::1. [fd00:1234::1]. [2001:db8::1]:11435,"
        ])

        let joined = buffer.lines.joined(separator: "\n")
        XCTAssertTrue(joined.contains("[path]"), joined)
        XCTAssertTrue(joined.contains("username=[user]"), joined)
        XCTAssertTrue(joined.contains("hostname=[host]"), joined)
        XCTAssertTrue(joined.contains("[ip]"), joined)
        XCTAssertFalse(joined.contains("/Users"), joined)
        XCTAssertFalse(joined.contains(username), joined)
        XCTAssertFalse(joined.contains("provider-mac.local"), joined)
        XCTAssertFalse(joined.contains("10.1.2.3"), joined)
        XCTAssertFalse(joined.contains("fd00:1234::1"), joined)
        XCTAssertFalse(joined.contains("fd00::1"), joined)
        XCTAssertFalse(joined.contains("2001:db8::1"), joined)
        XCTAssertFalse(joined.contains("::1"), joined)
        XCTAssertFalse(joined.contains("fe80::1234%en0"), joined)
        XCTAssertFalse(joined.contains("fd00::1."), joined)
        XCTAssertFalse(joined.contains("[fd00:1234::1]."), joined)
        XCTAssertFalse(joined.contains("[2001:db8::1]:11435,"), joined)
        XCTAssertFalse(joined.contains(#"\/Users"#), joined)
        XCTAssertFalse(joined.contains(#"\/private"#), joined)
        XCTAssertTrue(buffer.lines.allSatisfy { line in
            !line.unicodeScalars.contains { scalar in
                scalar.value <= 0x1F || (0x7F...0x9F).contains(scalar.value)
            }
        }, joined)
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
