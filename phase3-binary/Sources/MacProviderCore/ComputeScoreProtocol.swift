import Foundation

/// SPEC-036 FR-21 teacher-forced scoring job wire format.
///
/// The coordinator asks a scorer provider for the log-probabilities of another
/// provider's output under the same catalog model. Parsing is strict: the field
/// set is closed and every bound is checked before any model work runs.
public enum ComputeScoreProtocol {
    public static let requestType = "compute_score_request_v1"
    public static let resultType = "compute_score_result_v1"
    public static let capability = "compute_score_v1"
    public static let version = 1

    public static let maxBodyBytes = 64 * 1024
    public static let maxOutputBytes = 32 * 1024
    public static let maxPromptTokens = 4096
    public static let maxScoredTokens = 512
    static let maxIdentifierBytes = 256
    /// Per-token log-probabilities are clamped to [-logprobFloor, 0].
    public static let logprobFloor = 100.0

    static let requestFields: Set<String> = [
        "type", "version", "score_id", "provider_id", "assigned_id", "model_id",
        "weights_manifest_sha256", "body", "output_text", "reasoning_text",
        "issued_at", "expires_at",
    ]

    public enum Status: String, Sendable {
        case ok
        case unavailable
        case invalid
        case tooLong = "too_long"
    }

    public struct Request: Sendable, Equatable {
        public let scoreID: String
        public let providerID: String
        public let assignedID: String
        public let modelID: String
        public let weightsManifestSHA256: String
        public let body: String
        public let outputText: String
        public let reasoningText: String
        public let issuedAt: Date
        public let expiresAt: Date

        /// The scored continuation. Reasoning is wrapped in the think delimiters
        /// the chat templates of reasoning models emit (SPEC-036 FR-21).
        public var scoredText: String {
            reasoningText.isEmpty ? outputText : "<think>\n" + reasoningText + "\n</think>\n\n" + outputText
        }
    }

    public struct Result: Sendable, Equatable {
        public let scoreID: String
        public let providerID: String
        public let assignedID: String
        public let modelID: String
        public let weightsManifestSHA256: String
        public let status: Status
        public let promptTokens: Int
        public let scoredTokens: Int
        public let top1Matches: Int
        public let sumLogprob: Double

        public init(
            request: Request,
            status: Status,
            promptTokens: Int = 0,
            scoredTokens: Int = 0,
            top1Matches: Int = 0,
            sumLogprob: Double = 0
        ) {
            self.scoreID = request.scoreID
            self.providerID = request.providerID
            self.assignedID = request.assignedID
            self.modelID = request.modelID
            self.weightsManifestSHA256 = request.weightsManifestSHA256
            self.status = status
            let ok = status == .ok
            self.promptTokens = ok ? max(0, promptTokens) : 0
            self.scoredTokens = ok ? max(0, scoredTokens) : 0
            self.top1Matches = ok ? min(max(0, top1Matches), max(0, scoredTokens)) : 0
            // A non-finite sum means an impossible token: score it at the floor,
            // never as a perfect 0.
            let floorSum = -ComputeScoreProtocol.logprobFloor * Double(self.scoredTokens)
            self.sumLogprob = ok ? (sumLogprob.isFinite ? max(floorSum, min(0, sumLogprob)) : floorSum) : 0
        }

        public var wireObject: [String: Any] {
            [
                "type": ComputeScoreProtocol.resultType,
                "version": ComputeScoreProtocol.version,
                "score_id": scoreID,
                "provider_id": providerID,
                "assigned_id": assignedID,
                "model_id": modelID,
                "weights_manifest_sha256": weightsManifestSHA256,
                "status": status.rawValue,
                "prompt_tokens": promptTokens,
                "scored_tokens": scoredTokens,
                "top1_matches": top1Matches,
                "sum_logprob": sumLogprob,
            ]
        }
    }

    public enum DecodeError: Error, Equatable {
        case invalid(String)
        case tooLong(String)
    }

    /// Decodes a request. `tooLong` is returned for an otherwise valid request
    /// whose body or output exceeds the FR-21 byte bounds, so the scorer can
    /// answer `too_long` instead of `invalid`.
    public static func decodeRequest(_ raw: [String: Any]) throws -> Request {
        for key in raw.keys where !requestFields.contains(key) {
            throw DecodeError.invalid("unknown field")
        }
        guard raw["type"] as? String == requestType else { throw DecodeError.invalid("type") }
        guard let version = raw["version"] as? Int, version == ComputeScoreProtocol.version else {
            throw DecodeError.invalid("version")
        }
        let scoreID = try identifier(raw, "score_id")
        let providerID = try identifier(raw, "provider_id")
        let assignedID = try identifier(raw, "assigned_id")
        let modelID = try identifier(raw, "model_id")
        guard let manifest = raw["weights_manifest_sha256"] as? String, isLowerHex64(manifest) else {
            throw DecodeError.invalid("weights_manifest_sha256")
        }
        guard let body = raw["body"] as? String, !body.isEmpty else { throw DecodeError.invalid("body") }
        guard let output = raw["output_text"] as? String else { throw DecodeError.invalid("output_text") }
        let reasoning: String
        switch raw["reasoning_text"] {
        case nil, is NSNull: reasoning = ""
        case let value as String: reasoning = value
        default: throw DecodeError.invalid("reasoning_text")
        }
        guard let issuedAt = timestamp(raw["issued_at"]) else { throw DecodeError.invalid("issued_at") }
        guard let expiresAt = timestamp(raw["expires_at"]), expiresAt > issuedAt else {
            throw DecodeError.invalid("expires_at")
        }
        let request = Request(
            scoreID: scoreID,
            providerID: providerID,
            assignedID: assignedID,
            modelID: modelID,
            weightsManifestSHA256: manifest,
            body: body,
            outputText: output,
            reasoningText: reasoning,
            issuedAt: issuedAt,
            expiresAt: expiresAt
        )
        if body.utf8.count > maxBodyBytes { throw DecodeError.tooLong("body") }
        if output.utf8.count + reasoning.utf8.count > maxOutputBytes { throw DecodeError.tooLong("output") }
        if request.scoredText.isEmpty { throw DecodeError.invalid("output_text") }
        return request
    }

    /// Best-effort echo identity for a NAK-free `invalid` or `too_long` answer:
    /// the coordinator matches results on these fields, so they are copied only
    /// when each is a bounded string.
    public static func echoRequest(_ raw: [String: Any]) -> Request? {
        guard let scoreID = try? identifier(raw, "score_id"),
              let providerID = try? identifier(raw, "provider_id"),
              let assignedID = try? identifier(raw, "assigned_id"),
              let modelID = try? identifier(raw, "model_id"),
              let manifest = raw["weights_manifest_sha256"] as? String, isLowerHex64(manifest)
        else {
            return nil
        }
        return Request(
            scoreID: scoreID,
            providerID: providerID,
            assignedID: assignedID,
            modelID: modelID,
            weightsManifestSHA256: manifest,
            body: "",
            outputText: "",
            reasoningText: "",
            issuedAt: Date(timeIntervalSince1970: 0),
            expiresAt: Date(timeIntervalSince1970: 0)
        )
    }

    /// Aggregates per-position scores. `logprobs[i]` is the log-probability of
    /// output token i and `top1[i]` whether it was the arg-max token.
    public static func aggregate(logprobs: [Double], top1: [Bool]) -> (scored: Int, matches: Int, sum: Double) {
        let count = min(logprobs.count, top1.count)
        var sum = 0.0
        var matches = 0
        for i in 0..<count {
            let value = logprobs[i]
            sum += value.isFinite ? max(-logprobFloor, min(0, value)) : -logprobFloor
            if top1[i] { matches += 1 }
        }
        return (count, matches, sum)
    }

    static func identifier(_ raw: [String: Any], _ key: String) throws -> String {
        guard let value = raw[key] as? String,
              !value.isEmpty,
              value.utf8.count <= maxIdentifierBytes,
              value.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7e })
        else {
            throw DecodeError.invalid(key)
        }
        return value
    }

    static func isLowerHex64(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    static func timestamp(_ raw: Any?) -> Date? {
        guard let text = raw as? String, text.utf8.count <= 64 else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}
