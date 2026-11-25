import Foundation
import XCTest
@testable import Malibu

@MainActor
final class MCPHTTPTests: XCTestCase {
    override func tearDown() async throws {
        MCPHTTPProtocol.reset()
        try await super.tearDown()
    }

    func testRejectedURLsNeverConnect() async {
        let rejected = [
            "file:///tmp/secret",
            "https://user:pass@example.com/mcp",
            "http://example.com/mcp",
            "https://127.0.0.1/mcp",
            "http://localhost.example.com/mcp",
        ]
        for raw in rejected {
            XCTAssertNil(MCPServerConfiguration.acceptedURL(raw), raw)
            let configuration = MCPServerConfiguration(name: "remote", url: raw)
            XCTAssertFalse(configuration.isAcceptable, raw)
            let client = MCPHTTPClient(configuration: configuration, timeout: 1, session: makeSession())
            do {
                _ = try await client.start()
                XCTFail("Started \(raw)")
            } catch {
                XCTAssertEqual(error as? MCPFailure, .unavailable, raw)
            }
        }
        XCTAssertTrue(MCPHTTPProtocol.recorded().isEmpty)
        XCTAssertNotNil(MCPServerConfiguration.acceptedURL("https://example.com/mcp"))
        XCTAssertNotNil(MCPServerConfiguration.acceptedURL("http://127.0.0.1:9/mcp"))
        XCTAssertNotNil(MCPServerConfiguration.acceptedURL("http://localhost/mcp"))
        XCTAssertNotNil(MCPServerConfiguration.acceptedURL("http://[::1]:9/mcp"))
        XCTAssertFalse(MCPServerConfiguration(name: "both", command: "/bin/echo", url: "https://example.com/mcp").isAcceptable)
    }

    func testSavedConfigurationsWithoutURLStillDecode() throws {
        let id = UUID()
        let serverID = UUID()
        let agents = """
        [{"id":"\(id.uuidString)","name":"A","instructions":"Read","target":"thisMac","model":"m","workspaceTools":false,"servers":[{"id":"\(serverID.uuidString)","name":"local","command":"/bin/echo","arguments":[],"environment":{}}],"sampling":{"temperature":0.7,"topP":0.9,"maxTokens":256}}]
        """
        let decoded = try JSONDecoder().decode([AgentDefinition].self, from: Data(agents.utf8))
        XCTAssertEqual(decoded.first?.servers.first?.command, "/bin/echo")
        XCTAssertEqual(decoded.first?.servers.first?.url, "")
        XCTAssertTrue(decoded.first?.servers.first?.isAcceptable == true)
        let settings = try JSONDecoder().decode(ChatSettings.self, from: Data(#"{"systemPrompt":"hi","sampling":{"temperature":0.5,"topP":0.25,"maxTokens":512}}"#.utf8))
        XCTAssertNil(settings.servers)
        XCTAssertTrue(settings.isValid)
    }

    func testRedirectDelegateRefusesAndStatusDoesNotFollow() async throws {
        let blocker = MCPHTTPRedirectBlocker()
        var followed: URLRequest?
        let task = URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:9/mcp")!)
        let redirect = HTTPURLResponse(url: URL(string: "http://127.0.0.1:9/mcp")!, statusCode: 302, httpVersion: nil,
                                       headerFields: ["Location": "https://example.com/stolen"])!
        blocker.urlSession(URLSession.shared, task: task,
                           willPerformHTTPRedirection: redirect,
                           newRequest: URLRequest(url: URL(string: "https://example.com/stolen")!),
                           completionHandler: { followed = $0 })
        XCTAssertNil(followed)

        var stolen = 0
        let endpoint = try XCTUnwrap(MCPServerConfiguration.acceptedURL("http://127.0.0.1:9/mcp"))
        MCPHTTPProtocol.register(endpoint.absoluteString) { _ in
            MCPHTTPProtocol.Reply(status: 302, headers: ["Location": "https://example.com/stolen"], body: Data())
        }
        MCPHTTPProtocol.register("https://example.com/stolen") { _ in
            stolen += 1
            return MCPHTTPProtocol.Reply(status: 200, headers: [:], body: Data("leaked".utf8))
        }
        let configuration = MCPServerConfiguration(name: "Docs", url: endpoint.absoluteString)
        let client = MCPHTTPClient(configuration: configuration, timeout: 2, session: makeSession())
        do {
            _ = try await client.start()
            XCTFail("Redirected server started")
        } catch {
            XCTAssertEqual(error as? MCPFailure, .unavailable)
        }
        XCTAssertEqual(stolen, 0)
        XCTAssertEqual(MCPHTTPProtocol.recorded().count, 1)
    }

    func testJSONHandshakeAsksBeforeTheCallAndDenySkipsIt() async throws {
        let log = CallLog()
        let endpoint = try registerJSON(endpoint: "http://127.0.0.1:9/mcp", log: log, call: .json)
        let configuration = MCPServerConfiguration(name: "Docs", url: endpoint.absoluteString)
        let client = MCPHTTPClient(configuration: configuration, timeout: 2, session: makeSession())
        let tools = try await client.start()
        let tool = try XCTUnwrap(tools.first)
        XCTAssertEqual(tool.originalName, "echo")
        do {
            _ = try await client.call(tool: tool, arguments: "{}") { _, _ in
                XCTFail("Invalid arguments reached approval")
                return .allowOnce
            }
            XCTFail("Invalid arguments were sent")
        } catch { XCTAssertEqual(error as? MCPFailure, .invalidArguments) }
        do {
            _ = try await client.call(tool: tool, arguments: "{\"text\":\"no\"}") { _, _ in .deny }
            XCTFail("Denied call returned")
        } catch { XCTAssertEqual(error as? MCPFailure, .denied) }
        XCTAssertFalse(log.methods.contains("tools/call"))
        let result = try await client.call(tool: tool, arguments: "{\"text\":\"hi\"}") { _, _ in .allowOnce }
        XCTAssertTrue(result.contains("hello"))
        XCTAssertEqual(log.methods, ["initialize", "notifications/initialized", "tools/list", "tools/call"])
        XCTAssertEqual(log.protocolVersions.count, 4)
        XCTAssertNil(log.protocolVersions[0])
        XCTAssertEqual(log.protocolVersions[1], "2025-03-26")
        XCTAssertEqual(log.sessionIDs[2], "sess-1")
        client.stop()
    }

    func testSSEResultIsReadAndNotificationsAreIgnored() async throws {
        let log = CallLog()
        let endpoint = try registerJSON(endpoint: "http://127.0.0.1:9/sse", log: log, call: .sse)
        let configuration = MCPServerConfiguration(name: "Docs", url: endpoint.absoluteString)
        let client = MCPHTTPClient(configuration: configuration, timeout: 2, session: makeSession())
        let tools = try await client.start()
        let tool = try XCTUnwrap(tools.first)
        let result = try await client.call(tool: tool, arguments: "{\"text\":\"hi\"}") { _, _ in .allowOnce }
        XCTAssertTrue(result.contains("from-sse"))
        XCTAssertEqual(log.methods.last, "tools/call")
        client.stop()
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MCPHTTPProtocol.self]
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 2
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    private enum CallBody { case json, sse }

    private func registerJSON(endpoint raw: String, log: CallLog, call: CallBody) throws -> URL {
        let endpoint = try XCTUnwrap(MCPServerConfiguration.acceptedURL(raw))
        MCPHTTPProtocol.register(endpoint.absoluteString) { request in
            let data = MCPHTTPProtocol.body(of: request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let method = json?["method"] as? String ?? ""
            log.add(method: method,
                    session: request.value(forHTTPHeaderField: "Mcp-Session-Id"),
                    protocolVersion: request.value(forHTTPHeaderField: "MCP-Protocol-Version"))
            if method == "notifications/initialized" {
                return MCPHTTPProtocol.Reply(status: 202, headers: [:], body: Data())
            }
            let id = json?["id"] as? Int ?? 0
            if method == "tools/call", call == .sse {
                let body = """
                : ping
                event: message
                data: {"jsonrpc":"2.0","method":"notifications/progress","params":{}}

                data: {"jsonrpc":"2.0","id":\(id),"result":{"content":[{"type":"text","text":"from-sse"}]}}

                """
                return MCPHTTPProtocol.Reply(status: 200, headers: ["Content-Type": "text/event-stream"], body: Data(body.utf8))
            }
            let result: [String: Any]
            switch method {
            case "initialize":
                let info: [String: Any] = ["name": "stub", "version": "1"]
                result = ["protocolVersion": "2025-03-26", "capabilities": [String: Any](), "serverInfo": info]
            case "tools/list":
                let textSchema: [String: Any] = ["type": "string"]
                let properties: [String: Any] = ["text": textSchema]
                let schema: [String: Any] = [
                    "type": "object",
                    "properties": properties,
                    "required": ["text"],
                    "additionalProperties": false,
                ]
                let tool: [String: Any] = ["name": "echo", "inputSchema": schema]
                result = ["tools": [tool]]
            case "tools/call":
                let content: [String: Any] = ["type": "text", "text": "hello"]
                result = ["content": [content]]
            default:
                return MCPHTTPProtocol.Reply(status: 400, headers: [:], body: Data())
            }
            let payload: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
            let body = try JSONSerialization.data(withJSONObject: payload)
            var headers = ["Content-Type": "application/json"]
            if method == "initialize" { headers["Mcp-Session-Id"] = "sess-1" }
            return MCPHTTPProtocol.Reply(status: 200, headers: headers, body: body)
        }
        return endpoint
    }
}

/// Written from the URL loading thread and read after the client call returns.
private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storedMethods: [String] = []
    private var storedSessions: [String?] = []
    private var storedProtocols: [String?] = []
    var methods: [String] { lock.lock(); defer { lock.unlock() }; return storedMethods }
    var sessionIDs: [String?] { lock.lock(); defer { lock.unlock() }; return storedSessions }
    var protocolVersions: [String?] { lock.lock(); defer { lock.unlock() }; return storedProtocols }
    func add(method: String, session: String?, protocolVersion: String?) {
        lock.lock()
        storedMethods.append(method)
        storedSessions.append(session)
        storedProtocols.append(protocolVersion)
        lock.unlock()
    }
}
