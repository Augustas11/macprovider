import Foundation
import XCTest
@testable import macprovider_cli

/// SPEC-015 §N.12 (v0.4.10, SPEC-015-R006, #1690 M5): tolerant parsing of the
/// `pool_runtime_authorization` settlement-metadata member, the per-request
/// signing decision, and the informative honest-bug usage guard.
final class PoolRuntimeAuthorizationTests: XCTestCase {
    private static let requestID = "req-pool"
    private static let providerID = "provider-a"
    private static let runtimeSource = LlamaCppLoopbackServeModel.runtimeSource

    private static func metadataWire(authorization: Any?) -> [String: Any] {
        var wire = ReceiptEligibilityFixtures.settlementMetadataWire(
            requestID: requestID,
            providerID: providerID,
            modelID: "mlx-community/Fixture-Model",
            receiptKeyID: "ed25519-sha256:" + String(repeating: "0", count: 64),
            expectedModelHash: String(repeating: "a", count: 64)
        )
        if let authorization {
            wire[PoolRuntimeAuthorization.wireKey] = authorization
        }
        return wire
    }

    private static func authorizationWire() -> [String: Any] {
        ReceiptEligibilityFixtures.poolRuntimeAuthorizationWire(
            runtimeSource: runtimeSource,
            requestID: requestID,
            providerID: providerID
        )
    }

    private static func metadata(authorization: Any?) throws -> SettlementReceiptMetadata {
        try XCTUnwrap(SettlementReceiptMetadata(wire: metadataWire(authorization: authorization)))
    }

    func testWellFormedAuthorizationParses() throws {
        let parsed = try XCTUnwrap(try Self.metadata(authorization: Self.authorizationWire()).poolRuntimeAuthorization)
        XCTAssertEqual(parsed.poolID, "pool-lab-1")
        XCTAssertEqual(parsed.manifestCoreDigest, String(repeating: "6", count: 64))
        XCTAssertEqual(parsed.runtimeSource, Self.runtimeSource)
        XCTAssertEqual(parsed.requestID, Self.requestID)
        XCTAssertEqual(parsed.attemptN, 0)
        XCTAssertEqual(parsed.providerID, Self.providerID)
        XCTAssertEqual(parsed.routeSnapshotDigest, String(repeating: "3", count: 64))
    }

    /// Absent or malformed never invalidates the rest of the settlement
    /// metadata; it only means not authorized.
    func testAbsentOrMalformedAuthorizationParsesAsNotAuthorized() throws {
        XCTAssertNil(try Self.metadata(authorization: nil).poolRuntimeAuthorization)

        func mutated(_ change: (inout [String: Any]) -> Void) -> [String: Any] {
            var wire = Self.authorizationWire()
            change(&wire)
            return wire
        }
        let malformed: [(label: String, value: Any)] = [
            ("not_an_object", "pool-lab-1"),
            ("extra_member", mutated { $0["label_disputed"] = false }),
            ("missing_member", mutated { $0.removeValue(forKey: "manifest_core_digest") }),
            ("uppercase_digest", mutated { $0["route_snapshot_digest"] = String(repeating: "A", count: 64) }),
            ("short_digest", mutated { $0["manifest_core_digest"] = String(repeating: "6", count: 63) }),
            ("empty_runtime_source", mutated { $0["runtime_source"] = "" }),
            ("string_attempt", mutated { $0["attempt_n"] = "0" }),
            ("bool_attempt", mutated { $0["attempt_n"] = false }),
            ("fractional_attempt", mutated { $0["attempt_n"] = 0.5 }),
            ("numeric_provider", mutated { $0["provider_id"] = 7 }),
        ]
        for testCase in malformed {
            let metadata = try Self.metadata(authorization: testCase.value)
            XCTAssertNil(metadata.poolRuntimeAuthorization, testCase.label)
            XCTAssertFalse(
                SettlementReceiptEligibility.poolAuthorizes(
                    runtimeSource: Self.runtimeSource,
                    settlementMetadata: metadata,
                    providerID: Self.providerID
                ),
                testCase.label
            )
        }
    }

    func testAuthorizationFromDecodedJSONParses() throws {
        let data = try JSONSerialization.data(withJSONObject: Self.metadataWire(authorization: Self.authorizationWire()))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let metadata = try XCTUnwrap(SettlementReceiptMetadata(wire: object))
        XCTAssertNotNil(metadata.poolRuntimeAuthorization)
        XCTAssertTrue(SettlementReceiptEligibility.poolAuthorizes(
            runtimeSource: Self.runtimeSource,
            settlementMetadata: metadata,
            providerID: Self.providerID
        ))
    }

    func testDecisionRequiresEveryBoundField() throws {
        let metadata = try Self.metadata(authorization: Self.authorizationWire())
        XCTAssertTrue(SettlementReceiptEligibility.poolAuthorizes(
            runtimeSource: Self.runtimeSource, settlementMetadata: metadata, providerID: Self.providerID
        ))
        XCTAssertFalse(SettlementReceiptEligibility.poolAuthorizes(
            runtimeSource: OllamaLoopbackServeModel.runtimeSource, settlementMetadata: metadata, providerID: Self.providerID
        ))
        XCTAssertFalse(SettlementReceiptEligibility.poolAuthorizes(
            runtimeSource: nil, settlementMetadata: metadata, providerID: Self.providerID
        ))
        XCTAssertFalse(SettlementReceiptEligibility.poolAuthorizes(
            runtimeSource: Self.runtimeSource, settlementMetadata: metadata, providerID: "provider-b"
        ))
        XCTAssertFalse(SettlementReceiptEligibility.poolAuthorizes(
            runtimeSource: Self.runtimeSource, settlementMetadata: metadata, providerID: nil
        ))
        XCTAssertFalse(SettlementReceiptEligibility.poolAuthorizes(
            runtimeSource: Self.runtimeSource, settlementMetadata: nil, providerID: Self.providerID
        ))

        let copied: [(label: String, wire: [String: Any])] = [
            ("other_request", ReceiptEligibilityFixtures.poolRuntimeAuthorizationWire(
                runtimeSource: Self.runtimeSource, requestID: "req-other", providerID: Self.providerID)),
            ("other_attempt", ReceiptEligibilityFixtures.poolRuntimeAuthorizationWire(
                runtimeSource: Self.runtimeSource, requestID: Self.requestID, providerID: Self.providerID, attemptN: 1)),
            ("other_provider", ReceiptEligibilityFixtures.poolRuntimeAuthorizationWire(
                runtimeSource: Self.runtimeSource, requestID: Self.requestID, providerID: "provider-b")),
            ("other_route_snapshot", ReceiptEligibilityFixtures.poolRuntimeAuthorizationWire(
                runtimeSource: Self.runtimeSource, requestID: Self.requestID, providerID: Self.providerID,
                routeSnapshotDigest: String(repeating: "5", count: 64))),
        ]
        for testCase in copied {
            XCTAssertFalse(
                SettlementReceiptEligibility.poolAuthorizes(
                    runtimeSource: Self.runtimeSource,
                    settlementMetadata: try Self.metadata(authorization: testCase.wire),
                    providerID: Self.providerID
                ),
                testCase.label
            )
        }
    }

    func testLoopbackRuntimesDeclareTheirRuntimeSourceAndNativeDoesNot() throws {
        let loopback = try ReceiptEligibilityFixtures.makeOllamaLoopbackRuntime(testCase: self)
        XCTAssertFalse(loopback.runtime.isSettlementReceiptEligible)
        XCTAssertEqual(loopback.runtime.settlementRuntimeSource, OllamaLoopbackServeModel.runtimeSource)
        XCTAssertNil(ReceiptEligibilityFixtures.makeRelayBlindFixtureRuntime().settlementRuntimeSource)
    }

    // MARK: honest-bug guard (§N.12 item 5, informative)

    func testUsageGuardToleranceIsSmall() {
        XCTAssertFalse(PoolLoopbackUsageGuard.isDivergent(reported: 10, recounted: 18))
        XCTAssertTrue(PoolLoopbackUsageGuard.isDivergent(reported: 10, recounted: 19))
        XCTAssertFalse(PoolLoopbackUsageGuard.isDivergent(reported: 1000, recounted: 1050))
        XCTAssertTrue(PoolLoopbackUsageGuard.isDivergent(reported: 1000, recounted: 1051))
        XCTAssertTrue(PoolLoopbackUsageGuard.isDivergent(reported: 1000, recounted: 900))
    }

    func testUsageGuardAppliesToGGUFRuntimesOnly() throws {
        let gguf = try XCTUnwrap(try Self.metadata(authorization: Self.authorizationWire()).poolRuntimeAuthorization)
        XCTAssertTrue(PoolLoopbackUsageGuard.applies(to: gguf))
        let mlx = try XCTUnwrap(try Self.metadata(authorization: ReceiptEligibilityFixtures.poolRuntimeAuthorizationWire(
            runtimeSource: "mlx_cache", requestID: Self.requestID, providerID: Self.providerID
        )).poolRuntimeAuthorization)
        XCTAssertFalse(PoolLoopbackUsageGuard.applies(to: mlx))
    }

    func testUsageGuardWithoutSiblingTokenizerAlertsUnavailableOnly() async throws {
        let metadata = try Self.metadata(authorization: Self.authorizationWire())
        let authorization = try XCTUnwrap(metadata.poolRuntimeAuthorization)
        let records = PoolGuardRecordSink()
        let status = await ReceiptAudit.withSink({ record in records.append(record) }) {
            await PoolLoopbackUsageGuard.check(
                settlementMetadata: metadata,
                authorization: authorization,
                providerID: Self.providerID,
                completionText: "answer",
                reportedCompletionTokens: 3,
                snapshotDirectory: { _ in nil }
            )
        }
        XCTAssertEqual(status, .tokenizerUnavailable)
        let lines = records.all.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?["event"] as? String, "pool_usage_recount")
        XCTAssertEqual(lines.first?["status"] as? String, "tokenizer_unavailable")
        XCTAssertEqual(lines.first?["reported_completion_tokens"] as? Int, 3)
        XCTAssertTrue(lines.first?["recounted_completion_tokens"] is NSNull)
        XCTAssertEqual(lines.first?["pool_id"] as? String, "pool-lab-1")
    }
}

private final class PoolGuardRecordSink: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [Data] = []

    func append(_ record: Data) {
        lock.lock()
        records.append(record)
        lock.unlock()
    }

    var all: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }
}
