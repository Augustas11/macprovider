import Foundation

struct ProviderWalletStatusSummary: Decodable, Equatable, Sendable {
    static let schemaV1 = "provider_wallet_status.v1"

    let schemaVersion: String
    let unavailable: Bool
    let providerID: String?
    let walletBound: Bool
    let walletMismatch: Bool
    let holdOrMismatchReason: String?
    let payoutWallet: ProviderPayoutWalletSummary?
    let rewardWallet: ProviderRewardWalletSummary?
    let rewardAmounts: ProviderWalletRewardAmountsSummary?
    let eligibilityInputs: ProviderWalletEligibilityInputsSummary?
    let rewardEligibility: MalibuRewardEligibility?
    let audit: ProviderWalletAuditPageSummary?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case providerID = "provider_id"
        case walletBound = "wallet_bound"
        case walletMismatch = "wallet_mismatch"
        case holdOrMismatchReason = "hold_or_mismatch_reason"
        case payoutWallet = "payout_wallet"
        case rewardWallet = "reward_wallet"
        case rewardAmounts = "reward_amounts"
        case eligibilityInputs = "eligibility_inputs"
        case rewardEligibility = "reward_eligibility"
        case audit
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawSchema = try c.decodeIfPresent(String.self, forKey: .schemaVersion) ?? ""
        guard rawSchema == Self.schemaV1 else {
            Self.logSchemaDrift(schemaVersion: rawSchema, field: "schema_version")
            schemaVersion = rawSchema.isEmpty ? Self.schemaV1 : rawSchema
            unavailable = true
            providerID = try c.decodeIfPresent(String.self, forKey: .providerID)
            walletBound = false
            walletMismatch = false
            holdOrMismatchReason = "telemetry_unavailable"
            payoutWallet = nil
            rewardWallet = nil
            rewardAmounts = nil
            eligibilityInputs = nil
            rewardEligibility = MalibuRewardEligibility.unavailableForMissingObject()
            audit = nil
            return
        }
        schemaVersion = rawSchema
        unavailable = false
        providerID = try decodeNonEmptyString(c, forKey: .providerID)
        walletBound = try c.decode(Bool.self, forKey: .walletBound)
        walletMismatch = try c.decode(Bool.self, forKey: .walletMismatch)
        holdOrMismatchReason = try c.decodeIfPresent(String.self, forKey: .holdOrMismatchReason)
        payoutWallet = try c.decodeIfPresent(ProviderPayoutWalletSummary.self, forKey: .payoutWallet)
        rewardWallet = try c.decode(ProviderRewardWalletSummary.self, forKey: .rewardWallet)
        rewardAmounts = try c.decode(ProviderWalletRewardAmountsSummary.self, forKey: .rewardAmounts)
        eligibilityInputs = try c.decode(ProviderWalletEligibilityInputsSummary.self, forKey: .eligibilityInputs)
        rewardEligibility = try c.decode(MalibuRewardEligibility.self, forKey: .rewardEligibility)
        audit = try c.decode(ProviderWalletAuditPageSummary.self, forKey: .audit)
    }

    private static func logSchemaDrift(schemaVersion: String, field: String) {
        let schema = schemaVersion.isEmpty ? "missing" : schemaVersion
        let line = "event=provider_wallet_status_schema_drift schema_version=\(schema) field=\(field)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}

struct ProviderPayoutWalletSummary: Decodable, Equatable, Sendable {
    let chain: String
    let address: String
    let payoutAllowed: Bool
    let pendingUntilUTC: String?
    let rotatedFrom: String?
    let registeredAtUTC: String?
    let registeredAgainstHotWallet: String?
    let verificationSource: String
    let lastUpdateUTC: String?

    enum CodingKeys: String, CodingKey {
        case chain
        case address
        case payoutAllowed = "payout_allowed"
        case pendingUntilUTC = "pending_until_utc"
        case rotatedFrom = "rotated_from"
        case registeredAtUTC = "registered_at_utc"
        case registeredAgainstHotWallet = "registered_against_hot_wallet"
        case verificationSource = "verification_source"
        case lastUpdateUTC = "last_update_utc"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chain = try decodeNonEmptyString(c, forKey: .chain)
        address = try decodeNonEmptyString(c, forKey: .address)
        payoutAllowed = try c.decode(Bool.self, forKey: .payoutAllowed)
        pendingUntilUTC = try decodeOptionalNonEmptyString(c, forKey: .pendingUntilUTC)
        rotatedFrom = try decodeOptionalNonEmptyString(c, forKey: .rotatedFrom)
        registeredAtUTC = try decodeOptionalNonEmptyString(c, forKey: .registeredAtUTC)
        registeredAgainstHotWallet = try decodeOptionalNonEmptyString(c, forKey: .registeredAgainstHotWallet)
        verificationSource = try decodeNonEmptyString(c, forKey: .verificationSource)
        lastUpdateUTC = try decodeOptionalNonEmptyString(c, forKey: .lastUpdateUTC)
    }
}

struct ProviderRewardWalletSummary: Decodable, Equatable, Sendable {
    let address: String?
    let verificationSource: String
    let lastUpdateUTC: String?
    let capReplayPending: Bool

    enum CodingKeys: String, CodingKey {
        case address
        case verificationSource = "verification_source"
        case lastUpdateUTC = "last_update_utc"
        case capReplayPending = "cap_replay_pending"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        address = try decodeOptionalNonEmptyString(c, forKey: .address)
        verificationSource = try decodeNonEmptyString(c, forKey: .verificationSource)
        lastUpdateUTC = try decodeOptionalNonEmptyString(c, forKey: .lastUpdateUTC)
        capReplayPending = try c.decode(Bool.self, forKey: .capReplayPending)
    }
}

struct ProviderWalletRewardAmountsSummary: Decodable, Equatable, Sendable {
    let accruedMALIBU: Double
    let withdrawableMALIBU: Double
    let heldMALIBU: Double
    let providerDailyCapMALIBU: Double
    let providerDayMALIBU: Double
    let providerDailyCapped: Bool
    let walletDailyCapMALIBU: Double
    let walletDayMALIBU: Double
    let walletDailyCapped: Bool

    enum CodingKeys: String, CodingKey {
        case accruedMALIBU = "accrued_malibu"
        case withdrawableMALIBU = "withdrawable_malibu"
        case heldMALIBU = "held_malibu"
        case providerDailyCapMALIBU = "provider_daily_cap_malibu"
        case providerDayMALIBU = "provider_day_malibu"
        case providerDailyCapped = "provider_daily_capped"
        case walletDailyCapMALIBU = "wallet_daily_cap_malibu"
        case walletDayMALIBU = "wallet_day_malibu"
        case walletDailyCapped = "wallet_daily_capped"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accruedMALIBU = try Self.decodeDecimal(c, key: .accruedMALIBU)
        withdrawableMALIBU = try Self.decodeDecimal(c, key: .withdrawableMALIBU)
        heldMALIBU = try Self.decodeDecimal(c, key: .heldMALIBU)
        providerDailyCapMALIBU = try Self.decodeDecimal(c, key: .providerDailyCapMALIBU)
        providerDayMALIBU = try Self.decodeDecimal(c, key: .providerDayMALIBU)
        providerDailyCapped = try c.decode(Bool.self, forKey: .providerDailyCapped)
        walletDailyCapMALIBU = try Self.decodeDecimal(c, key: .walletDailyCapMALIBU)
        walletDayMALIBU = try Self.decodeDecimal(c, key: .walletDayMALIBU)
        walletDailyCapped = try c.decode(Bool.self, forKey: .walletDailyCapped)
    }

    private static func decodeDecimal(
        _ c: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> Double {
        if let value = try? c.decode(Double.self, forKey: key), value.isFinite {
            return value
        }
        if let text = try? c.decode(String.self, forKey: key),
           let value = Double(text),
           value.isFinite {
            return value
        }
        throw DecodingError.dataCorruptedError(
            forKey: key,
            in: c,
            debugDescription: "Invalid provider wallet MALIBU amount"
        )
    }
}

struct ProviderWalletEligibilityInputsSummary: Decodable, Equatable, Sendable {
    let trustTier: String
    let demotionCooldownUntil: String?
    let quarantined: Bool
    let receiptQuality: String
    let verifiedReceiptCount: Int
    let requiredReceiptCount: Int
    let computeIntegrityState: String
    let attestationTier: String
    let appAttested: Bool
    let criteriaMet: Int
    let criteriaRequired: Int
    let economicCriteria: [String]
    let additionalCriteria: [String]
    let walletBalanceOK: Bool
    let uptimeOK: Bool

    enum CodingKeys: String, CodingKey {
        case trustTier = "trust_tier"
        case demotionCooldownUntil = "demotion_cooldown_until"
        case quarantined
        case receiptQuality = "receipt_quality"
        case verifiedReceiptCount = "verified_receipt_count"
        case requiredReceiptCount = "required_receipt_count"
        case computeIntegrityState = "compute_integrity_state"
        case attestationTier = "attestation_tier"
        case appAttested = "app_attested"
        case criteriaMet = "criteria_met"
        case criteriaRequired = "criteria_required"
        case economicCriteria = "economic_criteria"
        case additionalCriteria = "additional_criteria"
        case walletBalanceOK = "wallet_balance_ok"
        case uptimeOK = "uptime_ok"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trustTier = try decodeNonEmptyString(c, forKey: .trustTier)
        demotionCooldownUntil = try c.decodeIfPresent(String.self, forKey: .demotionCooldownUntil)
        quarantined = try c.decode(Bool.self, forKey: .quarantined)
        receiptQuality = try decodeNonEmptyString(c, forKey: .receiptQuality)
        verifiedReceiptCount = try c.decode(Int.self, forKey: .verifiedReceiptCount)
        requiredReceiptCount = try c.decode(Int.self, forKey: .requiredReceiptCount)
        computeIntegrityState = try decodeNonEmptyString(c, forKey: .computeIntegrityState)
        attestationTier = try decodeNonEmptyString(c, forKey: .attestationTier)
        appAttested = try c.decode(Bool.self, forKey: .appAttested)
        criteriaMet = try c.decode(Int.self, forKey: .criteriaMet)
        criteriaRequired = try c.decode(Int.self, forKey: .criteriaRequired)
        economicCriteria = try c.decode([String].self, forKey: .economicCriteria)
        additionalCriteria = try c.decode([String].self, forKey: .additionalCriteria)
        walletBalanceOK = try c.decode(Bool.self, forKey: .walletBalanceOK)
        uptimeOK = try c.decode(Bool.self, forKey: .uptimeOK)
    }
}

struct ProviderWalletAuditPageSummary: Decodable, Equatable, Sendable {
    let events: [ProviderWalletAuditEventSummary]
    let nextBeforeID: String?

    enum CodingKeys: String, CodingKey {
        case events
        case nextBeforeID = "next_before_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        events = try c.decode([ProviderWalletAuditEventSummary].self, forKey: .events)
        nextBeforeID = try decodeOptionalNonEmptyString(c, forKey: .nextBeforeID)
    }
}

struct ProviderWalletAuditEventSummary: Decodable, Equatable, Sendable {
    let id: String
    let occurredAt: String
    let eventType: String
    let ledgerID: Int64?
    let amountMALIBU: Double?
    let withdrawalHoldReason: String?
    let trustTier: String?
    let sourceReason: String?
    let summary: String

    enum CodingKeys: String, CodingKey {
        case id
        case occurredAt = "occurred_at"
        case eventType = "event_type"
        case ledgerID = "ledger_id"
        case amountMALIBU = "amount_malibu"
        case withdrawalHoldReason = "withdrawal_hold_reason"
        case trustTier = "trust_tier"
        case sourceReason = "source_reason"
        case summary
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try decodeNonEmptyString(c, forKey: .id)
        occurredAt = try decodeNonEmptyString(c, forKey: .occurredAt)
        eventType = try decodeNonEmptyString(c, forKey: .eventType)
        ledgerID = try c.decodeIfPresent(Int64.self, forKey: .ledgerID)
        amountMALIBU = try Self.decodeOptionalDecimal(c, key: .amountMALIBU)
        withdrawalHoldReason = try decodeOptionalNonEmptyString(c, forKey: .withdrawalHoldReason)
        trustTier = try decodeOptionalNonEmptyString(c, forKey: .trustTier)
        sourceReason = try decodeOptionalNonEmptyString(c, forKey: .sourceReason)
        summary = try decodeNonEmptyString(c, forKey: .summary)
    }

    private static func decodeOptionalDecimal(
        _ c: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> Double? {
        guard c.contains(key) else { return nil }
        if try c.decodeNil(forKey: key) {
            return nil
        }
        if let value = try? c.decode(Double.self, forKey: key), value.isFinite {
            return value
        }
        if let text = try? c.decode(String.self, forKey: key),
           let value = Double(text),
           value.isFinite {
            return value
        }
        throw DecodingError.dataCorruptedError(
            forKey: key,
            in: c,
            debugDescription: "Invalid provider wallet audit MALIBU amount"
        )
    }
}

private func decodeNonEmptyString<K: CodingKey>(
    _ c: KeyedDecodingContainer<K>,
    forKey key: K
) throws -> String {
    let value = try c.decode(String.self, forKey: key)
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw DecodingError.dataCorruptedError(
            forKey: key,
            in: c,
            debugDescription: "Required provider wallet string is empty"
        )
    }
    return value
}

private func decodeOptionalNonEmptyString<K: CodingKey>(
    _ c: KeyedDecodingContainer<K>,
    forKey key: K
) throws -> String? {
    guard c.contains(key), !(try c.decodeNil(forKey: key)) else {
        return nil
    }
    return try decodeNonEmptyString(c, forKey: key)
}

enum ProviderWalletStatusClientError: Error, Equatable {
    case invalidCoordinatorURL
    case httpStatus(Int)
    case unavailable
}

struct ProviderWalletStatusClient: Sendable {
    let walletURL: URL
    private let session: URLSession?

    init(coordinatorURL: String?, session: URLSession? = nil) throws {
        guard let url = Self.walletURL(from: coordinatorURL) else {
            throw ProviderWalletStatusClientError.invalidCoordinatorURL
        }
        self.walletURL = url
        self.session = session
    }

    init(walletURL: URL, session: URLSession? = nil) {
        self.walletURL = walletURL
        self.session = session
    }

    static func walletURL(from coordinatorURL: String?) -> URL? {
        guard let coordinatorURL,
              var components = URLComponents(string: coordinatorURL) else {
            return nil
        }
        switch components.scheme {
        case "wss":
            components.scheme = "https"
        case "https":
            break
        default:
            return nil
        }
        components.path = "/v1/provider/wallet"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    func fetch(bearerToken: String) async throws -> ProviderWalletStatusSummary {
        var request = URLRequest(url: walletURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        let data: Data
        let response: URLResponse
        if let session {
            (data, response) = try await session.data(for: request)
        } else {
            let ephemeral = URLSession(
                configuration: .ephemeral,
                delegate: NoRedirectURLSessionDelegate(),
                delegateQueue: nil
            )
            defer { ephemeral.finishTasksAndInvalidate() }
            (data, response) = try await ephemeral.data(for: request)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ProviderWalletStatusClientError.unavailable
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderWalletStatusClientError.httpStatus(http.statusCode)
        }
        return try JSONDecoder().decode(ProviderWalletStatusSummary.self, from: data)
    }
}
