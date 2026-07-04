import XCTest
@testable import Malibu

@MainActor
final class ThermalMonitorTests: XCTestCase {
    func testThermalStateMapsProcessInfoValues() {
        XCTAssertEqual(MalibuThermalState(processInfoState: .nominal), .nominal)
        XCTAssertEqual(MalibuThermalState(processInfoState: .fair), .fair)
        XCTAssertEqual(MalibuThermalState(processInfoState: .serious), .serious)
        XCTAssertEqual(MalibuThermalState(processInfoState: .critical), .critical)
        XCTAssertEqual(MalibuThermalState.critical.label, "Throttled")
        XCTAssertTrue(MalibuThermalState.serious.isMenuBarAttention)
        XCTAssertFalse(MalibuThermalState.fair.isMenuBarAttention)
    }

    func testRefreshPublishesUpdatedState() {
        var current: ProcessInfo.ThermalState = .nominal
        let monitor = ThermalMonitor(notificationCenter: NotificationCenter(), stateProvider: { current })
        XCTAssertEqual(monitor.state, .nominal)
        current = .critical
        monitor.refresh()
        XCTAssertEqual(monitor.state, .critical)
    }
}
