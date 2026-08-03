import Foundation

/// Local non-secret display cache for the registered payout address so the
/// dashboard can show a truncated address after restart without inventing a
/// new money-path write. Source of truth remains the coordinator row; this
/// store is refreshed from the challenge GET on dashboard open.
enum PayoutRegistrationStore {
    private static let addressKey = "malibu.payout.registered_address"
    private static let pendingKey = "malibu.payout.pending_until_utc"

    struct Record: Equatable {
        let address: String
        let pendingUntilUTC: String?
    }

    static func save(address: String, pendingUntilUTC: String?) {
        let defaults = UserDefaults.standard
        defaults.set(address, forKey: addressKey)
        if let pendingUntilUTC {
            defaults.set(pendingUntilUTC, forKey: pendingKey)
        } else {
            defaults.removeObject(forKey: pendingKey)
        }
    }

    static func load() -> Record? {
        let defaults = UserDefaults.standard
        guard let address = defaults.string(forKey: addressKey),
              !address.isEmpty
        else {
            return nil
        }
        return Record(
            address: address,
            pendingUntilUTC: defaults.string(forKey: pendingKey)
        )
    }

    static func clear() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: addressKey)
        defaults.removeObject(forKey: pendingKey)
    }
}
