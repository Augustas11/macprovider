import Foundation

// MARK: - MDM enrollment state

/// MDM enrollment state of this Mac, as reported by
/// `profiles status -type enrollment`.
///
/// macOS allows exactly one MDM enrollment per device: a Mac managed by a
/// corporate MDM cannot also enroll in macprovider's MDM, and an unenrolled
/// Mac must never be incorrectly told it is "already enrolled".
enum MDMEnrollmentState: Equatable, Sendable {
    case notEnrolled
    case enrolledMacprovider(serverURL: String)
    case enrolledOtherMDM(serverURL: String)
    /// `profiles status` could not be run or produced no useful output.
    /// Distinct from .notEnrolled — callers should proceed (not block) when
    /// the check fails, since a redundant profile download is idempotent.
    case checkFailed

    var isMacprovider: Bool {
        if case .enrolledMacprovider = self { return true }
        return false
    }
}

// MARK: - Recognised macprovider MDM host suffixes / known hosts

/// Coordinator hosts that are always ours regardless of local config.
let macproviderMDMHostSuffixes = [".streamvc.live", ".macprovider.xyz"]
let macproviderMDMHosts = ["coordinator.streamvc.live"]

// MARK: - Parser

/// Parse `profiles status -type enrollment` output into an enrollment state.
///
/// Relevant output shapes (macOS 14+):
///
///     Enrolled via DEP: No
///     MDM enrollment: Yes (User Approved)
///     MDM server: https://coordinator.streamvc.live/mdm/connect
///
/// or when not enrolled:
///
///     Enrolled via DEP: No
///     MDM enrollment: No
///
/// Only the `MDM enrollment:` line decides enrolled-vs-not. The
/// `Enrolled via DEP:` line must NOT be used (it was a false-positive source
/// in earlier heuristics that matched on a substring of "enrolled").
///
/// - Parameters:
///   - output: Raw stdout from `profiles status -type enrollment`.
///   - expectedHosts: Additional hosts that count as "ours" (e.g. the host
///     extracted from the locally configured coordinator URL).
/// - Returns: The computed enrollment state.
func parseMDMEnrollmentStatus(
    _ output: String,
    expectedHosts: [String] = []
) -> MDMEnrollmentState {
    var enrolled = false
    var serverURL: String?

    for rawLine in output.split(separator: "\n") {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        let lower = line.lowercased()
        if lower.hasPrefix("mdm enrollment:") {
            let value = line.dropFirst("mdm enrollment:".count)
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            enrolled = value.hasPrefix("yes")
        } else if lower.hasPrefix("mdm server:") {
            serverURL = line.dropFirst("mdm server:".count)
                .trimmingCharacters(in: .whitespaces)
        }
    }

    guard enrolled else { return .notEnrolled }

    guard let serverURL, let host = URL(string: serverURL)?.host?.lowercased() else {
        // Enrolled but the server URL is unreadable — report as foreign.
        return .enrolledOtherMDM(serverURL: serverURL ?? "<unknown>")
    }

    let ours = macproviderMDMHosts.contains(host)
        || macproviderMDMHostSuffixes.contains(where: { host.hasSuffix($0) })
        || expectedHosts.contains(where: { !$0.isEmpty && $0.lowercased() == host })
    return ours
        ? .enrolledMacprovider(serverURL: serverURL)
        : .enrolledOtherMDM(serverURL: serverURL)
}

// MARK: - Live check

/// Query this Mac's MDM enrollment state by running
/// `/usr/bin/profiles status -type enrollment` (works unprivileged).
///
/// `coordinatorURL` (http(s):// or ws(s)://) contributes its host to the set
/// of accepted macprovider MDM hosts so that self-hosted coordinators are
/// recognised without being listed in the static suffix table.
///
/// Returns `.checkFailed` (not `.notEnrolled`) when the tool itself fails,
/// so callers can choose: enroll proceeds to download (idempotent),
/// doctor says state is unknown rather than asserting non-enrollment.
func checkMDMEnrollment(coordinatorURL: String? = nil) -> MDMEnrollmentState {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/profiles")
    process.arguments = ["status", "-type", "enrollment"]

    let outPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = Pipe()

    do {
        try process.run()
    } catch {
        return .checkFailed
    }
    process.waitUntilExit()

    let output = String(
        data: outPipe.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
    ) ?? ""

    if process.terminationStatus != 0
        && output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return .checkFailed
    }

    var expectedHosts: [String] = []
    if let coordinatorURL, let host = URL(string: coordinatorURL)?.host {
        expectedHosts.append(host)
    }
    return parseMDMEnrollmentStatus(output, expectedHosts: expectedHosts)
}

// MARK: - Hardware serial

/// Read the Mac's hardware serial number via `ioreg -c IOPlatformExpertDevice`.
/// Returns `nil` on parse failure (unlikely on real hardware; hits in test environments).
func macHardwareSerialNumber() -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
    process.arguments = ["-c", "IOPlatformExpertDevice", "-d", "2"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
        try process.run()
    } catch {
        return nil
    }
    process.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let text = String(data: data, encoding: .utf8) else { return nil }

    for line in text.split(separator: "\n") {
        guard line.contains("IOPlatformSerialNumber") else { continue }
        // ioreg format: "IOPlatformSerialNumber" = "C02XXXXX..."
        // Splitting on " yields: [..., "IOPlatformSerialNumber", " = ", "C02...", ...]
        let parts = line.split(separator: "\"", omittingEmptySubsequences: false)
        if parts.count >= 4 {
            let candidate = String(parts[3])
            if !candidate.isEmpty { return candidate }
        }
    }
    return nil
}

// MARK: - URL helpers

/// Derive the HTTPS coordinator base URL from a coordinator URL that may use
/// `wss://` or `https://`.  Path, query, and fragment are stripped.
///
///     coordinatorHTTPBase("wss://coordinator.streamvc.live/ws")
///     // → "https://coordinator.streamvc.live"
func coordinatorHTTPBase(_ rawURL: String) -> String {
    guard var components = URLComponents(string: rawURL) else {
        return rawURL
    }
    switch components.scheme {
    case "wss":  components.scheme = "https"
    case "ws":   components.scheme = "http"
    default:     break
    }
    components.path = ""
    components.query = nil
    components.fragment = nil
    return components.url?.absoluteString ?? rawURL
}
