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

    func testEncodeDecodeRotateReceiptKeyRequest() throws {
        try assertRoundTrip(.rotateReceiptKeyRequest(providerID: "provider-a"))
    }

    func testEncodeDecodeRotateReceiptKeyResultAccepted() throws {
        try assertRoundTrip(.rotateReceiptKeyResult(status: .accepted, error: nil))
    }

    func testEncodeDecodeRotateReceiptKeyResultRejected() throws {
        try assertRoundTrip(.rotateReceiptKeyResult(status: .rejected, error: "rotation failed"))
    }

    func testEncodeDecodeRotateReceiptKeyResultCommittedUnconfirmed() throws {
        try assertRoundTrip(.rotateReceiptKeyResult(status: .committedUnconfirmed, error: "publication unconfirmed"))
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

    func testEncodeDecodeSwitchAckNotInSupportedModels() throws {
        try assertRoundTrip(.switchAck(
            accepted: false,
            reason: .notInSupportedModels,
            currentTarget: nil,
            secondsRemaining: nil
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

    func testDecodeRejectsRotateReceiptKeyRequestMissingProviderID() {
        XCTAssertThrowsError(try ControlSocketCodec.decode(Data(#"{"type":"rotate_receipt_key_request"}"#.utf8))) { error in
            XCTAssertEqual(error as? ControlSocketError, .missingRequiredField("provider_id"))
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

    // MARK: - SPEC-025 App-track frames

    func testEncodeDecodeMetricsRequest() throws {
        try assertRoundTrip(.metricsRequest)
    }

    func testEncodeDecodeMetricsResponseFull() throws {
        try assertRoundTrip(.metricsResponse(ControlMetricsSnapshot(
            earningsUsdc: 0.42,
            malibuAccrued: 0.14,
            providerEarnings: ProviderEarningsSummary(
                walletBound: true,
                trustTier: "trusted",
                unpaidLedgerBacklogUSDC: 0.5,
                unpaidLedgerBacklogMALIBU: 1.5,
                usdcToday: 0.42,
                usdcWeek: 2,
                usdcPending: 0.25,
                usdcLifetime: 10,
                malibuToday: 0.14,
                malibuAllTime: 5,
                trustCriteriaMet: 4,
                trustCriteriaRequired: 4
            ),
            gpuC: 58.5,
            latencyP50Ms: 180,
            uptimeSec: 3600
        )))
    }

    func testEncodeDecodeMetricsResponseOptionalsOmitted() throws {
        let data = try ControlSocketCodec.encode(.metricsResponse(ControlMetricsSnapshot(
            earningsUsdc: nil,
            malibuAccrued: nil,
            gpuC: nil,
            latencyP50Ms: nil,
            uptimeSec: 0
        )))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("gpu_c"))
        XCTAssertFalse(text.contains("latency_p50_ms"))
        XCTAssertFalse(text.contains("earnings_usdc"))
        XCTAssertFalse(text.contains("malibu_accrued"))
        XCTAssertFalse(text.contains("provider_earnings"))
        XCTAssertEqual(try ControlSocketCodec.decode(data), .metricsResponse(ControlMetricsSnapshot(
            earningsUsdc: nil, malibuAccrued: nil, gpuC: nil, latencyP50Ms: nil, uptimeSec: 0
        )))
    }

    func testEncodeDecodePauseAndResume() throws {
        try assertRoundTrip(.pauseRequest)
        try assertRoundTrip(.pauseAck(accepted: false, reason: "lifecycle_control_unavailable"))
        try assertRoundTrip(.pauseAck(accepted: true, reason: nil))
        try assertRoundTrip(.resumeRequest)
        try assertRoundTrip(.resumeAck(accepted: false, reason: "lifecycle_control_unavailable"))
        try assertRoundTrip(.resumeAck(accepted: true, reason: nil))
    }

    func testEncodeDecodeShutdown() throws {
        try assertRoundTrip(.shutdownRequest(graceSeconds: 30))
        try assertRoundTrip(.shutdownAck)
    }

    func testEncodeDecodeReferralFrames() throws {
        let status = ReferralStatusSnapshot(
            campaign: "prebeta",
            joinBaseURL: "https://join.example/j",
            socialState: "eligible",
            baseCapacity: 1,
            configuredBonusCapacity: 2,
            bonusCapacity: 0,
            redemptions: 0,
            remaining: 1,
            firstServingSeen: true,
            joinLinksEnabled: true,
            socialBonusEnabled: true,
            inviteCode: "invite-1",
            inviteURL: "https://join.example/j/invite-1",
            observedAt: "2027-01-15T08:00:00.000Z",
            pendingChallenge: ReferralPendingAdvocacy(
                expiresAt: "2027-01-15T08:10:00.000Z"
            )
        )
        try assertRoundTrip(.referralStatusRequest)
        try assertRoundTrip(.referralStatusResponse(status))
        try assertRoundTrip(.referralChallengeRequest)
        try assertRoundTrip(.referralChallengeResponse(expiresAt: "2027-01-15T08:10:00.000Z"))
        try assertRoundTrip(.referralChallengeReopenRequest)
        try assertRoundTrip(.referralChallengeReopenAck(expiresAt: "2027-01-15T08:10:00.000Z"))
        try assertRoundTrip(.referralVerifyRequest(postURL: "https://x.com/a/status/123"))
        try assertRoundTrip(.referralChallengeCancelRequest)
        try assertRoundTrip(.referralChallengeCancelAck(status: status))
        try assertRoundTrip(.referralChallengeCancelAck(status: nil))
        try assertRoundTrip(.referralError(
            operation: .verify,
            code: .rateLimited,
            retryAfterSeconds: 17
        ))
    }

    func testAckOmitsReasonWhenNil() throws {
        let data = try ControlSocketCodec.encode(.pauseAck(accepted: true, reason: nil))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("reason"))
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

    func testServerHandlesReceiptRotationRequest() async throws {
        let socketPath = try makeSocketPath()
        let rotated = LockedBool()
        let server = ControlSocketServer(
            socketPath: socketPath,
            modelRuntime: makeRuntime(modelID: "ready-model"),
            receiptRotator: { rotated.set(true) },
            receiptRotationProviderID: "provider-a",
            idleTimeoutSeconds: 0.2
        )
        try await server.start()

        let connection = try await ControlSocketClient.connect(socketPath: socketPath)
        try await connection.send(.rotateReceiptKeyRequest(providerID: "provider-a"))
        let response = try await connection.receive(timeout: 1)
        await connection.close()
        await server.stop()

        XCTAssertEqual(response, .rotateReceiptKeyResult(status: .accepted, error: nil))
        XCTAssertTrue(rotated.get())
    }

    func testServerExecutesPauseAndResumeLifecycleCallbacks() async throws {
        let socketPath = try makeSocketPath()
        let paused = LockedBool()
        let resumed = LockedBool()
        let server = ControlSocketServer(
            socketPath: socketPath,
            modelRuntime: makeRuntime(modelID: "ready-model"),
            idleTimeoutSeconds: 0.2,
            pauseProvider: {
                paused.set(true)
                return .accepted
            },
            resumeProvider: {
                resumed.set(true)
                return .rejected("readiness_unconfirmed")
            }
        )
        try await server.start()

        let connection = try await ControlSocketClient.connect(socketPath: socketPath)
        try await connection.send(.pauseRequest)
        let pauseResponse = try await connection.receive(timeout: 1)
        XCTAssertEqual(pauseResponse, .pauseAck(accepted: true, reason: nil))
        try await connection.send(.resumeRequest)
        let resumeResponse = try await connection.receive(timeout: 1)
        XCTAssertEqual(
            resumeResponse,
            .resumeAck(accepted: false, reason: "readiness_unconfirmed")
        )
        await connection.close()
        await server.stop()

        XCTAssertTrue(paused.get())
        XCTAssertTrue(resumed.get())
    }

    func testServerReturnsSanitizedReferralAvailabilityWithoutService() async throws {
        let socketPath = try makeSocketPath()
        let server = makeServer(socketPath: socketPath, modelRuntime: makeRuntime(modelID: "ready-model"))
        try await server.start()

        let connection = try await ControlSocketClient.connect(socketPath: socketPath)
        try await connection.send(.referralStatusRequest)
        let statusResponse = try await connection.receive(timeout: 1)
        XCTAssertEqual(
            statusResponse,
            .referralError(operation: .status, code: .featureUnavailable, retryAfterSeconds: nil)
        )
        try await connection.send(.referralChallengeCancelRequest)
        let cancelResponse = try await connection.receive(timeout: 1)
        XCTAssertEqual(
            cancelResponse,
            .referralError(operation: .cancel, code: .featureUnavailable, retryAfterSeconds: nil)
        )
        await connection.close()
        await server.stop()
    }

    func testServerRejectsReceiptRotationWhenDisabled() async throws {
        let socketPath = try makeSocketPath()
        let server = makeServer(socketPath: socketPath, modelRuntime: makeRuntime(modelID: "ready-model"))
        try await server.start()

        let connection = try await ControlSocketClient.connect(socketPath: socketPath)
        try await connection.send(.rotateReceiptKeyRequest(providerID: "provider-a"))
        let response = try await connection.receive(timeout: 1)
        await connection.close()
        await server.stop()

        guard case let .rotateReceiptKeyResult(status, error) = response else {
            return XCTFail("unexpected response: \(response)")
        }
        XCTAssertEqual(status, .rejected)
        XCTAssertTrue(error?.contains("not enabled") == true, error ?? "nil")
    }


    func testServerWaitsForReceiptRotationCompletionBeforeResponding() async throws {
        let socketPath = try makeSocketPath()
        let rotated = LockedBool()
        let server = ControlSocketServer(
            socketPath: socketPath,
            modelRuntime: makeRuntime(modelID: "ready-model"),
            receiptRotator: {
                try await Task.sleep(nanoseconds: 50_000_000)
                rotated.set(true)
            },
            receiptRotationProviderID: "provider-a",
            idleTimeoutSeconds: 0.2
        )
        try await server.start()

        let connection = try await ControlSocketClient.connect(socketPath: socketPath)
        try await connection.send(.rotateReceiptKeyRequest(providerID: "provider-a"))
        let response = try await connection.receive(timeout: 1)
        await connection.close()
        await server.stop()

        XCTAssertEqual(response, .rotateReceiptKeyResult(status: .accepted, error: nil))
        XCTAssertTrue(rotated.get())
    }

    func testServerRejectsReceiptRotationProviderIDMismatch() async throws {
        let socketPath = try makeSocketPath()
        let rotated = LockedBool()
        let server = ControlSocketServer(
            socketPath: socketPath,
            modelRuntime: makeRuntime(modelID: "ready-model"),
            receiptRotator: { rotated.set(true) },
            receiptRotationProviderID: "provider-b",
            idleTimeoutSeconds: 0.2
        )
        try await server.start()

        let connection = try await ControlSocketClient.connect(socketPath: socketPath)
        try await connection.send(.rotateReceiptKeyRequest(providerID: "provider-a"))
        let response = try await connection.receive(timeout: 1)
        await connection.close()
        await server.stop()

        guard case let .rotateReceiptKeyResult(status, error) = response else {
            return XCTFail("unexpected response: \(response)")
        }
        XCTAssertEqual(status, .rejected)
        XCTAssertTrue(error?.contains("provider_id mismatch") == true, error ?? "nil")
        XCTAssertFalse(rotated.get())
    }


    func testServerBindsAndAcceptsConnection() async throws {
        let socketPath = try makeSocketPath()
        let runtime = makeRuntime(modelID: "ready-model")
        let server = makeServer(socketPath: socketPath, modelRuntime: runtime)
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
        let server = makeServer(socketPath: socketPath, modelRuntime: makeRuntime(modelID: "ready-model"))

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
        let server = makeServer(socketPath: socketPath, modelRuntime: makeRuntime(modelID: "ready-model"))
        try await server.start()

        XCTAssertEqual(mode(path: socketPath.deletingLastPathComponent().path), 0o700)
        XCTAssertEqual(mode(path: socketPath.path), 0o600)

        await server.stop()
    }

    func testServerStopUnlinksSocket() async throws {
        let socketPath = try makeSocketPath()
        let server = makeServer(socketPath: socketPath, modelRuntime: makeRuntime(modelID: "ready-model"))
        try await server.start()
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath.path))

        await server.stop()

        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath.path))
    }

    func testReceiveRejectsFramesLargerThan64KB() async throws {
        let socketPath = try makeSocketPath()
        let server = makeServer(socketPath: socketPath, modelRuntime: makeRuntime(modelID: "ready-model"))
        try await server.start()
        let fd = try rawConnect(socketPath: socketPath)
        defer { close(fd) }

        let oversized = Data(repeating: 0x61, count: ControlSocketConnection.maxFrameBytes + 1)
        try writeAll(oversized, to: fd)

        XCTAssertTrue(try waitForEOF(fd: fd, timeout: 2.0))
        await server.stop()
    }

    func testReceiveTimesOutAfterConfiguredIdleTimeout() async throws {
        let socketPath = try makeSocketPath()
        let server = ControlSocketServer(
            socketPath: socketPath,
            modelRuntime: makeRuntime(modelID: "ready-model"),
            idleTimeoutSeconds: 0.2
        )
        try await server.start()
        let fd = try rawConnect(socketPath: socketPath)
        defer { close(fd) }

        XCTAssertTrue(try waitForEOF(fd: fd, timeout: 1.0))
        await server.stop()
    }

    func testServerStopCancelsActiveClientTasks() async throws {
        let socketPath = try makeSocketPath()
        let server = makeServer(socketPath: socketPath, modelRuntime: makeRuntime(modelID: "ready-model"))
        try await server.start()
        let fd = try rawConnect(socketPath: socketPath)
        defer { close(fd) }
        try writeAll(Data(#"{"type":"status_request""#.utf8), to: fd)
        try await Task.sleep(nanoseconds: 50_000_000)

        await server.stop()

        XCTAssertTrue(try waitForEOF(fd: fd, timeout: 1.0))
    }

    func testClientTasksDoNotLeakOnCompletion() async throws {
        let socketPath = try makeSocketPath()
        let server = makeServer(socketPath: socketPath, modelRuntime: makeRuntime(modelID: "ready-model"))
        try await server.start()

        for _ in 0 ..< 50 {
            let connection = try await ControlSocketClient.connect(socketPath: socketPath)
            try await connection.send(.statusRequest)
            _ = try await connection.receive(timeout: 1)
            await connection.close()
        }

        try await waitUntil(timeoutNanoseconds: 500_000_000) {
            await server.clientTasksCountForTest() <= 2
        }
        let taskCount = await server.clientTasksCountForTest()
        await server.stop()

        XCTAssertLessThanOrEqual(taskCount, 2)
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

    private func makeServer(socketPath: URL, modelRuntime: ModelRuntime) -> ControlSocketServer {
        ControlSocketServer(socketPath: socketPath, modelRuntime: modelRuntime, idleTimeoutSeconds: 0.2)
    }

    private func rawConnect(socketPath: URL) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var address = try unixAddress(path: socketPath.path)
        let result = withUnsafePointer(to: &address.sockaddr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, address.length)
            }
        }
        if result != 0 {
            let err = errno
            close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
        }
        return fd
    }

    private func unixAddress(path: String) throws -> (sockaddr: sockaddr_un, length: socklen_t) {
        let pathBytes = Array(path.utf8)
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENAMETOOLONG))
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.offset(of: \.sun_path)! + pathBytes.count + 1)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            for (index, byte) in pathBytes.enumerated() {
                bytes[index] = byte
            }
            bytes[pathBytes.count] = 0
        }
        return (address, socklen_t(address.sun_len))
    }

    private func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var sent = 0
            while sent < rawBuffer.count {
                let count = Darwin.write(fd, base.advanced(by: sent), rawBuffer.count - sent)
                if count < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                sent += count
            }
        }
    }

    private func waitForEOF(fd: Int32, timeout: TimeInterval) throws -> Bool {
        var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let result = Darwin.poll(&pollFD, 1, Int32((timeout * 1000).rounded()))
        guard result > 0 else {
            return false
        }
        var byte: UInt8 = 0
        let count = Darwin.read(fd, &byte, 1)
        if count == 0 {
            return true
        }
        if count < 0 {
            return errno == ECONNRESET || errno == EBADF
        }
        return false
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64,
        _ predicate: () async -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await predicate() {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for condition")
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

private final class LockedBool: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set(_ value: Bool) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
