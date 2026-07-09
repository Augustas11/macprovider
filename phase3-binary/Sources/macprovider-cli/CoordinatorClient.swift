import Foundation
import MacProviderCore
import Darwin
import CryptoKit

protocol ProviderWebSocketTask: AnyObject, Sendable {
    func resume()
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func sendPing() async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

// M1-1 follow-up (codex security audit 2026-06-11): refuse HTTP redirects
// on the provider WS connect so the Authorization: Bearer <token> header
// cannot leak to an attacker-controlled redirect target. The default
// URLSession.shared follows redirects with the credential headers attached.
// We install this delegate on a dedicated session via providerWebSocketSession
// so the same isolation holds across reconnects.
final class NoRedirectURLSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        CoordinatorClient.keepaliveDebug("ws_redirect_refused status=\(response.statusCode)")
        completionHandler(nil)
    }
}

// providerWebSocketSession is the dedicated URLSession used by the default
// webSocketFactory. URLSession retains its delegate until invalidated, so we
// keep a process-wide singleton rather than leaking one session per connect.
private let providerWebSocketSession: URLSession = {
    let config = URLSessionConfiguration.default
    config.httpShouldUsePipelining = false
    config.httpAdditionalHeaders = nil
    return URLSession(
        configuration: config,
        delegate: NoRedirectURLSessionDelegate(),
        delegateQueue: nil
    )
}()

extension URLSessionWebSocketTask: ProviderWebSocketTask {}

protocol ReceiptKeyRotatingCoordinatorClient: Sendable {
    func reconnectWithNewKey(
        _ newKey: Curve25519.Signing.PrivateKey,
        commitKey: @escaping @Sendable () async throws -> Void
    ) async throws
}

// Issue #189: heartbeat send wedged at the URLSession layer (TCP socket
// half-open or App Nap-starved task). The keepalive loop bounds each
// sendHeartbeat() with this timeout; a timeout throw routes to the
// existing closeWebSocketAfterKeepaliveFailure() → runReconnectLoop path.
struct CoordinatorHeartbeatSendTimeout: Error, CustomStringConvertible, Equatable {
    let timeoutSeconds: Double

    var description: String {
        String(format: "coordinator heartbeat send timed out after %.1fs", timeoutSeconds)
    }
}

struct CoordinatorReceiptRotationTimeout: Error, CustomStringConvertible, Equatable {
    let timeoutSeconds: Double

    var description: String {
        String(format: "receipt key rotation timed out after %.1fs", timeoutSeconds)
    }
}

struct CoordinatorReceiptRotationInProgress: Error, CustomStringConvertible, Equatable {
    var description: String {
        "receipt key rotation already in progress"
    }
}

struct CoordinatorReceiptRotationCommittedRecoveryFailed: Error, CustomStringConvertible, Equatable {
    let underlying: String

    var description: String {
        "receipt key rotation committed locally, but coordinator publication recovery failed: \(underlying)"
    }
}

// Guards a CheckedContinuation so it resumes exactly once. URLSession's
// pongReceiveHandler can fire more than once on a connection abort (observed
// in the field: NSPOSIXErrorDomain Code=53 "Software caused connection
// abort"), which previously double-resumed the continuation and tripped a
// SWIFT TASK CONTINUATION MISUSE fatalError — crashing the whole provider on
// a single transient WS blip. NSLock-guarded flag matches the @unchecked
// Sendable idiom used elsewhere in this file (CaffeinateSleepAssertion).
private final class ResumeOnceGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    /// Returns true exactly once — for the first caller. All later calls
    /// return false so the continuation is never resumed twice.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if resumed { return false }
        resumed = true
        return true
    }
}

extension URLSessionWebSocketTask {
    func sendPing() async throws {
        let once = ResumeOnceGuard()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sendPing { error in
                guard once.claim() else { return }
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
}

protocol ProviderSleepAssertion: AnyObject, Sendable {
    func stop()
}

final class CaffeinateSleepAssertion: ProviderSleepAssertion, @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    private init(process: Process) {
        self.process = process
    }

    static func start() -> CaffeinateSleepAssertion? {
        let path = "/usr/bin/caffeinate"
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-dimsu", "-w", String(getpid())]
        do {
            try process.run()
            return CaffeinateSleepAssertion(process: process)
        } catch {
            CoordinatorClient.keepaliveDebug("sleep_assertion_start_failed error=\(error)")
            return nil
        }
    }

    func stop() {
        lock.lock()
        let running = process
        process = nil
        lock.unlock()
        running?.terminate()
    }
}

actor CoordinatorClient {
    typealias SendOverride = @Sendable (sending [String: Any]) async throws -> Void

    static let binaryVersion = "1.8.19"
    private static let keepaliveDebugEnabled = ProcessInfo.processInfo.environment["MACPROVIDER_KEEPALIVE_DEBUG"] == "1"

    private let coordinatorURL: URL
    private let appConfig: AppConfig
    private let providerStatus: ProviderStatus
    private let drainTimeoutSeconds: Int
    private let providerID: String
    private let endpointURL: String?
    private let wsTunneledMode: Bool
    private let modelRuntime: ModelRuntime
    private let loadedModelID: String?
    private let maxBodyBytes: Int
    private let maxActiveRequests: Int
    private let supportedModels: [String]?
    private let catalogModelIDForCoordinator: String?
    private let publishesSupportedModels: Bool
    private let warmSwapEnabled: Bool
    private let hardwareSummary: [String: Any]?
    private var providerReceiptPublicKey: String?
    private let receiptBuilder: ReceiptBuilder?
    private var receiptRotationInFlight = false
    private let reconnectGraceNanoseconds: UInt64
    private let receiptKeyRotationTimeoutNanoseconds: UInt64
    private let connectAndRunOverride: (@Sendable () async throws -> Void)?
    private let attestationGenerator: Tier2AttestationTokenGenerating
    // SE liveness challenge signing (Phase 1, Track P1-C).
    // Nil until first challenge; lazily loads SecureEnclaveIdentity on arm64.
    // Tests inject a SELivenessTestSigning double via the init parameter.
    private var seLivenessSigner: (any SELivenessSigning)?
    // M1-1 / XSEC-1: the factory now takes a URLRequest so the binary can
    // attach an Authorization: Bearer header when a provider token is
    // configured. The header is required when the coordinator runs with
    // auth.require_provider_tokens=true (the production posture per
    // SPEC-001). The factory signature change is intentional — keeping
    // it URL-only would require a parallel header-injection seam.
    private let webSocketFactory: @Sendable (URLRequest) -> ProviderWebSocketTask
    // SPEC-003 v0.8 FR-C9.3 — was `let` pre-v0.8, now `var` so a
    // self-minted provisional token from acceptCoordinatorSession can be
    // adopted in-process without waiting for a binary restart. Actor
    // isolation makes the mutation race-free.
    private var providerToken: String?
    // SPEC-003 v0.8 FR-C9.3 — captured at init so the persist hook in
    // acceptCoordinatorSession knows where to write the new token
    // without taking another dependency on the loader.
    private let configPath: String
    private let sleepAssertionFactory: @Sendable () -> ProviderSleepAssertion?
    private let pairingController: PairingController
    private var inferenceRelay: InferenceRelay?
    private var tier2Session: Tier2ProviderSession?
    private var autoupdateTrustState = AutoUpdateTrustState(
        v2Accepted: false,
        tier: nil,
        encryptedLegValid: false,
        attestationRequired: false,
        attestationSatisfied: false,
        tokenConfigured: false,
        tokenValidated: false,
        bearerlessDuplicate: false,
        connected: false
    )
    private var autoupdateCoordinatorPayload: [String: Any] = [:]
    private var autoupdateCoordinatorPayloadIsV2 = false
    private var autoupdateAssignedProviderTokenAdopted = false
    private var autoupdateDemotionReason: String?
    private var autoupdateDisabledForSessionReason: String?
    private var autoupdateDrainExtensions = false
    private var autoupdateAttemptedTargets = Set<String>()
    private var webSocket: ProviderWebSocketTask?
    private var coordinatorSessionAccepted = false
    private var runTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    // Issue #189: separate watchdog task observing heartbeat liveness.
    // If the heartbeat task itself stalls (App Nap, cooperative-task
    // starvation), the watchdog fires watchdogExitHook so launchd respawns.
    private var heartbeatWatchdogTask: Task<Void, Never>?
    private var lastHeartbeatSuccessNanoseconds: UInt64 = 0
    private let watchdogExitHook: @Sendable (String) -> Void
    private var swapHeartbeatTask: Task<Void, Never>?
    private var sleepAssertion: ProviderSleepAssertion?
    private let sendOverride: SendOverride?
    private let streamInterval: Int

    // SPEC-026 §7: optional bridge for delegating identity signature to
    // Malibu.app via the control socket. `nil` when the CLI runs standalone
    // (install.sh path) — the coordinator's per-provider exemption
    // (identity_signature.go:38) covers that case.
    private let identityBridge: IdentitySignatureBridge?
    private let identitySignatureTimeoutSeconds: TimeInterval

    init?(
        config: AppConfig,
        modelRuntime: ModelRuntime,
        providerStatus: ProviderStatus,
        sendOverride: SendOverride? = nil,
        reconnectGraceNanoseconds: UInt64 = 10 * 1_000_000_000,
        receiptKeyRotationTimeoutNanoseconds: UInt64 = 55 * 1_000_000_000,
        attestationGenerator: Tier2AttestationTokenGenerating = {
            #if arch(arm64)
            if let seGen = SecureEnclaveAttestationGenerator.loadIfAvailable() {
                return seGen
            }
            #endif
            return ManagedDeviceAttestationGenerator()
        }(),
        seLivenessSignerOverride: (any SELivenessSigning)? = nil,
        webSocketFactory: @escaping @Sendable (URLRequest) -> ProviderWebSocketTask = { providerWebSocketSession.webSocketTask(with: $0) },
        sleepAssertionFactory: @escaping @Sendable () -> ProviderSleepAssertion? = { CaffeinateSleepAssertion.start() },
        pairingController: PairingController? = nil,
        connectAndRunOverride: (@Sendable () async throws -> Void)? = nil,
        providerReceiptPublicKey: String? = nil,
        receiptBuilder: ReceiptBuilder? = nil,
        identityBridge: IdentitySignatureBridge? = nil,
        // Must sit well below the coordinator's WS handshake timeout
        // (`Config.ProviderWSHandshakeTimeout` — 10s default in Pearl's
        // production config). If our identity_signature roundtrip
        // (CLI → Malibu.app → Ed25519 sign → CLI → coordinator) takes
        // longer than the coordinator's read deadline, the coordinator
        // closes the WS with 4001 `invalid_auth_request: read` before we
        // finish sending the proof. Malibu.app's signing itself is
        // <100ms; the roundtrip includes control-socket write + read,
        // typically <200ms. Budget 3s so a truly-wedged Malibu (App
        // hung, TCC race) falls through to the unsigned proof path
        // within one coordinator handshake window; the coordinator's
        // per-provider exemption at `identity_signature.go:38` then
        // decides whether to admit us.
        identitySignatureTimeoutSeconds: TimeInterval = 3,
        // Issue #189: injectable in tests; production uses Darwin.exit(1)
        // so the launchd KeepAlive contract recovers the wedged process.
        watchdogExitHook: @escaping @Sendable (String) -> Void = { reason in
            FileHandle.standardError.write(Data("FATAL coordinator heartbeat watchdog: \(reason)\n".utf8))
            Darwin.exit(1)
        }
    ) {
        guard let rawURL = config.coordinatorURL, let url = URL(string: rawURL) else {
            return nil
        }
        guard url.scheme == "wss" else {
            return nil
        }
        self.coordinatorURL = url
        self.appConfig = config
        self.providerStatus = providerStatus
        self.drainTimeoutSeconds = config.drainTimeoutSeconds
        // SPEC-001 v1.1.2 / SPEC-002 v1.0.4 F-2: provider_id is the operator-issued
        // stable identifier matching coordinator's config.providers[] map. If unset,
        // we fall back to a per-instance UUID (dev/test only — production coordinators
        // will reject with close code 4002 unknown_provider_id).
        self.providerID = config.providerID ?? UUID().uuidString
        self.endpointURL = config.endpointURL?.isEmpty == false ? config.endpointURL : nil
        self.wsTunneledMode = self.endpointURL == nil && (config.wsTunneledMode ?? true)
        self.modelRuntime = modelRuntime
        self.loadedModelID = config.model
        self.maxBodyBytes = config.maxRequestBodyBytes
        self.maxActiveRequests = 1
        self.supportedModels = config.supportedModels
        self.catalogModelIDForCoordinator = config.modelCatalogModelID.flatMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        self.publishesSupportedModels = config.publishesSupportedModels
        self.warmSwapEnabled = config.enableWarmSwap
        self.hardwareSummary = ProviderHardwareSummary.liveWireObject()
        self.providerReceiptPublicKey = providerReceiptPublicKey
        self.receiptBuilder = receiptBuilder
        self.reconnectGraceNanoseconds = reconnectGraceNanoseconds
        self.receiptKeyRotationTimeoutNanoseconds = receiptKeyRotationTimeoutNanoseconds
        self.attestationGenerator = attestationGenerator
        self.seLivenessSigner = seLivenessSignerOverride
        self.webSocketFactory = webSocketFactory
        self.providerToken = config.providerToken.flatMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        self.configPath = config.configPath
        self.sleepAssertionFactory = sleepAssertionFactory
        self.pairingController = pairingController ?? PairingController(configPath: config.configPath)
        self.connectAndRunOverride = connectAndRunOverride
        self.sendOverride = sendOverride
        self.identityBridge = identityBridge
        self.identitySignatureTimeoutSeconds = identitySignatureTimeoutSeconds
        self.watchdogExitHook = watchdogExitHook
        self.streamInterval = max(1, config.streamInterval)
    }

    func start() async {
        await runStartupAutoupdateRecovery()
        startReconnectTask()
        if warmSwapEnabled, swapHeartbeatTask == nil {
            swapHeartbeatTask = Task { [weak self] in
                await self?.consumeSwapSignals()
            }
        }
    }

    func stop() async {
        runTask?.cancel()
        heartbeatTask?.cancel()
        heartbeatWatchdogTask?.cancel()
        swapHeartbeatTask?.cancel()
        sleepAssertion?.stop()
        sleepAssertion = nil
        await inferenceRelay?.cancelAllAndClear()
        inferenceRelay = nil
        tier2Session = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        coordinatorSessionAccepted = false
        autoupdateCoordinatorPayload = [:]
        autoupdateCoordinatorPayloadIsV2 = false
        autoupdateAssignedProviderTokenAdopted = false
        autoupdateDemotionReason = "coordinator_disconnected"
        autoupdateDisabledForSessionReason = nil
        autoupdateTrustState = AutoUpdateTrustState(
            v2Accepted: false,
            tier: nil,
            encryptedLegValid: false,
            attestationRequired: false,
            attestationSatisfied: false,
            tokenConfigured: false,
            tokenValidated: false,
            bearerlessDuplicate: false,
            connected: false
        )
        await providerStatus.setCoordinatorSession(connected: false)
        runTask = nil
        heartbeatTask = nil
        heartbeatWatchdogTask = nil
        swapHeartbeatTask = nil
        webSocket = nil
    }

    func sendIdlePrewarmEvent(event rawEvent: String, reason: String?) async {
        guard coordinatorSessionAccepted else {
            return
        }
        var payload: [String: Any] = [
            "type": "idle_prewarm_event",
            "event": rawEvent,
        ]
        if rawEvent == "idle_prewarm_skipped", let reason {
            payload["reason"] = reason
        }
        do {
            try await send(payload)
        } catch {
            // Stdout remains the local trail while the coordinator session is
            // absent or reconnecting.
        }
    }

    private func consumeSwapSignals() async {
        let stream = await modelRuntime.swapSignals()
        for await signal in stream {
            if Task.isCancelled {
                return
            }
            switch signal.outcome {
            case .loadFinished:
                continue
            case .completed:
                guard coordinatorSessionAccepted || webSocket == nil else {
                    continue
                }
                // Issue #189 R1 architect MEDIUM: the warm-swap completion
                // path is the second hot heartbeat callsite. A wedged
                // URLSession.send() here would park swapHeartbeatTask
                // exactly the way it parks the keepalive loop; bound it
                // through the same 5s timeout for symmetry.
                do {
                    try await sendHeartbeatBounded(resetWindow: true)
                    recordHeartbeatSuccess()
                } catch {
                    Self.keepaliveDebug("warm_swap_heartbeat_send_error error=\(error)")
                    closeWebSocketAfterKeepaliveFailure()
                }
            case let .failed(reason):
                Self.keepaliveDebug("coordinator.warmSwap.swapFailed reason=\(reason)")
            }
        }
    }

    private func startReconnectTask() {
        guard runTask == nil else { return }
        runTask = Task { [weak self] in
            await self?.runReconnectLoop()
        }
    }

    private func runReconnectLoop() async {
        var backoffSeconds: UInt64 = 1
        var failedAttempts = 0
        while !Task.isCancelled {
            do {
                try await connectAndRunOnce()
                await cleanupConnection()
                backoffSeconds = 1
                failedAttempts = 0
            } catch is CancellationError {
                await cleanupConnection()
                return
            } catch is CoordinatorDrainComplete {
                // Coordinator asked us to drain (likely it is restarting).
                // We acknowledged with drain_status; the WS is already closed.
                // Wait a grace period so the coordinator has time to come back
                // before we try to reconnect, then loop.
                await cleanupConnection()
                print("coordinator reconnect attempt 1 scheduled after drain")
                try? await Task.sleep(nanoseconds: reconnectGraceNanoseconds)
                backoffSeconds = 1
                failedAttempts = 0
            } catch is CoordinatorAuthUpgradeReconnect {
                // FR-C9.3: tokenless bootstrap minted a bearer; reconnect immediately
                // so the coordinator registers auth_state=bearer_validated and the
                // session becomes buyer-routable.
                await cleanupConnection()
                print("coordinator reconnect scheduled after provisional token adoption")
                try? await Task.sleep(nanoseconds: reconnectGraceNanoseconds)
                backoffSeconds = 1
                failedAttempts = 0
            } catch {
                await cleanupConnection()
                failedAttempts += 1
                if failedAttempts >= 3 {
                    print("WARN coordinator reconnect failed attempt_count=\(failedAttempts) last_error=\(error)")
                }
                try? await Task.sleep(nanoseconds: backoffSeconds * 1_000_000_000)
                backoffSeconds = min(backoffSeconds * 2, 60)
            }
        }
    }

    private func connectAndRunOnce() async throws {
        if let connectAndRunOverride {
            try await connectAndRunOverride()
            return
        }
        try await connectAndRun()
    }

    func connectAndRunOnceForTest() async throws {
        try await connectAndRunOnce()
    }

    func reconnectWithNewKey(
        _ newKey: Curve25519.Signing.PrivateKey,
        commitKey: @escaping @Sendable () async throws -> Void
    ) async throws {
        guard wsTunneledMode else {
            throw CoordinatorAuthError.invalidMessage("receipt key rotation requires v2 WS-tunneled auth")
        }
        guard !receiptRotationInFlight else {
            throw CoordinatorReceiptRotationInProgress()
        }
        receiptRotationInFlight = true
        defer { receiptRotationInFlight = false }

        // Round-2 audit M14: give any in-flight non-streaming inference a
        // bounded window to finish so the receipt it carries (signed with
        // the OLD key) lands on the buyer before we tear the socket down
        // and swap keys. Without this drain, a buyer mid-request sees a
        // dropped session with no receipt even though the provider
        // produced one. The budget mirrors drainTimeoutSeconds so it
        // composes with the existing shutdown path.
        if let activeRunTask = runTask {
            _ = await inferenceRelay?.waitUntilIdle(timeoutSeconds: max(1, drainTimeoutSeconds))
            activeRunTask.cancel()
            webSocket?.cancel(with: .goingAway, reason: nil)
            await activeRunTask.value
            runTask = nil
        }
        await cleanupConnection()

        let socket = try await openWebSocket()
        do {
            try await authenticateRotatedSocket(socket, newKey: newKey, commitKey: commitKey)
        } catch let error as CoordinatorReceiptRotationCommittedRecoveryFailed {
            startReconnectTask()
            throw error
        } catch {
            let rotationError = error
            if webSocket === socket {
                webSocket = nil
            }
            socket.cancel(with: .goingAway, reason: nil)
            await cleanupConnection()
            do {
                try await restoreReceiptRotationSessionWithTimeout()
            } catch {
                startReconnectTask()
                throw rotationError
            }
            throw rotationError
        }
    }
    private struct ReceiptRotationHandshakeValue: @unchecked Sendable {
        let publicKey: String
        let session: Tier2ProviderSession
        let response: [String: Any]
    }

    private enum ReceiptRotationHandshakeRace: @unchecked Sendable {
        case completed(Result<ReceiptRotationHandshakeValue, Error>)
        case timedOut
    }

    private final class ReceiptRotationHandshakeCompletion: @unchecked Sendable {
        private let lock = NSLock()
        private var result: ReceiptRotationHandshakeRace?
        private var continuation: CheckedContinuation<ReceiptRotationHandshakeRace, Never>?

        func complete(_ result: ReceiptRotationHandshakeRace) {
            lock.lock()
            if self.result != nil {
                lock.unlock()
                return
            }
            self.result = result
            let continuation = continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: result)
        }

        func wait() async -> ReceiptRotationHandshakeRace {
            if let result = storedResult() {
                return result
            }
            return await withCheckedContinuation { continuation in
                install(continuation)
            }
        }

        private func storedResult() -> ReceiptRotationHandshakeRace? {
            lock.lock()
            defer { lock.unlock() }
            return result
        }

        private func install(_ continuation: CheckedContinuation<ReceiptRotationHandshakeRace, Never>) {
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    private enum ReceiptRotationVoidRace: @unchecked Sendable {
        case completed(Result<Void, Error>)
        case timedOut
    }

    private final class ReceiptRotationVoidCompletion: @unchecked Sendable {
        private let lock = NSLock()
        private var result: ReceiptRotationVoidRace?
        private var continuation: CheckedContinuation<ReceiptRotationVoidRace, Never>?

        func complete(_ result: ReceiptRotationVoidRace) {
            lock.lock()
            if self.result != nil {
                lock.unlock()
                return
            }
            self.result = result
            let continuation = continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: result)
        }

        func wait() async -> ReceiptRotationVoidRace {
            if let result = storedResult() {
                return result
            }
            return await withCheckedContinuation { continuation in
                install(continuation)
            }
        }

        private func storedResult() -> ReceiptRotationVoidRace? {
            lock.lock()
            defer { lock.unlock() }
            return result
        }

        private func install(_ continuation: CheckedContinuation<ReceiptRotationVoidRace, Never>) {
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    private func runReceiptRotationHandshakeWithTimeout(
        socket: ProviderWebSocketTask,
        newKey: Curve25519.Signing.PrivateKey
    ) async throws -> (publicKey: String, session: Tier2ProviderSession, response: [String: Any]) {
        let timeoutNanoseconds = receiptKeyRotationTimeoutNanoseconds
        let completion = ReceiptRotationHandshakeCompletion()
        let handshakeTask = Task {
            do {
                let result = try await performRotatedAuthHandshake(socket, newKey: newKey)
                completion.complete(.completed(.success(ReceiptRotationHandshakeValue(
                    publicKey: result.publicKey,
                    session: result.session,
                    response: result.response
                ))))
            } catch {
                completion.complete(.completed(.failure(error)))
            }
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                completion.complete(.timedOut)
            } catch {
                return
            }
        }
        defer {
            handshakeTask.cancel()
            timeoutTask.cancel()
        }

        switch await completion.wait() {
        case .completed(.success(let result)):
            return (result.publicKey, result.session, result.response)
        case .completed(.failure(let error)):
            throw error
        case .timedOut:
            socket.cancel(with: .goingAway, reason: nil)
            handshakeTask.cancel()
            throw CoordinatorReceiptRotationTimeout(
                timeoutSeconds: Double(timeoutNanoseconds) / 1_000_000_000
            )
        }
    }

    private func performRotatedAuthHandshake(
        _ socket: ProviderWebSocketTask,
        newKey: Curve25519.Signing.PrivateKey
    ) async throws -> (publicKey: String, session: Tier2ProviderSession, response: [String: Any]) {
        let authAttempt = Tier2AuthAttempt()
        let publicKey = Data(newKey.publicKey.rawRepresentation).base64EncodedString()
        let initialMessage = await authInitialMessage(
            attempt: authAttempt,
            providerReceiptPublicKeyOverride: publicKey
        )
        try await send(initialMessage, to: socket)
        let challenge = try await receiveAuthChallenge(from: socket)
        try Task.checkCancellation()
        let session = try makeTier2Session(attempt: authAttempt, challenge: challenge)
        let proofMessage = try await authProofMessage(
            challenge: challenge,
            attempt: authAttempt,
            initialMessage: initialMessage
        )
        try Task.checkCancellation()
        try await send(proofMessage, to: socket)
        let response = try await receiveAuthResponse(from: socket)
        try Task.checkCancellation()
        return (publicKey, session, response)
    }

    private func authenticateRotatedSocket(
        _ socket: ProviderWebSocketTask,
        newKey: Curve25519.Signing.PrivateKey,
        commitKey: @escaping @Sendable () async throws -> Void
    ) async throws {
        let handshake = try await runReceiptRotationHandshakeWithTimeout(socket: socket, newKey: newKey)
        try validateAcceptedAuthResponse(handshake.response, session: handshake.session)
        try await commitKey()
        providerReceiptPublicKey = handshake.publicKey
        do {
            try await acceptCoordinatorSession(handshake.response, reason: "coordinator rotated receipt key accepted")
        } catch {
            print("WARN coordinator rotated receipt key committed but session activation failed; retrying committed receipt key publication last_error=\(error)")
            socket.cancel(with: .goingAway, reason: nil)
            await cleanupConnection()
            do {
                try await restoreReceiptRotationSessionWithTimeout()
                return
            } catch {
                throw CoordinatorReceiptRotationCommittedRecoveryFailed(underlying: String(describing: error))
            }
        }
        installTier2Session(handshake.session, socket: socket)
        runTask = Task { [weak self] in
            await self?.runAuthenticatedSocketThenReconnect(socket)
        }
    }

    private func restoreReceiptRotationSessionWithTimeout() async throws {
        let timeoutNanoseconds = receiptKeyRotationTimeoutNanoseconds
        let socket = try await openWebSocket()
        let completion = ReceiptRotationVoidCompletion()
        let restoreTask = Task {
            do {
                try await restoreReceiptRotationSession(on: socket)
                completion.complete(.completed(.success(())))
            } catch {
                completion.complete(.completed(.failure(error)))
            }
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                completion.complete(.timedOut)
            } catch {
                return
            }
        }
        defer {
            restoreTask.cancel()
            timeoutTask.cancel()
        }

        switch await completion.wait() {
        case .completed(.success):
            return
        case .completed(.failure(let error)):
            throw error
        case .timedOut:
            socket.cancel(with: .goingAway, reason: nil)
            restoreTask.cancel()
            if webSocket === socket {
                webSocket = nil
            }
            await cleanupConnection()
            throw CoordinatorReceiptRotationTimeout(
                timeoutSeconds: Double(timeoutNanoseconds) / 1_000_000_000
            )
        }
    }

    private func restoreReceiptRotationSession(on socket: ProviderWebSocketTask) async throws {
        do {
            let authAttempt = Tier2AuthAttempt()
            let initialMessage = await authInitialMessage(attempt: authAttempt)
            try await send(initialMessage, to: socket)
            let challenge = try await receiveAuthChallenge(from: socket)
            try Task.checkCancellation()
            let session = try makeTier2Session(attempt: authAttempt, challenge: challenge)
            let proofMessage = try await authProofMessage(
                challenge: challenge,
                attempt: authAttempt,
                initialMessage: initialMessage
            )
            try Task.checkCancellation()
            try await send(proofMessage, to: socket)
            let response = try await receiveAuthResponse(from: socket)
            try Task.checkCancellation()
            try await acceptAuthResponse(response, session: session)
            try Task.checkCancellation()
            installTier2Session(session, socket: socket)
            runTask = Task { [weak self] in
                await self?.runAuthenticatedSocketThenReconnect(socket)
            }
        } catch {
            if webSocket === socket {
                webSocket = nil
            }
            socket.cancel(with: .goingAway, reason: nil)
            await cleanupConnection()
            throw error
        }
    }

    private func installTier2Session(_ session: Tier2ProviderSession, socket: ProviderWebSocketTask) {
        tier2Session = session
        inferenceRelay = InferenceRelay(
            modelRuntime: modelRuntime,
            providerStatus: providerStatus,
            loadedModelID: loadedModelID,
            catalogModelIDAlias: catalogModelIDForCoordinator,
            warmSwapEnabled: warmSwapEnabled,
            maxActiveRequests: maxActiveRequests,
            maxBodyBytes: maxBodyBytes,
            tier2Session: session,
            receiptBuilder: receiptBuilder,
            receiptProviderID: providerID,
            streamInterval: streamInterval,
            demoteAutoupdateTrust: { [weak self] reason in
                await self?.markAutoupdateTrustDemoted(reason: reason)
            },
            sendFrame: { payload in
                try await Self.send(payload, to: socket)
            }
        )
    }

    private func markAutoupdateTrustDemoted(reason: String) {
        autoupdateDemotionReason = reason
    }

    private func runAuthenticatedSocketThenReconnect(_ socket: ProviderWebSocketTask) async {
        do {
            try await receiveLoop(socket)
            await cleanupConnection()
            runTask = nil
            startReconnectTask()
        } catch is CancellationError {
            await cleanupConnection()
            runTask = nil
        } catch is CoordinatorDrainComplete {
            await cleanupConnection()
            runTask = nil
            print("coordinator reconnect attempt 1 scheduled after drain")
            try? await Task.sleep(nanoseconds: reconnectGraceNanoseconds)
            startReconnectTask()
        } catch is CoordinatorAuthUpgradeReconnect {
            await cleanupConnection()
            runTask = nil
            print("coordinator reconnect scheduled after provisional token adoption")
            try? await Task.sleep(nanoseconds: reconnectGraceNanoseconds)
            startReconnectTask()
        } catch {
            await cleanupConnection()
            runTask = nil
            print("WARN coordinator rotated session ended last_error=\(error)")
            startReconnectTask()
        }
    }

    private func connectAndRun() async throws {
        let socket = try await openWebSocket()
        if wsTunneledMode {
            try await connectAndRunTier2(socket: socket)
        } else {
            try await connectAndRunLegacy(socket: socket)
        }
    }

    private func openWebSocket() async throws -> ProviderWebSocketTask {
        var request = URLRequest(url: coordinatorURL)
        // M1-1 / XSEC-1: attach Authorization: Bearer when the operator has
        // issued this provider a token. Coordinator validates the header in
        // its WS upgrade path (server.go:236-262) and rejects with
        // CloseInvalidToken when auth.require_provider_tokens=true.
        // The token never appears in log lines — redactedURL only logs the
        // URL, not headers, and we don't dump headers anywhere.
        if let token = providerToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let socket = webSocketFactory(request)
        webSocket = socket
        socket.resume()
        Self.keepaliveDebug("ws_resume url=\(Self.redactedURL(coordinatorURL)) token=\(providerToken == nil ? "absent" : "present")")
        try await Self.waitForWebSocketReady(socket)
        return socket
    }

    /// URLSessionWebSocketTask.send() fails with NSPOSIXErrorDomain Code=57
    /// ("Socket is not connected") when called immediately after resume(), before
    /// the TCP/TLS/WS handshake completes. Reconnect loops then spam WARN lines
    /// and leave the provider absent from the pool during the backoff window.
    private static func waitForWebSocketReady(_ socket: ProviderWebSocketTask, timeoutSeconds: Double = 15) async throws {
        guard let urlTask = socket as? URLSessionWebSocketTask else { return }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var lastError: Error?
        while Date() < deadline {
            if Task.isCancelled { throw CancellationError() }
            switch urlTask.state {
            case .completed, .canceling:
                throw lastError ?? CoordinatorAuthError.invalidMessage("WebSocket closed before ready")
            case .running:
                do {
                    try await urlTask.sendPing()
                    return
                } catch {
                    lastError = error
                }
            default:
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw lastError ?? CoordinatorAuthError.invalidMessage("WebSocket timed out waiting for ready")
    }

    private func connectAndRunTier2(socket: ProviderWebSocketTask) async throws {
        let authAttempt = Tier2AuthAttempt()
        let initialMessage = await authInitialMessage(attempt: authAttempt)
        try await send(initialMessage)
        let challenge: [String: Any] = try await receiveAuthChallenge(from: socket)
        let session = try makeTier2Session(attempt: authAttempt, challenge: challenge)
        try await send(try await authProofMessage(
            challenge: challenge,
            attempt: authAttempt,
            initialMessage: initialMessage
        ))
        let response = try await receiveAuthResponse(from: socket)
        try await acceptAuthResponse(response, session: session)
        installTier2Session(session, socket: socket)
        try await receiveLoop(socket)
    }

    private func connectAndRunLegacy(socket: ProviderWebSocketTask) async throws {
        tier2Session = nil
        // endpoint_url legacy mode — no relay needed.
        inferenceRelay = nil
        try await send(await helloMessage())
        try await receiveLoop(socket)
    }

    // Receive/handle decoupling (provider WS drain fix). Previously this loop
    // ran `await socket.receive()` then `await handle(message)` serially on the
    // CoordinatorClient actor. While handle() suspended — drain's
    // waitUntilDrained (up to drainTimeoutSeconds), warm_up's two state_update
    // writes, acceptCoordinatorSession's token-persist + state_update, or an
    // InferenceRelay actor hop — the actor could not re-enter the loop to call
    // the next receive(). The OS WS read buffer backed up, TCP backpressure made
    // the coordinator's heartbeat/control writes block and time out (~30-48s),
    // and the coordinator dropped the session. A constrained provider thus never
    // held a steady `ready` heartbeat.
    //
    // The fix splits receiving from handling across two structured child tasks:
    //   - the receive task does only `socket.receive()` -> `continuation.yield`
    //     and loops straight back, so the socket is always drained promptly;
    //   - one drainer task consumes the stream and calls handle() serially,
    //     preserving inbound frame ordering (control/heartbeat frames are no
    //     longer blocked by inference handling, which spawns its own child Task
    //     in InferenceRelay and returns quickly).
    // The inbox is .unbounded: AsyncStream.yield never suspends, so it never
    // re-introduces producer backpressure, and unbounded never drops a control
    // frame (a bounded buffering policy would silently drop cancel/drain/
    // inference frames). On any handle() throw (e.g. CoordinatorDrainComplete or
    // a send failure) the drainer rethrows; the first child to finish ends the
    // connection and the group cancels its sibling, so the error unwinds to
    // runReconnectLoop exactly as before.
    private func receiveLoop(_ socket: ProviderWebSocketTask) async throws {
        let (inbox, continuation) = AsyncStream.makeStream(
            of: URLSessionWebSocketTask.Message.self,
            bufferingPolicy: .unbounded
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            // Receive task: keep the socket drained. Captures `socket` and
            // `continuation` (both Sendable), never `self`, so nothing here
            // hops onto the actor and stalls the next receive().
            group.addTask {
                defer { continuation.finish() }
                while !Task.isCancelled {
                    let message: URLSessionWebSocketTask.Message
                    do {
                        message = try await socket.receive()
                    } catch {
                        Self.keepaliveDebug("ws_receive_error error=\(error)")
                        throw error
                    }
                    continuation.yield(message)
                }
            }

            // Drainer task: serial handle() preserves frame ordering. The actor
            // hop on self.handle is the serialization point and is race-free.
            group.addTask { [self] in
                for await message in inbox {
                    try Task.checkCancellation()
                    try await handle(message)
                }
            }

            // The first child to finish (normal end or throw) ends the
            // connection; cancel the sibling and unwind. Rethrowing here
            // carries CoordinatorDrainComplete / receive errors to
            // runReconnectLoop unchanged.
            do {
                try await group.next()
            } catch {
                group.cancelAll()
                throw error
            }
            group.cancelAll()
        }
    }

    private func cleanupConnection() async {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        heartbeatWatchdogTask?.cancel()
        heartbeatWatchdogTask = nil
        sleepAssertion?.stop()
        sleepAssertion = nil
        await inferenceRelay?.cancelAllAndClear()
        inferenceRelay = nil
        tier2Session = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        coordinatorSessionAccepted = false
        autoupdateCoordinatorPayload = [:]
        autoupdateCoordinatorPayloadIsV2 = false
        autoupdateAssignedProviderTokenAdopted = false
        autoupdateDemotionReason = "coordinator_disconnected"
        autoupdateTrustState = AutoUpdateTrustState(
            v2Accepted: false,
            tier: nil,
            encryptedLegValid: false,
            attestationRequired: false,
            attestationSatisfied: false,
            tokenConfigured: false,
            tokenValidated: false,
            bearerlessDuplicate: false,
            connected: false
        )
        await providerStatus.setCoordinatorSession(connected: false)
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) async throws {
        // Issue #189 R1 security MEDIUM: the watchdog measures local
        // send completion, which a one-way-broken socket can satisfy
        // indefinitely (OS-level queueing while the coordinator has
        // stopped receiving). Bump the success timestamp on EVERY
        // received frame too, so a coordinator that has stopped
        // talking back (the actual signal we care about) trips the
        // watchdog within tolerance.
        recordHeartbeatSuccess()

        let text: String
        switch message {
        case .string(let value):
            text = value
        case .data(let data):
            text = String(decoding: data, as: UTF8.self)
        @unknown default:
            try await sendNAK(inReplyTo: "unknown", code: "unsupported_frame", message: "Unsupported WebSocket frame")
            return
        }

        guard let data = text.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let dict = raw as? [String: Any],
              let type = dict["type"] as? String
        else {
            try await sendNAK(inReplyTo: "unknown", code: "invalid_json", message: "Coordinator message must be a JSON object")
            return
        }
        Self.keepaliveDebug("ws_recv type=\(type) bytes=\(text.utf8.count)")

        switch type {
        case "hello_ack":
            try await acceptCoordinatorSession(dict, reason: "coordinator hello_ack received")
        case "ownership_event":
            try await handleOwnershipEvent(dict)
        case "ownership_status":
            try await handleOwnershipStatus(dict)
        case "preflight":
            try await handlePreflight(dict)
        case "inference_request":
            guard wsTunneledMode, let inferenceRelay else {
                try await sendNAK(
                    inReplyTo: type,
                    code: "unknown_message_type",
                    message: "Unrecognized message type: '\(type)'"
                )
                return
            }
            try await inferenceRelay.handleInferenceRequest(dict)
        case "cancel_request":
            guard wsTunneledMode, let inferenceRelay else {
                try await sendNAK(
                    inReplyTo: type,
                    code: "unknown_message_type",
                    message: "Unrecognized message type: '\(type)'"
                )
                return
            }
            try await inferenceRelay.handleCancelRequest(dict)
        case "drain":
            // SPEC-001 v1.1.3: coordinator drain stops registration only.
            // The local buyer HTTP server keeps serving. Throwing
            // CoordinatorDrainComplete unwinds connectAndRun and signals
            // the reconnect loop to wait a grace period before reconnecting.
            try await drainFromCoordinator(reason: "coordinator drain requested")
            throw CoordinatorDrainComplete()
        case "warm_up":
            try await sendStateUpdate(state: .degraded, reason: "coordinator warm_up requested")
            try await sendStateUpdate(state: .ready, reason: "warm_up complete")
        case "se_liveness_challenge":
            try await handleSELivenessChallenge(dict)
        default:
            try await sendNAK(
                inReplyTo: type,
                code: "unknown_message_type",
                message: "Unrecognized message type: '\(type)'"
            )
        }
    }

    func handleCoordinatorPayloadForTest(_ payload: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        try await handle(.string(String(decoding: data, as: UTF8.self)))
    }

    func acceptAuthResponseForTest(_ response: [String: Any], session: Tier2ProviderSession) async throws {
        try await acceptAuthResponse(response, session: session)
    }

    private func handleOwnershipEvent(_ payload: [String: Any]) async throws {
        guard let providerID = payload["provider_id"] as? String,
              providerID == self.providerID,
              let login = payload["github_login"] as? String,
              let rawEvent = payload["event"] as? String,
              let event = OwnershipEventKind(rawValue: rawEvent)
        else {
            try await sendNAK(inReplyTo: "ownership_event", code: "invalid_message", message: "Invalid ownership_event frame")
            return
        }
        try pairingController.handleOwnershipEvent(OwnershipEventFrame(providerID: providerID, githubLogin: login, event: event))
    }

    private func handleOwnershipStatus(_ payload: [String: Any]) async throws {
        guard let providerID = payload["provider_id"] as? String, providerID == self.providerID else {
            try await sendNAK(inReplyTo: "ownership_status", code: "invalid_message", message: "Invalid ownership_status frame")
            return
        }
        if payload["needs_claim"] as? Bool == true {
            try pairingController.handleNeedsClaim()
        }
    }

    func sendHeartbeatForTest() async throws {
        try await sendHeartbeat()
    }

    // Issue #189: test seam — exercise the 5s timeout against an
    // injected sendOverride that never returns.
    func sendHeartbeatBoundedForTest(resetWindow: Bool = true) async throws {
        try await sendHeartbeatBounded(resetWindow: resetWindow)
    }

    // Issue #189: test seam — start a watchdog with a short interval
    // and verify it fires the exit hook when last-success is stale.
    func startHeartbeatWatchdogForTest(intervalSeconds: Int) {
        startHeartbeatWatchdog(intervalSeconds: intervalSeconds)
    }

    func seedLastHeartbeatSuccessForTest(ageNanoseconds: UInt64) {
        let now = DispatchTime.now().uptimeNanoseconds
        lastHeartbeatSuccessNanoseconds = now > ageNanoseconds ? now - ageNanoseconds : 1
    }

    func cancelHeartbeatWatchdogForTest() {
        heartbeatWatchdogTask?.cancel()
        heartbeatWatchdogTask = nil
    }

    // Issue #189 R1 security MEDIUM: assert that any inbound frame
    // bumps the heartbeat success timestamp via handle().
    func handleForTest(_ message: URLSessionWebSocketTask.Message) async throws {
        try await handle(message)
    }

    func nanosecondsSinceLastHeartbeatSuccessForTest() -> UInt64 {
        nanosecondsSinceLastHeartbeatSuccess()
    }

    private func receiveAuthChallenge(from socket: ProviderWebSocketTask) async throws -> [String: Any] {
        let challenge = try await Self.receiveJSONObject(from: socket)
        guard challenge["type"] as? String == "auth_challenge",
              Self.intValue(challenge["version"]) == 2
        else {
            throw CoordinatorAuthError.invalidMessage("Expected auth_challenge v2")
        }
        return challenge
    }

    private func receiveAuthResponse(from socket: ProviderWebSocketTask) async throws -> [String: Any] {
        let response = try await Self.receiveJSONObject(from: socket)
        guard response["type"] as? String == "auth_response",
              Self.intValue(response["version"]) == 2
        else {
            throw CoordinatorAuthError.invalidMessage("Expected auth_response v2")
        }
        return response
    }

    private func makeTier2Session(attempt: Tier2AuthAttempt, challenge: [String: Any]) throws -> Tier2ProviderSession {
        guard let assignedID = challenge["assigned_id"] as? String,
              let coordinatorPublicKey = challenge["coordinator_ecdh_public_key"] as? String
        else {
            throw CoordinatorAuthError.invalidMessage("auth_challenge missing assigned_id or coordinator_ecdh_public_key")
        }
        let selectedAEAD = (challenge["selected_aead_suite"] as? String) ?? (challenge["selected_aead"] as? String) ?? ""
        guard !selectedAEAD.isEmpty else {
            throw CoordinatorAuthError.invalidMessage("auth_challenge missing selected_aead_suite")
        }
        return try Tier2ProviderSession(
            attempt: attempt,
            providerID: providerID,
            assignedID: assignedID,
            coordinatorPublicKeyBase64URL: coordinatorPublicKey,
            selectedAEAD: selectedAEAD,
            expectedKeyID: challenge["key_id"] as? String
        )
    }

    func authProofMessage(
        challenge: [String: Any],
        attempt: Tier2AuthAttempt,
        initialMessage: [String: Any]? = nil
    ) async throws -> [String: Any] {
        guard let attemptID = challenge["auth_attempt_id"] as? String, !attemptID.isEmpty else {
            throw CoordinatorAuthError.invalidMessage("auth_challenge missing auth_attempt_id")
        }
        let snapshot = await providerStatus.snapshot()
        let token = await attestationGenerator.makeAttestationToken(
            challengeBase64URL: challenge["attestation_challenge"] as? String,
            authAttemptID: attemptID,
            providerID: providerID,
            binaryVersion: Self.binaryVersion,
            snapshot: snapshot,
            providerECDHPublicKey: attempt.publicKeyBase64URL
        )
        var proof: [String: Any] = [
            "type": "auth_request",
            "version": 2,
            "stage": "proof",
            "auth_attempt_id": attemptID,
            "provider_id": providerID,
        ]
        proof["attestation_token"] = token ?? NSNull()

        // SPEC-026 §7: if we have both the initial-stage message (needed
        // to compute the retained transcript hash) and an
        // IdentitySignatureBridge (i.e. Malibu.app is attached), ask
        // Malibu to sign the canonical tuple with its Keychain Ed25519
        // key. Failure to obtain a signature falls through — the
        // coordinator's `identitySignatures == nil` gate or per-provider
        // exemption at `identity_signature.go:38` covers the CLI-track
        // path.
        if let identityBridge, let initialMessage,
           let transcriptSHA256 = try? Self.initialAuthTranscriptHashBase64(initialMessage) {
            let request = IdentitySignatureBridge.Request(
                authAttemptID: attemptID,
                providerID: providerID,
                binaryVersion: Self.binaryVersion,
                providerECDHPublicKey: attempt.publicKeyBase64URL,
                transcriptSHA256: transcriptSHA256
            )
            let response = await identityBridge.requestSignature(
                request,
                timeout: identitySignatureTimeoutSeconds
            )
            if let response, response.accepted,
               let signature = response.identitySignature,
               let echoed = response.transcriptSHA256 {
                proof["identity_signature"] = signature
                proof["identity_signature_transcript_sha256"] = echoed
            }
        }

        return proof
    }

    /// Compute `base64(SHA-256(CanonicalJSON(initialMessage)))`. Matches
    /// what the coordinator retains from the initial auth_request stage
    /// via `phase4-coordinator/internal/ws/identity_signature.go:15`.
    static func initialAuthTranscriptHashBase64(_ message: [String: Any]) throws -> String {
        let canonical = try CanonicalJSON.encode(CanonicalJSON.fromJSONLike(message))
        let digest = SHA256.hash(data: canonical)
        return Data(digest).base64EncodedString()
    }

    private func acceptAuthResponse(_ response: [String: Any], session: Tier2ProviderSession) async throws {
        try validateAcceptedAuthResponse(response, session: session)
        tier2Session = session
        try await acceptCoordinatorSession(response, reason: "coordinator auth_response accepted")
    }

    private func validateAcceptedAuthResponse(_ response: [String: Any], session: Tier2ProviderSession) throws {
        guard response["status"] as? String == "accepted" else {
            let error = response["error"] as? [String: Any]
            throw CoordinatorAuthError.rejected(
                code: error?["code"] as? String ?? "auth_rejected",
                message: error?["message"] as? String ?? "Coordinator rejected auth_response"
            )
        }
        guard let tier2 = response["tier2_session"] as? [String: Any],
              let encryptedLeg = tier2["encrypted_leg"] as? [String: Any],
              encryptedLeg["enabled"] as? Bool == true,
              encryptedLeg["alg"] as? String == session.selectedAEAD,
              encryptedLeg["kid"] as? String == session.keyID
        else {
            throw CoordinatorAuthError.invalidMessage("auth_response missing matching encrypted_leg session")
        }
        if encryptedLeg["response_chunk_plaintext_envelope"] as? Bool == true {
            session.enableResponseChunkPlaintextEnvelope()
        }
    }

    /// SPEC-003 v0.8.2 FR-C9.3 — extract `assigned_provider_token` from
    /// a hello_ack / auth_response payload, persist it to disk via a
    /// detached I/O task, and adopt it in-memory ONLY on persist
    /// success. The token is `await`-gated by the persist outcome.
    ///
    /// v0.8.2 hardening: v0.8.1 implemented this as "adopt in memory
    /// FIRST, then fire-and-forget detached persist". The codex security
    /// re-audit on PR #44 (MINOR-1) flagged the brick-mode window:
    /// process crash / SIGKILL between in-memory adoption and persist
    /// flush leaves the coordinator holding a valid token row that the
    /// binary will never use. On next process restart the binary
    /// reconnects tokenless, the coordinator's FR-C9.4 TOFU gate refuses
    /// it ("an active token already exists"), and the provider is
    /// bricked until operator runs `coordinator-cli revoke-token`.
    ///
    /// v0.8.2 closes this by awaiting the persist task before adopting
    /// in memory. The disk I/O still runs on a detached priority-utility
    /// task so the receive loop is suspended (not the whole runtime)
    /// during the ~10ms persist; this preserves the FR-C9.3 SHOULD-not-
    /// block contract because it is a `Task.detached(...).value` await,
    /// not a sync blocking call.
    ///
    /// On persist failure the in-memory token is NOT adopted. The
    /// current WS session continues with whatever bearer (if any) was
    /// already configured — the connect already authenticated, so the
    /// session itself is fine. Next reconnect attempt will retry from
    /// scratch and the legitimate provider can mint cleanly. The
    /// asymmetry "coordinator has token / binary doesn't" never appears
    /// in this design.
    private func adoptAssignedProviderTokenIfPresent(_ payload: [String: Any]) async -> Bool {
        guard let assigned = payload["assigned_provider_token"] as? String else {
            return false
        }
        let trimmed = assigned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }
        // AUDIT R1 SECURITY S4 fix (PR #334) — when the CLI is spawned as a
        // managed child of Malibu.app, disk persistence of the bearer token
        // is contrary to the App-track security model: the app stores the
        // token in Keychain and NEVER wants it landed in
        // ~/.config/macprovider/config.yaml. We still adopt in-memory so
        // the current WS session keeps authenticating, and emit an event
        // so operators can see the skip. Keychain-side rotation lands with
        // SPEC-025 §11 P1 alongside the "CLI reads Keychain directly" work.
        if appConfig.managedBy == "malibu-app" {
            self.providerToken = trimmed
            Self.emitTokenPersistEvent(
                event: "provider_token_persist_skipped_managed_by_malibu_app",
                path: configPath,
                error: nil
            )
            return true
        }
        let path = configPath
        let result: Result<Void, Error> = await Task.detached(priority: .utility) {
            do {
                try ProviderTokenPersist.write(token: trimmed, configPath: path)
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .success:
            self.providerToken = trimmed
            Self.emitTokenPersistEvent(event: "provider_token_persisted", path: path, error: nil)
            return true
        case .failure(let error):
            Self.emitTokenPersistEvent(event: "provider_token_persist_failed", path: path, error: error)
            return false
        }
    }

    /// Emit a structured-log line for the FR-C9.3 persist outcome via
    /// `JSONSerialization` so embedded paths or error descriptions
    /// containing quotes/backslashes/newlines cannot break the JSON
    /// envelope. All three codex auditors (code, security, architect)
    /// independently flagged the previous hand-built JSON as injectable.
    private static func emitTokenPersistEvent(event: String, path: String, error: Error?) {
        var payload: [String: String] = [
            "event": event,
            "config_path": path,
        ]
        if let error {
            payload["error"] = String(describing: error)
        }
        do {
            var data = try JSONSerialization.data(withJSONObject: payload, options: [])
            data.append(0x0A)  // trailing newline
            FileHandle.standardError.write(data)
        } catch {
            // Encoder failure on a String:String dict is essentially
            // impossible; fall back to a safe minimal line so the
            // operator still sees something.
            FileHandle.standardError.write(Data(("{\"event\":\"" + event + "\"}\n").utf8))
        }
    }

    private func acceptCoordinatorSession(_ payload: [String: Any], reason: String) async throws {
        // SPEC-003 v0.8.2 FR-C9.3 — single hook for both v1 (hello_ack)
        // and v2 (auth_response) ack paths since both funnel here.
        // Awaited so that persist-before-adopt holds: see
        // adoptAssignedProviderTokenIfPresent doc-comment.
        let assignedProviderTokenAdopted = await adoptAssignedProviderTokenIfPresent(payload)
        if assignedProviderTokenAdopted {
            // The current tokenless WS session stays auth_state=self_minted and is
            // not buyer-routable until we reconnect with Authorization: Bearer.
            throw CoordinatorAuthUpgradeReconnect()
        }
        do {
            try pairingController.handlePairingMaterial(
                pairOT: payload["pair_ot"] as? String,
                claimURL: payload["claim_url"] as? String,
                portalBaseURL: payload["portal_base_url"] as? String
            )
        } catch {
            Self.emitClaimURLHandoffEvent(error: error)
        }
        let interval = max(Self.intValue(payload["heartbeat_interval_s"]) ?? 30, 1)
        let isV2 = payload["type"] as? String == "auth_response" && payload["status"] as? String == "accepted"
        autoupdateCoordinatorPayload = payload
        autoupdateCoordinatorPayloadIsV2 = isV2
        autoupdateAssignedProviderTokenAdopted = assignedProviderTokenAdopted
        autoupdateDemotionReason = nil
        autoupdateTrustState = AutoUpdateTrustState.fromCoordinatorPayload(
            payload,
            isV2: isV2,
            session: tier2Session,
            providerToken: providerToken,
            assignedProviderTokenAdopted: assignedProviderTokenAdopted,
            acceptProvisional: AutoUpdateConfig.acceptProvisional(appConfig)
        )
        autoupdateDrainExtensions = payload["autoupdate_drain_extensions"] as? Bool == true
        autoupdateAttemptedTargets.removeAll()
        await providerStatus.setCoordinatorSession(
            connected: true,
            assignedID: payload["assigned_id"] as? String,
            tier: payload["tier"] as? String,
            recommendedBinaryVersion: payload["recommended_binary_version"] as? String
        )
        coordinatorSessionAccepted = true
        if let tier = payload["tier"] as? String {
            print("Coordinator tier: \(tier)")
        }
        sleepAssertion?.stop()
        sleepAssertion = sleepAssertionFactory()
        startHeartbeat(intervalSeconds: interval)
        let completedAutoupdate = await pendingSuccessfulAutoupdate()
        try await sendStateUpdate(state: nil, reason: reason)
        if let completedAutoupdate {
            let markerStore = AutoUpdateMarkerStore()
            try? markerStore.completeSuccessfulUpdate(completedAutoupdate)
            try? markerStore.finalizeSuccessfulUpdate(completedAutoupdate)
        }
        if let recommended = payload["recommended_binary_version"] as? String {
            let trust = currentAutoupdateTrustState()
            guard trust.isEligible else {
                let parsed = try? AutoUpdateRecommendation.validate(recommended)
                if let parsed,
                   SelfUpdate.compareSemver(Self.binaryVersion, parsed.normalized) == .orderedAscending
                {
                    print("A newer version is available (v\(parsed.normalized)). Run 'macprovider-cli update' to upgrade.")
                }
                await AutoUpdateEventStore.shared.record(AutoUpdateEvent(
                    updateID: UUID().uuidString.lowercased(),
                    currentVersion: Self.binaryVersion,
                    targetVersion: parsed?.normalized ?? "<notify-only>",
                    phase: .eligibility,
                    outcome: .skipped,
                    reason: trust.lossReason,
                    attempt: 1
                ))
                return
            }
            await runAutoupdateIfEligible(recommended)
        }
    }

    private static func emitClaimURLHandoffEvent(error: Error) {
        let payload = [
            "event": "claim_url_handoff_failed",
            "error": String(describing: error),
        ]
        do {
            var data = try JSONSerialization.data(withJSONObject: payload, options: [])
            data.append(0x0A)
            FileHandle.standardError.write(data)
        } catch {
            FileHandle.standardError.write(Data("{\"event\":\"claim_url_handoff_failed\"}\n".utf8))
        }
    }

    private func pendingSuccessfulAutoupdate(markerStore: AutoUpdateMarkerStore = AutoUpdateMarkerStore()) async -> AutoUpdatePendingMarker? {
        guard let marker = try? markerStore.readPending(),
              marker.targetVersion == Self.binaryVersion
        else {
            return nil
        }
        await AutoUpdateEventStore.shared.record(AutoUpdateEvent(
            updateID: marker.updateID,
            currentVersion: Self.binaryVersion,
            targetVersion: marker.targetVersion,
            phase: .postStart,
            outcome: .success,
            reason: "post_start_rejoin_succeeded",
            attempt: 1
        ))
        return marker
    }

    private func runStartupAutoupdateRecovery() async {
        guard let binaryURL = Bundle.main.executableURL else { return }
        await runStartupAutoupdateRecovery(binaryURL: binaryURL, markerStore: AutoUpdateMarkerStore())
    }

    func runStartupAutoupdateRecoveryForTest(binaryURL: URL, markerStore: AutoUpdateMarkerStore) async {
        await runStartupAutoupdateRecovery(binaryURL: binaryURL, markerStore: markerStore)
    }

    private func runStartupAutoupdateRecovery(binaryURL: URL, markerStore: AutoUpdateMarkerStore) async {
        let binaryDir = binaryURL.deletingLastPathComponent()
        let pending: AutoUpdatePendingMarker?
        do {
            pending = try markerStore.readPending()
        } catch {
            markerStore.recoverInvalidPendingMarker()
            await AutoUpdateEventStore.shared.record(AutoUpdateEvent(
                updateID: UUID().uuidString.lowercased(),
                currentVersion: Self.binaryVersion,
                targetVersion: "<invalid>",
                phase: .rollback,
                outcome: .failure,
                reason: "marker_invalid",
                attempt: 1,
                failureClass: .orphanedPendingMarker
            ))
            return
        }
        for sentinel in markerStore.successSentinels(in: binaryDir) {
            let payload: (updateID: String, binaryVersion: String)
            do {
                payload = try markerStore.readSuccessSentinel(sentinel)
            } catch {
                try? FileManager.default.removeItem(at: sentinel)
                continue
            }
            guard payload.binaryVersion == Self.binaryVersion else {
                await recordOrphanedSuccessSentinel(
                    updateID: payload.updateID,
                    targetVersion: payload.binaryVersion,
                    reason: "binary_version_mismatch",
                    sentinel: sentinel
                )
                continue
            }
            guard let pending else {
                await recordOrphanedSuccessSentinel(
                    updateID: payload.updateID,
                    targetVersion: payload.binaryVersion,
                    reason: "no_matching_pending",
                    sentinel: sentinel
                )
                continue
            }
            guard pending.updateID == payload.updateID else {
                await recordOrphanedSuccessSentinel(
                    updateID: payload.updateID,
                    targetVersion: payload.binaryVersion,
                    reason: "update_id_mismatch",
                    sentinel: sentinel
                )
                continue
            }
            await AutoUpdateEventStore.shared.record(AutoUpdateEvent(
                updateID: payload.updateID,
                currentVersion: Self.binaryVersion,
                targetVersion: pending.targetVersion,
                phase: .postStart,
                outcome: .success,
                reason: "post_start_rejoin_succeeded",
                attempt: 1
            ))
            do {
                try await sendStateUpdate(state: nil, reason: "autoupdate_post_start_success")
                try markerStore.completeSuccessfulUpdate(pending)
                try markerStore.finalizeSuccessfulUpdate(pending)
            } catch {
                await AutoUpdateEventStore.shared.record(AutoUpdateEvent(
                    updateID: payload.updateID,
                    currentVersion: Self.binaryVersion,
                    targetVersion: pending.targetVersion,
                    phase: .postStart,
                    outcome: .failure,
                    reason: "post_start_success_publish_or_cleanup_failed",
                    attempt: 1,
                    failureClass: .other
                ))
            }
        }
        if let marker = pending {
            guard Self.autoupdateMarkerDeadlineExpired(marker.markerDeadline) else {
                return
            }
            if !markerStore.updateLockIsLive() {
                let outcome = markerStore.recoverOrphanedMarker(marker)
                switch outcome {
                case .restored(let recovered):
                    await AutoUpdateEventStore.shared.record(AutoUpdateEvent(
                        updateID: recovered.updateID,
                        currentVersion: Self.binaryVersion,
                        targetVersion: recovered.targetVersion,
                        phase: .rollback,
                        outcome: .failure,
                        reason: "orphaned_pending_marker_recovered",
                        attempt: 1,
                        failureClass: .orphanedPendingMarker
                    ))
                case .markerInvalid:
                    await AutoUpdateEventStore.shared.record(AutoUpdateEvent(
                        updateID: UUID().uuidString.lowercased(),
                        currentVersion: Self.binaryVersion,
                        targetVersion: "<invalid>",
                        phase: .rollback,
                        outcome: .failure,
                        reason: "marker_invalid",
                        attempt: 1,
                        failureClass: .orphanedPendingMarker
                    ))
                case let .backupCorrupt(recovered, reason):
                    autoupdateDisabledForSessionReason = "rollback_backup_corrupt"
                    await AutoUpdateEventStore.shared.record(AutoUpdateEvent(
                        updateID: recovered.updateID,
                        currentVersion: Self.binaryVersion,
                        targetVersion: recovered.targetVersion,
                        phase: .rollback,
                        outcome: .failure,
                        reason: reason,
                        attempt: 1,
                        failureClass: .rollbackBackupCorrupt
                    ))
                }
            }
        } else {
            for backup in markerStore.rollbackBackups(in: binaryDir) {
                try? FileManager.default.removeItem(at: backup)
            }
        }
    }

    private func recordOrphanedSuccessSentinel(updateID: String, targetVersion: String, reason: String, sentinel: URL) async {
        try? FileManager.default.removeItem(at: sentinel)
        await AutoUpdateEventStore.shared.record(AutoUpdateEvent(
            updateID: updateID,
            currentVersion: Self.binaryVersion,
            targetVersion: targetVersion,
            phase: .postStart,
            outcome: .failure,
            reason: reason,
            attempt: 1,
            failureClass: .orphanedSuccessSentinel
        ))
    }

    // Provider WS keepalive fix. The coordinator advertises heartbeat_interval_s
    // (typically 30) and we previously slept the FULL interval before the first
    // keepalive, then on each tick sent a WebSocket control PING followed by a
    // heartbeat. That kept a constrained provider out of the `ready` pool via a
    // connect -> i/o-timeout -> disconnect -> reconnect loop, for two reasons
    // confirmed against the coordinator code:
    //
    //   1. A provider->coordinator WS control PING is actively harmful here. The
    //      coordinator's gobwas reader auto-writes a PONG to the raw conn
    //      (server.go readClientData / ControlFrameHandler), but the coordinator
    //      only ever sets the connection write deadline inside its runWriter
    //      text-frame path (relay.go:106, write_timeout_s=10) and never clears
    //      it. Once the connection has been idle past that absolute 10s deadline,
    //      the PONG write fails immediately with "write tcp ... i/o timeout" and
    //      the coordinator drops the session. So the PING we sent to keep the
    //      link alive was the very thing triggering the disconnect — which is
    //      why the drop cadence tracked our ping period.
    //   2. The coordinator does not count provider control frames as liveness:
    //      readProviderLoop ignores any non-text frame (server.go:1127) and only
    //      text frames refresh activity. A PING would not have kept us alive even
    //      without bug (1).
    //
    // The fix: send a heartbeat TEXT frame on a short sub-interval tick and send
    // no control pings. A text frame routes through the coordinator's runWriter,
    // which sets a FRESH write deadline before writing, and reaches handleMessage
    // which refreshes liveness. The tick is capped well under the coordinator's
    // 10s write deadline (and any proxy idle timeout) so the connection never
    // sits idle long enough for the stale-deadline write to fire. The since-last
    // metrics window is still rolled only on the full coordinator interval
    // (resetWindow), so heartbeat metrics are unchanged from before.
    private static let keepaliveTickCeilingSeconds = 5
    // Issue #189: hard ceiling on one heartbeat send. URLSession.send() can
    // queue frames without surfacing TCP half-open until the OS reaps the
    // socket minutes/hours later. 5s comfortably exceeds normal RTT to the
    // coordinator (sub-100ms) and is well under the 90s
    // provider_inactive_threshold, so a wedged send fails fast and the
    // existing closeWebSocketAfterKeepaliveFailure → reconnect path fires
    // before the coordinator decides we're gone.
    private static let heartbeatSendTimeoutSeconds: Double = 5
    // Issue #189: watchdog tolerance, expressed against the actual tick
    // cadence (≤ keepaliveTickCeilingSeconds = 5s) rather than the
    // coordinator-supplied interval. The tick is what produces a
    // success timestamp, so multiplying tickSeconds × 3 (= ≤15s on a
    // 5s tick) gives a hard upper bound that is independent of the
    // coordinator-configured heartbeat interval and is always well
    // below the 90s coordinator inactivity drop.
    private static let heartbeatWatchdogToleranceMultiplier: Int = 3
    private func startHeartbeat(intervalSeconds: Int) {
        heartbeatTask?.cancel()
        heartbeatWatchdogTask?.cancel()
        let tickSeconds = max(1, min(intervalSeconds, Self.keepaliveTickCeilingSeconds))
        Self.keepaliveDebug("heartbeat_start interval_s=\(intervalSeconds) tick_s=\(tickSeconds)")
        // Seed last-success to "now" so the watchdog doesn't fire before
        // the very first tick completes.
        lastHeartbeatSuccessNanoseconds = DispatchTime.now().uptimeNanoseconds
        startHeartbeatWatchdog(intervalSeconds: intervalSeconds)
        heartbeatTask = Task { [weak self] in
            var secondsSinceWindowReset = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(tickSeconds) * 1_000_000_000)
                if Task.isCancelled {
                    return
                }
                secondsSinceWindowReset += tickSeconds
                // Roll the metrics window only on the full coordinator interval;
                // intermediate ticks are keepalive heartbeats that report the
                // same accumulating window without resetting it.
                let rollWindow = secondsSinceWindowReset >= intervalSeconds
                if rollWindow {
                    secondsSinceWindowReset = 0
                }
                do {
                    // Issue #189: bound the send so a wedged URLSession does
                    // not silently absorb every tick for hours.
                    try await self?.sendHeartbeatBounded(resetWindow: rollWindow)
                    await self?.recordHeartbeatSuccess()
                } catch {
                    Self.keepaliveDebug("keepalive_send_error error=\(error)")
                    await self?.closeWebSocketAfterKeepaliveFailure()
                    return
                }
            }
        }
    }

    // Issue #189: separate liveness observer. The heartbeat task itself
    // can be App Nap-starved (the originally reported failure mode); a
    // task that just sleeps and inspects a timestamp is cheaper to
    // schedule and acts as an independent timer of last resort.
    //
    // Tolerance derives from tickSeconds (the actual tick cadence,
    // capped at keepaliveTickCeilingSeconds = 5s), NOT from the
    // coordinator-supplied intervalSeconds. This keeps the watchdog
    // tolerance bounded at ~15s regardless of operator/coordinator
    // misconfiguration and avoids integer-overflow math at the
    // extremes (Int.max heartbeat_interval_s no longer traps).
    private func startHeartbeatWatchdog(intervalSeconds: Int) {
        let tickSeconds = max(1, min(intervalSeconds, Self.keepaliveTickCeilingSeconds))
        let tolerance = UInt64(tickSeconds * Self.heartbeatWatchdogToleranceMultiplier)
            * 1_000_000_000
        // Check at a sub-tick cadence so an overrun is detected within
        // one extra tick rather than after the next full tick boundary.
        let checkNanoseconds = UInt64(tickSeconds) * 500_000_000
        let hook = watchdogExitHook
        heartbeatWatchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: checkNanoseconds)
                if Task.isCancelled { return }
                guard let self else { return }
                let elapsed = await self.nanosecondsSinceLastHeartbeatSuccess()
                // Issue #189 R2 security LOW: recheck cancellation
                // AFTER the actor hop. A drain entry that lands
                // between the actor await and the hook invocation
                // could otherwise lose the race to Darwin.exit(1).
                if Task.isCancelled { return }
                if elapsed >= tolerance {
                    hook("heartbeat liveness exceeded tolerance: \(elapsed / 1_000_000_000)s since last success >= \(tolerance / 1_000_000_000)s")
                    return
                }
            }
        }
    }

    private func recordHeartbeatSuccess() {
        lastHeartbeatSuccessNanoseconds = DispatchTime.now().uptimeNanoseconds
    }

    private func nanosecondsSinceLastHeartbeatSuccess() -> UInt64 {
        let last = lastHeartbeatSuccessNanoseconds
        guard last != 0 else { return 0 }
        let now = DispatchTime.now().uptimeNanoseconds
        return now > last ? now - last : 0
    }

    // Issue #189: structured concurrency wrapper. The send task races a
    // sleep task; whichever finishes first wins and the other is
    // cancelled.
    //
    // Subtlety (R1 code/architect/security HIGH↔MEDIUM convergent):
    // URLSessionWebSocketTask.send() is NOT cancellation-cooperative
    // once the underlying TCP socket is half-open; Task.cancel alone
    // will not unblock it, and TaskGroup deinit awaits all children.
    // Before the timeout child throws, it explicitly calls
    // cancel(with:reason:) on the captured WebSocket task — that
    // forces URLSession to surface a transport error on the in-flight
    // send, which lets the send child unwind so the group can return.
    // In production the captured socket is non-nil; in unit tests
    // the WS is mocked via sendOverride and the cancellation arrives
    // through the existing cooperative Task.cancel path.
    private func sendHeartbeatBounded(resetWindow: Bool) async throws {
        let socketRef = webSocket
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                try await self?.sendHeartbeat(resetWindow: resetWindow)
            }
            group.addTask {
                let nanoseconds = UInt64(Self.heartbeatSendTimeoutSeconds * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
                // Force the wedged URLSession.send() to error out so
                // the racing send child can unwind. Calling cancel on
                // a closed/nil task is safe and idempotent.
                socketRef?.cancel(with: .goingAway, reason: nil)
                throw CoordinatorHeartbeatSendTimeout(timeoutSeconds: Self.heartbeatSendTimeoutSeconds)
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    private func closeWebSocketAfterKeepaliveFailure() {
        webSocket?.cancel(with: .goingAway, reason: nil)
    }

    private func handlePreflight(_ message: [String: Any]) async throws {
        let requestID = message["request_id"] as? String ?? ""
        let estimatedTokens = message["estimated_tokens"] as? Int ?? 0
        let snapshot = await providerStatus.snapshot()

        if estimatedTokens > snapshot.capacity.maxContextTokens {
            try await send([
                "type": "preflight_ack",
                "request_id": requestID,
                "accepted": false,
                "reason": "context_exceeds_capacity",
                "max_context_tokens": snapshot.capacity.maxContextTokens,
            ])
        } else if snapshot.status == .draining {
            try await send([
                "type": "preflight_ack",
                "request_id": requestID,
                "accepted": false,
                "reason": "draining",
            ])
        } else if !snapshot.modelLoaded {
            try await send([
                "type": "preflight_ack",
                "request_id": requestID,
                "accepted": false,
                "reason": "model_not_loaded",
            ])
        } else if snapshot.status == .unavailable {
            try await send([
                "type": "preflight_ack",
                "request_id": requestID,
                "accepted": false,
                "reason": "unhealthy",
            ])
        } else {
            try await send([
                "type": "preflight_ack",
                "request_id": requestID,
                "accepted": true,
                "estimated_wait_ms": 0,
            ])
        }
    }

    func drainAndExit(reason: String, exitCode: Int32 = 0) async {
        // Used by SIGTERM signal handler — drain in-flight buyer requests,
        // notify coordinator, then exit the whole process.
        // Issue #189 R1 security LOW: cancel the heartbeat watchdog on
        // drain entry. Otherwise a watchdog-triggered Darwin.exit(1)
        // could race the orderly drain and drop the final drain_status
        // frame (and the SIGTERM-requested exit code).
        // R2 security LOW: also stop the heartbeat tick task here so a
        // bounded-send timeout cannot force-cancel the WS while the
        // drain_status sequence is still being emitted.
        heartbeatTask?.cancel()
        heartbeatTask = nil
        heartbeatWatchdogTask?.cancel()
        heartbeatWatchdogTask = nil
        try? await sendStateUpdate(state: .draining, reason: reason)
        try? await sendDrainStatus(phase: "starting")
        try? await sendDrainStatus(phase: "in_progress")
        let drained = await providerStatus.waitUntilDrained(timeoutSeconds: drainTimeoutSeconds)
        if !drained {
            await inferenceRelay?.cancelAll()
            _ = await inferenceRelay?.waitUntilIdle(timeoutSeconds: 5)
        }
        try? await sendDrainStatus(phase: "complete")
        webSocket?.cancel(with: .goingAway, reason: nil)
        Darwin.exit(exitCode)
    }

    /// Handle a coordinator-initiated drain (typically because the coordinator
    /// is shutting down or restarting). Sends the drain_status sequence,
    /// closes the WebSocket, but does NOT exit the process — the local buyer
    /// HTTP server keeps serving direct traffic. The reconnect loop will
    /// attempt to rejoin the coordinator after a grace period.
    /// SPEC-001 v1.1.4 § 6.5: after drain_status=complete, the provider's
    /// internal state machine MUST be reset back to .ready before the next
    /// hello, since hello starts a fresh coordinator session and any
    /// `draining` status carried over from the previous session would be
    /// reported in the very first heartbeat and stick (the coordinator
    /// has no implicit "draining → ready" transition).
    func drainFromCoordinator(reason: String) async throws {
        // Issue #189 R1 security LOW: cancel the watchdog at drain
        // ENTRY (not just at the end of the drain) so a watchdog
        // exit cannot race the in-progress drain_status sequence.
        // R2 security LOW: also stop the heartbeat tick task here so
        // a bounded-send timeout cannot force-cancel the WS while
        // the drain_status sequence is still being emitted.
        heartbeatTask?.cancel()
        heartbeatTask = nil
        heartbeatWatchdogTask?.cancel()
        heartbeatWatchdogTask = nil
        try? await sendStateUpdate(state: .draining, reason: reason)
        try? await sendDrainStatus(phase: "starting")
        try? await sendDrainStatus(phase: "in_progress")
        let drained = await providerStatus.waitUntilDrained(timeoutSeconds: drainTimeoutSeconds)
        if !drained {
            await inferenceRelay?.cancelAll()
            _ = await inferenceRelay?.waitUntilIdle(timeoutSeconds: 5)
        }
        try? await sendDrainStatus(phase: "complete")
        webSocket?.cancel(with: .goingAway, reason: nil)
        heartbeatTask?.cancel()
        heartbeatTask = nil
        heartbeatWatchdogTask?.cancel()
        heartbeatWatchdogTask = nil
        sleepAssertion?.stop()
        sleepAssertion = nil
        // v1.1.4: reset local state for the next coordinator session.
        // Local HTTP server kept serving throughout drain; provider is ready.
        await providerStatus.setState(.ready)
    }

    private func runAutoupdateIfEligible(_ recommended: String) async {
        // SPEC-025 §12 conflict #2 — when the CLI is spawned as a managed child of
        // Malibu.app, Sparkle owns whole-bundle updates end-to-end. Two auto-update
        // paths racing on the same binary would fight over rollback markers and
        // the launchd LaunchAgent. Skip loudly so we can see it in event history.
        if appConfig.managedBy == "malibu-app" {
            let parsedTarget = (try? AutoUpdateRecommendation.validate(recommended))?.normalized ?? "<unvalidated>"
            await AutoUpdateEventStore.shared.record(AutoUpdateEvent(
                updateID: UUID().uuidString.lowercased(),
                currentVersion: Self.binaryVersion,
                targetVersion: parsedTarget,
                phase: .eligibility,
                outcome: .skipped,
                reason: "managed_by_malibu_app",
                attempt: 1
            ))
            return
        }
        if let parsed = try? AutoUpdateRecommendation.validate(recommended) {
            let trust = currentAutoupdateTrustState()
            guard trust.isEligible else {
                await AutoUpdateEventStore.shared.record(AutoUpdateEvent(
                    updateID: UUID().uuidString.lowercased(),
                    currentVersion: Self.binaryVersion,
                    targetVersion: parsed.normalized,
                    phase: .eligibility,
                    outcome: .skipped,
                    reason: trust.lossReason,
                    attempt: 1
                ))
                return
            }
            guard !autoupdateAttemptedTargets.contains(parsed.normalized) else {
                await AutoUpdateEventStore.shared.record(AutoUpdateEvent(
                    updateID: UUID().uuidString.lowercased(),
                    currentVersion: Self.binaryVersion,
                    targetVersion: parsed.normalized,
                    phase: .cooldown,
                    outcome: .skipped,
                    reason: "already_attempted_this_session",
                    attempt: 1
                ))
                return
            }
            autoupdateAttemptedTargets.insert(parsed.normalized)
        }
        let updater = AutoUpdater(
            config: appConfig,
            currentVersion: Self.binaryVersion,
            providerStatus: providerStatus,
            trustProvider: { await self.currentAutoupdateTrustState() },
            drain: { target in try await self.autoupdateDrain(target: target) },
            sendReady: { try await self.sendStateUpdate(state: .ready, reason: "autoupdate_timeout_skipped_ready") }
        )
        await updater.handleCoordinatorRecommendation(recommended)
    }

    private func currentAutoupdateTrustState() -> AutoUpdateTrustState {
        if let reason = autoupdateDisabledForSessionReason {
            return AutoUpdateTrustState(
                v2Accepted: false,
                tier: nil,
                encryptedLegValid: false,
                attestationRequired: false,
                attestationSatisfied: false,
                tokenConfigured: providerToken?.isEmpty == false,
                tokenValidated: false,
                bearerlessDuplicate: false,
                connected: false,
                stableReason: reason
            )
        }
        guard !autoupdateCoordinatorPayload.isEmpty else {
            return AutoUpdateTrustState(
                v2Accepted: false,
                tier: nil,
                encryptedLegValid: false,
                attestationRequired: false,
                attestationSatisfied: false,
                tokenConfigured: providerToken?.isEmpty == false,
                tokenValidated: providerToken?.isEmpty == false,
                bearerlessDuplicate: false,
                connected: false,
                stableReason: autoupdateDemotionReason ?? "coordinator_disconnected"
            )
        }
        var state = AutoUpdateTrustState.fromCoordinatorPayload(
            autoupdateCoordinatorPayload,
            isV2: autoupdateCoordinatorPayloadIsV2,
            session: tier2Session,
            providerToken: providerToken,
            assignedProviderTokenAdopted: autoupdateAssignedProviderTokenAdopted,
            acceptProvisional: AutoUpdateConfig.acceptProvisional(appConfig)
        )
        if let reason = autoupdateDemotionReason {
            switch reason {
            case "encrypted_leg_invalidated":
                state = AutoUpdateTrustState(
                    v2Accepted: state.v2Accepted,
                    tier: state.tier,
                    encryptedLegValid: false,
                    attestationRequired: state.attestationRequired,
                    attestationSatisfied: state.attestationSatisfied,
                    tokenConfigured: state.tokenConfigured,
                    tokenValidated: state.tokenValidated,
                    bearerlessDuplicate: state.bearerlessDuplicate,
                    connected: state.connected,
                    stableReason: reason,
                    acceptProvisional: state.acceptProvisional
                )
            case "tier_demoted":
                state = AutoUpdateTrustState(
                    v2Accepted: state.v2Accepted,
                    tier: "provisional",
                    encryptedLegValid: state.encryptedLegValid,
                    attestationRequired: state.attestationRequired,
                    attestationSatisfied: state.attestationSatisfied,
                    tokenConfigured: state.tokenConfigured,
                    tokenValidated: state.tokenValidated,
                    bearerlessDuplicate: state.bearerlessDuplicate,
                    connected: state.connected,
                    stableReason: reason,
                    acceptProvisional: state.acceptProvisional
                )
            case "token_revoked":
                state = AutoUpdateTrustState(
                    v2Accepted: state.v2Accepted,
                    tier: state.tier,
                    encryptedLegValid: state.encryptedLegValid,
                    attestationRequired: state.attestationRequired,
                    attestationSatisfied: state.attestationSatisfied,
                    tokenConfigured: true,
                    tokenValidated: false,
                    bearerlessDuplicate: state.bearerlessDuplicate,
                    connected: state.connected,
                    stableReason: reason,
                    acceptProvisional: state.acceptProvisional
                )
            case "attestation_state_degraded":
                state = AutoUpdateTrustState(
                    v2Accepted: state.v2Accepted,
                    tier: state.tier,
                    encryptedLegValid: state.encryptedLegValid,
                    attestationRequired: true,
                    attestationSatisfied: false,
                    tokenConfigured: state.tokenConfigured,
                    tokenValidated: state.tokenValidated,
                    bearerlessDuplicate: state.bearerlessDuplicate,
                    connected: state.connected,
                    stableReason: reason,
                    acceptProvisional: state.acceptProvisional
                )
            default:
                state = AutoUpdateTrustState(
                    v2Accepted: state.v2Accepted,
                    tier: state.tier,
                    encryptedLegValid: state.encryptedLegValid,
                    attestationRequired: state.attestationRequired,
                    attestationSatisfied: state.attestationSatisfied,
                    tokenConfigured: state.tokenConfigured,
                    tokenValidated: state.tokenValidated,
                    bearerlessDuplicate: state.bearerlessDuplicate,
                    connected: false,
                    stableReason: reason,
                    acceptProvisional: state.acceptProvisional
                )
            }
        }
        autoupdateTrustState = state
        return state
    }

    private static func autoupdateTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func autoupdateMarkerDeadlineExpired(_ raw: String) -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        guard let deadline = formatter.date(from: raw) else {
            return true
        }
        return Date() >= deadline
    }

    private func autoupdateDrain(target: String) async throws -> Bool {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        heartbeatWatchdogTask?.cancel()
        heartbeatWatchdogTask = nil
        try await sendStateUpdate(state: .draining, reason: "autoupdate_to_\(target)")
        try await sendDrainStatus(phase: "starting")
        try await sendDrainStatus(phase: "in_progress")
        let softDrained = await providerStatus.waitUntilDrained(timeoutSeconds: 120)
        if softDrained {
            try await sendDrainStatus(phase: "complete")
            return true
        }
        let snapshot = await providerStatus.snapshot()
        await AutoUpdateEventStore.shared.record(AutoUpdateEvent(
            updateID: UUID().uuidString.lowercased(),
            currentVersion: Self.binaryVersion,
            targetVersion: target,
            phase: .drain,
            outcome: .inProgress,
            reason: "soft_drain_timeout",
            attempt: 1,
            inflightRequests: snapshot.requestsInFlight
        ))
        let hardDrained = await providerStatus.waitUntilDrained(timeoutSeconds: 30)
        if hardDrained {
            try await sendDrainStatus(phase: "complete")
            return true
        }
        try await sendDrainStatus(phase: autoupdateDrainExtensions ? "timeout_skipped" : "complete")
        return false
    }

    // resetWindow=true rolls the since-last metrics window (the coordinator-
    // interval heartbeat). Intermediate keepalive heartbeats (sent on the short
    // sub-interval tick to keep the connection alive) pass resetWindow=false so
    // the since-last window stays aligned to the full coordinator interval and
    // metrics are unchanged from the prior single-heartbeat-per-interval cadence.
    private func coordinatorWireModelID(for servedModelID: String?) -> String {
        guard let servedModelID, !servedModelID.isEmpty else {
            return ""
        }
        guard let catalogModelIDForCoordinator,
              let loadedModelID,
              !loadedModelID.isEmpty,
              servedModelID == loadedModelID
        else {
            return servedModelID
        }
        return catalogModelIDForCoordinator
    }

    private func sendHeartbeat(resetWindow: Bool = true) async throws {
        let snapshot = await providerStatus.snapshot(resetWindow: resetWindow)
        let snapshotWireModelID = coordinatorWireModelID(for: snapshot.modelID)
        var payload: [String: Any] = [
            "type": "heartbeat",
            "status": snapshot.status.rawValue,
            "model_id": snapshotWireModelID,
            "model_params_b": snapshot.capacity.modelParamsB(modelID: snapshotWireModelID),
            "ram_gb": snapshot.capacity.ramGB,
            "max_context_tokens": snapshot.capacity.maxContextTokens,
            "max_concurrency": snapshot.capacity.maxConcurrency,
            "slots_free": snapshot.slotsFree,
            "slots_total": snapshot.slotsTotal,
            "throughput_tps_estimate": snapshot.capacity.throughputTPSEstimate,
            "requests_served_since_last": snapshot.requestsServedSinceLast,
            "avg_latency_ms_since_last": nullableNumber(snapshot.avgLatencyMSSinceLast),
            "throughput_tps_since_last": nullableNumber(snapshot.throughputTPSSinceLast),
        ]
        if let hardwareSummary {
            payload["hardware_summary"] = hardwareSummary
        }
        var specDecodeTelemetryMatchesRuntime = true
        var specDecodeTelemetryRuntimeEligible = true
        if warmSwapEnabled {
            let runtimeSnapshot = await modelRuntime.currentSnapshot()
            let runtimeModelID = runtimeSnapshot.modelID
            let runtimeWireModelID = coordinatorWireModelID(for: runtimeModelID)
            payload["model_id"] = runtimeWireModelID
            payload["model_params_b"] = snapshot.capacity.modelParamsB(modelID: runtimeWireModelID)
            if let modelHash = runtimeSnapshot.modelHash {
                payload["model_hash"] = modelHash
            }
            payload["loading"] = runtimeSnapshot.state == .loading || runtimeSnapshot.state == .draining
            specDecodeTelemetryMatchesRuntime = runtimeSnapshot.specDecodeGeneration == snapshot.specDecodeGeneration
            specDecodeTelemetryRuntimeEligible = runtimeSnapshot.state == .ready && runtimeSnapshot.hasTargetCompatibleDraft
        }
        if appConfig.publishesSpecDecodeTelemetry {
            if specDecodeTelemetryMatchesRuntime && specDecodeTelemetryRuntimeEligible {
                payload["spec_decode_enabled"] = snapshot.specDecodeEnabled
                payload["spec_decode_draft_model_id"] = snapshot.specDecodeDraftModelID ?? NSNull()
                payload["spec_decode_num_draft_tokens"] = snapshot.specDecodeNumDraftTokens ?? NSNull()
                payload["spec_decode_drafted_tokens_since_last"] = snapshot.specDecodeDraftedTokensSinceLast
                payload["spec_decode_accepted_tokens_since_last"] = snapshot.specDecodeAcceptedTokensSinceLast
                payload["spec_decode_acceptance_rate"] = nullableNumber(snapshot.specDecodeAcceptanceRate)
            } else {
                payload["spec_decode_enabled"] = false
                payload["spec_decode_draft_model_id"] = NSNull()
                payload["spec_decode_num_draft_tokens"] = NSNull()
                payload["spec_decode_drafted_tokens_since_last"] = 0
                payload["spec_decode_accepted_tokens_since_last"] = 0
                payload["spec_decode_acceptance_rate"] = NSNull()
            }
        }
        if let event = await AutoUpdateEventStore.shared.lastWireObject() {
            payload["last_autoupdate_event"] = event
        }
        try await send(payload)
    }

    private func sendStateUpdate(state newState: ProviderHealthState?, reason: String) async throws {
        if let newState {
            await providerStatus.setState(newState)
        }
        let snapshot = await providerStatus.snapshot()
        var payload: [String: Any] = [
            "type": "state_update",
            "state": snapshot.status.rawValue,
            "reason": reason,
            "since": ISO8601DateFormatter().string(from: Date()),
            "metrics_snapshot": [
                "slots_free": snapshot.slotsFree,
                "slots_total": snapshot.slotsTotal,
                "requests_served_since_last": snapshot.requestsServedSinceLast,
                "avg_latency_ms_since_last": nullableNumber(snapshot.avgLatencyMSSinceLast),
                "throughput_tps_since_last": nullableNumber(snapshot.throughputTPSSinceLast),
            ],
        ]
        if let event = await AutoUpdateEventStore.shared.lastWireObject() {
            payload["last_autoupdate_event"] = event
        }
        try await send(payload)
    }

    private func sendDrainStatus(phase: String) async throws {
        let snapshot = await providerStatus.snapshot()
        try await send([
            "type": "drain_status",
            "phase": phase,
            "inflight_requests": snapshot.requestsInFlight,
            "estimated_drain_seconds": 0,
        ])
    }

    private func sendNAK(inReplyTo: String, code: String, message: String) async throws {
        try await send([
            "type": "nak",
            "in_reply_to": inReplyTo,
            "error": [
                "code": code,
                "message": message,
            ],
        ])
    }

    // MARK: - SE Liveness Challenge (Phase 1, Track P1-C)

    private func handleSELivenessChallenge(_ dict: [String: Any]) async throws {
        guard
            let nonce = dict["nonce"] as? String,
            let timestamp = dict["timestamp"] as? String,
            !nonce.isEmpty
        else {
            print("WARN se_liveness_challenge missing nonce or timestamp — ignoring")
            return
        }

        // Lazily load the SE identity on arm64; use injected signer in tests.
        if seLivenessSigner == nil {
            #if arch(arm64)
            if let seIdentity = try? SecureEnclaveIdentity.loadOrCreate() {
                seLivenessSigner = seIdentity
            } else {
                print("WARN SE liveness challenge received but SecureEnclaveIdentity unavailable — ignoring")
                return
            }
            #else
            print("WARN SE liveness challenge received on non-arm64 — ignoring")
            return
            #endif
        }

        guard let signer = seLivenessSigner else { return }

        let message = (nonce + timestamp).data(using: .utf8)!
        let signature: Data
        do {
            signature = try signer.sign(message)
        } catch {
            print("ERROR SE liveness signing failed: \(error.localizedDescription)")
            return
        }

        try await send([
            "type": "se_liveness_response",
            "version": 1,
            "nonce": nonce,
            "timestamp": timestamp,
            "public_key": signer.publicKeyBase64,
            "signature": signature.base64EncodedString(),
        ])
        print("se_liveness_response sent (nonce prefix: \(nonce.prefix(8))…)")
    }

    func authInitialMessage(
        attempt: Tier2AuthAttempt,
        providerReceiptPublicKeyOverride: String? = nil
    ) async -> [String: Any] {
        let snapshot = await providerStatus.snapshot()
        // Issue #203: when warm-swap is enabled, the authoritative
        // post-swap model metadata lives in `ModelRuntime.currentSnapshot()`,
        // not in `ProviderStatus` (which carries boot-time / pre-swap
        // values that drift). helloMessage already routes through the
        // runtime snapshot; authInitialMessage (v2 auth) historically
        // missed this, so a reconnect AFTER a completed warm-swap
        // re-admitted the provider with the STALE pre-swap model_id
        // until the next regular heartbeat corrected it. Coordinator
        // routing decisions in that window used the wrong metadata.
        // Fix: source modelID + modelHash from the same place
        // helloMessage does.
        let wireModelID: String
        let resolvedModelHash: String?
        if warmSwapEnabled {
            let runtimeSnapshot = await modelRuntime.currentSnapshot()
            wireModelID = coordinatorWireModelID(for: runtimeSnapshot.modelID)
            resolvedModelHash = runtimeSnapshot.modelHash
        } else {
            wireModelID = coordinatorWireModelID(for: snapshot.modelID)
            resolvedModelHash = snapshot.modelHash
        }
        var message: [String: Any] = [
            "type": "auth_request",
            "version": 2,
            "stage": "initial",
            "provider_id": providerID,
            "hostname": Host.current().localizedName ?? "unknown",
            "model_id": wireModelID,
            "model_params_b": snapshot.capacity.modelParamsB(modelID: wireModelID),
            "ram_gb": snapshot.capacity.ramGB,
            "max_context_tokens": snapshot.capacity.maxContextTokens,
            "max_concurrency": snapshot.capacity.maxConcurrency,
            "throughput_tps_estimate": snapshot.capacity.throughputTPSEstimate,
            "binary_version": Self.binaryVersion,
            "provider_ecdh_public_key": attempt.publicKeyBase64URL,
            "tier2_capabilities": [
                "encrypted_leg": true,
                "attestation": true,
                "aead_suites": [Tier2ProviderSession.aeadSuite],
                "response_chunk_plaintext_envelope": true,
            ],
        ]
        let resolvedCatalog: [String]
        do {
            resolvedCatalog = try SupportedModels.validate(
                model: wireModelID,
                supportedModels: supportedModels
            )
        } catch {
            resolvedCatalog = [wireModelID]
        }
        message["supported_models"] = resolvedCatalog
        if publishesSupportedModels {
            message["publishes_supported_models"] = true
        }
        let receiptPublicKey = providerReceiptPublicKeyOverride ?? providerReceiptPublicKey
        if let receiptPublicKey, !receiptPublicKey.isEmpty {
            message["provider_receipt_public_key"] = receiptPublicKey
        }
        if let endpointURL {
            message["endpoint_url"] = endpointURL
        }
        if let modelHash = resolvedModelHash {
            message["model_hash"] = modelHash
        }
        return message
    }

    func helloMessage() async -> [String: Any] {
        let snapshot = await providerStatus.snapshot()
        var message: [String: Any] = [
            "type": "hello",
            "version": 1,
            "tier": 1,
            "provider_id": providerID,
            "hostname": Host.current().localizedName ?? "unknown",
            "model_id": snapshot.modelID ?? "",
            "model_params_b": snapshot.capacity.modelParamsB(modelID: snapshot.modelID),
            "ram_gb": snapshot.capacity.ramGB,
            "max_context_tokens": snapshot.capacity.maxContextTokens,
            "max_concurrency": snapshot.capacity.maxConcurrency,
            "throughput_tps_estimate": snapshot.capacity.throughputTPSEstimate,
            "binary_version": Self.binaryVersion,
            "attestation": NSNull(),
        ]
        if let endpointURL {
            message["endpoint_url"] = endpointURL
        }
        let wireModelIDForHello: String
        let hashForHello: String?
        if warmSwapEnabled {
            let runtimeSnapshot = await modelRuntime.currentSnapshot()
            wireModelIDForHello = coordinatorWireModelID(for: runtimeSnapshot.modelID)
            hashForHello = runtimeSnapshot.modelHash
        } else {
            wireModelIDForHello = coordinatorWireModelID(for: snapshot.modelID)
            hashForHello = snapshot.modelHash
        }
        message["model_id"] = wireModelIDForHello
        message["model_params_b"] = snapshot.capacity.modelParamsB(modelID: wireModelIDForHello)
        if let hashForHello {
            message["model_hash"] = hashForHello
        }
        return message
    }

    private func send(_ payload: sending [String: Any]) async throws {
        if let sendOverride {
            try await sendOverride(payload)
            return
        }
        guard let webSocket else { throw CancellationError() }
        try await Self.send(payload, to: webSocket)
    }

    private func send(_ payload: [String: Any], to webSocket: ProviderWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes])
        let text = String(decoding: data, as: UTF8.self)
        if let type = payload["type"] as? String {
            Self.keepaliveDebug("ws_send type=\(type) bytes=\(text.utf8.count)")
        }
        try await webSocket.send(.string(text))
    }

    private static func send(_ payload: sending [String: Any], to webSocket: ProviderWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes])
        let text = String(decoding: data, as: UTF8.self)
        if let type = payload["type"] as? String {
            keepaliveDebug("ws_send type=\(type) bytes=\(text.utf8.count)")
        }
        let wsSendStart = clockMonotonicMicros()
        try await webSocket.send(.string(text))
        EgressPerfTraceKey.current?.recordWSSend(durationMicros: clockMonotonicMicros() &- wsSendStart)
    }

    private static func receiveJSONObject(from webSocket: ProviderWebSocketTask) async throws -> [String: Any] {
        let message = try await webSocket.receive()
        let text: String
        switch message {
        case .string(let value):
            text = value
        case .data(let data):
            text = String(decoding: data, as: UTF8.self)
        @unknown default:
            throw CoordinatorAuthError.invalidMessage("Unsupported WebSocket frame")
        }
        guard let data = text.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let dict = raw as? [String: Any]
        else {
            throw CoordinatorAuthError.invalidMessage("Coordinator message must be a JSON object")
        }
        if let type = dict["type"] as? String {
            keepaliveDebug("ws_recv type=\(type) bytes=\(text.utf8.count)")
        }
        return dict
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as NSNumber:
            return value.intValue
        default:
            return nil
        }
    }

    fileprivate static func keepaliveDebug(_ message: String) {
        guard keepaliveDebugEnabled else { return }
        let timestamp = String(format: "%.2f", Date().timeIntervalSince1970)
        FileHandle.standardError.write(Data("[keepalive \(timestamp)] \(message)\n".utf8))
    }

    private static func redactedURL(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.user = nil
        components?.password = nil
        components?.query = nil
        components?.fragment = nil
        return components?.string ?? "\(url.scheme ?? "wss")://\(url.host ?? "unknown")"
    }

    private func nullableNumber(_ value: Double?) -> Any {
        guard let value else { return NSNull() }
        return value
    }

}

extension CoordinatorClient: ReceiptKeyRotatingCoordinatorClient {}

/// Signals "coordinator asked us to drain, handle complete, reconnect later
/// after a grace period." Caught by runReconnectLoop.
struct CoordinatorDrainComplete: Error {}

/// FR-C9.3 — coordinator minted a provisional bearer on a tokenless connect;
/// reconnect with Authorization so auth_state becomes bearer_validated.
struct CoordinatorAuthUpgradeReconnect: Error {}

enum CoordinatorAuthError: Error, Equatable, CustomStringConvertible {
    case invalidMessage(String)
    case rejected(code: String, message: String)

    var description: String {
        switch self {
        case .invalidMessage(let message):
            return message
        case .rejected(let code, let message):
            return "\(code): \(message)"
        }
    }
}
