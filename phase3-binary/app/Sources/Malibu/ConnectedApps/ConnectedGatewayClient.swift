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

    func models(key: String) async throws -> [ConnectedModel] {
        let data = try await request(path: "models", key: key, body: nil)
        return try Self.decodeModels(data)
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
            return ConnectedModel(id: id, contextWindow: context.flatMap { $0 > 0 ? $0 : nil },
                                  maxOutputTokens: output.flatMap { $0 > 0 ? $0 : nil })
        }.sorted { $0.id < $1.id }
    }

    static func testBody(api: ConnectedAPI, model: String) -> [String: Any] {
        switch api {
        case .responses: ["model": model, "input": "Reply with OK.", "max_output_tokens": 16, "stream": false, "store": false]
        case .chatCompletions: ["model": model, "messages": [["role": "user", "content": "Reply with OK."]], "max_tokens": 16, "stream": false]
        }
    }

    func test(api: ConnectedAPI, model: String, key: String) async throws {
        let body = Self.testBody(api: api, model: model)
        let data = try await request(path: api == .responses ? "responses" : "chat/completions", key: key, body: body)
        try Self.validateCompletion(data, api: api)
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
