#if DEBUG || MACPROVIDER_LAB_HARNESS
import Foundation

/// Issue #2364 lab hook. `MACPROVIDER_LAB_FIRST_TOKEN_STALL_ARM` names a file;
/// while it holds a number of seconds, the next admitted request removes it and
/// waits that long before it reaches the model. Apple GPUs time-slice, so a
/// competing GPU load cannot keep a first token away past the watchdog floor;
/// arming after the provider is ready keeps admission canaries unaffected.
/// Release builds do not contain it.
enum LabFirstTokenStall {
    static let maximumSeconds: Double = 900

    static func consume(environment: [String: String] = ProcessInfo.processInfo.environment) -> Double? {
        guard let path = environment["MACPROVIDER_LAB_FIRST_TOKEN_STALL_ARM"],
              !path.isEmpty, (path as NSString).isAbsolutePath,
              let data = FileManager.default.contents(atPath: path)
        else { return nil }
        // Only the request whose removal succeeds takes the hold.
        guard (try? FileManager.default.removeItem(atPath: path)) != nil else { return nil }
        guard let raw = String(data: data, encoding: .utf8),
              let seconds = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              seconds.isFinite, seconds > 0, seconds <= maximumSeconds
        else { return nil }
        return seconds
    }
}
#endif
