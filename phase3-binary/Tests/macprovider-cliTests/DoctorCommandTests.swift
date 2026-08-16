import Foundation
import XCTest
@testable import macprovider_cli

/// Issue #767 item 3 — `macprovider-cli doctor`. Offline-first: everything but
/// the floor comparison is answerable with no network at all.
final class DoctorCommandTests: XCTestCase {
    private func runner(
        binaryVersion: String = "1.8.65",
        coordinatorURL: String? = "wss://coordinator.malibu.tech/ws/provider",
        offline: Bool = false,
        fetch: @escaping @Sendable (URL) async -> DoctorHealthz?
    ) -> DoctorRunner {
        DoctorRunner(
            binaryVersion: binaryVersion,
            coordinatorURL: coordinatorURL,
            providerID: "mac",
            configPath: "/tmp/macprovider-doctor-test.yaml",
            offline: offline,
            fetch: fetch
        )
    }

    private static let unreachable: @Sendable (URL) async -> DoctorHealthz? = { _ in nil }

    // MARK: - endpoint derivation

    func testHealthzURLDerivation() {
        XCTAssertEqual(
            DoctorRunner.healthzURL(coordinatorURL: "wss://coordinator.malibu.tech/ws/provider")?.absoluteString,
            "https://coordinator.malibu.tech/healthz"
        )
        XCTAssertEqual(
            DoctorRunner.healthzURL(coordinatorURL: "ws://127.0.0.1:8444/ws/provider")?.absoluteString,
            "http://127.0.0.1:8444/healthz"
        )
        // Plaintext is loopback-only, credentials are refused, and a garbage or
        // absent URL yields nil rather than a guessed endpoint.
        XCTAssertNil(DoctorRunner.healthzURL(coordinatorURL: "ws://coordinator.malibu.tech/ws/provider"))
        XCTAssertNil(DoctorRunner.healthzURL(coordinatorURL: "wss://user:pass@coordinator.malibu.tech/ws/provider"))
        XCTAssertNil(DoctorRunner.healthzURL(coordinatorURL: "not a url"))
        XCTAssertNil(DoctorRunner.healthzURL(coordinatorURL: nil))
    }

    // MARK: - floor standing

    func testStandingAgainstPublishedFloor() {
        XCTAssertEqual(DoctorRunner.standing(binaryVersion: "1.8.32", requiredBinaryVersion: "1.8.33"), .belowFloor)
        XCTAssertEqual(DoctorRunner.standing(binaryVersion: "1.8.33", requiredBinaryVersion: "1.8.33"), .aboveFloor)
        XCTAssertEqual(DoctorRunner.standing(binaryVersion: "1.8.65", requiredBinaryVersion: "1.8.33"), .aboveFloor)
        XCTAssertEqual(DoctorRunner.standing(binaryVersion: "1.8.65", requiredBinaryVersion: nil), .noFloorConfigured)
        XCTAssertEqual(DoctorRunner.standing(binaryVersion: "1.8.65", requiredBinaryVersion: "  "), .noFloorConfigured)
        // Never claim "you're fine" from a comparison that did not happen.
        XCTAssertEqual(DoctorRunner.standing(binaryVersion: "1.8.65-dev", requiredBinaryVersion: "1.8.33"), .indeterminate)
        XCTAssertEqual(DoctorRunner.standing(binaryVersion: "1.8.65", requiredBinaryVersion: "latest"), .indeterminate)
    }

    // MARK: - offline-first behavior

    func testOfflineSkipsTheCoordinatorEntirely() async {
        let probed = LockedBox(false)
        let report = await runner(offline: true, fetch: { _ in
            probed.set(true)
            return nil
        }).run()
        XCTAssertFalse(probed.get(), "--offline must not touch the network")
        XCTAssertEqual(report.floorStanding, .notChecked)
        XCTAssertEqual(report.binaryVersion, "1.8.65")
        XCTAssertEqual(report.coordinatorURL, "wss://coordinator.malibu.tech/ws/provider")
        XCTAssertNil(report.requiredBinaryVersion)
    }

    func testUnreachableCoordinatorDegradesGracefully() async {
        let report = await runner(fetch: Self.unreachable).run()
        XCTAssertEqual(report.floorStanding, .unreachable)
        // Local facts are still reported — that is the point of offline-first.
        XCTAssertEqual(report.binaryVersion, "1.8.65")
        XCTAssertEqual(report.healthzURL, "https://coordinator.malibu.tech/healthz")
    }

    func testMissingCoordinatorURLIsNotChecked() async {
        let report = await runner(coordinatorURL: nil, fetch: Self.unreachable).run()
        XCTAssertEqual(report.floorStanding, .notChecked)
        XCTAssertNil(report.healthzURL)
    }

    func testBelowFloorIsReportedWithTheRequiredTarget() async {
        let report = await runner(binaryVersion: "1.8.32", fetch: { _ in
            DoctorHealthz(
                version: "v1.4.0",
                requiredBinaryVersion: "1.8.33",
                recommendedBinaryVersion: "1.8.65"
            )
        }).run()
        XCTAssertEqual(report.floorStanding, .belowFloor)
        XCTAssertEqual(report.requiredBinaryVersion, "1.8.33")
        XCTAssertEqual(report.recommendedBinaryVersion, "1.8.65")
        XCTAssertEqual(report.coordinatorVersion, "v1.4.0")
        XCTAssertTrue(try! XCTUnwrap(report.note).contains("4004"))
    }

    func testAboveFloorIsClean() async {
        let report = await runner(fetch: { _ in
            DoctorHealthz(version: "v1.4.0", requiredBinaryVersion: "1.8.33", recommendedBinaryVersion: "1.8.65")
        }).run()
        XCTAssertEqual(report.floorStanding, .aboveFloor)
        XCTAssertNil(report.note)
    }

    func testNoFloorPublished() async {
        let report = await runner(fetch: { _ in
            DoctorHealthz(version: "v1.4.0", requiredBinaryVersion: nil, recommendedBinaryVersion: "1.8.65")
        }).run()
        XCTAssertEqual(report.floorStanding, .noFloorConfigured)
    }

    // MARK: - healthz parsing

    func testParseHealthz() throws {
        let body = Data("""
        {"status":"ok","version":"v1.4.0","recommended_binary_version":"1.8.65","required_binary_version":"1.8.33"}
        """.utf8)
        let parsed = try XCTUnwrap(DoctorRunner.parseHealthz(body))
        XCTAssertEqual(parsed.version, "v1.4.0")
        XCTAssertEqual(parsed.requiredBinaryVersion, "1.8.33")
        XCTAssertEqual(parsed.recommendedBinaryVersion, "1.8.65")

        // The coordinator omits required_binary_version when no floor is set.
        let noFloor = try XCTUnwrap(DoctorRunner.parseHealthz(Data("""
        {"status":"ok","version":"v1.4.0","recommended_binary_version":"1.8.65"}
        """.utf8)))
        XCTAssertNil(noFloor.requiredBinaryVersion)

        XCTAssertNil(DoctorRunner.parseHealthz(Data("not json".utf8)))
    }
}
