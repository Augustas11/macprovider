import XCTest
@testable import macprovider_cli

final class NativeMTPJourneyResourceObserverTests: XCTestCase {
    func testFaultOnlyReducesCapacityForNamedRowAfterThreshold() {
        let observer = NativeMTPJourneyResourceObserver(fault: .init(requestID: "named", afterGeneratedTokens: 8, capacityBytes: 500))
        XCTAssertEqual(observer.capacity(requestID: "other", generatedTokens: 8, realCapacity: 1000), 1000)
        XCTAssertEqual(observer.capacity(requestID: "named", generatedTokens: 7, realCapacity: 1000), 1000)
        XCTAssertEqual(observer.capacity(requestID: "named", generatedTokens: 8, realCapacity: 1000), 500)
        XCTAssertEqual(observer.capacity(requestID: "named", generatedTokens: 8, realCapacity: 100), 100)
    }

    func testNegativeFaultCannotCreateCapacityOrHideDuplicateTerminal() {
        let observer = NativeMTPJourneyResourceObserver(fault: .init(requestID: "named", afterGeneratedTokens: 0, capacityBytes: -1))
        XCTAssertEqual(observer.capacity(requestID: "named", generatedTokens: 0, realCapacity: 1000), 0)
        for _ in 0..<2 {
            observer.record(.init(requestID: "named", status: "cancelled", errorCode: nil,
                emittedTokens: 8, hasRetainedCache: false, hasSerialCache: false))
        }
        XCTAssertEqual(observer.terminalSnapshot().count, 2)
    }
}
