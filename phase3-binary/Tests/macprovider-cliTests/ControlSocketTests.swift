import Darwin
import Foundation
import XCTest
@testable import macprovider_cli

final class ControlSocketTests: XCTestCase {
    func testEncodeDecodeSwitchRequest() throws {
        try assertRoundTrip(.switchRequest(targetModelID: "model-A", requestedAtMs: 123))
    }

    func testEncodeDecodeStatusRequest() throws {
        try assertRoundTrip(.statusRequest)
    }

    func testEncodeDecodeSwitchAckAccepted() throws {
        try assertRoundTrip(.switchAck(accepted: true, reason: nil, currentTarget: nil, secondsRemaining: nil))
    }

    func testEncodeDecodeSwitchAckLoadingInProgress() throws {
        let data = try ControlSocketCodec.encode(.switchAck(
            accepted: false,
            reason: .loadingInProgress,
            currentTarget: "model-B",
            secondsRemaining: nil
        ))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""current_target":"model-B""#))
        XCTAssertEqual(try ControlSocketCodec.decode(data), .switchAck(
            accepted: false,
            reason: .loadingInProgress,
            currentTarget: "model-B",
            secondsRemaining: nil
        ))
    }

    func testEncodeDecodeSwitchAckCooldown() throws {
        let data = try ControlSocketCodec.encode(.switchAck(
            accepted: false,
            reason: .cooldown,
            currentTarget: nil,
            secondsRemaining: 7
        ))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""seconds_remaining":7"#))
        XCTAssertEqual(try ControlSocketCodec.decode(data), .switchAck(
            accepted: false,
            reason: .cooldown,
            currentTarget: nil,
            secondsRemaining: 7
        ))
    }

    func testEncodeDecodeSwitchProgressLoading() throws {
        try assertRoundTrip(.switchProgress(state: .loading, elapsedMs: 11, reason: nil))
    }

    func testEncodeDecodeSwitchProgressFailed() throws {
        let data = try ControlSocketCodec.encode(.switchProgress(state: .failed, elapsedMs: 22, reason: "oom"))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""reason":"oom""#))
        XCTAssertEqual(
            try ControlSocketCodec.decode(data),
            .switchProgress(state: .failed, elapsedMs: 22, reason: "oom")
        )
    }

    func testEncodeDecodeStatusResponseReady() throws {
        try assertRoundTrip(.statusResponse(currentModelID: "model-A", runtimeState: .ready))
    }

    func testDecodeRejectsMissingType() {
        XCTAssertThrowsError(try ControlSocketCodec.decode(Data(#"{"target_model_id":"X"}"#.utf8))) { error in
            XCTAssertEqual(error as? ControlSocketError, .missingType)
        }
    }

    func testDecodeRejectsUnknownType() {
        XCTAssertThrowsError(try ControlSocketCodec.decode(Data(#"{"type":"wat"}"#.utf8))) { error in
            XCTAssertEqual(error as? ControlSocketError, .unknownType("wat"))
        }
    }

    func testDecodeRejectsSwitchRequestMissingTarget() {
        XCTAssertThrowsError(try ControlSocketCodec.decode(Data(#"{"type":"switch_request","requested_at_ms":1}"#.utf8))) { error in
            XCTAssertEqual(error as? ControlSocketError, .missingRequiredField("target_model_id"))
        }
    }

    func testDecodeRejectsSwitchAckUnknownReason() {
        XCTAssertThrowsError(try ControlSocketCodec.decode(Data(#"{"type":"switch_ack","accepted":false,"reason":"xyz"}"#.utf8))) { error in
            XCTAssertEqual(error as? ControlSocketError, .invalidEnumValue(field: "reason", value: "xyz"))
        }
    }

    func testEncodedBytesHaveNoForwardSlashEscaping() throws {
        let data = try ControlSocketCodec.encode(.switchRequest(
            targetModelID: "mlx-community/Llama",
            requestedAtMs: 123
        ))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("mlx-community/Llama"))
        XCTAssertFalse(text.contains("mlx-community\\/Llama"))
    }

    func testServerBindsAndAcceptsConnection() async throws {
        let socketPath = try makeSocketPath()
        let runtime = makeRuntime(modelID: "ready-model")
        let server = ControlSocketServer(socketPath: socketPath, modelRuntime: runtime)
        try await server.start()

        let connection = try await ControlSocketClient.connect(socketPath: socketPath)
        try await connection.send(.statusRequest)
        let response = try await connection.receive(timeout: 1)
        await connection.close()
        await server.stop()

        XCTAssertEqual(response, .statusResponse(currentModelID: "ready-model", runtimeState: .ready))
    }

    func testServerRefusesStartIfSocketAlreadyExists() async throws {
        let socketPath = try makeSocketPath()
        try FileManager.default.createDirectory(at: socketPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: socketPath.path, contents: Data())
        let server = ControlSocketServer(socketPath: socketPath, modelRuntime: makeRuntime(modelID: "ready-model"))

        do {
            try await server.start()
            XCTFail("expected stale socket rejection")
        } catch let error as ControlSocketServerError {
            XCTAssertEqual(error, .staleSocket(path: socketPath.path))
            XCTAssertEqual(error.description, "control socket \(socketPath.path) already exists; remove the stale file and restart serve")
        }
        try? FileManager.default.removeItem(at: socketPath.deletingLastPathComponent())
    }

    func testServerSocketParentDirIs0700AndSocketIs0600() async throws {
        let socketPath = try makeSocketPath()
        let server = ControlSocketServer(socketPath: socketPath, modelRuntime: makeRuntime(modelID: "ready-model"))
        try await server.start()

        XCTAssertEqual(mode(path: socketPath.deletingLastPathComponent().path), 0o700)
        XCTAssertEqual(mode(path: socketPath.path), 0o600)

        await server.stop()
    }

    func testServerStopUnlinksSocket() async throws {
        let socketPath = try makeSocketPath()
        let server = ControlSocketServer(socketPath: socketPath, modelRuntime: makeRuntime(modelID: "ready-model"))
        try await server.start()
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath.path))

        await server.stop()

        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath.path))
    }

    private func assertRoundTrip(_ frame: ControlSocketFrame) throws {
        XCTAssertEqual(try ControlSocketCodec.decode(try ControlSocketCodec.encode(frame)), frame)
    }

    private func makeSocketPath() throws -> URL {
        let dir = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("mpcs-\(getpid())-\(Int.random(in: 0 ... 999_999))")
        return dir.appendingPathComponent("ctl.sock")
    }

    private func mode(path: String) -> mode_t {
        var status = stat()
        XCTAssertEqual(lstat(path, &status), 0)
        return status.st_mode & mode_t(0o777)
    }

    private func makeRuntime(modelID: String?) -> ModelRuntime {
        ModelRuntime(
            modelID: modelID,
            warmSwapEnabled: true,
            loader: { _ in throw ControlSocketTestError.unexpectedContainerLoader },
            testLoader: { target in (target, "hash") }
        )
    }
}

private enum ControlSocketTestError: Error {
    case unexpectedContainerLoader
}
