import XCTest
@testable import macprovider_cli

final class NativeMTPTupleOfferLogTests: XCTestCase {
    // The offer outcome is one grep-able stderr line, so a provider that never
    // offers its tuple to the coordinator canary is visible in production logs.
    func testTupleOfferLogLineIsOneEventLine() {
        let line = CoordinatorClient.nativeMTPTupleOfferLogLine(
            action: "skipped",
            detail: "reason=missing_wire_identity"
        )
        XCTAssertEqual(line, "event=native_mtp_tuple_offer action=skipped reason=missing_wire_identity\n")
        XCTAssertEqual(line.filter { $0 == "\n" }.count, 1)
    }
}
