import Foundation
import CoreFoundation
import MacProviderCore

/// The local stateless Responses facade shares the chat inference pipeline.
/// This adapter owns only wire translation; it never loads or invokes a model.
struct LocalResponsesError: Error {
    let code: String
    let param: String
    let message: String
    var errorBody: Data {
        (try? JSONSerialization.data(withJSONObject: ["error": ["type": "invalid_request_error", "code": code, "param": param, "message": message]])) ?? Data()
    }
}

final class LocalResponsesAdapter {
    private(set) var chatRequestBody: Data
    let stream: Bool
    private let request: [String: Any]
    private let tools: [[String: Any]]
    private let format: [String: Any]
    private let customToolNames: Set<String>
    private var announcedTools = Set<Int>()
    private var reasoningText = ""
    private var reasoningIndex: Int?
    private var reasoningClosed = false
    private let id = "resp_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private let created = Int(Date().timeIntervalSince1970)
    private var sequence = 1
    private var started = false
    private var terminal = false
    private var lineBuffer = ""
    private var text = ""
    private var textIndex: Int?
    private var output: [[String: Any]] = []
    private var toolIndices: [Int: Int] = [:]
    private var finishReason: String?
    private var usage: [String: Any]?
    private var thinkBuffer = ""
    private var thinking = false

    init(body: Data) throws {
        func invalid(_ param: String, _ message: String, _ code: String = "invalid_request") -> LocalResponsesError {
            LocalResponsesError(code: code, param: param, message: message)
        }
        guard let raw = String(data: body, encoding: .utf8), (try? StrictJSONParser.parse(raw, maxDepth: 32)) != nil else {
            throw invalid("", "Malformed JSON, duplicate keys, or excessive nesting")
        }
        guard let req = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw invalid("", "Request must be a JSON object")
        }
        let allowed: Set<String> = ["model", "input", "instructions", "tools", "tool_choice", "max_output_tokens", "stream", "previous_response_id", "store", "temperature", "top_p", "text", "metadata", "user", "reasoning", "parallel_tool_calls", "conversation", "include", "truncation", "background"]
        for key in req.keys where !allowed.contains(key) {
            throw invalid(key, "Unsupported parameter: \(key)", "unsupported_parameter")
        }
        guard let model = req["model"] as? String, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw invalid("model", "model is required")
        }
        if let metadata = req["metadata"], !(metadata is NSNull), !(metadata is [String: Any]) {
            throw invalid("metadata", "metadata must be an object or null")
        }
        for field in ["stream", "store", "background", "parallel_tool_calls"] {
            if let value = req[field], !(value is NSNull), !Self.isBoolean(value) { throw invalid(field, "\(field) must be a boolean") }
        }
        for field in ["instructions", "previous_response_id", "truncation", "user"] {
            if let value = req[field], !(value is NSNull), !(value is String) { throw invalid(field, "\(field) must be a string") }
        }
        for field in ["temperature", "top_p", "max_output_tokens"] {
            if let value = req[field], !(value is NSNull) {
                guard let number = value as? NSNumber, !Self.isBoolean(value), number.doubleValue.isFinite else { throw invalid(field, "\(field) must be numeric") }
                if field == "max_output_tokens", number.doubleValue < 1 || number.doubleValue.rounded() != number.doubleValue { throw invalid(field, "max_output_tokens must be a positive integer") }
            }
        }
        if req["store"] as? Bool == true { throw invalid("store", "store:true is not supported; send full input with store:false", "unsupported_parameter") }
        if let previous = req["previous_response_id"] as? String, !previous.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw invalid("previous_response_id", "previous_response_id is not supported; send full input", "unsupported_parameter") }
        if let conversation = req["conversation"], !(conversation is NSNull) { throw invalid("conversation", "conversation is not supported", "unsupported_parameter") }
        if req["background"] as? Bool == true { throw invalid("background", "background:true is not supported", "unsupported_parameter") }
        if let truncation = req["truncation"] as? String, truncation != "disabled" { throw invalid("truncation", "Only truncation:disabled is supported", "unsupported_parameter") }
        if let include = req["include"], !(include is NSNull) {
            guard let values = include as? [String], values.allSatisfy({ $0 == "reasoning.encrypted_content" }) else { throw invalid("include", "Unsupported include field", "unsupported_parameter") }
        }
        var reasoningEffort: String?
        if let value = req["reasoning"], !(value is NSNull) {
            guard let reasoning = value as? [String: Any], Set(reasoning.keys).isSubset(of: ["effort", "summary"]) else { throw invalid("reasoning", "Unsupported reasoning controls", "unsupported_parameter") }
            if let effort = reasoning["effort"], !(effort is NSNull) {
                guard let effort = effort as? String, ["none", "minimal", "low", "medium", "high", "xhigh"].contains(effort) else { throw invalid("reasoning.effort", "Unsupported reasoning effort", "unsupported_parameter") }
                reasoningEffort = effort
            }
            if let summary = reasoning["summary"], !(summary is NSNull) {
                guard let summary = summary as? String, ["auto", "concise", "detailed"].contains(summary) else { throw invalid("reasoning.summary", "Unsupported reasoning summary", "unsupported_parameter") }
            }
        }
        var messages: [[String: Any]] = []
        if let instructions = req["instructions"] as? String, !instructions.isEmpty { messages.append(["role": "system", "content": instructions]) }
        if let input = req["input"] as? String, !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append(["role": "user", "content": input])
        } else if let items = req["input"] as? [[String: Any]], !items.isEmpty {
            var pendingReasoning: [String] = []
            for item in items {
                for field in ["type", "role"] {
                    if let value = item[field], !(value is String) { throw invalid("input", "Input item \(field) must be a string") }
                }
                let type = item["type"] as? String ?? "message"
                let itemFields: Set<String>
                switch type {
                case "message": itemFields = ["type", "id", "status", "role", "content"]
                case "function_call": itemFields = ["type", "id", "status", "call_id", "name", "arguments"]
                case "custom_tool_call": itemFields = ["type", "id", "status", "call_id", "name", "input"]
                case "reasoning": itemFields = ["type", "id", "status", "summary", "content", "encrypted_content"]
                default: itemFields = ["type", "id", "status", "call_id", "output"]
                }
                guard Set(item.keys).isSubset(of: itemFields) else { throw invalid("input", "Unsupported input item field", "unsupported_parameter") }
                if type == "reasoning" {
                    let text = try Self.reasoningHistoryText(item)
                    if !text.isEmpty { pendingReasoning.append(text) }
                    continue
                }
                switch type {
                case "message":
                    let role = item["role"] as? String ?? "user"
                    guard ["system", "developer", "user", "assistant"].contains(role) else { throw invalid("input", "Unsupported message role") }
                    messages.append(["role": role == "developer" ? "system" : role, "content": try Self.content(item["content"])])
                case "function_call_output", "function_call", "custom_tool_call", "custom_tool_call_output":
                    guard let callID = (item["call_id"] ?? item["id"]) as? String, !callID.isEmpty else { throw invalid("input", "Function items require call_id") }
                    if type == "function_call_output" || type == "custom_tool_call_output" {
                        messages.append(["role": "tool", "tool_call_id": callID, "content": try Self.content(item["output"])])
                    } else {
                        guard let name = item["name"] as? String, !name.isEmpty, let argumentsValue = item[type == "custom_tool_call" ? "input" : "arguments"] as? String else { throw invalid("input", "Tool calls require name and arguments or input") }
                        let arguments = type == "custom_tool_call" ? String(decoding: try JSONSerialization.data(withJSONObject: ["input": argumentsValue]), as: UTF8.self) : argumentsValue
                        messages.append(["role": "assistant", "content": NSNull(), "tool_calls": [["id": callID, "type": "function", "function": ["name": name, "arguments": arguments]]]])
                    }
                default: throw invalid("input", "Unsupported input item: \(type)", "unsupported_parameter")
                }
                if messages.last?["role"] as? String == "assistant", !pendingReasoning.isEmpty {
                    messages[messages.count - 1]["reasoning_content"] = pendingReasoning.joined(separator: "\n")
                }
                pendingReasoning.removeAll()
            }
        } else { throw invalid("input", "input must be a nonempty string or message array") }
        guard messages.count > ((req["instructions"] as? String).map { $0.isEmpty ? 0 : 1 } ?? 0) else { throw invalid("input", "input produced no chat messages") }
        var flatTools: [[String: Any]] = []
        if let value = req["tools"], !(value is NSNull) {
            guard let inputTools = value as? [[String: Any]] else { throw invalid("tools", "tools must be an array") }
            flatTools = try Self.flattenTools(inputTools)
        }
        var names = Set<String>()
        var customNames = Set<String>()
        var chatTools: [[String: Any]] = []
        for tool in flatTools {
            let type = tool["type"] as? String ?? ""
            if !["function", "custom"].contains(type) {
                guard type != "local_shell", Self.isHostedToolType(type) else { throw invalid("tools", "Unsupported tool type: \(type)", "unsupported_tool_type") }
                // Hosted tools execute upstream; the buyer discloses their omission.
                continue
            }
            let fields: Set<String> = type == "custom" ? ["type", "name", "description", "format"] : ["type", "name", "description", "parameters", "strict"]
            guard Set(tool.keys).isSubset(of: fields) else { throw invalid("tools", "Unsupported tool field", "unsupported_parameter") }
            guard let name = tool["name"] as? String, !name.isEmpty, names.insert(name).inserted else { throw invalid("tools", "Tools require unique names", "unsupported_parameter") }
            var fn = tool; fn.removeValue(forKey: "type")
            if type == "custom" {
                customNames.insert(name)
                var description = tool["description"] as? String ?? ""
                if let value = tool["format"], !(value is NSNull) {
                    guard let format = value as? [String: Any], let formatType = format["type"] as? String else { throw invalid("tools", "Custom format requires a type") }
                    if formatType == "grammar" {
                        guard Set(format.keys).isSubset(of: ["type", "syntax", "definition"]), let syntax = format["syntax"] as? String, ["lark", "regex"].contains(syntax), let definition = format["definition"] as? String else { throw invalid("tools", "Malformed custom grammar") }
                        // Match the gateway's bounded grammar hint; this is not grammar enforcement.
                        let grammar = String(decoding: definition.utf8.prefix(16 * 1024), as: UTF8.self)
                        description = (description + "\n\nThe input must follow this " + syntax + " grammar:\n" + grammar).trimmingCharacters(in: .whitespacesAndNewlines)
                    } else if formatType != "text" || Set(format.keys) != ["type"] { throw invalid("tools", "Unsupported custom format", "unsupported_parameter") }
                }
                fn = ["name": name, "description": description, "parameters": ["type": "object", "properties": ["input": ["type": "string", "description": "The raw tool input."]], "required": ["input"], "additionalProperties": false]]
            }
            chatTools.append(["type": "function", "function": fn])
        }
        var chat: [String: Any] = ["model": model, "messages": messages, "stream": req["stream"] as? Bool ?? false]
        if let reasoningEffort { chat["reasoning_effort"] = reasoningEffort }
        if !chatTools.isEmpty { chat["tools"] = chatTools }
        if let choice = req["tool_choice"], !(choice is NSNull) {
            if let choice = choice as? String, ["auto", "none", "required"].contains(choice), choice != "required" || !chatTools.isEmpty { chat["tool_choice"] = choice }
            else if let choice = choice as? [String: Any], Set(choice.keys).isSubset(of: ["type", "name"]), ["function", "custom"].contains(choice["type"] as? String ?? ""), let name = choice["name"] as? String, names.contains(name) { chat["tool_choice"] = ["type": "function", "function": ["name": name]] }
            else { throw invalid("tool_choice", "Unsupported or unavailable function selection", "unsupported_parameter") }
        }
        var textFormat: [String: Any] = ["type": "text"]
        if let value = req["text"], !(value is NSNull) {
            guard let config = value as? [String: Any], Set(config.keys).isSubset(of: ["format"]) else { throw invalid("text", "Only text.format is supported") }
            if let value = config["format"], !(value is NSNull) {
                guard let fmt = value as? [String: Any], let type = fmt["type"] as? String else { throw invalid("text.format", "text.format must have a type") }
                let fields: Set<String> = type == "json_schema" ? ["type", "name", "description", "schema", "strict"] : ["type"]
                guard Set(fmt.keys).isSubset(of: fields) else { throw invalid("text.format", "Unsupported text format field", "unsupported_parameter") }
                textFormat = fmt
                switch type {
                case "text": break
                case "json_object": chat["response_format"] = ["type": type]
                case "json_schema":
                    guard let name = fmt["name"] as? String, !name.isEmpty, fmt["schema"] is [String: Any] else { throw invalid("text.format", "json_schema requires name and schema") }
                    var schema = fmt; schema.removeValue(forKey: "type")
                    chat["response_format"] = ["type": type, "json_schema": schema]
                default: throw invalid("text.format.type", "Unsupported text format", "unsupported_parameter")
                }
            }
        }
        for field in ["temperature", "top_p", "user", "parallel_tool_calls"] { if let value = req[field], !(value is NSNull) { chat[field] = value } }
        if let value = req["max_output_tokens"], !(value is NSNull) { chat["max_tokens"] = value }
        request = req; tools = chatTools.map { var fn = $0["function"] as! [String: Any]; fn["type"] = "function"; return fn }; format = textFormat; customToolNames = customNames
        stream = req["stream"] as? Bool ?? false
        chatRequestBody = try JSONSerialization.data(withJSONObject: chat)
    }

    private static func flattenTools(_ tools: [[String: Any]]) throws -> [[String: Any]] {
        var result: [[String: Any]] = []
        for tool in tools {
            if tool["type"] as? String == "namespace" {
                guard Set(tool.keys).isSubset(of: ["type", "name", "description", "tools"]), let nested = tool["tools"] as? [[String: Any]] else { throw LocalResponsesError(code: "invalid_request", param: "tools", message: "namespace tools must be an array") }
                result += try flattenTools(nested)
            } else { result.append(tool) }
        }
        return result
    }
    private static func isHostedToolType(_ type: String) -> Bool {
        !type.isEmpty && type.utf8.count <= 64 && type.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45 }
    }
    /// Only metadata for the buyer's local disclosure header. Never rewrites input.
    static func unservedToolTypes(in originalBody: Data) -> [String] {
        guard let req = (try? JSONSerialization.jsonObject(with: originalBody)) as? [String: Any],
              let tools = req["tools"] as? [[String: Any]], let flattened = try? flattenTools(tools) else { return [] }
        return Set(flattened.compactMap { tool -> String? in
            guard let type = tool["type"] as? String, !["function", "custom", "local_shell"].contains(type), isHostedToolType(type) else { return nil }
            return type
        }).sorted()
    }

    /// Privacy relay parsing releases the translated byte buffer before inference.
    /// Parsed immutable Swift strings retain the disclosed zeroization limitation.
    func clearTranslatedRequestBody() {
        chatRequestBody.resetBytes(in: 0..<chatRequestBody.count)
        chatRequestBody.removeAll(keepingCapacity: false)
    }

    private static func isBoolean(_ value: Any) -> Bool { (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false }
    private static func content(_ value: Any?) throws -> String {
        if let value = value as? String { return value }
        if value == nil || value is NSNull { return "" }
        guard let parts = value as? [[String: Any]] else { throw LocalResponsesError(code: "invalid_request", param: "input", message: "Only text content is supported") }
        return try parts.map { part in
            guard Set(part.keys).isSubset(of: ["type", "text", "annotations"]), let type = part["type"] as? String, ["input_text", "output_text", "text"].contains(type), part["image_url"] == nil, let text = part["text"] as? String else { throw LocalResponsesError(code: "invalid_request", param: "input", message: "Only text content is supported") }
            return text
        }.joined()
    }

    /// Opaque upstream encrypted reasoning is accepted as history but never decoded.
    private static func reasoningHistoryText(_ item: [String: Any]) throws -> String {
        if let encrypted = item["encrypted_content"], !(encrypted is NSNull), !(encrypted is String) { throw LocalResponsesError(code: "invalid_request", param: "input", message: "encrypted_content must be a string") }
        func collect(_ field: String, types: Set<String>) throws -> String {
            guard let value = item[field], !(value is NSNull) else { return "" }
            guard let parts = value as? [[String: Any]] else { throw LocalResponsesError(code: "invalid_request", param: "input", message: "Reasoning parts must be an array") }
            return try parts.map { part in
                guard Set(part.keys).isSubset(of: ["type", "text"]), let type = part["type"] as? String, types.contains(type), let text = part["text"] as? String else { throw LocalResponsesError(code: "invalid_request", param: "input", message: "Unsupported reasoning part") }
                return text
            }.joined(separator: "\n")
        }
        let content = try collect("content", types: ["reasoning_text", "text"])
        let summary = try collect("summary", types: ["summary_text"])
        return content.isEmpty ? summary : content
    }
    private func reasoningItem(_ text: String) -> [String: Any] {
        ["id": "rs_" + id, "type": "reasoning", "summary": [] as [Any], "content": [["type": "reasoning_text", "text": text]]]
    }
    private func toolItem(callID: String, name: String, arguments: String) -> [String: Any] {
        if customToolNames.contains(name) {
            let object = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any]
            return ["id": "ctc_" + callID, "type": "custom_tool_call", "call_id": callID, "name": name, "input": object?["input"] as? String ?? arguments, "status": "completed"]
        }
        return ["id": "fc_" + callID, "type": "function_call", "call_id": callID, "name": name, "arguments": arguments, "status": "completed"]
    }

    private func response(status: String, items: [[String: Any]], usage: [String: Any]? = nil) -> [String: Any] {
        ["id": id, "object": "response", "created_at": created, "status": status, "error": NSNull(), "incomplete_details": NSNull(), "model": request["model"]!, "output": items, "store": false, "previous_response_id": NSNull(), "instructions": request["instructions"] ?? NSNull(), "max_output_tokens": request["max_output_tokens"] ?? NSNull(), "parallel_tool_calls": request["parallel_tool_calls"] ?? true, "text": ["format": format], "tool_choice": request["tool_choice"] ?? "auto", "tools": tools, "truncation": "disabled", "usage": usage ?? NSNull() as Any, "metadata": request["metadata"] ?? [:], "temperature": request["temperature"] ?? NSNull(), "top_p": request["top_p"] ?? NSNull(), "user": request["user"] ?? NSNull(), "reasoning": ["effort": NSNull(), "summary": NSNull()]]
    }
    private func usageMap(_ chat: [String: Any]) -> [String: Any] {
        let input = chat["prompt_tokens"] as? Int ?? 0, output = chat["completion_tokens"] as? Int ?? 0
        let details = chat["prompt_tokens_details"] as? [String: Any]
        return ["input_tokens": input, "output_tokens": output, "total_tokens": chat["total_tokens"] as? Int ?? input + output, "input_tokens_details": ["cached_tokens": max(chat["cached_prompt_tokens"] as? Int ?? 0, details?["cached_tokens"] as? Int ?? 0), "cache_write_tokens": 0], "output_tokens_details": ["reasoning_tokens": min(max((chat["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int ?? 0, 0), max(output, 0))]]
    }
    private func message(_ value: String, status: String = "completed") -> [String: Any] {
        ["id": "msg_" + id, "type": "message", "role": "assistant", "status": status, "content": [["type": "output_text", "text": value, "annotations": [] as [Any]]]]
    }
    private func terminalResponse(items: [[String: Any]], reason: String, usage: [String: Any]?) -> [String: Any] {
        let incomplete = reason == "length" || reason == "content_filter"
        var result = response(status: incomplete ? "incomplete" : "completed", items: items, usage: usage)
        if incomplete { result["incomplete_details"] = ["reason": reason == "length" ? "max_output_tokens" : "content_filter"] }
        return result
    }
    func translateResponse(_ body: Data) throws -> Data {
        guard let chat = try JSONSerialization.jsonObject(with: body) as? [String: Any], let choice = (chat["choices"] as? [[String: Any]])?.first, let msg = choice["message"] as? [String: Any], let reason = choice["finish_reason"] as? String else { throw LocalResponsesError(code: "provider_error", param: "", message: "Malformed chat completion") }
        guard ["stop", "tool_calls", "function_call", "length", "content_filter"].contains(reason) else { throw LocalResponsesError(code: "provider_error", param: "", message: "Unsupported chat finish reason") }
        var items: [[String: Any]] = []
        if let reasoning = msg["reasoning_content"] as? String, !reasoning.isEmpty { items.append(reasoningItem(reasoning)) }
        let content = try Self.content(msg["content"])
        let clean = content.replacingOccurrences(of: "(?s)<think>.*?(?:</think>|$)", with: "", options: .regularExpression) + (msg["refusal"] as? String ?? "")
        if !clean.isEmpty { items.append(message(clean)) }
        for call in msg["tool_calls"] as? [[String: Any]] ?? [] {
            guard let fn = call["function"] as? [String: Any], let name = fn["name"] as? String, let args = fn["arguments"] as? String else { throw LocalResponsesError(code: "provider_error", param: "", message: "Malformed function call") }
            let callID = call["id"] as? String ?? "call_\(id)_\(items.count)"
            items.append(toolItem(callID: callID, name: name, arguments: args))
        }
        return try JSONSerialization.data(withJSONObject: terminalResponse(items: items, reason: reason, usage: (chat["usage"] as? [String: Any]).map(usageMap)))
    }

    private func event(_ name: String, _ fields: [String: Any]) -> String {
        var payload = fields; payload["type"] = name; payload["sequence_number"] = sequence; sequence += 1
        // All payload values originate in parsed JSON or JSON primitives.
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return "event: \(name)\ndata: \(String(decoding: data, as: UTF8.self))\n\n"
    }
    func startStream() -> [String] {
        guard !started else { return [] }; started = true
        return [event("response.created", ["response": response(status: "in_progress", items: [])])]
    }
    func consumeStream(_ bytes: String) -> [String] {
        guard !terminal else { return [] }
        var events = startStream()
        lineBuffer += bytes
        while let newline = lineBuffer.firstIndex(of: "\n"), !terminal {
            let line = String(lineBuffer[..<newline]).trimmingCharacters(in: .newlines)
            lineBuffer.removeSubrange(...newline)
            guard line.hasPrefix("data:") else { continue }
            let data = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if data == "[DONE]" { events += completeStream(); continue }
            guard let chunk = (try? JSONSerialization.jsonObject(with: Data(data.utf8))) as? [String: Any] else { events += failStream(["code": "stream_malformed", "message": "Malformed chat stream", "type": "api_error"]); continue }
            if let error = chunk["error"] as? [String: Any] { events += failStream(error); continue }
            if let rawUsage = chunk["usage"] as? [String: Any] { usage = usageMap(rawUsage) }
            guard let choice = (chunk["choices"] as? [[String: Any]])?.first else { continue }
            if let reason = choice["finish_reason"] as? String { finishReason = reason }
            guard let delta = choice["delta"] as? [String: Any] else { continue }
            if let reasoning = delta["reasoning_content"] as? String { events += appendReasoning(reasoning) }
            if let content = delta["content"] as? String { events += appendText(filterThink(content)) }
            if let refusal = delta["refusal"] as? String { events += appendText(refusal) }
            for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
                guard let index = call["index"] as? Int, index >= 0, let fn = call["function"] as? [String: Any] else { events += failStream(["code": "stream_malformed", "message": "Malformed function delta"]); break }
                events += appendTool(index: index, call: call, function: fn)
            }
        }
        return events
    }
    /// EOF without the chat terminal marker must never become response.completed.
    func finishStream() -> [String] {
        guard !terminal else { return [] }
        var events = startStream()
        if !lineBuffer.isEmpty { events += consumeStream("\n") }
        if !terminal { events += failStream(["code": "stream_incomplete", "message": "Chat stream ended before its terminal marker", "type": "api_error"]) }
        return events
    }
    private func filterThink(_ fragment: String, final: Bool = false) -> String {
        thinkBuffer += fragment
        var visible = ""
        while !thinkBuffer.isEmpty {
            let delimiter = thinking ? "</think>" : "<think>"
            if let range = thinkBuffer.range(of: delimiter) {
                if !thinking { visible += thinkBuffer[..<range.lowerBound] }
                thinkBuffer.removeSubrange(..<range.upperBound); thinking.toggle()
                continue
            }
            var held = 0
            if !final {
                for length in 1..<delimiter.count where thinkBuffer.hasSuffix(String(delimiter.prefix(length))) { held = length }
            }
            if !thinking { visible += thinkBuffer.dropLast(held) }
            thinkBuffer = String(thinkBuffer.suffix(held))
            break
        }
        return visible
    }
    private func appendText(_ delta: String) -> [String] {
        guard !delta.isEmpty, !terminal else { return [] }
        var events = closeReasoning()
        if textIndex == nil {
            textIndex = output.count
            let item: [String: Any] = ["id": "msg_" + id, "type": "message", "role": "assistant", "status": "in_progress", "content": [] as [Any]]
            output.append(item)
            events.append(event("response.output_item.added", ["output_index": textIndex!, "item": item]))
            events.append(event("response.content_part.added", ["item_id": "msg_" + id, "output_index": textIndex!, "content_index": 0, "part": ["type": "output_text", "text": "", "annotations": [] as [Any]]]))
        }
        text += delta
        events.append(event("response.output_text.delta", ["item_id": "msg_" + id, "output_index": textIndex!, "content_index": 0, "delta": delta]))
        return events
    }
    private func appendReasoning(_ delta: String) -> [String] {
        guard !delta.isEmpty, !reasoningClosed else { return [] }
        var events: [String] = []
        if reasoningIndex == nil {
            reasoningIndex = output.count
            let item: [String: Any] = ["id": "rs_" + id, "type": "reasoning", "summary": [] as [Any], "content": [] as [Any]]
            output.append(item)
            events.append(event("response.output_item.added", ["output_index": reasoningIndex!, "item": item]))
            events.append(event("response.content_part.added", ["item_id": "rs_" + id, "output_index": reasoningIndex!, "content_index": 0, "part": ["type": "reasoning_text", "text": ""]]))
        }
        reasoningText += delta
        events.append(event("response.reasoning_text.delta", ["item_id": "rs_" + id, "output_index": reasoningIndex!, "content_index": 0, "delta": delta]))
        return events
    }
    private func closeReasoning() -> [String] {
        guard let index = reasoningIndex, !reasoningClosed else { return [] }
        reasoningClosed = true
        let fields: [String: Any] = ["item_id": "rs_" + id, "output_index": index, "content_index": 0]
        var done = fields; done["text"] = reasoningText
        var part = fields; part["part"] = ["type": "reasoning_text", "text": reasoningText]
        output[index] = reasoningItem(reasoningText)
        return [event("response.reasoning_text.done", done), event("response.content_part.done", part), event("response.output_item.done", ["output_index": index, "item": output[index]])]
    }
    private func appendTool(index: Int, call: [String: Any], function: [String: Any]) -> [String] {
        var events = closeReasoning()
        if toolIndices[index] == nil {
            let callID = call["id"] as? String ?? "call_\(id)_\(index)"
            toolIndices[index] = output.count
            output.append(["id": "fc_" + callID, "type": "function_call", "call_id": callID, "name": "", "arguments": "", "status": "in_progress"])
        }
        let out = toolIndices[index]!
        if let name = function["name"] as? String, !name.isEmpty { output[out]["name"] = name }
        let args = function["arguments"] as? String ?? ""
        output[out]["arguments"] = (output[out]["arguments"] as? String ?? "") + args
        let name = output[out]["name"] as? String ?? ""
        // Custom input is emitted whole, after the fragmented JSON has been joined.
        if !name.isEmpty, !customToolNames.contains(name) {
            let first = announcedTools.insert(out).inserted
            if first {
                var item = output[out]; item["arguments"] = ""
                events.append(event("response.output_item.added", ["output_index": out, "item": item]))
            }
            let delta = first ? output[out]["arguments"] as? String ?? "" : args
            if !delta.isEmpty { events.append(event("response.function_call_arguments.delta", ["item_id": output[out]["id"]!, "output_index": out, "delta": delta])) }
        }
        return events
    }
    private func completeStream() -> [String] {
        guard !terminal else { return [] }
        guard let reason = finishReason, ["stop", "tool_calls", "function_call", "length", "content_filter"].contains(reason) else { return failStream(["code": "stream_incomplete", "message": "Chat stream has no valid finish reason", "type": "api_error"]) }
        var events = appendText(filterThink("", final: true))
        events += closeReasoning()
        for index in output.indices {
            if index == reasoningIndex { continue }
            if index == textIndex {
                let fields: [String: Any] = ["item_id": "msg_" + id, "output_index": index, "content_index": 0]
                var done = fields; done["text"] = text
                events.append(event("response.output_text.done", done))
                let item = message(text)
                var part = fields; part["part"] = (item["content"] as! [[String: Any]])[0]
                events.append(event("response.content_part.done", part))
                output[index] = item
            } else {
                let name = output[index]["name"] as? String ?? ""
                let arguments = output[index]["arguments"] as? String ?? ""
                output[index] = toolItem(callID: output[index]["call_id"] as! String, name: name, arguments: arguments)
                if customToolNames.contains(name) {
                    events.append(event("response.output_item.added", ["output_index": index, "item": output[index]]))
                } else {
                    if announcedTools.insert(index).inserted { events.append(event("response.output_item.added", ["output_index": index, "item": output[index]])) }
                    events.append(event("response.function_call_arguments.done", ["item_id": output[index]["id"]!, "output_index": index, "name": name, "arguments": arguments]))
                }
            }
            events.append(event("response.output_item.done", ["output_index": index, "item": output[index]]))
        }
        let result = terminalResponse(items: output, reason: reason, usage: usage)
        events.append(event(result["status"] as? String == "incomplete" ? "response.incomplete" : "response.completed", ["response": result]))
        events.append("data: [DONE]\n\n"); terminal = true
        return events
    }
    private func failStream(_ error: [String: Any]) -> [String] {
        guard !terminal else { return [] }
        if let code = error["code"] as? String, ["stream_output_exceeded", "response_byte_cap_exceeded"].contains(code) {
            finishReason = "length"
            return completeStream()
        }
        var result = response(status: "failed", items: [], usage: usage)
        result["error"] = error
        terminal = true
        return [event("response.failed", ["response": result]), "data: [DONE]\n\n"]
    }
}

// ResponseWriter confines every mutable access to its channel event loop.
extension LocalResponsesAdapter: @unchecked Sendable {}
