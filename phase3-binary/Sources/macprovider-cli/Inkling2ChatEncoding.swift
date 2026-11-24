import Foundation
import Jinja

/// Inkling 2 prompts (#2467), rendered natively as the
/// `thinkingmachines/Inkling-2-Mini` `chat_template.jinja` renders them.
///
/// The pinned swift-jinja (2.5.1) cannot render that template: its `tojson`
/// takes only `indent` and `ensure_ascii` and throws on the template's
/// `sort_keys=true, separators=(",", ":")`, which every request with tools or
/// tool history reaches. The template is short and fixed, so this renders the
/// same bytes from the same message values instead of rewriting it. Its
/// output is checked against prompts rendered by Jinja2 from the template
/// itself (`Inkling2ChatEncodingTests`, fixtures from
/// `scripts/lab/2467/make_inkling2_prompt_fixtures.py`).
///
/// - Tools: one `<|message_system|>tool_declare<|content_xml|>` message with
///   the declared functions as compact JSON, keys sorted at every depth.
/// - `Thinking effort level: X` is a system message before the first
///   non-system message (or at the end when there is none). The level comes
///   from `reasoning_effort` (`none` 0, `minimal` 0.1, `low` 0.2, `medium`
///   0.7, `high` 0.9, `xhigh` and `max` 0.99; 0.9 when omitted).
/// - Each message is a frame `ROLE[NAME]<|content_…|>BODY<|end_message|>`;
///   an assistant turn ends with `<|content_model_end_sampling|>`. The prompt
///   ends after the effort message: the model writes its own
///   `<|message_model|>`.
/// - A history call is `<|message_model|>NAME<|content_invoke_tool_json|>`
///   then `{"name":NAME,"args":{…}}` with top-level argument keys sorted and
///   nested values in their given order, then `<|end_message|>`.
///
/// Rendering runs inside `PromptControlTokenEncoder.encodePrompt`, so request
/// text that spells a control token stays ordinary text (SPEC-018 §3.14).
enum Inkling2Encoding {
    struct EncodingError: Error, CustomStringConvertible {
        let description: String
    }

    /// `config.json` model types whose prompts this encoder renders.
    static let modelTypes: Set<String> = ["inkling2_loop"]

    static let roleTokens: [String: String] = [
        "user": "<|message_user|>",
        "assistant": "<|message_model|>",
        "system": "<|message_system|>",
        "tool": "<|message_tool|>",
    ]

    /// The template's `effort_map`, written as its `{{ num }}` prints each
    /// value (`0` for 0.0).
    static let effortLevels: [String: String] = [
        "none": "0", "minimal": "0.1", "low": "0.2", "medium": "0.7", "high": "0.9", "xhigh": "0.99", "max": "0.99",
    ]
    static let defaultEffortLevel = "0.9"

    static let endMessage = "<|end_message|>"
    static let endSampling = "<|content_model_end_sampling|>"

    static func applies(to directory: URL) -> Bool {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("config.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let modelType = object["model_type"] as? String
        else { return false }
        return modelTypes.contains(modelType)
    }

    /// `render(_:)` over request-shaped values, as
    /// `ChatTemplatePromptRenderer.input` converts them.
    static func render(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> String {
        try render(ChatTemplatePromptRenderer.Input(
            messages: try messages.map { try Jinja.Value(any: $0) },
            tools: try tools.map { try $0.map { try Jinja.Value(any: $0) } },
            additionalContext: try (additionalContext ?? [:]).mapValues { try Jinja.Value(any: $0) },
            toolSpecs: tools
        ))
    }

    static func render(_ input: ChatTemplatePromptRenderer.Input) throws -> String {
        var out = ""
        if let tools = input.tools, !tools.isEmpty {
            let specs = try tools.map(toolSpec)
            out += "<|message_system|>tool_declare<|content_xml|>"
            out += try json(.array(specs), sortKeys: true)
            out += endMessage
        }
        let effort = try effortMessage(input.additionalContext["reasoning_effort"])
        var effortEmitted = false
        for message in input.messages {
            guard let role = member(message, "role").stringValue, let roleToken = roleTokens[role] else {
                throw EncodingError(description: "Unknown message role")
            }
            if !effortEmitted, role != "system" {
                out += effort
                effortEmitted = true
            }
            out += try frames(message, role: role, roleToken: roleToken, messages: input.messages)
        }
        if !effortEmitted { out += effort }
        return out
    }

    // MARK: Pieces

    static func effortMessage(_ value: Jinja.Value?) throws -> String {
        let level: String
        switch value {
        case nil, .null?, .undefined?:
            level = defaultEffortLevel
        case .string(let raw)?:
            guard let mapped = effortLevels[raw.trimmingCharacters(in: .whitespaces)] else {
                throw EncodingError(description: "Unknown reasoning_effort: \(raw)")
            }
            level = mapped
        case .int(let number)?:
            guard number == 0 else { throw EncodingError(description: "reasoning_effort must be in [0.0, 0.99]") }
            level = "0"
        case .double(let number)?:
            guard number >= 0, number <= 0.99 else { throw EncodingError(description: "reasoning_effort must be in [0.0, 0.99]") }
            level = number == 0 ? "0" : "\(number)"
        default:
            throw EncodingError(description: "Unknown reasoning_effort")
        }
        return "<|message_system|><|content_text|>Thinking effort level: " + level + endMessage
    }

    private static func toolSpec(_ tool: Jinja.Value) throws -> Jinja.Value {
        let fn = isDefined(member(tool, "function")) ? member(tool, "function") : tool
        var spec = OrderedDictionary<ObjectKey, Jinja.Value>()
        let description = member(fn, "description")
        spec[.string("description")] = isDefined(description) && description.isTruthy ? description : .string("")
        spec[.string("name")] = member(fn, "name")
        let parameters = member(fn, "parameters")
        spec[.string("parameters")] = isDefined(parameters) && parameters.isTruthy ? parameters : .object([:])
        let type = member(tool, "type")
        spec[.string("type")] = isDefined(type) && type.isTruthy ? type : .string("function")
        return .object(spec)
    }

    private static func frames(_ message: Jinja.Value, role: String, roleToken: String, messages: [Jinja.Value]) throws -> String {
        var header = roleToken
        let name = member(message, "name")
        if role == "tool" {
            let callID = member(message, "tool_call_id")
            if isDefined(name), name.isTruthy, let text = name.stringValue {
                header += text
            } else if isDefined(callID), callID.isTruthy {
                // As the template does: every matching earlier call appends
                // its function name.
                for previous in messages where member(previous, "role").stringValue == "assistant" && member(previous, "tool_calls").isTruthy {
                    guard case .array(let calls) = member(previous, "tool_calls") else { continue }
                    for call in calls {
                        let id = member(call, "id")
                        let callName = member(member(call, "function"), "name")
                        if isDefined(id), id == callID, isDefined(callName), let text = callName.stringValue {
                            header += text
                        }
                    }
                }
            }
        } else if role == "assistant", isDefined(name), name.isTruthy, let text = name.stringValue {
            header += text
        }

        var out = ""
        let reasoning = member(message, "reasoning_content")
        let toolCalls = member(message, "tool_calls")
        if role == "assistant", isDefined(reasoning), reasoning.isTruthy {
            out += header + "<|content_thinking|>" + (try text(reasoning)) + endMessage
        }
        let content = member(message, "content")
        if case .string(let string) = content,
           !string.isEmpty || !(role == "assistant" && (toolCalls.isTruthy || (isDefined(reasoning) && reasoning.isTruthy))) {
            out += header + "<|content_text|>" + string + endMessage
        } else if content.isTruthy {
            guard case .array(let parts) = content else {
                throw EncodingError(description: "Unsupported message content")
            }
            for part in parts {
                if case .string(let string) = part {
                    out += header + "<|content_text|>" + string + endMessage
                    continue
                }
                let type = member(part, "type")
                if !isDefined(type) || type.stringValue == "text" || type.stringValue == "input_text" {
                    let partText = member(part, "text")
                    out += header + "<|content_text|>" + (partText.stringValue ?? "") + endMessage
                } else {
                    // The provider serves Inkling 2 text-only: images are
                    // refused before rendering, so no image frame is written.
                    throw EncodingError(description: "Unsupported content part type: \(type.stringValue ?? "")")
                }
            }
        }
        if role == "assistant", toolCalls.isTruthy {
            guard case .array(let calls) = toolCalls else {
                throw EncodingError(description: "tool_calls must be a list")
            }
            for call in calls {
                let fn = member(call, "function")
                guard let fnName = member(fn, "name").stringValue else {
                    throw EncodingError(description: "tool call function name must be a string")
                }
                if isDefined(name), name.isTruthy, name.stringValue != fnName {
                    throw EncodingError(description: "assistant name does not match its tool call")
                }
                let rawArguments = member(fn, "arguments")
                let arguments: OrderedDictionary<ObjectKey, Jinja.Value>
                switch rawArguments {
                case .object(let object) where isDefined(rawArguments):
                    arguments = object
                case _ where !isDefined(rawArguments) || !rawArguments.isTruthy:
                    arguments = [:]
                case .string:
                    throw EncodingError(description: "tool call arguments must be a parsed object, not a JSON string")
                default:
                    throw EncodingError(description: "tool call arguments must be an object")
                }
                out += "<|message_model|>" + fnName + "<|content_invoke_tool_json|>"
                out += "{\"name\":" + (try json(.string(fnName), sortKeys: true)) + ",\"args\":{"
                let sorted = try arguments.sorted { lhs, rhs in
                    guard case .string(let left) = lhs.key, case .string(let right) = rhs.key else {
                        throw EncodingError(description: "tool call argument keys must be strings")
                    }
                    return left.unicodeScalars.lexicographicallyPrecedes(right.unicodeScalars)
                }
                out += try sorted.map { entry -> String in
                    guard case .string(let key) = entry.key else { throw EncodingError(description: "tool call argument keys must be strings") }
                    return (try json(.string(key), sortKeys: false)) + ":" + (try json(entry.value, sortKeys: false))
                }.joined(separator: ",")
                out += "}}" + endMessage
            }
        }
        if role == "assistant" { out += endSampling }
        return out
    }

    // MARK: Values

    /// `json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=…)`,
    /// the transformers `tojson` filter with the template's arguments.
    static func json(_ value: Jinja.Value, sortKeys: Bool) throws -> String {
        try Jinja.JSON.dumps(value, options: .init(ensureASCII: false, sortKeys: sortKeys, separators: (item: ",", key: ":")))
    }

    private static func member(_ value: Jinja.Value, _ key: String) -> Jinja.Value {
        guard case .object(let object) = value else { return .undefined }
        return object[.string(key)] ?? .undefined
    }

    private static func isDefined(_ value: Jinja.Value) -> Bool {
        if case .undefined = value { return false }
        return true
    }

    /// `~` string concatenation of a defined value.
    private static func text(_ value: Jinja.Value) throws -> String {
        if case .string(let string) = value { return string }
        throw EncodingError(description: "reasoning_content must be a string")
    }
}

private extension Jinja.Value {
    var stringValue: String? {
        if case .string(let string) = self { return string }
        return nil
    }
}
