import Foundation
import Network
import XCTest
@testable import macprovider_cli

// SPEC-001-R012: the provider's coordinator WebSocket accepts messages up to
// the limit it advertises. Foundation's 1 MiB default made a ~784 KB prompt's
// sealed inference_request (about 1.07 MB on the wire) fail the receive and
// tear the session down.
final class CoordinatorWebSocketMessageLimitTests: XCTestCase {
    func testCoordinatorTaskUsesAdvertisedMessageLimit() throws {
        let request = URLRequest(url: try XCTUnwrap(URL(string: "ws://127.0.0.1:9/ws/provider")))
        let task = makeCoordinatorWebSocketTask(request)
        defer { task.cancel(with: .goingAway, reason: nil) }
        XCTAssertEqual(coordinatorWebSocketMaximumMessageBytes, 64 * 1024 * 1024)
        XCTAssertEqual(task.maximumMessageSize, coordinatorWebSocketMaximumMessageBytes)
        XCTAssertGreaterThan(task.maximumMessageSize, 1024 * 1024)
    }

    // A message larger than Foundation's old 1 MiB default, the size class of
    // the live failure, now arrives intact on a production-configured task.
    func testMessageOverLegacyDefaultIsReceived() async throws {
        let size = 2 * 1024 * 1024
        let server = try LoopbackWebSocketServer(messageSizes: [size])
        let port = try await server.start()
        defer { server.stop() }
        let task = makeCoordinatorWebSocketTask(URLRequest(url: try XCTUnwrap(URL(string: "ws://127.0.0.1:\(port)/"))))
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }
        let message = try await task.receive()
        guard case .string(let text) = message else {
            return XCTFail("expected a text message")
        }
        XCTAssertEqual(text.utf8.count, size)
    }

    // The limit is exact: a message of exactly the limit is received; one byte
    // more fails the task. URLSessionWebSocketTask cannot skip one message and
    // keep the session, which is why the coordinator refuses to write an
    // over-limit frame (SPEC-001-R012).
    func testLimitBoundaryAcceptsAtLimitAndRejectsOneByteOver() async throws {
        let limit = 4 * 1024 * 1024
        let server = try LoopbackWebSocketServer(messageSizes: [limit, limit + 1])
        let port = try await server.start()
        defer { server.stop() }
        let task = makeCoordinatorWebSocketTask(
            URLRequest(url: try XCTUnwrap(URL(string: "ws://127.0.0.1:\(port)/"))),
            maximumMessageSize: limit
        )
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }
        let first = try await task.receive()
        guard case .string(let text) = first else {
            return XCTFail("expected a text message")
        }
        XCTAssertEqual(text.utf8.count, limit)
        do {
            _ = try await task.receive()
            XCTFail("an over-limit message must fail the receive")
        } catch {
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, NSPOSIXErrorDomain)
            XCTAssertEqual(nsError.code, Int(EMSGSIZE))
        }
    }
}

/// A loopback WebSocket server that sends one text message of each size, in
/// order, to every client.
private final class LoopbackWebSocketServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "coordinator-ws-message-limit-tests")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var startContinuation: CheckedContinuation<Int, Error>?
    private let messageSizes: [Int]

    init(messageSizes: [Int]) throws {
        self.messageSizes = messageSizes
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        options.maximumMessageSize = 128 * 1024 * 1024
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> Int {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            lock.lock()
            startContinuation = continuation
            lock.unlock()
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.resumeStart(.success(Int(self.listener.port?.rawValue ?? 0)))
                case .failed(let error):
                    self.resumeStart(.failure(error))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                self.lock.lock()
                self.connections.append(connection)
                self.lock.unlock()
                connection.stateUpdateHandler = { [weak self] state in
                    if case .ready = state { self?.send(on: connection, index: 0) }
                }
                connection.start(queue: self.queue)
            }
            listener.start(queue: queue)
        }
    }

    private func resumeStart(_ result: Result<Int, Error>) {
        lock.lock()
        let continuation = startContinuation
        startContinuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    private func send(on connection: NWConnection, index: Int) {
        guard index < messageSizes.count else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        let payload = Data(repeating: UInt8(ascii: "a"), count: messageSizes[index])
        connection.send(content: payload, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.send(on: connection, index: index + 1)
        })
    }

    func stop() {
        listener.cancel()
        lock.lock()
        let open = connections
        connections.removeAll()
        lock.unlock()
        open.forEach { $0.cancel() }
    }
}
