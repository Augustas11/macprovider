import Foundation

/// Durable per-`provider_id` request/token counters for dashboard UX.
/// Survives CLI restarts; lives under Application Support alongside install manifest.
struct ProviderStatsRecord: Codable, Equatable {
    static let currentVersion = 1

    var version: Int
    var providerID: String
    var requestsTotal: Int
    var requestsToday: Int
    var requestsTodayDayStart: Date
    var inputTokensToday: Int64
    var outputTokensToday: Int64
    var inputTokensAllTime: Int64
    var outputTokensAllTime: Int64
    var errorsTotal: Int
    var restartCount: Int
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case version
        case providerID = "provider_id"
        case requestsTotal = "requests_total"
        case requestsToday = "requests_today"
        case requestsTodayDayStart = "requests_today_day_start"
        case inputTokensToday = "input_tokens_today"
        case outputTokensToday = "output_tokens_today"
        case inputTokensAllTime = "input_tokens_all_time"
        case outputTokensAllTime = "output_tokens_all_time"
        case errorsTotal = "errors_total"
        case restartCount = "restart_count"
        case updatedAt = "updated_at"
    }

    static func empty(providerID: String, now: Date = Date()) -> ProviderStatsRecord {
        ProviderStatsRecord(
            version: currentVersion,
            providerID: providerID,
            requestsTotal: 0,
            requestsToday: 0,
            requestsTodayDayStart: Calendar.current.startOfDay(for: now),
            inputTokensToday: 0,
            outputTokensToday: 0,
            inputTokensAllTime: 0,
            outputTokensAllTime: 0,
            errorsTotal: 0,
            restartCount: 0,
            updatedAt: now
        )
    }
}

struct ProviderStatsStore: Sendable {
    private let fileURL: URL
    private let fileManager: FileManager

    init(providerID: String, home: URL = FileManager.default.homeDirectoryForCurrentUser, fileManager: FileManager = .default) {
        let safeID = Self.sanitizeProviderID(providerID)
        let base = home
            .appendingPathComponent("Library/Application Support/macprovider/stats", isDirectory: true)
        self.fileURL = base.appendingPathComponent("\(safeID).json", isDirectory: false)
        self.fileManager = fileManager
    }

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    func load(now: Date = Date()) -> ProviderStatsRecord? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let record = try decoder.decode(ProviderStatsRecord.self, from: data)
            guard record.version == ProviderStatsRecord.currentVersion else { return nil }
            return record
        } catch {
            return nil
        }
    }

    func save(_ record: ProviderStatsRecord) {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(record)
            let tempURL = fileURL.appendingPathExtension("tmp")
            try data.write(to: tempURL, options: .atomic)
            _ = try fileManager.replaceItemAt(fileURL, withItemAt: tempURL)
        } catch {
            // Stats persistence must never block serving.
        }
    }

    static func sanitizeProviderID(_ providerID: String) -> String {
        let trimmed = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "unknown" }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let scalars = trimmed.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        return String(scalars)
    }
}
