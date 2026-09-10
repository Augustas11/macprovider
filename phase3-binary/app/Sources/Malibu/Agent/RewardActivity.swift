import Foundation

/// A read-only page from the coordinator reward audit, relayed by the local
/// provider control socket. It intentionally contains activity, not totals:
/// audit rows can describe holds or state transitions and must never be summed
/// as economic credits in the app.
struct RewardActivityPage: Codable, Equatable, Sendable {
    let events: [RewardActivityEvent]
    let nextBeforeID: String?

    enum CodingKeys: String, CodingKey {
        case events
        case nextBeforeID = "next_before_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        events = try c.decode([RewardActivityEvent].self, forKey: .events)
        if c.contains(.nextBeforeID), !(try c.decodeNil(forKey: .nextBeforeID)) {
            let cursor = try c.decode(String.self, forKey: .nextBeforeID)
            guard Self.isValidCursor(cursor) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .nextBeforeID,
                    in: c,
                    debugDescription: "Invalid reward audit cursor"
                )
            }
            nextBeforeID = cursor
        } else {
            nextBeforeID = nil
        }
    }

    init(events: [RewardActivityEvent], nextBeforeID: String?) {
        self.events = events
        self.nextBeforeID = nextBeforeID
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(events, forKey: .events)
        try c.encodeIfPresent(nextBeforeID, forKey: .nextBeforeID)
    }

    private static func isValidCursor(_ value: String) -> Bool {
        guard value.hasPrefix("mra_"), let id = Int64(value.dropFirst(4)) else { return false }
        return id > 0 && value == "mra_\(id)"
    }

    func mergedEvents(
        with existing: [RewardActivityEvent],
        loadingOlderPage: Bool
    ) -> [RewardActivityEvent] {
        guard loadingOlderPage else { return events }
        let existingIDs = Set(existing.map(\.id))
        return existing + events.filter { !existingIDs.contains($0.id) }
    }
}

struct RewardActivityEvent: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let occurredAt: Date
    let eventType: String
    let amountMALIBU: Double?
    let withdrawalHoldReason: String?
    let sourceReason: String?
    let summary: String

    enum CodingKeys: String, CodingKey {
        case id
        case occurredAt = "occurred_at"
        case eventType = "event_type"
        case amountMALIBU = "amount_malibu"
        case withdrawalHoldReason = "withdrawal_hold_reason"
        case sourceReason = "source_reason"
        case summary
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try Self.requiredString(c, key: .id)
        let rawOccurredAt = try Self.requiredString(c, key: .occurredAt)
        guard let parsed = Self.parseUTC(rawOccurredAt) else {
            throw DecodingError.dataCorruptedError(
                forKey: .occurredAt,
                in: c,
                debugDescription: "Invalid reward audit time"
            )
        }
        occurredAt = parsed
        eventType = try Self.requiredString(c, key: .eventType)
        amountMALIBU = try Self.optionalDecimal(c, key: .amountMALIBU)
        withdrawalHoldReason = try Self.optionalString(c, key: .withdrawalHoldReason)
        sourceReason = try Self.optionalString(c, key: .sourceReason)
        summary = try Self.requiredString(c, key: .summary)
    }

    init(
        id: String,
        occurredAt: Date,
        eventType: String,
        amountMALIBU: Double? = nil,
        withdrawalHoldReason: String? = nil,
        sourceReason: String? = nil,
        summary: String
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.eventType = eventType
        self.amountMALIBU = amountMALIBU
        self.withdrawalHoldReason = withdrawalHoldReason
        self.sourceReason = sourceReason
        self.summary = summary
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(Self.formatUTC(occurredAt), forKey: .occurredAt)
        try c.encode(eventType, forKey: .eventType)
        try c.encodeIfPresent(amountMALIBU, forKey: .amountMALIBU)
        try c.encodeIfPresent(withdrawalHoldReason, forKey: .withdrawalHoldReason)
        try c.encodeIfPresent(sourceReason, forKey: .sourceReason)
        try c.encode(summary, forKey: .summary)
    }

    private static func requiredString(
        _ c: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> String {
        let value = try c.decode(String.self, forKey: key)
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "Empty reward audit field")
        }
        return value
    }

    private static func optionalString(
        _ c: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> String? {
        guard c.contains(key), !(try c.decodeNil(forKey: key)) else { return nil }
        return try requiredString(c, key: key)
    }

    private static func optionalDecimal(
        _ c: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> Double? {
        guard c.contains(key), !(try c.decodeNil(forKey: key)) else { return nil }
        if let value = try? c.decode(Double.self, forKey: key), value.isFinite { return value }
        if let raw = try? c.decode(String.self, forKey: key),
           let value = Double(raw), value.isFinite { return value }
        throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "Invalid reward audit amount")
    }

    private static func parseUTC(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    private static func formatUTC(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

enum RewardAuditControlErrorCode: String, Sendable, Equatable {
    case authenticationRequired = "authentication_required"
    case rateLimited = "rate_limited"
    case temporarilyUnavailable = "temporarily_unavailable"
    case invalidResponse = "invalid_response"
}

enum RewardActivityPresentation {
    static func title(for event: RewardActivityEvent) -> String {
        switch event.eventType {
        case "malibu_accrual_inserted": return "MALIBU reward recorded"
        case "malibu_hold_applied": return "MALIBU reward held"
        case "malibu_hold_cleared": return "MALIBU hold cleared"
        case "wallet_daily_cap_applied": return "Wallet daily limit applied"
        case "wallet_bind_projected": return "Reward wallet updated"
        case "trust_tier_promoted": return "Trust status updated"
        case "trust_tier_demoted": return "Trust status updated"
        case "withdrawal_candidate_selected": return "Withdrawal eligibility checked"
        case "withdrawal_candidate_skipped": return "Withdrawal eligibility checked"
        case "eligibility_reason_changed": return "Reward eligibility updated"
        default: return "Reward activity updated"
        }
    }

    static func detailLines(for event: RewardActivityEvent) -> [String] {
        var lines: [String] = []
        if let amount = event.amountMALIBU {
            lines.append(String(format: "%.2f MALIBU", amount))
        }
        if let source = event.sourceReason {
            lines.append("Source: \(sourceCopy(source))")
        }
        if let hold = event.withdrawalHoldReason {
            lines.append("Hold: \(holdCopy(hold))")
        }
        return lines
    }

    static func timeText(for event: RewardActivityEvent) -> String {
        event.occurredAt.formatted(date: .abbreviated, time: .shortened)
    }

    static func errorText(_ code: RewardAuditControlErrorCode, retryAfterSeconds: Int?) -> String {
        switch code {
        case .authenticationRequired:
            return "Reward activity needs a refreshed provider connection."
        case .rateLimited:
            if let retryAfterSeconds, retryAfterSeconds > 0 {
                return "Reward activity is busy. Try again in \(retryAfterSeconds) seconds."
            }
            return "Reward activity is busy. Try again shortly."
        case .temporarilyUnavailable:
            return "Reward activity is temporarily unavailable."
        case .invalidResponse:
            return "Reward activity could not be verified. Try again."
        }
    }

    private static func sourceCopy(_ raw: String) -> String {
        switch raw {
        case "malibu_verified_useful_work_v0_2": return "verified useful work"
        case "malibu_bootstrap_tick": return "bootstrap reward"
        default: return "coordinator record"
        }
    }

    private static func holdCopy(_ raw: String) -> String {
        switch raw {
        case "per_wallet_daily_cap": return "wallet daily limit"
        case "per_provider_daily_cap": return "provider daily limit"
        case "trust_tier_provisional", "provisional_trust_tier": return "trust review"
        default: return "review pending"
        }
    }
}
