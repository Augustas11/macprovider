import AppKit
import XCTest
@testable import Malibu

@MainActor
final class TerminalClipboardTests: XCTestCase {
    func testOSC52CannotWriteClipboardButExplicitSelectionCopyCan() throws {
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.pasteboardItems?.map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        } ?? []
        defer {
            pasteboard.clearContents()
            let items = previous.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            pasteboard.writeObjects(items)
        }
        pasteboard.clearContents()
        pasteboard.setString("trusted clipboard", forType: .string)
        let changeCount = pasteboard.changeCount
        let view = EmbeddedProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let payload = Data("attacker command".utf8).base64EncodedString()
        view.feed(byteArray: Array("\u{1b}]52;c;\(payload)\u{7}".utf8)[...])
        XCTAssertEqual(pasteboard.changeCount, changeCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "trusted clipboard")

        view.feed(byteArray: Array("deliberately selected".utf8)[...])
        view.selectAll(nil)
        // The same responder action used by the Edit menu and Command-C.
        view.copy(self)
        XCTAssertTrue(try XCTUnwrap(pasteboard.string(forType: .string)).contains("deliberately selected"))
    }
}
