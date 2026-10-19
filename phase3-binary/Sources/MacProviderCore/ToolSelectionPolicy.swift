import Foundation

/// Bounded, fail-closed tool selection. Guaranteed modes start generation
/// inside a call (SPEC-018 §3.11 call prefill) and validate the complete
/// output; the decoder does not constrain logits.
public enum ToolSelectionPolicy {
    public static let supportedNativeModel = "mlx-community/Qwen3.6-35B-A3B-4bit"

    /// How a chat template opens a tool call.
    public enum CallFormat: Equatable, Sendable {
        /// `<tool_call>\n<function=NAME>\n<parameter=KEY>...` (Qwen3.6).
        case functionXML
        /// `<tool_call>\n{"name": "NAME", "arguments": {...}}`.
        case jsonEnvelope
    }

    /// Per-model guaranteed-call profile. `generationPromptSuffix` is the
    /// exact text the template's generation prompt ends with when it has
    /// closed any think block; the call prefill is placed only after it.
    public struct GuaranteedCallProfile: Equatable, Sendable {
        public let format: CallFormat
        public let generationPromptSuffix: String

        public init(format: CallFormat, generationPromptSuffix: String) {
            self.format = format
            self.generationPromptSuffix = generationPromptSuffix
        }

        /// The assistant-turn prefill for a guaranteed selection: `required`
        /// opens the envelope, a named choice also opens the selected call.
        /// Names are already restricted to `[A-Za-z0-9_-]` by `schemas`.
        public func prefill(for selection: Selection) -> String? {
            switch selection {
            case .required:
                return "<tool_call>\n"
            case .named(let name):
                switch format {
                case .functionXML: return "<tool_call>\n<function=\(name)>\n"
                case .jsonEnvelope: return "<tool_call>\n{\"name\": \"\(name)\", \"arguments\": "
                }
            case .auto, .none:
                return nil
            }
        }
    }

    /// Exact loaded identities that support `required`/named, with the
    /// template facts the call prefill needs. A model without an entry gets
    /// neither guaranteed mode.
    public static let guaranteedCallProfiles: [String: GuaranteedCallProfile] = [
        supportedNativeModel: GuaranteedCallProfile(
            format: .functionXML,
            generationPromptSuffix: "<|im_start|>assistant\n<think>\n\n</think>\n\n"
        ),
        // Catalog-pinned chat_template.jinja templates and their hashes are
        // recorded in SPEC-018 §3.11. Both end at a non-thinking assistant turn;
        // their call grammars differ, so they must not share a family default.
        "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit": GuaranteedCallProfile(
            format: .functionXML,
            generationPromptSuffix: "<|im_start|>assistant\n"
        ),
        "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit": GuaranteedCallProfile(
            format: .jsonEnvelope,
            generationPromptSuffix: "<|im_start|>assistant\n"
        ),
    ]

    public static func guaranteedCallProfile(modelID: String?) -> GuaranteedCallProfile? {
        modelID.flatMap { guaranteedCallProfiles[$0] }
    }

    public static let maxCalls = 128
    public static let maxGuaranteedTokens = 16_384
    public static let maxSafeNumericMagnitude = 9_007_199_254_740_991
    public static let maxArgumentBytes = 1_048_576
    public static let maxResponseArgumentBytes = 2_097_152

    public enum Selection: Equatable, Sendable {
        case auto, none, required, named(String)
        public var holdsOutput: Bool { self != .auto }
        public var requiresCall: Bool {
            switch self { case .required, .named: return true; default: return false }
        }
    }

    public static func selection(_ value: JSONValue?) throws -> Selection {
        switch value {
        case nil, .null?, .string("auto")?: return .auto
        case .string("none")?: return .none
        case .string("required")?: return .required
        case .object(let object)?:
            guard object.count == 2, object["type"] == .string("function"),
                  case .object(let function)? = object["function"], function.count == 1,
                  case .string(let name)? = function["name"], !name.isEmpty else {
                throw unsupported("Named tool_choice must select one function")
            }
            return .named(name)
        default: throw unsupported("Unsupported tool_choice")
        }
    }

    public static func modes(modelID: String?, runtime: String) -> [String] {
        guard runtime == "mlx_cache" else { return ["auto"] }
        return guaranteedCallProfile(modelID: modelID) != nil ? ["auto", "none", "required", "named"] : ["auto", "none"]
    }

    public static func validateRequest(_ request: ChatCompletionRequest, loadedModelID: String?, runtime: String) throws {
        let mode = try selection(request.promptSource.toolChoice)
        guard mode.holdsOutput else { return }
        guard runtime == "mlx_cache", !mode.requiresCall || guaranteedCallProfile(modelID: loadedModelID) != nil else {
            throw unsupported("This model/runtime does not support the requested tool selection")
        }
        guard mode.requiresCall else { return }
        guard let maxTokens = request.maxTokens, (1...maxGuaranteedTokens).contains(maxTokens) else {
            throw unsupported("Guaranteed tool selection requires explicit max_tokens in 1...16384")
        }
        guard case .text = request.responseFormat, request.stop.isEmpty else {
            throw unsupported("Guaranteed tool selection requires text response_format and no custom stop strings")
        }
        _ = try schemas(request)
    }

    public static func schemas(_ request: ChatCompletionRequest) throws -> [String: JSONValue] {
        guard case .array(let tools)? = request.promptSource.tools, !tools.isEmpty, tools.count <= maxCalls else {
            throw unsupported("Guaranteed tool selection requires 1...128 function tools")
        }
        var schemas: [String: JSONValue] = [:]
        for tool in tools {
            guard case .object(let object) = tool, object["type"] == .string("function"),
                  case .object(let function)? = object["function"],
                  case .string(let name)? = function["name"], !name.isEmpty,
                  name.utf8.count <= 64,
                  name.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45 }),
                  schemas[name] == nil,
                  case .object(let parameters)? = function["parameters"], parameters["type"] == .string("object") else {
                throw APIError(status: 400, message: "Guaranteed tool selection requires unique named object schemas", code: "unsupported_tool_schema", param: "tools")
            }
            let schema = JSONValue.object(parameters)
            do {
                guard supportsNumericDomain(schema) else {
                    throw unsupported("Tool schema numeric values exceed the supported finite safe magnitude")
                }
                guard try schema.deterministicJSONString().utf8.count <= JSONSchemaValidator.maxSchemaBytes else {
                    throw unsupported("Tool schema exceeds byte limit")
                }
                try JSONSchemaValidator.validateSchemaShape(schema: schema)
            } catch {
                throw APIError(status: 400, message: "Tool schema is outside the supported strict JSON Schema subset", code: "unsupported_tool_schema", param: "tools")
            }
            schemas[name] = schema
        }
        if case .named(let selected) = try selection(request.promptSource.toolChoice), schemas[selected] == nil {
            throw unsupported("The selected function is not declared in tools")
        }
        return schemas
    }

    public static func validateOutput(calls: [ToolCall], finishReason: String, generatedTokens: Int, request: ChatCompletionRequest) throws {
        let mode = try selection(request.promptSource.toolChoice)
        guard mode.holdsOutput else { return }
        if mode == .none {
            guard calls.isEmpty else { throw outputError("tool_choice none produced a tool call") }
            return
        }
        guard finishReason != "length", finishReason != "cancelled", finishReason != "content_filter",
              request.maxTokens.map({ generatedTokens < $0 }) ?? true else {
            throw outputError("Tool generation ended before a complete validated result")
        }
        guard !calls.isEmpty, calls.count <= maxCalls,
              request.parallelToolCalls == true || calls.count == 1 else {
            throw outputError("Tool call cardinality does not satisfy the requested selection")
        }
        let declared = try schemas(request)
        var totalBytes = 0
        var ids = Set<String>()
        for call in calls {
            guard ids.insert(call.id).inserted, let schema = declared[call.functionName] else {
                throw outputError("Tool output contains a duplicate ID or undeclared function")
            }
            if case .named(let name) = mode, name != call.functionName {
                throw outputError("Tool output did not call the selected function")
            }
            totalBytes += call.arguments.utf8.count
            guard call.arguments.utf8.count <= maxArgumentBytes, totalBytes <= maxResponseArgumentBytes else {
                throw outputError("Tool arguments exceeded the supported byte limit")
            }
            do {
                let arguments = try StrictJSONParser.parse(call.arguments)
                guard case .object = arguments else { throw outputError("Tool arguments must be an object") }
                guard supportsNumericDomain(arguments) else {
                    throw outputError("Tool argument numeric values exceed the supported finite safe magnitude")
                }
                try JSONSchemaValidator.validateInstance(arguments, against: schema)
            } catch {
                throw outputError("Tool arguments did not validate against their declared schema")
            }
        }
    }

    /// Restrict the existing floating-point validator to a supported finite
    /// magnitude. Check Int directly, without rounding it through Double.
    public static func supportsNumericDomain(_ value: JSONValue) -> Bool {
        switch value {
        case .int(let number):
            return number >= -maxSafeNumericMagnitude && number <= maxSafeNumericMagnitude
        case .double(let number):
            return number.isFinite && number >= -Double(maxSafeNumericMagnitude) && number <= Double(maxSafeNumericMagnitude)
        case .object(let object):
            return object.values.allSatisfy(supportsNumericDomain)
        case .array(let array):
            return array.allSatisfy(supportsNumericDomain)
        default:
            return true
        }
    }

    public static func outputError(_ message: String) -> APIError {
        APIError(status: 502, message: message, type: "upstream_provider_error", code: "tool_selection_validation_failed", retryable: false, inferenceRan: true, settlementRan: true)
    }

    private static func unsupported(_ message: String) -> APIError {
        APIError(status: 400, message: message, code: "unsupported_tool_choice", param: "tool_choice")
    }
}
