import XCTest
@testable import macprovider_cli

final class SelfUpdateTests: XCTestCase {
    func testSemverComparison() {
        XCTAssertEqual(SelfUpdate.compareSemver("1.2.0", "1.2.1"), .orderedAscending)
        XCTAssertEqual(SelfUpdate.compareSemver("v1.2.1", "1.2.1"), .orderedSame)
        XCTAssertEqual(SelfUpdate.compareSemver("1.3.0", "1.2.9"), .orderedDescending)
        XCTAssertEqual(SelfUpdate.compareSemver("1.2", "1.2.0"), .orderedSame)
    }
}
