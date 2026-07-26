import Darwin
import Foundation
import MacProviderCore
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
            inviteURL: "https://join.example/j#/invite-1",
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

    func testServerReclaimsOrphanedControlSocketOnStart() async throws {
        let socketPath = try makeSocketPath()
        try FileManager.default.createDirectory(at: socketPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        chmod(socketPath.deletingLastPathComponent().path, 0o700)
        try createOrphanedSocket(at: socketPath)

        let server = makeServer(socketPath: socketPath, modelRuntime: makeRuntime(modelID: "reclaimed-model"))
        try await server.start()

        let connection = try await ControlSocketClient.connect(socketPath: socketPath)
        try await connection.send(.statusRequest)
        let response = try await connection.receive(timeout: 1)
        await connection.close()
        await server.stop()

        XCTAssertEqual(response, .statusResponse(currentModelID: "reclaimed-model", runtimeState: .ready))
        try? FileManager.default.removeItem(at: socketPath.deletingLastPathComponent())
    }

    func testServerFailsClosedWhenControlSocketIsLive() async throws {
        let socketPath = try makeSocketPath()
        let liveServer = makeServer(socketPath: socketPath, modelRuntime: makeRuntime(modelID: "live-model"))
        try await liveServer.start()

        let contender = makeServer(socketPath: socketPath, modelRuntime: makeRuntime(modelID: "contender"))
        do {
            try await contender.start()
            XCTFail("expected stale socket rejection while peer is live")
        } catch let error as ControlSocketServerError {
            XCTAssertEqual(error, .staleSocket(path: socketPath.path))
        }

        // The live peer must be completely unaffected by the failed reclaim attempt.
        let connection = try await ControlSocketClient.connect(socketPath: socketPath)
        try await connection.send(.statusRequest)
        let response = try await connection.receive(timeout: 1)
        await connection.close()
        await liveServer.stop()

        XCTAssertEqual(response, .statusResponse(currentModelID: "live-model", runtimeState: .ready))
    }

    func testStaleSocketReclaimPreservesLiveReplacementOnIdentityRace() async throws {
        let socketPath = try makeSocketPath()
        try FileManager.default.createDirectory(at: socketPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        chmod(socketPath.deletingLastPathComponent().path, 0o700)

        // Capture the identity a reclaimer would have observed for a
        // now-orphaned socket before it acted on it.
        let staleIdentityPath = socketPath.deletingLastPathComponent().appendingPathComponent("stale-identity.sock")
        try createOrphanedSocket(at: staleIdentityPath)
        let staleIdentity = try socketIdentity(at: staleIdentityPath)
        try FileManager.default.removeItem(at: staleIdentityPath)

        // A live server now wins the race and legitimately owns socketPath.
        let liveServer = makeServer(socketPath: socketPath, modelRuntime: makeRuntime(modelID: "winner"))
        try await liveServer.start()

        let parentFD = Darwin.open(socketPath.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY)
        XCTAssertGreaterThanOrEqual(parentFD, 0)
        defer { Darwin.close(parentFD) }

        // Attempting to quarantine using the stale (pre-race) identity must
        // fail and must not disturb the live replacement's socket file.
        XCTAssertFalse(ControlSocketStaleSocketReclaimer.quarantineAndUnlinkForTest(
            parentFD: parentFD,
            socketName: socketPath.lastPathComponent,
            expectedIdentity: staleIdentity
        ))

        let connection = try await ControlSocketClient.connect(socketPath: socketPath)
        try await connection.send(.statusRequest)
        let response = try await connection.receive(timeout: 1)
        await connection.close()
        await liveServer.stop()

        XCTAssertEqual(response, .statusResponse(currentModelID: "winner", runtimeState: .ready))
        try? FileManager.default.removeItem(at: socketPath.deletingLastPathComponent())
    }

    func testWatchdogCleanupRemovesOwnedUnixSocket() async throws {
        let socketPath = try makeSocketPath()
        let cleanup = ControlSocketWatchdogCleanup(socketPath: socketPath)
        let server = ControlSocketServer(
            socketPath: socketPath,
            modelRuntime: makeRuntime(modelID: "ready-model"),
            watchdogCleanup: cleanup
        )
        try await server.start()

        XCTAssertTrue(cleanup.prepareForWatchdogExit())
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath.path))
        await server.stop()
    }

    func testWatchdogCleanupRefusesWhenNotArmed() throws {
        let socketPath = try makeSocketPath()
        let cleanup = ControlSocketWatchdogCleanup(socketPath: socketPath)
        XCTAssertFalse(cleanup.prepareForWatchdogExit())
    }

    func testWatchdogCleanupPreservesRegularFile() throws {
        let socketPath = try makeSocketPath()
        let cleanup = ControlSocketWatchdogCleanup(socketPath: socketPath)
        try FileManager.default.createDirectory(at: socketPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        chmod(socketPath.deletingLastPathComponent().path, 0o700)
        XCTAssertTrue(FileManager.default.createFile(atPath: socketPath.path, contents: Data("keep".utf8)))

        XCTAssertFalse(cleanup.arm())
        XCTAssertFalse(cleanup.prepareForWatchdogExit())
        XCTAssertEqual(try Data(contentsOf: socketPath), Data("keep".utf8))
        try? FileManager.default.removeItem(at: socketPath.deletingLastPathComponent())
    }

    func testWatchdogCleanupPreservesSymlink() throws {
        let socketPath = try makeSocketPath()
        let cleanup = ControlSocketWatchdogCleanup(socketPath: socketPath)
        try FileManager.default.createDirectory(at: socketPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        chmod(socketPath.deletingLastPathComponent().path, 0o700)
        try FileManager.default.createSymbolicLink(atPath: socketPath.path, withDestinationPath: "/tmp/not-a-provider-socket")

        XCTAssertFalse(cleanup.arm())
        XCTAssertFalse(cleanup.prepareForWatchdogExit())
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: socketPath.path), "/tmp/not-a-provider-socket")
        try? FileManager.default.removeItem(at: socketPath.deletingLastPathComponent())
    }

    func testWatchdogCleanupPreservesReplacementSocket() async throws {
        let socketPath = try makeSocketPath()
        let originalPath = socketPath.deletingLastPathComponent().appendingPathComponent("original.sock")
        let cleanup = ControlSocketWatchdogCleanup(socketPath: socketPath)
        let originalServer = ControlSocketServer(
            socketPath: socketPath,
            modelRuntime: makeRuntime(modelID: "original"),
            watchdogCleanup: cleanup
        )
        try await originalServer.start()
        try FileManager.default.moveItem(at: socketPath, to: originalPath)

        let replacementServer = makeServer(
            socketPath: socketPath,
            modelRuntime: makeRuntime(modelID: "replacement")
        )
        try await replacementServer.start()

        XCTAssertFalse(cleanup.prepareForWatchdogExit())
        let connection = try await ControlSocketClient.connect(socketPath: socketPath)
        try await connection.send(.statusRequest)
        let response = try await connection.receive(timeout: 1)
        XCTAssertEqual(
            response,
            .statusResponse(currentModelID: "replacement", runtimeState: .ready)
        )
        await connection.close()

        await replacementServer.stop()
        await originalServer.stop()
        try? FileManager.default.removeItem(at: socketPath.deletingLastPathComponent())
    }

    func testServerPreservesSocketPathWhenWatchdogCleanupCannotArm() async throws {
        let socketPath = try makeSocketPath()
        let unrelatedPath = socketPath.deletingLastPathComponent().appendingPathComponent("unrelated.sock")
        let cleanup = ControlSocketWatchdogCleanup(socketPath: unrelatedPath)
        let server = ControlSocketServer(
            socketPath: socketPath,
            modelRuntime: makeRuntime(modelID: "ready-model"),
            watchdogCleanup: cleanup
        )

        do {
            try await server.start()
            XCTFail("expected watchdog cleanup arming failure")
        } catch let error as ControlSocketServerError {
            XCTAssertEqual(error, .watchdogCleanupFailed(path: socketPath.path))
        }

        var socketInfo = stat()
        XCTAssertEqual(Darwin.lstat(socketPath.path, &socketInfo), 0)
        XCTAssertEqual(socketInfo.st_mode & S_IFMT, S_IFSOCK)
        try? FileManager.default.removeItem(at: socketPath.deletingLastPathComponent())
    }

    func testWatchdogCleanupRefusesUnsafeSocketMode() async throws {
        let socketPath = try makeSocketPath()
        let server = makeServer(socketPath: socketPath, modelRuntime: makeRuntime(modelID: "ready-model"))
        try await server.start()
        chmod(socketPath.path, 0o666)
        let cleanup = ControlSocketWatchdogCleanup(socketPath: socketPath)

        XCTAssertFalse(cleanup.arm())
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath.path))

        chmod(socketPath.path, 0o600)
        await server.stop()
    }

    func testWatchdogCleanupRefusesUnsafeParentMode() async throws {
        let socketPath = try makeSocketPath()
        let server = makeServer(socketPath: socketPath, modelRuntime: makeRuntime(modelID: "ready-model"))
        try await server.start()
        chmod(socketPath.deletingLastPathComponent().path, 0o755)
        let cleanup = ControlSocketWatchdogCleanup(socketPath: socketPath)

        XCTAssertFalse(cleanup.arm())
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath.path))

        chmod(socketPath.deletingLastPathComponent().path, 0o700)
        await server.stop()
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

    // MARK: - SPEC-037 FR-KVP8 — disabled-disk-tier RAM purge/status (Finding 2)

    /// With the disk tier DISABLED (kvDiskTier == nil), the serve holds NO KV
    /// namespace flock, so the on-disk crypto-shred is delegated to the standalone
    /// CLI path. A socket-routed single-key purge must (1) still clear the serve-owned
    /// RAM (hot) entry — so we never keep serving a purged prefix from RAM — and
    /// (2) reply `unavailable`/`disk_tier_disabled` so the CLI's `status != "unavailable"`
    /// guard falls THROUGH to the standalone `purge` that actually shreds disk +
    /// Keychain. Replying `purge_ok` here would make the CLI return early and skip the
    /// only disk-shred code.
    func testKVCachePurgeSingleClearsHotRAMWhenDiskTierDisabled() async throws {
        let socketPath = try makeSocketPath()
        let runtime = makeRuntime(modelID: "ready-model")
        let key = "conv:kvs-synth:ram-single"
        let tokens = (0 ..< 40).map(Int32.init)
        await runtime.seedHotConversationForTest(key: key, tokens: tokens, modelID: "ready-model")
        // Prove residency via a non-mutating stats read (begin() would consume the entry).
        let residentBefore = await runtime.hotConversationStats().entries
        XCTAssertEqual(residentBefore, 1, "precondition: hot entry resident")

        let server = makeServer(socketPath: socketPath, modelRuntime: runtime)   // kvDiskTier == nil
        try await server.start()
        let connection = try await ControlSocketClient.connect(socketPath: socketPath)
        try await connection.send(.kvCachePurgeRequest(mode: "single", key: key))
        let response = try await connection.receive(timeout: 2)
        await connection.close()
        await server.stop()

        guard case let .kvCachePurgeResponse(status, _, _, detail) = response else {
            return XCTFail("expected kvCachePurgeResponse, got \(response)")
        }
        // (2) CLI must fall through to the standalone disk shred.
        XCTAssertEqual(status, "unavailable")
        XCTAssertEqual(detail, "disk_tier_disabled")
        // (1) RAM hot residency was cleared by the handler.
        let residentAfter = await runtime.hotConversationStats().entries
        XCTAssertEqual(residentAfter, 0, "hot entry evicted from RAM")
        // A subsequent begin() with a proper superset prompt (which WOULD warm-hit the
        // 40-token entry) is now a cold-start miss — nothing is served from RAM.
        let probe = (0 ..< 44).map(Int32.init)
        let cachedAfter = await runtime.hotCachedPromptTokensForTest(key: key, tokens: probe, modelID: "ready-model")
        XCTAssertEqual(cachedAfter, 0)
    }

    /// With the disk tier disabled, `--all` clears every RAM entry over the socket and
    /// replies `unavailable` so the CLI falls through to the standalone disk shred.
    func testKVCachePurgeAllClearsHotRAMWhenDiskTierDisabled() async throws {
        let socketPath = try makeSocketPath()
        let runtime = makeRuntime(modelID: "ready-model")
        await runtime.seedHotConversationForTest(key: "conv:kvs-synth:a", tokens: (0 ..< 40).map(Int32.init), modelID: "ready-model")
        await runtime.seedHotConversationForTest(key: "conv:kvs-synth:b", tokens: (0 ..< 40).map(Int32.init), modelID: "ready-model")
        let residentBefore = await runtime.hotConversationStats().entries
        XCTAssertEqual(residentBefore, 2)

        let server = makeServer(socketPath: socketPath, modelRuntime: runtime)
        try await server.start()
        let connection = try await ControlSocketClient.connect(socketPath: socketPath)
        try await connection.send(.kvCachePurgeRequest(mode: "all", key: nil))
        let response = try await connection.receive(timeout: 2)
        await connection.close()
        await server.stop()

        guard case let .kvCachePurgeResponse(status, _, _, detail) = response else {
            return XCTFail("expected kvCachePurgeResponse, got \(response)")
        }
        XCTAssertEqual(status, "unavailable")
        XCTAssertEqual(detail, "disk_tier_disabled")
        let residentAfter = await runtime.hotConversationStats().entries
        XCTAssertEqual(residentAfter, 0)
    }

    /// With the disk tier disabled and NO resident hot entry, the handler still replies
    /// `unavailable`/`disk_tier_disabled` (the CLI must delegate the disk shred to the
    /// standalone path regardless of whether RAM held anything to clear).
    func testKVCachePurgeDisabledReportsZeroForAbsentHotEntry() async throws {
        let socketPath = try makeSocketPath()
        let runtime = makeRuntime(modelID: "ready-model")
        let server = makeServer(socketPath: socketPath, modelRuntime: runtime)
        try await server.start()
        let connection = try await ControlSocketClient.connect(socketPath: socketPath)
        try await connection.send(.kvCachePurgeRequest(mode: "single", key: "conv:kvs-synth:absent"))
        let response = try await connection.receive(timeout: 2)
        await connection.close()
        await server.stop()

        guard case let .kvCachePurgeResponse(status, _, _, detail) = response else {
            return XCTFail("expected kvCachePurgeResponse, got \(response)")
        }
        XCTAssertEqual(status, "unavailable")
        XCTAssertEqual(detail, "disk_tier_disabled")
    }

    /// FINDING A — the disabled-tier disk crypto-shred must be IDENTICAL whether or
    /// not a serve is running: both flows converge on the standalone
    /// `purgeAllAndForget` (the CLI fall-through), which deletes on-disk ciphertext +
    /// Keychain DEKs left by a prior enabled run. The socket arm reaches it because the
    /// disabled handler replies `unavailable` (not `purge_ok`) so the CLI does not
    /// short-circuit; the no-serve arm reaches it because `trySocket` finds nothing.
    func testDisabledForgetShredsDiskIdenticallyWithAndWithoutServe() async throws {
        // Arm A — a running serve with the disk tier DISABLED (tier == nil).
        let armA = try await seedPriorEnabledRunResidue()
        let (diskA, kcA) = await residencyCounts(armA)
        XCTAssertEqual(diskA, 1, "precondition: prior enabled run left a disk entry")
        XCTAssertGreaterThan(kcA, 0, "precondition: prior enabled run left Keychain DEK material")

        let socketPath = try makeSocketPath()
        let runtime = makeRuntime(modelID: "ready-model")
        await runtime.seedHotConversationForTest(key: "conv:kvs-synth:armA", tokens: (0 ..< 40).map(Int32.init), modelID: "ready-model")
        let server = makeServer(socketPath: socketPath, modelRuntime: runtime)   // kvDiskTier == nil
        try await server.start()
        let connection = try await ControlSocketClient.connect(socketPath: socketPath)
        try await connection.send(.kvCachePurgeRequest(mode: "all_forget", key: nil))
        let response = try await connection.receive(timeout: 2)
        await connection.close()
        await server.stop()
        guard case let .kvCachePurgeResponse(status, _, _, detail) = response else {
            return XCTFail("expected kvCachePurgeResponse, got \(response)")
        }
        XCTAssertEqual(status, "unavailable", "disabled serve must delegate disk shred to the standalone CLI")
        XCTAssertEqual(detail, "disk_tier_disabled")
        let hotAfterA = await runtime.hotConversationStats().entries
        XCTAssertEqual(hotAfterA, 0, "serve cleared RAM before delegating")
        // The CLI now falls through to the standalone shred.
        _ = await armA.tier.purgeAllAndForget()
        let (diskAfterA, kcAfterA) = await residencyCounts(armA)
        await armA.tier.shutdown()

        // Arm B — no serve at all: the CLI goes straight to the standalone shred.
        let armB = try await seedPriorEnabledRunResidue()
        let (diskB, kcB) = await residencyCounts(armB)
        XCTAssertEqual(diskB, 1)
        XCTAssertGreaterThan(kcB, 0)
        _ = await armB.tier.purgeAllAndForget()
        let (diskAfterB, kcAfterB) = await residencyCounts(armB)
        await armB.tier.shutdown()

        // Identical end state: both arms shredded disk ciphertext + Keychain DEKs.
        XCTAssertEqual(diskAfterA, 0)
        XCTAssertEqual(kcAfterA, 0)
        XCTAssertEqual(diskAfterB, 0)
        XCTAssertEqual(kcAfterB, 0)
        XCTAssertEqual(diskAfterA, diskAfterB, "disk end state identical with/without a running serve")
        XCTAssertEqual(kcAfterA, kcAfterB, "Keychain end state identical with/without a running serve")
    }

    /// A disabled disk tier over a namespace that a prior ENABLED run populated with one
    /// committed entry (ciphertext on disk + a DEK in the shared Keychain). Returns the
    /// disabled tier plus the shared root/keychain for residency assertions.
    private struct DiskResidue {
        let tier: KVDiskTier
        let root: URL
        let keychain: KVInMemoryKeychain
    }

    private func seedPriorEnabledRunResidue() async throws -> DiskResidue {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kvres-\(getpid())-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let keychain = KVInMemoryKeychain()
        // Prior ENABLED run: write one committed entry, then shut down (releasing the lock).
        let enabled = KVDiskTier(
            config: KVDiskCacheConfig(enabled: true, directory: root.path, minFreeBytes: 1024 * 1024),
            namespaceID: "ns-res", eligibilityTTLSeconds: 900, keychain: keychain, sink: KVRecordingEventSink())
        let activated = await enabled.activateForControlPlane()
        XCTAssertTrue(activated)
        let key = "conv:kvs-synth:residue"
        let seq = 5
        let index = try await enabled.store.currentIndex(rawKey: key)
        let sampled = try await enabled.store.highWatermark(rawKey: key)
        let byteCount = 1 * 2 * seq * 4 * KVCodecDType.f32.byteSize
        let snapshot = KVWriteSnapshot(
            rawKey: key, indexHMAC: try XCTUnwrap(index), tokens: Array(0 ..< Int32(seq)),
            layers: [KVLayerPayload(
                layerIndex: 0, classID: "KVCacheSimple", ndim: 4, dims: [1, 2, seq, 4], dtype: .f32,
                cacheOffset: seq, keyBytes: Data(count: byteCount), valueBytes: Data(count: byteCount))],
            identity: KVWriteIdentity(
                requestModel: "qwen-test", servedModelID: "qwen-test-served",
                modelSHA256: String(repeating: "b", count: 64), catalogRevision: "r1",
                tokenizerID: "tok-1", tokenizerConfigSHA256: String(repeating: "c", count: 64),
                chatTemplateSHA256: String(repeating: "d", count: 64), abiEpoch: 1,
                mlxSwiftLMRevision: "3.31.4", mlxVersion: "0.0.0", cacheClass: "KVCacheSimple",
                layerCount: 1, kvBits: nil, kvGroupSize: nil, kvQuantMode: nil, kvQuantPolicy: nil,
                decodePath: "ordinary", keyEpoch: 1),
            sampledPurgeGeneration: sampled, commitSequence: 1,
            createdAtMillis: 1_000_000, eligibleUntilMillis: 1_900_000,
            incarnation: "inc-\(UUID().uuidString)")
        guard case .committed = try await enabled.store.write(snapshot, nowMillis: 1_000_000) else {
            XCTFail("prior enabled write should commit"); throw ControlSocketTestError.unexpectedContainerLoader
        }
        await enabled.shutdown()
        // Current run has the tier DISABLED, sharing the same on-disk namespace + Keychain.
        let disabled = KVDiskTier(
            config: KVDiskCacheConfig(enabled: false, directory: root.path, minFreeBytes: 1024 * 1024),
            namespaceID: "ns-res", eligibilityTTLSeconds: 900, keychain: keychain, sink: KVRecordingEventSink())
        return DiskResidue(tier: disabled, root: root, keychain: keychain)
    }

    private func residencyCounts(_ residue: DiskResidue) async -> (disk: Int, keychain: Int) {
        let disk = await residue.tier.status()?.entryCount ?? 0
        let keychain = (try? residue.keychain.enumerate(servicePrefix: "").count) ?? -1
        return (disk, keychain)
    }

    /// With the disk tier disabled, `kv-cache status` reports the RAM/hot residency
    /// with enabled=false — not `unavailable`.
    func testKVCacheStatusReportsHotStateWhenDiskTierDisabled() async throws {
        let socketPath = try makeSocketPath()
        let runtime = makeRuntime(modelID: "ready-model")
        await runtime.seedHotConversationForTest(key: "conv:kvs-synth:s", tokens: (0 ..< 12).map(Int32.init), modelID: "ready-model")

        let server = makeServer(socketPath: socketPath, modelRuntime: runtime)
        try await server.start()
        let connection = try await ControlSocketClient.connect(socketPath: socketPath)
        try await connection.send(.kvCacheStatusRequest)
        let response = try await connection.receive(timeout: 2)
        await connection.close()
        await server.stop()

        guard case let .kvCacheStatusResponse(payloadJSON) = response else {
            return XCTFail("expected kvCacheStatusResponse, got \(response)")
        }
        XCTAssertFalse(payloadJSON.contains("\"unavailable\""), "disabled tier must not report unavailable")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(payloadJSON.utf8)) as? [String: Any])
        XCTAssertEqual(object["status"] as? String, "ok")
        XCTAssertEqual(object["enabled"] as? Bool, false)
        XCTAssertEqual(object["hot_entries"] as? Int, 1)
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

    /// Binds and listens on `path` like a real serve process would, then
    /// closes the listener without unlinking the file — reproducing the
    /// exact orphaned-inode state left behind when a process dies (SIGKILL,
    /// OOM, power loss) before its watchdog exit cleanup can run.
    private func createOrphanedSocket(at path: URL) throws {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var address = try unixAddress(path: path.path)
        let result = withUnsafePointer(to: &address.sockaddr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, address.length)
            }
        }
        XCTAssertEqual(result, 0)
        chmod(path.path, 0o600)
        XCTAssertEqual(Darwin.listen(fd, 128), 0)
        Darwin.close(fd)
    }

    private func socketIdentity(at path: URL) throws -> ControlSocketFileIdentity {
        var info = stat()
        XCTAssertEqual(Darwin.lstat(path.path, &info), 0)
        return ControlSocketFileIdentity(info)
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
