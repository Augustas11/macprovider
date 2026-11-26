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
    case malformed, limit, timeout, http(Int), unsafePath, invalidTool, contextTooLong
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Start a provider and load a model to chat on this Mac."
        case .upgradeRequired: return "Update provider software to use local Chat with customer priority and separate usage."
        case .modelChanged: return "The loaded model changed before this reply."
        case .unsupportedTools: return "This model does not advertise guaranteed tool selection. Use Chat mode."
        case .preempted: return "Paused for a paying customer. Send a new message when this Mac is available."
        case .malformed: return "The local provider returned an incomplete or invalid response."
        case .limit: return "This turn reached its safety limit. Try a smaller request."
        case .timeout: return "This turn timed out. Try again."
        case .http(let status): return "The local provider could not complete this request (HTTP \(status))."
        case .unsafePath: return "That file is unavailable within the selected folder. Symlinks, hard links and special files are not allowed."
        case .invalidTool: return "The model requested an invalid or unsupported tool."
        case .contextTooLong: return "This chat is longer than the model's context; start a new chat or continue with fewer turns."
        }
    }
}

struct ChatCapability: Equatable, Sendable {
    let model: String
    let generation: Int?
    let guaranteedTools: Bool
    /// From `/v1/status` `capacity.max_context_tokens`, when reported.
    var maxContextTokens: Int?
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
        let context = (state["capacity"] as? [String: Any])?["max_context_tokens"] as? Int
        return Self(model: model, generation: responses["generation"] as? Int,
                    guaranteedTools: modes.contains("required"),
                    maxContextTokens: context.flatMap { $0 > 0 ? $0 : nil })
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
    /// Model reasoning (`reasoning_content`) is shown and saved, never sent back to the model.
    var reasoning = ""
    /// The reply stopped early (finish_reason `length`, or the text cap); `text` holds what arrived.
    var truncated = false
    /// `usage.completion_tokens`, when the server reported it.
    var completionTokens: Int? = nil
    /// `usage.prompt_tokens`, when the server reported it.
    var promptTokens: Int? = nil
    /// Provider decode time (`macprovider_decode_ms`, else `macprovider_generation_ms`).
    var decodeMilliseconds: Int? = nil
    var tokensPerSecond: Double? { ChatStats.rate(completionTokens: completionTokens, milliseconds: decodeMilliseconds) }
}

enum ChatStats {
    /// "128 tokens · 36.4 tok/s" when the provider reported both numbers.
    static func line(completionTokens: Int?, tokensPerSecond: Double?) -> String? {
        switch (completionTokens, tokensPerSecond) {
        case let (tokens?, rate?): return "\(tokens) tokens · \(Self.format(rate)) tok/s"
        case let (tokens?, nil): return "\(tokens) tokens"
        default: return nil
        }
    }
    static func rate(completionTokens: Int?, milliseconds: Int?) -> Double? {
        guard let completionTokens, completionTokens >= 0, let milliseconds, milliseconds > 0 else { return nil }
        return Double(completionTokens) / (Double(milliseconds) / 1000)
    }
    static func format(_ rate: Double) -> String {
        guard rate.isFinite, rate >= 0 else { return "0" }
        if rate >= 100 { return String(Int(rate.rounded())) }
        return String(format: "%.1f", rate)
    }
}

/// Byte framing preserves split UTF-8 scalars and CRLF. Limits apply before
/// decoding, not after URLSession has accumulated an unbounded line or body.
struct ChatSSEDecoder {
    private var line = Data()
    private var eventLines: [Data] = []
    private var eventBytes = 0
    private var total = 0
    /// A whole stream: 8192 tokens plus reasoning, one small JSON event each.
    static let streamByteLimit = 8 * 1024 * 1024
    mutating func feed(_ byte: UInt8) throws -> String? {
        total += 1
        guard total <= Self.streamByteLimit, line.count < 64 * 1024 else { throw ChatFailure.limit }
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
    static let textByteLimit = 64 * 1024
    /// Tool calls one response may carry, for every transport.
    static let maxCallsPerResponse = 12
    private(set) var text = ""
    private(set) var reasoning = ""
    /// The reasoning fragment from the most recent accepted event, if any.
    private(set) var lastReasoning: String?
    private(set) var truncated = false
    private(set) var completionTokens: Int?
    private(set) var promptTokens: Int?
    private(set) var decodeMilliseconds: Int?
    private var calls: [Int: ChatToolCall] = [:]
    private(set) var done = false
    private var finished = false
    mutating func accept(_ payload: String) throws -> String? {
        lastReasoning = nil
        guard !done else { throw ChatFailure.malformed }
        if payload == "[DONE]" {
            guard finished else { throw ChatFailure.malformed }
            done = true; return nil
        }
        guard let data = payload.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ChatFailure.malformed }
        if let error = object["error"] as? [String: Any] {
            switch error["code"] as? String {
            case "local_preempted": throw ChatFailure.preempted
            case "context_length_exceeded": throw ChatFailure.contextTooLong
            default: throw ChatFailure.malformed
            }
        }
        if let usage = object["usage"] as? [String: Any] {
            if let tokens = Self.usageInt(usage["completion_tokens"]) { completionTokens = tokens }
            if let tokens = Self.usageInt(usage["prompt_tokens"]) { promptTokens = tokens }
            if let decode = Self.usageInt(usage["macprovider_decode_ms"]) ?? Self.usageInt(usage["macprovider_generation_ms"]),
               decode > 0 {
                decodeMilliseconds = decode
            }
        }
        guard let choices = object["choices"] as? [[String: Any]] else { throw ChatFailure.malformed }
        // Usage-only events are permitted, but may not substitute for a finish.
        guard !choices.isEmpty else { return nil }
        guard !finished, choices.count == 1, let choice = choices.first,
              (choice["index"] as? Int ?? 0) == 0 else { throw ChatFailure.malformed }
        if let reason = choice["finish_reason"] as? String {
            // `length` keeps the partial reply; any other early stop is still a failure.
            guard reason == "stop" || reason == "tool_calls" || reason == "length" else { throw ChatFailure.limit }
            if reason == "length" { truncated = true }
            finished = true
        }
        let delta = choice["delta"] as? [String: Any] ?? [:]
        let thought = delta["reasoning_content"] as? String ?? delta["reasoning"] as? String ?? ""
        if !thought.isEmpty, reasoning.utf8.count + thought.utf8.count <= Self.textByteLimit {
            reasoning += thought; lastReasoning = thought
        }
        var fragment = delta["content"] as? String ?? ""
        // Past the cap the text already received is kept and the rest is dropped.
        if text.utf8.count + fragment.utf8.count > Self.textByteLimit {
            truncated = true; fragment = ""
        }
        text += fragment
        for part in delta["tool_calls"] as? [[String: Any]] ?? [] {
            guard let index = part["index"] as? Int, (0..<Self.maxCallsPerResponse).contains(index) else { throw ChatFailure.limit }
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
        return ChatCompletion(text: text, calls: ordered, reasoning: reasoning, truncated: truncated,
                              completionTokens: completionTokens, promptTokens: promptTokens,
                              decodeMilliseconds: decodeMilliseconds)
    }
    /// JSON numbers arrive as Int or as a whole Double.
    static func usageInt(_ value: Any?) -> Int? {
        if let number = value as? Int, number >= 0 { return number }
        if let number = value as? Double, number >= 0, number.rounded() == number, number <= Double(Int.max) {
            return Int(number)
        }
        return nil
    }
}

/// The provider sends `: keepalive` comments while a stream is quiet, and
/// they reset URLSession's idle timer. This guard counts only `data:` events,
/// so a stream that sends nothing but keepalives still times out.
struct ChatDataStallGuard {
    let limit: Duration
    private(set) var lastData: ContinuousClock.Instant
    init(limit: Duration, now: ContinuousClock.Instant = .now) { self.limit = limit; lastData = now }
    mutating func noteData(at now: ContinuousClock.Instant = .now) { lastData = now }
    func check(at now: ContinuousClock.Instant = .now) throws {
        guard now - lastData <= limit else { throw ChatFailure.timeout }
    }
}

@MainActor
protocol ChatTransport {
    func capability(at endpoint: ChatEndpoint) async throws -> ChatCapability
    func complete(at endpoint: ChatEndpoint, body: Data,
                  onText: @escaping @MainActor (String) -> Void) async throws -> ChatCompletion
    /// Streams reasoning fragments too. Transports without live reasoning
    /// still return it in `ChatCompletion.reasoning`.
    func complete(at endpoint: ChatEndpoint, body: Data,
                  onText: @escaping @MainActor (String) -> Void,
                  onReasoning: @escaping @MainActor (String) -> Void) async throws -> ChatCompletion
}

extension ChatTransport {
    func complete(at endpoint: ChatEndpoint, body: Data,
                  onText: @escaping @MainActor (String) -> Void,
                  onReasoning: @escaping @MainActor (String) -> Void) async throws -> ChatCompletion {
        try await complete(at: endpoint, body: body, onText: onText)
    }
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
    init() { session = URLSession(configuration: Self.sessionConfiguration()) }
    /// Idle (stall) timeout per request: a provider buffering a tool call can
    /// send nothing for over a minute. The resource limit is a backstop only;
    /// Stop is how the user ends a long reply or Agent run.
    nonisolated static let idleTimeout: TimeInterval = 300
    nonisolated static let resourceTimeout: TimeInterval = 3600
    nonisolated static func sessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = idleTimeout
        config.timeoutIntervalForResource = resourceTimeout
        return config
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
        try await complete(at: endpoint, body: body, onText: onText, onReasoning: { _ in })
    }
    func complete(at endpoint: ChatEndpoint, body: Data,
                  onText: @escaping @MainActor (String) -> Void,
                  onReasoning: @escaping @MainActor (String) -> Void) async throws -> ChatCompletion {
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
            let code = (object?["error"] as? [String: Any])?["code"] as? String
            if code == "local_preempted" { throw ChatFailure.preempted }
            if code == "context_length_exceeded" { throw ChatFailure.contextTooLong }
            throw ChatFailure.http(http.statusCode)
        }
        guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("text/event-stream") == true
        else { throw ChatFailure.malformed }
        var decoder = ChatSSEDecoder(); var accumulator = ChatStreamAccumulator()
        var stall = ChatDataStallGuard(limit: .seconds(Self.idleTimeout))
        for try await byte in bytes {
            try Task.checkCancellation()
            if byte == 10 { try stall.check() }
            if let event = try decoder.feed(byte) {
                stall.noteData()
                if let fragment = try accumulator.accept(event) { onText(fragment) }
                if let thought = accumulator.lastReasoning { onReasoning(thought) }
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
        // Continuous batching refuses a request without an id.
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-ID")
        return request
    }

    private func check(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw ChatFailure.malformed }
        guard response.statusCode == 200 else { throw ChatFailure.http(response.statusCode) }
    }
}
