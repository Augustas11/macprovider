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

    func testStatusSnapshotDecodesBuyerServingCatalogTrust() throws {
        let json = """
        {
          "binary_version": "0.5.0",
          "network_state": "buyer_serving",
          "coordinator": {
            "connected": true,
            "tier": "trusted",
            "recommended_binary_version": "0.5.1"
          },
          "catalog": {
            "state": "live_verified",
            "release_id": "published-2026-07-10-catalog-recovery-v1",
            "digest": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "signer_key_id": "streamvc-autotune-static-v4",
            "source": "coordinator"
          }
        }
        """.data(using: .utf8)!

        let snapshot = try XCTUnwrap(InstalledProviderMonitor.decodeStatus(json))
        XCTAssertEqual(snapshot.networkState, "buyer_serving")
        XCTAssertTrue(snapshot.coordinatorConnected)
        XCTAssertEqual(snapshot.catalogState, "live_verified")
        XCTAssertEqual(snapshot.catalogReleaseID, "published-2026-07-10-catalog-recovery-v1")
        XCTAssertEqual(snapshot.catalogSignerKeyID, "streamvc-autotune-static-v4")
        XCTAssertEqual(snapshot.catalogSource, "coordinator")
    }

    func testBusyHealthStatusRemainsHealthyDuringBuyerRequest() {
        XCTAssertTrue(InstalledProviderMonitor.isHealthyStatus("ready"))
        XCTAssertTrue(InstalledProviderMonitor.isHealthyStatus("busy"))
        XCTAssertFalse(InstalledProviderMonitor.isHealthyStatus("starting"))
    }

    func testStatusSnapshotKeepsOlderCLIReadableWithoutTrustFields() throws {
        let json = """
        {
          "binary_version": "0.4.9",
          "coordinator": { "connected": true, "tier": "provisional" }
        }
        """.data(using: .utf8)!

        let snapshot = try XCTUnwrap(InstalledProviderMonitor.decodeStatus(json))
        XCTAssertTrue(snapshot.coordinatorConnected)
        XCTAssertNil(snapshot.networkState)
        XCTAssertNil(snapshot.catalogState)
    }

    private static func int64Value(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        return nil
    }
}
