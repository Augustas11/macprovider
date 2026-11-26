import XCTest
@testable import Malibu

final class ChatTranscriptTests: XCTestCase {
    func testMarkdownKeepsTheVisibleChatAndDropsAttachmentBytes() {
        let turn = ChatTurn(
            id: UUID(), prompt: "Where is the cat?", answer: "In the notes.", complete: true,
            reasoning: "Looked at the folder.", note: "kept", tools: ["read_file notes.txt"],
            citations: ["notes.txt"],
            attachments: [ChatAttachment(id: UUID(), name: "photo.png\nSECRETNAME",
                                          imageDataURL: "data:image/png;base64,SECRETBYTES",
                                          documentText: "SECRETDOC")])
        let text = ChatTranscript.markdown(title: "Hello\n## Injected", turns: [turn])
        XCTAssertTrue(text.contains("# Hello ## Injected"))
        XCTAssertFalse(text.contains("\n## Injected"))
        XCTAssertTrue(text.contains("## You"))
        XCTAssertTrue(text.contains("Where is the cat?"))
        XCTAssertTrue(text.contains("### Thinking"))
        XCTAssertTrue(text.contains("Looked at the folder."))
        XCTAssertTrue(text.contains("## Malibu"))
        XCTAssertTrue(text.contains("In the notes."))
        XCTAssertTrue(text.contains("Source: notes.txt"))
        XCTAssertTrue(text.contains("Tool: read_file notes.txt"))
        XCTAssertTrue(text.contains("Note: kept"))
        XCTAssertTrue(text.contains("Attachment: photo.png SECRETNAME"))
        XCTAssertFalse(text.contains("SECRETBYTES"))
        XCTAssertFalse(text.contains("SECRETDOC"))
        XCTAssertFalse(text.contains("NOT-IN-CHAT"))
    }

    func testExportIsOwnerOnlyAndReplacesASymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-export-\(UUID().uuidString)")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("chat-export-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let secret = outside.appendingPathComponent("secret.txt")
        try Data("SECRET".utf8).write(to: secret)
        let link = root.appendingPathComponent("chat.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        try ChatTranscript.write("# Exported\n", to: link)
        XCTAssertEqual(try String(contentsOf: secret, encoding: .utf8), "SECRET")
        XCTAssertEqual(try String(contentsOf: link, encoding: .utf8), "# Exported\n")
        let values = try link.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        XCTAssertNotEqual(values.isSymbolicLink, true)
        XCTAssertEqual(values.isRegularFile, true)
        XCTAssertEqual(try posixMode(link), 0o600)
        XCTAssertTrue(try leftovers(root).isEmpty)

        let hard = root.appendingPathComponent("hard.md")
        try FileManager.default.linkItem(at: secret, to: hard)
        try ChatTranscript.write("local only\n", to: hard)
        XCTAssertEqual(try String(contentsOf: secret, encoding: .utf8), "SECRET")
        XCTAssertEqual(try String(contentsOf: hard, encoding: .utf8), "local only\n")
        XCTAssertEqual(try posixMode(hard), 0o600)
    }

    func testExportRejectsAnUnsafeOrEmptyDestination() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-export-reject-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("chat.md")
        XCTAssertThrowsError(try ChatTranscript.write("", to: file)) { error in
            XCTAssertEqual(error as? ChatTranscriptFailure, .invalid)
        }
        XCTAssertThrowsError(try ChatTranscript.write(String(repeating: "a", count: ChatTranscript.byteLimit + 1), to: file)) { error in
            XCTAssertEqual(error as? ChatTranscriptFailure, .invalid)
        }
        let remote = try XCTUnwrap(URL(string: "https://example.com/chat.md"))
        XCTAssertThrowsError(try ChatTranscript.write("hello\n", to: remote)) { error in
            XCTAssertEqual(error as? ChatTranscriptFailure, .unsafeFile)
        }
        let directory = root.appendingPathComponent("chat.md", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertThrowsError(try ChatTranscript.write("hello\n", to: directory)) { error in
            XCTAssertEqual(error as? ChatTranscriptFailure, .unsafeFile)
        }
        XCTAssertTrue(try leftovers(root).isEmpty)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    @MainActor
    func testDictationStaysOnDeviceAndInsideTheComposerLimit() {
        XCTAssertEqual(ChatDictationGate.refusal(recognizerOnDevice: false, speechAuthorized: true, microphoneAuthorized: true),
                       ChatDictationGate.onDevice)
        XCTAssertEqual(ChatDictationGate.refusal(recognizerOnDevice: true, speechAuthorized: false, microphoneAuthorized: true),
                       ChatDictationGate.permission)
        XCTAssertEqual(ChatDictationGate.refusal(recognizerOnDevice: true, speechAuthorized: true, microphoneAuthorized: false),
                       ChatDictationGate.permission)
        XCTAssertNil(ChatDictationGate.refusal(recognizerOnDevice: true, speechAuthorized: true, microphoneAuthorized: true))
        XCTAssertEqual(ChatDictation.cappedDraft(base: "  hello ", heard: "world"), "hello world")
        XCTAssertEqual(ChatDictation.cappedDraft(base: "", heard: "world"), "world")
        let almost = String(repeating: "a", count: ChatStore.maxPromptBytes - 1)
        let capped = ChatDictation.cappedDraft(base: almost, heard: "é")
        XCTAssertEqual(capped.utf8.count, ChatStore.maxPromptBytes)
        XCTAssertFalse(capped.contains("é"))
        let wide = ChatDictation.cappedDraft(base: "", heard: String(repeating: "é", count: ChatStore.maxPromptBytes))
        XCTAssertLessThanOrEqual(wide.utf8.count, ChatStore.maxPromptBytes)
        XCTAssertEqual(wide.utf8.count % 2, 0)
    }

    func testChatOffersExportVoiceShortcutsAndOnDeviceSpeech() throws {
        let screen = try String(contentsOf: source("Sources/Malibu/Chat/ChatScreen.swift"), encoding: .utf8)
        let speech = try String(contentsOf: source("Sources/Malibu/Chat/ChatSpeech.swift"), encoding: .utf8)
        let project = try String(contentsOf: source("project.yml"), encoding: .utf8)
        for identifier in ["malibu.chat.export", "malibu.chat.share", "malibu.chat.dictate",
                           "malibu.chat.speak", "malibu.chat.focus"] {
            XCTAssertTrue(screen.contains(identifier), identifier)
        }
        XCTAssertTrue(screen.contains(".keyboardShortcut(\"n\", modifiers: .command)"))
        XCTAssertTrue(screen.contains(".keyboardShortcut(\"e\", modifiers: [.command, .shift])"))
        XCTAssertTrue(screen.contains(".keyboardShortcut(\"l\", modifiers: .command)"))
        XCTAssertTrue(screen.contains(".keyboardShortcut(\"d\", modifiers: [.command, .shift])"))
        XCTAssertTrue(screen.contains(".keyboardShortcut(\"r\", modifiers: [.command, .shift])"))
        XCTAssertTrue(screen.contains(".keyboardShortcut(\"z\", modifiers: .command)"))
        XCTAssertTrue(screen.contains(".keyboardShortcut(\".\", modifiers: .command)"))
        XCTAssertTrue(screen.contains(".keyboardShortcut(.return, modifiers: .command)"))
        XCTAssertTrue(screen.contains("AccessibilityNotification.Announcement"))
        XCTAssertTrue(screen.contains("prefix(400)"))
        XCTAssertTrue(screen.contains("accessibilityAddTraits(.updatesFrequently)"))
        XCTAssertTrue(screen.contains("dictation.stop()"))
        XCTAssertTrue(screen.contains("speaker.stop()"))
        XCTAssertTrue(screen.contains("ChatTranscript.exportFailed"))
        XCTAssertTrue(speech.contains("requiresOnDeviceRecognition = true"))
        XCTAssertFalse(speech.contains("requiresOnDeviceRecognition = false"))
        XCTAssertFalse(speech.contains("print("))
        XCTAssertTrue(speech.contains("AVSpeechSynthesizer"))
        XCTAssertTrue(project.contains("NSMicrophoneUsageDescription: \"Malibu uses the microphone so you can dictate a message on this Mac.\""))
        XCTAssertTrue(project.contains("NSSpeechRecognitionUsageDescription: \"Malibu turns speech into text on this Mac.\""))
    }

    private func source(_ relative: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(relative)
    }

    private func posixMode(_ url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attrs[.posixPermissions] as? NSNumber).intValue
    }

    private func leftovers(_ root: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".malibu-export-") }
    }
}
