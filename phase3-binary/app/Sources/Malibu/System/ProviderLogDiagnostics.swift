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
