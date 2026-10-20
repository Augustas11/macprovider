import Combine
import Foundation

/// App-only preferences. Provider behavior remains owned by the CLI and its
/// signed configuration; these values only control Malibu's own presence.
@MainActor
final class AppPreferences: ObservableObject {
    enum UpdateChannel: String, CaseIterable, Identifiable {
        case stable

        var id: String { rawValue }
        var title: String {
            switch self {
            case .stable: return String(localized: "Stable", comment: "Provider update channel")
            }
        }
    }

    static let shared = AppPreferences()

    @Published private(set) var updateChannel: UpdateChannel
    @Published private(set) var showsMenuBarIcon: Bool
    @Published private(set) var keepsDockIcon: Bool
    @Published private(set) var persistenceFailed: Bool

    private let fileURL: URL
    private let fileManager: FileManager
    private var storedObject: [String: Any]

    init(
        fileURL: URL = ProviderPaths.current.appSupport.appendingPathComponent("prefs.json"),
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        let fileExists = fileManager.fileExists(atPath: fileURL.path)
        let storedData = try? Data(contentsOf: fileURL)
        let parsedStored = storedData
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let stored = parsedStored ?? [:]
        storedObject = stored
        updateChannel = (stored["updateChannel"] as? String)
            .flatMap(UpdateChannel.init(rawValue:)) ?? .stable
        showsMenuBarIcon = stored["showsMenuBarIcon"] as? Bool ?? true
        keepsDockIcon = stored["keepsDockIcon"] as? Bool ?? false
        persistenceFailed = fileExists && parsedStored == nil

        // Malibu must remain reachable when it has no open windows.
        if !showsMenuBarIcon && !keepsDockIcon {
            showsMenuBarIcon = true
            persist()
        }
    }

    func setUpdateChannel(_ channel: UpdateChannel) {
        updateChannel = channel
        persist()
    }

    func setShowsMenuBarIcon(_ visible: Bool) {
        if !visible && !keepsDockIcon {
            keepsDockIcon = true
        }
        showsMenuBarIcon = visible
        persist()
    }

    func setKeepsDockIcon(_ visible: Bool) {
        if !visible && !showsMenuBarIcon {
            showsMenuBarIcon = true
        }
        keepsDockIcon = visible
        persist()
    }

    private func persist() {
        var value = storedObject
        value["updateChannel"] = updateChannel.rawValue
        value["showsMenuBarIcon"] = showsMenuBarIcon
        value["keepsDockIcon"] = keepsDockIcon
        do {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            storedObject = value
            persistenceFailed = false
        } catch {
            // Presence changes still apply to this process. The next launch
            // safely falls back to the reachable default if persistence fails.
            persistenceFailed = true
        }
    }
}
