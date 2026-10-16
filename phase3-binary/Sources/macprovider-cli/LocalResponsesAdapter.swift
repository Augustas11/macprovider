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
    let chatRequestBody: Data
    let stream: Bool
    private let request: [String: Any]
    private let tools: [[String: Any]]
    private let format: [String: Any]
    private let id = "resp_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private let created = Int(Date().timeIntervalSince1970)
    private var sequence = 0
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
        if let include = req["include"], !(include is NSNull), (include as? [Any])?.isEmpty != true { throw invalid("include", "include is not supported", "unsupported_parameter") }
        if let reasoning = req["reasoning"], !(reasoning is NSNull), (reasoning as? [String: Any])?.isEmpty != true { throw invalid("reasoning", "reasoning controls are not supported", "unsupported_parameter") }
        var messages: [[String: Any]] = []
        if let instructions = req["instructions"] as? String, !instructions.isEmpty { messages.append(["role": "system", "content": instructions]) }
        if let input = req["input"] as? String, !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append(["role": "user", "content": input])
        } else if let items = req["input"] as? [[String: Any]], !items.isEmpty {
            for item in items {
                let type = item["type"] as? String ?? "message"
                switch type {
                case "message":
                    let role = item["role"] as? String ?? "user"
                    guard ["system", "developer", "user", "assistant"].contains(role) else { throw invalid("input", "Unsupported message role") }
                    messages.append(["role": role == "developer" ? "system" : role, "content": try Self.content(item["content"])])
                case "function_call_output", "function_call":
                    guard let callID = (item["call_id"] ?? item["id"]) as? String, !callID.isEmpty else { throw invalid("input", "Function items require call_id") }
                    if type == "function_call_output" {
                        messages.append(["role": "tool", "tool_call_id": callID, "content": try Self.content(item["output"])])
                    } else {
                        guard let name = item["name"] as? String, !name.isEmpty, let arguments = item["arguments"] as? String else { throw invalid("input", "Function calls require name and arguments") }
                        messages.append(["role": "assistant", "content": NSNull(), "tool_calls": [["id": callID, "type": "function", "function": ["name": name, "arguments": arguments]]]])
                    }
                default: throw invalid("input", "Unsupported input item: \(type)", "unsupported_parameter")
                }
            }
        } else { throw invalid("input", "input must be a nonempty string or message array") }
        var flatTools: [[String: Any]] = []
        if let value = req["tools"], !(value is NSNull) {
            guard let inputTools = value as? [[String: Any]] else { throw invalid("tools", "tools must be an array") }
            for tool in inputTools {
                if tool["type"] as? String == "namespace" {
                    guard let nested = tool["tools"] as? [[String: Any]] else { throw invalid("tools", "namespace tools must be an array") }
                    flatTools.append(contentsOf: nested)
                } else { flatTools.append(tool) }
            }
        }
        var names = Set<String>()
        for tool in flatTools {
            guard tool["type"] as? String == "function", let name = tool["name"] as? String, !name.isEmpty, names.insert(name).inserted else { throw invalid("tools", "Only uniquely named function tools are supported", "unsupported_parameter") }
        }
        var chat: [String: Any] = ["model": model, "messages": messages, "stream": req["stream"] as? Bool ?? false]
        if !flatTools.isEmpty { chat["tools"] = flatTools.map { tool -> [String: Any] in var fn = tool; fn.removeValue(forKey: "type"); return ["type": "function", "function": fn] } }
        if let choice = req["tool_choice"], !(choice is NSNull) {
            if let choice = choice as? String, ["auto", "none", "required"].contains(choice), choice != "required" || !flatTools.isEmpty { chat["tool_choice"] = choice }
            else if let choice = choice as? [String: Any], choice["type"] as? String == "function", let name = choice["name"] as? String, names.contains(name) { chat["tool_choice"] = ["type": "function", "function": ["name": name]] }
            else { throw invalid("tool_choice", "Unsupported or unavailable function selection", "unsupported_parameter") }
        }
        var textFormat: [String: Any] = ["type": "text"]
        if let value = req["text"], !(value is NSNull) {
            guard let config = value as? [String: Any], Set(config.keys).isSubset(of: ["format"]) else { throw invalid("text", "Only text.format is supported") }
            if let value = config["format"], !(value is NSNull) {
                guard let fmt = value as? [String: Any], let type = fmt["type"] as? String else { throw invalid("text.format", "text.format must have a type") }
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
        request = req; tools = flatTools; format = textFormat
        stream = req["stream"] as? Bool ?? false
        chatRequestBody = try JSONSerialization.data(withJSONObject: chat)
    }

    private static func isBoolean(_ value: Any) -> Bool { (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false }
    private static func content(_ value: Any?) throws -> String {
        if let value = value as? String { return value }
        if value == nil || value is NSNull { return "" }
        guard let parts = value as? [[String: Any]] else { throw LocalResponsesError(code: "invalid_request", param: "input", message: "Only text content is supported") }
        return try parts.map { part in
            guard let type = part["type"] as? String, ["input_text", "output_text", "text"].contains(type), part["image_url"] == nil, let text = part["text"] as? String else { throw LocalResponsesError(code: "unsupported_parameter", param: "input", message: "Only text content is supported") }
            return text
        }.joined()
    }

    private func response(status: String, items: [[String: Any]], usage: [String: Any]? = nil) -> [String: Any] {
        ["id": id, "object": "response", "created_at": created, "status": status, "error": NSNull(), "incomplete_details": NSNull(), "model": request["model"]!, "output": items, "store": false, "previous_response_id": NSNull(), "instructions": request["instructions"] ?? NSNull(), "max_output_tokens": request["max_output_tokens"] ?? NSNull(), "parallel_tool_calls": request["parallel_tool_calls"] ?? true, "text": ["format": format], "tool_choice": request["tool_choice"] ?? "auto", "tools": tools, "truncation": "disabled", "usage": usage ?? NSNull() as Any, "metadata": request["metadata"] ?? [:], "temperature": request["temperature"] ?? NSNull(), "top_p": request["top_p"] ?? NSNull(), "user": request["user"] ?? NSNull(), "reasoning": ["effort": NSNull(), "summary": NSNull()]]
    }
    private func usageMap(_ chat: [String: Any]) -> [String: Any] {
        let input = chat["prompt_tokens"] as? Int ?? 0, output = chat["completion_tokens"] as? Int ?? 0
        let details = chat["prompt_tokens_details"] as? [String: Any]
        return ["input_tokens": input, "output_tokens": output, "total_tokens": chat["total_tokens"] as? Int ?? input + output, "input_tokens_details": ["cached_tokens": max(chat["cached_prompt_tokens"] as? Int ?? 0, details?["cached_tokens"] as? Int ?? 0), "cache_write_tokens": 0], "output_tokens_details": ["reasoning_tokens": 0]]
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
        let content = try Self.content(msg["content"])
        let clean = content.replacingOccurrences(of: "(?s)<think>.*?(?:</think>|$)", with: "", options: .regularExpression) + (msg["refusal"] as? String ?? "")
        if !clean.isEmpty { items.append(message(clean)) }
        for call in msg["tool_calls"] as? [[String: Any]] ?? [] {
            guard let fn = call["function"] as? [String: Any], let name = fn["name"] as? String, let args = fn["arguments"] as? String else { throw LocalResponsesError(code: "provider_error", param: "", message: "Malformed function call") }
            let callID = call["id"] as? String ?? "call_\(id)_\(items.count)"
            items.append(["id": "fc_" + callID, "type": "function_call", "call_id": callID, "name": name, "arguments": args, "status": "completed"])
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
        var events: [String] = []
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
    private func appendTool(index: Int, call: [String: Any], function: [String: Any]) -> [String] {
        var events: [String] = []
        if toolIndices[index] == nil {
            let callID = call["id"] as? String ?? "call_\(id)_\(index)"
            toolIndices[index] = output.count
            let item: [String: Any] = ["id": "fc_" + callID, "type": "function_call", "call_id": callID, "name": function["name"] as? String ?? "", "arguments": "", "status": "in_progress"]
            output.append(item)
            events.append(event("response.output_item.added", ["output_index": output.count - 1, "item": item]))
        }
        let out = toolIndices[index]!
        if let name = function["name"] as? String, !name.isEmpty { output[out]["name"] = name }
        if let args = function["arguments"] as? String, !args.isEmpty {
            output[out]["arguments"] = (output[out]["arguments"] as? String ?? "") + args
            events.append(event("response.function_call_arguments.delta", ["item_id": output[out]["id"]!, "output_index": out, "delta": args]))
        }
        return events
    }
    private func completeStream() -> [String] {
        guard !terminal else { return [] }
        guard let reason = finishReason, ["stop", "tool_calls", "function_call", "length", "content_filter"].contains(reason) else { return failStream(["code": "stream_incomplete", "message": "Chat stream has no valid finish reason", "type": "api_error"]) }
        var events = appendText(filterThink("", final: true))
        for index in output.indices {
            if index == textIndex {
                let fields: [String: Any] = ["item_id": "msg_" + id, "output_index": index, "content_index": 0]
                var done = fields; done["text"] = text
                events.append(event("response.output_text.done", done))
                let item = message(text)
                var part = fields; part["part"] = (item["content"] as! [[String: Any]])[0]
                events.append(event("response.content_part.done", part))
                output[index] = item
            } else {
                output[index]["status"] = "completed"
                events.append(event("response.function_call_arguments.done", ["item_id": output[index]["id"]!, "output_index": index, "name": output[index]["name"]!, "arguments": output[index]["arguments"]!]))
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
