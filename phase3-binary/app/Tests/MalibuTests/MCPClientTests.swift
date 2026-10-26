import Darwin
import Foundation
import XCTest
@testable import Malibu

@MainActor
final class MCPClientTests: XCTestCase {
    private var directories: [URL] = []
    override func tearDown() async throws {
        MCPClient.terminateAll()
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        try await super.tearDown()
    }

    private func server(_ mode: String = "normal", timeout: TimeInterval = 2,
                        limit: Int = 65536, lifetime: TimeInterval = 30) throws -> (MCPClient, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let script = directory.appendingPathComponent("server.py")
        try Data(Self.script.utf8).write(to: script)
        var configuration = MCPServerConfiguration()
        configuration.name = "Test server"
        configuration.command = "/usr/bin/python3"
        configuration.arguments = ["-u", script.path, mode]
        configuration.environment = ["MCP_TEST_MARKER": directory.appendingPathComponent("calls").path,
                                     "MCP_TEST_CHILD": directory.appendingPathComponent("child").path,
                                     "MCP_TEST_VALUE": "explicit"]
        return (MCPClient(configuration: configuration, timeout: timeout, lifetime: lifetime, messageLimit: limit), directory)
    }

    func testHandshakeListCallAndSanitizedEnvironment() async throws {
        let (client, directory) = try server()
        let tools = try await client.start()
        XCTAssertEqual(tools.count, 1)
        let tool = try XCTUnwrap(tools.first)
        XCTAssertTrue(tool.name.hasPrefix("mcp_"))
        XCTAssertLessThanOrEqual(tool.name.count, 64)
        XCTAssertEqual(tool.originalName, "echo")
        XCTAssertEqual(tool.serverName, "Test server")
        let result = try await client.call(tool: tool, arguments: "{\"text\":\"hello\"}") { _, _ in .allowOnce }
        XCTAssertTrue(result.contains("hello"))
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("calls")), "call\n")
        client.stop()
    }

    func testDenyExecutesNothingAndSessionAllowAsksOnlyOnce() async throws {
        let (client, directory) = try server()
        let tools = try await client.start()
        let tool = try XCTUnwrap(tools.first)
        do {
            _ = try await client.call(tool: tool, arguments: "{\"text\":\"denied\"}") { _, _ in .deny }
            XCTFail("Denied tool executed")
        } catch { XCTAssertEqual(error as? MCPFailure, .denied) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("calls").path))
        var approvals = 0
        for _ in 0..<2 {
            _ = try await client.call(tool: tool, arguments: "{\"text\":\"allowed\"}") { _, _ in
                approvals += 1
                return .allowSession
            }
        }
        XCTAssertEqual(approvals, 1)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("calls")), "call\ncall\n")
        client.stop()
    }

    func testAllowOnceAsksAgainAndInvalidArgumentsNeverExecute() async throws {
        let (client, directory) = try server()
        let tools = try await client.start()
        let tool = try XCTUnwrap(tools.first)
        var approvals = 0
        for _ in 0..<2 {
            _ = try await client.call(tool: tool, arguments: "{\"text\":\"a\"}") { _, _ in
                approvals += 1; return .allowOnce
            }
        }
        XCTAssertEqual(approvals, 2)
        for arguments in ["{}", "{\"text\":2}", "{\"text\":\"a\",\"extra\":true}"] {
            do {
                _ = try await client.call(tool: tool, arguments: arguments) { _, _ in XCTFail("Invalid args reached approval"); return .allowOnce }
                XCTFail("Invalid args accepted")
            } catch { XCTAssertEqual(error as? MCPFailure, .invalidArguments) }
        }
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("calls")), "call\ncall\n")
        client.stop()
    }

    func testTimeoutStopsServerAndRejectsFurtherExecution() async throws {
        try await assertStartFailure("timeout", expected: .timeout, timeout: 0.15)
    }
    func testOversizeMessageStopsServer() async throws {
        try await assertStartFailure("oversize", expected: .oversize, limit: 1024)
    }
    func testMalformedJSONStopsServer() async throws {
        try await assertStartFailure("malformed", expected: .malformed)
    }
    func testMalformedJSONRPCStopsServer() async throws {
        try await assertStartFailure("bad_rpc", expected: .malformed)
    }
    func testServerCrashStopsSession() async throws {
        try await assertStartFailure("crash", expected: .serverExited)
    }
    func testUnsupportedArgumentSchemaStopsSession() async throws {
        try await assertStartFailure("bad_schema", expected: .invalidArguments)
    }
    func testMissingCommandShowsStartFailure() async throws {
        var configuration = MCPServerConfiguration()
        configuration.command = "/no/such/mcp/server"
        let client = MCPClient(configuration: configuration)
        do { _ = try await client.start(); XCTFail("Missing server started") }
        catch { XCTAssertEqual(error as? MCPFailure, .unavailable) }
    }

    func testCallTimeoutTerminatesServer() async throws {
        let (client, _) = try server("call_timeout", timeout: 0.2)
        let tools = try await client.start()
        do {
            _ = try await client.call(tool: XCTUnwrap(tools.first), arguments: "{\"text\":\"a\"}") { _, _ in .allowOnce }
            XCTFail("Hung call returned")
        } catch { XCTAssertEqual(error as? MCPFailure, .timeout) }
        XCTAssertEqual(client.processIdentifier, 0)
    }

    func testProcessGroupKilledOnSessionEnd() async throws {
        let (client, directory) = try server("child")
        _ = try await client.start()
        let childFile = directory.appendingPathComponent("child")
        let child = try XCTUnwrap(Int32(String(contentsOf: childFile).trimmingCharacters(in: .whitespacesAndNewlines)))
        let parent = client.processIdentifier
        XCTAssertEqual(getpgid(child), parent)
        client.stop()
        for _ in 0..<200 {
            if kill(parent, 0) == -1 && kill(child, 0) == -1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(kill(parent, 0), -1)
        XCTAssertEqual(kill(child, 0), -1)
    }

    func testServerLifetimeIsBoundedAndQuitKillsAll() async throws {
        let (client, _) = try server(lifetime: 0.2)
        _ = try await client.start()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(client.processIdentifier, 0)
        let (other, _) = try server()
        _ = try await other.start()
        MCPClient.terminateAll()
        XCTAssertEqual(other.processIdentifier, 0)
    }

    func testInteractiveContinuationRestartsExpiredClientAndRequiresFreshPermission() async throws {
        let (template, directory) = try server()
        var created: [MCPClient] = []
        let transport = MCPExpiryTransport()
        let session = AgentSession(transport: AgentModelTransport(local: transport, port: { 9042 }), makeClient: { configuration in
            let client = MCPClient(configuration: configuration, lifetime: created.isEmpty ? 1 : 30)
            created.append(client)
            return client
        })
        defer { session.cancel() }
        var agent = AgentDefinition(); agent.servers = [template.configuration]
        let first = Task { try await session.run(agent: agent, prompt: "first") }
        for _ in 0..<500 where session.pendingApproval == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNotNil(session.pendingApproval)
        session.resolveApproval(.allowSession)
        _ = try await first.value
        XCTAssertEqual(created.count, 1)
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertFalse(try XCTUnwrap(created.first).isRunning)
        let second = Task { try await session.run(agent: agent, prompt: "continue") }
        for _ in 0..<500 where session.pendingApproval == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(created.count, 2)
        XCTAssertTrue(try XCTUnwrap(created.last).isRunning)
        XCTAssertNotNil(session.pendingApproval, "Expired session permission must not authorize the new process")
        session.resolveApproval(.deny)
        do { _ = try await second.value; XCTFail("Fresh tool permission was denied") }
        catch { XCTAssertEqual(error as? MCPFailure, .denied) }
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("calls")), "call\n")
    }

    func testCancellationEndsInFlightRequest() async throws {
        let (client, _) = try server("timeout", timeout: 3)
        let operation = Task { try await client.start() }
        try await Task.sleep(for: .milliseconds(100))
        operation.cancel()
        do { _ = try await operation.value; XCTFail("Cancelled request returned") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(client.processIdentifier, 0)
    }

    func testSchemaRejectsUnsupportedKeywordsAndBooleanNumbers() throws {
        XCTAssertThrowsError(try MCPArgumentSchema.check(["type": "object", "$ref": "file:///tmp/schema"]))
        let schema: [String: Any] = ["type": "object", "properties": ["n": ["type": "integer"]], "required": ["n"]]
        let boolean = try JSONSerialization.jsonObject(with: Data("{\"n\":true}".utf8))
        XCTAssertThrowsError(try MCPArgumentSchema.validate(boolean, schema: schema))
    }

    private func assertStartFailure(_ mode: String, expected: MCPFailure,
                                    timeout: TimeInterval = 2, limit: Int = 65536) async throws {
        let (client, _) = try server(mode, timeout: timeout, limit: limit)
        do { _ = try await client.start(); XCTFail("Bad server started") }
        catch { XCTAssertEqual(error as? MCPFailure, expected) }
        XCTAssertEqual(client.processIdentifier, 0)
        do { _ = try await client.start(); XCTFail("Failed server restarted") }
        catch { XCTAssertEqual(error as? MCPFailure, .unavailable) }
    }

    private static let script = #"""
import json, os, subprocess, sys, time
mode = sys.argv[1]
if mode == 'crash': sys.exit(7)
if mode == 'timeout': time.sleep(20)
if mode == 'oversize':
    sys.stdout.write('x' * 100000 + '\n'); sys.stdout.flush(); time.sleep(20)
if mode == 'malformed':
    print('not json', flush=True); time.sleep(20)
child = None
if mode == 'child':
    child = subprocess.Popen(['/bin/sleep', '600'])
    with open(os.environ['MCP_TEST_CHILD'], 'w') as f: f.write(str(child.pid))
initialized = False
for line in sys.stdin:
    request = json.loads(line)
    method = request['method']
    if method == 'notifications/initialized':
        initialized = True
        continue
    if mode == 'bad_rpc':
        print(json.dumps({'jsonrpc': '1.0', 'id': request['id'], 'result': {}}), flush=True)
        continue
    if method == 'initialize':
        assert request['params']['protocolVersion'] == '2024-11-05'
        result = {'protocolVersion': '2024-11-05', 'capabilities': {'tools': {}}, 'serverInfo': {'name': 'test', 'version': '1'}}
    elif method == 'tools/list':
        assert initialized
        schema = {'type': 'object', 'properties': {'text': {'type': 'string'}}, 'required': ['text'], 'additionalProperties': False}
        if mode == 'bad_schema': schema['$ref'] = 'file:///tmp/untrusted'
        result = {'tools': [{'name': 'echo', 'inputSchema': schema}]}
    elif method == 'tools/call':
        assert os.environ['MCP_TEST_VALUE'] == 'explicit'
        assert 'MACPROVIDER_PROVIDER_TOKEN' not in os.environ
        if mode == 'call_timeout': time.sleep(20)
        with open(os.environ['MCP_TEST_MARKER'], 'a') as f: f.write('call\n')
        result = {'content': [{'type': 'text', 'text': request['params']['arguments']['text']}]}
    else: raise Exception('Unexpected method')
    print(json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'result': result}), flush=True)
"""#
}

@MainActor
private final class MCPExpiryTransport: ChatTransport {
    func capability(at endpoint: ChatEndpoint) async throws -> ChatCapability {
        ChatCapability(model: "fixture", generation: 1, guaranteedTools: true)
    }
    func complete(at endpoint: ChatEndpoint, body: Data,
                  onText: @escaping @MainActor (String) -> Void) async throws -> ChatCompletion {
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        if messages.last?["role"] as? String == "tool" { return ChatCompletion(text: "done", calls: []) }
        let tools = try XCTUnwrap(object["tools"] as? [[String: Any]])
        let function = try XCTUnwrap(tools.first?["function"] as? [String: Any])
        let name = try XCTUnwrap(function["name"] as? String)
        return ChatCompletion(text: "", calls: [ChatToolCall(id: UUID().uuidString, name: name,
                                                           arguments: #"{"text":"hello"}"#)])
    }
}
