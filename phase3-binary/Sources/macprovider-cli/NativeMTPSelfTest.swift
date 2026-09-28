import CryptoKit
import Foundation

enum NativeMTPSelfTestError: Error, Equatable, CustomStringConvertible {
    case runnerUnavailable
    case failed(String)
    case tupleMismatch
    case challengeBankMismatch
    case invalidJSON
    case unknownField(String)
    case missingOrInvalidField(String)
    case invalidSignature

    var description: String {
        switch self {
        case .runnerUnavailable:
            return "native_mtp_selftest_v1 runner unavailable"
        case .failed(let reason):
            return "native_mtp_selftest_v1 failed: \(reason)"
        case .tupleMismatch:
            return "native_mtp_selftest_v1 tuple mismatch"
        case .challengeBankMismatch:
            return "native_mtp_selftest_v1 challenge bank mismatch"
        case .invalidJSON:
            return "native_mtp_selftest_v1 invalid JSON"
        case .unknownField(let field):
            return "native_mtp_selftest_v1 unknown field: \(field)"
        case .missingOrInvalidField(let field):
            return "native_mtp_selftest_v1 missing or invalid field: \(field)"
        case .invalidSignature:
            return "native_mtp_selftest_v1 invalid signature"
        }
    }
}

struct NativeMTPSelfTestInput: Sendable, Equatable {
    let tupleSHA256: String
    let modelID: String
    let modelRevision: String
    let familyAdapter: String
    let proposalDepth: Int
    let challengeBank: NativeMTPSelfTestChallengeBank
    let selectedChallenge: NativeMTPSelfTestChallenge?
    let servedSnapshot: NativeMTPSelfTestServedSnapshot?

    init(
        tupleSHA256: String,
        modelID: String,
        modelRevision: String,
        familyAdapter: String,
        proposalDepth: Int,
        challengeBank: NativeMTPSelfTestChallengeBank,
        selectedChallenge: NativeMTPSelfTestChallenge? = nil,
        servedSnapshot: NativeMTPSelfTestServedSnapshot? = nil
    ) {
        self.tupleSHA256 = tupleSHA256
        self.modelID = modelID
        self.modelRevision = modelRevision
        self.familyAdapter = familyAdapter
        self.proposalDepth = proposalDepth
        self.challengeBank = challengeBank
        self.selectedChallenge = selectedChallenge
        self.servedSnapshot = servedSnapshot
    }
}

struct NativeMTPSelfTestServedSnapshot: Sendable, Equatable {
    let tupleSHA256: String
    let runtimeTuple: NativeMTPSelfTestRuntimeTuple
    let generation: UInt64
    let proposalDepth: Int
}

struct NativeMTPSelfTestReceipt: Sendable, Equatable {
    let version: String
    let tupleSHA256: String
    let challengeID: String
    let challengeBankSHA256: String
    let servedSnapshotGeneration: UInt64
    let proposalDepth: Int
    let maxCompletionTokens: Int
    let promptTokenIDs: [Int]
    let generatedTokenIDs: [Int]
    let terminalReason: ContinuousBatchSchedulerTerminalStatus
    let acceptedTokens: Int
    let rejectedTokens: Int
    let bonusTokens: Int
    let committedTokens: Int
    let committedStateDigestSHA256: String
    let actualDecodePath: NativeMTPSelfTestExecutionResult.DecodePath
    let fallbackUsed: Bool

    init(
        version: String,
        tupleSHA256: String,
        challengeID: String = "",
        challengeBankSHA256: String,
        servedSnapshotGeneration: UInt64 = 0,
        proposalDepth: Int = 0,
        maxCompletionTokens: Int = 0,
        promptTokenIDs: [Int],
        generatedTokenIDs: [Int],
        terminalReason: ContinuousBatchSchedulerTerminalStatus,
        acceptedTokens: Int,
        rejectedTokens: Int,
        bonusTokens: Int,
        committedTokens: Int,
        committedStateDigestSHA256: String,
        actualDecodePath: NativeMTPSelfTestExecutionResult.DecodePath = .unavailable,
        fallbackUsed: Bool = true
    ) {
        self.version = version
        self.tupleSHA256 = tupleSHA256
        self.challengeID = challengeID
        self.challengeBankSHA256 = challengeBankSHA256
        self.servedSnapshotGeneration = servedSnapshotGeneration
        self.proposalDepth = proposalDepth
        self.maxCompletionTokens = maxCompletionTokens
        self.promptTokenIDs = promptTokenIDs
        self.generatedTokenIDs = generatedTokenIDs
        self.terminalReason = terminalReason
        self.acceptedTokens = acceptedTokens
        self.rejectedTokens = rejectedTokens
        self.bonusTokens = bonusTokens
        self.committedTokens = committedTokens
        self.committedStateDigestSHA256 = committedStateDigestSHA256
        self.actualDecodePath = actualDecodePath
        self.fallbackUsed = fallbackUsed
    }
}

extension NativeMTPSelfTestReceipt {
    var passDigestSHA256: String {
        let canonical = [
            "version=\(version)",
            "tuple=\(tupleSHA256)",
            "challenge=\(challengeID)",
            "bank=\(challengeBankSHA256)",
            "generation=\(servedSnapshotGeneration)",
            "depth=\(proposalDepth)",
            "max_completion=\(maxCompletionTokens)",
            "prompt=\(promptTokenIDs.map(String.init).joined(separator: ","))",
            "generated=\(generatedTokenIDs.map(String.init).joined(separator: ","))",
            "terminal=\(terminalReason.rawValue)",
            "accepted=\(acceptedTokens)",
            "rejected=\(rejectedTokens)",
            "bonus=\(bonusTokens)",
            "committed=\(committedTokens)",
            "state=\(committedStateDigestSHA256)",
            "path=\(actualDecodePath.rawValue)",
            "fallback=\(fallbackUsed ? "true" : "false")",
        ].joined(separator: "\n")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

struct NativeMTPSelfTestRuntimeTuple: Sendable, Equatable {
    let modelID: String
    let modelHash: String
    let modelHashAlgorithm: String
    let tokenizerDigest: String
    let artifactDigest: String
    let manifestDigest: String
    let sidecarDigest: String
    let providerBinarySHA256: String
    let runtimeCDHash: String
    let cacheNamespace: String
    let stateDigest: String
    let proposalDepth: Int
}

struct NativeMTPSelfTestCounters: Sendable, Equatable {
    let acceptedTokens: UInt64
    let rejectedTokens: UInt64
    let bonusTokens: UInt64
    let committedTokens: UInt64
}

struct NativeMTPSelfTestChallenge: Sendable, Equatable {
    static let bankSchemaVersion = "macprovider.native-mtp-challenge-bank.v1"
    static let maxPromptTokens = 2048
    static let maxSerializedPromptBytes = 8 * 1024
    static let maxCompletionTokens = 64
    static let maxProposalDepth = 16
    static let maxEntries = 256

    let challengeID: String
    let modelID: String
    let modelHash: String
    let tokenizerSHA256: String
    let artifactSHA256: String
    let mtpManifestSHA256: String
    let promptTokenIDs: [Int]
    let maxCompletionTokens: Int
    let fixedProposalDepth: Int
    let expectedTokenIDs: [Int]
    let expectedTokenIDSHA256: String
    let expectedTerminalReason: String
    let expectedCounters: NativeMTPSelfTestCounters
    let expectedCommittedStateDigest: String
}

struct NativeMTPSelfTestChallengeBankEnvelope: Sendable, Equatable {
    let releaseID: String
    let issuedAt: Date
    let expiresAt: Date
    let signerKeyID: String
    let entries: [NativeMTPSelfTestChallenge]
}

struct NativeMTPSelfTestExecutionResult: Sendable, Equatable {
    enum DecodePath: String, Sendable, Equatable {
        case nativeMTP = "native_mtp"
        case ordinary
        case classicSpecDecode = "classic_spec_decode"
        case unavailable
    }

    let runtimeTuple: NativeMTPSelfTestRuntimeTuple
    let servedSnapshotGeneration: UInt64
    let proposalDepth: Int
    let outputTokenIDs: [Int]
    let terminalReason: String
    let counters: NativeMTPSelfTestCounters
    let committedStateDigest: String
    let actualDecodePath: DecodePath
    let fallbackUsed: Bool
}

struct NativeMTPSelfTestEvaluation: Sendable, Equatable {
    enum Reason: String, Sendable, Equatable {
        case passed
        case tupleMismatch
        case generationMismatch
        case proposalDepthMismatch
        case decodePathMismatch
        case fallbackUsed
        case outputDigestMismatch
        case terminalReasonMismatch
        case counterMismatch
        case committedStateMismatch
    }

    let passed: Bool
    let reason: Reason
}

enum NativeMTPSelfTest {
    static func parseChallengeBank(
        _ data: Data,
        now: Date = Date()
    ) throws -> NativeMTPSelfTestChallengeBankEnvelope {
        do {
            try AutotuneStrictJSON.rejectDuplicateKeys(data)
        } catch {
            throw NativeMTPSelfTestError.invalidJSON
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NativeMTPSelfTestError.invalidJSON
        }
        try rejectUnknownFields(object, allowed: [
            "schema_version", "release_id", "issued_at", "expires_at", "signer_key_id", "entries",
        ])
        guard try printableString(object, "schema_version", maxBytes: 128) == NativeMTPSelfTestChallenge.bankSchemaVersion else {
            throw NativeMTPSelfTestError.missingOrInvalidField("schema_version")
        }
        let releaseID = try printableString(object, "release_id", maxBytes: 128)
        let issuedAt = try utcSecondsDate(object, "issued_at")
        let expiresAt = try utcSecondsDate(object, "expires_at")
        guard issuedAt < expiresAt,
              now >= issuedAt,
              now < expiresAt
        else {
            throw NativeMTPSelfTestError.missingOrInvalidField("issued_at")
        }
        let signerKeyID = try printableString(object, "signer_key_id", maxBytes: 128)
        guard let entries = object["entries"] as? [[String: Any]],
              !entries.isEmpty,
              entries.count <= NativeMTPSelfTestChallenge.maxEntries
        else {
            throw NativeMTPSelfTestError.missingOrInvalidField("entries")
        }
        var parsed: [NativeMTPSelfTestChallenge] = []
        var seen = Set<String>()
        var lastID = ""
        for entry in entries {
            let challenge = try parseChallengeRecord(entry)
            guard seen.insert(challenge.challengeID).inserted,
                  lastID.isEmpty || challenge.challengeID > lastID
            else {
                throw NativeMTPSelfTestError.missingOrInvalidField("challenge_id")
            }
            lastID = challenge.challengeID
            parsed.append(challenge)
        }
        return NativeMTPSelfTestChallengeBankEnvelope(
            releaseID: releaseID,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            signerKeyID: signerKeyID,
            entries: parsed
        )
    }

    static func selectChallenge(
        _ bank: NativeMTPSelfTestChallengeBankEnvelope,
        challengeID: String
    ) throws -> NativeMTPSelfTestChallenge {
        guard let record = bank.entries.first(where: { $0.challengeID == challengeID }) else {
            throw NativeMTPSelfTestError.missingOrInvalidField("challenge_id")
        }
        return record
    }

    private static func parseChallengeRecord(_ object: [String: Any]) throws -> NativeMTPSelfTestChallenge {
        try rejectUnknownFields(object, allowed: [
            "challenge_id", "model_id", "model_hash", "tokenizer_sha256", "artifact_sha256",
            "mtp_manifest_sha256", "prompt_token_ids", "max_completion_tokens",
            "fixed_proposal_depth", "expected_token_ids", "expected_token_id_sha256",
            "expected_terminal_reason", "expected_counters", "expected_committed_state_sha256",
        ])
        guard let countersObject = object["expected_counters"] as? [String: Any] else {
            throw NativeMTPSelfTestError.missingOrInvalidField("expected_counters")
        }
        try rejectUnknownFields(countersObject, allowed: [
            "accepted", "rejected", "bonus", "committed",
        ])
        let promptTokenIDs = try tokenIDs(
            object,
            "prompt_token_ids",
            minCount: 1,
            maxCount: NativeMTPSelfTestChallenge.maxPromptTokens
        )
        guard serializedTokenArrayByteCount(promptTokenIDs) <= NativeMTPSelfTestChallenge.maxSerializedPromptBytes else {
            throw NativeMTPSelfTestError.missingOrInvalidField("prompt_token_ids")
        }
        let expectedTokenIDs = try tokenIDs(
            object,
            "expected_token_ids",
            minCount: 0,
            maxCount: NativeMTPSelfTestChallenge.maxCompletionTokens
        )
        let expectedTokenIDSHA256 = try sha256(object, "expected_token_id_sha256")
        guard tokenDigest(expectedTokenIDs) == expectedTokenIDSHA256 else {
            throw NativeMTPSelfTestError.missingOrInvalidField("expected_token_id_sha256")
        }
        let counters = NativeMTPSelfTestCounters(
            acceptedTokens: try uint64(countersObject, "accepted"),
            rejectedTokens: try uint64(countersObject, "rejected"),
            bonusTokens: try uint64(countersObject, "bonus"),
            committedTokens: try uint64(countersObject, "committed")
        )
        guard counters.committedTokens == UInt64(expectedTokenIDs.count) else {
            throw NativeMTPSelfTestError.missingOrInvalidField("expected_counters.committed")
        }
        return NativeMTPSelfTestChallenge(
            challengeID: try printableString(object, "challenge_id", maxBytes: 128),
            modelID: try printableString(object, "model_id", maxBytes: 256),
            modelHash: try sha256(object, "model_hash"),
            tokenizerSHA256: try sha256(object, "tokenizer_sha256"),
            artifactSHA256: try sha256(object, "artifact_sha256"),
            mtpManifestSHA256: try sha256(object, "mtp_manifest_sha256"),
            promptTokenIDs: promptTokenIDs,
            maxCompletionTokens: try int(object, "max_completion_tokens", min: 1, max: NativeMTPSelfTestChallenge.maxCompletionTokens),
            fixedProposalDepth: try int(object, "fixed_proposal_depth", min: 1, max: NativeMTPSelfTestChallenge.maxProposalDepth),
            expectedTokenIDs: expectedTokenIDs,
            expectedTokenIDSHA256: expectedTokenIDSHA256,
            expectedTerminalReason: try printableString(object, "expected_terminal_reason", maxBytes: 64),
            expectedCounters: counters,
            expectedCommittedStateDigest: try sha256(object, "expected_committed_state_sha256")
        )
    }

    static func evaluate(
        challenge: NativeMTPSelfTestChallenge,
        servedSnapshot: NativeMTPSelfTestServedSnapshot,
        result: NativeMTPSelfTestExecutionResult
    ) -> NativeMTPSelfTestEvaluation {
        guard result.runtimeTuple == servedSnapshot.runtimeTuple,
              result.runtimeTuple.modelID == challenge.modelID,
              result.runtimeTuple.modelHash == challenge.modelHash,
              result.runtimeTuple.tokenizerDigest == challenge.tokenizerSHA256,
              result.runtimeTuple.artifactDigest == challenge.artifactSHA256,
              result.runtimeTuple.manifestDigest == challenge.mtpManifestSHA256
        else {
            return NativeMTPSelfTestEvaluation(passed: false, reason: .tupleMismatch)
        }
        guard result.servedSnapshotGeneration == servedSnapshot.generation else {
            return NativeMTPSelfTestEvaluation(passed: false, reason: .generationMismatch)
        }
        guard result.proposalDepth == challenge.fixedProposalDepth,
              servedSnapshot.proposalDepth == challenge.fixedProposalDepth
        else {
            return NativeMTPSelfTestEvaluation(passed: false, reason: .proposalDepthMismatch)
        }
        guard result.actualDecodePath == .nativeMTP else {
            return NativeMTPSelfTestEvaluation(passed: false, reason: .decodePathMismatch)
        }
        guard !result.fallbackUsed else {
            return NativeMTPSelfTestEvaluation(passed: false, reason: .fallbackUsed)
        }
        guard tokenDigest(result.outputTokenIDs) == challenge.expectedTokenIDSHA256 else {
            return NativeMTPSelfTestEvaluation(passed: false, reason: .outputDigestMismatch)
        }
        guard result.terminalReason == challenge.expectedTerminalReason else {
            return NativeMTPSelfTestEvaluation(passed: false, reason: .terminalReasonMismatch)
        }
        guard result.counters == challenge.expectedCounters else {
            return NativeMTPSelfTestEvaluation(passed: false, reason: .counterMismatch)
        }
        guard result.committedStateDigest == challenge.expectedCommittedStateDigest else {
            return NativeMTPSelfTestEvaluation(passed: false, reason: .committedStateMismatch)
        }
        return NativeMTPSelfTestEvaluation(passed: true, reason: .passed)
    }

    static func tokenDigest(_ tokens: [Int]) -> String {
        let canonical = "[" + tokens.map(String.init).joined(separator: ",") + "]"
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func runtimeTupleDigest(_ tuple: NativeMTPSelfTestRuntimeTuple) throws -> String {
        try RFC8785JCS.sha256Hex(of: tuple.canonicalValue())
    }

    private static func rejectUnknownFields(_ object: [String: Any], allowed: Set<String>) throws {
        for key in object.keys where !allowed.contains(key) {
            throw NativeMTPSelfTestError.unknownField(key)
        }
    }

    private static func string(_ object: [String: Any], _ field: String) throws -> String {
        guard let value = object[field] as? String else {
            throw NativeMTPSelfTestError.missingOrInvalidField(field)
        }
        return value
    }

    private static func printableString(_ object: [String: Any], _ field: String, maxBytes: Int) throws -> String {
        let value = try string(object, field)
        guard !value.isEmpty,
              value.utf8.count <= maxBytes,
              value.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7e })
        else {
            throw NativeMTPSelfTestError.missingOrInvalidField(field)
        }
        return value
    }

    private static func utcSecondsDate(_ object: [String: Any], _ field: String) throws -> Date {
        let value = try string(object, field)
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$"#, options: .regularExpression) != nil else {
            throw NativeMTPSelfTestError.missingOrInvalidField(field)
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        guard let date = formatter.date(from: value),
              formatter.string(from: date) == value
        else {
            throw NativeMTPSelfTestError.missingOrInvalidField(field)
        }
        return date
    }

    private static func sha256(_ object: [String: Any], _ field: String) throws -> String {
        let value = try string(object, field)
        guard value.count == 64,
              value.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (97...102).contains(byte)
              })
        else {
            throw NativeMTPSelfTestError.missingOrInvalidField(field)
        }
        return value
    }

    private static func lowercaseHex(_ object: [String: Any], _ field: String, lengths: Set<Int>) throws -> String {
        let value = try string(object, field)
        guard lengths.contains(value.count),
              value.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (97...102).contains(byte)
              })
        else {
            throw NativeMTPSelfTestError.missingOrInvalidField(field)
        }
        return value
    }

    private static func int(_ object: [String: Any], _ field: String, min: Int, max: Int) throws -> Int {
        guard let value = object[field] as? Int,
              value >= min,
              value <= max
        else {
            throw NativeMTPSelfTestError.missingOrInvalidField(field)
        }
        return value
    }

    private static func uint64(_ object: [String: Any], _ field: String) throws -> UInt64 {
        if let value = object[field] as? UInt64 {
            return value
        }
        guard let value = object[field] as? Int, value >= 0 else {
            throw NativeMTPSelfTestError.missingOrInvalidField(field)
        }
        return UInt64(value)
    }

    private static func tokenIDs(_ object: [String: Any], _ field: String, minCount: Int, maxCount: Int) throws -> [Int] {
        guard let values = object[field] as? [Int],
              values.count >= minCount,
              values.count <= maxCount,
              values.allSatisfy({ $0 >= 0 && $0 <= Int(UInt32.max) })
        else {
            throw NativeMTPSelfTestError.missingOrInvalidField(field)
        }
        return values
    }

    private static func serializedTokenArrayByteCount(_ tokens: [Int]) -> Int {
        ("[" + tokens.map(String.init).joined(separator: ",") + "]").utf8.count
    }

}

extension NativeMTPSelfTestRuntimeTuple {
    func canonicalValue() -> RFC8785JCS.Value {
        .object([
            "model_id": .string(modelID),
            "model_hash": .string(modelHash),
            "model_hash_algorithm": .string(modelHashAlgorithm),
            "tokenizer_digest": .string(tokenizerDigest),
            "artifact_digest": .string(artifactDigest),
            "manifest_digest": .string(manifestDigest),
            "sidecar_digest": .string(sidecarDigest),
            "provider_binary_sha256": .string(providerBinarySHA256),
            "runtime_cdhash": .string(runtimeCDHash),
            "cache_namespace": .string(cacheNamespace),
            "state_digest": .string(stateDigest),
            "proposal_depth": .int(proposalDepth),
        ])
    }
}

struct NativeMTPSelfTestRunner: Sendable {
    static let capability = "native_mtp_selftest_v1"

    var run: @Sendable (NativeMTPSelfTestInput) async throws -> NativeMTPSelfTestReceipt

    static let unavailable = NativeMTPSelfTestRunner { _ in
        throw NativeMTPSelfTestError.runnerUnavailable
    }

    func validate(_ input: NativeMTPSelfTestInput) async throws -> NativeMTPSelfTestReceipt {
        guard let challenge = input.selectedChallenge else {
            throw NativeMTPSelfTestError.failed("missing_challenge_record")
        }
        guard let servedSnapshot = input.servedSnapshot else {
            throw NativeMTPSelfTestError.failed("missing_served_snapshot")
        }
        guard servedSnapshot.tupleSHA256 == input.tupleSHA256,
              servedSnapshot.runtimeTuple.modelID == challenge.modelID,
              servedSnapshot.runtimeTuple.modelHash == challenge.modelHash,
              servedSnapshot.runtimeTuple.tokenizerDigest == challenge.tokenizerSHA256,
              servedSnapshot.runtimeTuple.artifactDigest == challenge.artifactSHA256,
              servedSnapshot.runtimeTuple.manifestDigest == challenge.mtpManifestSHA256,
              servedSnapshot.proposalDepth == challenge.fixedProposalDepth,
              input.proposalDepth == challenge.fixedProposalDepth
        else {
            throw NativeMTPSelfTestError.tupleMismatch
        }
        guard challenge.modelID == input.modelID else {
            throw NativeMTPSelfTestError.failed("model_id_mismatch")
        }
        let receipt = try await run(input)
        guard receipt.tupleSHA256 == input.tupleSHA256 else {
            throw NativeMTPSelfTestError.tupleMismatch
        }
        guard receipt.challengeBankSHA256 == input.challengeBank.challengeBankSHA256 else {
            throw NativeMTPSelfTestError.challengeBankMismatch
        }
        guard receipt.version == Self.capability else {
            throw NativeMTPSelfTestError.failed("version_mismatch")
        }
        guard receipt.challengeID == challenge.challengeID else {
            throw NativeMTPSelfTestError.failed("challenge_id_mismatch")
        }
        guard receipt.servedSnapshotGeneration == servedSnapshot.generation else {
            throw NativeMTPSelfTestError.failed("served_snapshot_generation_mismatch")
        }
        guard receipt.proposalDepth == challenge.fixedProposalDepth else {
            throw NativeMTPSelfTestError.failed("proposal_depth_mismatch")
        }
        guard receipt.maxCompletionTokens == challenge.maxCompletionTokens else {
            throw NativeMTPSelfTestError.failed("max_completion_tokens_mismatch")
        }
        guard receipt.promptTokenIDs == challenge.promptTokenIDs else {
            throw NativeMTPSelfTestError.failed("prompt_token_ids_mismatch")
        }
        guard receipt.actualDecodePath == .nativeMTP else {
            throw NativeMTPSelfTestError.failed("decode_path_mismatch")
        }
        guard !receipt.fallbackUsed else {
            throw NativeMTPSelfTestError.failed("fallback_used")
        }
        guard NativeMTPSelfTest.tokenDigest(receipt.generatedTokenIDs) == challenge.expectedTokenIDSHA256 else {
            throw NativeMTPSelfTestError.failed("expected_output_token_digest_mismatch")
        }
        guard receipt.terminalReason.rawValue == challenge.expectedTerminalReason else {
            throw NativeMTPSelfTestError.failed("terminal_reason_mismatch")
        }
        guard Self.int(receipt.acceptedTokens, equals: challenge.expectedCounters.acceptedTokens),
              Self.int(receipt.rejectedTokens, equals: challenge.expectedCounters.rejectedTokens),
              Self.int(receipt.bonusTokens, equals: challenge.expectedCounters.bonusTokens),
              Self.int(receipt.committedTokens, equals: challenge.expectedCounters.committedTokens)
        else {
            throw NativeMTPSelfTestError.failed("counter_mismatch")
        }
        guard receipt.committedStateDigestSHA256 == challenge.expectedCommittedStateDigest else {
            throw NativeMTPSelfTestError.failed("committed_state_digest_mismatch")
        }
        return receipt
    }

    private static func int(_ value: Int, equals expected: UInt64) -> Bool {
        guard value >= 0 else { return false }
        let value64 = UInt64(bitPattern: Int64(value))
        return value64 == expected
    }
}

enum NativeMTPSelfTestDigest {
    static func committedStateDigest(
        promptTokenIDs: [Int],
        generatedTokenIDs: [Int],
        acceptedTokens: Int,
        rejectedTokens: Int,
        bonusTokens: Int,
        committedTokens: Int,
        terminalReason: ContinuousBatchSchedulerTerminalStatus
    ) -> String {
        let fields = [
            "prompt=\(promptTokenIDs.map(String.init).joined(separator: ","))",
            "generated=\(generatedTokenIDs.map(String.init).joined(separator: ","))",
            "accepted=\(acceptedTokens)",
            "rejected=\(rejectedTokens)",
            "bonus=\(bonusTokens)",
            "committed=\(committedTokens)",
            "terminal=\(terminalReason.rawValue)",
        ]
        let digest = SHA256.hash(data: Data(fields.joined(separator: "\n").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
