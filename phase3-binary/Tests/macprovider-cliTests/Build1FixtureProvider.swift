import Darwin
import Foundation

/// Deterministic loopback SSE fixture. This executable performs no MLX inference.
/// It owns its listener directly so the real candidate runner can verify its PID.
struct Build1FixtureProvider {
    struct Options: Codable {
        var readyDelayMS = 0
        var tokenDelayMS = 1
        var tokenCount = 100
    }

    let binaryURL: URL
    let traceURL: URL
    let pidURL: URL
    private let optionsURL: URL

    /// Reopens only fixture-owned files; useful in a fresh XCTest child process.
    static func existing(in root: URL) throws -> Self {
        let fixture = Self(binaryURL: root.appendingPathComponent("fixture-provider"),
                           traceURL: root.appendingPathComponent("fixture-trace.jsonl"),
                           pidURL: root.appendingPathComponent("fixture.pid"),
                           optionsURL: root.appendingPathComponent("fixture-config.json"))
        guard FileManager.default.isExecutableFile(atPath: fixture.binaryURL.path) else {
            throw NSError(domain: "Build1FixtureProvider", code: 3)
        }
        _ = try JSONDecoder().decode(Options.self, from: Data(contentsOf: fixture.optionsURL))
        return fixture
    }

    static func compile(in root: URL, options: Options = Options()) throws -> Self {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let source = root.appendingPathComponent("fixture-provider.swift")
        let binary = root.appendingPathComponent("fixture-provider")
        try providerSource.write(to: source, atomically: true, encoding: .utf8)
        let log = root.appendingPathComponent("fixture-compile.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
        compiler.arguments = [source.path, "-o", binary.path]
        compiler.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                                "HOME": root.path, "TMPDIR": root.path]
        compiler.standardOutput = handle
        compiler.standardError = handle
        try compiler.run()
        compiler.waitUntilExit()
        guard compiler.terminationStatus == 0 else {
            throw NSError(domain: "Build1FixtureProvider", code: Int(compiler.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: try String(contentsOf: log, encoding: .utf8)])
        }
        let fixture = Self(binaryURL: binary,
                           traceURL: root.appendingPathComponent("fixture-trace.jsonl"),
                           pidURL: root.appendingPathComponent("fixture.pid"),
                           optionsURL: root.appendingPathComponent("fixture-config.json"))
        try fixture.writeOptions(options)
        return fixture
    }

    /// Options are read at child startup; update only after the previous child exits.
    func writeOptions(_ options: Options) throws {
        precondition(options.readyDelayMS >= 0 && options.tokenDelayMS >= 0)
        precondition((1...512).contains(options.tokenCount))
        try JSONEncoder().encode(options).write(to: optionsURL, options: .atomic)
    }

    func observations() throws -> [[String: Any]] {
        guard FileManager.default.fileExists(atPath: traceURL.path) else { return [] }
        return try String(contentsOf: traceURL, encoding: .utf8).split(separator: "\n").map {
            guard let value = try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] else {
                throw NSError(domain: "Build1FixtureProvider", code: 2)
            }
            return value
        }
    }

    /// A port reservation hint only: callers still handle a subsequent bind race.
    static func unusedPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private static let providerSource = #"""
import Darwin
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let args = Array(CommandLine.arguments.dropFirst())
func argument(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return nil }
    return args[i + 1]
}
guard args.first == "serve", args.contains("--no-join"),
      let model = argument("--model"), let port = Int(argument("--port") ?? ""),
      (1...65535).contains(port) else { exit(2) }
let options = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("fixture-config.json"))) as! [String: Int]
let traceFD = open(root.appendingPathComponent("fixture-trace.jsonl").path, O_CREAT | O_WRONLY | O_APPEND, 0o600)
guard traceFD >= 0 else { exit(3) }
func record(_ fields: [String: Any]) {
    var value = fields
    value["pid"] = getpid()
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) + Data([10])
    data.withUnsafeBytes { _ = write(traceFD, $0.baseAddress, $0.count) }
    fsync(traceFD)
}
// Fixed bytes and write/_exit only in the signal handler.
let terminationLine = strdup("{\"event\":\"terminated\"}\n")!
signal(SIGPIPE, SIG_IGN)
signal(SIGTERM) { _ in
    _ = write(traceFD, terminationLine, 23)
    _exit(0)
}
try String(getpid()).write(to: root.appendingPathComponent("fixture.pid"), atomically: true, encoding: .utf8)
record(["event": "start", "args": args, "model": model])
if let expectedParent = argument("--candidate-parent-pid").flatMap(Int32.init) {
    guard expectedParent > 1 else { exit(2) }
    Thread.detachNewThread {
        while true {
            if getppid() != expectedParent {
                record(["event": "parent_exited"])
                _exit(0)
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}
let fd = socket(AF_INET, SOCK_STREAM, 0)
guard fd >= 0 else { exit(4) }
var yes: Int32 = 1
setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
var address = sockaddr_in()
address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
address.sin_family = sa_family_t(AF_INET)
address.sin_port = in_port_t(port).bigEndian
address.sin_addr.s_addr = inet_addr("127.0.0.1")
let bound = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
}
guard bound == 0, listen(fd, 16) == 0 else { record(["event": "bind_failed"]); exit(5) }
Thread.sleep(forTimeInterval: Double(options["readyDelayMS"] ?? 0) / 1000)
record(["event": "ready", "port": port])
func send(_ text: String, to client: Int32) -> Bool {
    let data = Data(text.utf8)
    return data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = write(client, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if count <= 0 { return false }
            offset += count
        }
        return true
    }
}
while true {
    let client = accept(fd, nil, nil)
    if client < 0 { continue }
    var receiveTimeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))
    var request = Data()
    var buffer = [UInt8](repeating: 0, count: 8192)
    while request.count < 2_000_000 {
        let count = read(client, &buffer, buffer.count)
        if count <= 0 { break }
        request.append(contentsOf: buffer.prefix(count))
        if let split = request.range(of: Data("\r\n\r\n".utf8)) {
            let headers = String(decoding: request[..<split.lowerBound], as: UTF8.self)
            let contentLength = headers.components(separatedBy: "\r\n").first {
                $0.lowercased().hasPrefix("content-length:")
            }.flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) } ?? 0
            if request.count - split.upperBound >= contentLength { break }
        }
    }
    let firstLine = String(decoding: request.prefix(512), as: UTF8.self).components(separatedBy: "\r\n")[0]
    if firstLine.hasPrefix("POST /v1/chat/completions ") {
        record(["event": "chat", "model": model])
        _ = send("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n", to: client)
        var sent = 0
        for _ in 0..<(options["tokenCount"] ?? 100) {
            Thread.sleep(forTimeInterval: Double(options["tokenDelayMS"] ?? 1) / 1000)
            if !send("data: {\"choices\":[{\"delta\":{\"content\":\"x\"}}]}\n\n", to: client) { break }
            sent += 1
        }
        // No provider timing override: Stage1 measures actual streamed wall time.
        _ = send("data: {\"choices\":[],\"usage\":{\"completion_tokens\":\(sent)}}\n\ndata: [DONE]\n\n", to: client)
        record(["event": "chat_finished", "chunks": sent])
    } else {
        let body = try! JSONSerialization.data(withJSONObject: ["object": "list", "data": [["id": model, "object": "model", "owned_by": "build1-fixture"]]])
        _ = send("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n" + String(decoding: body, as: UTF8.self), to: client)
    }
    close(client)
}
"""#
}
