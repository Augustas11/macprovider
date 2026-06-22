import MacProviderCore
import XCTest

final class BrowserOpenerTests: XCTestCase {
    func testAutoOpen_Skipped_WhenNoControllingTTY() throws {
        let opened = LockedBox(false)
        let opener = BrowserOpener(hasControllingTTY: { false }, environment: { _ in nil }, spawn: { _ in opened.set(true) })

        let decision = try opener.openIfAllowed("https://portal.example/claim?ot=PAIR", expectedPortalHost: "portal.example")

        XCTAssertEqual(decision, .skippedNoTTY)
        XCTAssertFalse(opened.get())
    }

    func testAutoOpen_Skipped_WhenSSHTTYSet() throws {
        let opened = LockedBox(false)
        let opener = BrowserOpener(hasControllingTTY: { true }, environment: { $0 == "SSH_TTY" ? "/dev/ttys001" : nil }, spawn: { _ in opened.set(true) })

        let decision = try opener.openIfAllowed("https://portal.example/claim?ot=PAIR", expectedPortalHost: "portal.example")

        XCTAssertEqual(decision, .skippedSSH)
        XCTAssertFalse(opened.get())
    }

    func testAutoOpen_Skipped_WhenMACPROVIDER_NO_BROWSERSet() throws {
        let opened = LockedBox(false)
        let opener = BrowserOpener(hasControllingTTY: { true }, environment: { $0 == "MACPROVIDER_NO_BROWSER" ? "1" : nil }, spawn: { _ in opened.set(true) })

        let decision = try opener.openIfAllowed("https://portal.example/claim?ot=PAIR", expectedPortalHost: "portal.example")

        XCTAssertEqual(decision, .skippedDisabled)
        XCTAssertFalse(opened.get())
    }

    func testAutoOpen_RejectsClaimURLWithMetacharacters() throws {
        let opened = LockedBox(false)
        let opener = BrowserOpener(hasControllingTTY: { true }, environment: { _ in nil }, spawn: { _ in opened.set(true) })

        let decision = try opener.openIfAllowed("https://portal.example/claim?ot=PAIR;open", expectedPortalHost: "portal.example")

        XCTAssertEqual(decision, .rejectedInvalidURL)
        XCTAssertFalse(opened.get())
    }

    func testAutoOpen_UsesSpawnForValidTTYCase() throws {
        let openedURL = LockedBox<String?>(nil)
        let opener = BrowserOpener(hasControllingTTY: { true }, environment: { _ in nil }, spawn: { openedURL.set($0) })

        let decision = try opener.openIfAllowed("https://portal.example/claim?ot=PAIR", expectedPortalHost: "portal.example")

        XCTAssertEqual(decision, .opened)
        XCTAssertEqual(openedURL.get(), "https://portal.example/claim?ot=PAIR")
    }
}
