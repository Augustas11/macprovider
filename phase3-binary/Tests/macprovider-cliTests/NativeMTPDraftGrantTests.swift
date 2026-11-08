import XCTest
@testable import macprovider_cli

final class NativeMTPDraftGrantTests: XCTestCase {
    private let entry = NativeMTPDraftCostFit.Entry(
        rows: 2,
        baseRoundMicros: 50_000,
        extraMicrosPerGrantedRow: 20_000
    )

    private func candidate(_ id: String, _ ppm: UInt64) -> NativeMTPDraftGrantCandidate {
        NativeMTPDraftGrantCandidate(requestID: id, acceptancePPM: ppm)
    }

    func testRowAboveTheBreakEvenAcceptanceIsGranted() {
        // Break-even for two rows: 2 * 20_000 / 50_000 = 0.8.
        XCTAssertEqual(
            NativeMTPDraftGrant.deniedRequestIDs(
                candidates: [candidate("a", 900_000), candidate("b", 900_000)],
                activeRows: 2,
                entry: entry
            ),
            []
        )
    }

    func testRowBelowTheBreakEvenAcceptanceIsDenied() {
        XCTAssertEqual(
            NativeMTPDraftGrant.deniedRequestIDs(
                candidates: [candidate("a", 700_000), candidate("b", 700_000)],
                activeRows: 2,
                entry: entry
            ),
            ["a", "b"]
        )
    }

    func testRowAtExactlyBreakEvenIsDenied() {
        XCTAssertEqual(
            NativeMTPDraftGrant.deniedRequestIDs(
                candidates: [candidate("a", 800_000)],
                activeRows: 2,
                entry: entry
            ),
            ["a"]
        )
    }

    func testHigherAcceptanceRowsAreGrantedFirst() {
        XCTAssertEqual(
            NativeMTPDraftGrant.deniedRequestIDs(
                candidates: [candidate("low", 500_000), candidate("high", 950_000)],
                activeRows: 2,
                entry: entry
            ),
            ["low"]
        )
    }

    func testCostFitHasNoEntryForALoneRowAndClampsAboveItsWidestRow() throws {
        let fit = NativeMTPDraftCostFit(entries: [
            .init(rows: 2, baseRoundMicros: 1, extraMicrosPerGrantedRow: 1),
            .init(rows: 4, baseRoundMicros: 2, extraMicrosPerGrantedRow: 2),
        ])
        XCTAssertNil(fit.entry(activeRows: 1))
        XCTAssertEqual(fit.entry(activeRows: 2)?.rows, 2)
        XCTAssertEqual(fit.entry(activeRows: 3)?.rows, 4)
        XCTAssertEqual(fit.entry(activeRows: 16)?.rows, 4)
    }

    func testAcceptanceIsOptimisticUntilEnoughProposalsAreObserved() {
        XCTAssertEqual(NativeMTPDraftGrant.acceptancePPM(accepted: 0, rejected: 15), 1_000_000)
        XCTAssertEqual(NativeMTPDraftGrant.acceptancePPM(accepted: 8, rejected: 8), 500_000)
    }

    func testOnlyTheMeasuredMachineHasAFit() throws {
        let fits = NativeMTPDraftCostFit.fits(chip: "Apple M3 Ultra")
        let glm = try XCTUnwrap(fits[NativeMTPStagedRoundBytes.glm5NextFamilyAdapter])
        XCTAssertEqual(glm.entries.map(\.rows), [2, 4])
        XCTAssertEqual(NativeMTPDraftCostFit.fits(chip: "Apple M4 Max"), [:])
    }
}
