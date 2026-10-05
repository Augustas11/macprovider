import CryptoKit
import Foundation
import XCTest
@testable import macprovider_cli

/// SPEC-015 §N.13 (SPEC-015-R007) parity vectors and SPEC-001-R005 metadata.
/// The fixture's signatures are RFC 8032 (deterministic). CryptoKit Ed25519
/// signatures are randomized, so the Swift builder must match the fixture's
/// JCS bytes exactly and produce a signature that verifies, while the fixture
/// signature must verify over the same bytes.
final class RelayBlindSettlementReceiptTests: XCTestCase {
    private static let tupleFields: Set<String> = [
        "account_scope", "attempt_n", "catalog_body_digest", "catalog_id", "expected_catalog_model_hash",
        "input_token_upper_bound", "issued_at_unix_ms", "max_output_tokens", "model_hash", "model_id",
        "paid_entrypoint", "privacy_class", "prompt_hash_basis", "provider_id", "provider_receipt_key_id",
        "receipt_version", "relay_blind_envelope_digest", "relay_blind_execution_auth_digest", "relay_blind_kid",
        "relay_blind_provider_binding_digest", "request_id", "response_body_bytes", "response_body_sha256",
        "route_snapshot_digest", "route_snapshot_mode", "route_snapshot_policy_version", "signature_key_alg",
        "terminal_state", "terminal_state_ts_unix_ms", "usage",
    ]

    func testFixtureSigningKeyDerivesPublishedPublicKeyAndKeyID() throws {
        let fixture = try Self.fixture()
        let key = try Self.signingKey(fixture)
        XCTAssertEqual(key.publicKey.rawRepresentation.base64EncodedString(), fixture["signing_public_key_b64"] as? String)
        let digest = SHA256.hash(data: key.publicKey.rawRepresentation).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual("ed25519-sha256:" + digest, fixture["provider_receipt_key_id"] as? String)
    }

    func testBuilderMatchesEveryPositiveVectorByteForByte() throws {
        let fixture = try Self.fixture()
        let key = try Self.signingKey(fixture)
        let positives = try XCTUnwrap(fixture["positive"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(positives.count, 2)
        XCTAssertTrue(positives.contains { $0["stream"] as? Bool == true })
        XCTAssertTrue(positives.contains { $0["stream"] as? Bool == false })
        for vector in positives {
            let name = vector["id"] as? String ?? "?"
            let input = try Self.receiptInput(vector, fixture: fixture)
            let store = InMemoryReceiptKeyStore()
            try store.storeNew(providerId: input.metadata.providerID, privateKey: key)
            let envelope = try ReceiptBuilder(keyStore: store)
                .buildRelayBlindSettlement(providerId: input.metadata.providerID, input: input)
            let parts = envelope.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            XCTAssertEqual(parts.count, 2, name)
            let tupleBytes = try XCTUnwrap(Data(base64Encoded: parts[0]), name)
            let expectedJCS = try XCTUnwrap(vector["jcs_utf8"] as? String)
            XCTAssertEqual(String(decoding: tupleBytes, as: UTF8.self), expectedJCS, name)
            XCTAssertEqual(parts[0], (vector["envelope"] as? String)?.split(separator: ".").first.map(String.init), name)
            let signature = try XCTUnwrap(Data(base64Encoded: parts[1]), name)
            XCTAssertTrue(key.publicKey.isValidSignature(signature, for: tupleBytes), name)
            // Go's deterministic RFC 8032 signature verifies over the same bytes.
            let fixtureSignature = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(vector["signature_b64"] as? String)))
            XCTAssertTrue(key.publicKey.isValidSignature(fixtureSignature, for: Data(expectedJCS.utf8)), name)
            XCTAssertNoThrow(try Self.verify(try XCTUnwrap(vector["envelope"] as? String), publicKey: key.publicKey), name)
            XCTAssertNoThrow(try Self.verify(envelope, publicKey: key.publicKey), name)
        }
    }

    func testEveryNegativeVectorIsRejected() throws {
        let fixture = try Self.fixture()
        let key = try Self.signingKey(fixture)
        let negatives = try XCTUnwrap(fixture["negative"] as? [[String: Any]])
        let ids = Set(negatives.compactMap { $0["id"] as? String })
        for id in [
            "wrong_receipt_version", "v04_receipt_version", "wrong_entrypoint", "wrong_basis", "extra_field",
            "missing_field", "null_field", "non_canonical_whitespace", "duplicate_member", "non_integer_number",
            "oversized_tuple", "usage_above_input_bound", "usage_above_output_bound", "v04_tuple",
        ] {
            XCTAssertTrue(ids.contains(id), "fixture lacks the \(id) negative")
        }
        for vector in negatives {
            let name = vector["id"] as? String ?? "?"
            let envelope = try XCTUnwrap(vector["envelope"] as? String)
            XCTAssertThrowsError(try Self.verify(envelope, publicKey: key.publicKey), name)
        }
    }

    func testBuilderRefusesInputsTheVerifierWouldReject() throws {
        let fixture = try Self.fixture()
        let key = try Self.signingKey(fixture)
        let vector = try XCTUnwrap((fixture["positive"] as? [[String: Any]])?.first)
        let base = try Self.receiptInput(vector, fixture: fixture)
        let store = InMemoryReceiptKeyStore()
        try store.storeNew(providerId: base.metadata.providerID, privateKey: key)
        let builder = ReceiptBuilder(keyStore: store)
        let providerID = base.metadata.providerID
        func modified(_ change: (inout Fields) -> Void) -> RelayBlindSettlementReceiptInput {
            var fields = Fields(base)
            change(&fields)
            return fields.input
        }
        let rejected: [(String, RelayBlindSettlementReceiptInput)] = [
            ("input above bound", modified { $0.inputTokens = $0.inputTokenUpperBound + 1 }),
            ("output above bound", modified { $0.outputTokens = $0.maxOutputTokens + 1 }),
            ("negative output", modified { $0.outputTokens = -1 }),
            ("negative bytes", modified { $0.responseBodyBytes = -1 }),
            ("bound zero", modified { $0.inputTokenUpperBound = 0 }),
            ("bound above int32", modified { $0.maxOutputTokens = Int64(Int32.max) + 1 }),
            ("terminal state", modified { $0.terminalState = "verified" }),
            ("uppercase digest", modified { $0.responseBodySHA256 = $0.responseBodySHA256.uppercased() }),
            ("short kid", modified { $0.kid = String($0.kid.dropLast()) }),
            ("model hash mismatch", modified { $0.modelHash = String(repeating: "a", count: 64) }),
            ("padded execution digest", modified { $0.executionAuthDigest += "=" }),
        ]
        for (name, input) in rejected {
            XCTAssertThrowsError(try builder.buildRelayBlindSettlement(providerId: providerID, input: input), name)
        }
        XCTAssertThrowsError(try builder.buildRelayBlindSettlement(providerId: "other-provider", input: base))
        // A different current receipt key never signs a tuple pinned to the fixture key.
        let rotated = InMemoryReceiptKeyStore()
        try rotated.storeNew(providerId: providerID, privateKey: Curve25519.Signing.PrivateKey())
        XCTAssertThrowsError(try ReceiptBuilder(keyStore: rotated).buildRelayBlindSettlement(providerId: providerID, input: base))
        XCTAssertThrowsError(try ReceiptBuilder(keyStore: InMemoryReceiptKeyStore()).buildRelayBlindSettlement(providerId: providerID, input: base))
    }

    func testReceiptCarriesNoPlaintextOrV04Material() throws {
        let fixture = try Self.fixture()
        let key = try Self.signingKey(fixture)
        for vector in try XCTUnwrap(fixture["positive"] as? [[String: Any]]) {
            let input = try Self.receiptInput(vector, fixture: fixture)
            let store = InMemoryReceiptKeyStore()
            try store.storeNew(providerId: input.metadata.providerID, privateKey: key)
            let envelope = try ReceiptBuilder(keyStore: store)
                .buildRelayBlindSettlement(providerId: input.metadata.providerID, input: input)
            let tuple = try Self.verify(envelope, publicKey: key.publicKey)
            XCTAssertEqual(Set(tuple.keys), Self.tupleFields)
            for forbidden in ["prompt_hash", "output_hash", "output_prefix_start_byte", "output_prefix_end_byte", "provider_pubkey"] {
                XCTAssertNil(tuple[forbidden])
            }
            XCTAssertEqual(Set((tuple["usage"] as? [String: Any]).map { Array($0.keys) } ?? []), ["input_tokens", "output_tokens"])
        }
    }

    func testMetadataParsesOnlyTheClosedSixteenMemberObject() throws {
        let fixture = try Self.fixture()
        let vector = try XCTUnwrap((fixture["positive"] as? [[String: Any]])?.first)
        let wire = try Self.metadataWire(vector, fixture: fixture)
        XCTAssertEqual(Set(wire.keys), RelayBlindSettlementMetadata.wireFields)
        XCTAssertEqual(RelayBlindSettlementMetadata.wireFields.count, 16)
        let parsed = try XCTUnwrap(RelayBlindSettlementMetadata(wire: wire))
        XCTAssertEqual(parsed.requestID, wire["request_id"] as? String)

        func mutated(_ change: (inout [String: Any]) -> Void) -> [String: Any] {
            var copy = wire
            change(&copy)
            return copy
        }
        let invalid: [(String, Any?)] = [
            ("absent", nil),
            ("null", NSNull()),
            ("array", [wire]),
            ("missing member", mutated { $0.removeValue(forKey: "catalog_id") }),
            ("unknown member", mutated { $0["prompt_hash"] = String(repeating: "a", count: 64) }),
            ("null member", mutated { $0["model_id"] = NSNull() }),
            ("bool attempt", mutated { $0["attempt_n"] = true }),
            ("fractional attempt", mutated { $0["attempt_n"] = 1.5 }),
            ("negative attempt", mutated { $0["attempt_n"] = -1 }),
            ("string attempt", mutated { $0["attempt_n"] = "0" }),
            ("deadline zero", mutated { $0["pending_deadline_seconds"] = 0 }),
            ("deadline above 900", mutated { $0["pending_deadline_seconds"] = 901 }),
            ("wrong entrypoint", mutated { $0["paid_entrypoint"] = "coordinator_buyer_v1_chat_completions" }),
            ("wrong basis", mutated { $0["prompt_hash_basis"] = "coordinator_prompt_canonical_v1" }),
            ("wrong mode", mutated { $0["route_snapshot_mode"] = "off" }),
            ("bad key id", mutated { $0["provider_receipt_key_id"] = "ed25519:" + String(repeating: "a", count: 64) }),
            ("upper hex", mutated { $0["route_snapshot_digest"] = String(repeating: "A", count: 64) }),
            ("padded envelope digest", mutated { $0["relay_blind_envelope_digest"] = ($0["relay_blind_envelope_digest"] as? String ?? "") + "=" }),
            ("hex envelope digest", mutated { $0["relay_blind_envelope_digest"] = String(repeating: "a", count: 64) }),
            ("empty model id", mutated { $0["model_id"] = "" }),
            ("oversized account scope", mutated { $0["account_scope"] = String(repeating: "a", count: 257) }),
            ("non-printable request id", mutated { $0["request_id"] = "settle\nreq" }),
            ("non-ascii catalog id", mutated { $0["catalog_id"] = "catalog-é" }),
        ]
        for (name, value) in invalid {
            XCTAssertNil(RelayBlindSettlementMetadata(wire: value), name)
        }
    }

    // MARK: - Test-side strict §N.13 verifier (shape and signature only).

    private enum VerifyError: Error { case reject(String) }

    @discardableResult
    static func verify(_ envelope: String, publicKey: Curve25519.Signing.PublicKey) throws -> [String: Any] {
        func reject(_ reason: String) -> VerifyError { .reject(reason) }
        guard envelope.utf8.count <= ReceiptBuilder.relayBlindSettlementMaxEnvelopeBytes else { throw reject("envelope size") }
        let parts = envelope.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let tupleBytes = Data(base64Encoded: String(parts[0])),
              let signature = Data(base64Encoded: String(parts[1])) else { throw reject("envelope form") }
        guard tupleBytes.count <= ReceiptBuilder.relayBlindSettlementMaxTupleBytes else { throw reject("tuple size") }
        guard publicKey.isValidSignature(signature, for: tupleBytes) else { throw reject("signature") }
        guard let tuple = try JSONSerialization.jsonObject(with: tupleBytes) as? [String: Any] else { throw reject("object") }
        guard Data(try RFC8785JCS.canonicalString(try jcsValue(tuple)).utf8) == tupleBytes else { throw reject("non-canonical") }
        guard Set(tuple.keys) == tupleFields else { throw reject("field set") }
        func string(_ key: String) throws -> String {
            guard let value = tuple[key] as? String else { throw reject("\(key) type") }
            return value
        }
        func integer(_ value: Any?, _ key: String) throws -> Int64 {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.isEqual(to: NSNumber(value: number.int64Value)) else { throw reject("\(key) integer") }
            return number.int64Value
        }
        guard try string("receipt_version") == ReceiptBuilder.relayBlindSettlementReceiptVersion,
              try string("paid_entrypoint") == RelayBlindSettlementMetadata.paidEntrypoint,
              try string("prompt_hash_basis") == RelayBlindSettlementMetadata.promptHashBasis,
              try string("signature_key_alg") == "Ed25519",
              ["none", PrivacyClassConstants.v1].contains(try string("privacy_class")),
              ReceiptBuilder.terminalStates.contains(try string("terminal_state")),
              ["observe", "enforce"].contains(try string("route_snapshot_mode")),
              ReceiptBuilder.isValidReceiptKeyID(try string("provider_receipt_key_id")) else {
            throw reject("constant")
        }
        for key in ["account_scope", "catalog_id", "model_id", "provider_id", "request_id", "route_snapshot_policy_version"] {
            guard ReceiptBuilder.isBoundedPrintableASCII(try string(key)) else { throw reject("\(key) size") }
        }
        for key in ["catalog_body_digest", "expected_catalog_model_hash", "model_hash", "response_body_sha256", "route_snapshot_digest"] {
            guard ReceiptBuilder.isValidModelHash(try string(key)) else { throw reject("\(key) hex") }
        }
        for key in ["relay_blind_envelope_digest", "relay_blind_execution_auth_digest", "relay_blind_provider_binding_digest"] {
            guard ReceiptBuilder.isCanonicalBase64URL(try string(key), byteCount: 32) else { throw reject("\(key) b64") }
        }
        guard ReceiptBuilder.isCanonicalBase64URL(try string("relay_blind_kid"), byteCount: 16) else { throw reject("kid") }
        for key in ["attempt_n", "issued_at_unix_ms", "response_body_bytes", "terminal_state_ts_unix_ms"] {
            guard try integer(tuple[key], key) >= 0 else { throw reject("\(key) negative") }
        }
        let inputBound = try integer(tuple["input_token_upper_bound"], "input_token_upper_bound")
        let outputBound = try integer(tuple["max_output_tokens"], "max_output_tokens")
        guard (1...Int64(Int32.max)).contains(inputBound), (1...Int64(Int32.max)).contains(outputBound) else {
            throw reject("bounds")
        }
        guard let usage = tuple["usage"] as? [String: Any], Set(usage.keys) == ["input_tokens", "output_tokens"] else {
            throw reject("usage shape")
        }
        let inputTokens = try integer(usage["input_tokens"], "usage.input_tokens")
        let outputTokens = try integer(usage["output_tokens"], "usage.output_tokens")
        guard (0...inputBound).contains(inputTokens), (0...outputBound).contains(outputTokens) else {
            throw reject("usage bound")
        }
        return tuple
    }

    private static func jcsValue(_ value: Any) throws -> RFC8785JCS.Value {
        switch value {
        case let object as [String: Any]:
            return .object(try object.mapValues { try jcsValue($0) })
        case let string as String:
            return .string(string)
        case is NSNull:
            return .null
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
            guard let integer = Int(exactly: number.doubleValue), number.isEqual(to: NSNumber(value: integer)) else {
                throw VerifyError.reject("non-integer number")
            }
            return .int(integer)
        default:
            throw VerifyError.reject("unsupported JSON value")
        }
    }

    // MARK: - Fixture helpers

    private struct Fields {
        var metadata: RelayBlindSettlementMetadata
        var executionAuthDigest: String
        var providerBindingDigest: String
        var kid: String
        var inputTokenUpperBound: Int64
        var maxOutputTokens: Int64
        var privacyClass: Bool
        var modelHash: String
        var inputTokens: Int64
        var outputTokens: Int64
        var responseBodyBytes: Int64
        var responseBodySHA256: String
        var terminalState: String
        var terminalStateUnixMS: Int64
        var issuedAtUnixMS: Int64

        init(_ input: RelayBlindSettlementReceiptInput) {
            metadata = input.metadata
            executionAuthDigest = input.executionAuthDigest
            providerBindingDigest = input.providerBindingDigest
            kid = input.kid
            inputTokenUpperBound = input.inputTokenUpperBound
            maxOutputTokens = input.maxOutputTokens
            privacyClass = input.privacyClass
            modelHash = input.modelHash
            inputTokens = input.inputTokens
            outputTokens = input.outputTokens
            responseBodyBytes = input.responseBodyBytes
            responseBodySHA256 = input.responseBodySHA256
            terminalState = input.terminalState
            terminalStateUnixMS = input.terminalStateUnixMS
            issuedAtUnixMS = input.issuedAtUnixMS
        }

        var input: RelayBlindSettlementReceiptInput {
            RelayBlindSettlementReceiptInput(
                metadata: metadata, executionAuthDigest: executionAuthDigest,
                providerBindingDigest: providerBindingDigest, kid: kid,
                inputTokenUpperBound: inputTokenUpperBound, maxOutputTokens: maxOutputTokens,
                privacyClass: privacyClass, modelHash: modelHash, inputTokens: inputTokens,
                outputTokens: outputTokens, responseBodyBytes: responseBodyBytes,
                responseBodySHA256: responseBodySHA256, terminalState: terminalState,
                terminalStateUnixMS: terminalStateUnixMS, issuedAtUnixMS: issuedAtUnixMS
            )
        }
    }

    static func fixture() throws -> [String: Any] {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let url = tests.appendingPathComponent("../../../test/fixtures/receipts/relay-blind-settlement-v1.json").standardizedFileURL
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    static func signingKey(_ fixture: [String: Any]) throws -> Curve25519.Signing.PrivateKey {
        let seed = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(fixture["signing_seed_b64"] as? String)))
        return try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    }

    /// The SPEC-001-R005 object the coordinator would have dispatched for a
    /// vector: tuple members plus the snapshot's pending deadline.
    static func metadataWire(_ vector: [String: Any], fixture: [String: Any]) throws -> [String: Any] {
        let tuple = try XCTUnwrap(vector["tuple"] as? [String: Any])
        let snapshot = try XCTUnwrap(fixture["route_snapshot"] as? [String: Any])
        var wire: [String: Any] = [:]
        for field in RelayBlindSettlementMetadata.wireFields where field != "pending_deadline_seconds" {
            wire[field] = try XCTUnwrap(tuple[field], field)
        }
        wire["pending_deadline_seconds"] = try XCTUnwrap(snapshot["pending_deadline_seconds"])
        return wire
    }

    /// Builds the receipt input the relay would: metadata, SPEC-041 dispatch
    /// context, and the vector's emitted-byte digest, usage, and timestamps.
    static func receiptInput(_ vector: [String: Any], fixture: [String: Any]) throws -> RelayBlindSettlementReceiptInput {
        let tuple = try XCTUnwrap(vector["tuple"] as? [String: Any])
        let dispatch = try XCTUnwrap(fixture["dispatch"] as? [String: Any])
        let metadata = try XCTUnwrap(RelayBlindSettlementMetadata(wire: try metadataWire(vector, fixture: fixture)))
        let usage = try XCTUnwrap(tuple["usage"] as? [String: Any])
        func int(_ value: Any?) throws -> Int64 { try XCTUnwrap((value as? NSNumber)?.int64Value) }
        return RelayBlindSettlementReceiptInput(
            metadata: metadata,
            executionAuthDigest: try XCTUnwrap(dispatch["execution_auth_digest"] as? String),
            providerBindingDigest: try XCTUnwrap(dispatch["provider_binding_digest"] as? String),
            kid: try XCTUnwrap(dispatch["kid"] as? String),
            inputTokenUpperBound: try int(dispatch["input_token_upper_bound"]),
            maxOutputTokens: try int(dispatch["max_output_tokens"]),
            privacyClass: tuple["privacy_class"] as? String == PrivacyClassConstants.v1,
            modelHash: try XCTUnwrap(tuple["model_hash"] as? String),
            inputTokens: try int(usage["input_tokens"]),
            outputTokens: try int(usage["output_tokens"]),
            responseBodyBytes: try int(tuple["response_body_bytes"]),
            responseBodySHA256: try XCTUnwrap(tuple["response_body_sha256"] as? String),
            terminalState: try XCTUnwrap(tuple["terminal_state"] as? String),
            terminalStateUnixMS: try int(tuple["terminal_state_ts_unix_ms"]),
            issuedAtUnixMS: try int(tuple["issued_at_unix_ms"])
        )
    }

    // MARK: - send failure (SPEC-022 R-14.6)

    private func settlementAttempt() throws -> RelayBlindSettlementAttempt {
        let key = Curve25519.Signing.PrivateKey()
        let store = InMemoryReceiptKeyStore()
        try store.storeNew(providerId: "provider-1", privateKey: key)
        let digest = RelayBlindBase64URL.encode(Data(repeating: 7, count: 32))
        let metadata = try XCTUnwrap(RelayBlindSettlementMetadata(wire: [
            "account_scope": "acct-scope-test", "request_id": "ledger-row-1", "attempt_n": 0, "provider_id": "provider-1",
            "provider_receipt_key_id": "ed25519-sha256:" + SHA256.hash(data: key.publicKey.rawRepresentation).map { String(format: "%02x", $0) }.joined(),
            "model_id": "model-a", "expected_catalog_model_hash": String(repeating: "5e", count: 32),
            "catalog_id": "catalog-test", "catalog_body_digest": String(repeating: "c", count: 64),
            "route_snapshot_digest": String(repeating: "d", count: 64), "route_snapshot_policy_version": "spec022-policy-test",
            "route_snapshot_mode": "enforce", "pending_deadline_seconds": 300,
            "paid_entrypoint": RelayBlindSettlementMetadata.paidEntrypoint,
            "prompt_hash_basis": RelayBlindSettlementMetadata.promptHashBasis, "relay_blind_envelope_digest": digest,
        ] as [String: Any]))
        let context = RelayBlindDispatchContext(
            executionAuthDigest: digest, envelopeDigest: digest, providerBindingDigest: digest, buyerBindingDigest: digest,
            kid: RelayBlindBase64URL.encode(Data(repeating: 1, count: 16)), assignedSession: "session-1", requestID: "envelope-1",
            inputTokenUpperBound: 8, maxOutputTokens: 4, privacyClass: nil
        )
        let attempt = RelayBlindSettlementAttempt(metadata: metadata, context: context, privacyClass: false, builder: ReceiptBuilder(keyStore: store))
        attempt.pin(modelHash: String(repeating: "5e", count: 32), preparedModelID: "model-a", aliases: [])
        attempt.validated(inputTokens: 4)
        return attempt
    }

    func testReceiptIsIssuedWhenEveryRecordedChunkWasSent() throws {
        let attempt = try settlementAttempt()
        XCTAssertTrue(attempt.recordEmitted("data: one\n\n"))
        XCTAssertNotNil(attempt.receipt(terminalState: "normal_done", terminalStateUnixMS: 1_780_000_000_000, outputTokens: 2))
    }

    /// A chunk recorded in the digest but not sent would sign a body the
    /// coordinator never received; the receipt is withheld permanently.
    func testSendFailureSuppressesTheReceipt() throws {
        let attempt = try settlementAttempt()
        XCTAssertTrue(attempt.recordEmitted("data: one\n\n"))
        attempt.suppressReceiptAfterSendFailure()
        XCTAssertNil(attempt.receipt(terminalState: "provider_error", terminalStateUnixMS: 1_780_000_000_000, outputTokens: 1))
        XCTAssertNil(attempt.receipt(terminalState: "provider_error", terminalStateUnixMS: 1_780_000_000_000, outputTokens: 1))
        XCTAssertFalse(attempt.recordEmitted("data: two\n\n"))
    }
}
