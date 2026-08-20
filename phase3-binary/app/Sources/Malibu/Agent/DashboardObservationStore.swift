import Foundation

/// Local non-secret dashboard hold so a Malibu relaunch (DMG replace) does
/// not flash first-join copy or blank last-known USDC. Bound to `provider_id`
/// and dropped on durable demotion or identity change.
enum DashboardObservationStore {
    static let maxAge: TimeInterval = 72 * 3600

    struct Record: Codable, Equatable {
        var providerID: String
        var lastBuyerServingAt: Date?
        var hasObservedProviderEarnings: Bool
        var earningsUsdcToday: Double?
        var earningsUsdcWeek: Double?
        var earningsUsdcPending: Double?
        var earningsUsdcLifetime: Double?
        var malibuAccruedToday: Double?
        var malibuAccruedAllTime: Double?
        var malibuWithdrawable: Double?
        var malibuHeld: Double?
        var walletBound: Bool?
        var recordedAt: Date
    }

    static func fileURL(paths: ProviderPaths = .current) -> URL {
        paths.appSupport.appendingPathComponent("dashboard-observation.json")
    }

    static func load(
        providerID: String,
        fileURL: URL,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> Record? {
        guard !providerID.isEmpty,
              let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let record = try? decoder.decode(Record.self, from: data) else {
            try? fileManager.removeItem(at: fileURL)
            return nil
        }
        if record.providerID != providerID
            || now.timeIntervalSince(record.recordedAt) > maxAge {
            try? fileManager.removeItem(at: fileURL)
            return nil
        }
        return record
    }

    static func save(_ record: Record, fileURL: URL, fileManager: FileManager = .default) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(record) else { return }
        let directory = fileURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appendingPathComponent("dashboard-observation.json.tmp")
        do {
            try data.write(to: temp, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: temp.path
            )
            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try fileManager.replaceItemAt(fileURL, withItemAt: temp)
            } else {
                try fileManager.moveItem(at: temp, to: fileURL)
            }
        } catch {
            try? fileManager.removeItem(at: temp)
        }
    }

    static func clear(fileURL: URL, fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: fileURL)
    }
}
