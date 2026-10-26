import XCTest
@testable import Malibu

final class TaskScheduleTests: XCTestCase {
    private let timezone = TimeZone(identifier: "America/Los_Angeles")!
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    func testSpringDSTMissingTimeUsesNextValidTime() {
        let schedule = TaskSchedule(kind: .daily, hour: 2, minute: 30)
        XCTAssertEqual(schedule.nextFire(after: date("2026-03-08T08:00:00Z"), timezone: timezone),
                       date("2026-03-08T10:00:00Z"))
    }

    func testAutumnDSTRepeatedTimeRunsOnlyAtFirstOccurrence() {
        let schedule = TaskSchedule(kind: .daily, hour: 1, minute: 30)
        let first = date("2026-11-01T08:30:00Z")
        XCTAssertEqual(schedule.nextFire(after: date("2026-11-01T07:00:00Z"), timezone: timezone), first)
        XCTAssertEqual(schedule.nextFire(after: first, timezone: timezone), date("2026-11-02T09:30:00Z"))
    }

    func testWeekdaysSkipsWeekendAcrossDST() {
        let schedule = TaskSchedule(kind: .weekdays, hour: 9, minute: 15)
        XCTAssertEqual(schedule.nextFire(after: date("2026-03-06T18:00:00Z"), timezone: timezone),
                       date("2026-03-09T16:15:00Z"))
    }

    func testHourlyUsesNextDeviceLocalHour() {
        let schedule = TaskSchedule(kind: .hourly)
        XCTAssertEqual(schedule.nextFire(after: date("2026-10-26T10:45:00Z"), timezone: timezone),
                       date("2026-10-26T11:00:00Z"))
    }

    func testOnceInPastIsInitiallyDueButHasNoNextOccurrence() {
        let past = date("2026-10-25T10:00:00Z")
        let now = date("2026-10-26T10:00:00Z")
        let schedule = TaskSchedule(kind: .once, date: past)
        XCTAssertEqual(schedule.initialFire(now: now, timezone: timezone), past)
        XCTAssertNil(schedule.nextFire(after: now, timezone: timezone))
    }

    func testInvalidTimeDoesNotSchedule() {
        XCTAssertNil(TaskSchedule(kind: .daily, hour: 24).nextFire(after: Date(), timezone: timezone))
        XCTAssertNil(TaskSchedule(kind: .weekdays, minute: 60).nextFire(after: Date(), timezone: timezone))
    }
}
