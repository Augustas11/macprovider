import Foundation

enum ProviderRecoveryDiagnosticsBundle {
    static func write(
        snapshot: AgentSnapshot,
        providerLogLines: [String],
        watchdogLogURL: URL?,
        launchdNeedsRepair: Bool,
        appVersion: String,
        paths: ProviderPaths = .current,
        now: Date = Date()
    ) throws -> URL {
        let directory = paths.appSupport.appendingPathComponent("Diagnostics", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let destination = directory
            .appendingPathComponent("malibu-recovery-failure-\(formatter.string(from: now)).json")
        let data = try ProviderDiagnosticsBundle.make(
            snapshot: snapshot,
            providerLogLines: providerLogLines,
            watchdogLogURL: watchdogLogURL,
            appVersion: appVersion,
            launchdNeedsRepair: launchdNeedsRepair,
            now: now
        )
        try data.write(to: destination, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return destination
    }

    static func appVersion(bundle: Bundle = .main) -> String {
        (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "unknown"
    }
}
