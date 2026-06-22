import CryptoKit
import Darwin
import Foundation
import MacProviderCore
import NIO
import NIOHTTP1
import XCTest
@testable import macprovider_cli

final class HTTPServerReceiptTests: XCTestCase {
    func testHTTPNonStreamingHandlerWritesReceiptHeaderOnSuccess() async throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        let response = try await roundTripChatCompletion(
            body: [
                "model": "fixture-model",
                "messages": [["role": "user", "content": "hello"]],
            ],
            receiptBuilder: ReceiptBuilder(keyStore: HTTPFixedReceiptKeyStore(key: key)),
            completion: CompletionResult(
                content: "answer",
                finishReason: "stop",
                promptTokens: 1,
                completionTokens: 2,
                ttftMilliseconds: 7
            )
        )

        let header = try XCTUnwrap(response.headers.first(name: RouterHandler.receiptHeaderName))
        let parsed = try parseReceiptHeader(header)

        XCTAssertEqual(response.status, .ok, response.body)
        XCTAssertEqual(parsed.tuple["tokens_out"] as? Int, 2)
        XCTAssertEqual(parsed.tuple["ttft_ms"] as? Int, 7)
        XCTAssertTrue(response.body.contains(#""content":"answer""#), response.body)
        XCTAssertTrue(parsed.publicKey.isValidSignature(parsed.signature, for: parsed.tupleData))
    }

    func testHTTPPreKeypairOmissionDoesNotFailResponse() async throws {
        let response = try await roundTripChatCompletion(
            body: [
                "model": "fixture-model",
                "messages": [["role": "user", "content": "hello"]],
            ],
            receiptBuilder: ReceiptBuilder(keyStore: HTTPEmptyReceiptKeyStore()),
            completion: CompletionResult(content: "answer", finishReason: "stop", promptTokens: 1, completionTokens: 1)
        )

        XCTAssertEqual(response.status, .ok, response.body)
        XCTAssertNil(response.headers.first(name: RouterHandler.receiptHeaderName))
        XCTAssertTrue(response.body.contains(#""content":"answer""#), response.body)
    }

    func testHTTPGenericInferenceFailureGetsNullUsageReceipt() async throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        let response = try await roundTripChatCompletion(
            body: [
                "model": "fixture-model",
                "messages": [["role": "user", "content": "hello"]],
            ],
            receiptBuilder: ReceiptBuilder(keyStore: HTTPFixedReceiptKeyStore(key: key)),
            completionError: HTTPReceiptFixtureError.inferenceFailed
        )
        let header = try XCTUnwrap(response.headers.first(name: RouterHandler.receiptHeaderName))
        let parsed = try parseReceiptHeader(header)

        XCTAssertEqual(response.status, .serviceUnavailable, response.body)
        XCTAssertTrue(response.body.contains(#""code":"model_not_loaded""#), response.body)
        XCTAssertEqual(parsed.tuple["tokens_out"] as? Int, 0)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(parsed.tuple["ttft_ms"] as? Int), 0)
        XCTAssertEqual(
            parsed.tuple["output_hash"] as? String,
            try OutputCanonicalizer.outputHash(content: "", toolCalls: nil, finishReason: "error")
        )
        XCTAssertTrue(parsed.publicKey.isValidSignature(parsed.signature, for: parsed.tupleData))
    }

    func testHTTPEarlyModelNotLoadedValidationGetsNullUsageReceipt() async throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        let response = try await roundTripChatCompletion(
            body: [
                "model": "fixture-model",
                "messages": [["role": "user", "content": "hello"]],
            ],
            routerModelID: nil,
            receiptBuilder: ReceiptBuilder(keyStore: HTTPFixedReceiptKeyStore(key: key)),
            completion: CompletionResult(content: "answer", finishReason: "stop", promptTokens: 1, completionTokens: 1)
        )
        let header = try XCTUnwrap(response.headers.first(name: RouterHandler.receiptHeaderName))
        let parsed = try parseReceiptHeader(header)

        XCTAssertEqual(response.status, .serviceUnavailable, response.body)
        XCTAssertTrue(response.body.contains(#""code":"model_not_loaded""#), response.body)
        XCTAssertEqual(parsed.tuple["tokens_out"] as? Int, 0)
        XCTAssertEqual(
            parsed.tuple["output_hash"] as? String,
            try OutputCanonicalizer.outputHash(content: "", toolCalls: nil, finishReason: "error")
        )
        XCTAssertTrue(parsed.publicKey.isValidSignature(parsed.signature, for: parsed.tupleData))
    }

    func testHTTPStreamingHandlerWritesNoMacProviderHeaders() async throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        let response = try await roundTripChatCompletion(
            body: [
                "model": "fixture-model",
                "messages": [["role": "user", "content": "hello"]],
                "stream": true,
            ],
            receiptBuilder: ReceiptBuilder(keyStore: HTTPFixedReceiptKeyStore(key: key)),
            completion: CompletionResult(content: "chunk", finishReason: "stop", promptTokens: 1, completionTokens: 1)
        )

        XCTAssertEqual(response.status, .ok, response.body)
        XCTAssertEqual(response.headers.first(name: "content-type"), "text/event-stream; charset=utf-8")
        XCTAssertFalse(response.headers.contains(name: RouterHandler.receiptHeaderName))
        XCTAssertFalse(response.headers.containsMacProviderHeader)
    }

    func testNonStreamingReceiptHeaderParsesAndSelfVerifies() throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        let request = try parseRequest([
            "model": "fixture-model",
            "messages": [
                [
                    "role": "user",
                    "content": "hello",
                ],
            ],
            "temperature": 0,
        ])
        let header = try XCTUnwrap(RouterHandler.receiptHeader(
            providerID: "provider-a",
            receiptBuilder: ReceiptBuilder(keyStore: HTTPFixedReceiptKeyStore(key: key)),
            request: request,
            outputContent: "answer",
            outputToolCalls: nil,
            finishReason: "stop",
            ttftMs: 12,
            tokensOut: 2,
            unixTsSeconds: 1_800_000_000
        ))
        let parsed = try parseReceiptHeader(header)

        XCTAssertLessThanOrEqual(header.utf8.count, RouterHandler.maxReceiptHeaderBytes)
        XCTAssertEqual(parsed.tuple["model_id"] as? String, "fixture-model")
        XCTAssertEqual(parsed.tuple["tokens_out"] as? Int, 2)
        XCTAssertEqual(parsed.tuple["ttft_ms"] as? Int, 12)
        XCTAssertEqual(parsed.tuple["unix_ts"] as? Int, 1_800_000_000)
        XCTAssertEqual(
            parsed.tuple["output_hash"] as? String,
            try OutputCanonicalizer.outputHash(content: "answer", toolCalls: nil, finishReason: "stop")
        )
        XCTAssertEqual(parsed.signature.count, 64)
        XCTAssertTrue(parsed.publicKey.isValidSignature(parsed.signature, for: parsed.tupleData))
    }

    func testPreKeypairReceiptHeaderIsOmittedWithout500() throws {
        let request = try parseRequest([
            "model": "fixture-model",
            "messages": [
                [
                    "role": "user",
                    "content": "hello",
                ],
            ],
        ])

        let header = try RouterHandler.receiptHeader(
            providerID: "provider-a",
            receiptBuilder: ReceiptBuilder(keyStore: HTTPEmptyReceiptKeyStore()),
            request: request,
            outputContent: "answer",
            outputToolCalls: nil,
            finishReason: "stop",
            ttftMs: 1,
            tokensOut: 1,
            unixTsSeconds: 1
        )

        XCTAssertNil(header)
    }

    func testNullUsageModelNotLoadedErrorGetsReceiptHeader() throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        let request = try parseRequest([
            "model": "fixture-model",
            "messages": [
                [
                    "role": "user",
                    "content": "hello",
                ],
            ],
        ])
        let error = APIError(
            status: 503,
            message: "Model not loaded",
            type: "server_error",
            code: "model_not_loaded"
        )

        let header = try XCTUnwrap(RouterHandler.errorReceiptHeader(
            providerID: "provider-a",
            receiptBuilder: ReceiptBuilder(keyStore: HTTPFixedReceiptKeyStore(key: key)),
            request: request,
            error: error,
            startedAt: Date(timeIntervalSince1970: 1_800_000_000)
        ))
        let parsed = try parseReceiptHeader(header)

        XCTAssertEqual(parsed.tuple["tokens_out"] as? Int, 0)
        XCTAssertEqual(
            parsed.tuple["output_hash"] as? String,
            try OutputCanonicalizer.outputHash(content: "", toolCalls: nil, finishReason: "error")
        )
        XCTAssertTrue(parsed.publicKey.isValidSignature(parsed.signature, for: parsed.tupleData))
    }

    func testNonNullUsageErrorsDoNotGetReceiptHeader() throws {
        let request = try parseRequest([
            "model": "fixture-model",
            "messages": [
                [
                    "role": "user",
                    "content": "hello",
                ],
            ],
        ])
        let error = APIError(
            status: 503,
            message: "Provider loading",
            type: "service_unavailable",
            code: "provider_loading"
        )

        let header = try RouterHandler.errorReceiptHeader(
            providerID: "provider-a",
            receiptBuilder: ReceiptBuilder(keyStore: HTTPFixedReceiptKeyStore(
                key: Curve25519.Signing.PrivateKey()
            )),
            request: request,
            error: error,
            startedAt: Date()
        )

        XCTAssertNil(header)
    }

    func testWorstCaseModelIDHeaderStaysUnder4096Bytes() throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        let modelID = String(repeating: "m", count: 512)
        let request = try parseRequest([
            "model": modelID,
            "messages": [
                [
                    "role": "user",
                    "content": "hello",
                ],
            ],
        ])

        let header = try XCTUnwrap(RouterHandler.receiptHeader(
            providerID: "provider-a",
            receiptBuilder: ReceiptBuilder(keyStore: HTTPFixedReceiptKeyStore(key: key)),
            request: request,
            outputContent: "answer",
            outputToolCalls: nil,
            finishReason: "stop",
            ttftMs: 1,
            tokensOut: 1,
            unixTsSeconds: 1
        ))

        XCTAssertLessThanOrEqual(header.utf8.count, RouterHandler.maxReceiptHeaderBytes)
    }

    func testJSONHeadersCanCarryReceiptBeforeBodyWrite() {
        let headers = makeJSONResponseHeaders(
            dataLength: 2,
            extraHeaders: [(RouterHandler.receiptHeaderName, "tuple.signature")]
        )

        XCTAssertEqual(headers.first(name: "content-type"), "application/json")
        XCTAssertEqual(headers.first(name: "content-length"), "2")
        XCTAssertEqual(headers.first(name: "connection"), "close")
        XCTAssertEqual(headers.first(name: RouterHandler.receiptHeaderName), "tuple.signature")
    }

    func testStreamingHeadersStayReceiptFreeAndByteStable() {
        let headers = makeSSEResponseHeaders()

        XCTAssertEqual(headers.first(name: "content-type"), "text/event-stream; charset=utf-8")
        XCTAssertEqual(headers.first(name: "cache-control"), "no-cache")
        XCTAssertEqual(headers.first(name: "connection"), "close")
        XCTAssertEqual(headers.first(name: "transfer-encoding"), "chunked")
        XCTAssertFalse(headers.contains(name: RouterHandler.receiptHeaderName))
        XCTAssertFalse(headers.containsMacProviderHeader)
        XCTAssertEqual(headers.canonicalPairs, [
            "content-type: text/event-stream; charset=utf-8",
            "cache-control: no-cache",
            "connection: close",
            "transfer-encoding: chunked",
        ])
    }
}

private struct ParsedReceipt {
    let tupleData: Data
    let tuple: [String: Any]
    let signature: Data
    let publicKey: Curve25519.Signing.PublicKey
}

private struct HTTPReceiptResponse {
    let status: HTTPResponseStatus
    let headers: HTTPHeaders
    let body: String
}

private enum HTTPReceiptFixtureError: Error {
    case inferenceFailed
}

private func roundTripChatCompletion(
    body: [String: Any],
    routerModelID: String? = "fixture-model",
    providerID: String? = "provider-a",
    receiptBuilder: ReceiptBuilder?,
    completion: CompletionResult? = nil,
    completionError: Error? = nil
) async throws -> HTTPReceiptResponse {
    let runtime = ModelRuntime(
        modelID: "fixture-model",
        warmSwapEnabled: false,
        loader: { _ in throw HTTPReceiptFixtureError.inferenceFailed },
        testCompletion: { _, _ in
            if let completionError {
                throw completionError
            }
            return completion ?? CompletionResult(
                content: "answer",
                finishReason: "stop",
                promptTokens: 1,
                completionTokens: 1
            )
        }
    )
    let status = ProviderStatus(
        modelID: "fixture-model",
        modelLoaded: true,
        capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: nil)
    )
    return try await withReceiptHTTPServer(
        runtime: runtime,
        providerStatus: status,
        providerID: providerID,
        routerModelID: routerModelID,
        receiptBuilder: receiptBuilder
    ) { port in
        try rawChatCompletionRoundTrip(port: port, body: body, headerOnly: body["stream"] as? Bool == true)
    }
}

private func withReceiptHTTPServer<T>(
    runtime: ModelRuntime,
    providerStatus: ProviderStatus,
    providerID: String?,
    routerModelID: String? = "fixture-model",
    receiptBuilder: ReceiptBuilder?,
    operation: (Int) throws -> T
) async throws -> T {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let bootstrap = ServerBootstrap(group: group)
        .serverChannelOption(ChannelOptions.backlog, value: 16)
        .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        .childChannelInitializer { channel in
            channel.pipeline.configureHTTPServerPipeline().flatMap {
                channel.pipeline.addHandler(RouterHandler(
                    modelID: routerModelID,
                    providerID: providerID,
                    coordinatorURL: nil,
                    modelRuntime: runtime,
                    providerStatus: providerStatus,
                    warmSwapEnabled: false,
                    maxBodyBytes: 1_000_000,
                    receiptBuilder: receiptBuilder
                ))
            }
        }
        .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
    let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
    do {
        let port = try XCTUnwrap(channel.localAddress?.port)
        let result = try operation(port)
        try await channel.close().get()
        try await group.shutdownGracefully()
        return result
    } catch {
        try? await channel.close().get()
        try? await group.shutdownGracefully()
        throw error
    }
}

private func rawChatCompletionRoundTrip(
    port: Int,
    body: [String: Any],
    headerOnly: Bool
) throws -> HTTPReceiptResponse {
    let bodyData = try JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes])
    let requestHead = "POST /v1/chat/completions HTTP/1.1\r\n"
        + "Host: 127.0.0.1:\(port)\r\n"
        + "Content-Type: application/json\r\n"
        + "Content-Length: \(bodyData.count)\r\n"
        + "Connection: close\r\n"
        + "\r\n"
    var requestData = Data(requestHead.utf8)
    requestData.append(bodyData)

    let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    XCTAssertGreaterThanOrEqual(descriptor, 0)
    defer { close(descriptor) }
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(port).bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let connectResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    XCTAssertEqual(connectResult, 0)

    try requestData.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress else { return }
        var sent = 0
        while sent < requestData.count {
            let count = Darwin.send(descriptor, base.advanced(by: sent), requestData.count - sent, 0)
            if count <= 0 {
                throw POSIXError(.EIO)
            }
            sent += count
        }
    }

    var response = Data()
    var scratch = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = Darwin.recv(descriptor, &scratch, scratch.count, 0)
        if count < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK {
                throw POSIXError(.ETIMEDOUT)
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if count == 0 {
            break
        }
        response.append(scratch, count: count)
        if let range = String(decoding: response, as: UTF8.self).range(of: "\r\n\r\n") {
            if headerOnly {
                break
            }
            let raw = String(decoding: response, as: UTF8.self)
            let headers = String(raw[..<range.lowerBound])
            let expectedLength = contentLength(from: headers)
            let body = raw[range.upperBound...]
            if let expectedLength, body.utf8.count >= expectedLength {
                break
            }
        }
    }

    return try parseRawHTTPResponse(response)
}

private func contentLength(from headerText: String) -> Int? {
    for line in headerText.split(separator: "\r\n") {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let name = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.lowercased() == "content-length" else { continue }
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(value)
    }
    return nil
}

private func parseRawHTTPResponse(_ data: Data) throws -> HTTPReceiptResponse {
    let raw = String(decoding: data, as: UTF8.self)
    let separator = try XCTUnwrap(raw.range(of: "\r\n\r\n"))
    let headerText = String(raw[..<separator.lowerBound])
    let body = String(raw[separator.upperBound...])
    let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
    let statusLine = try XCTUnwrap(lines.first)
    let statusParts = statusLine.split(separator: " ")
    let code = try XCTUnwrap(Int(statusParts[1]))
    var headers = HTTPHeaders()
    for line in lines.dropFirst() {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let name = String(line[..<colon])
        let valueStart = line.index(after: colon)
        let value = String(line[valueStart...]).trimmingCharacters(in: .whitespaces)
        headers.add(name: name, value: value)
    }
    return HTTPReceiptResponse(
        status: HTTPResponseStatus(statusCode: code),
        headers: headers,
        body: body
    )
}

private func parseReceiptHeader(_ header: String) throws -> ParsedReceipt {
    let pieces = header.split(separator: ".")
    XCTAssertEqual(pieces.count, 2)
    let tupleData = try XCTUnwrap(Data(base64Encoded: String(pieces[0])))
    let signature = try XCTUnwrap(Data(base64Encoded: String(pieces[1])))
    let tuple = try XCTUnwrap(JSONSerialization.jsonObject(with: tupleData) as? [String: Any])
    let pubkey = try XCTUnwrap(tuple["provider_pubkey"] as? String)
    let pubkeyData = try XCTUnwrap(Data(base64Encoded: pubkey))
    return ParsedReceipt(
        tupleData: tupleData,
        tuple: tuple,
        signature: signature,
        publicKey: try Curve25519.Signing.PublicKey(rawRepresentation: pubkeyData)
    )
}

private final class HTTPFixedReceiptKeyStore: ReceiptKeyStoring, @unchecked Sendable {
    private let key: Curve25519.Signing.PrivateKey

    init(key: Curve25519.Signing.PrivateKey) {
        self.key = key
    }

    func loadOrGenerate(providerId: String) throws -> Curve25519.Signing.PrivateKey {
        key
    }

    func loadCurrent(providerId: String) throws -> Curve25519.Signing.PrivateKey? {
        key
    }

    func storeNew(providerId: String, privateKey: Curve25519.Signing.PrivateKey) throws {}

    func swapToCurrent(providerId: String, newKey: Curve25519.Signing.PrivateKey) throws {}
}

private final class HTTPEmptyReceiptKeyStore: ReceiptKeyStoring, @unchecked Sendable {
    func loadOrGenerate(providerId: String) throws -> Curve25519.Signing.PrivateKey {
        Curve25519.Signing.PrivateKey()
    }

    func loadCurrent(providerId: String) throws -> Curve25519.Signing.PrivateKey? {
        nil
    }

    func storeNew(providerId: String, privateKey: Curve25519.Signing.PrivateKey) throws {}

    func swapToCurrent(providerId: String, newKey: Curve25519.Signing.PrivateKey) throws {}
}

private extension HTTPHeaders {
    var containsMacProviderHeader: Bool {
        contains { name, _ in
            name.lowercased().hasPrefix("x-macprovider-")
        }
    }

    var canonicalPairs: [String] {
        map { "\($0.name.lowercased()): \($0.value)" }
    }
}
