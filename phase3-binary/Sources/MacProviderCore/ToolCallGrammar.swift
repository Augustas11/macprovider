import Foundation

/// The tool-call grammar a loaded model's chat template teaches (SPEC-018
/// §3.1). The runtime selects it from the template the model loaded with;
/// `family(modelID:)` is the catalog-family fallback for paths that have no
/// loaded template (tests, loopback relays, the coordinator's mirror).
public enum ToolCallGrammar: String, Sendable, Equatable, CaseIterable {
    /// `<tool_call>` + JSON `{"name","arguments"}` or function-XML
    /// `<function=NAME><parameter=KEY>…` (Qwen 2.5/3/3.5/3.6/3.8, Qwen3-Coder,
    /// Nemotron-3).
    case qwen
    /// `<tool_call>NAME<arg_key>K</arg_key><arg_value>V</arg_value></tool_call>`
    /// (GLM-4.5, GLM-5.3). Values are typed by the declared JSON schema.
    case glm
    /// Bare JSON `{"name","parameters"}`, optionally after `<|python_tag|>`
    /// (Llama 3.1/3.2/3.3).
    case llama3
    /// `<|tool_call>call:NAME{key:<|"|>v<|"|>,…}<tool_call|>` (Gemma 4).
    case gemma4
    /// gpt-oss Harmony frames, parsed by `HarmonyResponseParser`.
    case harmony
    /// DeepSeek-V4 DSML: `<｜DSML｜tool_calls>` holding one
    /// `<｜DSML｜invoke name="NAME">` per call, each with
    /// `<｜DSML｜parameter name="KEY" string="true|false">VALUE</｜DSML｜parameter>`
    /// (`encoding/encoding_dsv4.py`; the family has no Jinja template).
    case dsml
    /// LFM2 Pythonic call list inside native tool-call delimiters.
    case lfm2

    /// Catalog-family fallback. Families whose template has no tool support
    /// (Qwen2-VL) return nil, and so does any unknown family.
    public static func family(modelID: String) -> ToolCallGrammar? {
        let id = modelID.lowercased()
        if id.contains("qwen2-vl") || id.contains("qwen2vl") { return nil }
        // Table order (SPEC-018 §3.6): the Qwen row wins a mixed name.
        if id.contains("qwen2.5") || id.contains("qwen3") { return .qwen }
        if id.contains("gpt-oss") { return .harmony }
        if id.contains("glm-4.5") || id.contains("glm-4.6") || id.contains("glm-4.7")
            || id.contains("glm-5") { return .glm }
        if id.contains("llama-3.1") || id.contains("llama-3.2") || id.contains("llama-3.3")
            || id.contains("llama3.1") || id.contains("llama3.2") || id.contains("llama3.3") { return .llama3 }
        if id.contains("gemma-4") || id.contains("gemma4") { return .gemma4 }
        if id.contains("nemotron-3") || id.contains("nemotron3") { return .qwen }
        if id.contains("deepseek-v4") || id.contains("deepseek_v4") { return .dsml }
        if id.contains("lfm2.5-24b-a2b") { return .lfm2 }
        return nil
    }

    /// LFM templates emit these names as unquoted Python keywords.
    public static func isLFMIdentifier(_ value: String) -> Bool {
        let keywords: Set<String> = ["False", "None", "True", "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield"]
        guard !keywords.contains(value) else { return false }
        let bytes = Array(value.utf8)
        guard let first = bytes.first,
              (65...90).contains(first) || (97...122).contains(first) || first == 95 else { return false }
        return bytes.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }
    }

    /// Grammar named by an mlx-swift-lm `ToolCallFormat` raw value, which the
    /// model factory resolves from the loaded chat template.
    public static func fromTemplateFormat(_ rawValue: String?) -> ToolCallGrammar? {
        switch rawValue {
        case "json", "xml_function", "qwen3_5": return .qwen
        case "glm4": return .glm
        case "llama3": return .llama3
        case "gemma4": return .gemma4
        case "gpt_oss": return .harmony
        case "lfm2": return .lfm2
        default: return nil
        }
    }

    /// The template grammar when the model loaded one, else the family. A
    /// family with no template tool support stays unsupported even if a
    /// generic format was guessed for it.
    public static func resolved(templateFormat: String?, modelID: String) -> ToolCallGrammar? {
        let id = modelID.lowercased()
        if id.contains("qwen2-vl") || id.contains("qwen2vl") { return nil }
        return fromTemplateFormat(templateFormat) ?? family(modelID: modelID)
    }
}

/// Per-request output facts resolved when the prompt is rendered. They are
/// runtime state, never parsed from the buyer body.
public struct RequestOutputTraits: Sendable, Equatable {
    /// Tool grammar of the loaded template; nil means resolve by family.
    public var toolGrammar: ToolCallGrammar?
    /// The rendered generation prompt ends inside an open `<think>`: output
    /// up to the first `</think>` is reasoning, not content (SPEC-018 §3.12).
    public var reasoningOpen: Bool

    public init(toolGrammar: ToolCallGrammar? = nil, reasoningOpen: Bool = false) {
        self.toolGrammar = toolGrammar
        self.reasoningOpen = reasoningOpen
    }

    public static let unresolved = RequestOutputTraits()
}

/// Holder for the traits the runtime resolves while rendering one request's
/// prompt. Every copy of the request shares it, so the stop filters, stream
/// emitter and final parser read what the renderer found.
public final class RequestOutputState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = RequestOutputTraits.unresolved

    public init(_ traits: RequestOutputTraits = .unresolved) {
        value = traits
    }

    public var traits: RequestOutputTraits {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public func resolve(_ traits: RequestOutputTraits) {
        lock.lock()
        value = traits
        lock.unlock()
    }
}
