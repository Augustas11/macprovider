import Foundation

/// No remote URLs or credentials enter this transport. Redirects and proxies are
/// disabled even for discovery, so a loopback response cannot move a chat off-Mac.
struct ChatEndpoint: Equatable, Sendable {
    let port: Int
    init(port: Int) throws {
        guard (1024...65535).contains(port) else { throw ChatFailure.unavailable }
        self.port = port
    }
    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }
}

enum ChatFailure: Error, LocalizedError, Equatable {
    case unavailable, upgradeRequired, modelChanged, unsupportedTools, preempted
    case malformed, limit, timeout, http(Int), unsafePath, invalidTool
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Start a provider and load a model to chat on this Mac."
        case .upgradeRequired: return "Update provider software to use local Chat with customer priority and separate usage."
        case .modelChanged: return "The loaded model changed. Start a new conversation."
        case .unsupportedTools: return "This model does not advertise guaranteed tool selection. Use Chat mode."
        case .preempted: return "Paused for a paying customer. Send a new message when this Mac is available."
        case .malformed: return "The local provider returned an incomplete or invalid response."
        case .limit: return "This turn reached its safety limit. Try a smaller request."
        case .timeout: return "This turn reached its time limit. Try again."
        case .http(let status): return "The local provider could not complete this request (HTTP \(status))."
        case .unsafePath: return "That file is unavailable within the selected folder. Symlinks and special files are not allowed."
        case .invalidTool: return "The model requested an invalid or unsupported tool."
        }
    }
}

struct ChatCapability: Equatable, Sendable {
    let model: String
    let generation: Int?
    let guaranteedTools: Bool
    static func parse(capabilities: Data, status: Data) throws -> Self {
        guard let cap = try JSONSerialization.jsonObject(with: capabilities) as? [String: Any],
              let state = try JSONSerialization.jsonObject(with: status) as? [String: Any],
              let priority = cap["local_priority"] as? [String: Any],
              priority["capability"] as? String == "local_chat_priority_v1",
              priority["billable"] as? Bool == false,
              priority["heartbeat_counted"] as? Bool == false,
              priority["priority"] as? String == "customers_first",
              priority["preempted_error_code"] as? String == "local_preempted",
              let usage = state["local_usage"] as? [String: Any],
              usage["billable"] as? Bool == false,
              usage["heartbeat_counted"] as? Bool == false,
              usage["priority"] as? String == "customers_first",
              let contract = state["local_status_contract"] as? [String: Any],
              (contract["capabilities"] as? [String])?.contains("local_chat_priority_v1") == true
        else { throw ChatFailure.upgradeRequired }
        guard let responses = cap["responses"] as? [String: Any],
              responses["available"] as? Bool == true,
              let model = responses["model"] as? String, !model.isEmpty,
              state["model_loaded"] as? Bool == true,
              state["model"] as? String == model
        else { throw ChatFailure.unavailable }
        let modes = responses["tool_choice_modes"] as? [String] ?? []
        return Self(model: model, generation: responses["generation"] as? Int,
                    guaranteedTools: modes.contains("required"))
    }
}

struct ChatToolCall: Equatable, Sendable {
    var id: String = ""
    var name: String = ""
    var arguments: String = ""
    var json: [String: Any] {
        ["id": id, "type": "function", "function": ["name": name, "arguments": arguments]]
    }
}
struct ChatCompletion: Sendable {
    let text: String
    let calls: [ChatToolCall]
}

/// Byte framing preserves split UTF-8 scalars and CRLF. Limits apply before
/// decoding, not after URLSession has accumulated an unbounded line or body.
struct ChatSSEDecoder {
    private var line = Data()
    private var eventLines: [Data] = []
    private var eventBytes = 0
    private var total = 0
    mutating func feed(_ byte: UInt8) throws -> String? {
        total += 1
        guard total <= 512 * 1024, line.count < 64 * 1024 else { throw ChatFailure.limit }
        if byte != 10 { line.append(byte); return nil }
        if line.last == 13 { line.removeLast() }
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty {
            guard !eventLines.isEmpty else { return nil }
            let data = eventLines.reduce(into: Data()) { result, part in
                if !result.isEmpty { result.append(10) }
                result.append(part)
            }
            eventLines.removeAll(keepingCapacity: true); eventBytes = 0
            guard let text = String(data: data, encoding: .utf8) else { throw ChatFailure.malformed }
            return text
        }
        if line.starts(with: Data("data:".utf8)) {
            var payload = line.dropFirst(5)
            if payload.first == 32 { payload = payload.dropFirst() }
            eventBytes += payload.count
            guard eventBytes <= 64 * 1024 else { throw ChatFailure.limit }
            eventLines.append(Data(payload))
        }
        return nil
    }
}

struct ChatStreamAccumulator {
    private(set) var text = ""
    private var calls: [Int: ChatToolCall] = [:]
    private(set) var done = false
    private var finished = false
    mutating func accept(_ payload: String) throws -> String? {
        guard !done else { throw ChatFailure.malformed }
        if payload == "[DONE]" {
            guard finished else { throw ChatFailure.malformed }
            done = true; return nil
        }
        guard let data = payload.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ChatFailure.malformed }
        if let error = object["error"] as? [String: Any] {
            throw error["code"] as? String == "local_preempted" ? ChatFailure.preempted : ChatFailure.malformed
        }
        guard let choices = object["choices"] as? [[String: Any]] else { throw ChatFailure.malformed }
        // Usage-only events are permitted, but may not substitute for a finish.
        guard !choices.isEmpty else { return nil }
        guard !finished, choices.count == 1, let choice = choices.first,
              (choice["index"] as? Int ?? 0) == 0 else { throw ChatFailure.malformed }
        if let reason = choice["finish_reason"] as? String {
            guard reason == "stop" || reason == "tool_calls" else { throw ChatFailure.limit }
            finished = true
        }
        let delta = choice["delta"] as? [String: Any] ?? [:]
        let fragment = delta["content"] as? String ?? ""
        text += fragment
        guard text.utf8.count <= 64 * 1024 else { throw ChatFailure.limit }
        for part in delta["tool_calls"] as? [[String: Any]] ?? [] {
            guard let index = part["index"] as? Int, (0..<12).contains(index) else { throw ChatFailure.limit }
            var call = calls[index] ?? ChatToolCall()
            call.id += part["id"] as? String ?? ""
            let function = part["function"] as? [String: Any] ?? [:]
            call.name += function["name"] as? String ?? ""
            call.arguments += function["arguments"] as? String ?? ""
            guard call.id.utf8.count <= 128, call.name.utf8.count <= 64,
                  call.arguments.utf8.count <= 32 * 1024 else { throw ChatFailure.limit }
            calls[index] = call
        }
        return fragment.isEmpty ? nil : fragment
    }
    func result() throws -> ChatCompletion {
        guard done else { throw ChatFailure.malformed }
        let ordered = calls.keys.sorted().compactMap { calls[$0] }
        guard ordered.allSatisfy({ !$0.id.isEmpty && !$0.name.isEmpty }),
              Set(ordered.map(\.id)).count == ordered.count else { throw ChatFailure.malformed }
        return ChatCompletion(text: text, calls: ordered)
    }
}

@MainActor
protocol ChatTransport {
    func capability(at endpoint: ChatEndpoint) async throws -> ChatCapability
    func complete(at endpoint: ChatEndpoint, body: Data,
                  onText: @escaping @MainActor (String) -> Void) async throws -> ChatCompletion
}

private final class ChatNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor
final class LocalChatTransport: ChatTransport {
    private let session: URLSession
    private let redirect = ChatNoRedirect()
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 90
        session = URLSession(configuration: config)
    }
    deinit { session.invalidateAndCancel() }
    func capability(at endpoint: ChatEndpoint) async throws -> ChatCapability {
        let capabilities = try await json(at: endpoint.url("/v1/capabilities"))
        let status = try await json(at: endpoint.url("/v1/status"))
        return try ChatCapability.parse(capabilities: capabilities, status: status)
    }
    private func json(at url: URL) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: URLRequest(url: url), delegate: redirect)
        try check(response)
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 256 * 1024 else { throw ChatFailure.limit }
            data.append(byte)
        }
        return data
    }
    func complete(at endpoint: ChatEndpoint, body: Data,
                  onText: @escaping @MainActor (String) -> Void) async throws -> ChatCompletion {
        let request = Self.completionRequest(at: endpoint, body: body)
        let (bytes, response) = try await session.bytes(for: request, delegate: redirect)
        guard let http = response as? HTTPURLResponse else { throw ChatFailure.malformed }
        if http.statusCode != 200 {
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < 16 * 1024 else { throw ChatFailure.limit }
                data.append(byte)
            }
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if (object?["error"] as? [String: Any])?["code"] as? String == "local_preempted" {
                throw ChatFailure.preempted
            }
            throw ChatFailure.http(http.statusCode)
        }
        guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("text/event-stream") == true
        else { throw ChatFailure.malformed }
        var decoder = ChatSSEDecoder(); var accumulator = ChatStreamAccumulator()
        for try await byte in bytes {
            try Task.checkCancellation()
            if let event = try decoder.feed(byte) {
                if let fragment = try accumulator.accept(event) { onText(fragment) }
                if accumulator.done { return try accumulator.result() }
            }
        }
        throw ChatFailure.malformed
    }
    /// SPEC-001-R011: the provider classifies a loopback request as local
    /// only when it carries this explicit marker; anything else is a buyer.
    nonisolated static let originHeader = "X-MacProvider-Origin"
    nonisolated static let localOrigin = "local-app"

    nonisolated static func completionRequest(at endpoint: ChatEndpoint, body: Data) -> URLRequest {
        var request = URLRequest(url: endpoint.url("/v1/chat/completions"))
        request.httpMethod = "POST"; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(localOrigin, forHTTPHeaderField: originHeader)
        return request
    }

    private func check(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw ChatFailure.malformed }
        guard response.statusCode == 200 else { throw ChatFailure.http(response.statusCode) }
    }
}
