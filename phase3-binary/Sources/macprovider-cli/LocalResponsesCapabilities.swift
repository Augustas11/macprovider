import Foundation
import MacProviderCore

/// Runtime-owned capability identity; never combine this with a separately
/// sampled model identity during a warm swap. Upstream forwarding is distinct
/// from formats whose output this provider validates.
struct LocalResponsesCapabilities: Codable, Sendable {
    let available: Bool
    let model: String?
    let modelHash: String?
    let generation: Int?
    let toolChoiceModes: [String]
    let textFormats: [String]
    let upstreamTextFormats: [String]
    let structuredOutputEnforcement: String

    enum CodingKeys: String, CodingKey {
        case available, model, generation
        case modelHash = "model_hash"
        case toolChoiceModes = "tool_choice_modes"
        case textFormats = "text_formats"
        case upstreamTextFormats = "upstream_text_formats"
        case structuredOutputEnforcement = "structured_output_enforcement"
    }

    static let unavailable = LocalResponsesCapabilities(
        available: false, model: nil, modelHash: nil, generation: nil,
        toolChoiceModes: [], textFormats: [], upstreamTextFormats: [],
        structuredOutputEnforcement: "unavailable")

    /// `toolSelectionModelID` is the runtime's exact tool-selection identity
    /// when it differs from the served `model` name (a configured catalog id).
    static func loaded(model: String, modelHash: String?, generation: Int?, runtime: String,
                       toolSelectionModelID: String? = nil) -> Self {
        let native = runtime == "mlx_cache"
        return Self(
            available: true, model: model, modelHash: modelHash, generation: generation,
            toolChoiceModes: ToolSelectionPolicy.modes(modelID: toolSelectionModelID ?? model, runtime: runtime),
            textFormats: native ? ["text", "json_object", "json_schema"] : ["text"],
            upstreamTextFormats: native ? [] : ["json_object", "json_schema"],
            structuredOutputEnforcement: native
                ? "json_object_and_strict_json_schema_validated"
                : "upstream_dependent")
    }
}
