import CryptoKit
import Foundation
import XCTest
@testable import malibu_cli

final class SPEC015V04SettlementFixtureTests: XCTestCase {
    private static let routeSnapshotKeys: Set<String> = [
        "account_scope",
        "attempt_n",
        "catalog_body_digest",
        "catalog_expires_at_unix_ms",
        "catalog_id",
        "catalog_signature_key_id",
        "catalog_signature_pubkey_fingerprint",
        "expected_catalog_model_hash",
        "model_id",
        "paid_entrypoint",
        "pending_deadline_seconds",
        "prompt_hash",
        "prompt_hash_basis",
        "provider_generation_id",
        "provider_id",
        "provider_receipt_key_id",
        "provider_receipt_key_source",
        "provider_reported_model_hash",
        "provider_session_id",
        "request_id",
        "request_start_ts_unix_ms",
        "route_decision_ts_unix_ms",
        "route_snapshot_mode",
        "route_snapshot_policy_version",
        "spec008_hash_status",
    ]

    private static let settlementOutputKeys: Set<String> = [
        "content",
        "finish_reason",
        "output_prefix_end_byte",
        "output_prefix_start_byte",
        "terminal_state",
        "tool_calls",
    ]

    private static let usageKeys: Set<String> = [
        "billable_input_tokens",
        "billable_output_tokens",
        "delivered_output_bytes",
        "observed_input_tokens",
        "observed_output_tokens",
    ]

    private static let receiptTupleKeys: Set<String> = [
        "account_scope",
        "attempt_n",
        "catalog_body_digest",
        "catalog_id",
        "expected_catalog_model_hash",
        "issued_at_unix_ms",
        "model_hash",
        "model_id",
        "output_hash",
        "output_prefix_end_byte",
        "output_prefix_start_byte",
        "prompt_hash",
        "provider_id",
        "provider_receipt_key_id",
        "receipt_version",
        "request_id",
        "route_snapshot_digest",
        "route_snapshot_mode",
        "route_snapshot_policy_version",
        "signature_key_alg",
        "terminal_state",
        "terminal_state_ts_unix_ms",
        "usage",
    ]

    func testV04SettlementFixturesMatchSwiftJCS() throws {
        let fixtures = try Self.loadFixtures()

        for fixture in fixtures.objects {
            let value = try Self.jcsValue(from: fixture.value, kind: fixture.kind)
            let canonical = try RFC8785JCS.canonicalString(value)
            XCTAssertEqual(
                Data(canonical.utf8).base64EncodedString(),
                fixture.expectedCanonicalB64,
                "canonical bytes drifted for \(fixture.id)"
            )
            XCTAssertEqual(Self.sha256Hex(canonical), fixture.expectedSHA256Hex, "hash drifted for \(fixture.id)")
            let expectedKeys = try Self.strictKeys(for: fixture.kind)
            XCTAssertEqual(Set(fixture.strictKeys), expectedKeys, "fixture strict_keys drifted for \(fixture.id)")
            XCTAssertEqual(Set(fixture.value.keys), expectedKeys, "strict key set drifted for \(fixture.id)")
        }
    }

    func testV04SignedTupleFixturesSelfVerify() throws {
        let fixtures = try Self.loadFixtures()
        let pubkeyData = try XCTUnwrap(Data(base64Encoded: fixtures.providerReceiptPubkeyB64))
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: pubkeyData)
        let expectedKeyID = "ed25519-sha256:\(Self.sha256Hex(pubkeyData))"
        XCTAssertEqual(fixtures.providerReceiptKeyID, expectedKeyID)

        for tuple in fixtures.receiptTuples {
            let value = try Self.jcsValue(from: tuple.value, kind: "receipt_tuple_v4")
            let canonical = try RFC8785JCS.canonicalString(value)
            let canonicalData = Data(canonical.utf8)
            let signature = try XCTUnwrap(Data(base64Encoded: tuple.signatureB64), "signature base64 for \(tuple.id)")
            let receiptParts = tuple.wireReceipt.split(separator: ".")

            XCTAssertEqual(tuple.value["receipt_version"] as? String, "4", "receipt_version drifted for \(tuple.id)")
            XCTAssertEqual(tuple.value["signature_key_alg"] as? String, "Ed25519", "signature_key_alg drifted for \(tuple.id)")
            XCTAssertEqual(tuple.value["provider_receipt_key_id"] as? String, expectedKeyID, "receipt key id drifted for \(tuple.id)")
            XCTAssertEqual(Set(tuple.strictKeys), Self.receiptTupleKeys, "fixture strict_keys drifted for \(tuple.id)")
            XCTAssertEqual(Set(tuple.value.keys), Self.receiptTupleKeys, "strict tuple key set drifted for \(tuple.id)")
            XCTAssertEqual(canonicalData.base64EncodedString(), tuple.expectedCanonicalB64, "canonical tuple drifted for \(tuple.id)")
            XCTAssertEqual(Self.sha256Hex(canonical), tuple.expectedSHA256Hex, "tuple hash drifted for \(tuple.id)")
            XCTAssertEqual(receiptParts.count, 2, "wire receipt shape drifted for \(tuple.id)")
            XCTAssertEqual(String(receiptParts[0]), tuple.expectedCanonicalB64, "wire tuple segment drifted for \(tuple.id)")
            XCTAssertEqual(String(receiptParts[1]), tuple.signatureB64, "wire signature segment drifted for \(tuple.id)")
            XCTAssertTrue(publicKey.isValidSignature(signature, for: canonicalData), "signature failed for \(tuple.id)")
        }
    }

    func testV04SettlementOutputPreservesRawToolArguments() throws {
        let fixtures = try Self.loadFixtures()
        let fixture = try XCTUnwrap(
            fixtures.objects.first { $0.id == "settlement_output_streaming_tool_call_nonzero_prefix" },
            "streaming tool-call settlement output fixture"
        )
        let value = try Self.jcsValue(from: fixture.value, kind: fixture.kind)
        let canonical = try RFC8785JCS.canonicalString(value)

        XCTAssertTrue(
            canonical.contains(#""content":"Use <tag>& Café.""#),
            "content should be NFC-normalized in canonical bytes"
        )
        XCTAssertTrue(
            canonical.contains(#""arguments":"{\"query\":\"<tag>& Café\"}""#),
            "tool-call arguments should preserve raw decomposed bytes"
        )
    }

    func testV04SignedTuplesCoverTerminalStateMatrix() throws {
        let fixtures = try Self.loadFixtures()
        let objectsByID = Dictionary(uniqueKeysWithValues: fixtures.objects.map { ($0.id, $0) })
        var seen = Set<String>()

        for tuple in fixtures.receiptTuples {
            let output = try XCTUnwrap(objectsByID[tuple.settlementOutputID], "output \(tuple.settlementOutputID)")
            let usage = try XCTUnwrap(tuple.value["usage"] as? [String: Any], "usage for \(tuple.id)")
            let state = try XCTUnwrap(tuple.value["terminal_state"] as? String, "terminal_state for \(tuple.id)")
            let delivered = try XCTUnwrap(Self.int64(usage["delivered_output_bytes"]))
            let inputTokens = try XCTUnwrap(Self.int64(usage["billable_input_tokens"]))
            let outputTokens = try XCTUnwrap(Self.int64(usage["billable_output_tokens"]))
            let observedInputTokens = try XCTUnwrap(Self.int64(usage["observed_input_tokens"]))
            let observedTokens = try XCTUnwrap(Self.int64(usage["observed_output_tokens"]))
            let bucket = delivered == 0 ? "zero" : "nonzero"
            seen.insert("\(state):\(bucket)")

            XCTAssertFalse(output.id.isEmpty, "output fixture must be present for \(tuple.id)")
            if state == "normal_done" {
                XCTAssertEqual(inputTokens, observedInputTokens, "normal_done billable input must equal observed input for \(tuple.id)")
                XCTAssertEqual(outputTokens, observedTokens, "normal_done billable output must equal observed output for \(tuple.id)")
            } else if delivered == 0 {
                XCTAssertEqual(inputTokens, 0, "zero-prefix \(state) must have zero billable input tokens for \(tuple.id)")
                XCTAssertEqual(outputTokens, 0, "zero-prefix \(state) must have zero billable output tokens for \(tuple.id)")
            } else {
                XCTAssertGreaterThan(inputTokens, 0, "nonzero \(state) must have billable input tokens for \(tuple.id)")
                XCTAssertLessThanOrEqual(inputTokens, observedInputTokens, "nonzero \(state) billable input tokens exceed observed tokens for \(tuple.id)")
                XCTAssertGreaterThan(outputTokens, 0, "nonzero \(state) must have billable output tokens for \(tuple.id)")
                XCTAssertLessThanOrEqual(outputTokens, observedTokens, "nonzero \(state) billable output tokens exceed observed tokens for \(tuple.id)")
            }
        }

        let required: Set<String> = [
            "normal_done:zero",
            "normal_done:nonzero",
            "provider_error:zero",
            "provider_error:nonzero",
            "buyer_cancel:zero",
            "buyer_cancel:nonzero",
            "gateway_timeout:zero",
            "gateway_timeout:nonzero",
            "upstream_transport_disconnect:zero",
            "upstream_transport_disconnect:nonzero",
        ]
        let missing = required.subtracting(seen)
        XCTAssertTrue(missing.isEmpty, "missing signed terminal-state matrix cells: \(missing)")
    }

    func testV04TupleFixturesBindLinkedRouteOutputAndUsage() throws {
        let fixtures = try Self.loadFixtures()
        let objectsByID = Dictionary(uniqueKeysWithValues: fixtures.objects.map { ($0.id, $0) })

        for tuple in fixtures.receiptTuples {
            let route = try XCTUnwrap(objectsByID[tuple.routeSnapshotID], "route snapshot \(tuple.routeSnapshotID) for \(tuple.id)")
            let output = try XCTUnwrap(objectsByID[tuple.settlementOutputID], "settlement output \(tuple.settlementOutputID) for \(tuple.id)")
            let usage = try XCTUnwrap(objectsByID[tuple.usageID], "usage \(tuple.usageID) for \(tuple.id)")

            XCTAssertEqual(Self.int64(tuple.value["attempt_n"]), Self.int64(route.value["attempt_n"]), "attempt binding drifted for \(tuple.id)")
            Self.assertRouteBoundFields(tuple: tuple, route: route)
            XCTAssertEqual(tuple.value["route_snapshot_digest"] as? String, route.expectedSHA256Hex, "route digest drifted for \(tuple.id)")
            XCTAssertEqual(tuple.value["output_hash"] as? String, output.expectedSHA256Hex, "output hash drifted for \(tuple.id)")
            XCTAssertEqual(Self.int64(tuple.value["output_prefix_start_byte"]), Self.int64(output.value["output_prefix_start_byte"]), "prefix start drifted for \(tuple.id)")
            XCTAssertEqual(Self.int64(tuple.value["output_prefix_end_byte"]), Self.int64(output.value["output_prefix_end_byte"]), "prefix end drifted for \(tuple.id)")
            XCTAssertEqual(tuple.value["terminal_state"] as? String, output.value["terminal_state"] as? String, "terminal state drifted for \(tuple.id)")

            let tupleUsage = try XCTUnwrap(tuple.value["usage"] as? [String: Any], "tuple usage for \(tuple.id)")
            XCTAssertEqual(Set(tupleUsage.keys), Self.usageKeys, "strict usage key set drifted for \(tuple.id)")
            for field in Self.usageKeys {
                XCTAssertEqual(
                    Self.int64(tupleUsage[field]),
                    Self.int64(usage.value[field]),
                    "linked usage.\(field) drifted for \(tuple.id)"
                )
            }
            let deliveredBytes = try XCTUnwrap(Self.int64(tupleUsage["delivered_output_bytes"]))
            let prefixStart = try XCTUnwrap(Self.int64(tuple.value["output_prefix_start_byte"]))
            let prefixEnd = try XCTUnwrap(Self.int64(tuple.value["output_prefix_end_byte"]))
            XCTAssertGreaterThanOrEqual(prefixStart, 0, "prefix start must be nonnegative for \(tuple.id)")
            XCTAssertGreaterThanOrEqual(prefixEnd, 0, "prefix end must be nonnegative for \(tuple.id)")
            XCTAssertLessThanOrEqual(prefixStart, prefixEnd, "prefix range must be ordered for \(tuple.id)")
            XCTAssertEqual(deliveredBytes, prefixEnd - prefixStart, "usage delivered bytes must match prefix range for \(tuple.id)")
            let content = try XCTUnwrap(output.value["content"] as? String, "content for \(output.id)")
            let canonicalContentBytes = Int64(content.precomposedStringWithCanonicalMapping.data(using: .utf8)?.count ?? -1)
            XCTAssertEqual(deliveredBytes, canonicalContentBytes, "delivered bytes must match canonical content bytes for \(tuple.id)")
            XCTAssertEqual(prefixStart + deliveredBytes, prefixEnd, "prefix start plus delivered bytes must equal prefix end for \(tuple.id)")
        }
    }

    func testV04ReceiptTupleRangesDoNotOverlapWithinRequest() throws {
        let fixtures = try Self.loadFixtures()
        let byRequest = Dictionary(grouping: fixtures.receiptTuples) { tuple in
            tuple.value["request_id"] as? String ?? ""
        }
        for (requestID, tuples) in byRequest {
            let byAttempt = tuples.sorted {
                (Self.int64($0.value["attempt_n"]) ?? -1) <
                    (Self.int64($1.value["attempt_n"]) ?? -1)
            }
            for (expectedAttempt, tuple) in byAttempt.enumerated() {
                let attempt = try XCTUnwrap(Self.int64(tuple.value["attempt_n"]), "attempt_n for \(tuple.id)")
                XCTAssertEqual(
                    attempt,
                    Int64(expectedAttempt),
                    "\(requestID) attempt sequence mismatch at \(tuple.id)"
                )
            }

            let sorted = tuples.sorted {
                (Self.int64($0.value["output_prefix_start_byte"]) ?? -1) <
                    (Self.int64($1.value["output_prefix_start_byte"]) ?? -1)
            }
            for index in sorted.indices.dropFirst() {
                let previousEnd = try XCTUnwrap(Self.int64(sorted[index - 1].value["output_prefix_end_byte"]))
                let start = try XCTUnwrap(Self.int64(sorted[index].value["output_prefix_start_byte"]))
                XCTAssertGreaterThanOrEqual(
                    start,
                    previousEnd,
                    "\(requestID) overlapping ranges: \(sorted[index - 1].id) ends at \(previousEnd), \(sorted[index].id) starts at \(start)"
                )
            }
        }

        let chain = try XCTUnwrap(byRequest["req_spec015_v04_chain_0001"], "contiguous chain fixtures")
            .sorted {
                (Self.int64($0.value["output_prefix_start_byte"]) ?? -1) <
                    (Self.int64($1.value["output_prefix_start_byte"]) ?? -1)
        }
        XCTAssertEqual(chain.count, 2)
        XCTAssertEqual(chain[0].id, "receipt_tuple_v4_failover_upstream_disconnect_prefix")
        XCTAssertEqual(chain[0].settlementOutputID, "settlement_output_failover_upstream_disconnect_prefix")
        XCTAssertEqual(Self.int64(chain[0].value["attempt_n"]), 0)
        XCTAssertEqual(Self.int64(chain[0].value["output_prefix_start_byte"]), 0)
        XCTAssertEqual(Self.int64(chain[0].value["output_prefix_end_byte"]), 13)
        XCTAssertEqual(chain[0].value["terminal_state"] as? String, "upstream_transport_disconnect")
        XCTAssertEqual(chain[1].id, "receipt_tuple_v4_streaming_tool_call_nonzero_prefix")
        XCTAssertEqual(chain[1].settlementOutputID, "settlement_output_streaming_tool_call_nonzero_prefix")
        XCTAssertEqual(Self.int64(chain[1].value["attempt_n"]), 1)
        XCTAssertEqual(Self.int64(chain[1].value["output_prefix_start_byte"]), 13)
        XCTAssertEqual(Self.int64(chain[1].value["output_prefix_end_byte"]), 30)
        XCTAssertEqual(chain[1].value["terminal_state"] as? String, "normal_done")
    }

    func testV04NegativeRangeScenariosFailExpectedChecks() throws {
        let fixtures = try Self.loadFixtures()
        XCTAssertFalse(fixtures.negativeRangeScenarios.isEmpty)
        for scenario in fixtures.negativeRangeScenarios {
            switch scenario.expectedFailure {
            case "overlapping_ranges":
                XCTAssertTrue(Self.hasOverlappingRangesByAttempt(scenario.ranges), scenario.id)
            case "duplicate_ranges":
                XCTAssertTrue(Self.hasDuplicateRanges(scenario.ranges), scenario.id)
            case "out_of_order_ranges":
                XCTAssertTrue(Self.hasOutOfOrderRangesByAttempt(scenario.ranges), scenario.id)
            default:
                XCTFail("unknown expected failure \(scenario.expectedFailure) for \(scenario.id)")
            }
        }
    }

    func testV04NegativeReceiptFixturesFailExpectedChecks() throws {
        let fixtures = try Self.loadFixtures()
        let pubkeyData = try XCTUnwrap(Data(base64Encoded: fixtures.providerReceiptPubkeyB64))
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: pubkeyData)
        let objectsByID = Dictionary(uniqueKeysWithValues: fixtures.objects.map { ($0.id, $0) })
        let tuplesByID = Dictionary(uniqueKeysWithValues: fixtures.receiptTuples.map { ($0.id, $0) })
        XCTAssertFalse(fixtures.negativeReceipts.isEmpty)

        for negative in fixtures.negativeReceipts {
            let base = try XCTUnwrap(tuplesByID[negative.baseTupleID], "base tuple \(negative.baseTupleID)")
            let value = try Self.jcsValue(from: negative.value, kind: "receipt_tuple_v4")
            let canonical = try RFC8785JCS.canonicalString(value)
            let canonicalData = Data(canonical.utf8)
            let signature = try XCTUnwrap(Data(base64Encoded: negative.signatureB64), "signature for \(negative.id)")
            let signatureValid = publicKey.isValidSignature(signature, for: canonicalData)
            XCTAssertEqual(canonicalData.base64EncodedString(), negative.expectedCanonicalB64, "canonical drifted for \(negative.id)")

            switch negative.expectedFailure {
            case "output_hash_mismatch":
                let output = try XCTUnwrap(objectsByID[base.settlementOutputID], "output for \(base.id)")
                XCTAssertNotEqual(negative.value["output_hash"] as? String, output.expectedSHA256Hex)
                XCTAssertTrue(signatureValid)
            case "route_snapshot_digest_mismatch":
                let route = try XCTUnwrap(objectsByID[base.routeSnapshotID], "route for \(base.id)")
                XCTAssertNotEqual(negative.value["route_snapshot_digest"] as? String, route.expectedSHA256Hex)
                XCTAssertTrue(signatureValid)
            case "model_hash_mismatch":
                let route = try XCTUnwrap(objectsByID[base.routeSnapshotID], "route for \(base.id)")
                XCTAssertNotEqual(negative.value["model_hash"] as? String, route.value["provider_reported_model_hash"] as? String)
                XCTAssertNotEqual(negative.value["model_hash"] as? String, route.value["expected_catalog_model_hash"] as? String)
                XCTAssertTrue(signatureValid)
            case "terminal_state_mismatch":
                let output = try XCTUnwrap(objectsByID[base.settlementOutputID], "output for \(base.id)")
                XCTAssertNotEqual(negative.value["terminal_state"] as? String, output.value["terminal_state"] as? String)
                XCTAssertTrue(signatureValid)
            case "terminal_state_out_of_enum":
                XCTAssertEqual(negative.value["terminal_state"] as? String, "provider_claimed_done")
                XCTAssertTrue(signatureValid)
            case "attempt_mismatch":
                let route = try XCTUnwrap(objectsByID[base.routeSnapshotID], "route for \(base.id)")
                XCTAssertNotEqual(Self.int64(negative.value["attempt_n"]), Self.int64(route.value["attempt_n"]))
                XCTAssertTrue(signatureValid)
            case "wrong_key_signature":
                XCTAssertFalse(signatureValid)
            case "legacy_receipt_version":
                XCTAssertNotEqual(negative.value["receipt_version"] as? String, "4")
                XCTAssertTrue(signatureValid)
            case "strict_shape_missing_output_hash":
                XCTAssertNil(negative.value["output_hash"])
                XCTAssertTrue(signatureValid)
            case "usage_delivered_bytes_mismatch":
                let usage = try XCTUnwrap(negative.value["usage"] as? [String: Any], "usage for \(negative.id)")
                let start = try XCTUnwrap(Self.int64(negative.value["output_prefix_start_byte"]))
                let end = try XCTUnwrap(Self.int64(negative.value["output_prefix_end_byte"]))
                let delivered = try XCTUnwrap(Self.int64(usage["delivered_output_bytes"]))
                XCTAssertNotEqual(delivered, end - start)
                XCTAssertTrue(signatureValid)
            case "usage_negative_value":
                let usage = try XCTUnwrap(negative.value["usage"] as? [String: Any], "usage for \(negative.id)")
                let inputTokens = try XCTUnwrap(Self.int64(usage["billable_input_tokens"]))
                XCTAssertLessThan(inputTokens, 0)
                XCTAssertTrue(signatureValid)
            case "usage_null":
                XCTAssertTrue(negative.value["usage"] is NSNull)
                XCTAssertTrue(signatureValid)
            case "usage_missing_required_field":
                let usage = try XCTUnwrap(negative.value["usage"] as? [String: Any], "usage for \(negative.id)")
                XCTAssertNil(usage["observed_output_tokens"])
                XCTAssertTrue(signatureValid)
            case "usage_extra_field":
                let usage = try XCTUnwrap(negative.value["usage"] as? [String: Any], "usage for \(negative.id)")
                XCTAssertNotNil(usage["unsettled_extra_tokens"])
                XCTAssertTrue(signatureValid)
            case "strict_shape_extra_top_level_field":
                XCTAssertNotNil(negative.value["unexpected_settlement_field"])
                XCTAssertTrue(signatureValid)
            default:
                XCTFail("unknown expected failure \(negative.expectedFailure) for \(negative.id)")
            }
        }
    }

    private static func assertRouteBoundFields(tuple: TupleFixture, route: ObjectFixture) {
        let fieldPairs = [
            "account_scope": "account_scope",
            "catalog_body_digest": "catalog_body_digest",
            "catalog_id": "catalog_id",
            "expected_catalog_model_hash": "expected_catalog_model_hash",
            "model_id": "model_id",
            "prompt_hash": "prompt_hash",
            "provider_id": "provider_id",
            "provider_receipt_key_id": "provider_receipt_key_id",
            "request_id": "request_id",
            "route_snapshot_mode": "route_snapshot_mode",
            "route_snapshot_policy_version": "route_snapshot_policy_version",
        ]
        for (tupleField, routeField) in fieldPairs {
            XCTAssertEqual(
                tuple.value[tupleField] as? String,
                route.value[routeField] as? String,
                "\(tuple.id) \(tupleField) drifted from route \(routeField)"
            )
        }
        XCTAssertEqual(
            tuple.value["model_hash"] as? String,
            route.value["provider_reported_model_hash"] as? String,
            "\(tuple.id) model_hash drifted from provider_reported_model_hash"
        )
        XCTAssertEqual(
            tuple.value["model_hash"] as? String,
            route.value["expected_catalog_model_hash"] as? String,
            "\(tuple.id) model_hash drifted from expected_catalog_model_hash"
        )
    }

    private static func hasOverlappingRangesByAttempt(_ ranges: [RangeFixture]) -> Bool {
        let ordered = ranges.sorted { $0.attempt < $1.attempt }
        for index in ordered.indices.dropFirst() where ordered[index].start < ordered[index - 1].end {
            return true
        }
        return false
    }

    private static func hasDuplicateRanges(_ ranges: [RangeFixture]) -> Bool {
        var seen: Set<String> = []
        for item in ranges {
            let key = "\(item.start):\(item.end)"
            if seen.contains(key) {
                return true
            }
            seen.insert(key)
        }
        return false
    }

    private static func hasOutOfOrderRangesByAttempt(_ ranges: [RangeFixture]) -> Bool {
        let ordered = ranges.sorted { $0.attempt < $1.attempt }
        for index in ordered.indices.dropFirst() where ordered[index].start < ordered[index - 1].start {
            return true
        }
        return false
    }

    private struct Fixtures {
        let providerReceiptPubkeyB64: String
        let providerReceiptKeyID: String
        let objects: [ObjectFixture]
        let receiptTuples: [TupleFixture]
        let negativeReceipts: [TupleFixture]
        let negativeRangeScenarios: [RangeScenario]
    }

    private struct ObjectFixture {
        let id: String
        let kind: String
        let value: [String: Any]
        let strictKeys: [String]
        let expectedCanonicalB64: String
        let expectedSHA256Hex: String
    }

    private struct TupleFixture {
        let id: String
        let baseTupleID: String
        let expectedFailure: String
        let routeSnapshotID: String
        let settlementOutputID: String
        let usageID: String
        let value: [String: Any]
        let strictKeys: [String]
        let expectedCanonicalB64: String
        let expectedSHA256Hex: String
        let signatureB64: String
        let wireReceipt: String
    }

    private struct RangeScenario {
        let id: String
        let requestID: String
        let expectedFailure: String
        let ranges: [RangeFixture]
    }

    private struct RangeFixture {
        let tupleID: String
        let attempt: Int64
        let start: Int64
        let end: Int64
    }

    private static func loadFixtures() throws -> Fixtures {
        let data = try Data(contentsOf: fixtureURL())
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pubkey = root["provider_receipt_pubkey_b64"] as? String,
              let keyID = root["provider_receipt_key_id"] as? String,
              let objects = root["objects"] as? [[String: Any]],
              let tuples = root["receipt_tuples"] as? [[String: Any]],
              let negativeReceipts = root["negative_receipts"] as? [[String: Any]],
              let negativeRangeScenarios = root["negative_range_scenarios"] as? [[String: Any]] else {
            throw FixtureError.invalidShape("expected v0.4 fixture root")
        }
        return Fixtures(
            providerReceiptPubkeyB64: pubkey,
            providerReceiptKeyID: keyID,
            objects: try objects.map(objectFixture),
            receiptTuples: try tuples.map(tupleFixture),
            negativeReceipts: try negativeReceipts.map(tupleFixture),
            negativeRangeScenarios: try negativeRangeScenarios.map(rangeScenario)
        )
    }

    private static func objectFixture(_ raw: [String: Any]) throws -> ObjectFixture {
        guard let id = raw["id"] as? String,
              let kind = raw["kind"] as? String,
              let value = raw["value"] as? [String: Any],
              let strictKeys = raw["strict_keys"] as? [String],
              let expectedCanonicalB64 = raw["expected_canonical_b64"] as? String,
              let expectedSHA256Hex = raw["expected_sha256_hex"] as? String else {
            throw FixtureError.invalidShape("invalid object fixture")
        }
        return ObjectFixture(
            id: id,
            kind: kind,
            value: value,
            strictKeys: strictKeys,
            expectedCanonicalB64: expectedCanonicalB64,
            expectedSHA256Hex: expectedSHA256Hex
        )
    }

    private static func rangeScenario(_ raw: [String: Any]) throws -> RangeScenario {
        guard let id = raw["id"] as? String,
              let requestID = raw["request_id"] as? String,
              let expectedFailure = raw["expected_failure"] as? String,
              let ranges = raw["ranges"] as? [[String: Any]] else {
            throw FixtureError.invalidShape("invalid range scenario")
        }
        return RangeScenario(
            id: id,
            requestID: requestID,
            expectedFailure: expectedFailure,
            ranges: try ranges.map(rangeFixture)
        )
    }

    private static func rangeFixture(_ raw: [String: Any]) throws -> RangeFixture {
        guard let tupleID = raw["tuple_id"] as? String,
              let attempt = int64(raw["attempt_n"]),
              let start = int64(raw["output_prefix_start_byte"]),
              let end = int64(raw["output_prefix_end_byte"]) else {
            throw FixtureError.invalidShape("invalid range fixture")
        }
        return RangeFixture(tupleID: tupleID, attempt: attempt, start: start, end: end)
    }

    private static func tupleFixture(_ raw: [String: Any]) throws -> TupleFixture {
        guard let id = raw["id"] as? String,
              let routeSnapshotID = raw["route_snapshot_id"] as? String,
              let settlementOutputID = raw["settlement_output_id"] as? String,
              let usageID = raw["usage_id"] as? String,
              let value = raw["value"] as? [String: Any],
              let strictKeys = raw["strict_keys"] as? [String],
              let expectedCanonicalB64 = raw["expected_canonical_b64"] as? String,
              let expectedSHA256Hex = raw["expected_sha256_hex"] as? String,
              let signatureB64 = raw["signature_b64"] as? String,
              let wireReceipt = raw["wire_receipt"] as? String else {
            throw FixtureError.invalidShape("invalid tuple fixture")
        }
        return TupleFixture(
            id: id,
            baseTupleID: raw["base_tuple_id"] as? String ?? "",
            expectedFailure: raw["expected_failure"] as? String ?? "",
            routeSnapshotID: routeSnapshotID,
            settlementOutputID: settlementOutputID,
            usageID: usageID,
            value: value,
            strictKeys: strictKeys,
            expectedCanonicalB64: expectedCanonicalB64,
            expectedSHA256Hex: expectedSHA256Hex,
            signatureB64: signatureB64,
            wireReceipt: wireReceipt
        )
    }

    private static func fixtureURL() -> URL {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return repoRoot
            .appendingPathComponent("testdata")
            .appendingPathComponent("spec015")
            .appendingPathComponent("v04_settlement_receipts.json")
    }

    private static func jcsValue(from input: Any, kind: String) throws -> RFC8785JCS.Value {
        try jcsValue(from: input, rawToolCallArguments: kind == "settlement_output_v1", path: [])
    }

    private static func jcsValue(
        from input: Any,
        rawToolCallArguments: Bool,
        path: [String]
    ) throws -> RFC8785JCS.Value {
        if let object = input as? [String: Any] {
            var members: [String: RFC8785JCS.Value] = [:]
            for (key, value) in object {
                let childPath = path + [key]
                if rawToolCallArguments,
                   isToolCallArgumentPath(childPath),
                   let raw = value as? String {
                    members[key] = .rawString(raw)
                } else {
                    members[key] = try jcsValue(
                        from: value,
                        rawToolCallArguments: rawToolCallArguments,
                        path: childPath
                    )
                }
            }
            return .object(members)
        }
        if let array = input as? [Any] {
            return .array(try array.map {
                try jcsValue(from: $0, rawToolCallArguments: rawToolCallArguments, path: path)
            })
        }
        if let string = input as? String {
            return .string(string)
        }
        if input is NSNull {
            return .null
        }
        if let number = input as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            let type = String(cString: number.objCType)
            if type == "d" || type == "f" {
                return .double(number.doubleValue)
            }
            guard let int = Int(exactly: number.int64Value) else {
                throw FixtureError.invalidShape("integer \(number) does not fit Swift Int")
            }
            return .int(int)
        }
        throw FixtureError.invalidShape("unsupported JSON value \(type(of: input))")
    }

    private static func isToolCallArgumentPath(_ path: [String]) -> Bool {
        guard path.count >= 3,
              Array(path.suffix(2)) == ["function", "arguments"] else {
            return false
        }
        return path.dropLast(2).contains("tool_calls")
    }

    private static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256Hex(_ value: Data) -> String {
        SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
    }

    private static func strictKeys(for kind: String) throws -> Set<String> {
        switch kind {
        case "route_snapshot_v1":
            return routeSnapshotKeys
        case "settlement_output_v1":
            return settlementOutputKeys
        case "usage":
            return usageKeys
        default:
            throw FixtureError.invalidShape("unknown fixture kind \(kind)")
        }
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber {
            return number.int64Value
        }
        return nil
    }

    private enum FixtureError: Error {
        case invalidShape(String)
    }
}
