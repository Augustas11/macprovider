import Foundation

/// Bridges the App-track SPEC-026 identity-signature challenge between the
/// coordinator WS client (`CoordinatorClient`) and the ControlSocket handler.
///
/// **The problem**: SPEC-026 keeps the provider's Ed25519 private key in
/// Malibu.app's Keychain, not in the CLI. When the coordinator sends a
/// Tier-2 `auth_challenge`, the CLI's proof stage must include
/// `identity_signature` + `identity_signature_transcript_sha256`. Those can
/// only be computed by Malibu.app.
///
/// **The flow**:
/// 1. `CoordinatorClient` receives `auth_challenge`, prepares the proof body,
///    calls `requestSignature(_:timeout:)` on this bridge.
/// 2. Bridge stores the request + suspends the caller on a continuation, then
///    yields the request into a stream consumed by the ControlSocket handler.
/// 3. `ControlSocket.handleClient` writes an `identitySignatureRequest`
///    frame onto the connected Malibu.app control socket.
/// 4. Malibu.app signs with its Keychain key, replies with
///    `identitySignatureResponse`.
/// 5. `handleClient` calls `deliverResponse` on this bridge.
/// 6. Bridge resumes the suspended `requestSignature` call with the response.
///
/// **Timeout / no-client case**: if no ControlSocket client is connected
/// (i.e. CLI running standalone via install.sh), `requestSignature` returns
/// `nil` after the timeout. `CoordinatorClient` then omits the signature
/// fields from the proof; the coordinator's per-provider
/// `provider_auth_policy` exemption (see
/// `phase4-coordinator/internal/ws/identity_signature.go:38`) covers the
/// CLI-track path.
public actor IdentitySignatureBridge {
    public struct Request: Sendable, Equatable {
        public let authAttemptID: String
        public let providerID: String
        /// String, NOT integer — must byte-match the value the CLI sent in
        /// the initial auth_request `binary_version` field (`"1.8.6"`), so
        /// the coordinator's canonical tuple and Malibu.app's signed tuple
        /// carry the same JSON string type.
        public let binaryVersion: String
        public let providerECDHPublicKey: String
        public let transcriptSHA256: String

        public init(
            authAttemptID: String,
            providerID: String,
            binaryVersion: String,
            providerECDHPublicKey: String,
            transcriptSHA256: String
        ) {
            self.authAttemptID = authAttemptID
            self.providerID = providerID
            self.binaryVersion = binaryVersion
            self.providerECDHPublicKey = providerECDHPublicKey
            self.transcriptSHA256 = transcriptSHA256
        }
    }

    public struct Response: Sendable, Equatable {
        public let accepted: Bool
        public let identitySignature: String?
        public let transcriptSHA256: String?
        public let reason: String?

        public init(
            accepted: Bool,
            identitySignature: String?,
            transcriptSHA256: String?,
            reason: String?
        ) {
            self.accepted = accepted
            self.identitySignature = identitySignature
            self.transcriptSHA256 = transcriptSHA256
            self.reason = reason
        }
    }

    private struct Pending {
        let request: Request
        let continuation: CheckedContinuation<Response?, Never>
    }

    private var pending: Pending?
    private var listeners: [UUID: AsyncStream<Request>.Continuation] = [:]

    public init() {}

    /// Called by `CoordinatorClient` from the proof-stage builder. Suspends
    /// until the matching `identity_signature_response` frame comes back
    /// from a ControlSocket client, or `timeout` elapses.
    ///
    /// Returns `nil` on timeout / when no ControlSocket subscriber is
    /// connected — the caller should proceed WITHOUT the signature and let
    /// the coordinator's per-provider exemption handle it.
    public func requestSignature(_ request: Request, timeout: TimeInterval) async -> Response? {
        FileHandle.standardError.write(Data("[idsig] bridge: requestSignature listeners=\(listeners.count)\n".utf8))
        if let existing = pending {
            existing.continuation.resume(returning: nil)
            pending = nil
        }
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            await self?.timeoutIfPending()
        }
        defer { timeoutTask.cancel() }
        let response = await withCheckedContinuation { (cont: CheckedContinuation<Response?, Never>) in
            pending = Pending(request: request, continuation: cont)
            for continuation in listeners.values {
                continuation.yield(request)
            }
        }
        FileHandle.standardError.write(Data("[idsig] bridge: requestSignature returned response=\(response == nil ? "nil" : "value") accepted=\(response?.accepted.description ?? "nil")\n".utf8))
        return response
    }

    /// Called by `ControlSocket.handleClient` after receiving an
    /// `identitySignatureResponse` frame from Malibu.app.
    public func deliverResponse(_ response: Response) {
        FileHandle.standardError.write(Data("[idsig] bridge: deliverResponse accepted=\(response.accepted) hasSig=\(response.identitySignature != nil) pending=\(pending != nil)\n".utf8))
        guard let existing = pending else { return }
        pending = nil
        existing.continuation.resume(returning: response)
    }

    /// Called by `ControlSocket.handleClient` when it wants to receive
    /// pending signature requests. Each subscribed connection gets its own
    /// stream; the same request is yielded to all connected subscribers
    /// (only one Malibu.app instance is expected at a time in practice).
    public func subscribe() -> (id: UUID, stream: AsyncStream<Request>) {
        let id = UUID()
        let stream = AsyncStream<Request> { continuation in
            listeners[id] = continuation
            FileHandle.standardError.write(Data("[idsig] bridge: subscribe id=\(id.uuidString) total_listeners=\(listeners.count) hasPending=\(pending != nil)\n".utf8))
            if let pending {
                continuation.yield(pending.request)
            }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.unsubscribe(id) }
            }
        }
        return (id, stream)
    }

    public func unsubscribe(_ id: UUID) {
        listeners.removeValue(forKey: id)?.finish()
    }

    private func timeoutIfPending() {
        guard let existing = pending else { return }
        pending = nil
        existing.continuation.resume(returning: nil)
    }
}
