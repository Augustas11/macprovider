import Foundation

/// Maps macprovider-cli stderr lines (launchd or Malibu-spawned) to operator-facing text.
enum ProviderLogDiagnostics {
    struct Finding: Equatable {
        let id: String
        let userMessage: String
        let matchedLine: String
    }

    private struct Rule {
        let id: String
        let needle: String
        let userMessage: String
    }

    private static let rules: [Rule] = [
        Rule(
            id: "stale_model_catalog",
            needle: "model catalog provenance envelope is stale",
            userMessage:
                "Model catalog was republished since autotune last wrote config. "
                + "Serving continues while your model row is still admitted; "
                + "run: macprovider-cli autotune --recommend --apply to refresh provenance."
        ),
        Rule(
            id: "catalog_admission",
            needle: "model artifact is not admitted by the signed candidate catalog",
            userMessage:
                "The configured model is not allowed by the signed catalog. "
                + "Run: macprovider-cli autotune --recommend --apply"
        ),
        Rule(
            id: "rate_card_admission",
            needle: "model artifact is not admitted by the signed rate card",
            userMessage:
                "The configured model is not on the signed rate card. "
                + "Run: macprovider-cli autotune --recommend --apply"
        ),
        Rule(
            id: "catalog_key_mismatch",
            needle: "model must match model_catalog_key",
            userMessage:
                "Config model does not match the catalog entry from autotune. "
                + "Run: macprovider-cli autotune --recommend --apply"
        ),
        Rule(
            id: "artifact_hash_mismatch",
            needle: "model artifact hash mismatch",
            userMessage:
                "Downloaded model weights do not match the catalog hash. "
                + "Re-download the model or rerun autotune --recommend --apply."
        ),
        Rule(
            id: "artifact_verification_failed",
            needle: "model artifact verification failed",
            userMessage:
                "Local model weights failed verification. Re-download the model or rerun autotune."
        ),
        Rule(
            id: "missing_catalog_provenance",
            needle: "model_artifact_sha256 requires model_catalog_* provenance",
            userMessage:
                "Serve config is missing catalog provenance from autotune. "
                + "Run: macprovider-cli autotune --recommend --apply"
        ),
        Rule(
            id: "missing_artifact_sha",
            needle: "coordinator join requires model_artifact_sha256",
            userMessage:
                "Serve config is missing a verified model artifact hash. "
                + "Run: macprovider-cli autotune --recommend --apply"
        ),
        Rule(
            id: "snapshot_path_mismatch",
            needle: "model must be the catalog-pinned hugging face snapshot path",
            userMessage:
                "Config points at the wrong on-disk model path. "
                + "Run: macprovider-cli autotune --recommend --apply"
        ),
    ]

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

    static func timeoutMessage(logHint: String) -> String {
        "Background provider did not become healthy in time. \(logHint)"
    }

    static func logHint(paths: ProviderPaths = .current) -> String {
        "Check \(paths.launchdStderrLog.path) and \(paths.launchdStdoutLog.path)."
    }
}
