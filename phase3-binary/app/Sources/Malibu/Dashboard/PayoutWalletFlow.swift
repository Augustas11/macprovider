import AppKit
import CryptoKit
import Foundation
import Network

// Non-custodial "Add wallet" flow (SPEC-016 §3):
// 1. CLI `payout-address challenge` (provider token never leaves CLI Keychain)
// 2. Ephemeral 127.0.0.1 loopback + bundled signer.html in the default browser
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

enum PayoutWalletFlow {
    static let callbackTimeout: TimeInterval = 5 * 60
    static let chain = "base-mainnet"

    static func randomNonceHex() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // Fallback: CryptoKit hash of UUID entropy (still 32 random-looking bytes).
            let digest = SHA256.hash(data: Data(UUID().uuidString.utf8))
            bytes = Array(digest)
        }
        return "0x" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func randomState() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
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

    static func validateCallback(
        payload: PayoutSignedPayload,
        expectedState: String,
        expectedNonce: String,
        expectedTsUtc: UInt64
    ) -> Bool {
        guard payload.state == expectedState else { return false }
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
        guard let obj = try JSONSerialization.jsonObject(with: stdout) as? [String: Any],
              let verifying = obj["verifying_contract"] as? String,
              let chainID = jsonUInt64(obj["chain_id"]),
              let domainName = obj["domain_name"] as? String,
              let domainVersion = obj["domain_version"] as? String,
              let chain = obj["chain"] as? String,
              let serverTs = jsonInt64(obj["server_ts_utc"]),
              let providerID = (obj["provider_id"] as? String) ?? ProviderConfig.readProviderID()
        else {
            throw PayoutWalletFlowError.challengeFailed("Unexpected challenge response.")
        }
        return PayoutChallengeView(
            providerID: providerID,
            verifyingContract: verifying,
            chainID: chainID,
            domainName: domainName,
            domainVersion: domainVersion,
            chain: chain,
            serverTsUTC: serverTs,
            registeredAddress: obj["registered_address"] as? String,
            pendingUntilUTC: obj["pending_until_utc"] as? String,
            payoutAllowed: obj["payout_allowed"] as? Bool
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

    private static func jsonUInt64(_ value: Any?) -> UInt64? {
        switch value {
        case let n as UInt64: return n
        case let n as Int: return UInt64(n)
        case let n as Int64: return UInt64(n)
        case let n as Double: return UInt64(n)
        case let n as NSNumber: return n.uint64Value
        default: return nil
        }
    }

    private static func jsonInt64(_ value: Any?) -> Int64? {
        switch value {
        case let n as Int64: return n
        case let n as Int: return Int64(n)
        case let n as Double: return Int64(n)
        case let n as NSNumber: return n.int64Value
        default: return nil
        }
    }

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
        try await server.start()
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

// MARK: - Loopback HTTP server (127.0.0.1 only)

final class LoopbackCaptureServer: @unchecked Sendable {
    private let resourceDirectory: URL
    private let queue = DispatchQueue(label: "tech.malibu.payout-loopback")
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var continuation: CheckedContinuation<PayoutSignedPayload, Error>?
    private var finished = false
    private(set) var port: UInt16 = 0

    init(resourceDirectory: URL) {
        self.resourceDirectory = resourceDirectory
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                var resumed = false
                func resumeOnce(_ result: Result<Void, Error>) {
                    guard !resumed else { return }
                    resumed = true
                    cont.resume(with: result)
                }
                do {
                    let params = NWParameters.tcp
                    params.allowLocalEndpointReuse = true
                    // NWListener binds the wildcard by default; we only advertise
                    // and open 127.0.0.1 URLs, and serve only the one-shot capture.
                    let listener = try NWListener(using: params, on: 0)
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
                            resumeOnce(.failure(PayoutWalletFlowError.loopbackFailed(String(describing: error))))
                        default:
                            break
                        }
                    }
                    listener.newConnectionHandler = { [weak self] connection in
                        self?.accept(connection)
                    }
                    listener.start(queue: self.queue)
                } catch {
                    resumeOnce(.failure(PayoutWalletFlowError.loopbackFailed(String(describing: error))))
                }
            }
        }
        if port == 0 {
            throw PayoutWalletFlowError.loopbackFailed("Listener did not publish a port.")
        }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            for c in self.connections { c.cancel() }
            self.connections.removeAll()
            if let cont = self.continuation, !self.finished {
                self.finished = true
                self.continuation = nil
                cont.resume(throwing: PayoutWalletFlowError.cancelled)
            }
        }
    }

    func awaitCallback(timeout: TimeInterval) async throws -> PayoutSignedPayload {
        try await withThrowingTaskGroup(of: PayoutSignedPayload.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<PayoutSignedPayload, Error>) in
                    self.queue.async {
                        if self.finished {
                            cont.resume(throwing: PayoutWalletFlowError.cancelled)
                            return
                        }
                        self.continuation = cont
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw PayoutWalletFlowError.timedOut
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state {
                self.receive(on: connection, buffer: Data())
            }
            if case .failed = state {
                connection.cancel()
            }
            if case .cancelled = state {
                connection.cancel()
            }
        }
        connection.start(queue: queue)
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                connection.cancel()
                _ = error
                return
            }
            var buf = buffer
            if let data { buf.append(data) }
            if let response = self.tryHandleHTTP(buf, connection: connection) {
                self.send(response, on: connection)
                return
            }
            if isComplete {
                connection.cancel()
                return
            }
            if buf.count > 256 * 1024 {
                connection.cancel()
                return
            }
            self.receive(on: connection, buffer: buf)
        }
    }

    private func tryHandleHTTP(_ data: Data, connection: NWConnection) -> Data? {
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
        guard parts.count >= 2 else { return nil }
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
        if method == "POST", bodyPart.utf8.count < contentLength {
            return nil // wait for more body
        }

        if method == "GET" {
            return serveStatic(path: path)
        }
        if method == "POST", path == "/cb" || path.hasPrefix("/cb") {
            return handleCallback(body: bodyPart, contentLength: contentLength)
        }
        return httpResponse(status: 404, body: "not found", contentType: "text/plain")
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
        // Path traversal guard.
        if relative.contains("..") || relative.contains("/") && !["signer.html", "ethers.min.js"].contains(relative) {
            if relative != "signer.html" && relative != "ethers.min.js" {
                return httpResponse(status: 404, body: "not found", contentType: "text/plain")
            }
        }
        let allowed = Set(["signer.html", "ethers.min.js"])
        let fileName = (relative as NSString).lastPathComponent
        guard allowed.contains(fileName) else {
            return httpResponse(status: 404, body: "not found", contentType: "text/plain")
        }
        let fileURL = resourceDirectory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: fileURL) else {
            return httpResponse(status: 404, body: "missing", contentType: "text/plain")
        }
        let type = fileName.hasSuffix(".js") ? "application/javascript" : "text/html; charset=utf-8"
        return httpResponse(status: 200, bodyData: data, contentType: type)
    }

    private func handleCallback(body: String, contentLength: Int) -> Data {
        let payloadData: Data
        if contentLength > 0, body.utf8.count >= contentLength {
            payloadData = Data(body.utf8.prefix(contentLength))
        } else {
            payloadData = Data(body.utf8)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let address = obj["address"] as? String,
              let nonce = obj["nonce"] as? String,
              let signature = obj["signature"] as? String,
              let state = obj["state"] as? String
        else {
            return httpResponse(status: 400, body: #"{"error":"bad_json"}"#, contentType: "application/json")
        }
        let ts: UInt64
        if let n = obj["ts_utc"] as? UInt64 {
            ts = n
        } else if let n = obj["ts_utc"] as? Int {
            ts = UInt64(n)
        } else if let n = obj["ts_utc"] as? Double {
            ts = UInt64(n)
        } else if let n = obj["ts_utc"] as? NSNumber {
            ts = n.uint64Value
        } else {
            return httpResponse(status: 400, body: #"{"error":"missing_ts"}"#, contentType: "application/json")
        }
        let signed = PayoutSignedPayload(
            address: address,
            nonce: nonce,
            tsUtc: ts,
            signature: signature,
            state: state
        )
        complete(with: .success(signed))
        // CORS so browser page on same origin always works; allow simple POST.
        return httpResponse(
            status: 200,
            body: #"{"ok":true}"#,
            contentType: "application/json",
            extraHeaders: [
                "Access-Control-Allow-Origin: *",
                "Access-Control-Allow-Methods: POST, GET, OPTIONS",
                "Access-Control-Allow-Headers: Content-Type",
            ]
        )
    }

    private func complete(with result: Result<PayoutSignedPayload, Error>) {
        guard let cont = continuation, !finished else { return }
        finished = true
        continuation = nil
        cont.resume(with: result)
    }

    private func send(_ data: Data, on connection: NWConnection) {
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
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
