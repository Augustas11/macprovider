import XCTest

@testable import macprovider_cli

final class NativeMTPBackendSafetyTests: XCTestCase {
    func testSignedProposalDepthMustFitDrafterTotalBlockSize() {
        XCTAssertTrue(NativeMTPProposalBounds.fits(
            maximumProposalDepth: 1,
            maximumBlockSize: 2
        ))
        XCTAssertFalse(NativeMTPProposalBounds.fits(
            maximumProposalDepth: 2,
            maximumBlockSize: 2
        ))
        XCTAssertTrue(NativeMTPProposalBounds.fits(
            maximumProposalDepth: 4,
            maximumBlockSize: nil
        ))
    }
}
