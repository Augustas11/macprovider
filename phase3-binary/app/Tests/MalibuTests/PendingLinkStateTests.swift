import XCTest
@testable import Malibu

// AUDIT R1 SECURITY S1 / CODE H3 / ARCHITECT A3: nonce state machine tests.
// These lock in that a malibu://link callback is refused unless a matching
// pending nonce exists AND the app is not already configured.

final class PendingLinkStateTests: XCTestCase {
    override func setUp() {
        super.setUp()
        PendingLinkState.discard()
    }
    override func tearDown() {
        PendingLinkState.discard()
        super.tearDown()
    }

    func testCallbackWithoutPendingLinkIsRejected() {
        XCTAssertThrowsError(try PendingLinkState.consume(state: "anything", appAlreadyConfigured: false)) { err in
            XCTAssertEqual(err as? PendingLinkState.ValidationError, .noPendingLink)
        }
    }

    func testCallbackWithMismatchedStateIsRejected() throws {
        _ = try PendingLinkState.beginLink()
        XCTAssertThrowsError(try PendingLinkState.consume(state: "not-the-real-nonce", appAlreadyConfigured: false)) { err in
            XCTAssertEqual(err as? PendingLinkState.ValidationError, .mismatch)
        }
        // Nonce is single-use; further attempts must be rejected as no-pending.
        XCTAssertThrowsError(try PendingLinkState.consume(state: "any", appAlreadyConfigured: false)) { err in
            XCTAssertEqual(err as? PendingLinkState.ValidationError, .noPendingLink)
        }
    }

    func testCallbackWhileAlreadyConfiguredIsRejected() throws {
        let nonce = try PendingLinkState.beginLink()
        XCTAssertThrowsError(try PendingLinkState.consume(state: nonce, appAlreadyConfigured: true)) { err in
            XCTAssertEqual(err as? PendingLinkState.ValidationError, .alreadyConfigured)
        }
    }

    func testHappyPathConsumesOnce() throws {
        let nonce = try PendingLinkState.beginLink()
        XCTAssertNoThrow(try PendingLinkState.consume(state: nonce, appAlreadyConfigured: false))
        XCTAssertThrowsError(try PendingLinkState.consume(state: nonce, appAlreadyConfigured: false)) { err in
            XCTAssertEqual(err as? PendingLinkState.ValidationError, .noPendingLink)
        }
    }
}
