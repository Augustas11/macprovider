import Foundation

enum MCPServingFactory {
    @MainActor
    static func make(_ configuration: MCPServerConfiguration) -> any MCPServing {
        if configuration.command.isEmpty, MCPServerConfiguration.acceptedURL(configuration.url) != nil {
            return MCPHTTPClient(configuration: configuration)
        }
        return MCPClient(configuration: configuration)
    }
}

/// Refuses every redirect. A loopback POST must not be sent on with tool arguments.
final class MCPHTTPRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Streamable HTTP JSON-RPC. POST only, no cookies, no redirects, no logged URLs.
/// http is limited to loopback; every other host must be https.
@MainActor
final class MCPHTTPClient: MCPServing {
    let configuration: MCPServerConfiguration
    private let timeout: TimeInterval
    private let lifetime: TimeInterval
    private let messageLimit: Int
    private let session: URLSession
    private let redirect = MCPHTTPRedirectBlocker()
    private let endpoint: URL?
    private var tools: [MCPTool] = []
    private var allowed: Set<String> = []
    private var busy = false
    private var started = false
    private var terminal = false
    private var sessionID: String?
    private var protocolVersion: String?
    private var requestID = 0
    private var lifetimeTask: Task<Void, Never>?
    private nonisolated(unsafe) var didInvalidate = false
    var isRunning: Bool { started && !terminal }

    init(configuration: MCPServerConfiguration, timeout: TimeInterval = 15,
         lifetime: TimeInterval = 300, messageLimit: Int = 65536, session: URLSession? = nil) {
        self.configuration = configuration
        self.timeout = timeout
        self.lifetime = lifetime
        self.messageLimit = messageLimit
        self.endpoint = MCPServerConfiguration.acceptedURL(configuration.url)
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.connectionProxyDictionary = [:]
            config.httpShouldSetCookies = false
            config.httpCookieAcceptPolicy = .never
            config.urlCredentialStorage = nil
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.timeoutIntervalForRequest = timeout
            config.timeoutIntervalForResource = timeout
            self.session = URLSession(configuration: config)
        }
    }

    deinit {
        guard !didInvalidate else { return }
        didInvalidate = true
        session.invalidateAndCancel()
    }

    func start() async throws -> [MCPTool] {
        guard !terminal, !started, endpoint != nil, configuration.command.isEmpty else { throw MCPFailure.unavailable }
        lifetimeTask = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(for: .seconds(self.lifetime)) } catch { return }
            self.stop()
        }
        do {
            requestID += 1
            let initialized = try await post(method: "initialize", params: ["protocolVersion": "2024-11-05", "capabilities": [:],
                "clientInfo": ["name": "Malibu", "version": "1"]], id: requestID)
            protocolVersion = try MCPExchange.checkInitialize(initialized)
            try await post(method: "notifications/initialized", params: [:], id: nil)
            requestID += 1
            let listed = try await post(method: "tools/list", params: [:], id: requestID)
            tools = try MCPExchange.tools(from: listed, configuration: configuration)
            guard !terminal else { throw MCPFailure.unavailable }
            started = true
            return tools
        } catch {
            stop()
            throw error
        }
    }

    func call(tool: MCPTool, arguments: String,
              approval: @MainActor (MCPTool, String) async -> MCPApprovalDecision) async throws -> String {
        guard !terminal, !busy, started, let known = tools.first(where: { $0.name == tool.name }) else { throw MCPFailure.unavailable }
        let object = try MCPExchange.arguments(arguments, tool: known, limit: messageLimit)
        if !allowed.contains(known.name) {
            let decision = await approval(known, arguments)
            try Task.checkCancellation()
            guard !terminal else { throw MCPFailure.unavailable }
            switch decision {
            case .deny: throw MCPFailure.denied
            case .allowOnce: break
            case .allowSession: allowed.insert(known.name)
            }
        }
        do {
            requestID += 1
            let result = try await post(method: "tools/call", params: ["name": known.originalName, "arguments": object], id: requestID)
            return try MCPExchange.resultText(result)
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        terminal = true
        lifetimeTask?.cancel()
        lifetimeTask = nil
        allowed.removeAll()
        tools.removeAll()
        sessionID = nil
        started = false
        guard !didInvalidate else { return }
        didInvalidate = true
        session.invalidateAndCancel()
    }

    /// `id` nil is a notification. The result is the JSON-RPC result object.
    private func post(method: String, params: [String: Any], id: Int?) async throws -> [String: Any] {
        guard !busy, !terminal, let endpoint else { throw MCPFailure.unavailable }
        busy = true
        defer { busy = false }
        var payload: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let id { payload["id"] = id }
        if id != nil || !params.isEmpty { payload["params"] = params }
        let body = try JSONSerialization.data(withJSONObject: payload)
        guard body.count <= messageLimit else { throw MCPFailure.oversize }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = timeout
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let protocolVersion {
            request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        }
        if let sessionID {
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        if let origin = Self.origin(for: endpoint) {
            request.setValue(origin, forHTTPHeaderField: "Origin")
        }
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request, delegate: redirect)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw MCPFailure.timeout
        } catch let failure as MCPFailure {
            throw failure
        } catch {
            throw MCPFailure.unavailable
        }
        guard let http = response as? HTTPURLResponse else { throw MCPFailure.malformed }
        if let raw = http.value(forHTTPHeaderField: "Mcp-Session-Id") {
            guard let accepted = Self.acceptedSessionID(raw) else { throw MCPFailure.malformed }
            if let sessionID, sessionID != accepted { throw MCPFailure.malformed }
            sessionID = accepted
        }
        // A 3xx is never success, even if the redirect delegate was skipped.
        if (300..<400).contains(http.statusCode) { throw MCPFailure.unavailable }
        var data = Data()
        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < messageLimit else { throw MCPFailure.oversize }
                data.append(byte)
            }
        } catch let failure as MCPFailure {
            throw failure
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MCPFailure.unavailable
        }
        if id == nil {
            guard (200...299).contains(http.statusCode) || http.statusCode == 202 else { throw MCPFailure.malformed }
            return [:]
        }
        guard (200...299).contains(http.statusCode) else { throw MCPFailure.malformed }
        let type = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        if type.lowercased().contains("text/event-stream") {
            return try Self.sseResult(data, id: id ?? 0)
        }
        return try Self.jsonResult(data, id: id ?? 0)
    }

    private static func origin(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty else { return nil }
        let hostText = host.contains(":") ? "[\(host)]" : host
        if let port = url.port { return "\(scheme)://\(hostText):\(port)" }
        return "\(scheme)://\(hostText)"
    }

    /// Header values only. Reject CR, LF and spaces so a session id cannot inject headers.
    private static func acceptedSessionID(_ raw: String) -> String? {
        guard !raw.isEmpty, raw.utf8.count <= 256,
              raw.allSatisfy({ character in
                  guard character.isASCII, let value = character.asciiValue else { return false }
                  return value >= 0x21 && value <= 0x7e
              })
        else { return nil }
        return raw
    }

    private static func jsonResult(_ data: Data, id: Int) throws -> [String: Any] {
        do { try MalibuStrictJSON.rejectDuplicateKeys(data) } catch { throw MCPFailure.malformed }
        guard let message = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MCPFailure.malformed }
        return try match(message, id: id)
    }

    private static func sseResult(_ data: Data, id: Int) throws -> [String: Any] {
        guard let text = String(data: data, encoding: .utf8) else { throw MCPFailure.malformed }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var found: [String: Any]?
        var dataLines: [String] = []
        func flush() throws {
            guard !dataLines.isEmpty else { return }
            let payload = Data(dataLines.joined(separator: "\n").utf8)
            dataLines.removeAll()
            do { try MalibuStrictJSON.rejectDuplicateKeys(payload) } catch { throw MCPFailure.malformed }
            guard let message = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  message["jsonrpc"] as? String == "2.0" else { throw MCPFailure.malformed }
            if message["id"] == nil, message["method"] is String,
               message["result"] == nil, message["error"] == nil { return }
            let result = try match(message, id: id)
            guard found == nil else { throw MCPFailure.malformed }
            found = result
        }
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty {
                try flush()
                continue
            }
            if line.hasPrefix(":") { continue }
            if line.hasPrefix("data:") {
                var payload = line.dropFirst(5)
                if payload.first == " " { payload = payload.dropFirst() }
                dataLines.append(String(payload))
            }
        }
        try flush()
        guard let found else { throw MCPFailure.malformed }
        return found
    }

    private static func match(_ message: [String: Any], id: Int) throws -> [String: Any] {
        guard message["jsonrpc"] as? String == "2.0", message["method"] == nil,
              let reply = message["id"] as? Int, reply == id,
              message["error"] == nil, let result = message["result"] as? [String: Any]
        else { throw MCPFailure.malformed }
        return result
    }
}

/// Test double for streamable HTTP. Records requests and never opens a socket.
final class MCPHTTPProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status: Int
        var headers: [String: String]
        var body: Data
    }
    static let lock = NSLock()
    nonisolated(unsafe) static var handlers: [String: (URLRequest) throws -> Reply] = [:]
    nonisolated(unsafe) static var requests: [URLRequest] = []

    static func register(_ url: String, _ handler: @escaping (URLRequest) throws -> Reply) {
        lock.lock()
        handlers[url] = handler
        lock.unlock()
    }
    static func reset() {
        lock.lock()
        handlers.removeAll()
        requests.removeAll()
        lock.unlock()
    }
    static func recorded() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let key = request.url?.absoluteString else { return false }
        lock.lock()
        defer { lock.unlock() }
        return handlers[key] != nil
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url?.absoluteString ?? ""
        Self.lock.lock()
        Self.requests.append(request)
        let handler = Self.handlers[url]
        Self.lock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let reply = try handler(request)
            let response = HTTPURLResponse(url: request.url ?? URL(string: "http://127.0.0.1/")!,
                                           statusCode: reply.status, httpVersion: "HTTP/1.1",
                                           headerFields: reply.headers)
            guard let response else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}

    static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 4096)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
