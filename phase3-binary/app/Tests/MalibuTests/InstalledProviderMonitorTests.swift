import XCTest
@testable import Malibu

final class InstalledProviderMonitorTests: XCTestCase {
    func testHealthSnapshotDecodesTokenCountersFromJSON() throws {
        let json = """
        {
          "status": "ready",
          "model": "qwen3-coder-30b-a3b-instruct",
          "requests_total": 4,
          "requests_today": 2,
          "input_tokens_today": 766,
          "output_tokens_today": 1325,
          "input_tokens_all_time": 766,
          "output_tokens_all_time": 1325,
          "uptime_s": 4713,
          "restart_count": 5
        }
        """.data(using: .utf8)!
        let object = try JSONSerialization.jsonObject(with: json) as! [String: Any]

        let status = object["status"] as? String
        let model = object["model"] as? String
        let requestsTotal = object["requests_total"] as? Int
        let requestsToday = object["requests_today"] as? Int
        let inputTokensToday = Self.int64Value(object["input_tokens_today"])
        let outputTokensToday = Self.int64Value(object["output_tokens_today"])
        let inputTokensAllTime = Self.int64Value(object["input_tokens_all_time"])
        let outputTokensAllTime = Self.int64Value(object["output_tokens_all_time"])
        let uptimeSeconds = object["uptime_s"] as? Int
        let restartCount = object["restart_count"] as? Int

        let snapshot = InstalledProviderMonitor.HealthSnapshot(
            ready: status == "ready",
            model: model,
            requestsTotal: requestsTotal,
            requestsToday: requestsToday,
            inputTokensToday: inputTokensToday,
            outputTokensToday: outputTokensToday,
            inputTokensAllTime: inputTokensAllTime,
            outputTokensAllTime: outputTokensAllTime,
            uptimeSeconds: uptimeSeconds,
            restartCount: restartCount
        )

        XCTAssertTrue(snapshot.ready)
        XCTAssertEqual(snapshot.requestsTotal, 4)
        XCTAssertEqual(snapshot.requestsToday, 2)
        XCTAssertEqual(snapshot.restartCount, 5)
        XCTAssertEqual(snapshot.inputTokensToday, 766)
        XCTAssertEqual(snapshot.outputTokensToday, 1325)
        XCTAssertEqual(snapshot.inputTokensAllTime, 766)
        XCTAssertEqual(snapshot.outputTokensAllTime, 1325)
    }

    private static func int64Value(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        return nil
    }
}
