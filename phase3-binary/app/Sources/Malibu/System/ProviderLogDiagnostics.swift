import Foundation

/// Maps macprovider-cli stderr lines (launchd or Malibu-spawned) to operator-facing text.
enum ProviderLogDiagnostics {
    static let providerSoftwareInstallHandledAutoupdateACLMarker =
        "autoupdate acl_home_repair_handled=malibu_provider_software_install_success"

    static let staleLaunchAgentMessage =
        "Provider setup is blocked by a previous installation. "
        + "Click Launch Provider to repair the background service. "
        + "Your provider identity and model files will be kept."

    struct Finding: Equatable {
        let id: String
        let userMessage: String
        let matchedLine: String
    }

    static func isActionable(_ finding: Finding, launchdNeedsRepair: Bool) -> Bool {
        finding.id != "stale_launch_agent" || launchdNeedsRepair
    }

    private struct Rule {
        let id: String
        let needle: String
        let userMessage: String
    }

    private static let rules: [Rule] = [
        Rule(
            id: "stale_launch_agent",
            needle: "provider process unhealthy: launchd service live.malibu.provider has no validated pid at",
            userMessage: staleLaunchAgentMessage
        ),
        Rule(
            id: "stale_model_catalog",
            needle: "model catalog provenance envelope is stale",
            userMessage:
                "Model options changed since this Mac last picked a model. "
                + "Customer work can continue if this model is still approved; "
                + "update provider software if Malibu asks you to refresh it."
        ),
        Rule(
            id: "catalog_admission",
            needle: "model artifact is not admitted by the signed candidate catalog",
            userMessage:
                "This model is not currently allowed for customer work. "
                + "Update provider software and pick the recommended model again."
        ),
        Rule(
            id: "rate_card_admission",
            needle: "model artifact is not admitted by the signed rate card",
            userMessage:
                "This model is not currently eligible for paid customer work. "
                + "Update provider software and pick the recommended model again."
        ),
        Rule(
            id: "catalog_key_mismatch",
            needle: "model must match model_catalog_key",
            userMessage:
                "The selected model no longer matches the saved provider setup. "
                + "Update provider software and pick the recommended model again."
        ),
        Rule(
            id: "artifact_hash_mismatch",
            needle: "model artifact hash mismatch",
            userMessage:
                "Downloaded model weights do not match the approved copy. "
                + "Download the model again or pick the recommended model again."
        ),
        Rule(
            id: "artifact_verification_failed",
            needle: "model artifact verification failed",
            userMessage:
                "Local model weights failed verification. Download the model again or pick the recommended model again."
        ),
        Rule(
            id: "missing_catalog_provenance",
            needle: "model_artifact_sha256 requires model_catalog_* provenance",
            userMessage:
                "Provider setup is missing model verification details. "
                + "Update provider software and pick the recommended model again."
        ),
        Rule(
            id: "missing_artifact_sha",
            needle: "coordinator join requires model_artifact_sha256",
            userMessage:
                "Provider setup is missing a verified model file. "
                + "Update provider software and download the model again."
        ),
        Rule(
            id: "snapshot_path_mismatch",
            needle: "model must be the catalog-pinned hugging face snapshot path",
            userMessage:
                "Provider setup points at the wrong local model path. "
                + "Update provider software and pick the recommended model again."
        ),
    ]

    static func homeAutoupdateACLRejection(
        lines: [String],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Finding? {
        let needle = "autoupdate recovery_error=acl_write_rejected:"
        let homePath = homeDirectory.standardizedFileURL.path
        for line in lines.reversed() {
            let lower = line.lowercased()
            if lower.contains(providerSoftwareInstallHandledAutoupdateACLMarker)
                || lower.contains("autoupdate lifecycle_transition=watchdog_recovery ") {
                return nil
            }
            guard let range = lower.range(of: needle) else { continue }
            let rawPath = String(line[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if URL(fileURLWithPath: rawPath).standardizedFileURL.path == homePath {
                return Finding(
                    id: "autoupdate_home_acl_rejected",
                    userMessage:
                        "Provider software repair is needed. A macOS folder permission is blocking automatic update recovery; Malibu can repair the provider software while keeping your provider identity and downloaded model files.",
                    matchedLine: line
                )
            }
            let firstField = rawPath.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? rawPath
            let rejectedPath = URL(fileURLWithPath: firstField).standardizedFileURL.path
            guard rejectedPath == homePath else { continue }
            return Finding(
                id: "autoupdate_home_acl_rejected",
                userMessage:
                    "Provider software repair is needed. A macOS folder permission is blocking automatic update recovery; Malibu can repair the provider software while keeping your provider identity and downloaded model files.",
                matchedLine: line
            )
        }
        return nil
    }

    static func diagnose(lines: [String]) -> Finding? {
        for line in lines.reversed() {
            let normalized = line.lowercased()
            for rule in rules {
                if normalized.contains(rule.needle) {
                    return Finding(id: rule.id, userMessage: rule.userMessage, matchedLine: line)
                }
            }
        }
        return nil
    }

    /// Provider stdout/stderr and watchdog logs have independent tails, so
    /// their array order is not a chronology. Provider diagnostics take
    /// precedence; a stale watchdog hint must not hide a newer provider error.
    static func diagnose(
        providerLines: [String],
        watchdogLines: [String],
        launchdNeedsRepair: Bool = false
    ) -> Finding? {
        if launchdNeedsRepair,
           let staleFinding = diagnose(
               lines: (providerLines + watchdogLines).filter {
                   $0.lowercased().contains("provider process unhealthy: launchd service live.malibu.provider has no validated pid at")
               }
           ) {
            return staleFinding
        }
        return diagnose(lines: providerLines) ?? diagnose(lines: watchdogLines)
    }

    static func timeoutMessage(logHint: String) -> String {
        "Background provider did not become healthy in time. \(logHint)"
    }

    static func logHint(paths: ProviderPaths = .current) -> String {
        "Check \(paths.launchdStderrLog.path), \(paths.launchdStdoutLog.path), and \(paths.watchdogLog.path)."
    }
}
