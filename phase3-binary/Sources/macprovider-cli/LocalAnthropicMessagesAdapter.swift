import Foundation
import CoreFoundation
import MacProviderCore

struct LocalAnthropicMessagesError: Error {
    let code: String
    let param: String
    let message: String
    var errorBody: Data {
        (try? JSONSerialization.data(withJSONObject: ["type": "error", "error": ["type": "invalid_request_error", "code": code, "param": param, "message": message]])) ?? Data()
    }
}

/// Anthropic Messages wire translation over the existing local chat pipeline.
/// No model execution, admission, accounting, or cancellation lives here.
final class LocalAnthropicMessagesAdapter {
    let chatRequestBody: Data
    let stream: Bool
    private let model: String
    private let thinkingRequested: Bool
    private let stopSequences: [String]
    private let id = "msg_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private var started = false
    private var terminal = false
    private var lineBuffer = ""
    private var finishReason: String?
    private var stopSequence: String?
    private var usage: [String: Any] = ["input_tokens": 0, "output_tokens": 0]
    private var nextIndex = 0
    private var openBlock: (index: Int, type: String)?
    private var toolCalls: [Int: [String: Any]] = [:]
    private var toolOrder: [Int] = []
    private var textTail = ""
    private var thinkBuffer = ""
    private var insideThink = false
    private var refusal = false

    private static func invalid(_ param: String, _ message: String, code: String = "unsupported_content_shape") -> LocalAnthropicMessagesError {
        LocalAnthropicMessagesError(code: code, param: param, message: message)
    }
    private static func isBool(_ value: Any) -> Bool {
        (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
    }
    private static func number(_ value: Any?, integer: Bool = false) -> NSNumber? {
        guard let value, let number = value as? NSNumber, !isBool(value), number.doubleValue.isFinite,
              !integer || number.doubleValue.rounded() == number.doubleValue else { return nil }
        return number
    }
    private static func keys(_ object: [String: Any], _ allowed: Set<String>, _ path: String) throws {
        guard Set(object.keys).isSubset(of: allowed) else { throw invalid(path, "Unsupported field in \(path)") }
    }
    private static func nonempty(_ value: Any?, _ path: String) throws -> String {
        guard let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw invalid(path, "\(path) is required", code: "invalid_request") }
        return text
    }
    private static func object(_ body: Data) throws -> [String: Any] {
        guard let text = String(data: body, encoding: .utf8), (try? StrictJSONParser.parse(text, maxDepth: 32)) != nil,
              let result = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw invalid("", "Malformed JSON, duplicate keys, or excessive nesting", code: "invalid_request")
        }
        return result
    }
    private static func text(_ value: Any?, optional: Bool = false) throws -> String {
        if optional && (value == nil || value is NSNull) { return "" }
        if let value = value as? String { return value }
        guard let blocks = value as? [[String: Any]] else { throw invalid("content", "content must be a string or text block array") }
        return try blocks.map { block in
            try keys(block, ["type", "text", "cache_control"], "content")
            guard block["type"] as? String == "text", let text = block["text"] as? String else { throw invalid("content", "Only text blocks are supported") }
            return text
        }.joined()
    }

    init(body: Data) throws {
        let request = try Self.object(body)
        // Privacy-class work is accepted only over the coordinator WebSocket.
        // Translation must not discard its direct-HTTP downgrade marker.
        if request.keys.contains("privacy_class") {
            throw APIError(status: 400, message: PrivacyClassConstants.downgradeRejected, code: PrivacyClassConstants.downgradeRejected)
        }
        let known: Set<String> = ["model", "max_tokens", "system", "messages", "tools", "tool_choice", "stream", "stop_sequences", "temperature", "top_p", "top_k", "metadata", "service_tier", "thinking"]
        // Match the gateway: SDK extension fields and beta controls are ignored,
        // while ambiguous case variants and explicitly unsupported controls fail.
        for key in request.keys {
            if key == "top_k" || (!known.contains(key) && known.contains(where: { $0.lowercased() == key.lowercased() })) {
                throw Self.invalid(key, "\(key) is not supported")
            }
        }
        model = try Self.nonempty(request["model"], "model")
        guard let maximum = Self.number(request["max_tokens"], integer: true), maximum.doubleValue >= 0 else { throw Self.invalid("max_tokens", "max_tokens is required and must be a nonnegative integer", code: "invalid_request") }
        if let value = request["stream"], !Self.isBool(value) { throw Self.invalid("stream", "stream must be a boolean") }
        stream = request["stream"] as? Bool ?? false
        if let value = request["metadata"], !(value is NSNull), !(value is [String: Any]) { throw Self.invalid("metadata", "metadata must be an object") }
        if let value = request["service_tier"], !(value is NSNull), !(value is String) { throw Self.invalid("service_tier", "service_tier must be a string") }
        if let value = request["stop_sequences"], !(value is [String]) { throw Self.invalid("stop_sequences", "stop_sequences must be a string array") }
        stopSequences = (request["stop_sequences"] as? [String] ?? []).filter { !$0.isEmpty }
        var messages: [[String: Any]] = []
        if let system = request["system"], !(system is NSNull) {
            let content = try Self.text(system)
            if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { messages.append(["role": "system", "content": content]) }
        }
        guard let input = request["messages"] as? [[String: Any]], !input.isEmpty else { throw Self.invalid("messages", "messages is required", code: "invalid_request") }
        for message in input {
            try Self.keys(message, ["role", "content"], "messages")
            guard let role = message["role"] as? String, ["user", "assistant"].contains(role) else { throw Self.invalid("messages.role", "role must be user or assistant") }
            if let content = message["content"] as? String { messages.append(["role": role, "content": content]); continue }
            guard let blocks = message["content"] as? [[String: Any]] else { throw Self.invalid("messages.content", "content must be a string or content block array") }
            var content = "", reasoning: [String] = [], calls: [[String: Any]] = []
            var emitted = false
            for block in blocks {
                switch block["type"] as? String {
                case "text": content += try Self.text([block])
                case "thinking", "redacted_thinking":
                    guard role == "assistant" else { throw Self.invalid("content", "Only assistant messages support thinking") }
                    try Self.keys(block, ["type", "thinking", "signature", "data", "cache_control"], "thinking")
                    for field in ["thinking", "signature", "data"] { if let value = block[field], !(value is String) { throw Self.invalid(field, "\(field) must be a string") } }
                    if block["type"] as? String == "thinking", let value = block["thinking"] as? String, !value.isEmpty { reasoning.append(value) }
                case "tool_use":
                    guard role == "assistant" else { throw Self.invalid("content", "tool_use requires assistant role") }
                    try Self.keys(block, ["type", "id", "name", "input", "cache_control"], "tool_use")
                    let callID = try Self.nonempty(block["id"], "tool_use.id"), name = try Self.nonempty(block["name"], "tool_use.name")
                    let arguments: [String: Any]
                    if let value = block["input"], !(value is NSNull) {
                        guard let object = value as? [String: Any] else { throw Self.invalid("tool_use.input", "input must be an object") }; arguments = object
                    } else { arguments = [:] }
                    calls.append(["id": callID, "type": "function", "function": ["name": name, "arguments": String(decoding: try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]), as: UTF8.self)]])
                case "tool_result":
                    guard role == "user" else { throw Self.invalid("content", "tool_result requires user role") }
                    try Self.keys(block, ["type", "tool_use_id", "content", "is_error", "cache_control"], "tool_result")
                    if let value = block["is_error"], !Self.isBool(value) { throw Self.invalid("tool_result.is_error", "is_error must be a boolean") }
                    if !content.isEmpty { messages.append(["role": "user", "content": content]); content = "" }
                    let result = try Self.text(block["content"], optional: true)
                    messages.append(["role": "tool", "tool_call_id": try Self.nonempty(block["tool_use_id"], "tool_result.tool_use_id"), "content": (block["is_error"] as? Bool == true ? "Tool error: " : "") + result]); emitted = true
                default: throw Self.invalid("content", "Unsupported content block")
                }
            }
            if role == "assistant" {
                var result: [String: Any] = ["role": role, "content": content.isEmpty && !calls.isEmpty ? NSNull() : content as Any]
                if !reasoning.isEmpty { result["reasoning_content"] = reasoning.joined(separator: "\n") }
                if !calls.isEmpty { result["tool_calls"] = calls }
                messages.append(result)
            } else if !content.isEmpty { messages.append(["role": role, "content": content]) }
            else if !emitted { throw Self.invalid("content", "user content produced no chat messages") }
        }
        var chat: [String: Any] = ["model": model, "messages": messages, "stream": stream, "max_tokens": maximum]
        if !stopSequences.isEmpty { chat["stop"] = stopSequences }
        for field in ["temperature", "top_p"] {
            if let value = request[field] { guard Self.number(value) != nil else { throw Self.invalid(field, "\(field) must be numeric") }; chat[field] = value }
        }
        var thinking = false
        if let value = request["thinking"], !(value is NSNull) {
            guard let config = value as? [String: Any] else { throw Self.invalid("thinking", "thinking must be an object") }
            if let budget = config["budget_tokens"], Self.number(budget, integer: true) == nil { throw Self.invalid("thinking.budget_tokens", "budget_tokens must be an integer") }
            switch config["type"] as? String {
            case "enabled": thinking = true; chat["reasoning_effort"] = (Self.number(config["budget_tokens"], integer: true)?.doubleValue ?? 0) >= 16384 ? "high" : "medium"
            case "adaptive": thinking = true; chat["reasoning_effort"] = "medium"
            case "disabled": chat["reasoning_effort"] = "low"
            default: throw Self.invalid("thinking.type", "thinking.type must be enabled, disabled or adaptive")
            }
        }
        thinkingRequested = thinking
        var names = Set<String>(), tools: [[String: Any]] = []
        if let value = request["tools"] {
            guard let inputTools = value as? [[String: Any]] else { throw Self.invalid("tools", "tools must be an array") }
            for tool in inputTools {
                try Self.keys(tool, ["type", "name", "description", "input_schema", "cache_control"], "tools")
                if let type = tool["type"], type as? String != "custom" { throw Self.invalid("tools.type", "Only custom tools are supported") }
                let name = try Self.nonempty(tool["name"], "tools.name")
                guard names.insert(name).inserted else { throw Self.invalid("tools.name", "Tool names must be unique") }
                var function: [String: Any] = ["name": name, "parameters": ["type": "object"]]
                if let description = tool["description"] { guard description is String else { throw Self.invalid("tools.description", "description must be a string") }; function["description"] = description }
                if let schema = tool["input_schema"], !(schema is NSNull) { guard schema is [String: Any] else { throw Self.invalid("tools.input_schema", "input_schema must be an object") }; function["parameters"] = schema }
                tools.append(["type": "function", "function": function])
            }
        }
        if !tools.isEmpty { chat["tools"] = tools }
        if let value = request["tool_choice"], !(value is NSNull) {
            guard let choice = value as? [String: Any] else { throw Self.invalid("tool_choice", "tool_choice must be an object") }
            try Self.keys(choice, ["type", "name", "disable_parallel_tool_use"], "tool_choice")
            if let value = choice["disable_parallel_tool_use"] { guard Self.isBool(value) else { throw Self.invalid("tool_choice", "disable_parallel_tool_use must be a boolean") }; chat["parallel_tool_calls"] = !(value as! Bool) }
            if let name = choice["name"], !(name is String) { throw Self.invalid("tool_choice.name", "name must be a string") }
            if let type = choice["type"], !(type is String) { throw Self.invalid("tool_choice.type", "type must be a string") }
            switch choice["type"] as? String ?? "auto" {
            case "", "auto": chat["tool_choice"] = "auto"
            case "none": chat["tool_choice"] = "none"
            case "any": guard !tools.isEmpty else { throw Self.invalid("tool_choice", "tool_choice requires tools", code: "invalid_tools") }; chat["tool_choice"] = "required"
            case "tool":
                let name = try Self.nonempty(choice["name"], "tool_choice.name")
                guard names.contains(name) else { throw Self.invalid("tool_choice", "tool_choice references unavailable function", code: "invalid_tools") }
                chat["tool_choice"] = ["type": "function", "function": ["name": name]]
            default: throw Self.invalid("tool_choice", "Unsupported tool choice")
            }
        }
        chatRequestBody = try JSONSerialization.data(withJSONObject: chat)
    }

    static func translateError(_ body: Data) -> Data {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let raw = object?["error"] as? [String: Any] ?? [:]
        var error = raw
        let code = raw["code"] as? String ?? "internal_error"
        let type: String
        switch code {
        case "local_preempted", "overloaded", "provider_busy", "queue_full": type = "overloaded_error"
        case "unauthorized", "invalid_api_key": type = "authentication_error"
        default:
            switch raw["type"] as? String {
            case "invalid_request_error": type = "invalid_request_error"
            case "authentication_error": type = "authentication_error"
            case "permission_error": type = "permission_error"
            case "rate_limit_error": type = "rate_limit_error"
            case "not_found_error": type = "not_found_error"
            default: type = "api_error"
            }
        }
        error["type"] = type; error["code"] = code
        error["message"] = raw["message"] as? String ?? "Inference engine error"
        return (try? JSONSerialization.data(withJSONObject: ["type": "error", "error": error])) ?? Data()
    }
    private func providerError(_ message: String) -> LocalAnthropicMessagesError {
        Self.invalid("", message, code: "invalid_provider_response")
    }
    private func usageMap(_ raw: [String: Any]) throws -> [String: Any] {
        var result: [String: Any] = [:]
        for (source, target) in [("prompt_tokens", "input_tokens"), ("completion_tokens", "output_tokens")] {
            if let value = raw[source] {
                guard let number = Self.number(value, integer: true), number.doubleValue >= 0 else { throw providerError("Invalid usage count") }; result[target] = number
            } else { result[target] = 0 }
        }
        return result
    }
    private func tool(_ raw: [String: Any]) throws -> [String: Any] {
        guard raw["type"] == nil || raw["type"] as? String == "function", let function = raw["function"] as? [String: Any],
              let name = function["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let callID = raw["id"] as? String, !callID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let args = function["arguments"] as? String else { throw providerError("Incomplete tool call") }
        let input = try Self.object(Data((args.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{}" : args).utf8))
        return ["type": "tool_use", "id": callID, "name": name, "input": input]
    }
    private func stopReason(_ reason: String, hasTools: Bool) throws -> String {
        guard ["stop", "length", "tool_calls", "content_filter", "stop_sequence"].contains(reason), reason != "tool_calls" || hasTools else { throw providerError("Missing or invalid finish reason") }
        if reason == "length" { return "max_tokens" }
        if reason == "tool_calls" || hasTools { return "tool_use" }
        if reason == "stop_sequence" { return "stop_sequence" }
        if reason == "content_filter" { return "refusal" }
        return "end_turn"
    }
    private func trimStop(_ text: String, reason: String, sequence: String?) -> (String, String?) {
        if ["stop", "stop_sequence"].contains(reason), let sequence, !sequence.isEmpty {
            // Native inference already removes matched request stops. Metadata
            // distinguishes that case from a natural EOS with identical text.
            return (text.hasSuffix(sequence) ? String(text.dropLast(sequence.count)) : text, sequence)
        }
        if reason == "stop", let sequence = stopSequences.first(where: { text.hasSuffix($0) }) { return (String(text.dropLast(sequence.count)), sequence) }
        return (text, reason == "stop_sequence" ? sequence : nil)
    }
    private func stripThink(_ text: String) -> String {
        text.replacingOccurrences(of: "(?s)<think>.*?(?:</think>|$)", with: "", options: .regularExpression)
    }
    private func message(_ content: [[String: Any]], reason: Any, sequence: Any, usage: [String: Any]) -> [String: Any] {
        ["id": id, "type": "message", "role": "assistant", "model": model, "content": content, "stop_reason": reason, "stop_sequence": sequence, "usage": usage]
    }
    func translateResponse(_ body: Data) throws -> Data {
        let chat = try Self.object(body)
        if chat["error"] != nil { return Self.translateError(body) }
        guard let choices = chat["choices"] as? [[String: Any]], choices.count == 1, let choice = choices.first,
              let response = choice["message"] as? [String: Any], let reason = choice["finish_reason"] as? String else { throw providerError("Malformed chat completion") }
        var content: [[String: Any]] = []
        if thinkingRequested, let reasoning = response["reasoning_content"] as? String, !reasoning.isEmpty { content.append(["type": "thinking", "thinking": reasoning, "signature": ""]) }
        let rawText = try Self.text(response["content"], optional: true)
        let (visible, sequence) = trimStop(stripThink(rawText), reason: reason, sequence: choice["stop_sequence"] as? String)
        if !visible.isEmpty { content.append(["type": "text", "text": visible]) }
        if let value = response["tool_calls"], !(value is [[String: Any]]) { throw providerError("Malformed tool calls") }
        var seen = Set<String>()
        for call in response["tool_calls"] as? [[String: Any]] ?? [] {
            let block = try tool(call)
            guard seen.insert(block["id"] as! String).inserted else { throw providerError("Duplicate tool call id") }
            content.append(block)
        }
        var stop = try stopReason(reason, hasTools: !seen.isEmpty)
        if sequence != nil { stop = "stop_sequence" }
        if let refusal = response["refusal"] as? String, !refusal.isEmpty { if content.isEmpty { content.append(["type": "text", "text": refusal]) }; stop = "refusal" }
        return try JSONSerialization.data(withJSONObject: message(content, reason: stop, sequence: sequence as Any? ?? NSNull(), usage: try usageMap(chat["usage"] as? [String: Any] ?? [:])))
    }
    private func event(_ name: String, _ fields: [String: Any]) -> String {
        var fields = fields; fields["type"] = name
        let data = try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        return "event: \(name)\ndata: \(String(decoding: data, as: UTF8.self))\n\n"
    }
    func startStream() -> [String] {
        guard !started else { return [] }; started = true
        return [event("message_start", ["message": message([], reason: NSNull(), sequence: NSNull(), usage: ["input_tokens": 0, "output_tokens": 0])])]
    }
    private func closeBlock() -> [String] {
        guard let block = openBlock else { return [] }; openBlock = nil
        var frames: [String] = []
        if block.type == "thinking" { frames.append(event("content_block_delta", ["index": block.index, "delta": ["type": "signature_delta", "signature": ""]])) }
        frames.append(event("content_block_stop", ["index": block.index])); return frames
    }
    private func append(_ text: String, thinking: Bool = false) -> [String] {
        guard !text.isEmpty, !terminal, !thinking || thinkingRequested else { return [] }
        let type = thinking ? "thinking" : "text"
        var frames: [String] = []
        if openBlock?.type != type {
            frames += closeBlock()
            openBlock = (nextIndex, type); nextIndex += 1
            var block: [String: Any] = ["type": type, type: ""]
            if thinking { block["signature"] = "" }
            frames.append(event("content_block_start", ["index": openBlock!.index, "content_block": block]))
        }
        frames.append(event("content_block_delta", ["index": openBlock!.index, "delta": ["type": thinking ? "thinking_delta" : "text_delta", type: text]]))
        return frames
    }
    private func filterThink(_ fragment: String, final: Bool = false) -> String {
        thinkBuffer += fragment
        var visible = ""
        while !thinkBuffer.isEmpty {
            let delimiter = insideThink ? "</think>" : "<think>"
            if let range = thinkBuffer.range(of: delimiter) {
                if !insideThink { visible += thinkBuffer[..<range.lowerBound] }
                thinkBuffer.removeSubrange(..<range.upperBound); insideThink.toggle(); continue
            }
            var held = 0
            if !final { for length in 1..<delimiter.count where thinkBuffer.hasSuffix(String(delimiter.prefix(length))) { held = length } }
            if !insideThink { visible += thinkBuffer.dropLast(held) }
            thinkBuffer = String(thinkBuffer.suffix(held)); break
        }
        return visible
    }
    private func appendVisible(_ text: String, final: Bool = false) -> [String] {
        textTail += text
        if final {
            let result = trimStop(textTail, reason: finishReason ?? "", sequence: stopSequence)
            textTail = ""; stopSequence = result.1
            return append(result.0)
        }
        // Preserve the longest possible stop-sequence suffix across writes.
        let held = max(stopSequences.map(\.count).max() ?? 0, stopSequence?.count ?? 0)
        guard textTail.count > held else { return [] }
        let visible = String(textTail.dropLast(held)); textTail = String(textTail.suffix(held))
        return append(visible)
    }
    func consumeStream(_ bytes: String) -> [String] {
        guard !terminal else { return [] }
        var frames = startStream(); lineBuffer += bytes
        while let newline = lineBuffer.firstIndex(of: "\n"), !terminal {
            let line = String(lineBuffer[..<newline]).trimmingCharacters(in: .newlines); lineBuffer.removeSubrange(...newline)
            guard line.hasPrefix("data:") else { continue }
            let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { frames += complete(); continue }
            do {
                let chunk = try Self.object(Data(payload.utf8))
                if let error = chunk["error"] as? [String: Any] { frames += fail(error); continue }
                if let rawUsage = chunk["usage"] as? [String: Any] { usage = try usageMap(rawUsage) }
                guard let choices = chunk["choices"] as? [[String: Any]], choices.count <= 1 else { throw providerError("Malformed chat stream choices") }
                guard let choice = choices.first else {
                    guard chunk["usage"] is [String: Any] else { throw providerError("Stream has neither choices nor usage") }; continue
                }
                if let reason = choice["finish_reason"], !(reason is NSNull) {
                    guard let reason = reason as? String, finishReason == nil || finishReason == reason else { throw providerError("Invalid or changed finish reason") }
                }
                if let sequence = choice["stop_sequence"], !(sequence is NSNull) { guard let sequence = sequence as? String else { throw providerError("Invalid stop sequence") }; stopSequence = sequence }
                guard let delta = choice["delta"] as? [String: Any] else { throw providerError("Malformed chat stream delta") }
                guard delta["function_call"] == nil, finishReason == nil || delta.isEmpty else { throw providerError("Unsupported or post-terminal stream content") }
                for field in ["content", "reasoning_content", "refusal"] { if let value = delta[field], !(value is NSNull), !(value is String) { throw providerError("Invalid stream text") } }
                if let reasoning = delta["reasoning_content"] as? String { frames += append(reasoning, thinking: true) }
                if let text = delta["content"] as? String { frames += appendVisible(filterThink(text)) }
                if let text = delta["refusal"] as? String, !text.isEmpty { refusal = true; frames += appendVisible(text) }
                if let value = delta["tool_calls"], !(value is [[String: Any]]) { throw providerError("Malformed tool delta") }
                for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
                    guard let number = Self.number(call["index"], integer: true), number.doubleValue >= 0, number.doubleValue <= Double(Int.max), let function = call["function"] as? [String: Any] else { throw providerError("Malformed tool delta") }
                    let index = number.intValue
                    if toolCalls[index] == nil { toolCalls[index] = ["type": "function", "function": ["name": "", "arguments": ""]]; toolOrder.append(index) }
                    var stored = toolCalls[index]!, storedFunction = stored["function"] as! [String: Any]
                    if let type = call["type"], type as? String != "function" { throw providerError("Unsupported tool delta type") }
                    if let callID = call["id"] { guard let callID = callID as? String else { throw providerError("Invalid tool id") }; if let previous = stored["id"] as? String, previous != callID { throw providerError("Tool id changed") }; stored["id"] = callID }
                    for field in ["name", "arguments"] {
                        if let value = function[field] {
                            guard let text = value as? String else { throw providerError("Invalid tool function delta") }
                            if field == "name", !text.isEmpty {
                                let previous = storedFunction[field] as? String ?? ""
                                guard previous.isEmpty || previous == text else { throw providerError("Tool name changed") }
                                storedFunction[field] = text
                            } else if field == "arguments" { storedFunction[field] = (storedFunction[field] as? String ?? "") + text }
                        }
                    }
                    stored["function"] = storedFunction; toolCalls[index] = stored
                }
                if let reason = choice["finish_reason"] as? String {
                    _ = try stopReason(reason, hasTools: !toolCalls.isEmpty)
                    finishReason = reason
                }
            } catch { frames += fail(["type": "api_error", "code": "invalid_provider_response", "message": "Invalid chat stream response", "retryable": true]) }
        }
        return frames
    }
    private func complete() -> [String] {
        guard !terminal else { return [] }
        do {
            guard let reason = finishReason else { throw providerError("Stream ended without finish reason") }
            var stop = try stopReason(reason, hasTools: !toolOrder.isEmpty)
            var tools: [[String: Any]] = [], seen = Set<String>()
            // Validate the entire tool response before exposing executable input.
            for index in toolOrder {
                let block = try tool(toolCalls[index]!)
                guard seen.insert(block["id"] as! String).inserted else { throw providerError("Duplicate tool id") }
                tools.append(block)
            }
            var frames = appendVisible(filterThink("", final: true), final: true)
            if stopSequence != nil { stop = "stop_sequence" }
            if refusal { stop = "refusal" }
            frames += closeBlock()
            for block in tools {
                let index = nextIndex; nextIndex += 1
                var start = block; start["input"] = [String: Any]()
                frames.append(event("content_block_start", ["index": index, "content_block": start]))
                let arguments = String(decoding: try JSONSerialization.data(withJSONObject: block["input"]!, options: [.sortedKeys]), as: UTF8.self)
                frames.append(event("content_block_delta", ["index": index, "delta": ["type": "input_json_delta", "partial_json": arguments]]))
                frames.append(event("content_block_stop", ["index": index]))
            }
            frames.append(event("message_delta", ["delta": ["stop_reason": stop, "stop_sequence": stopSequence as Any? ?? NSNull()], "usage": usage]))
            frames.append(event("message_stop", [:])); terminal = true
            return frames
        } catch { return fail(["type": "api_error", "code": "invalid_provider_response", "message": "Incomplete or invalid chat stream response", "retryable": true]) }
    }
    private func fail(_ error: [String: Any]) -> [String] {
        guard !terminal else { return [] }
        if let code = error["code"] as? String, ["stream_output_exceeded", "response_byte_cap_exceeded"].contains(code) { finishReason = "length"; return complete() }
        let raw = (try? JSONSerialization.data(withJSONObject: ["error": error])) ?? Data()
        let translated = (try? JSONSerialization.jsonObject(with: Self.translateError(raw))) as? [String: Any] ?? [:]
        var frames = closeBlock()
        frames.append(event("error", ["error": translated["error"] ?? ["type": "api_error", "message": "Inference engine error"]])); terminal = true
        return frames
    }
    /// A disconnected upstream cannot be reported as a successful assistant turn.
    func finishStream() -> [String] {
        guard !terminal else { return [] }
        var frames = startStream()
        if !lineBuffer.isEmpty { frames += consumeStream("\n") }
        if !terminal { frames += fail(["type": "api_error", "code": "stream_incomplete", "message": "Chat stream ended before its terminal marker", "retryable": true]) }
        return frames
    }
}

// ResponseWriter confines every mutable access to its channel event loop.
extension LocalAnthropicMessagesAdapter: @unchecked Sendable {}
