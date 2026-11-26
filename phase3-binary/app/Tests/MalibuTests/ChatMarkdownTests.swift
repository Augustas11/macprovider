import XCTest
@testable import Malibu

final class ChatMarkdownTests: XCTestCase {
    func testFencedCodeKeepsLanguageAndSource() {
        let blocks = ChatMarkdown.parse("Before\n```swift\nlet x = 1\n```\nAfter")
        guard case .code(let language, let source) = blocks[1] else { return XCTFail("missing code block") }
        XCTAssertEqual(language, "swift")
        XCTAssertEqual(source, "let x = 1")
        XCTAssertEqual(ChatMarkdown.plain([blocks[0]]), "Before")
        XCTAssertEqual(ChatMarkdown.plain([blocks[2]]), "After")
    }

    func testInlineCodeStrongAndMathStayInsideTheParagraph() {
        let blocks = ChatMarkdown.parse("Use `code`, **bold**, *note* and $x^2$.")
        guard case .paragraph(let inlines) = blocks.first else { return XCTFail("missing paragraph") }
        XCTAssertTrue(inlines.contains(.code("code")))
        XCTAssertTrue(inlines.contains(.strong("bold")))
        XCTAssertTrue(inlines.contains(.emphasis("note")))
        XCTAssertTrue(inlines.contains(.math("x^2")))
    }

    func testHeadingsListsAndQuotes() {
        let blocks = ChatMarkdown.parse("# Title\n\n- one\n- two\n\n> quoted")
        guard case .heading(1, "Title") = blocks[0] else { return XCTFail("heading") }
        guard case .list(false, let items) = blocks[1] else { return XCTFail("list") }
        XCTAssertEqual(items.map { ChatMarkdown.plain($0) }, ["one", "two"])
        guard case .quote(let quote) = blocks[2] else { return XCTFail("quote") }
        XCTAssertEqual(ChatMarkdown.plain(quote), "quoted")
    }

    func testDisplayMathAndInlineFraction() {
        let blocks = ChatMarkdown.parse("$$\\frac{1}{2}$$\n\nThe value is $\\alpha$.")
        guard case .math(let display) = blocks[0] else { return XCTFail("display math") }
        XCTAssertEqual(ChatMath.render(display), "1⁄2")
        guard case .paragraph(let inlines) = blocks[1] else { return XCTFail("paragraph") }
        XCTAssertTrue(inlines.contains(.math("\\alpha")))
        XCTAssertEqual(ChatMath.render("\\alpha"), "α")
        XCTAssertEqual(ChatMath.render("x^{2}"), "x²")
    }

    func testLinksAndImagesAreTextAndAreNotASeparateAction() {
        let blocks = ChatMarkdown.parse("See [the note](https://example.test/a) and ![pic](https://example.test/b.png)")
        guard case .paragraph(let inlines) = blocks.first else { return XCTFail("paragraph") }
        let text = ChatMarkdown.plain(inlines)
        XCTAssertTrue(text.contains("the note (https://example.test/a)"))
        XCTAssertTrue(text.contains("pic (https://example.test/b.png)"))
        XCTAssertFalse(inlines.contains { inline in
            if case .text = inline { return false }
            return true
        })
    }

    func testUnclosedFenceDoesNotSwallowPastTheCapAsAParagraph() {
        let source = "```\n" + String(repeating: "x\n", count: 3)
        let blocks = ChatMarkdown.parse(source)
        guard case .code(_, let source) = blocks.first else { return XCTFail("code") }
        XCTAssertTrue(source.hasPrefix("x"))
    }

    func testAnswerViewIsWhatChatAndAgentsRender() throws {
        let chat = try String(contentsOf: source("Chat/ChatScreen.swift"), encoding: .utf8)
        XCTAssertTrue(chat.contains("ChatAnswerView(text: text)"))
        XCTAssertTrue(chat.contains("malibu.chat.copy-answer") == false)
        let answer = try String(contentsOf: source("Chat/ChatMarkdown.swift"), encoding: .utf8)
        XCTAssertTrue(answer.contains("malibu.chat.copy-answer"))
        XCTAssertTrue(answer.contains("malibu.chat.copy-code"))
        XCTAssertTrue(answer.contains("malibu.chat.math"))
        let agents = try String(contentsOf: source("Agents/AgentsScreen.swift"), encoding: .utf8)
        XCTAssertTrue(agents.contains("ChatAnswerView(text: session.transcript)"))
    }

    private func source(_ relative: String) throws -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Malibu").appendingPathComponent(relative)
    }
}
