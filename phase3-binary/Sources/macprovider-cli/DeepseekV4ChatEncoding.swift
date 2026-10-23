import Foundation
import Hub
import Jinja
import MLXLMCommon
import MacProviderCore
import Tokenizers

/// DeepSeek-V4 prompt encoding: a port of the model's own
/// `encoding/encoding_dsv4.py` (`encode_messages`, sha256
/// `abc0d26120250dda0ae077dc64aa28836026e61e970854aaeb792445e6a0dde6` in
/// `deepseek-ai/DeepSeek-V4-Flash-0731` and the TensorFold MXFP4 artifact).
/// V4 ships no Jinja chat template, so this renderer is the template for the
/// family. Messages are ordered JSON objects, as Python dicts are, and every
/// function keeps the reference's structure so it can be checked line by
/// line; the golden tests compare its output byte for byte with the Python
/// reference.
enum DeepseekV4Encoding {
    static let bosToken = "<｜begin▁of▁sentence｜>"
    static let eosToken = "<｜end▁of▁sentence｜>"
    static let thinkingStartToken = "<think>"
    static let thinkingEndToken = "</think>"
    static let dsmlToken = "｜DSML｜"
    static let userToken = "<｜User｜>"
    static let assistantToken = "<｜Assistant｜>"
    static let latestReminderToken = "<｜latest_reminder｜>"
    static let taskTokens: [String: String] = [
        "action": "<｜action｜>",
        "query": "<｜query｜>",
        "authority": "<｜authority｜>",
        "domain": "<｜domain｜>",
        "title": "<｜title｜>",
        "read_url": "<｜read_url｜>",
    ]

    /// `<｜DSML｜tool_calls>` and its close: the call block the model writes.
    static let toolCallsStart = "<\(dsmlToken)tool_calls>"
    static let toolCallsEnd = "</\(dsmlToken)tool_calls>"

    enum ThinkingMode: String, Sendable {
        case chat, thinking
    }

    /// The reference's three effort levels; `low` is its default and adds
    /// nothing to the prompt.
    enum ReasoningEffort: String, Sendable {
        case low, high, max

        var prompt: String {
            switch self {
            case .low:
                return ""
            case .high:
                return "Reasoning Effort: Absolute maximum with no shortcuts permitted.\n"
                    + "You MUST be very thorough in your thinking and comprehensively decompose the problem to resolve the root cause, rigorously stress-testing your logic against all potential paths, edge cases, and adversarial scenarios.\n"
                    + "Explicitly write out your entire deliberation process, documenting every intermediate step, considered alternative, and rejected hypothesis to ensure absolutely no assumption is left unchecked.\n\n"
            case .max:
                return "Reasoning Effort: Beyond maximum — exhaustive, relentless, and uncompromising.\n"
                    + "You MUST reason with the utmost depth and rigor, leaving absolutely nothing to chance: exhaustively decompose the problem into its most fundamental components, trace every causal chain to its root, and resolve the underlying cause rather than any surface symptom.\n"
                    + "Do not stop reasoning until you have independently verified the solution from multiple angles and are certain that no assumption remains unchecked and no error remains undiscovered.\n\n"
            }
        }
    }

    struct EncodingError: Error, Equatable, CustomStringConvertible {
        let description: String
    }

    // MARK: - Ordered JSON (Python dict semantics)

    /// A JSON value whose objects keep member order, as Python dicts do.
    indirect enum Value: Equatable {
        case null
        case bool(Bool)
        case int(Int)
        case double(Double)
        case string(String)
        case array([Value])
        case object([Member])

        struct Member: Equatable {
            var key: String
            var value: Value
        }

        subscript(key: String) -> Value? {
            guard case .object(let members) = self else { return nil }
            return members.first(where: { $0.key == key })?.value
        }

        /// `dict[key] = value`: replaces in place, else appends.
        mutating func set(_ key: String, _ value: Value) {
            guard case .object(var members) = self else { return }
            if let index = members.firstIndex(where: { $0.key == key }) {
                members[index].value = value
            } else {
                members.append(Member(key: key, value: value))
            }
            self = .object(members)
        }

        mutating func remove(_ key: String) {
            guard case .object(let members) = self else { return }
            self = .object(members.filter { $0.key != key })
        }

        func has(_ key: String) -> Bool {
            guard case .object(let members) = self else { return false }
            return members.contains(where: { $0.key == key })
        }

        /// Python truthiness.
        var isTruthy: Bool {
            switch self {
            case .null: return false
            case .bool(let value): return value
            case .int(let value): return value != 0
            case .double(let value): return value != 0
            case .string(let value): return !value.isEmpty
            case .array(let value): return !value.isEmpty
            case .object(let value): return !value.isEmpty
            }
        }

        var string: String? {
            if case .string(let value) = self { return value }
            return nil
        }

        var array: [Value]? {
            if case .array(let value) = self { return value }
            return nil
        }

        static func object(_ pairs: KeyValuePairs<String, Value>) -> Value {
            .object(pairs.map { Member(key: $0.key, value: $0.value) })
        }
    }

    /// `json.dumps(value, ensure_ascii=False)`: `", "` and `": "` separators,
    /// member order kept, non-ASCII written raw, Python float repr.
    static func toJSON(_ value: Value) -> String {
        var out = ""
        writeJSON(value, into: &out)
        return out
    }

    private static func writeJSON(_ value: Value, into out: inout String) {
        switch value {
        case .null: out += "null"
        case .bool(let bool): out += bool ? "true" : "false"
        case .int(let int): out += String(int)
        case .double(let double): out += pythonFloatRepr(double)
        case .string(let string): writeJSONString(string, into: &out)
        case .array(let array):
            out += "["
            for (index, element) in array.enumerated() {
                if index > 0 { out += ", " }
                writeJSON(element, into: &out)
            }
            out += "]"
        case .object(let members):
            out += "{"
            for (index, member) in members.enumerated() {
                if index > 0 { out += ", " }
                writeJSONString(member.key, into: &out)
                out += ": "
                writeJSON(member.value, into: &out)
            }
            out += "}"
        }
    }

    private static func writeJSONString(_ string: String, into out: inout String) {
        out += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }

    /// Python `repr(float)` for finite values: shortest round-trip digits,
    /// fixed notation for exponents in [-4, 16), `.0` on integral values.
    static func pythonFloatRepr(_ value: Double) -> String {
        guard value.isFinite else { return value.isNaN ? "NaN" : (value < 0 ? "-Infinity" : "Infinity") }
        // Swift's description is also the shortest round-trip form and uses
        // the same notation switch points (1e-05, 0.0001, 1e+16).
        return "\(value)"
    }

    /// An order-keeping strict JSON reader for reference fixtures and tool
    /// arguments (Python `json.loads`).
    static func parseJSON(_ text: String) throws -> Value {
        var parser = OrderedJSONParser(Array(text.unicodeScalars))
        let value = try parser.value(depth: 0)
        parser.skipWhitespace()
        guard parser.atEnd else { throw EncodingError(description: "trailing characters after JSON") }
        return value
    }

    // MARK: - encoding_dsv4.py

    static func encodeArgumentsToDSML(_ toolCall: Value) -> String {
        var arguments: Value
        switch toolCall["arguments"] {
        case .string(let text)?:
            if let parsed = try? parseJSON(text), case .object = parsed {
                arguments = parsed
            } else {
                arguments = .object(["arguments": .string(text)])
            }
        case .object(let members)?:
            arguments = .object(members)
        default:
            arguments = .object(["arguments": toolCall["arguments"] ?? .null])
        }
        guard case .object(let members) = arguments else { return "" }
        return members.map { member in
            let isString: Bool
            let value: String
            if case .string(let text) = member.value {
                isString = true
                value = text
            } else {
                isString = false
                value = toJSON(member.value)
            }
            return "<\(dsmlToken)parameter name=\"\(member.key)\" string=\"\(isString ? "true" : "false")\">\(value)</\(dsmlToken)parameter>"
        }.joined(separator: "\n")
    }

    static func renderTools(_ tools: [Value]) -> String {
        let schemas = tools.map(toJSON).joined(separator: "\n")
        return """
            ## Tools

            You have access to a set of tools to help answer the user's question. You can invoke tools by writing a "<\(dsmlToken)tool_calls>" block like the following:

            <\(dsmlToken)tool_calls>
            <\(dsmlToken)invoke name="$TOOL_NAME">
            <\(dsmlToken)parameter name="$PARAMETER_NAME" string="true|false">$PARAMETER_VALUE</\(dsmlToken)parameter>
            ...
            </\(dsmlToken)invoke>
            <\(dsmlToken)invoke name="$TOOL_NAME2">
            ...
            </\(dsmlToken)invoke>
            </\(dsmlToken)tool_calls>

            String parameters should be specified as is and set `string="true"`. For all other types (numbers, booleans, arrays, objects), pass the value in JSON format and set `string="false"`.

            If thinking_mode is enabled (triggered by \(thinkingStartToken)), you MUST output your complete reasoning inside \(thinkingStartToken)...\(thinkingEndToken) BEFORE any tool calls or final response.

            Otherwise, output directly after \(thinkingEndToken) with tool calls or final response.

            ### Available Tool Schemas

            \(schemas)

            You MUST strictly follow the above defined tool name and parameter schemas to invoke tool calls.

            """
    }

    static func findLastUserIndex(_ messages: [Value]) -> Int {
        for index in stride(from: messages.count - 1, through: 0, by: -1) {
            if let role = messages[index]["role"]?.string, role == "user" || role == "developer" {
                return index
            }
        }
        return -1
    }

    private static func functions(_ tools: Value?) -> [Value] {
        (tools?.array ?? []).map { $0["function"] ?? .null }
    }

    private static func callsFromOpenAIFormat(_ calls: Value?) -> [Value] {
        (calls?.array ?? []).map { call in
            .object([
                "name": call["function"]?["name"] ?? .null,
                "arguments": call["function"]?["arguments"] ?? .null,
            ])
        }
    }

    private static func text(_ value: Value?) -> String {
        switch value {
        case .string(let text)?: return text
        case nil, .null?: return ""
        case let other?: return toJSON(other)
        }
    }

    static func renderMessage(
        index: Int,
        messages: [Value],
        lastUserIndex: Int,
        thinkingMode: ThinkingMode,
        dropThinking: Bool = true,
        reasoningEffort: ReasoningEffort? = nil
    ) throws -> String {
        var prompt = ""
        let message = messages[index]
        let role = message["role"]?.string
        let content = message["content"]
        let tools = message["tools"].flatMap { $0.isTruthy ? functions($0) : nil }
        let responseFormat = message["response_format"]
        let toolCalls = message["tool_calls"].flatMap { $0.isTruthy ? callsFromOpenAIFormat($0) : nil }
        let reasoningContent = message["reasoning_content"]
        let withoutEOS = message["wo_eos"]?.isTruthy ?? false

        if index == 0, thinkingMode == .thinking {
            prompt += (reasoningEffort ?? .low).prompt
        }

        switch role {
        case "system":
            prompt += content.flatMap { $0.isTruthy ? text($0) : nil } ?? ""
            if let tools { prompt += "\n\n" + renderTools(tools) }
            if let responseFormat, responseFormat.isTruthy {
                prompt += "\n\n" + responseFormatPrompt(responseFormat)
            }
        case "developer":
            guard let content, content.isTruthy else {
                throw EncodingError(description: "Invalid message for role `developer`")
            }
            var developer = userToken + text(content)
            if let tools { developer += "\n\n" + renderTools(tools) }
            if let responseFormat, responseFormat.isTruthy {
                developer += "\n\n" + responseFormatPrompt(responseFormat)
            }
            prompt += developer
        case "user":
            prompt += userToken
            if let blocks = message["content_blocks"]?.array, !blocks.isEmpty {
                var parts: [String] = []
                for block in blocks {
                    switch block["type"]?.string {
                    case "text":
                        parts.append(text(block["text"]))
                    case "tool_result":
                        var toolContent = text(block["content"])
                        if let list = block["content"]?.array {
                            toolContent = list.map { item in
                                item["type"]?.string == "text"
                                    ? text(item["text"])
                                    : "[Unsupported \(text(item["type"]))]"
                            }.joined(separator: "\n\n")
                        }
                        parts.append("<tool_result>\(toolContent)</tool_result>")
                    default:
                        parts.append("[Unsupported \(text(block["type"]))]")
                    }
                }
                prompt += parts.joined(separator: "\n\n")
            } else {
                prompt += content.flatMap { $0.isTruthy ? text($0) : nil } ?? ""
            }
        case "latest_reminder":
            prompt += latestReminderToken + text(content)
        case "tool":
            throw EncodingError(description: "deepseek_v4 merges tool messages into user; please preprocess with merge_tool_messages()")
        case "assistant":
            var thinkingPart = ""
            var toolCallContent = ""
            if let toolCalls {
                let invokes = toolCalls.map { call in
                    "<\(dsmlToken)invoke name=\"\(text(call["name"]))\">\n\(encodeArgumentsToDSML(call))\n</\(dsmlToken)invoke>"
                }
                toolCallContent += "\n\n<\(dsmlToken)tool_calls>\n" + invokes.joined(separator: "\n")
                    + "\n</\(dsmlToken)tool_calls>"
            }
            let summary = content.flatMap { $0.isTruthy ? text($0) : nil } ?? ""
            let reasoning = reasoningContent.flatMap { $0.isTruthy ? text($0) : nil } ?? ""
            let previousHasTask = index >= 1 && messages[index - 1]["task"].map { $0 != .null } == true
            if thinkingMode == .thinking, !previousHasTask, !dropThinking || index > lastUserIndex {
                thinkingPart = reasoning + thinkingEndToken
            }
            prompt += thinkingPart + summary + toolCallContent + (withoutEOS ? "" : eosToken)
        default:
            throw EncodingError(description: "Unknown role: \(role ?? "nil")")
        }

        if index + 1 < messages.count,
           !["assistant", "latest_reminder"].contains(messages[index + 1]["role"]?.string ?? "") {
            return prompt
        }

        if let task = message["task"], task != .null {
            guard let name = task.string, let token = taskTokens[name] else {
                throw EncodingError(description: "Invalid task: '\(text(task))'")
            }
            if name != "action" {
                prompt += token
            } else {
                prompt += assistantToken
                prompt += thinkingMode != .thinking ? thinkingEndToken : thinkingStartToken
                prompt += token
            }
        } else if role == "user" || role == "developer" {
            prompt += assistantToken
            if !dropThinking, thinkingMode == .thinking {
                prompt += thinkingStartToken
            } else if dropThinking, thinkingMode == .thinking, index >= lastUserIndex {
                prompt += thinkingStartToken
            } else {
                prompt += thinkingEndToken
            }
        }
        return prompt
    }

    private static func responseFormatPrompt(_ format: Value) -> String {
        "## Response Format:\n\nYou MUST strictly adhere to the following schema to reply:\n" + toJSON(format)
    }

    static func mergeToolMessages(_ messages: [Value]) -> [Value] {
        var merged: [Value] = []
        // Keep one uniquely owned buffer for each user/tool group. Storing
        // the growing array back into Value after every block forces a copy
        // on the next append.
        var pendingUser: Value?
        var pendingBlocks: [Value] = []
        func flushUser() {
            if var user = pendingUser {
                user.set("content_blocks", .array(pendingBlocks))
                merged.append(user)
            }
            pendingUser = nil
            pendingBlocks = []
        }
        for message in messages {
            switch message["role"]?.string {
            case "tool":
                let block = Value.object([
                    "type": .string("tool_result"),
                    "tool_use_id": message["tool_call_id"] ?? .string(""),
                    "content": message["content"] ?? .string(""),
                ])
                if pendingUser == nil {
                    pendingUser = .object(["role": .string("user")])
                }
                pendingBlocks.append(block)
            case "user":
                let block = Value.object(["type": .string("text"), "text": message["content"] ?? .string("")])
                if let task = pendingUser?["task"], task != .null {
                    flushUser()
                }
                if pendingUser == nil {
                    var user = Value.object([
                        "role": .string("user"),
                        "content": message["content"] ?? .string(""),
                        "content_blocks": .array([]),
                    ])
                    for key in ["task", "wo_eos", "mask"] {
                        if let value = message[key] { user.set(key, value) }
                    }
                    pendingUser = user
                }
                pendingBlocks.append(block)
            default:
                flushUser()
                merged.append(message)
            }
        }
        flushUser()
        return merged
    }

    static func sortToolResultsByCallOrder(_ messages: [Value]) -> [Value] {
        var order: [String: Int] = [:]
        var result = messages
        for (position, message) in messages.enumerated() {
            let role = message["role"]?.string
            if role == "assistant", let calls = message["tool_calls"], calls.isTruthy, let list = calls.array {
                order = [:]
                for (index, call) in list.enumerated() {
                    let id = call["id"].flatMap { $0.isTruthy ? text($0) : nil }
                        ?? text(call["function"]?["id"])
                    if !id.isEmpty { order[id] = index }
                }
            } else if role == "user", let blocks = message["content_blocks"]?.array, !blocks.isEmpty {
                let toolBlocks = blocks.filter { $0["type"]?.string == "tool_result" }
                guard toolBlocks.count > 1, !order.isEmpty else { continue }
                // Python's sorted() is stable.
                let sorted = toolBlocks.enumerated().sorted { lhs, rhs in
                    let l = order[text(lhs.element["tool_use_id"])] ?? 0
                    let r = order[text(rhs.element["tool_use_id"])] ?? 0
                    return l != r ? l < r : lhs.offset < rhs.offset
                }.map(\.element)
                var next = 0
                let reordered = blocks.map { block -> Value in
                    guard block["type"]?.string == "tool_result" else { return block }
                    defer { next += 1 }
                    return sorted[next]
                }
                var updated = message
                updated.set("content_blocks", .array(reordered))
                result[position] = updated
            }
        }
        return result
    }

    static func dropThinkingMessages(_ messages: [Value]) -> [Value] {
        let lastUserIndex = findLastUserIndex(messages)
        let keep: Set<String> = ["user", "system", "tool", "latest_reminder", "direct_search_results"]
        var result: [Value] = []
        for (index, message) in messages.enumerated() {
            let role = message["role"]?.string ?? ""
            if keep.contains(role) || index >= lastUserIndex {
                result.append(message)
            } else if role == "assistant" {
                var stripped = message
                stripped.remove("reasoning_content")
                result.append(stripped)
            }
        }
        return result
    }

    /// `encode_messages(messages, thinking_mode, drop_thinking, add_default_bos_token, reasoning_effort)`
    /// with no `context`.
    static func encodeMessages(
        _ messages: [Value],
        thinkingMode: ThinkingMode,
        dropThinking: Bool = true,
        addDefaultBOSToken: Bool = true,
        reasoningEffort: ReasoningEffort? = nil
    ) throws -> String {
        var full = sortToolResultsByCallOrder(mergeToolMessages(messages))
        var prompt = addDefaultBOSToken ? bosToken : ""
        let effectiveDropThinking = dropThinking && !full.contains { $0["tools"]?.isTruthy == true }
        if thinkingMode == .thinking, effectiveDropThinking {
            full = dropThinkingMessages(full)
        }
        let lastUserIndex = findLastUserIndex(full)
        for index in full.indices {
            prompt += try renderMessage(
                index: index,
                messages: full,
                lastUserIndex: lastUserIndex,
                thinkingMode: thinkingMode,
                dropThinking: effectiveDropThinking,
                reasoningEffort: reasoningEffort
            )
        }
        return prompt
    }

    // MARK: - Runtime request mapping

    /// The rendering options a request's template context selects. Thinking
    /// is the default; `reasoning_effort: none` or `enable_thinking: false`
    /// selects chat mode. The buyer's OpenAI effort maps onto the
    /// reference's three levels.
    static func options(additionalContext: [String: any Sendable]?) -> (ThinkingMode, ReasoningEffort) {
        let effort = additionalContext?["reasoning_effort"] as? String
        if effort == "none" || additionalContext?["enable_thinking"] as? Bool == false {
            return (.chat, .low)
        }
        switch effort {
        case "high", "xhigh": return (.thinking, .high)
        case "max": return (.thinking, .max)
        default: return (.thinking, .low)
        }
    }

    /// The prompt for the runtime's template inputs (MLX message dictionaries
    /// and OpenAI tool definitions). Tools ride on the first system message,
    /// as the reference attaches them; without one an empty system message
    /// carries them, since the reference renders tools only on system and
    /// developer messages.
    static func renderPrompt(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> String {
        var values = messages.map(runtimeMessage)
        if let tools, !tools.isEmpty {
            let toolValues = Value.array(tools.map(runtimeTool))
            if values.first?["role"]?.string == "system" {
                values[0].set("tools", toolValues)
            } else {
                values.insert(.object(["role": .string("system"), "content": .string(""), "tools": toolValues]), at: 0)
            }
        }
        let (mode, effort) = options(additionalContext: additionalContext)
        return try encodeMessages(values, thinkingMode: mode, reasoningEffort: effort)
    }

    private static func runtimeMessage(_ message: [String: any Sendable]) -> Value {
        var value = Value.object([])
        for key in ["role", "content", "reasoning_content"] {
            if let member = message[key] { value.set(key, runtimeValue(member)) }
        }
        if let calls = message["tool_calls"] as? [Any] {
            value.set("tool_calls", .array(calls.map { call in
                let entry = call as? [String: Any] ?? [:]
                let function = entry["function"] as? [String: Any] ?? [:]
                var result = Value.object([:])
                if let id = entry["id"] { result.set("id", runtimeValue(id)) }
                result.set("type", .string("function"))
                result.set("function", .object([
                    "name": runtimeValue(function["name"] ?? ""),
                    "arguments": runtimeValue(function["arguments"] ?? [String: Any]()),
                ]))
                return result
            }))
        }
        for key in ["tool_call_id", "name"] {
            if let member = message[key] { value.set(key, runtimeValue(member)) }
        }
        return value
    }

    /// An OpenAI tool definition: `function` members in the OpenAI order
    /// (name, description, parameters); schema keys sorted, since the
    /// runtime holds them unordered.
    private static func runtimeTool(_ tool: [String: any Sendable]) -> Value {
        let function = tool["function"] as? [String: Any] ?? [:]
        var members: [Value.Member] = []
        for key in ["name", "description", "parameters"] {
            guard let member = function[key] else { continue }
            let value = runtimeValue(member)
            if key == "description", value == .null { continue }
            members.append(.init(key: key, value: value))
        }
        for key in function.keys.sorted() where !["name", "description", "parameters"].contains(key) {
            members.append(.init(key: key, value: runtimeValue(function[key]!)))
        }
        return .object(["type": .string("function"), "function": .object(members)])
    }

    static func runtimeValue(_ any: Any) -> Value {
        switch any {
        case let value as Value: return value
        case is NSNull: return .null
        case let value as Jinja.Value:
            if case .null = value { return .null }
            return .string(value.description)
        case let value as String: return .string(value)
        case let value as Bool where type(of: any) == Bool.self: return .bool(value)
        case let value as Int where type(of: any) == Int.self: return .int(value)
        case let value as Double where type(of: any) == Double.self: return .double(value)
        case let value as NSNumber:
            // Foundation numbers (JSONSerialization) carry their own kind.
            if CFGetTypeID(value) == CFBooleanGetTypeID() { return .bool(value.boolValue) }
            if CFNumberIsFloatType(value) { return .double(value.doubleValue) }
            return .int(value.intValue)
        case let value as MLXLMCommon.JSONValue:
            switch value {
            case .null: return .null
            case .bool(let bool): return .bool(bool)
            case .int(let int): return .int(int)
            case .double(let double): return .double(double)
            case .string(let string): return .string(string)
            case .array(let array): return .array(array.map(runtimeValue))
            case .object(let object): return .object(object.keys.sorted().map { .init(key: $0, value: runtimeValue(object[$0]!)) })
            }
        case let value as [Any]: return .array(value.map(runtimeValue))
        case let value as [String: Any]:
            return .object(value.keys.sorted().map { .init(key: $0, value: runtimeValue(value[$0]!)) })
        default: return .string(String(describing: any))
        }
    }
}

/// Strict JSON reading into ordered `DeepseekV4Encoding.Value`s.
private struct OrderedJSONParser {
    typealias Value = DeepseekV4Encoding.Value
    let scalars: [Unicode.Scalar]
    var index = 0

    init(_ scalars: [Unicode.Scalar]) { self.scalars = scalars }

    var atEnd: Bool { index >= scalars.count }

    func error(_ message: String) -> DeepseekV4Encoding.EncodingError {
        DeepseekV4Encoding.EncodingError(description: "JSON: \(message) at \(index)")
    }

    mutating func skipWhitespace() {
        while index < scalars.count, [" ", "\n", "\r", "\t"].contains(scalars[index]) { index += 1 }
    }

    mutating func value(depth: Int) throws -> Value {
        guard depth < 128 else { throw error("too deep") }
        skipWhitespace()
        guard index < scalars.count else { throw error("unexpected end") }
        switch scalars[index] {
        case "{":
            index += 1
            var members: [Value.Member] = []
            skipWhitespace()
            if index < scalars.count, scalars[index] == "}" { index += 1; return .object(members) }
            while true {
                skipWhitespace()
                guard index < scalars.count, scalars[index] == "\"" else { throw error("expected key") }
                let key = try string()
                skipWhitespace()
                guard index < scalars.count, scalars[index] == ":" else { throw error("expected :") }
                index += 1
                let member = try value(depth: depth + 1)
                // Python keeps the last duplicate at the first key's position.
                if let existing = members.firstIndex(where: { $0.key == key }) {
                    members[existing].value = member
                } else {
                    members.append(.init(key: key, value: member))
                }
                skipWhitespace()
                guard index < scalars.count else { throw error("unexpected end") }
                if scalars[index] == "," { index += 1; continue }
                if scalars[index] == "}" { index += 1; return .object(members) }
                throw error("expected , or }")
            }
        case "[":
            index += 1
            var elements: [Value] = []
            skipWhitespace()
            if index < scalars.count, scalars[index] == "]" { index += 1; return .array(elements) }
            while true {
                elements.append(try value(depth: depth + 1))
                skipWhitespace()
                guard index < scalars.count else { throw error("unexpected end") }
                if scalars[index] == "," { index += 1; continue }
                if scalars[index] == "]" { index += 1; return .array(elements) }
                throw error("expected , or ]")
            }
        case "\"":
            return .string(try string())
        case "t": try literal("true"); return .bool(true)
        case "f": try literal("false"); return .bool(false)
        case "n": try literal("null"); return .null
        default:
            return try number()
        }
    }

    mutating func literal(_ word: String) throws {
        let expected = Array(word.unicodeScalars)
        guard index + expected.count <= scalars.count,
              Array(scalars[index ..< index + expected.count]) == expected else { throw error("bad literal") }
        index += expected.count
    }

    mutating func number() throws -> Value {
        let start = index
        if index < scalars.count, scalars[index] == "-" { index += 1 }
        var isFloat = false
        while index < scalars.count {
            let c = scalars[index]
            if ("0" ... "9").contains(c) {
                index += 1
            } else if [".", "e", "E", "+", "-"].contains(c) {
                isFloat = true
                index += 1
            } else {
                break
            }
        }
        let text = String(String.UnicodeScalarView(scalars[start ..< index]))
        guard !text.isEmpty, text != "-" else { throw error("bad value") }
        if !isFloat, let int = Int(text) { return .int(int) }
        guard let double = Double(text) else { throw error("bad number") }
        return .double(double)
    }

    mutating func string() throws -> String {
        index += 1
        var out = String.UnicodeScalarView()
        while index < scalars.count {
            let c = scalars[index]
            index += 1
            switch c {
            case "\"":
                return String(out)
            case "\\":
                guard index < scalars.count else { throw error("bad escape") }
                let e = scalars[index]
                index += 1
                switch e {
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "/": out.append("/")
                case "b": out.append("\u{08}")
                case "f": out.append("\u{0C}")
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                case "u":
                    var code = try hex4()
                    if (0xD800 ..< 0xDC00).contains(code), index + 1 < scalars.count,
                       scalars[index] == "\\", scalars[index + 1] == "u" {
                        index += 2
                        let low = try hex4()
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    }
                    guard let scalar = Unicode.Scalar(code) else { throw error("bad code point") }
                    out.append(scalar)
                default: throw error("bad escape")
                }
            default:
                guard c.value >= 0x20 else { throw error("control character in string") }
                out.append(c)
            }
        }
        throw error("unterminated string")
    }

    mutating func hex4() throws -> UInt32 {
        guard index + 4 <= scalars.count,
              let code = UInt32(String(String.UnicodeScalarView(scalars[index ..< index + 4])), radix: 16)
        else { throw error("bad \\u escape") }
        index += 4
        return code
    }
}

/// The swift-transformers tokenizer with the DeepSeek-V4 encoder as its chat
/// template (the family ships none). Every other operation is the stock
/// adaptor's.
struct DeepseekV4ChatTokenizer: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    /// Keep the artifact bytes intact; only normalize the Split regex spelling
    /// before swift-transformers hands it to String.range(.regularExpression).
    /// That Foundation path mishandles literal CR/LF in character classes,
    /// unlike NSRegularExpression and Rust tokenizers. Escaped CR/LF have the
    /// same regex meaning and preserve punctuation/newline BPE merge boundaries.
    static func load(from directory: URL) async throws -> Self {
        let config = LanguageModelConfigurationFromHub(modelFolder: directory)
        guard let tokenizerConfig = try await config.tokenizerConfig else {
            throw Tokenizers.TokenizerError.missingConfig
        }
        let tokenizerData = try await config.tokenizerData
        var data = tokenizerData.dictionary(or: [:])
        data["pre_tokenizer"] = escapedSplitNewlines(tokenizerData.preTokenizer)
        return Self(upstream: try PreTrainedTokenizer(
            tokenizerConfig: tokenizerConfig, tokenizerData: Config(data)
        ))
    }

    static func escapedSplitNewlines(_ config: Config) -> Config {
        var result = config.dictionary(or: [:])
        switch config.type.string() {
        case "Sequence":
            result["pretokenizers"] = Config(config.pretokenizers.array(or: []).map(escapedSplitNewlines))
        case "Split":
            if let regex = config.pattern.Regex.string() {
                var pattern = config.pattern.dictionary(or: [:])
                pattern["Regex"] = Config(regex
                    .replacingOccurrences(of: "\r", with: #"\r"#)
                    .replacingOccurrences(of: "\n", with: #"\n"#))
                result["pattern"] = Config(pattern)
            }
        default:
            return config
        }
        return Config(result)
    }

    /// `config.json` model types whose prompts this encoder renders.
    static let modelTypes: Set<String> = ["deepseek_v4", "deepseek_v41"]

    static func applies(to directory: URL) -> Bool {
        guard ChatTemplateCompatibility.configuredTemplate(in: directory) == nil,
              let data = try? Data(contentsOf: directory.appendingPathComponent("config.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let modelType = object["model_type"] as? String
        else { return false }
        return modelTypes.contains(modelType)
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        let prompt: String
        do {
            prompt = try DeepseekV4Encoding.renderPrompt(
                messages: messages, tools: tools, additionalContext: additionalContext
            )
        } catch let error as DeepseekV4Encoding.EncodingError {
            throw APIError(
                status: 400,
                message: "The model's prompt encoding does not accept this conversation: \(error.description)",
                code: "invalid_request",
                param: "messages"
            )
        }
        // The prompt already carries BOS; the tokenizer adds none
        // (`add_bos_token: false`), and the role markers are added tokens.
        return upstream.encode(text: prompt, addSpecialTokens: false)
    }
}
