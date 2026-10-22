import Foundation

final class ConnectedRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct ConnectedGatewayClient {
    static let maximumResponseBytes = 262_144

    /// Coding agents send long system prompts and tool schemas: the picker
    /// lists only models that call tools and have at least this context.
    static let minimumAgentContextTokens = 32_768

    func models(key: String) async throws -> [ConnectedModel] {
        let data = try await request(path: "models", key: key, body: nil)
        return Self.agentReady(try Self.decodeModels(data))
    }

    /// SPEC-025-R012: tool-capable models with enough context, from the
    /// gateway's published metadata only.
    static func agentReady(_ models: [ConnectedModel]) -> [ConnectedModel] {
        models.filter { $0.supportsTools && ($0.contextWindow ?? 0) >= minimumAgentContextTokens }
    }

    static func decodeModels(_ data: Data) throws -> [ConnectedModel] {
        guard data.count <= maximumResponseBytes else { throw ConnectedAppsError.invalidResponse }
        do { try MalibuStrictJSON.rejectDuplicateKeys(data) } catch { throw ConnectedAppsError.invalidResponse }
        guard data.count <= maximumResponseBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["data"] as? [[String: Any]], rows.count <= 2048 else { throw ConnectedAppsError.invalidResponse }
        var seen = Set<String>()
        return rows.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty, id.utf8.count <= 512,
                  !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  seen.insert(id).inserted else { return nil }
            let context = row["max_context_tokens"] as? Int
            let output = row["max_output_tokens"] as? Int
            let tools = (row["capabilities"] as? [String: Any])?["tools"] as? Bool ?? false
            return ConnectedModel(id: id, contextWindow: context.flatMap { $0 > 0 ? $0 : nil },
                                  maxOutputTokens: output.flatMap { $0 > 0 ? $0 : nil },
                                  supportsTools: tools)
        }.sorted { $0.id < $1.id }
    }

    static let testToolName = "get_magic_number"
    static let testToolResult = "42"
    /// Room for a reasoning model to think before its call; still bounded.
    static let testMaxTokens = 1024

    private static let testTool: [String: Any] = [
        "name": testToolName,
        "description": "Returns the magic number.",
        "parameters": ["type": "object", "properties": [String: Any](), "additionalProperties": false],
    ]
    private static let testPrompt = "Call the get_magic_number tool, then reply with the number it returns."

    /// Step 1 of the endpoint test: a declared tool the model must call.
    static func testBody(api: ConnectedAPI, model: String) -> [String: Any] {
        switch api {
        case .responses:
            var tool = testTool
            tool["type"] = "function"
            return ["model": model, "input": testPrompt, "tools": [tool], "max_output_tokens": testMaxTokens, "stream": false, "store": false]
        case .chatCompletions:
            return ["model": model, "messages": [["role": "user", "content": testPrompt]],
                    "tools": [["type": "function", "function": testTool]], "max_tokens": testMaxTokens, "stream": false]
        }
    }

    /// Step 2: the call and its result go back as history; the model answers.
    static func toolResultBody(api: ConnectedAPI, model: String, callID: String) -> [String: Any] {
        switch api {
        case .responses:
            var tool = testTool
            tool["type"] = "function"
            return ["model": model, "tools": [tool], "max_output_tokens": testMaxTokens, "stream": false, "store": false,
                    "input": [
                        ["type": "message", "role": "user", "content": testPrompt],
                        ["type": "function_call", "call_id": callID, "name": testToolName, "arguments": "{}"],
                        ["type": "function_call_output", "call_id": callID, "output": testToolResult],
                    ]]
        case .chatCompletions:
            return ["model": model, "tools": [["type": "function", "function": testTool]], "max_tokens": testMaxTokens, "stream": false,
                    "messages": [
                        ["role": "user", "content": testPrompt],
                        ["role": "assistant", "content": NSNull(), "tool_calls": [[
                            "id": callID, "type": "function",
                            "function": ["name": testToolName, "arguments": "{}"],
                        ]]],
                        ["role": "tool", "tool_call_id": callID, "content": testToolResult],
                    ]]
        }
    }

    /// SPEC-025-R012: the endpoint test is a tool round trip on the selected
    /// API and model: the model must call the declared tool, then answer from
    /// its result.
    func test(api: ConnectedAPI, model: String, key: String) async throws {
        let first = try await request(path: api == .responses ? "responses" : "chat/completions", key: key, body: Self.testBody(api: api, model: model))
        let callID = try Self.toolCallID(first, api: api)
        let second = try await request(path: api == .responses ? "responses" : "chat/completions", key: key,
                                       body: Self.toolResultBody(api: api, model: model, callID: callID))
        try Self.validateCompletion(second, api: api)
    }

    /// The id of the test tool call in a step-1 response; anything else
    /// (text, another tool, an error) fails the test.
    static func toolCallID(_ data: Data, api: ConnectedAPI) throws -> String {
        guard data.count <= maximumResponseBytes else { throw ConnectedAppsError.invalidResponse }
        do { try MalibuStrictJSON.rejectDuplicateKeys(data) } catch { throw ConnectedAppsError.invalidResponse }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], root["error"] == nil else {
            throw ConnectedAppsError.invalidResponse
        }
        let id: String?
        switch api {
        case .responses:
            id = (root["output"] as? [[String: Any]] ?? []).first {
                $0["type"] as? String == "function_call" && $0["name"] as? String == testToolName
            }?["call_id"] as? String
        case .chatCompletions:
            let choice = (root["choices"] as? [[String: Any]] ?? []).first { $0["finish_reason"] as? String == "tool_calls" }
            let calls = (choice?["message"] as? [String: Any])?["tool_calls"] as? [[String: Any]] ?? []
            id = calls.first { ($0["function"] as? [String: Any])?["name"] as? String == testToolName }?["id"] as? String
        }
        guard let id, !id.isEmpty, id.utf8.count <= 128,
              !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ConnectedAppsError.invalidResponse
        }
        return id
    }

    static func validateCompletion(_ data: Data, api: ConnectedAPI) throws {
        guard data.count <= maximumResponseBytes else { throw ConnectedAppsError.invalidResponse }
        do { try MalibuStrictJSON.rejectDuplicateKeys(data) } catch { throw ConnectedAppsError.invalidResponse }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], root["error"] == nil else {
            throw ConnectedAppsError.invalidResponse
        }
        let hasText: Bool
        switch api {
        case .responses:
            guard root["status"] as? String == "completed" else { throw ConnectedAppsError.invalidResponse }
            let output = root["output"] as? [[String: Any]] ?? []
            hasText = output.contains { item in
                (item["content"] as? [[String: Any]] ?? []).contains {
                    $0["type"] as? String == "output_text" && !($0["text"] as? String ?? "").isEmpty
                }
            }
        case .chatCompletions:
            hasText = (root["choices"] as? [[String: Any]] ?? []).contains {
                $0["finish_reason"] as? String == "stop"
                    && !((($0["message"] as? [String: Any])?["content"] as? String) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
        guard hasText else { throw ConnectedAppsError.invalidResponse }
    }

    private func request(path: String, key: String, body: [String: Any]?) async throws -> Data {
        // Fixed production HTTPS origin: no arbitrary endpoint can receive the buyer key.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: ConnectedRedirectBlocker(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: ConnectedAppConfiguration.gateway.appendingPathComponent(path))
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (stream, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw ConnectedAppsError.invalidResponse }
            guard (200 ... 299).contains(response.statusCode) else { throw ConnectedAppsError.http(response.statusCode) }
            guard response.expectedContentLength <= Int64(Self.maximumResponseBytes) else { throw ConnectedAppsError.invalidResponse }
            var data = Data()
            for try await byte in stream {
                try Task.checkCancellation()
                guard data.count < Self.maximumResponseBytes else { throw ConnectedAppsError.invalidResponse }
                data.append(byte)
            }
            return data
        } catch let error as ConnectedAppsError { throw error }
        catch { throw ConnectedAppsError.network }
    }
}
