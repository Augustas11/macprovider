import XCTest

/// The chat composer must keep keyboard focus: disabling it while a reply streams dropped focus,
/// so after every reply the user had to click the box before typing again.
final class ChatComposerFocusTests: XCTestCase {
    private func chatScreenSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Malibu/Chat/ChatScreen.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testComposerIsNotDisabledWhileAReplyStreams() throws {
        // Scoped to the composer's modifier chain: the Agent folder button may still
        // be disabled while a reply runs.
        let source = try chatScreenSource()
        let start = try XCTUnwrap(source.range(of: "TextField(\"Message the model on this Mac…\""))
        let end = try XCTUnwrap(source.range(of: ".accessibilityIdentifier(\"malibu.chat.composer\")"))
        XCTAssertFalse(source[start.lowerBound..<end.upperBound].contains(".disabled("))
    }

    func testComposerTakesFocusWhenTheChatOpens() throws {
        let source = try chatScreenSource()
        let focused = try XCTUnwrap(source.range(of: ".focused($composerFocused)"))
        let tail = source[focused.upperBound...].prefix(400)
        XCTAssertTrue(tail.contains(".onAppear { composerFocused = true }"))
    }

    func testReturnWhileRunningDoesNotSend() throws {
        let source = try chatScreenSource()
        XCTAssertTrue(source.contains("if canSend { send() }"))
        let canSend = try XCTUnwrap(source.range(of: "private var canSend: Bool {"))
        XCTAssertTrue(source[canSend.upperBound...].prefix(80).contains("!store.isRunning"))
    }
}
