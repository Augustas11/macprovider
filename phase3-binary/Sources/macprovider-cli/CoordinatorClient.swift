import Foundation
import MacProviderCore
import Darwin
import CryptoKit

protocol ProviderWebSocketTask: AnyObject, Sendable {
    func resume()
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    var closeCodeRawValueForDiagnostics: Int? { get }
    var closeReasonTextForDiagnostics: String? { get }
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

extension URLSessionWebSocketTask: ProviderWebSocketTask {
    var closeCodeRawValueForDiagnostics: Int? {
        let rawValue = closeCode.rawValue
        return rawValue == URLSessionWebSocketTask.CloseCode.invalid.rawValue ? nil : rawValue
    }

    var closeReasonTextForDiagnostics: String? {
        closeReason.flatMap { String(data: $0, encoding: .utf8) }
    }
}

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
    typealias CoordinatorReadiness = @Sendable (
        String,
        String,
        CoordinatorReadinessClient.ExpectedCatalogEnvelope
    ) async -> Bool?
    typealias CatalogArtifactIdentity = @Sendable (String?) async -> String?
    typealias InstalledCompatibilityManifest = @Sendable (URL, String) -> CompatibilitySetManifest?
    typealias ReloadHelperFence = @Sendable () throws -> Void

    static let binaryVersion = "1.8.82"
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
    private var providerAdmissionPublicKey: String?
    private var providerAdmissionNextPublicKey: String?
    private var providerAdmissionRecovery: Bool
    private var lastAdmissionProofPublicKey: String?
    private let commitAdmissionIdentityPublicKey: (@Sendable (Data, Date?) throws -> Void)?
    private let receiptBuilder: ReceiptBuilder?
    private var receiptRotationInFlight = false
    private let reconnectGraceNanoseconds: UInt64
    private let reconnectInitialBackoffNanoseconds: UInt64
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
    private let providerCredentialStore: any ProviderCredentialStoring
    private let credentialStatusRuntime: ProviderCredentialStatusRuntime
    private let admissionIdentityStatusRuntime: ProviderAdmissionIdentityStatusRuntime
    private let sleepAssertionFactory: @Sendable () -> ProviderSleepAssertion?
    private let pairingController: PairingController
    private struct PendingAEADRekey {
        let rekeyID: String
        let assignedID: String
        let oldKID: String
        let coordinatorPublicKey: String
        let providerPublicKey: String
        let selectedAEAD: String
        let expiresAtRaw: String
        let expiresAt: Date
        let session: Tier2ProviderSession
    }

    private var inferenceRelay: InferenceRelay?
    private var tier2Session: Tier2ProviderSession?
    private var pendingAEADRekey: PendingAEADRekey?
    private var preparingAEADRekeyID: String?
    private var inBandAEADRekeyEnabled = false
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
    private var lastSignedRecoveryDiscoveryAttempt: Date?
    private var recommendedCompatibilitySetID: String?
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
    // Whether the provider currently *intends* to keep the Mac awake. The
    // system sleep assertion is bound to serving INTENT, not to a single
    // coordinator session or the reconnect loop's lifetime. Acquiring/releasing
    // it per session let the Mac sleep during reconnect backoff, so a
    // battery/8GB Mac would only dark-wake ~every 30 minutes, reconnect for
    // ~60s, then drop again — a self-reinforcing flap that kept the provider
    // effectively offline.
    //
    // Intent is true while the provider is serving (or trying to reconnect to
    // serve) and false when it is intentionally not serving: operator pause,
    // terminal loop exit, or shutdown. Binding to intent (not the loop) means a
    // transient disconnect keeps the Mac awake, while an operator pause lets it
    // sleep, and a receipt-key rotation — which cancels the reconnect loop
    // mid-flight — does NOT drop the assertion, because intent stays true across
    // the rotation handshake.
    private var wantsSleepAssertion = false
    // Terminal latch: once the provider has permanently stopped serving
    // (shutdown), it must never re-arm keep-awake, even if a suspended
    // rotation/session-accept/resume path resumes afterward via actor reentrancy.
    private var stopped = false

    // True only while the provider can still serve or reconnect to serve. After
    // stop(), or a terminal reconnect-loop exit (below-floor version / terminal
    // bootstrap referral failure), the provider cannot serve until restart, so
    // it must be allowed to sleep.
    private var canServe: Bool {
        !stopped
            && terminalVersionFloorRejection == nil
            && terminalBootstrapReferralFailure == nil
    }

    // Declare serving intent and immediately reconcile the assertion to match.
    // Arming is gated on `canServe`: a request to keep the Mac awake is refused
    // once the provider can never serve again, so a late resume or a reentrant
    // rotation/session-accept cannot re-hold caffeinate with no serving path.
    private func setSleepAssertionDesired(_ desired: Bool) {
        wantsSleepAssertion = desired && canServe
        reconcileSleepAssertion()
    }

    // Bring the held assertion in line with intent. Idempotent: safe to call on
    // every reconnect/session-accept without churning the caffeinate child.
    private func reconcileSleepAssertion() {
        if wantsSleepAssertion {
            if sleepAssertion == nil {
                sleepAssertion = sleepAssertionFactory()
            }
        } else {
            sleepAssertion?.stop()
            sleepAssertion = nil
        }
    }
    private let sendOverride: SendOverride?
    private let streamInterval: Int
    private let credentialBootstrap: Bool
    private let bootstrapReceiptSigningKey: Curve25519.Signing.PrivateKey?
    private let bootstrapReferralCode: String?
    private var terminalBootstrapReferralFailure: ReferralBootstrapFailure?
    // #767: set when the coordinator closed us with 4004 version_unsupported.
    // Non-nil means the reconnect loop stopped on purpose and will not resume
    // until the binary is upgraded and the process restarts.
    private var terminalVersionFloorRejection: CoordinatorVersionFloorRejection?
    private let receiptIdentitySigningKeys: [Curve25519.Signing.PrivateKey]
    private let persistReceiptIdentitySigningKey: (@Sendable (Curve25519.Signing.PrivateKey) throws -> Void)?

    private let catalogReleaseID: String?
    private let catalogPolicyVersion: String?
    private let catalogCandidateSHA256: String?
    private let catalogSignerKeyID: String?
    private let catalogRowIdentity: String?
    private let compatibilitySetID: String?
    private let installedCompatibilityManifest: InstalledCompatibilityManifest
    private let catalogModelSHA256: String?
    private let catalogArtifactIdentity: CatalogArtifactIdentity
    private let coordinatorReadiness: CoordinatorReadiness
    private let coordinatorReadinessAttempts: Int
    private let coordinatorReadinessRetryNanoseconds: UInt64
    private let autoupdateMarkerStore: AutoUpdateMarkerStore
    private let autoupdateLocalHealthRequiredConsecutiveSamples: Int
    private let autoupdateLocalStatusProbe: @Sendable () async -> [String: Any]?
    private let autoupdateLocalHealthSleep: @Sendable () async -> Void
    private let autoupdateReloadHelperFence: ReloadHelperFence
    private let lifecycleStateStore: ProviderLifecycleStateStore
    private let lifecycleOperationID: String?
    private var operatorPaused: Bool
    private var catalogWarmSwapInvalidated = false
    private var acceptedAssignedProviderID: String?
    private var lastConnectionFailureDiagnostic: String?
    private var lastConnectionFailureAt: Date?

    init?(
        config: AppConfig,
        modelRuntime: ModelRuntime,
        providerStatus: ProviderStatus,
        sendOverride: SendOverride? = nil,
        reconnectGraceNanoseconds: UInt64 = 10 * 1_000_000_000,
        reconnectInitialBackoffNanoseconds: UInt64 = 1_000_000_000,
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
        providerAdmissionPublicKey: String? = nil,
        providerAdmissionNextPublicKey: String? = nil,
        providerAdmissionRecovery: Bool = false,
        commitAdmissionIdentityPublicKey: (@Sendable (Data, Date?) throws -> Void)? = nil,
        receiptBuilder: ReceiptBuilder? = nil,
        catalogReleaseID: String? = nil,
        catalogPolicyVersion: String? = nil,
        catalogCandidateSHA256: String? = nil,
        catalogSignerKeyID: String? = nil,
        catalogRowIdentity: String? = nil,
        compatibilitySetIDOverride: String? = nil,
        installedCompatibilityManifest: InstalledCompatibilityManifest? = nil,
        catalogModelSHA256: String? = nil,
        catalogArtifactIdentity: CatalogArtifactIdentity? = nil,
        coordinatorReadiness: CoordinatorReadiness? = nil,
        coordinatorReadinessAttempts: Int = 15,
        coordinatorReadinessRetryNanoseconds: UInt64 = 2_000_000_000,
        autoupdateMarkerStore: AutoUpdateMarkerStore = AutoUpdateMarkerStore(),
        autoupdateLocalHealthRequiredConsecutiveSamples: Int = SelfUpdate.localHealthRequiredConsecutiveSamples,
        autoupdateLocalStatusProbe: (@Sendable () async -> [String: Any]?)? = nil,
        autoupdateLocalHealthSleep: @escaping @Sendable () async -> Void = {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        },
        autoupdateReloadHelperFence: @escaping ReloadHelperFence = {
            try CoordinatorClient.fenceAutoupdateReloadHelpers()
        },
        credentialBootstrap: Bool = false,
        bootstrapReceiptSigningKey: Curve25519.Signing.PrivateKey? = nil,
        bootstrapReferralCode: String? = nil,
        receiptIdentitySigningKey: Curve25519.Signing.PrivateKey? = nil,
        receiptIdentitySigningKeyCandidates: [Curve25519.Signing.PrivateKey] = [],
        persistReceiptIdentitySigningKey: (@Sendable (Curve25519.Signing.PrivateKey) throws -> Void)? = nil,
        providerCredentialStore: any ProviderCredentialStoring = KeychainProviderCredentialStore(),
        credentialStatusRuntime: ProviderCredentialStatusRuntime = ProviderCredentialStatusRuntime(.unconfigured),
        admissionIdentityStatusRuntime: ProviderAdmissionIdentityStatusRuntime = ProviderAdmissionIdentityStatusRuntime(),
        lifecycleStateStore: ProviderLifecycleStateStore = ProviderLifecycleStateStore(),
        lifecycleOperationID: String? = nil,
        operatorPausedInitially: Bool = false,
        watchdogExitPreparation: @escaping @Sendable () -> Void = {},
        // Issue #189: injectable in tests; production uses Darwin.exit(1)
        // so the launchd KeepAlive contract recovers the wedged process.
        watchdogExitHook: @escaping @Sendable (String) -> Void = { reason in
            FileHandle.standardError.write(Data("FATAL coordinator recovery watchdog: \(reason)\n".utf8))
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
        self.providerAdmissionPublicKey = providerAdmissionPublicKey
        self.providerAdmissionNextPublicKey = providerAdmissionNextPublicKey
        self.providerAdmissionRecovery = providerAdmissionRecovery
        self.commitAdmissionIdentityPublicKey = commitAdmissionIdentityPublicKey
        self.receiptBuilder = receiptBuilder
        self.reconnectGraceNanoseconds = reconnectGraceNanoseconds
        self.reconnectInitialBackoffNanoseconds = reconnectInitialBackoffNanoseconds
        self.receiptKeyRotationTimeoutNanoseconds = receiptKeyRotationTimeoutNanoseconds
        self.attestationGenerator = attestationGenerator
        self.seLivenessSigner = seLivenessSignerOverride
        self.webSocketFactory = webSocketFactory
        self.providerToken = config.providerToken.flatMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        self.configPath = config.configPath
        self.providerCredentialStore = providerCredentialStore
        self.credentialStatusRuntime = credentialStatusRuntime
        self.admissionIdentityStatusRuntime = admissionIdentityStatusRuntime
        self.lifecycleStateStore = lifecycleStateStore
        self.lifecycleOperationID = lifecycleOperationID
        self.operatorPaused = operatorPausedInitially
        self.sleepAssertionFactory = sleepAssertionFactory
        self.pairingController = pairingController ?? PairingController(configPath: config.configPath)
        self.connectAndRunOverride = connectAndRunOverride
        self.sendOverride = sendOverride
        self.catalogReleaseID = catalogReleaseID
        self.catalogPolicyVersion = catalogPolicyVersion
        self.catalogCandidateSHA256 = catalogCandidateSHA256
        self.catalogSignerKeyID = catalogSignerKeyID
        self.catalogRowIdentity = catalogRowIdentity
        let markerStoreForManifest = autoupdateMarkerStore
        let compatibilityManifestLoader = installedCompatibilityManifest ?? { executableURL, expectedVersion in
            // Prefer install authority when PATH is a stale regular-file copy
            // without a sibling compatibility-set.json (#616 / #610).
            let canonical = markerStoreForManifest.resolveCanonicalInstallBinary(
                launchedExecutableURL: executableURL
            )
            return CompatibilitySetManifest.loadInstalledPreferringInstallAuthority(
                launchedExecutableURL: executableURL,
                canonicalBinaryURL: canonical,
                expectedVersion: expectedVersion,
                allowProviderVersionMismatch: false,
                publicKeyPEM: markerStoreForManifest.compatibilityManifestPublicKeyPEM
            )
        }
        self.installedCompatibilityManifest = compatibilityManifestLoader
        self.compatibilitySetID = compatibilitySetIDOverride ?? Bundle.main.executableURL.flatMap {
            compatibilityManifestLoader($0, Self.binaryVersion)?.compatibilitySetID
        }
        self.catalogModelSHA256 = catalogModelSHA256
        self.catalogArtifactIdentity = catalogArtifactIdentity ?? { modelID in
            guard let modelID,
                  let directory = ModelRuntime.localHuggingFaceSnapshot(for: modelID)
            else {
                return nil
            }
            return try? ModelArtifactVerifier.canonicalArtifactHash(directory: directory)
        }
        self.coordinatorReadiness = coordinatorReadiness ?? { providerID, assignedProviderID, expected in
            await CoordinatorReadinessClient.fetch(
                coordinatorURL: config.coordinatorURL,
                providerID: providerID,
                assignedID: assignedProviderID,
                expected: expected
            )
        }
        self.coordinatorReadinessAttempts = max(1, coordinatorReadinessAttempts)
        self.coordinatorReadinessRetryNanoseconds = coordinatorReadinessRetryNanoseconds
        self.autoupdateMarkerStore = autoupdateMarkerStore
        self.autoupdateLocalHealthRequiredConsecutiveSamples = max(
            1,
            autoupdateLocalHealthRequiredConsecutiveSamples
        )
        let localStatusPort = config.port
        self.autoupdateLocalStatusProbe = autoupdateLocalStatusProbe ?? {
            try? await LocalStatusClient.fetch(port: localStatusPort)
        }
        self.autoupdateLocalHealthSleep = autoupdateLocalHealthSleep
        self.autoupdateReloadHelperFence = autoupdateReloadHelperFence
        self.watchdogExitHook = { reason in
            watchdogExitPreparation()
            watchdogExitHook(reason)
        }
        self.streamInterval = max(1, config.streamInterval)
        self.credentialBootstrap = credentialBootstrap
        if credentialBootstrap {
            guard let bootstrapReceiptSigningKey,
                  let providerReceiptPublicKey,
                  Data(base64Encoded: providerReceiptPublicKey) == bootstrapReceiptSigningKey.publicKey.rawRepresentation else {
                return nil
            }
        }
        self.bootstrapReceiptSigningKey = bootstrapReceiptSigningKey
        self.bootstrapReferralCode = credentialBootstrap ? bootstrapReferralCode : nil
        self.receiptIdentitySigningKeys = receiptIdentitySigningKey.map { [$0] }
            ?? receiptIdentitySigningKeyCandidates
        self.persistReceiptIdentitySigningKey = persistReceiptIdentitySigningKey
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
        // Latch shutdown before cancelling so any suspended arm path that
        // resumes after this cannot re-hold the sleep assertion (canServe=false).
        stopped = true
        runTask?.cancel()
        heartbeatTask?.cancel()
        heartbeatWatchdogTask?.cancel()
        swapHeartbeatTask?.cancel()
        setSleepAssertionDesired(false)
        await inferenceRelay?.cancelAllAndClear()
        inferenceRelay = nil
        tier2Session = nil
        pendingAEADRekey = nil
        preparingAEADRekeyID = nil
        inBandAEADRekeyEnabled = false
        webSocket?.cancel(with: .goingAway, reason: nil)
        coordinatorSessionAccepted = false
        autoupdateCoordinatorPayload = [:]
        autoupdateCoordinatorPayloadIsV2 = false
        autoupdateAssignedProviderTokenAdopted = false
        autoupdateDemotionReason = "coordinator_disconnected"
        autoupdateDisabledForSessionReason = nil
        recommendedCompatibilitySetID = nil
        try? autoupdateMarkerStore.clearCompatibilityAdmission()
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
        if !operatorPaused {
            _ = try? recordLifecycleTransition(
                to: .coordinatorUnavailable,
                reasonCode: "coordinator_stopped",
                compatibilitySetID: installedCompatibilitySetID()
            )
        }
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
                if catalogReleaseID != nil {
                    let runtimeSnapshot = await modelRuntime.currentSnapshot()
                    if await catalogRuntimeMatches(runtimeSnapshot) == false {
                        // A catalog row identity is model-specific. Never send a
                        // post-swap heartbeat or reconnect handshake that pairs a
                        // new model with the boot model's signed row identity.
                        // Keep local serving available, but fail closed on network
                        // admission until the provider restarts with a freshly
                        // selected catalog row.
                        catalogWarmSwapInvalidated = true
                        coordinatorSessionAccepted = false
                        await providerStatus.setCatalogCompatibilityConfirmed(false)
                        Self.keepaliveDebug("catalog warm swap requires model-specific re-admission")
                        closeWebSocketAfterKeepaliveFailure()
                        continue
                    }
                    catalogWarmSwapInvalidated = false
                }
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
        // Entering the reconnect loop means the provider intends to serve, so
        // keep the Mac awake across disconnects and backoff — UNLESS the loop
        // is entered in a durable operator-paused state, in which case a paused
        // provider must be allowed to sleep. NOTE: no `defer` release here — the
        // loop is also cancelled mid-flight by receipt-key rotation, which then
        // continues serving on a fresh socket; releasing on every loop exit
        // would drop the assertion during the rotation handshake. Intent is
        // cleared explicitly at the terminal exits below and on stop()/pause.
        if !operatorPaused {
            setSleepAssertionDesired(true)
        }
        var backoffNanoseconds = reconnectInitialBackoffNanoseconds
        var failedAttempts = 0
        var consecutiveAuthProtocolFailures = 0
        while !Task.isCancelled {
            if !operatorPaused {
                _ = try? recordLifecycleTransition(
                    to: .locallyReadyConnecting,
                    reasonCode: "coordinator_connecting",
                    compatibilitySetID: installedCompatibilitySetID()
                )
            }
            do {
                try await connectAndRunOnce()
                await cleanupConnection()
                recordConnectionFailureLifecycle(
                    state: .coordinatorUnavailable,
                    reasonCode: "coordinator_connection_ended"
                )
                backoffNanoseconds = reconnectInitialBackoffNanoseconds
                failedAttempts = 0
                consecutiveAuthProtocolFailures = 0
            } catch is CancellationError {
                await cleanupConnection()
                return
            } catch is CoordinatorDrainComplete {
                // Coordinator asked us to drain (likely it is restarting).
                // We acknowledged with drain_status; the WS is already closed.
                // Wait a grace period so the coordinator has time to come back
                // before we try to reconnect, then loop.
                await cleanupConnection()
                recordConnectionFailureLifecycle(
                    state: .coordinatorUnavailable,
                    reasonCode: "coordinator_drain_complete"
                )
                print("coordinator reconnect attempt 1 scheduled after drain")
                try? await Task.sleep(nanoseconds: reconnectGraceNanoseconds)
                backoffNanoseconds = reconnectInitialBackoffNanoseconds
                failedAttempts = 0
                consecutiveAuthProtocolFailures = 0
            } catch is CoordinatorAuthUpgradeReconnect {
                // FR-C9.3: tokenless bootstrap minted a bearer; reconnect immediately
                // so the coordinator registers auth_state=bearer_validated and the
                // session becomes buyer-routable.
                await cleanupConnection()
                if !operatorPaused {
                    _ = try? recordLifecycleTransition(
                        to: .locallyReadyConnecting,
                        reasonCode: "coordinator_auth_upgrade_reconnect",
                        compatibilitySetID: installedCompatibilitySetID()
                    )
                }
                print("coordinator reconnect scheduled after provisional token adoption")
                try? await Task.sleep(nanoseconds: reconnectGraceNanoseconds)
                backoffNanoseconds = reconnectInitialBackoffNanoseconds
                failedAttempts = 0
                consecutiveAuthProtocolFailures = 0
            } catch {
                await cleanupConnection()
                // #767: a 4004 version_unsupported close is TERMINAL. Retrying
                // cannot succeed until the binary is upgraded, and a below-floor
                // fleet retrying on backoff is exactly the hammering the floor
                // exists to prevent. Mirror the terminal-bootstrap pattern
                // below: record the reason, tell the operator what to do, and
                // return out of the loop entirely.
                if let floorRejection = Self.versionFloorRejection(for: error) {
                    terminalVersionFloorRejection = floorRejection
                    recordConnectionFailureDiagnostic(
                        reasonCode: "binary_version_unsupported",
                        error: error
                    )
                    recordConnectionFailureLifecycle(
                        state: .catalogIncompatible,
                        reasonCode: "binary_version_unsupported"
                    )
                    Self.emitVersionFloorUpgradeDirective(floorRejection)
                    setSleepAssertionDesired(false)
                    return
                }
                if credentialBootstrap,
                   let terminalFailure = Self.terminalBootstrapReferralFailure(for: error) {
                    terminalBootstrapReferralFailure = terminalFailure
                    setSleepAssertionDesired(false)
                    return
                }
                let classification = Self.lifecycleClassification(for: error)
                recordConnectionFailureDiagnostic(reasonCode: classification.reasonCode, error: error)
                recordConnectionFailureLifecycle(
                    state: classification.state,
                    reasonCode: classification.reasonCode
                )
                failedAttempts += 1
                if Self.isFatalAuthProtocolFailure(error) {
                    consecutiveAuthProtocolFailures += 1
                } else {
                    consecutiveAuthProtocolFailures = 0
                }
                if consecutiveAuthProtocolFailures >= 3 {
                    let lastError = Self.sanitizedDiagnosticText(String(describing: error))
                    let reason = "coordinator auth handshake failed \(consecutiveAuthProtocolFailures) consecutive times before session acceptance; last_error=\(lastError)"
                    FileHandle.standardError.write(Data("FATAL coordinator auth watchdog: \(reason)\n".utf8))
                    watchdogExitHook(reason)
                    setSleepAssertionDesired(false)
                    return
                }
                if failedAttempts >= 3 {
                    print("WARN coordinator reconnect failed attempt_count=\(failedAttempts) last_error=\(error)")
                }
                await runSignedRecoveryDiscoveryIfDue()
                try? await Task.sleep(nanoseconds: backoffNanoseconds)
                backoffNanoseconds = backoffNanoseconds >= 30 * 1_000_000_000
                    ? 60 * 1_000_000_000
                    : backoffNanoseconds * 2
            }
        }
    }

    private static func sanitizedDiagnosticText(_ value: String, maxLength: Int = 240) -> String {
        guard maxLength > 0 else { return "" }
        var result = ""
        result.reserveCapacity(min(value.count, maxLength + 3))
        var appended = 0
        for scalar in value.unicodeScalars {
            guard appended < maxLength else {
                result.append("...")
                return result
            }
            if CharacterSet.controlCharacters.contains(scalar) ||
                CharacterSet.newlines.contains(scalar) {
                result.append(" ")
            } else {
                result.unicodeScalars.append(scalar)
            }
            appended += 1
        }
        return result
    }

    private static func redactedDiagnosticText(_ value: String, maxLength: Int = 240) -> String {
        let replacements: [(String, String)] = [
            (#"\b[a-z][a-z0-9+.-]*://[^\s]+"#, "[redacted_url]"),
            (#"(^|[\s=])/(Users|Volumes|private|var|tmp|etc|opt)/[^\s,;]+"#, "$1[redacted_path]"),
            (#"authorization\s*:\s*bearer\s+[^\s,;]+"#, "Authorization: Bearer [redacted]"),
            (#"\bbearer\s+[^\s,;]+"#, "Bearer [redacted]"),
            (#"\b(provider[_-]?token|authorization|token)\s*[=:]\s*[^\s,;]+"#, "$1=[redacted]"),
            (#"\bmpk_[A-Za-z0-9._~+/=-]+"#, "[redacted_provider_token]"),
            (#"\bmp-[A-Za-z0-9._~+/=-]+"#, "[redacted_provider_token]"),
            (#"\b[A-Fa-f0-9]{64}\b"#, "[redacted_sha256_like]"),
        ]
        var redacted = value
        for (pattern, replacement) in replacements {
            redacted = redacted.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return sanitizedDiagnosticText(redacted, maxLength: maxLength)
    }

    private static func isFatalAuthProtocolFailure(_ error: Error) -> Bool {
        guard let authError = error as? CoordinatorAuthError else {
            return false
        }
        switch authError {
        case .rejected(let code, _):
            return code == "invalid_auth_request"
        case .invalidMessage(let message):
            let lowered = message.lowercased()
            return lowered.contains("auth_request") ||
                lowered.contains("auth_response") ||
                lowered.contains("auth_challenge") ||
                lowered.contains("unrecognized auth message")
        }
    }

    private static func terminalBootstrapReferralFailure(
        for error: Error
    ) -> ReferralBootstrapFailure? {
        guard let authError = error as? CoordinatorAuthError,
              case .rejected(let code, _) = authError else {
            return nil
        }
        return ReferralBootstrapFailure.coordinatorCode(code)
    }

    func credentialBootstrapTerminalReferralFailure() -> ReferralBootstrapFailure? {
        terminalBootstrapReferralFailure
    }

    /// A coordinator 4004 `version_unsupported` close (issue #767). This build is
    /// below the coordinator's hard admission floor, so reconnecting cannot
    /// succeed until the binary is upgraded — it is terminal, not transient.
    struct CoordinatorVersionFloorRejection: Equatable, Sendable {
        /// The version this binary reported in its hello.
        let currentVersion: String
        /// The coordinator's required minimum, when it named one. Absent means
        /// the coordinator sent a reason we could not parse a target out of;
        /// the directive degrades to "upgrade to the latest release".
        let requiredVersion: String?
        /// The sanitized close reason, for diagnostics.
        let reason: String
    }

    /// Recognises the terminal version-floor rejection. Only a `version_unsupported`
    /// rejection qualifies; every other close stays on the ordinary retry path.
    static func versionFloorRejection(for error: Error) -> CoordinatorVersionFloorRejection? {
        guard let authError = error as? CoordinatorAuthError,
              case .rejected(let code, let message) = authError,
              code == "version_unsupported" else {
            return nil
        }
        return CoordinatorVersionFloorRejection(
            currentVersion: binaryVersion,
            requiredVersion: requiredBinaryVersion(from: message),
            reason: message
        )
    }

    /// Parses the required target out of the coordinator's close reason. The
    /// coordinator sends "version_unsupported: binary_version X below required Y"
    /// (phase4-coordinator/internal/ws/server.go); an older or future coordinator
    /// that words it differently yields nil, and the caller degrades gracefully
    /// rather than printing a wrong target.
    static func requiredBinaryVersion(from reason: String) -> String? {
        let marker = "below required "
        guard let range = reason.range(of: marker) else {
            return nil
        }
        let candidate = reason[range.upperBound...]
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let candidate, !candidate.isEmpty else {
            return nil
        }
        // Defensive: only echo a plausible version back to the operator, never
        // arbitrary coordinator-controlled text.
        let allowed = CharacterSet(charactersIn: "0123456789.")
        guard candidate.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return nil
        }
        return candidate
    }

    /// The terminal version-floor rejection that stopped the reconnect loop, if
    /// one did. Nil while the loop is healthy or stopped for any other reason.
    func coordinatorVersionFloorRejection() -> CoordinatorVersionFloorRejection? {
        terminalVersionFloorRejection
    }

    /// Emits the upgrade directive: a human line on stderr plus a structured
    /// stderr event, matching the CLI's existing emitTokenPersistEvent shape.
    static func emitVersionFloorUpgradeDirective(_ rejection: CoordinatorVersionFloorRejection) {
        let target = rejection.requiredVersion.map { "v\($0)" } ?? "the latest release"
        FileHandle.standardError.write(Data((
            "FATAL coordinator rejected this build: binary version " +
            "\(rejection.currentVersion) is below the required minimum \(target). " +
            "Upgrade with 'macprovider-cli update', then restart the provider. " +
            "Reconnect attempts stopped — a below-floor build must not hammer the coordinator.\n"
        ).utf8))
        var payload: [String: String] = [
            "event": "coordinator_version_floor_rejected",
            "close_code": "4004",
            "current_binary_version": rejection.currentVersion,
            "reason": rejection.reason,
        ]
        if let requiredVersion = rejection.requiredVersion {
            payload["required_binary_version"] = requiredVersion
        }
        do {
            var data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            data.append(0x0A)
            FileHandle.standardError.write(data)
        } catch {
            FileHandle.standardError.write(Data("{\"event\":\"coordinator_version_floor_rejected\"}\n".utf8))
        }
    }

    struct ConnectionLifecycleClassification: Equatable, Sendable {
        let state: ProviderLifecycleState
        let reasonCode: String
    }

    /// Reduces transport and admission failures to stable, non-secret lifecycle
    /// reason codes. The persisted state is intentionally coarser than logs: it
    /// drives Malibu recovery UX without copying coordinator messages, URLs, or
    /// credential-bearing diagnostics into durable storage.
    static func lifecycleClassification(for error: Error) -> ConnectionLifecycleClassification {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            let offlineCodes: Set<Int> = [
                URLError.notConnectedToInternet.rawValue,
                URLError.networkConnectionLost.rawValue,
                URLError.cannotFindHost.rawValue,
                URLError.dnsLookupFailed.rawValue,
                URLError.dataNotAllowed.rawValue,
                URLError.internationalRoamingOff.rawValue,
                URLError.callIsActive.rawValue,
            ]
            if offlineCodes.contains(nsError.code) {
                return ConnectionLifecycleClassification(
                    state: .networkOffline,
                    reasonCode: "network_offline"
                )
            }
        }

        guard let authError = error as? CoordinatorAuthError else {
            return ConnectionLifecycleClassification(
                state: .coordinatorUnavailable,
                reasonCode: "coordinator_unavailable"
            )
        }
        switch authError {
        case .rejected(let code, _):
            let normalized = code.lowercased()
            // Keep lifecycle wire states on the v1 enum so older Malibu readers
            // stay valid. Distinguish #582 onboarding outcomes via reason codes.
            if normalized == "autotune_evidence_required" {
                return ConnectionLifecycleClassification(
                    state: .coordinatorUnavailable,
                    reasonCode: "autotune_evidence_required"
                )
            }
            if normalized == "autotune_evidence_invalid"
                || normalized == "autotune_evidence_binary_version_mismatch"
                || normalized == "autotune_model_cap_exceeded" {
                return ConnectionLifecycleClassification(
                    state: .catalogIncompatible,
                    reasonCode: normalized
                )
            }
            if normalized == "autotune_model_uncatalogued" {
                return ConnectionLifecycleClassification(
                    state: .catalogIncompatible,
                    reasonCode: "autotune_model_uncatalogued"
                )
            }
            if normalized == "autotune_gate_unavailable" {
                return ConnectionLifecycleClassification(
                    state: .coordinatorUnavailable,
                    reasonCode: "autotune_gate_unavailable"
                )
            }
            // #767: below the coordinator's hard binary-version floor. Same
            // family as a catalog/compatibility rejection — this build cannot
            // serve until it is upgraded — but with its own reason code so
            // Malibu can surface "upgrade" instead of "reinstall the catalog".
            if normalized == "version_unsupported" {
                return ConnectionLifecycleClassification(
                    state: .catalogIncompatible,
                    reasonCode: "binary_version_unsupported"
                )
            }
            if normalized.contains("catalog") || normalized.contains("compatibility") {
                return ConnectionLifecycleClassification(
                    state: .catalogIncompatible,
                    reasonCode: "catalog_incompatible"
                )
            }
            if normalized.contains("identity") {
                return ConnectionLifecycleClassification(
                    state: .identityMigrationRequired,
                    reasonCode: "identity_migration_required"
                )
            }
            if normalized == "invalid_auth_request" {
                return ConnectionLifecycleClassification(
                    state: .failed,
                    reasonCode: "coordinator_auth_protocol_invalid"
                )
            }
            if normalized == "invalid_token" || normalized.contains("token") || normalized.contains("auth") {
                return ConnectionLifecycleClassification(
                    state: .authenticationRequired,
                    reasonCode: "authentication_required"
                )
            }
        case .invalidMessage(let message):
            let normalized = message.lowercased()
            if normalized.contains("catalog") || normalized.contains("compatibility") {
                return ConnectionLifecycleClassification(
                    state: .catalogIncompatible,
                    reasonCode: "catalog_incompatible"
                )
            }
            if normalized.contains("admission identity") || normalized.contains("identity_") {
                return ConnectionLifecycleClassification(
                    state: .identityMigrationRequired,
                    reasonCode: "identity_migration_required"
                )
            }
        }
        return ConnectionLifecycleClassification(
            state: .coordinatorUnavailable,
            reasonCode: "coordinator_unavailable"
        )
    }

    private func recordConnectionFailureLifecycle(
        state: ProviderLifecycleState,
        reasonCode: String
    ) {
        guard !operatorPaused else { return }
        _ = try? recordLifecycleTransition(
            to: state,
            reasonCode: reasonCode,
            compatibilitySetID: installedCompatibilitySetID()
        )
    }

    private func connectAndRunOnce() async throws {
        if catalogReleaseID != nil, warmSwapEnabled {
            let runtimeSnapshot = await modelRuntime.currentSnapshot()
            if await catalogRuntimeMatches(runtimeSnapshot) == false {
                catalogWarmSwapInvalidated = true
            }
        }
        guard !catalogWarmSwapInvalidated else {
            throw CoordinatorAuthError.invalidMessage(
                "catalog model changed without a model-specific signed row; restart with a fresh catalog recommendation"
            )
        }
        if let connectAndRunOverride {
            try await connectAndRunOverride()
            return
        }
        do {
            try await connectAndRun()
        } catch let error as CoordinatorAuthError {
            guard case .rejected(let code, _) = error,
                  code == "invalid_token",
                  await recoverInvalidBootstrapCredential() else {
                throw error
            }
            // The recovery handshake persisted a fresh same-key credential.
            // Re-enter the ordinary authenticated path immediately; only that
            // path may confirm the credential and register the provider.
            throw CoordinatorAuthUpgradeReconnect()
        }
    }

    /// Recover an installer bootstrap credential only after the coordinator
    /// explicitly rejects its bearer. The recovery handshake omits the stale
    /// bearer and proves the durable Keychain receipt identity instead. The
    /// coordinator permits replacement only while that exact identity remains
    /// unconfirmed; confirmed ownership and ordinary operator tokens fail
    /// closed without local mutation.
    private func recoverInvalidBootstrapCredential() async -> Bool {
        guard !credentialBootstrap,
              BootstrapAuthCommand.isCredentialBootstrapPrincipal(providerID),
              let rejectedToken = providerToken,
              let receiptKey = receiptIdentitySigningKeys.first else {
            return false
        }
        var recoveryConfig = appConfig
        recoveryConfig.providerToken = nil
        let publicKey = Data(receiptKey.publicKey.rawRepresentation).base64EncodedString()
        guard let recoveryClient = CoordinatorClient(
            config: recoveryConfig,
            modelRuntime: modelRuntime,
            providerStatus: providerStatus,
            reconnectGraceNanoseconds: reconnectGraceNanoseconds,
            reconnectInitialBackoffNanoseconds: reconnectInitialBackoffNanoseconds,
            receiptKeyRotationTimeoutNanoseconds: receiptKeyRotationTimeoutNanoseconds,
            attestationGenerator: attestationGenerator,
            webSocketFactory: webSocketFactory,
            sleepAssertionFactory: { nil },
            pairingController: pairingController,
            providerReceiptPublicKey: publicKey,
            credentialBootstrap: true,
            bootstrapReceiptSigningKey: receiptKey,
            providerCredentialStore: providerCredentialStore,
            credentialStatusRuntime: credentialStatusRuntime,
            watchdogExitHook: watchdogExitHook
        ) else {
            return false
        }

        do {
            try await recoveryClient.connectAndRunOnce()
        } catch is CoordinatorAuthUpgradeReconnect {
            await recoveryClient.stop()
            let recoveredFromKeychain = try? providerCredentialStore.load(providerID: providerID)
            guard let recovered = recoveredFromKeychain?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !recovered.isEmpty,
                  recovered != rejectedToken else {
                Self.keepaliveDebug("bootstrap_credential_recovery_persist_missing")
                return false
            }
            await removeRejectedLegacyCredentialSource(rejectedToken)
            providerToken = recovered
            Self.keepaliveDebug("bootstrap_credential_recovery_succeeded")
            return true
        } catch {
            await recoveryClient.stop()
            Self.keepaliveDebug("bootstrap_credential_recovery_failed error=\(Self.sanitizedDiagnosticText(String(describing: error)))")
            return false
        }
        await recoveryClient.stop()
        return false
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
        installTier2Session(session, sendFrame: { payload in
            try await Self.send(payload, to: socket)
        })
    }

    private func installTier2SessionForCurrentConnection(_ session: Tier2ProviderSession) {
        if let webSocket {
            installTier2Session(session, socket: webSocket)
            return
        }
        installTier2Session(session, sendFrame: { [weak self] payload in
            guard let self else { throw CancellationError() }
            try await self.send(payload)
        })
    }

    private func installTier2Session(_ session: Tier2ProviderSession, sendFrame: @escaping InferenceRelay.SendFrame) {
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
            sendFrame: sendFrame
        )
    }

    private func markAutoupdateTrustDemoted(reason: String) {
        autoupdateDemotionReason = reason
    }

    private func runAuthenticatedSocketThenReconnect(_ socket: ProviderWebSocketTask) async {
        do {
            try await receiveLoop(socket)
            await cleanupConnection()
            recordConnectionFailureLifecycle(
                state: .coordinatorUnavailable,
                reasonCode: "coordinator_connection_ended"
            )
            runTask = nil
            startReconnectTask()
        } catch is CancellationError {
            await cleanupConnection()
            runTask = nil
        } catch is CoordinatorDrainComplete {
            await cleanupConnection()
            recordConnectionFailureLifecycle(
                state: .coordinatorUnavailable,
                reasonCode: "coordinator_drain_complete"
            )
            runTask = nil
            print("coordinator reconnect attempt 1 scheduled after drain")
            try? await Task.sleep(nanoseconds: reconnectGraceNanoseconds)
            startReconnectTask()
        } catch is CoordinatorAuthUpgradeReconnect {
            await cleanupConnection()
            if !operatorPaused {
                _ = try? recordLifecycleTransition(
                    to: .locallyReadyConnecting,
                    reasonCode: "coordinator_auth_upgrade_reconnect",
                    compatibilitySetID: installedCompatibilitySetID()
                )
            }
            runTask = nil
            print("coordinator reconnect scheduled after provisional token adoption")
            try? await Task.sleep(nanoseconds: reconnectGraceNanoseconds)
            startReconnectTask()
        } catch {
            await cleanupConnection()
            let classification = Self.lifecycleClassification(for: error)
            recordConnectionFailureDiagnostic(reasonCode: classification.reasonCode, error: error)
            recordConnectionFailureLifecycle(
                state: classification.state,
                reasonCode: classification.reasonCode
            )
            runTask = nil
            print("WARN coordinator rotated session ended last_error=\(error)")
            startReconnectTask()
        }
    }

    private func connectAndRun() async throws {
        let socket = try await openWebSocket()
        if credentialBootstrap || wsTunneledMode {
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
        let attachesBearer = !credentialBootstrap && providerToken != nil
        if attachesBearer, let token = providerToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let socket = webSocketFactory(request)
        webSocket = socket
        socket.resume()
        Self.keepaliveDebug("ws_resume url=\(Self.redactedURL(coordinatorURL)) token=\(attachesBearer ? "present" : "absent")")
        return socket
    }

    private func connectAndRunTier2(socket: ProviderWebSocketTask) async throws {
        do {
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
        } catch {
            guard !coordinatorSessionAccepted else {
                throw error
            }
            if let closeError = Self.authProtocolErrorFromCloseDiagnostics(socket) {
                throw closeError
            }
            throw error
        }
    }

    private static func authProtocolErrorFromCloseDiagnostics(_ socket: ProviderWebSocketTask) -> CoordinatorAuthError? {
        guard let closeCode = socket.closeCodeRawValueForDiagnostics else {
            return nil
        }
        let reason = sanitizedDiagnosticText(socket.closeReasonTextForDiagnostics ?? "")
        switch closeCode {
        case 4001 where reason.hasPrefix("invalid_auth_request"):
            return .rejected(
                code: "invalid_auth_request",
                message: reason.isEmpty ? "coordinator closed invalid auth_request" : reason
            )
        case 4001 where reason == "autotune_evidence_required"
            || reason == "autotune_evidence_invalid"
            || reason == "autotune_evidence_binary_version_mismatch"
            || reason == "autotune_model_uncatalogued"
            || reason == "autotune_model_cap_exceeded"
            || reason == "autotune_gate_unavailable"
            || reason == "catalog_incompatible":
            // Pearl hello-gate / catalog admission closes use CloseInvalidHello
            // (4001). Remap them so lifecycle UX can distinguish pending
            // hardware verification from generic reconnect (#582).
            return .rejected(code: reason, message: reason)
        case 4005 where reason == "invalid_token" ||
            reason == "bootstrap_identity_mismatch" ||
            reason == "bootstrap_token_used" ||
            reason == "bootstrap_token_expired" ||
            reason == "referral_required" ||
            reason == "referral_invalid" ||
            reason == "referral_expired" ||
            reason == "referral_revoked" ||
            reason == "referral_exhausted" ||
            reason == "referral_conflict":
            return .rejected(code: reason, message: reason)
        case 4004 where reason.hasPrefix("version_unsupported"):
            // Issue #767: the coordinator's hard binary-version floor
            // (`coordinator_advertised_version.required_binary_version`) closes
            // with CloseVersionUnsupported and a reason shaped
            // "version_unsupported: binary_version <ours> below required <theirs>".
            // Before this case the close fell through to `default: nil`, so the
            // raw transport error propagated and the reconnect loop retried
            // forever — the operator saw an unexplained flap instead of an
            // upgrade directive. The FULL reason is carried in `message` so the
            // required target can be parsed out; see requiredBinaryVersion(from:).
            return .rejected(code: "version_unsupported", message: reason)
        case 4008 where reason == "credential_bootstrap_rate_limited":
            return .rejected(code: reason, message: reason)
        case 4000 where reason == "unrecognized auth message":
            return .invalidMessage(reason)
        default:
            return nil
        }
    }

    private func connectAndRunLegacy(socket: ProviderWebSocketTask) async throws {
        tier2Session = nil
        pendingAEADRekey = nil
        preparingAEADRekeyID = nil
        inBandAEADRekeyEnabled = false
        // endpoint_url legacy mode — no relay needed.
        inferenceRelay = nil
        do {
            try await send(await helloMessage())
            try await receiveLoop(socket)
        } catch {
            if let closeError = Self.authProtocolErrorFromCloseDiagnostics(socket) {
                throw closeError
            }
            throw error
        }
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
        // Deliberately do NOT release the sleep assertion here: cleanupConnection
        // runs on every disconnect, and the provider must keep the Mac awake
        // while reconnecting. Serving intent is cleared explicitly instead — at
        // the terminal loop exits, on operator pause, and on stop() — never on a
        // transient disconnect.
        await inferenceRelay?.cancelAllAndClear()
        inferenceRelay = nil
        tier2Session = nil
        pendingAEADRekey = nil
        preparingAEADRekeyID = nil
        inBandAEADRekeyEnabled = false
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        coordinatorSessionAccepted = false
        autoupdateCoordinatorPayload = [:]
        autoupdateCoordinatorPayloadIsV2 = false
        autoupdateAssignedProviderTokenAdopted = false
        autoupdateDemotionReason = "coordinator_disconnected"
        recommendedCompatibilitySetID = nil
        try? autoupdateMarkerStore.clearCompatibilityAdmission()
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
        case "aead_rekey_request":
            try await handleAEADRekeyRequest(dict)
        case "aead_rekey_commit":
            try await handleAEADRekeyCommit(dict)
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
        case LosslessnessProbeProtocol.requestType, LosslessnessProbeProtocol.encryptedRequestType:
            try await handleLosslessnessProbeRequest(dict)
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

    private func handleAEADRekeyRequest(_ message: [String: Any]) async throws {
        guard Self.intValue(message["version"]) == 1,
              let rekeyID = message["rekey_id"] as? String, !rekeyID.isEmpty,
              let assignedID = message["assigned_id"] as? String,
              assignedID == acceptedAssignedProviderID,
              let reason = message["reason"] as? String,
              reason == "request_threshold" || reason == "age_threshold",
              let oldKID = message["old_kid"] as? String,
              let coordinatorPublicKey = message["coordinator_ecdh_public_key"] as? String,
              let selectedAEAD = message["selected_aead"] as? String,
              selectedAEAD == Tier2ProviderSession.aeadSuite,
              let expiresAtRaw = message["expires_at"] as? String,
              let expiresAt = Self.parseAEADRekeyExpiry(expiresAtRaw),
              expiresAt > Date(),
              inBandAEADRekeyEnabled,
              let activeSession = tier2Session,
              activeSession.assignedID == assignedID,
              activeSession.keyID == oldKID,
              preparingAEADRekeyID == nil,
              pendingAEADRekey == nil
        else {
            throw CoordinatorAuthError.invalidMessage("invalid aead_rekey_request binding")
        }

        preparingAEADRekeyID = rekeyID
        do {
            guard let remainingSeconds = Self.rekeyWaitSeconds(until: expiresAt) else {
                throw CoordinatorAuthError.invalidMessage("expired aead_rekey_request")
            }
            if let inferenceRelay,
               await !inferenceRelay.waitUntilIdle(timeoutSeconds: remainingSeconds) {
                throw CoordinatorAuthError.invalidMessage("aead_rekey_request timed out waiting for idle relay")
            }
            guard preparingAEADRekeyID == rekeyID,
                  pendingAEADRekey == nil,
                  coordinatorSessionAccepted,
                  inBandAEADRekeyEnabled,
                  acceptedAssignedProviderID == assignedID,
                  expiresAt > Date(),
                  tier2Session?.keyID == oldKID
            else {
                throw CoordinatorAuthError.invalidMessage("stale aead_rekey_request after idle wait")
            }

            let attempt = Tier2AuthAttempt()
            let nextSession = try Tier2ProviderSession(
                attempt: attempt,
                providerID: providerID,
                assignedID: assignedID,
                coordinatorPublicKeyBase64URL: coordinatorPublicKey,
                selectedAEAD: selectedAEAD,
                expectedKeyID: nil
            )
            if message["response_chunk_plaintext_envelope"] as? Bool == true {
                nextSession.enableResponseChunkPlaintextEnvelope()
            }
            pendingAEADRekey = PendingAEADRekey(
                rekeyID: rekeyID,
                assignedID: assignedID,
                oldKID: oldKID,
                coordinatorPublicKey: coordinatorPublicKey,
                providerPublicKey: attempt.publicKeyBase64URL,
                selectedAEAD: selectedAEAD,
                expiresAtRaw: expiresAtRaw,
                expiresAt: expiresAt,
                session: nextSession
            )
            preparingAEADRekeyID = nil
            try await send([
                "type": "aead_rekey_response",
                "version": 1,
                "rekey_id": rekeyID,
                "assigned_id": assignedID,
                "old_kid": oldKID,
                "new_kid": nextSession.keyID,
                "provider_ecdh_public_key": attempt.publicKeyBase64URL,
            ])
        } catch {
            if preparingAEADRekeyID == rekeyID {
                preparingAEADRekeyID = nil
            }
            if pendingAEADRekey?.rekeyID == rekeyID {
                pendingAEADRekey = nil
            }
            throw error
        }
    }

    private func handleAEADRekeyCommit(_ message: [String: Any]) async throws {
        guard let pending = pendingAEADRekey,
              pending.expiresAt > Date(),
              Self.intValue(message["version"]) == 1,
              message["rekey_id"] as? String == pending.rekeyID,
              message["assigned_id"] as? String == pending.assignedID,
              message["old_kid"] as? String == pending.oldKID,
              message["new_kid"] as? String == pending.session.keyID,
              coordinatorSessionAccepted,
              inBandAEADRekeyEnabled,
              acceptedAssignedProviderID == pending.assignedID,
              tier2Session?.keyID == pending.oldKID
        else {
            throw CoordinatorAuthError.invalidMessage("invalid aead_rekey_commit binding")
        }

        let proofData = try pending.session.openAEADRekeyCommit(message, rekeyID: pending.rekeyID)
        guard let proofObject = try JSONSerialization.jsonObject(with: proofData) as? [String: Any],
              proofObject["type"] as? String == "aead_rekey_proof",
              Self.intValue(proofObject["version"]) == 1,
              proofObject["rekey_id"] as? String == pending.rekeyID,
              proofObject["provider_id"] as? String == providerID,
              proofObject["assigned_id"] as? String == pending.assignedID,
              proofObject["old_kid"] as? String == pending.oldKID,
              proofObject["new_kid"] as? String == pending.session.keyID,
              proofObject["provider_ecdh_public_key"] as? String == pending.providerPublicKey,
              proofObject["coordinator_ecdh_public_key"] as? String == pending.coordinatorPublicKey,
              proofObject["selected_aead"] as? String == pending.selectedAEAD,
              proofObject["expires_at"] as? String == pending.expiresAtRaw
        else {
            throw CoordinatorAuthError.invalidMessage("invalid aead_rekey_commit proof")
        }

        guard let remainingSeconds = Self.rekeyWaitSeconds(until: pending.expiresAt) else {
            throw CoordinatorAuthError.invalidMessage("expired aead_rekey_commit")
        }
        if let inferenceRelay,
           await !inferenceRelay.waitUntilIdle(timeoutSeconds: remainingSeconds) {
            throw CoordinatorAuthError.invalidMessage("aead_rekey_commit timed out waiting for idle relay")
        }
        guard pendingAEADRekey?.rekeyID == pending.rekeyID,
              pending.expiresAt > Date(),
              coordinatorSessionAccepted,
              inBandAEADRekeyEnabled,
              acceptedAssignedProviderID == pending.assignedID,
              tier2Session?.keyID == pending.oldKID
        else {
            throw CoordinatorAuthError.invalidMessage("stale aead_rekey_commit after idle wait")
        }
        let committedEnvelope = try pending.session.sealAEADRekeyCommitted(rekeyID: pending.rekeyID, proof: proofData)
        let committed: [String: Any] = [
            "type": "aead_rekey_committed",
            "version": 1,
            "rekey_id": pending.rekeyID,
            "assigned_id": pending.assignedID,
            "old_kid": pending.oldKID,
            "new_kid": pending.session.keyID,
            "encrypted": true,
            "enc": committedEnvelope,
        ]

        // Never roll back to the old epoch after proving possession of the new
        // keys. If the acknowledgement send fails, normal connection cleanup
        // forces a fresh full authentication instead of reusing counters.
        installTier2SessionForCurrentConnection(pending.session)
        pendingAEADRekey = nil
        try await send(committed)
    }

    private static func parseAEADRekeyExpiry(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractional.date(from: raw) {
            return parsed
        }
        let wholeSeconds = ISO8601DateFormatter()
        wholeSeconds.formatOptions = [.withInternetDateTime]
        return wholeSeconds.date(from: raw)
    }

    private static func rekeyWaitSeconds(until expiry: Date) -> Int? {
        let remaining = expiry.timeIntervalSinceNow
        guard remaining.isFinite, remaining > 0 else {
            return nil
        }
        return max(1, Int(min(ceil(remaining), Double(Int32.max))))
    }

    private func handleLosslessnessProbeRequest(_ message: [String: Any]) async throws {
        guard appConfig.losslessnessProbeEnabled else {
            try await sendNAK(
                inReplyTo: message["type"] as? String ?? LosslessnessProbeProtocol.requestType,
                code: "losslessness_probe_disabled",
                message: "losslessness_probe_v1 is disabled by provider config"
            )
            return
        }

        do {
            try await handleEnabledLosslessnessProbeRequest(message)
        } catch is LosslessnessProbeError {
            try await sendNAK(
                inReplyTo: message["type"] as? String ?? LosslessnessProbeProtocol.requestType,
                code: "invalid_message",
                message: "invalid losslessness_probe_v1 request"
            )
        } catch is Tier2ProviderError {
            try await sendNAK(
                inReplyTo: message["type"] as? String ?? LosslessnessProbeProtocol.requestType,
                code: "invalid_message",
                message: "invalid losslessness_probe_v1 encrypted request"
            )
        }
    }

    private func handleEnabledLosslessnessProbeRequest(_ message: [String: Any]) async throws {
        let encrypted = message["type"] as? String == LosslessnessProbeProtocol.encryptedRequestType
        let outer: [String: Any]
        var encryptedRequestID: String?
        if encrypted {
            guard let tier2Session,
                  let requestID = message["request_id"] as? String, !requestID.isEmpty
            else {
                try await sendNAK(inReplyTo: LosslessnessProbeProtocol.encryptedRequestType, code: "invalid_message", message: "losslessness encrypted request requires Tier-2 session and request_id")
                return
            }
            encryptedRequestID = requestID
            outer = try tier2Session.openLosslessnessProbeRequestPayload(message: message, requestID: requestID).outerEnvelope
        } else {
            if tier2Session != nil {
                try await sendNAK(inReplyTo: LosslessnessProbeProtocol.requestType, code: "invalid_message", message: "losslessness plaintext request rejected for active Tier-2 session")
                return
            }
            outer = message
        }

        let requestEnvelope = try LosslessnessProbeProtocol.decodeEnvelope(outer, expectedType: LosslessnessProbeProtocol.requestType)
        let requestPayload = try LosslessnessProbeProtocol.decodeRequestPayload(requestEnvelope.payload)
        if let encryptedRequestID, encryptedRequestID != requestEnvelope.probeID {
            try await sendNAK(inReplyTo: LosslessnessProbeProtocol.encryptedRequestType, code: "invalid_message", message: "losslessness encrypted request_id must match probe_id")
            return
        }
        let inconclusive = LosslessnessProbeRuntime.providerInconclusiveForUnavailableSampler(
            probeID: requestEnvelope.probeID,
            probeNonce: requestPayload.probeNonce,
            requestDigest: requestEnvelope.probeRequestDigest
        )
        let resultDigest = try LosslessnessProbeProtocol.digest(payload: inconclusive)
        let resultOuter: [String: Any] = [
            "type": LosslessnessProbeProtocol.resultType,
            "probe_id": requestEnvelope.probeID,
            "probe_request_digest": requestEnvelope.probeRequestDigest,
            "probe_result_digest": resultDigest,
            "payload": inconclusive,
        ]

        if encrypted {
            guard let tier2Session else {
                throw LosslessnessProbeError.invalidEnvelope
            }
            try await send(tier2Session.sealLosslessnessProbeResult(requestID: encryptedRequestID ?? requestEnvelope.probeID, outerEnvelope: resultOuter))
        } else {
            try await send(resultOuter)
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

    // Test seam — the sleep assertion is held for the whole serving lifetime
    // and must survive a per-connection cleanup (disconnect). These expose the
    // acquire/held/cleanup surface so a test can prove the assertion is not
    // released on disconnect and only released on stop().
    func sleepAssertionIsHeldForTest() -> Bool {
        sleepAssertion != nil
    }

    func setSleepAssertionDesiredForTest(_ desired: Bool) {
        setSleepAssertionDesired(desired)
    }

    func cleanupConnectionForTest() async {
        await cleanupConnection()
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

    static func heartbeatWatchdogToleranceNanosecondsForTest(intervalSeconds: Int) -> UInt64 {
        heartbeatWatchdogToleranceNanoseconds(intervalSeconds: intervalSeconds)
    }

    func seedLastHeartbeatSuccessForTest(ageNanoseconds: UInt64) {
        let now = DispatchTime.now().uptimeNanoseconds
        lastHeartbeatSuccessNanoseconds = now > ageNanoseconds ? now - ageNanoseconds : 1
    }

    func cancelHeartbeatWatchdogForTest() {
        heartbeatWatchdogTask?.cancel()
        heartbeatWatchdogTask = nil
    }

    func suppressSignedRecoveryDiscoveryForTest() {
        lastSignedRecoveryDiscoveryAttempt = Date()
    }

    // Issue #189 R1 security MEDIUM: assert that any inbound frame
    // bumps the heartbeat success timestamp via handle().
    func handleForTest(_ message: URLSessionWebSocketTask.Message) async throws {
        try await handle(message)
    }

    func tier2KeyIDForTest() -> String? {
        tier2Session?.keyID
    }

    func pendingAEADRekeyIDForTest() -> String? {
        pendingAEADRekey?.rekeyID
    }

    func tier2CountersForTest() -> (c2p: UInt64, p2c: UInt64)? {
        tier2Session?.countersForTest
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
        if credentialBootstrap {
            guard let initialMessage,
                  let bootstrapReceiptSigningKey else {
                throw CoordinatorAuthError.invalidMessage("credential bootstrap receipt identity unavailable")
            }
            proof["credential_bootstrap"] = true
            if let bootstrapReferralCode {
                proof["referral_code"] = bootstrapReferralCode
            }
            let transcriptSHA256 = try Self.initialAuthTranscriptHashBase64(initialMessage)
            let payload = try Self.credentialBootstrapIdentityPayload(
                challenge: challenge,
                authAttemptID: attemptID,
                providerID: providerID,
                providerECDHPublicKey: attempt.publicKeyBase64URL,
                transcriptSHA256: transcriptSHA256
            )
            let signature = try bootstrapReceiptSigningKey.signature(for: payload)
            proof["identity_signature"] = signature.base64EncodedString()
            proof["identity_signature_transcript_sha256"] = transcriptSHA256
        }

        // Every credentialed provider keeps a CLI-owned admission key in
        // Keychain. Historical mp-* coordinators use the bootstrap hint name;
        // current coordinators use admission_identity_public_key.
        let receiptIdentitySigningKey: Curve25519.Signing.PrivateKey? = {
            guard !receiptIdentitySigningKeys.isEmpty else { return nil }
            if let expected = (challenge["admission_identity_public_key"] as? String)
                ?? (challenge["bootstrap_identity_public_key"] as? String) {
                return receiptIdentitySigningKeys.first(where: {
                    Data($0.publicKey.rawRepresentation).base64EncodedString() == expected
                })
            }
            return receiptIdentitySigningKeys.count == 1 ? receiptIdentitySigningKeys[0] : nil
        }()
        if !credentialBootstrap, let receiptIdentitySigningKey, let initialMessage {
            let signingPublicKey = Data(receiptIdentitySigningKey.publicKey.rawRepresentation).base64EncodedString()
            if challenge["admission_identity_public_key"] != nil
                || challenge["bootstrap_identity_public_key"] != nil {
                try persistReceiptIdentitySigningKey?(receiptIdentitySigningKey)
                // This closure exists only while restoring/enrolling a missing
                // dedicated CLI identity. Pending rotation uses a separate CAS
                // closure and must not become current before acceptance.
                if persistReceiptIdentitySigningKey != nil {
                    providerAdmissionPublicKey = signingPublicKey
                }
            }
            let transcriptSHA256 = try Self.initialAuthTranscriptHashBase64(initialMessage)
            let payload = try Self.receiptIdentityPayload(
                authAttemptID: attemptID,
                providerID: providerID,
                providerECDHPublicKey: attempt.publicKeyBase64URL,
                transcriptSHA256: transcriptSHA256
            )
            let signature = try receiptIdentitySigningKey.signature(for: payload)
            proof["identity_signature"] = signature.base64EncodedString()
            proof["identity_signature_transcript_sha256"] = transcriptSHA256
            lastAdmissionProofPublicKey = signingPublicKey
        }

        return proof
    }

    static func receiptIdentityPayload(
        authAttemptID: String,
        providerID: String,
        providerECDHPublicKey: String,
        transcriptSHA256: String
    ) throws -> Data {
        let tuple: [String: Any] = [
            "auth_attempt_id": authAttemptID,
            "provider_id": providerID,
            "binary_version": Self.binaryVersion,
            "provider_ecdh_public_key": providerECDHPublicKey,
            "transcript_sha256": transcriptSHA256,
        ]
        return try CanonicalJSON.encode(CanonicalJSON.fromJSONLike(tuple))
    }

    /// Compute `base64(SHA-256(CanonicalJSON(initialMessage)))`. Matches
    /// what the coordinator retains from the initial auth_request stage
    /// via `phase4-coordinator/internal/ws/identity_signature.go:15`.
    static func initialAuthTranscriptHashBase64(_ message: [String: Any]) throws -> String {
        let canonical = try CanonicalJSON.encode(CanonicalJSON.fromJSONLike(message))
        let digest = SHA256.hash(data: canonical)
        return Data(digest).base64EncodedString()
    }

    static func credentialBootstrapIdentityPayload(
        challenge: [String: Any],
        authAttemptID: String,
        providerID: String,
        providerECDHPublicKey: String,
        transcriptSHA256: String
    ) throws -> Data {
        let requiredChallengeFields = [
            "type", "version", "auth_attempt_id", "assigned_id", "attestation_challenge",
            "attestation_formats", "coordinator_ecdh_public_key", "selected_aead_suite", "expires_at",
        ]
        for field in requiredChallengeFields where challenge[field] == nil {
            throw CoordinatorAuthError.invalidMessage("auth_challenge missing \(field)")
        }
        var challengeWire: [String: Any] = [:]
        for field in requiredChallengeFields {
            challengeWire[field] = challenge[field]
        }
        for field in ["selected_aead", "key_id"] where challenge[field] != nil {
            challengeWire[field] = challenge[field]
        }
        let tuple: [String: Any] = [
            "challenge": challengeWire,
            "auth_attempt_id": authAttemptID,
            "provider_id": providerID,
            "binary_version": Self.binaryVersion,
            "provider_ecdh_public_key": providerECDHPublicKey,
            "transcript_sha256": transcriptSHA256,
            "credential_bootstrap": true,
        ]
        return try CanonicalJSON.encode(CanonicalJSON.fromJSONLike(tuple))
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
        _ = try validateCompatibilitySetAcceptance(response)
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
        inBandAEADRekeyEnabled = encryptedLeg["in_band_aead_rekey_v1"] as? Bool == true
    }

    /// Persist-before-adopt for newly assigned credentials. CLI Keychain is
    /// the only durable destination; a failed commit leaves the in-memory
    /// credential unchanged and fails this admission attempt.
    private func adoptAssignedProviderTokenIfPresent(_ payload: [String: Any]) async throws -> Bool {
        guard let assigned = payload["assigned_provider_token"] as? String else {
            return false
        }
        let trimmed = assigned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }
        let path = configPath
        let providerID = providerID
        let store = providerCredentialStore
        let rejectedToken = providerToken
        let result: Result<Void, Error> = await Task.detached(priority: .utility) {
            do {
                try store.replace(providerID: providerID, token: trimmed)
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case .success:
            Self.emitTokenPersistEvent(event: "provider_token_keychain_persisted", path: path, error: nil)
        case .failure(let error):
            Self.emitTokenPersistEvent(event: "provider_token_keychain_persist_failed", path: path, error: error)
            throw CoordinatorAuthError.invalidMessage("assigned provider credential could not be committed")
        }

        if let rejectedToken, rejectedToken != trimmed {
            await removeRejectedLegacyCredentialSource(rejectedToken)
        }

        self.providerToken = trimmed
        await credentialStatusRuntime.update(
            ProviderCredentialStatus(source: .cliKeychain, state: .ready, restartSafe: true)
        )
        return true
    }

    private func removeRejectedLegacyCredentialSource(_ rejectedToken: String) async {
        guard !rejectedToken.isEmpty else { return }
        let path = configPath
        let cleanup: Result<Bool, Error> = await Task.detached(priority: .utility) {
            do {
                return .success(try ProviderTokenPersist.remove(
                    expectedToken: rejectedToken,
                    configPath: path
                ))
            } catch {
                return .failure(error)
            }
        }.value
        switch cleanup {
        case .success(true):
            Self.emitTokenPersistEvent(
                event: "provider_token_rejected_legacy_source_removed",
                path: path,
                error: nil
            )
        case .success(false):
            Self.emitTokenPersistEvent(
                event: "provider_token_rejected_legacy_source_preserved_mismatch",
                path: path,
                error: nil
            )
        case .failure(let error):
            Self.emitTokenPersistEvent(
                event: "provider_token_rejected_legacy_source_cleanup_failed",
                path: path,
                error: error
            )
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

    private func validateCompatibilitySetAcceptance(
        _ payload: [String: Any]
    ) throws -> (accepted: String, recommended: String)? {
        guard let compatibilitySetID else {
            return nil
        }
        guard let policy = payload["compatibility_policy"] as? String else {
            throw CoordinatorAuthError.invalidMessage(
                "coordinator omitted explicit compatibility-set policy"
            )
        }
        switch policy {
        case "configured":
            guard payload["accepted_compatibility_set_id"] as? String == compatibilitySetID,
                  let recommended = payload["recommended_compatibility_set_id"] as? String,
                  CompatibilitySetManifest.isCanonicalCompatibilitySetID(recommended) else {
                throw CoordinatorAuthError.invalidMessage(
                    "coordinator compatibility-set acknowledgement did not match installed signed set"
                )
            }
            return (compatibilitySetID, recommended)
        case "unconfigured":
            guard payload["accepted_compatibility_set_id"] == nil,
                  payload["recommended_compatibility_set_id"] == nil else {
                throw CoordinatorAuthError.invalidMessage(
                    "unconfigured coordinator returned a contradictory compatibility-set acknowledgement"
                )
            }
            return nil
        default:
            throw CoordinatorAuthError.invalidMessage(
                "coordinator returned an unknown compatibility-set policy"
            )
        }
    }

    private func acceptCoordinatorSession(_ payload: [String: Any], reason: String) async throws {
        let compatibilityAdmission: (accepted: String, recommended: String)?
        do {
            compatibilityAdmission = try validateCompatibilitySetAcceptance(payload)
        } catch {
            recommendedCompatibilitySetID = nil
            try? autoupdateMarkerStore.clearCompatibilityAdmission()
            throw error
        }
        if catalogReleaseID != nil, payload["catalog_compatible"] as? Bool != true {
            throw CoordinatorAuthError.invalidMessage("coordinator did not accept provider catalog release")
        }
        try await reconcileAdmissionIdentityIfNeeded(payload)
        // SPEC-003 v0.8.2 FR-C9.3 — single hook for both v1 (hello_ack)
        // and v2 (auth_response) ack paths since both funnel here.
        // Awaited so that persist-before-adopt holds: see
        // adoptAssignedProviderTokenIfPresent doc-comment.
        let assignedProviderTokenAdopted = try await adoptAssignedProviderTokenIfPresent(payload)
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
        recommendedCompatibilitySetID = compatibilityAdmission?.recommended
        autoupdateDisabledForSessionReason = nil
        do {
            if let compatibilityAdmission {
                try autoupdateMarkerStore.persistCompatibilityAdmission(
                    acceptedCompatibilitySetID: compatibilityAdmission.accepted,
                    recommendedCompatibilitySetID: compatibilityAdmission.recommended
                )
            } else {
                try autoupdateMarkerStore.clearCompatibilityAdmission()
            }
        } catch {
            autoupdateDisabledForSessionReason = "compatibility_admission_persist_failed"
        }
        await providerStatus.setCoordinatorSession(
            connected: true,
            assignedID: payload["assigned_id"] as? String,
            tier: payload["tier"] as? String,
            identityAdmissionMode: payload["identity_admission_mode"] as? String,
            recommendedBinaryVersion: payload["recommended_binary_version"] as? String
        )
        acceptedAssignedProviderID = (payload["assigned_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        await providerStatus.setCatalogCompatibilityConfirmed(
            catalogReleaseID == nil || payload["catalog_compatible"] as? Bool == true
        )
        coordinatorSessionAccepted = true
        if let tier = payload["tier"] as? String {
            print("Coordinator tier: \(tier)")
        }
        // A live, non-paused session means the provider is serving. This is
        // load-bearing for the receipt-key-rotation session that runs outside
        // runReconnectLoop(); it is idempotent for the ordinary loop path.
        if !operatorPaused {
            setSleepAssertionDesired(true)
        }
	        startHeartbeat(intervalSeconds: interval)
	        try await sendStateUpdate(state: nil, reason: reason)
	        if operatorPaused {
            _ = try recordLifecycleTransition(
                to: .pausedByOperator,
                reasonCode: "operator_pause_restored_after_admission",
                compatibilitySetID: installedCompatibilitySetID(),
                writer: .operatorCommand,
                operatorPaused: true
            )
            return
        }
        if lifecycleOperationID != nil {
            let servingCapabilityConfirmed = await waitForCoordinatorServingCapability()
            guard servingCapabilityConfirmed else {
                _ = try recordLifecycleTransition(
                    to: .locallyReadyConnecting,
                    reasonCode: "buyer_serving_readiness_unconfirmed",
                    compatibilitySetID: installedCompatibilitySetID()
                )
                throw CoordinatorAuthError.invalidMessage("coordinator buyer-serving readiness was not confirmed")
            }
        }
        _ = try recordLifecycleTransition(
            to: .servingBuyers,
            reasonCode: "coordinator_buyer_serving_confirmed",
            compatibilitySetID: installedCompatibilitySetID()
        )
        await finalizeAdmissionBoundaryAfterServingProof(
            successReason: "coordinator_admitted_serving_capability_confirmed"
        )
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

    private func recordConnectionFailureDiagnostic(reasonCode: String, error: Error) {
        let nsError = error as NSError
        let raw = "\(reasonCode): domain=\(nsError.domain) code=\(nsError.code)"
        lastConnectionFailureDiagnostic = Self.redactedDiagnosticText(raw, maxLength: 160)
        lastConnectionFailureAt = Date()
    }

    func recordConnectionFailureDiagnosticForTest(reasonCode: String, error: Error) async {
        recordConnectionFailureDiagnostic(reasonCode: reasonCode, error: error)
    }

    func diagnosticStatusPayloadForTest(reason: String = "test") async -> [String: Any] {
        await diagnosticStatusPayload(reason: reason)
    }

    private func sendDiagnosticStatus(reason: String) async throws {
        let payload = await diagnosticStatusPayload(reason: reason)
        guard payload["assigned_id"] as? String != nil else { return }
        try await send(payload)
    }

    private func diagnosticStatusPayload(reason: String) async -> [String: Any] {
        let snapshot = await providerStatus.snapshot()
        let observedAt = Date()
        let assignedID = snapshot.coordinatorAssignedID ?? acceptedAssignedProviderID
        var payload: [String: Any] = [
            "type": "diagnostic_status",
            "schema_version": 1,
            "reason": Self.sanitizedDiagnosticText(reason, maxLength: 64),
            "observed_at": ISO8601DateFormatter().string(from: observedAt),
            "provider_id": providerID,
            "assigned_id": assignedID ?? NSNull(),
            "binary_version": Self.binaryVersion,
            "status": snapshot.status.rawValue,
            "model_id": coordinatorWireModelID(for: snapshot.modelID),
            "model_loaded": snapshot.modelLoaded,
            "model_hash": snapshot.modelHash ?? NSNull(),
            "model_hash_algorithm": snapshot.modelHashAlgorithm ?? NSNull(),
            "weights_manifest_sha256": snapshot.weightsManifestSHA256 ?? NSNull(),
            "weights_manifest_algorithm": snapshot.weightsManifestAlgorithm ?? NSNull(),
            "uptime_s": snapshot.uptimeSeconds,
            "requests_total": snapshot.requestsTotal,
            "requests_in_flight": snapshot.requestsInFlight,
            "errors_total": snapshot.errorsTotal,
            "restart_count": snapshot.restartCount,
            "memory_rss_mb": snapshot.memoryRSSMB,
            "memory_pressure": snapshot.memoryPressure.rawValue,
            "thermal_state": snapshot.thermalState,
            "thermally_throttled": snapshot.thermallyThrottled,
            "capacity": [
                "ram_gb": snapshot.capacity.ramGB,
                "ram_tier": snapshot.capacity.ramTier,
                "max_context_tokens": snapshot.capacity.maxContextTokens,
                "max_concurrency": snapshot.capacity.maxConcurrency,
                "throughput_tps_estimate": snapshot.capacity.throughputTPSEstimate,
            ] as [String: Any],
            "coordinator": [
                "connected": snapshot.coordinatorConnected,
                "session": assignedID ?? NSNull(),
                "tier": snapshot.coordinatorTier ?? NSNull(),
                "identity_admission_mode": snapshot.coordinatorIdentityAdmissionMode ?? NSNull(),
                "recommended_binary_version": snapshot.recommendedBinaryVersion ?? NSNull(),
            ] as [String: Any],
            "credential": [
                "token_configured": providerToken != nil,
                "bootstrap_mode": credentialBootstrap,
            ] as [String: Any],
            "catalog": [
                "release_id": catalogReleaseID ?? NSNull(),
                "policy_version": catalogPolicyVersion ?? NSNull(),
                "candidate_sha256": catalogCandidateSHA256 ?? NSNull(),
                "signer_key_id": catalogSignerKeyID ?? NSNull(),
                "row_identity": catalogRowIdentity ?? NSNull(),
            ] as [String: Any],
            "compatibility_set_id": compatibilitySetID ?? NSNull(),
        ]
        if let lastConnectionFailureDiagnostic {
            payload["last_connection_failure"] = [
                "at": lastConnectionFailureAt.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(),
                "diagnostic": lastConnectionFailureDiagnostic,
            ] as [String: Any]
        }
        return payload
    }

    /// The server returns its authoritative active key after every accepted
    /// signed admission. Persist a staged rotation before adopting the session;
    /// an unknown key fails closed instead of silently changing local custody.
    func reconcileAdmissionIdentityIfNeeded(_ payload: [String: Any]) async throws {
        let admissionIdentityContractExpected = providerAdmissionPublicKey != nil
            || providerAdmissionNextPublicKey != nil
            || providerAdmissionRecovery
            || lastAdmissionProofPublicKey != nil
        guard admissionIdentityContractExpected else {
            return
        }
        guard let active = payload["admission_identity_public_key"] as? String,
              !active.isEmpty else {
            await admissionIdentityStatusRuntime.recordFailure(
                "coordinator_omitted_admission_identity_contract",
                recoveryAction: "retry_or_run_credentials_repair"
            )
            throw CoordinatorAuthError.invalidMessage("coordinator omitted the admission identity contract")
        }
        guard let raw = Data(base64Encoded: active), raw.count == 32 else {
            await admissionIdentityStatusRuntime.recordFailure(
                "coordinator_returned_invalid_admission_identity",
                recoveryAction: "retry_or_run_credentials_repair"
            )
            throw CoordinatorAuthError.invalidMessage("coordinator returned an invalid admission identity")
        }
        let activeDigest = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
        guard let generation = payload["identity_generation"] as? Int,
              generation >= 1,
              let keyRole = payload["identity_admission_key_role"] as? String,
              ["current", "previous", "recovery"].contains(keyRole) else {
            await admissionIdentityStatusRuntime.recordFailure(
                "coordinator_returned_incomplete_admission_identity_contract",
                recoveryAction: "retry_or_run_credentials_repair"
            )
            throw CoordinatorAuthError.invalidMessage("coordinator returned an incomplete admission identity contract")
        }
        let previousValidUntil: Date?
        if let text = payload["admission_identity_previous_valid_until"] as? String {
            guard let parsed = CredentialRestartProver.parseISO8601(text) else {
                await admissionIdentityStatusRuntime.recordFailure(
                    "coordinator_returned_invalid_previous_identity_deadline",
                    recoveryAction: "retry_or_run_credentials_repair"
                )
                throw CoordinatorAuthError.invalidMessage(
                    "coordinator returned an invalid previous admission identity deadline"
                )
            }
            previousValidUntil = parsed
        } else {
            previousValidUntil = nil
        }
        if active == providerAdmissionPublicKey {
            if providerAdmissionRecovery {
                guard generation >= 2,
                      ["recovery", "current"].contains(keyRole),
                      let commitAdmissionIdentityPublicKey else {
                    await admissionIdentityStatusRuntime.recordFailure(
                        "coordinator_did_not_authorize_identity_recovery",
                        recoveryAction: "obtain_operator_recovery_approval_then_retry"
                    )
                    throw CoordinatorAuthError.invalidMessage("coordinator did not authorize admission identity recovery")
                }
                try commitAdmissionIdentityPublicKey(raw, nil)
                providerAdmissionRecovery = false
                await admissionIdentityStatusRuntime.recordAccepted(
                    coordinatorPublicKeySHA256: activeDigest,
                    generation: generation,
                    keyRole: keyRole,
                    localState: "ready",
                    localSource: "cli_keychain",
                    localPublicKeySHA256: activeDigest,
                    recoveryAction: "none",
                    replaceLocalKeyState: true
                )
            } else {
                guard keyRole == "current" else {
                    await admissionIdentityStatusRuntime.recordFailure(
                        "coordinator_returned_mismatched_admission_identity_role",
                        recoveryAction: "retry_or_run_credentials_repair"
                    )
                    throw CoordinatorAuthError.invalidMessage("coordinator returned a mismatched admission identity role")
                }
                await admissionIdentityStatusRuntime.recordAccepted(
                    coordinatorPublicKeySHA256: activeDigest,
                    generation: generation,
                    keyRole: keyRole
                )
            }
            return
        }
        if active == providerAdmissionNextPublicKey,
           generation >= 2,
           keyRole == "current" {
            guard let previousValidUntil, let commitAdmissionIdentityPublicKey else {
                await admissionIdentityStatusRuntime.recordFailure(
                    "coordinator_omitted_previous_identity_deadline",
                    recoveryAction: "retry_or_run_credentials_repair"
                )
                throw CoordinatorAuthError.invalidMessage(
                    "coordinator omitted the previous admission identity deadline"
                )
            }
            let previousDigest = providerAdmissionPublicKey
                .flatMap { Data(base64Encoded: $0) }
                .map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
            try commitAdmissionIdentityPublicKey(raw, previousValidUntil)
            providerAdmissionPublicKey = active
            providerAdmissionNextPublicKey = nil
            let stillValid = previousValidUntil > Date()
            let previousValidUntilText = stillValid
                ? Self.formatAdmissionIdentityDeadline(previousValidUntil)
                : nil
            await admissionIdentityStatusRuntime.recordAccepted(
                coordinatorPublicKeySHA256: activeDigest,
                generation: generation,
                keyRole: keyRole,
                localState: "ready",
                localSource: "cli_keychain",
                localPublicKeySHA256: activeDigest,
                previousPublicKeySHA256: stillValid ? previousDigest : nil,
                previousValidUntil: previousValidUntilText,
                recoveryAction: "none",
                replaceLocalKeyState: true
            )
            return
        }

        // A rolled-back binary may prove the coordinator's bounded previous
        // key. The authenticated response still names the authoritative current
        // public key, which cannot restore a missing private key. Admit this
        // degraded session without changing custody; rotation remains disabled.
        if keyRole == "previous",
           generation >= 2,
           let lastAdmissionProofPublicKey,
           lastAdmissionProofPublicKey == providerAdmissionPublicKey,
           lastAdmissionProofPublicKey != active {
            guard let previousValidUntil, previousValidUntil > Date() else {
                await admissionIdentityStatusRuntime.recordFailure(
                    "coordinator_previous_identity_deadline_expired_or_missing",
                    recoveryAction: "restore_current_key_or_run_recover_admission_identity"
                )
                throw CoordinatorAuthError.invalidMessage(
                    "coordinator returned an expired or missing previous admission identity deadline"
                )
            }
            await admissionIdentityStatusRuntime.recordAccepted(
                coordinatorPublicKeySHA256: activeDigest,
                generation: generation,
                keyRole: keyRole,
                localState: "degraded_previous_key",
                previousValidUntil: Self.formatAdmissionIdentityDeadline(previousValidUntil),
                recoveryAction: "restore_current_key_or_run_recover_admission_identity"
            )
            return
        }
        await admissionIdentityStatusRuntime.recordFailure(
            "coordinator_accepted_unknown_admission_identity",
            recoveryAction: "run_credentials_repair_or_recover_admission_identity"
        )
        throw CoordinatorAuthError.invalidMessage("coordinator accepted an unknown admission identity")
    }

    private static func formatAdmissionIdentityDeadline(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private enum AdmissionUpdateBoundary: Equatable {
        case noPendingUpdate
        case committed(AutoUpdatePendingMarker)
        case restoredPrevious(AutoUpdatePendingMarker)
        case pendingRollback
    }

    private func commitPendingAutoupdateAfterServingProof() async -> AdmissionUpdateBoundary {
        guard let completedAutoupdate = try? autoupdateMarkerStore.readPending() else {
            return .noPendingUpdate
        }
        if completedAutoupdate.transactionState == .restoringPrevious
            || completedAutoupdate.transactionState == .awaitingPreviousReadiness
        {
            guard completedAutoupdate.previousVersion == Self.binaryVersion,
                  previousCompatibilitySetMatchesInstalled(completedAutoupdate),
                  await waitForCoordinatorServingCapability()
            else {
                return .pendingRollback
            }
            do {
                let transactionLock = try autoupdateMarkerStore.acquireRecoveryLock()
                defer { withExtendedLifetime(transactionLock) {} }
                guard var current = try autoupdateMarkerStore.readPending(),
                      current.updateID == completedAutoupdate.updateID,
                      current.transactionState == .restoringPrevious
                        || current.transactionState == .awaitingPreviousReadiness
                else {
                    throw AutoUpdateMarkerError.invalidMarker
                }
                if current.transactionState == .restoringPrevious {
                    current = try autoupdateMarkerStore.markPreviousRestoredAwaitingReadiness(current)
                }
                try autoupdateMarkerStore.completeRestoredPreviousSet(current)
                return .restoredPrevious(current)
            } catch {
                await AutoUpdateEventStore.shared.record(AutoUpdateEvent(
                    updateID: completedAutoupdate.updateID,
                    currentVersion: Self.binaryVersion,
                    targetVersion: completedAutoupdate.targetVersion,
                    phase: .rollback,
                    outcome: .failure,
                    reason: "previous_set_readiness_cleanup_failed",
                    attempt: 1,
                    failureClass: .other
                ))
                return .pendingRollback
            }
        }
        guard completedAutoupdate.targetVersion == Self.binaryVersion else {
            return .pendingRollback
        }
        // The old `macprovider-cli update` process owns this transaction and
        // may still roll back its child. The child must not clear either the
        // marker or the legacy YAML credential.
        guard completedAutoupdate.commitOwner != "self_update" else {
            return .pendingRollback
        }
        guard pendingCompatibilitySetMatchesInstalled(completedAutoupdate) else {
            await AutoUpdateEventStore.shared.record(AutoUpdateEvent(
                updateID: completedAutoupdate.updateID,
                currentVersion: Self.binaryVersion,
                targetVersion: completedAutoupdate.targetVersion,
                phase: .postStart,
                outcome: .failure,
                reason: "compatibility_set_readiness_mismatch",
                attempt: 1,
                failureClass: .other
            ))
            return .pendingRollback
        }
        if !localSignedSetRecoveryAllowed(completedAutoupdate) {
            guard await waitForCoordinatorServingCapability() else {
                return .pendingRollback
            }
        }
        do {
            let transactionLock = try autoupdateMarkerStore.acquireRecoveryLock()
            defer { withExtendedLifetime(transactionLock) {} }
            guard let current = try autoupdateMarkerStore.readPending(),
                  current.updateID == completedAutoupdate.updateID,
                  current.targetVersion == completedAutoupdate.targetVersion,
                  current.targetPath == completedAutoupdate.targetPath,
                  current.backupPath == completedAutoupdate.backupPath else {
                throw AutoUpdateMarkerError.invalidMarker
            }
            try autoupdateMarkerStore.completeSuccessfulUpdate(current)
            try autoupdateMarkerStore.finalizeSuccessfulUpdate(current)
            return .committed(completedAutoupdate)
        } catch {
            // Preserve the sentinel/pending state when cleanup is incomplete so
            // startup recovery can finish it idempotently. Credential cleanup
            // is also withheld because rollback may still restore an old binary.
            await AutoUpdateEventStore.shared.record(AutoUpdateEvent(
                updateID: completedAutoupdate.updateID,
                currentVersion: Self.binaryVersion,
                targetVersion: completedAutoupdate.targetVersion,
                phase: .postStart,
                outcome: .failure,
                reason: "buyer_serving_commit_cleanup_failed",
                attempt: 1,
                failureClass: .other
            ))
            return .pendingRollback
        }
    }

    private func finalizeAdmissionBoundaryAfterServingProof(successReason: String) async {
        let updateBoundary = await commitPendingAutoupdateAfterServingProof()
        if updateBoundary != .pendingRollback {
            // A pre-v1.8.34 rollback binary cannot read CLI Keychain. Commit
            // the coordinator update transaction before removing its YAML
            // compatibility bearer; failed readiness must leave rollback viable.
            await finalizeLegacyCredentialSourceAfterAdmission()
        }
        if case .committed(let completedAutoupdate) = updateBoundary {
            await AutoUpdateEventStore.shared.record(AutoUpdateEvent(
                updateID: completedAutoupdate.updateID,
                currentVersion: Self.binaryVersion,
                targetVersion: completedAutoupdate.targetVersion,
                phase: .postStart,
                outcome: .success,
                reason: successReason,
                attempt: 1
            ))
        } else if case .restoredPrevious(let completedAutoupdate) = updateBoundary {
            await AutoUpdateEventStore.shared.record(AutoUpdateEvent(
                updateID: completedAutoupdate.updateID,
                currentVersion: Self.binaryVersion,
                targetVersion: completedAutoupdate.targetVersion,
                phase: .rollback,
                outcome: .success,
                reason: "previous_compatibility_set_admitted_and_buyer_serving",
                attempt: 1
            ))
        }
    }

    private func localSignedSetRecoveryAllowed(_ marker: AutoUpdatePendingMarker) -> Bool {
        marker.updateAuthorityMode == "signed_release"
            && marker.targetCompatibilitySetID != nil
            && marker.targetCompatibilitySetSHA256 != nil
            && marker.discoveryHeadSequence != nil
            && marker.discoveryHeadSHA256 != nil
    }

    private func waitForStableLocalAutoupdateHealth(
        _ marker: AutoUpdatePendingMarker
    ) async -> Bool {
        let expectedInstanceKey = "\(getpid()):\(RouterHandler.serviceInstanceID)"
        for sample in 0 ..< autoupdateLocalHealthRequiredConsecutiveSamples {
            guard !Task.isCancelled else { return false }
            let status = await autoupdateLocalStatusProbe()
            guard Self.localHealthyTargetInstanceKey(
                status,
                targetVersion: marker.targetVersion,
                expectedCompatibilitySetID: marker.targetCompatibilitySetID,
                expectedCompatibilitySetSHA256: marker.targetCompatibilitySetSHA256,
                expectedServiceInstanceID: RouterHandler.serviceInstanceID,
                expectedProcessID: getpid()
            ) == expectedInstanceKey else {
                return false
            }
            if sample + 1 < autoupdateLocalHealthRequiredConsecutiveSamples {
                await autoupdateLocalHealthSleep()
            }
        }
        return true
    }

    static func localHealthyTargetInstanceKey(
        _ status: [String: Any]?,
        targetVersion: String,
        expectedCompatibilitySetID: String?,
        expectedCompatibilitySetSHA256: String?,
        expectedServiceInstanceID: String,
        expectedProcessID: pid_t
    ) -> String? {
        guard let status,
              status["binary_version"] as? String == targetVersion,
              expectedCompatibilitySetID == nil
                || status["compatibility_set_id"] as? String == expectedCompatibilitySetID,
              expectedCompatibilitySetSHA256 == nil
                || status["compatibility_set_sha256"] as? String == expectedCompatibilitySetSHA256,
              let health = status["status"] as? String,
              ["ready", "busy", "degraded"].contains(health),
              let serviceInstance = status["service_instance"] as? [String: Any],
              serviceInstance["instance_id"] as? String == expectedServiceInstanceID,
              let processID = serviceInstance["pid"] as? Int,
              processID == Int(expectedProcessID),
              !expectedServiceInstanceID.isEmpty,
              expectedProcessID > 0
        else {
            return nil
        }
        return "\(processID):\(expectedServiceInstanceID)"
    }

    private func pendingCompatibilitySetMatchesInstalled(_ marker: AutoUpdatePendingMarker) -> Bool {
        switch (marker.targetCompatibilitySetID, marker.targetCompatibilitySetSHA256) {
        case (nil, nil):
            return true
        case let (.some(expectedID), .some(expectedDigest)):
            guard let installed = installedCompatibilityManifest(
                URL(fileURLWithPath: marker.targetPath),
                Self.binaryVersion
            ) else { return false }
            return installed.compatibilitySetID == expectedID
                && installed.envelopeSHA256 == expectedDigest
        default:
            return false
        }
    }

    private func previousCompatibilitySetMatchesInstalled(_ marker: AutoUpdatePendingMarker) -> Bool {
        guard let expectedVersion = marker.previousVersion,
              let expectedID = marker.previousCompatibilitySetID,
              let expectedDigest = marker.previousCompatibilitySetSHA256,
              let installed = installedCompatibilityManifest(
                  URL(fileURLWithPath: marker.targetPath),
                  expectedVersion
              )
        else { return false }
        return installed.compatibilitySetID == expectedID
            && installed.envelopeSHA256 == expectedDigest
            && compatibilitySetID == expectedID
    }

    func finalizeCredentialAfterAutoupdateBoundaryForTest(assignedProviderID: String) async {
        acceptedAssignedProviderID = assignedProviderID
        let boundary = await commitPendingAutoupdateAfterServingProof()
        if boundary != .pendingRollback {
            await finalizeLegacyCredentialSourceAfterAdmission()
        }
    }

    /// The compatibility YAML remains intact until a restarted provider that
    /// resolved this exact value from CLI Keychain completes authenticated
    /// coordinator admission and publishes its first state update. Cleanup is
    /// compare-and-remove under the config lock, so a newer or conflicting
    /// credential is never deleted.
    private func finalizeLegacyCredentialSourceAfterAdmission() async {
        let status = await credentialStatusRuntime.snapshot()
        guard status.source == .cliKeychain,
              status.migrationPending,
              let expected = providerToken,
              !expected.isEmpty else {
            return
        }
        let store = providerCredentialStore
        let providerID = providerID
        let path = configPath
        let result: Result<Bool, Error> = await Task.detached(priority: .utility) {
            do {
                guard try store.load(providerID: providerID) == expected else {
                    return .success(false)
                }
                return .success(try ProviderTokenPersist.remove(
                    expectedToken: expected,
                    configPath: path
                ))
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case .success(true):
            await credentialStatusRuntime.update(
                ProviderCredentialStatus(source: .cliKeychain, state: .ready, restartSafe: true)
            )
            Self.emitTokenPersistEvent(
                event: "provider_token_legacy_source_removed_after_admission",
                path: path,
                error: nil
            )
        case .success(false):
            Self.emitTokenPersistEvent(
                event: "provider_token_legacy_source_preserved_mismatch",
                path: path,
                error: nil
            )
        case .failure(let error):
            Self.emitTokenPersistEvent(
                event: "provider_token_legacy_source_cleanup_failed",
                path: path,
                error: error
            )
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

    /// Rollback is committed only after the coordinator's public readiness
    /// verdict confirms admitted buyer-serving capability for the provider's
    /// current or previous signed catalog. A connected/accepted WebSocket alone
    /// is insufficient, while a busy provider remains serving-capable.
    private func waitForCoordinatorServingCapability() async -> Bool {
        guard let assignedProviderID = acceptedAssignedProviderID,
              !assignedProviderID.isEmpty,
              let releaseID = catalogReleaseID,
              let policyVersion = catalogPolicyVersion,
              let candidateSHA256 = catalogCandidateSHA256,
              let signerKeyID = catalogSignerKeyID,
              let rowIdentity = catalogRowIdentity
        else {
            return false
        }
        let expected = CoordinatorReadinessClient.ExpectedCatalogEnvelope(
            releaseID: releaseID,
            policyVersion: policyVersion,
            candidateSHA256: candidateSHA256,
            signerKeyID: signerKeyID,
            rowIdentity: rowIdentity
        )
        for attempt in 0 ..< coordinatorReadinessAttempts {
            if await coordinatorReadiness(providerID, assignedProviderID, expected) == true {
                return true
            }
            guard attempt + 1 < coordinatorReadinessAttempts,
                  coordinatorReadinessRetryNanoseconds > 0,
                  !Task.isCancelled
            else {
                break
            }
            try? await Task.sleep(nanoseconds: coordinatorReadinessRetryNanoseconds)
        }
        return false
    }

    @discardableResult
    private func recordLifecycleTransition(
        to state: ProviderLifecycleState,
        reasonCode: String,
        compatibilitySetID: String?,
        writer: ProviderLifecycleWriter = .serve,
        operationID: String? = nil,
        operatorPaused: Bool? = nil
    ) throws -> ProviderLifecycleStateRecord? {
        guard let lifecycleOperationID else { return nil }
        return try lifecycleStateStore.transition(
            to: state,
            reasonCode: reasonCode,
            writer: writer,
            providerID: providerID,
            modelID: loadedModelID,
            compatibilitySetID: compatibilitySetID,
            operationID: operationID ?? lifecycleOperationID,
            operatorPaused: operatorPaused
        )
    }

    private func installedCompatibilitySetID() -> String? {
        compatibilitySetID
    }

    private func runStartupAutoupdateRecovery() async {
        guard let binaryURL = CompatibilitySetManifest.resolvedExecutableURL(
            Bundle.main.executableURL
        ) else { return }
        await runStartupAutoupdateRecovery(binaryURL: binaryURL, markerStore: autoupdateMarkerStore)
    }

    func runStartupAutoupdateRecoveryForTest(binaryURL: URL, markerStore: AutoUpdateMarkerStore) async {
        await runStartupAutoupdateRecovery(binaryURL: binaryURL, markerStore: markerStore)
    }

    private func runStartupAutoupdateRecovery(binaryURL: URL, markerStore: AutoUpdateMarkerStore) async {
        let transactionLock: AutoUpdateLock
        do {
            transactionLock = try markerStore.acquireRecoveryLock()
        } catch {
            return
        }
        defer { withExtendedLifetime(transactionLock) {} }
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
            let payload: (
                updateID: String,
                binaryVersion: String,
                targetCompatibilitySetID: String?,
                targetCompatibilitySetSHA256: String?
            )
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
            if let expectedID = payload.targetCompatibilitySetID,
               expectedID != pending.targetCompatibilitySetID {
                await recordOrphanedSuccessSentinel(
                    updateID: payload.updateID,
                    targetVersion: payload.binaryVersion,
                    reason: "success_set_id_mismatch",
                    sentinel: sentinel
                )
                continue
            }
            if let expectedSHA = payload.targetCompatibilitySetSHA256,
               expectedSHA != pending.targetCompatibilitySetSHA256 {
                await recordOrphanedSuccessSentinel(
                    updateID: payload.updateID,
                    targetVersion: payload.binaryVersion,
                    reason: "success_set_digest_mismatch",
                    sentinel: sentinel
                )
                continue
            }
            guard pendingCompatibilitySetMatchesInstalled(pending) else {
                await recordOrphanedSuccessSentinel(
                    updateID: payload.updateID,
                    targetVersion: payload.binaryVersion,
                    reason: "installed_set_mismatch",
                    sentinel: sentinel
                )
                continue
            }
            if localSignedSetRecoveryAllowed(pending),
               !(await waitForStableLocalAutoupdateHealth(pending)) {
                return
            }
            do {
                if !localSignedSetRecoveryAllowed(pending) {
                    try await sendStateUpdate(state: nil, reason: "autoupdate_post_start_success")
                }
                try markerStore.completeSuccessfulUpdate(pending)
                try markerStore.finalizeSuccessfulUpdate(pending)
                await AutoUpdateEventStore.shared.record(AutoUpdateEvent(
                    updateID: payload.updateID,
                    currentVersion: Self.binaryVersion,
                    targetVersion: pending.targetVersion,
                    phase: .postStart,
                    outcome: .success,
                    reason: localSignedSetRecoveryAllowed(pending)
                        ? "local_signed_set_health_succeeded"
                        : "post_start_rejoin_succeeded",
                    attempt: 1
                ))
                return
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
            if marker.targetVersion == Self.binaryVersion,
               marker.commitOwner != "self_update",
               localSignedSetRecoveryAllowed(marker),
               pendingCompatibilitySetMatchesInstalled(marker) {
                guard await waitForStableLocalAutoupdateHealth(marker) else {
                    return
                }
                do {
                    try markerStore.completeSuccessfulUpdate(marker)
                    try markerStore.finalizeSuccessfulUpdate(marker)
                    await AutoUpdateEventStore.shared.record(AutoUpdateEvent(
                        updateID: marker.updateID,
                        currentVersion: Self.binaryVersion,
                        targetVersion: marker.targetVersion,
                        phase: .postStart,
                        outcome: .success,
                        reason: "local_signed_set_health_succeeded",
                        attempt: 1
                    ))
                } catch {
                    await AutoUpdateEventStore.shared.record(AutoUpdateEvent(
                        updateID: marker.updateID,
                        currentVersion: Self.binaryVersion,
                        targetVersion: marker.targetVersion,
                        phase: .postStart,
                        outcome: .failure,
                        reason: "local_success_cleanup_failed",
                        attempt: 1,
                        failureClass: .other
                    ))
                }
                return
            }
            guard Self.autoupdateMarkerDeadlineExpired(marker.markerDeadline) else {
                return
            }
            do {
                try autoupdateReloadHelperFence()
            } catch {
                await AutoUpdateEventStore.shared.record(AutoUpdateEvent(
                    updateID: marker.updateID,
                    currentVersion: Self.binaryVersion,
                    targetVersion: marker.targetVersion,
                    phase: .rollback,
                    outcome: .failure,
                    reason: "reload_helper_fence_failed",
                    attempt: 1,
                    failureClass: .other
                ))
                return
            }
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
                case .restoredAwaitingReadiness(let recovered):
                    await AutoUpdateEventStore.shared.record(AutoUpdateEvent(
                        updateID: recovered.updateID,
                        currentVersion: Self.binaryVersion,
                        targetVersion: recovered.targetVersion,
                        phase: .rollback,
                        outcome: .inProgress,
                        reason: "previous_set_restored_awaiting_buyer_serving",
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
                case let .rollbackTargetDisallowed(recovered):
                    autoupdateDisabledForSessionReason = "rollback_target_disallowed"
                    await AutoUpdateEventStore.shared.record(AutoUpdateEvent(
                        updateID: recovered.updateID,
                        currentVersion: Self.binaryVersion,
                        targetVersion: recovered.targetVersion,
                        phase: .rollback,
                        outcome: .failure,
                        reason: "rollback_target_disallowed",
                        attempt: 1,
                        failureClass: .rollbackTargetDisallowed
                    ))
            }
        } else {
            for backup in markerStore.rollbackBackups(in: binaryDir) {
                try? FileManager.default.removeItem(at: backup)
            }
        }
    }

    private static func fenceAutoupdateReloadHelpers() throws {
        try SelfUpdate.fenceProviderReloadLaunchdJobs(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            servicePresent: SelfUpdate.launchctlServicePresent,
            loadedServiceLabels: SelfUpdate.launchctlServiceLabels,
            runLaunchctl: { arguments, allowFailure in
                _ = try SelfUpdate.runLaunchctlCommand(
                    arguments: arguments,
                    allowFailure: allowFailure
                )
            }
        )
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
    // A one-second coordinator heartbeat previously produced a three-second
    // watchdog tolerance even though a single bounded send is allowed five
    // seconds. Brief post-boot or inference contention could therefore kill a
    // healthy provider before the send timeout had a chance to reconnect it.
    // Keep the historical 15-second upper bound as the minimum as well: it is
    // still far below coordinator inactivity while exceeding the send bound.
    private static let heartbeatWatchdogMinimumToleranceSeconds: Int = 15
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
        let tolerance = Self.heartbeatWatchdogToleranceNanoseconds(intervalSeconds: intervalSeconds)
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

    private static func heartbeatWatchdogToleranceNanoseconds(intervalSeconds: Int) -> UInt64 {
        let tickSeconds = max(1, min(intervalSeconds, keepaliveTickCeilingSeconds))
        let toleranceSeconds = max(
            tickSeconds * heartbeatWatchdogToleranceMultiplier,
            heartbeatWatchdogMinimumToleranceSeconds
        )
        return UInt64(toleranceSeconds) * 1_000_000_000
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
        if resetWindow {
            renewCompatibilityAdmission()
        }
    }

    private func renewCompatibilityAdmission() {
        guard coordinatorSessionAccepted,
              let accepted = compatibilitySetID,
              let recommended = recommendedCompatibilitySetID else {
            return
        }
        do {
            try autoupdateMarkerStore.persistCompatibilityAdmission(
                acceptedCompatibilitySetID: accepted,
                recommendedCompatibilitySetID: recommended
            )
        } catch {
            autoupdateDisabledForSessionReason = "compatibility_admission_persist_failed"
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

    func pauseByOperator() async -> ProviderControlCommandResult {
        if operatorPaused {
            return .accepted
        }

        await providerStatus.setState(.draining, reason: "operator_pause_draining")
        do {
            try await sendStateUpdate(state: nil, reason: "operator_pause_draining")
        } catch {
            // A disconnected coordinator must not prevent a local pause. Closing
            // the socket also prevents a stale remote route from surviving until
            // the next heartbeat timeout.
            webSocket?.cancel(with: .goingAway, reason: nil)
        }

        guard await providerStatus.waitUntilDrained(timeoutSeconds: drainTimeoutSeconds) else {
            await providerStatus.setState(.ready, reason: "operator_pause_drain_timeout")
            try? await sendStateUpdate(state: nil, reason: "operator_pause_drain_timeout")
            return .rejected("drain_timeout")
        }

        let operationID = "operator-pause:\(UUID().uuidString.lowercased())"
        do {
            _ = try recordLifecycleTransition(
                to: .pausedByOperator,
                reasonCode: "operator_pause_confirmed",
                compatibilitySetID: installedCompatibilitySetID(),
                writer: .operatorCommand,
                operationID: operationID,
                operatorPaused: true
            )
        } catch {
            await providerStatus.setState(.ready, reason: "operator_pause_persistence_failed")
            try? await sendStateUpdate(state: nil, reason: "operator_pause_persistence_failed")
            return .rejected("lifecycle_state_persistence_failed")
        }

        operatorPaused = true
        // A paused provider is fenced from buyer work and is not serving, so it
        // must be allowed to sleep: drop the keep-awake assertion until resume.
        setSleepAssertionDesired(false)
        await providerStatus.setState(.unavailable, reason: "operator_paused")
        do {
            try await sendStateUpdate(state: nil, reason: "operator_paused")
        } catch {
            webSocket?.cancel(with: .goingAway, reason: nil)
        }
        return .accepted
    }

    func resumeByOperator() async -> ProviderControlCommandResult {
        guard operatorPaused else {
            return .accepted
        }

        let operationID = "operator-resume:\(UUID().uuidString.lowercased())"
        do {
            _ = try recordLifecycleTransition(
                to: .locallyReadyConnecting,
                reasonCode: "operator_resume_requested",
                compatibilitySetID: installedCompatibilitySetID(),
                writer: .operatorCommand,
                operationID: operationID,
                operatorPaused: false
            )
        } catch {
            return .rejected("lifecycle_state_persistence_failed")
        }

        operatorPaused = false
        // Resuming means the provider intends to serve again: re-arm keep-awake
        // so the reconnect/serving path cannot let the Mac sleep. The canServe
        // gate makes this a no-op if the loop already exited terminally (e.g.
        // below-floor version), so a resume cannot keep a non-serving Mac awake.
        setSleepAssertionDesired(true)
        await providerStatus.setState(.ready, reason: "operator_resumed")
        do {
            try await sendStateUpdate(state: nil, reason: "operator_resumed")
        } catch {
            webSocket?.cancel(with: .goingAway, reason: nil)
            return .accepted
        }

        guard lifecycleOperationID != nil, coordinatorSessionAccepted else {
            return .accepted
        }
        if await waitForCoordinatorServingCapability() {
            _ = try? recordLifecycleTransition(
                to: .servingBuyers,
                reasonCode: "operator_resume_buyer_serving_confirmed",
                compatibilitySetID: installedCompatibilitySetID(),
                writer: .operatorCommand,
                operationID: operationID,
                operatorPaused: false
            )
            // A provider may restart into a durable paused state while an
            // installer-owned update transaction is awaiting buyer-serving
            // proof. Resume supplies that proof, so it must cross the same
            // commit/credential-cleanup boundary as ordinary admission.
            await finalizeAdmissionBoundaryAfterServingProof(
                successReason: "operator_resume_serving_capability_confirmed"
            )
        } else {
            _ = try? recordLifecycleTransition(
                to: .locallyReadyConnecting,
                reasonCode: "operator_resume_readiness_unconfirmed",
                compatibilitySetID: installedCompatibilitySetID(),
                writer: .operatorCommand,
                operationID: operationID,
                operatorPaused: false
            )
        }
        return .accepted
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
        // Keep the sleep assertion: a drain is a coordinator restart, after
        // which the reconnect loop reconnects. Releasing here would let the Mac
        // sleep during the drain grace window and stall the reconnect. The loop
        // releases it on terminal exit; stop() releases it on shutdown.
        // v1.1.4: reset local state for the next coordinator session.
        // Local HTTP server kept serving throughout drain; provider is ready.
        await providerStatus.setState(.ready, reason: "drain_complete")
    }

    private func runAutoupdateIfEligible(_ recommended: String) async {
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
            expectedCompatibilitySetID: recommendedCompatibilitySetID,
            markerStore: autoupdateMarkerStore,
            trustProvider: { await self.currentAutoupdateTrustState() },
            drain: { target in try await self.autoupdateDrain(target: target) },
            sendReady: { try await self.sendStateUpdate(state: .ready, reason: "autoupdate_timeout_skipped_ready") }
        )
        await updater.handleCoordinatorRecommendation(recommended)
    }

    private func runSignedRecoveryDiscoveryIfDue(now: Date = Date()) async {
        guard !coordinatorSessionAccepted else { return }
        if let lastSignedRecoveryDiscoveryAttempt,
           now.timeIntervalSince(lastSignedRecoveryDiscoveryAttempt) < signedRecoveryDiscoveryIntervalSeconds() {
            return
        }
        lastSignedRecoveryDiscoveryAttempt = now
        let updater = AutoUpdater(
            config: appConfig,
            currentVersion: Self.binaryVersion,
            providerStatus: providerStatus,
            markerStore: autoupdateMarkerStore,
            trustProvider: { await self.currentAutoupdateTrustState() },
            drain: { target in await self.autoupdateLocalDrain(target: target) },
            sendReady: {
                await self.providerStatus.setState(.ready, reason: "autoupdate_timeout_skipped_ready")
            }
        )
        await updater.handleSignedReleaseDiscovery()
    }

    private func signedRecoveryDiscoveryIntervalSeconds() -> TimeInterval {
        let jitter = TimeInterval(Int.random(in: 0...30))
        return 300 + jitter
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

    private func autoupdateLocalDrain(target: String) async -> Bool {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        heartbeatWatchdogTask?.cancel()
        heartbeatWatchdogTask = nil
        await providerStatus.setState(.draining, reason: "autoupdate_to_\(target)")
        let softDrained = await providerStatus.waitUntilDrained(timeoutSeconds: 120)
        if softDrained {
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
        if !hardDrained {
            await providerStatus.setState(.ready, reason: "autoupdate_drain_timeout")
        }
        return hardDrained
    }

    func autoupdateLocalDrainForTest(target: String) async -> Bool {
        await autoupdateLocalDrain(target: target)
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
            if catalogReleaseID != nil {
                guard await catalogRuntimeMatches(runtimeSnapshot) else {
                    catalogWarmSwapInvalidated = true
                    throw CoordinatorAuthError.invalidMessage(
                        "warm-swapped model has no model-specific signed catalog admission"
                    )
                }
            }
            payload["model_id"] = runtimeWireModelID
            payload["model_params_b"] = snapshot.capacity.modelParamsB(modelID: runtimeWireModelID)
            if let modelHash = runtimeSnapshot.modelHash {
                payload["model_hash"] = modelHash
                if let algorithm = runtimeSnapshot.modelHashAlgorithm {
                    payload["model_hash_algorithm"] = algorithm
                }
            }
            if let weights = runtimeSnapshot.weightsManifestSHA256 {
                payload["weights_manifest_sha256"] = weights
                payload["weights_manifest_algorithm"] = ModelArtifactIdentity.safetensorsManifestV1
            }
            payload["loading"] = runtimeSnapshot.state == .loading || runtimeSnapshot.state == .draining
            specDecodeTelemetryMatchesRuntime = runtimeSnapshot.specDecodeGeneration == snapshot.specDecodeGeneration
            specDecodeTelemetryRuntimeEligible = runtimeSnapshot.state == .ready && runtimeSnapshot.hasTargetCompatibleDraft
        } else if let modelHash = snapshot.modelHash,
                  let algorithm = snapshot.modelHashAlgorithm {
            payload["model_hash"] = modelHash
            payload["model_hash_algorithm"] = algorithm
            if let weights = snapshot.weightsManifestSHA256 {
                payload["weights_manifest_sha256"] = weights
                payload["weights_manifest_algorithm"] = ModelArtifactIdentity.safetensorsManifestV1
            }
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
        let observedAt = Date()
        payload["safety_telemetry"] = snapshot.safetyTelemetry(
            providerID: providerID,
            modelID: payload["model_id"] as? String ?? snapshotWireModelID,
            binaryVersion: Self.binaryVersion,
            compatibilitySetID: compatibilitySetID,
            modelHash: payload["model_hash"] as? String ?? snapshot.modelHash,
            modelHashAlgorithm: payload["model_hash_algorithm"] as? String ?? snapshot.modelHashAlgorithm,
            weightsManifestSHA256: payload["weights_manifest_sha256"] as? String ?? snapshot.weightsManifestSHA256,
            observationID: UUID().uuidString.lowercased(),
            observedAt: ISO8601DateFormatter().string(from: observedAt),
            validForMS: 90_000
        )
        try await send(payload)
    }

    private func sendStateUpdate(state newState: ProviderHealthState?, reason: String) async throws {
        if let newState {
            await providerStatus.setState(newState, reason: reason)
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
        if coordinatorSessionAccepted {
            do {
                try await sendDiagnosticStatus(reason: reason)
            } catch {
                Self.keepaliveDebug("diagnostic_status_send_error error=\(Self.sanitizedDiagnosticText(String(describing: error)))")
            }
        }
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
        lastAdmissionProofPublicKey = nil
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
        let resolvedModelHashAlgorithm: String?
        let resolvedWeightsManifestSHA256: String?
        if warmSwapEnabled {
            let runtimeSnapshot = await modelRuntime.currentSnapshot()
            wireModelID = coordinatorWireModelID(for: runtimeSnapshot.modelID)
            resolvedModelHash = runtimeSnapshot.modelHash
            resolvedModelHashAlgorithm = runtimeSnapshot.modelHashAlgorithm
            resolvedWeightsManifestSHA256 = runtimeSnapshot.weightsManifestSHA256
        } else {
            wireModelID = coordinatorWireModelID(for: snapshot.modelID)
            resolvedModelHash = snapshot.modelHash
            resolvedModelHashAlgorithm = snapshot.modelHashAlgorithm
            resolvedWeightsManifestSHA256 = snapshot.weightsManifestSHA256
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
                "in_band_aead_rekey_v1": true,
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
        appendCatalogAdmissionMetadata(to: &message, wireModelID: wireModelID)
        let receiptPublicKey = providerReceiptPublicKeyOverride ?? providerReceiptPublicKey
        if let receiptPublicKey, !receiptPublicKey.isEmpty {
            message["provider_receipt_public_key"] = receiptPublicKey
        }
        if let providerAdmissionPublicKey, !providerAdmissionPublicKey.isEmpty,
           !credentialBootstrap {
            message["provider_admission_public_key"] = providerAdmissionPublicKey
        }
        if let providerAdmissionNextPublicKey, !providerAdmissionNextPublicKey.isEmpty,
           !credentialBootstrap {
            message["provider_admission_next_public_key"] = providerAdmissionNextPublicKey
        }
        if providerAdmissionRecovery, !credentialBootstrap {
            message["provider_admission_recovery"] = true
        }
        if let compatibilitySetID {
            message["compatibility_set_id"] = compatibilitySetID
        }
        if let endpointURL {
            message["endpoint_url"] = endpointURL
        }
        if let modelHash = resolvedModelHash {
            message["model_hash"] = modelHash
            if let resolvedModelHashAlgorithm {
                message["model_hash_algorithm"] = resolvedModelHashAlgorithm
            }
        }
        if let resolvedWeightsManifestSHA256 {
            message["weights_manifest_sha256"] = resolvedWeightsManifestSHA256
            message["weights_manifest_algorithm"] = ModelArtifactIdentity.safetensorsManifestV1
        }
        if credentialBootstrap {
            message["credential_bootstrap"] = true
            if let bootstrapReferralCode {
                message["referral_code"] = bootstrapReferralCode
            }
        }
        return message
    }

    private func appendCatalogAdmissionMetadata(to message: inout [String: Any], wireModelID: String) {
        let catalogWireModelID = catalogModelIDForCoordinator ?? loadedModelID ?? ""
        guard !catalogWarmSwapInvalidated, wireModelID == catalogWireModelID else { return }
        if let catalogReleaseID { message["catalog_release_id"] = catalogReleaseID }
        if let catalogPolicyVersion { message["catalog_policy_version"] = catalogPolicyVersion }
        if let catalogCandidateSHA256 { message["catalog_candidate_sha256"] = catalogCandidateSHA256 }
        if let catalogSignerKeyID { message["catalog_signer_key_id"] = catalogSignerKeyID }
        if let catalogRowIdentity { message["catalog_row_identity"] = catalogRowIdentity }
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
        let hashAlgorithmForHello: String?
        let weightsManifestForHello: String?
        if warmSwapEnabled {
            let runtimeSnapshot = await modelRuntime.currentSnapshot()
            wireModelIDForHello = coordinatorWireModelID(for: runtimeSnapshot.modelID)
            hashForHello = runtimeSnapshot.modelHash
            hashAlgorithmForHello = runtimeSnapshot.modelHashAlgorithm
            weightsManifestForHello = runtimeSnapshot.weightsManifestSHA256
            if catalogReleaseID != nil,
               await catalogRuntimeMatches(runtimeSnapshot) == false {
                catalogWarmSwapInvalidated = true
            }
        } else {
            wireModelIDForHello = coordinatorWireModelID(for: snapshot.modelID)
            hashForHello = snapshot.modelHash
            hashAlgorithmForHello = snapshot.modelHashAlgorithm
            weightsManifestForHello = snapshot.weightsManifestSHA256
        }
        message["model_id"] = wireModelIDForHello
        message["model_params_b"] = snapshot.capacity.modelParamsB(modelID: wireModelIDForHello)
        if let hashForHello {
            message["model_hash"] = hashForHello
            if let hashAlgorithmForHello {
                message["model_hash_algorithm"] = hashAlgorithmForHello
            }
        }
        if let weightsManifestForHello {
            message["weights_manifest_sha256"] = weightsManifestForHello
            message["weights_manifest_algorithm"] = ModelArtifactIdentity.safetensorsManifestV1
        }
        appendCatalogAdmissionMetadata(to: &message, wireModelID: wireModelIDForHello)
        if let compatibilitySetID {
            message["compatibility_set_id"] = compatibilitySetID
        }
        return message
    }

    private func catalogRuntimeMatches(_ snapshot: RuntimeSnapshot) async -> Bool {
        let catalogWireModelID = catalogModelIDForCoordinator ?? loadedModelID ?? ""
        let wireModelID = coordinatorWireModelID(for: snapshot.modelID)
        guard wireModelID == catalogWireModelID else { return false }
        // Generation zero is the boot artifact already admitted by startup
        // preflight's canonical all-file artifact-set verifier. Recompute only
        // after a completed warm swap, including same-model-ID swaps.
        guard snapshot.specDecodeGeneration > 0 else { return true }
        guard let expected = catalogModelSHA256?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !expected.isEmpty else {
            return true
        }
        let resolved = await catalogArtifactIdentity(snapshot.modelID)
        let actual = resolved?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return actual == expected
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
