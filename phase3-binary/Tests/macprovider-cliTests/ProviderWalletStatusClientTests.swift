import Foundation
import XCTest
@testable import macprovider_cli

final class ProviderWalletStatusClientTests: XCTestCase {
    func testWalletURLFromWSSCoordinator() {
        let url = ProviderWalletStatusClient.walletURL(from: "wss://coordinator.malibu.tech/v2/provider")
        XCTAssertEqual(url?.absoluteString, "https://coordinator.malibu.tech/v1/provider/wallet")
    }

    func testWalletURLFromHTTPSCoordinator() {
        let url = ProviderWalletStatusClient.walletURL(from: "https://coordinator.malibu.tech")
        XCTAssertEqual(url?.absoluteString, "https://coordinator.malibu.tech/v1/provider/wallet")
    }

    func testDecodeWalletStatusHeldCappedMismatch() throws {
        let status = try JSONDecoder().decode(ProviderWalletStatusSummary.self, from: walletStatusJSON())

        XCTAssertFalse(status.unavailable)
        XCTAssertEqual(status.schemaVersion, "provider_wallet_status.v1")
        XCTAssertEqual(status.providerID, "mp-test")
        XCTAssertTrue(status.walletBound)
        XCTAssertTrue(status.walletMismatch)
        XCTAssertEqual(status.holdOrMismatchReason, "wallet_projection_mismatch")
        XCTAssertEqual(status.payoutWallet?.address, "0xPayout")
        XCTAssertEqual(status.payoutWallet?.verificationSource, "provider_payout_addresses")
        XCTAssertEqual(status.rewardWallet?.address, "0xReward")
        XCTAssertEqual(status.rewardAmounts?.withdrawableMALIBU, 7.5)
        XCTAssertEqual(status.rewardAmounts?.heldMALIBU, 2.5)
        XCTAssertTrue(status.rewardAmounts?.walletDailyCapped == true)
        XCTAssertEqual(status.eligibilityInputs?.trustTier, "trusted")
        XCTAssertEqual(status.eligibilityInputs?.computeIntegrityState, "unknown")
        XCTAssertEqual(status.rewardEligibility?.primaryReason, "held_wallet_daily_cap")
        XCTAssertEqual(status.audit?.events.first?.eventType, "wallet_daily_cap_applied")
    }

    func testProviderDailyCapReasonStaysAvailable() throws {
        let json = String(decoding: walletStatusJSON(), as: UTF8.self)
            .replacingOccurrences(of: #""primary_reason": "held_wallet_daily_cap""#, with: #""primary_reason": "held_provider_daily_cap""#)
            .replacingOccurrences(of: #""reasons": ["held_wallet_daily_cap"]"#, with: #""reasons": ["held_provider_daily_cap"]"#)

        let status = try JSONDecoder().decode(ProviderWalletStatusSummary.self, from: Data(json.utf8))

        XCTAssertEqual(status.rewardEligibility?.primaryReason, "held_provider_daily_cap")
        XCTAssertEqual(status.rewardEligibility?.earningState, "capped")
    }

    func testUnknownWalletSchemaNormalizesUnavailable() throws {
        let json = Data(#"{"schema_version":"provider_wallet_status.v2","provider_id":"mp-test","wallet_bound":true}"#.utf8)

        let status = try JSONDecoder().decode(ProviderWalletStatusSummary.self, from: json)

        XCTAssertTrue(status.unavailable)
        XCTAssertEqual(status.schemaVersion, "provider_wallet_status.v2")
        XCTAssertEqual(status.providerID, "mp-test")
        XCTAssertFalse(status.walletBound)
        XCTAssertEqual(status.holdOrMismatchReason, "telemetry_unavailable")
        XCTAssertEqual(status.rewardEligibility?.primaryReason, "telemetry_unavailable")
    }

    func testMissingV1RewardAmountsFailsClosed() {
        let json = Data(#"{"schema_version":"provider_wallet_status.v1","provider_id":"mp-test","wallet_bound":true,"wallet_mismatch":false}"#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(ProviderWalletStatusSummary.self, from: json))
    }

    func testMissingV1RewardEligibilityFailsClosed() throws {
        var object = try walletStatusObject()
        object.removeValue(forKey: "reward_eligibility")
        let json = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(ProviderWalletStatusSummary.self, from: json))
    }

    func testMissingV1AuditFailsClosed() throws {
        var object = try walletStatusObject()
        object.removeValue(forKey: "audit")
        let json = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(ProviderWalletStatusSummary.self, from: json))
    }

    func testIncompleteV1AuditEventFailsClosed() throws {
        var object = try walletStatusObject()
        object["audit"] = ["events": [["event_type": "wallet_daily_cap_applied"]]]
        let json = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(ProviderWalletStatusSummary.self, from: json))
    }

    func testMalformedV1AuditOptionalFieldsFailClosed() throws {
        var malformedAmount = try walletStatusObject()
        malformedAmount["audit"] = [
            "events": [try auditEventObject(overrides: ["amount_malibu": "not-a-number"])],
        ]
        XCTAssertThrowsError(try JSONDecoder().decode(
            ProviderWalletStatusSummary.self,
            from: try JSONSerialization.data(withJSONObject: malformedAmount)
        ))

        var badCursor = try walletStatusObject()
        badCursor["audit"] = [
            "next_before_id": "",
            "events": [try auditEventObject()],
        ]
        XCTAssertThrowsError(try JSONDecoder().decode(
            ProviderWalletStatusSummary.self,
            from: try JSONSerialization.data(withJSONObject: badCursor)
        ))

        var badLedger = try walletStatusObject()
        badLedger["audit"] = [
            "events": [try auditEventObject(overrides: ["ledger_id": "not-an-int"])],
        ]
        XCTAssertThrowsError(try JSONDecoder().decode(
            ProviderWalletStatusSummary.self,
            from: try JSONSerialization.data(withJSONObject: badLedger)
        ))

        var emptyOptionalString = try walletStatusObject()
        emptyOptionalString["audit"] = [
            "events": [try auditEventObject(overrides: ["source_reason": ""])],
        ]
        XCTAssertThrowsError(try JSONDecoder().decode(
            ProviderWalletStatusSummary.self,
            from: try JSONSerialization.data(withJSONObject: emptyOptionalString)
        ))
    }

    func testMalformedV1WalletOptionalFieldsFailClosed() throws {
        var emptyPayoutOptional = try walletStatusObject()
        emptyPayoutOptional["payout_wallet"] = [
            "chain": "base-mainnet",
            "address": "0xPayout",
            "payout_allowed": true,
            "verification_source": "provider_payout_addresses",
            "last_update_utc": "",
        ]
        XCTAssertThrowsError(try JSONDecoder().decode(
            ProviderWalletStatusSummary.self,
            from: try JSONSerialization.data(withJSONObject: emptyPayoutOptional)
        ))

        var emptyRewardAddress = try walletStatusObject()
        emptyRewardAddress["reward_wallet"] = [
            "address": "",
            "verification_source": "provider_emission_state",
            "cap_replay_pending": false,
        ]
        XCTAssertThrowsError(try JSONDecoder().decode(
            ProviderWalletStatusSummary.self,
            from: try JSONSerialization.data(withJSONObject: emptyRewardAddress)
        ))
    }

    func testFetchUsesBearerToken() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WalletMockURLProtocol.self]
        let session = URLSession(configuration: config)
        WalletMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer wallet-token")
            XCTAssertEqual(request.url?.path, "/v1/provider/wallet")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, walletStatusJSON())
        }
        defer { WalletMockURLProtocol.requestHandler = nil }

        let client = ProviderWalletStatusClient(
            walletURL: URL(string: "https://coordinator.malibu.tech/v1/provider/wallet")!,
            session: session
        )
        let status = try await client.fetch(bearerToken: "wallet-token")
        XCTAssertEqual(status.providerID, "mp-test")
    }
}

private func walletStatusJSON() -> Data {
    Data("""
    {
      "schema_version": "provider_wallet_status.v1",
      "provider_id": "mp-test",
      "wallet_bound": true,
      "wallet_mismatch": true,
      "hold_or_mismatch_reason": "wallet_projection_mismatch",
      "payout_wallet": {
        "chain": "base-mainnet",
        "address": "0xPayout",
        "payout_allowed": true,
        "registered_at_utc": "2026-08-18T01:00:00Z",
        "registered_against_hot_wallet": "0xHot",
        "verification_source": "provider_payout_addresses",
        "last_update_utc": "2026-08-18T01:00:00Z"
      },
      "reward_wallet": {
        "address": "0xReward",
        "verification_source": "provider_emission_state",
        "last_update_utc": "2026-08-18T01:01:00Z",
        "cap_replay_pending": true
      },
        "reward_amounts": {
        "accrued_malibu": "10",
        "withdrawable_malibu": "7.5",
        "held_malibu": "2.5",
        "provider_daily_cap_malibu": 25,
        "provider_day_malibu": "10",
        "provider_daily_capped": false,
        "wallet_daily_cap_malibu": 100,
        "wallet_day_malibu": "100",
        "wallet_daily_capped": true
      },
      "eligibility_inputs": {
        "trust_tier": "trusted",
        "quarantined": false,
        "receipt_quality": "sufficient_verified_receipts",
        "verified_receipt_count": 3,
        "required_receipt_count": 3,
        "compute_integrity_state": "unknown",
        "attestation_tier": "app_attested",
        "app_attested": true,
        "criteria_met": 4,
        "criteria_required": 4,
        "economic_criteria": ["uptime_ok", "wallet_balance_ok"],
        "additional_criteria": ["app_attested", "verified_receipts"],
        "wallet_balance_ok": true,
        "uptime_ok": true
      },
      "reward_eligibility": {
        "schema_version": "malibu_reward_eligibility.v1",
        "earning_state": "capped",
        "withdrawal_state": "capped",
        "primary_reason": "held_wallet_daily_cap",
        "reasons": ["held_wallet_daily_cap"]
      },
      "audit": {
        "events": [{
          "id": "evt-1",
          "occurred_at": "2026-08-18T01:02:00Z",
          "event_type": "wallet_daily_cap_applied",
          "ledger_id": 99,
          "amount_malibu": "2.5",
          "withdrawal_hold_reason": "per_wallet_daily_cap",
          "trust_tier": "trusted",
          "source_reason": "useful_work",
          "summary": "Reward hit the per-wallet daily cap."
        }]
      }
    }
    """.utf8)
}

private func walletStatusObject() throws -> [String: Any] {
    let decoded = try JSONSerialization.jsonObject(with: walletStatusJSON())
    guard let object = decoded as? [String: Any] else {
        throw NSError(domain: "ProviderWalletStatusClientTests", code: 1)
    }
    return object
}

private func auditEventObject(overrides: [String: Any] = [:]) throws -> [String: Any] {
    guard
        let audit = try walletStatusObject()["audit"] as? [String: Any],
        let events = audit["events"] as? [[String: Any]],
        var event = events.first
    else {
        throw NSError(domain: "ProviderWalletStatusClientTests", code: 2)
    }
    for (key, value) in overrides {
        event[key] = value
    }
    return event
}

private final class WalletMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
