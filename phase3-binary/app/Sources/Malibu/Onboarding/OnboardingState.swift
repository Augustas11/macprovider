import Foundation

/// Legacy V2 onboarding state persisted in onboarding.json.
/// Retained for decode tests; production onboarding no longer writes this file.
struct OnboardingState: Codable {
    let onboardingSchemaVersion: Int
    let providerID: String
    let createdAt: Date
    let lastStage: String
    let firstServingAt: Date?
    let modelDownload: ModelDownloadState?

    enum CodingKeys: String, CodingKey {
        case onboardingSchemaVersion = "onboarding_schema_version"
        case providerID = "provider_id"
        case createdAt = "created_at"
        case lastStage = "last_stage"
        case firstServingAt = "first_serving_at"
        case modelDownload = "model_download"
    }

    struct ModelDownloadState: Codable, Equatable {
        let modelID: String
        let targetURL: URL
        let targetSHA256: String
        let partialBytes: Int64

        enum CodingKeys: String, CodingKey {
            case modelID = "model_id"
            case targetURL = "target_url"
            case targetSHA256 = "target_sha256"
            case partialBytes = "partial_bytes"
        }
    }
}
