import Foundation
import XCTest
@testable import macprovider_cli

final class ControlMetricsBuilderTests: XCTestCase {
    private func makeCapacity() -> ProviderCapacity {
        ProviderCapacity(maxContextOverride: 50_000, maxConcurrencyOverride: 4)
    }

    // CS-3 regression: the control-socket metrics poll shares one ProviderStatus
    // instance with the coordinator heartbeat. The poll must READ the since-last
    // window without RESETTING it, so the next heartbeat still reports the full
    // window. Before the fix, build() reset the window and the heartbeat saw 0.
    func testMetricsBuildDoesNotDrainHeartbeatWindow() async {
        let status = ProviderStatus(modelID: "m", modelLoaded: true, capacity: makeCapacity())
        await status.finishRequest(startedAt: Date(), completion: nil, failed: false)

        // A Malibu.app metrics poll lands between two heartbeats.
        _ = await ControlMetricsBuilder.build(
            providerStatus: status,
            providerEarningsClient: nil,
            malibuAccrualClient: nil,
            providerToken: nil
        )

        // The heartbeat (resetWindow: true) must still observe the request the
        // poll read — the poll did not steal it from the since-last window.
        let heartbeat = await status.snapshot(resetWindow: true)
        XCTAssertEqual(heartbeat.requestsServedSinceLast, 1)

        // And the heartbeat, which owns rollover, has now cleared the window.
        let afterHeartbeat = await status.snapshot(resetWindow: false)
        XCTAssertEqual(afterHeartbeat.requestsServedSinceLast, 0)
    }
}
