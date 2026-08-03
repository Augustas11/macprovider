import AppKit
import CryptoKit
import Foundation
import Network

// Non-custodial "Add wallet" flow (SPEC-016 §3):
// 1. CLI `payout-address challenge` (provider token never leaves CLI Keychain)
// 2. Ephemeral 127.0.0.1-ONLY loopback + bundled signer.html in the default browser
// 3. Capture {address, nonce, ts_utc, signature, state} via POST /cb
// 4. CLI `payout-address register` with the public signature only
//
// Malibu never sees, generates, or stores a payout-wallet private key.

enum PayoutWalletFlowError: Error, Equatable {
    case cliNotFound
    case challengeFailed(String)
    case registerFailed(String)
    case loopbackFailed(String)
    case timedOut
    case cancelled
    case invalidCallback
    case missingResources
    case missingProviderID
    case rngFailure
}

struct PayoutChallengeView: Equatable {
    let providerID: String
    let verifyingContract: String
    let chainID: UInt64
    let domainName: String
    let domainVersion: String
    let chain: String
    let serverTsUTC: Int64
    let registeredAddress: String?
    let pendingUntilUTC: String?
    let payoutAllowed: Bool?
}

struct PayoutRegistrationView: Equatable {
    let address: String
    let chain: String
    let pendingUntilUTC: String
    let status: String
    let httpStatus: Int
}

struct PayoutSignedPayload: Equatable {
    let address: String
    let nonce: String
    let tsUtc: UInt64
    let signature: String
    let state: String
}

/// Structural decode target for the UNTRUSTED `/cb` callback body (M1).
/// JSONDecoder performs EXACT integer decoding into `tsUtc` — it natively
/// rejects fractional numbers, negatives, and out-of-range values
/// (including 2^64, which a Double-based bounds check cannot distinguish
/// from UInt64.max), so no hand-rolled NSNumber inspection is needed.
struct PayoutCallbackBody: Decodable, Equatable {
    let address: String
    let nonce: String
    let tsUtc: UInt64
    let signature: String
    let state: String

    enum CodingKeys: String, CodingKey {
        case address, nonce, signature, state
        case tsUtc = "ts_utc"
    }
}

/// Structural decode target for the coordinator/CLI `challenge` response.
/// Uses JSONDecoder for exact `chain_id` / `server_ts_utc` decoding (M1).
struct PayoutChallengeResponse: Decodable {
    let verifyingContract: String
    let chainID: UInt64
    let domainName: String
    let domainVersion: String
    let chain: String
    let serverTsUTC: Int64
    let providerID: String?
    let registeredAddress: String?
    let pendingUntilUTC: String?
    let payoutAllowed: Bool?

    enum CodingKeys: String, CodingKey {
        case verifyingContract = "verifying_contract"
        case chainID = "chain_id"
        case domainName = "domain_name"
        case domainVersion = "domain_version"
        case chain
        case serverTsUTC = "server_ts_utc"
        case providerID = "provider_id"
        case registeredAddress = "registered_address"
        case pendingUntilUTC = "pending_until_utc"
        case payoutAllowed = "payout_allowed"
    }
}

enum PayoutWalletFlow {
    static let callbackTimeout: TimeInterval = 5 * 60
    static let chain = "base-mainnet"

    /// CSPRNG nonce (0x + 32 bytes). Fail-closed: a CSPRNG failure
    /// ABORTS the flow (SPEC-016 §3 non-custodial correlation token
    /// must be unguessable) rather than falling back to a predictable
    /// value. FIX-5.
    static func randomNonceHex() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw PayoutWalletFlowError.rngFailure
        }
        return "0x" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// CSPRNG callback-correlation state (16 bytes hex). Fail-closed:
    /// on a CSPRNG failure the flow ABORTS instead of emitting a
    /// weak/empty state a LAN attacker could guess. FIX-5.
    static func randomState() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw PayoutWalletFlowError.rngFailure
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Prefer server_ts_utc (within coordinator skew window) for ts_utc.
    static func tsUtc(serverTsUTC: Int64, now: Date = Date()) -> UInt64 {
        let server = TimeInterval(serverTsUTC)
        let local = now.timeIntervalSince1970
        // Prefer server clock when within ±4 minutes of local; else local.
        if abs(server - local) <= 4 * 60 {
            return UInt64(max(0, serverTsUTC))
        }
        return UInt64(max(0, local.rounded()))
    }

    static func truncateAddress(_ address: String) -> String {
        guard address.count >= 12 else { return address }
        let prefix = address.prefix(6)
        let suffix = address.suffix(4)
        return "\(prefix)…\(suffix)"
    }

    /// Constant-time equality over UTF-8 bytes. Used for the secret
    /// correlation `state` so a LAN attacker cannot use response-timing
    /// to recover it byte-by-byte. FIX-10.
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8)
        let bb = Array(b.utf8)
        // Length is not secret; a length mismatch is an immediate
        // non-match, but still fold over the longer buffer so the loop
        // count does not leak which side was longer.
        var diff = UInt8(ab.count == bb.count ? 0 : 1)
        let n = max(ab.count, bb.count)
        var i = 0
        while i < n {
            let x = i < ab.count ? ab[i] : 0
            let y = i < bb.count ? bb[i] : 0
            diff |= (x ^ y)
            i += 1
        }
        return diff == 0
    }

    static func validateCallback(
        payload: PayoutSignedPayload,
        expectedState: String,
        expectedNonce: String,
        expectedTsUtc: UInt64
    ) -> Bool {
        // state is the secret correlation token → constant-time (FIX-10).
        guard constantTimeEquals(payload.state, expectedState) else { return false }
        guard payload.nonce == expectedNonce else { return false }
        guard payload.tsUtc == expectedTsUtc else { return false }
        guard payload.address.hasPrefix("0x") || payload.address.hasPrefix("0X") else { return false }
        guard payload.address.count == 42 else { return false }
        guard payload.signature.hasPrefix("0x") || payload.signature.hasPrefix("0X") else { return false }
        guard payload.signature.count == 132 else { return false }
        return true
    }

    // MARK: - CLI

    static func resolveCLI() throws -> URL {
        try CLIUpdateRunner.resolveExecutableURL()
    }

    static func fetchChallenge() async throws -> PayoutChallengeView {
        let cli = try resolveCLI()
        let (stdout, stderr, status) = try await runCLI(cli, arguments: ["payout-address", "challenge"])
        if status != 0 {
            let msg = parseCLIError(stderr: stderr, stdout: stdout)
            throw PayoutWalletFlowError.challengeFailed(msg)
        }
        // M1: exact numeric decoding via JSONDecoder (no NSNumber round-trip).
        guard let resp = try? JSONDecoder().decode(PayoutChallengeResponse.self, from: stdout),
              let providerID = resp.providerID ?? ProviderConfig.readProviderID()
        else {
            throw PayoutWalletFlowError.challengeFailed("Unexpected challenge response.")
        }
        return PayoutChallengeView(
            providerID: providerID,
            verifyingContract: resp.verifyingContract,
            chainID: resp.chainID,
            domainName: resp.domainName,
            domainVersion: resp.domainVersion,
            chain: resp.chain,
            serverTsUTC: resp.serverTsUTC,
            registeredAddress: resp.registeredAddress,
            pendingUntilUTC: resp.pendingUntilUTC,
            payoutAllowed: resp.payoutAllowed
        )
    }

    static func register(
        address: String,
        nonce: String,
        tsUtc: UInt64,
        signature: String,
        chain: String = chain
    ) async throws -> PayoutRegistrationView {
        let cli = try resolveCLI()
        let args = [
            "payout-address", "register",
            "--chain", chain,
            "--address", address,
            "--nonce", nonce,
            "--ts-utc", String(tsUtc),
            "--signature", signature,
        ]
        let (stdout, stderr, status) = try await runCLI(cli, arguments: args)
        if status != 0 {
            throw PayoutWalletFlowError.registerFailed(parseCLIError(stderr: stderr, stdout: stdout))
        }
        guard let obj = try JSONSerialization.jsonObject(with: stdout) as? [String: Any],
              let pending = obj["pending_until_utc"] as? String,
              let regStatus = obj["status"] as? String,
              let outChain = obj["chain"] as? String
        else {
            throw PayoutWalletFlowError.registerFailed("Unexpected registration response.")
        }
        let httpStatus = (obj["http_status"] as? Int) ?? 201
        return PayoutRegistrationView(
            address: (obj["address"] as? String) ?? address,
            chain: outChain,
            pendingUntilUTC: pending,
            status: regStatus,
            httpStatus: httpStatus
        )
    }

    private static func runCLI(_ executable: URL, arguments: [String]) async throws -> (Data, Data, Int32) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                let out = Pipe()
                let err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do {
                    try process.run()
                    process.waitUntilExit()
                    let stdout = out.fileHandleForReading.readDataToEndOfFile()
                    let stderr = err.fileHandleForReading.readDataToEndOfFile()
                    continuation.resume(returning: (stdout, stderr, process.terminationStatus))
                } catch {
                    continuation.resume(throwing: PayoutWalletFlowError.cliNotFound)
                }
            }
        }
    }

    private static func parseCLIError(stderr: Data, stdout: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: stderr) as? [String: Any],
           let message = obj["message"] as? String, !message.isEmpty {
            return message
        }
        if let obj = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any],
           let message = obj["message"] as? String, !message.isEmpty {
            return message
        }
        let errText = String(data: stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !errText.isEmpty { return errText }
        return "CLI payout-address command failed."
    }

    // Numeric parsing is handled structurally by JSONDecoder into
    // PayoutCallbackBody / PayoutChallengeResponse (M1) — exact integer
    // decoding rejects fractional, negative, and out-of-range values
    // (including 2^64) without hand-rolled NSNumber inspection.

    // MARK: - Loopback capture

    /// Starts 127.0.0.1-only server, opens signer in browser, awaits one valid callback.
    static func captureSignature(
        challenge: PayoutChallengeView,
        nonce: String,
        tsUtc: UInt64,
        state: String,
        timeout: TimeInterval = callbackTimeout,
        openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) async throws -> PayoutSignedPayload {
        guard let signerDir = Bundle.main.resourceURL?
            .appendingPathComponent("payout-signer", isDirectory: true),
              FileManager.default.fileExists(atPath: signerDir.appendingPathComponent("signer.html").path),
              FileManager.default.fileExists(atPath: signerDir.appendingPathComponent("ethers.min.js").path)
        else {
            throw PayoutWalletFlowError.missingResources
        }

        let server = LoopbackCaptureServer(resourceDirectory: signerDir)
        // FIX-6: the server validates every callback against these
        // expected values BEFORE it resolves the one-shot, so a
        // malformed/early/wrong-state callback is rejected (4xx) and the
        // server keeps listening for a valid one.
        server.expect(state: state, nonce: nonce, tsUtc: tsUtc)
        try await server.start()
        // FIX-4: teardown on EVERY exit path (success, timeout, cancel, error).
        defer { server.stop() }

        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(server.port)
        components.path = "/signer.html"
        components.queryItems = [
            URLQueryItem(name: "provider_id", value: challenge.providerID),
            URLQueryItem(name: "verifying_contract", value: challenge.verifyingContract),
            URLQueryItem(name: "chain_id", value: String(challenge.chainID)),
            URLQueryItem(name: "chain", value: challenge.chain),
            // M2: thread the coordinator-supplied EIP-712 domain name/version so
            // the signer uses them instead of hardcoded constants — the
            // coordinator stays the single source of truth across a domain
            // migration (verifying_contract already flows through above).
            URLQueryItem(name: "domain_name", value: challenge.domainName),
            URLQueryItem(name: "domain_version", value: challenge.domainVersion),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "ts_utc", value: String(tsUtc)),
            URLQueryItem(name: "redirect_uri", value: "http://127.0.0.1:\(server.port)/cb"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = components.url else {
            throw PayoutWalletFlowError.loopbackFailed("Could not build signer URL.")
        }
        openURL(url)

        let payload = try await server.awaitCallback(timeout: timeout)
        // Defense-in-depth: the server already validated; re-check here.
        guard validateCallback(
            payload: payload,
            expectedState: state,
            expectedNonce: nonce,
            expectedTsUtc: tsUtc
        ) else {
            throw PayoutWalletFlowError.invalidCallback
        }
        return payload
    }
}

// MARK: - Loopback HTTP server (127.0.0.1 ONLY)

final class LoopbackCaptureServer: @unchecked Sendable {
    struct Expectation {
        let state: String
        let nonce: String
        let tsUtc: UInt64
    }

    /// FIX-7 DoS bounds.
    static let maxConnections = 8
    static let maxRequestBytes = 32 * 1024 // total header+body cap
    static let maxContentLength = 16 * 1024
    static let connectionIdleTimeout: TimeInterval = 20

    private let resourceDirectory: URL
    private let queue = DispatchQueue(label: "tech.malibu.payout-loopback")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var connectionTimeouts: [ObjectIdentifier: DispatchWorkItem] = [:]
    private var continuation: CheckedContinuation<PayoutSignedPayload, Error>?
    private var pendingResult: Result<PayoutSignedPayload, Error>?
    private var timeoutWork: DispatchWorkItem?
    private var finished = false
    // M1: the one-shot is CLAIMED synchronously on the serial `queue` the
    // instant a callback validates — before its HTTP response is flushed —
    // so two concurrently-valid callbacks cannot both reach `complete()`
    // (first-in-queue wins; the loser gets 409 and never resolves the flow).
    private var claimed = false
    private var expectation: Expectation?
    private(set) var port: UInt16 = 0

    init(resourceDirectory: URL) {
        self.resourceDirectory = resourceDirectory
    }

    /// FIX-1: NWParameters that force the listener onto the loopback
    /// interface ONLY. `requiredLocalEndpoint = 127.0.0.1:.any` pins the
    /// bound address to IPv4 loopback (the app opens `http://127.0.0.1`),
    /// and `requiredInterfaceType = .loopback` denies every non-loopback
    /// interface — so the ~5-minute capture window is never LAN-reachable.
    static func loopbackParameters() -> NWParameters {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        params.requiredInterfaceType = .loopback
        return params
    }

    /// Test hook: set the expected callback values (FIX-6).
    func expect(state: String, nonce: String, tsUtc: UInt64) {
        queue.sync { self.expectation = Expectation(state: state, nonce: nonce, tsUtc: tsUtc) }
    }

    /// `parametersOverride` is a test-only seam to force a deterministic
    /// bind failure (M3 teardown coverage); production passes nil.
    func start(parametersOverride: NWParameters? = nil) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                var resumed = false
                func resumeOnce(_ result: Result<Void, Error>) {
                    guard !resumed else { return }
                    resumed = true
                    cont.resume(with: result)
                }
                do {
                    let params = parametersOverride ?? LoopbackCaptureServer.loopbackParameters()
                    let listener = try NWListener(using: params)
                    self.listener = listener
                    listener.stateUpdateHandler = { [weak self] state in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            if let p = listener.port?.rawValue {
                                self.port = p
                            }
                            resumeOnce(.success(()))
                        case let .failed(error):
                            let flowError = PayoutWalletFlowError.loopbackFailed(String(describing: error))
                            if resumed {
                                // H1: POST-ready fatal failure. start() has
                                // already returned, so a resume of the start
                                // continuation is a no-op — route through
                                // complete() to resolve the AWAITING flow
                                // (awaitCallback's continuation / pendingResult)
                                // exactly once. Guarded by `finished`, so if a
                                // valid callback already won, this is ignored.
                                self.failListenerPostReady(flowError)
                            } else {
                                // M3: PRE-ready startup failure — fail start()
                                // and tear down; nothing is awaiting yet.
                                self.teardownLocked()
                                self.finished = true
                                resumeOnce(.failure(flowError))
                            }
                        default:
                            break
                        }
                    }
                    listener.newConnectionHandler = { [weak self] connection in
                        self?.accept(connection)
                    }
                    listener.start(queue: self.queue)
                } catch {
                    // M3: NWListener construction failed — nothing was
                    // started, but clear any partial state defensively.
                    self.teardownLocked()
                    self.finished = true
                    resumeOnce(.failure(PayoutWalletFlowError.loopbackFailed(String(describing: error))))
                }
            }
        }
        if port == 0 {
            // M3: `.ready` fired without a published port — tear the
            // listener down instead of leaking it, then fail.
            queue.sync {
                self.teardownLocked()
                self.finished = true
            }
            throw PayoutWalletFlowError.loopbackFailed("Listener did not publish a port.")
        }
    }

    /// Test-only: reports whether a listener is currently retained (M3).
    var isListenerActiveForTest: Bool {
        queue.sync { self.listener != nil }
    }

    func stop() {
        queue.async {
            self.teardownLocked()
            if let cont = self.continuation, !self.finished {
                self.continuation = nil
                cont.resume(throwing: PayoutWalletFlowError.cancelled)
            }
            self.finished = true
        }
    }

    /// Awaits the first VALID callback (FIX-6) OR the timeout (FIX-4) OR
    /// Swift task cancellation (MED). Single-resolution is guaranteed because
    /// every resolution path — valid callback, timeout, cancel/stop() —
    /// funnels through the serial `queue`, guarded by `finished`.
    func awaitCallback(timeout: TimeInterval) async throws -> PayoutSignedPayload {
        // MED: honor task cancellation. If the enclosing Task is cancelled
        // (user backs out of Add Wallet / view dismissed), stop() tears the
        // listener + connections + timeout down IMMEDIATELY and resumes the
        // continuation with .cancelled exactly once (finished-guarded), rather
        // than lingering until the ~5-min timeout. If a valid callback already
        // won, stop()'s resume is a no-op; if cancel already fired, the
        // `finished` checks below (and complete()'s guard) prevent a
        // double-resume.
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<PayoutSignedPayload, Error>) in
                queue.async {
                    // A valid callback that arrived BEFORE awaitCallback
                    // registered is delivered here (no lost one-shot).
                    if let pending = self.pendingResult {
                        self.pendingResult = nil
                        cont.resume(with: pending)
                        return
                    }
                    // Already resolved — including a cancel/stop() that beat
                    // us to the queue. Do NOT schedule a timeout in that case.
                    if self.finished {
                        cont.resume(throwing: PayoutWalletFlowError.cancelled)
                        return
                    }
                    self.continuation = cont
                    let work = DispatchWorkItem { [weak self] in
                        self?.complete(with: .failure(PayoutWalletFlowError.timedOut))
                    }
                    self.timeoutWork = work
                    self.queue.asyncAfter(deadline: .now() + timeout, execute: work)
                }
            }
        } onCancel: {
            // Runs promptly on cancellation (possibly off `queue`); stop()
            // hops onto `queue` for the actual teardown + single resume.
            self.stop()
        }
    }

    /// H1: routes a post-ready fatal listener failure into the single-
    /// resolution path so a waiting `awaitCallback` is resumed with an
    /// error (never left hanging) and everything is torn down. Runs on
    /// `queue`; idempotent via `complete()`'s `finished` guard.
    private func failListenerPostReady(_ error: PayoutWalletFlowError) {
        complete(with: .failure(error))
    }

    /// Test-only: injects a post-ready listener failure through the exact
    /// same routing the NWListener `.failed` handler uses (H1 coverage).
    func injectPostReadyListenerFailureForTest() {
        queue.async {
            self.failListenerPostReady(.loopbackFailed("post-ready listener failure (test)"))
        }
    }

    // MARK: private (all mutate on `queue`)

    private func complete(with result: Result<PayoutSignedPayload, Error>) {
        guard !finished else { return }
        finished = true
        let cont = continuation
        continuation = nil
        teardownLocked()
        if let cont {
            cont.resume(with: result)
        } else {
            // Callback resolved before awaitCallback registered; hand
            // it to the next awaitCallback caller.
            pendingResult = result
        }
    }

    /// Cancels the timeout, listener, and all live connections. Idempotent.
    private func teardownLocked() {
        timeoutWork?.cancel()
        timeoutWork = nil
        listener?.cancel()
        listener = nil
        for (id, work) in connectionTimeouts {
            work.cancel()
            connectionTimeouts[id] = nil
        }
        for (_, c) in connections { c.cancel() }
        connections.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        // FIX-7: reject once resolved or over the concurrent-connection cap.
        if finished || connections.count >= Self.maxConnections {
            connection.cancel()
            return
        }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        // Per-connection idle/total timeout so a slow-loris / half-open
        // connection cannot pin the one-shot listener open. FIX-7.
        let idle = DispatchWorkItem { [weak self, weak connection] in
            connection?.cancel()
            self?.removeConnection(id)
        }
        connectionTimeouts[id] = idle
        queue.asyncAfter(deadline: .now() + Self.connectionIdleTimeout, execute: idle)

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receive(on: connection, buffer: Data())
            case .failed, .cancelled:
                self.removeConnection(id)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func removeConnection(_ id: ObjectIdentifier) {
        connectionTimeouts[id]?.cancel()
        connectionTimeouts[id] = nil
        if let c = connections[id] {
            connections[id] = nil
            c.cancel()
        }
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        let id = ObjectIdentifier(connection)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil {
                self.removeConnection(id)
                return
            }
            var buf = buffer
            if let data { buf.append(data) }
            // FIX-7: reject oversized requests instead of buffering unbounded.
            if buf.count > Self.maxRequestBytes {
                self.send(
                    self.httpResponse(status: 413, body: #"{"error":"too_large"}"#, contentType: "application/json"),
                    on: connection,
                    then: nil
                )
                return
            }
            if let outcome = self.tryHandleHTTP(buf) {
                switch outcome {
                case let .respond(responseData):
                    self.send(responseData, on: connection, then: nil)
                case let .capture(responseData, payload):
                    // Flush the 200 to the browser FIRST, then resolve.
                    self.send(responseData, on: connection, then: {
                        self.complete(with: .success(payload))
                    })
                }
                return
            }
            if isComplete {
                self.removeConnection(id)
                return
            }
            self.receive(on: connection, buffer: buf)
        }
    }

    private enum RequestOutcome {
        case respond(Data)                       // send + keep listening
        case capture(Data, PayoutSignedPayload)  // send + resolve one-shot
    }

    private func tryHandleHTTP(_ data: Data) -> RequestOutcome? {
        guard let raw = String(data: data, encoding: .utf8),
              let headerEnd = raw.range(of: "\r\n\r\n")
        else {
            return nil
        }
        let headerPart = String(raw[..<headerEnd.lowerBound])
        let bodyPart = String(raw[headerEnd.upperBound...])
        let lines = headerPart.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            return .respond(httpResponse(status: 400, body: "bad request", contentType: "text/plain"))
        }
        let method = String(parts[0])
        let pathWithQuery = String(parts[1])
        let path = pathWithQuery.split(separator: "?").first.map(String.init) ?? pathWithQuery

        // Content-Length for body completeness.
        var contentLength = 0
        for line in lines.dropFirst() {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let v = line.split(separator: ":", maxSplits: 1).last?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
                contentLength = Int(v) ?? 0
            }
        }
        // FIX-7: reject an oversized declared body outright.
        if contentLength > Self.maxContentLength {
            return .respond(httpResponse(status: 413, body: #"{"error":"too_large"}"#, contentType: "application/json"))
        }
        if method == "POST", bodyPart.utf8.count < contentLength {
            return nil // wait for more body
        }

        if method == "GET" {
            return .respond(serveStatic(path: path))
        }
        // FIX-6: exact path + method for the one-shot callback.
        if method == "POST", path == "/cb" {
            return handleCallback(body: bodyPart, contentLength: contentLength)
        }
        return .respond(httpResponse(status: 404, body: "not found", contentType: "text/plain"))
    }

    private func serveStatic(path: String) -> Data {
        let relative: String
        if path == "/" || path.isEmpty {
            relative = "signer.html"
        } else if path.hasPrefix("/") {
            relative = String(path.dropFirst())
        } else {
            relative = path
        }
        let allowed = Set(["signer.html", "ethers.min.js"])
        // Reject traversal / nested paths: only the two bare whitelisted
        // filenames are served.
        if relative.contains("..") || relative.contains("/") {
            return httpResponse(status: 404, body: "not found", contentType: "text/plain")
        }
        guard allowed.contains(relative) else {
            return httpResponse(status: 404, body: "not found", contentType: "text/plain")
        }
        let fileURL = resourceDirectory.appendingPathComponent(relative)
        guard let data = try? Data(contentsOf: fileURL) else {
            return httpResponse(status: 404, body: "missing", contentType: "text/plain")
        }
        let type = relative.hasSuffix(".js") ? "application/javascript" : "text/html; charset=utf-8"
        return httpResponse(status: 200, bodyData: data, contentType: type)
    }

    private var corsHeaders: [String] {
        [
            "Access-Control-Allow-Origin: *",
            "Access-Control-Allow-Methods: POST, GET, OPTIONS",
            "Access-Control-Allow-Headers: Content-Type",
        ]
    }

    /// Parses + fully validates a `/cb` POST. Returns `.capture` ONLY on
    /// a fully-valid callback (FIX-6); every malformed / negative-ts /
    /// fractional / out-of-range-ts (M1) / wrong-state / wrong-shape
    /// callback returns `.respond` with a 4xx so the server KEEPS
    /// listening for a valid one.
    private func handleCallback(body: String, contentLength: Int) -> RequestOutcome {
        let payloadData: Data
        if contentLength > 0, body.utf8.count >= contentLength {
            payloadData = Data(body.utf8.prefix(contentLength))
        } else {
            payloadData = Data(body.utf8)
        }
        // M1: structural decode. JSONDecoder's exact UInt64 decoding rejects
        // negative, fractional, non-numeric, and out-of-range ts_utc
        // (including 2^64) — no NSNumber round-trip, so no boundary bugs.
        guard let decoded = try? JSONDecoder().decode(PayoutCallbackBody.self, from: payloadData) else {
            return .respond(httpResponse(
                status: 400, body: #"{"error":"bad_callback"}"#,
                contentType: "application/json", extraHeaders: corsHeaders
            ))
        }
        let signed = PayoutSignedPayload(
            address: decoded.address,
            nonce: decoded.nonce,
            tsUtc: decoded.tsUtc,
            signature: decoded.signature,
            state: decoded.state
        )
        guard let exp = expectation,
              PayoutWalletFlow.validateCallback(
                  payload: signed,
                  expectedState: exp.state,
                  expectedNonce: exp.nonce,
                  expectedTsUtc: exp.tsUtc
              )
        else {
            // Invalid/early/wrong-state → reject, keep listening (FIX-6).
            return .respond(httpResponse(
                status: 400, body: #"{"error":"invalid_callback"}"#,
                contentType: "application/json", extraHeaders: corsHeaders
            ))
        }
        // M1: claim the one-shot NOW (still on the serial queue, before the
        // response is flushed). A second validated callback finds it already
        // claimed and is refused 409 — it never produces a `.capture` and so
        // never calls `complete()`, defeating the first-valid-wins swap race.
        if claimed || finished {
            return .respond(httpResponse(
                status: 409, body: #"{"error":"already_claimed"}"#,
                contentType: "application/json", extraHeaders: corsHeaders
            ))
        }
        claimed = true
        return .capture(
            httpResponse(
                status: 200, body: #"{"ok":true}"#,
                contentType: "application/json", extraHeaders: corsHeaders
            ),
            signed
        )
    }

    private func send(_ data: Data, on connection: NWConnection, then: (() -> Void)?) {
        let id = ObjectIdentifier(connection)
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            // Runs on `queue` (connection started with queue).
            self.removeConnection(id)
            then?()
        })
    }

    private func httpResponse(
        status: Int,
        body: String,
        contentType: String,
        extraHeaders: [String] = []
    ) -> Data {
        httpResponse(status: status, bodyData: Data(body.utf8), contentType: contentType, extraHeaders: extraHeaders)
    }

    private func httpResponse(
        status: Int,
        bodyData: Data,
        contentType: String,
        extraHeaders: [String] = []
    ) -> Data {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        case 413: reason = "Payload Too Large"
        default: reason = "Error"
        }
        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(bodyData.count)\r\n"
        header += "Connection: close\r\n"
        for h in extraHeaders {
            header += h + "\r\n"
        }
        header += "\r\n"
        var data = Data(header.utf8)
        data.append(bodyData)
        return data
    }
}
