import CryptoKit
import Foundation
import MacProviderCore

/// SPEC-015 v0.3 §M.2 — the provenance of `model_hash` at receipt
/// emission time. Sum-typed so the receipt-emission layer can refuse
/// the §M.2.2 ambiguous case BEFORE constructing a signed tuple.
///
/// - `.captured(hash)` — request-start container is known. Hash MUST
///   be raw 64-char lowercase hex (validated in ReceiptBuilder.build).
/// - `.warmSwapDisabled` — provider running with
///   `--enable-warm-swap=false` and no settlement hash requirement, or
///   a settlement path without a captured served hash. Legacy v0.3
///   encodes this as JSON `null`; v0.4 settlement receipt construction
///   rejects it fail-closed.
/// - `.ambiguous` — runtime cannot disambiguate which container served
///   this request (e.g. a future regression of SPEC-011 R-3.4.1
///   in-flight tracking). Receipt-emission MUST refuse with
///   `receipt_omitted: model_swap_violation` per §M.2.2's
///   defence-in-depth clause. NEVER emit a signed tuple with this
///   provenance.
enum ReceiptModelHashSource: Sendable, Equatable {
    case captured(String)
    case warmSwapDisabled
    case ambiguous
}

/// SPEC-015 v0.3 receipt issuance input.
///
/// `modelHash` carries the SHA-256 of the loaded MLX container per
/// SPEC-011 v0.5 R-3.3.1 (raw 64-char lowercase hex, no `sha256:`
/// prefix). `nil` MUST be emitted by providers running with
/// `--enable-warm-swap=false` per SPEC-015 §M.2.3; the receipt encodes
/// it as the JSON literal `null`.
///
/// The hash threaded in MUST be the value captured at request-acceptance
/// time (the §M.2.1 request-start container) — NOT the runtime's current
/// snapshot at receipt-emission time — so the §M.2.2 construction proof
/// holds: every receipt commits to the hash that started generation.
///
/// `ReceiptInput` carries the resolved `String?` (the
/// `.ambiguous` case never reaches this struct — the receipt-emission
/// layer short-circuits before construction). See
/// `ReceiptModelHashSource` for the full provenance state.
struct ReceiptInput {
    let modelId: String
    let request: ChatCompletionRequest
    let outputContent: String
    let outputToolCalls: [ToolCall]?
    let finishReason: String
    let ttftMs: Int64
    let tokensOut: Int64
    let unixTsSeconds: Int64
    let modelHash: String?
}

struct SettlementReceiptMetadata: Sendable, Equatable {
    let accountScope: String
    let requestID: String
    let attemptN: Int64
    let providerID: String
    let providerReceiptKeyID: String
    let modelID: String
    let expectedCatalogModelHash: String
    let catalogID: String
    let catalogBodyDigest: String
    let routeSnapshotDigest: String
    let routeSnapshotPolicyVersion: String
    let routeSnapshotMode: String
    let promptHash: String
    let outputPrefixStartByte: Int64
    let pendingDeadlineSeconds: Int64

    init?(wire: [String: Any]) {
        guard let accountScope = wire["account_scope"] as? String,
              let requestID = wire["request_id"] as? String,
              let attemptN = Self.int64(wire["attempt_n"]),
              let providerID = wire["provider_id"] as? String,
              let providerReceiptKeyID = wire["provider_receipt_key_id"] as? String,
              let modelID = wire["model_id"] as? String,
              let expectedCatalogModelHash = wire["expected_catalog_model_hash"] as? String,
              let catalogID = wire["catalog_id"] as? String,
              let catalogBodyDigest = wire["catalog_body_digest"] as? String,
              let routeSnapshotDigest = wire["route_snapshot_digest"] as? String,
              let routeSnapshotPolicyVersion = wire["route_snapshot_policy_version"] as? String,
              let routeSnapshotMode = wire["route_snapshot_mode"] as? String,
              let promptHash = wire["prompt_hash"] as? String,
              let outputPrefixStartByte = Self.int64(wire["output_prefix_start_byte"]),
              let pendingDeadlineSeconds = Self.int64(wire["pending_deadline_seconds"]) else {
            return nil
        }
        self.accountScope = accountScope
        self.requestID = requestID
        self.attemptN = attemptN
        self.providerID = providerID
        self.providerReceiptKeyID = providerReceiptKeyID
        self.modelID = modelID
        self.expectedCatalogModelHash = expectedCatalogModelHash
        self.catalogID = catalogID
        self.catalogBodyDigest = catalogBodyDigest
        self.routeSnapshotDigest = routeSnapshotDigest
        self.routeSnapshotPolicyVersion = routeSnapshotPolicyVersion
        self.routeSnapshotMode = routeSnapshotMode
        self.promptHash = promptHash
        self.outputPrefixStartByte = outputPrefixStartByte
        self.pendingDeadlineSeconds = pendingDeadlineSeconds
    }

    private static func int64(_ value: Any?) -> Int64? {
        switch value {
        case let value as Int:
            return Int64(value)
        case let value as Int64:
            return value
        case let value as NSNumber:
            return value.int64Value
        default:
            return nil
        }
    }
}

struct SettlementReceiptInput {
    let metadata: SettlementReceiptMetadata
    let modelHash: String
    let content: String
    let toolCalls: [ToolCall]?
    let finishReason: String
    let promptTokens: Int64
    let completionTokens: Int64
    let terminalState: String
    let terminalStateUnixMS: Int64
    let issuedAtUnixMS: Int64
}

struct ReceiptBuilder: Sendable {
    /// SPEC-015 §M.0 wire-shape discriminant. ASCII string `"3"`.
    static let receiptVersionV03 = "3"
    static let receiptVersionV04 = "4"

    let keyStore: ReceiptKeyStoring

    init(keyStore: ReceiptKeyStoring) {
        self.keyStore = keyStore
    }

    func build(providerId: String, input: ReceiptInput) throws -> String {
        guard isASCII(input.modelId) else {
            throw Error.nonASCIIModelId
        }
        guard input.ttftMs >= 0 else {
            throw Error.negativeInteger("ttft_ms")
        }
        guard input.tokensOut >= 0 else {
            throw Error.negativeInteger("tokens_out")
        }
        guard input.unixTsSeconds >= 0 else {
            throw Error.negativeInteger("unix_ts")
        }
        if let modelHash = input.modelHash {
            guard Self.isValidModelHash(modelHash) else {
                throw Error.invalidModelHash
            }
        }

        guard let key = try keyStore.loadCurrent(providerId: providerId) else {
            throw Error.missingCurrentReceiptKey(providerId: providerId)
        }
        let tuple = try tupleObject(input: input, publicKey: key.publicKey)
        let canonicalTuple = try RFC8785JCS.canonicalString(tuple)
        let signature = try key.signature(for: Data(canonicalTuple.utf8))

        return Data(canonicalTuple.utf8).base64EncodedString()
            + "."
            + Data(signature).base64EncodedString()
    }

    func buildSettlement(providerId: String, input: SettlementReceiptInput) throws -> String {
        guard providerId == input.metadata.providerID else {
            throw Error.settlementFieldMismatch("provider_id")
        }
        guard input.modelHash == input.metadata.expectedCatalogModelHash else {
            throw Error.settlementFieldMismatch("model_hash")
        }
        guard Self.isValidModelHash(input.modelHash) else {
            throw Error.invalidModelHash
        }
        guard Self.isValidModelHash(input.metadata.expectedCatalogModelHash),
              Self.isValidModelHash(input.metadata.catalogBodyDigest),
              Self.isValidModelHash(input.metadata.routeSnapshotDigest),
              Self.isValidModelHash(input.metadata.promptHash) else {
            throw Error.invalidSettlementMetadata
        }
        guard input.metadata.providerReceiptKeyID.hasPrefix("ed25519-sha256:"),
              Self.isValidModelHash(String(input.metadata.providerReceiptKeyID.dropFirst("ed25519-sha256:".count))) else {
            throw Error.invalidSettlementMetadata
        }
        for (field, value) in [
            ("attempt_n", input.metadata.attemptN),
            ("output_prefix_start_byte", input.metadata.outputPrefixStartByte),
            ("pending_deadline_seconds", input.metadata.pendingDeadlineSeconds),
            ("prompt_tokens", input.promptTokens),
            ("completion_tokens", input.completionTokens),
            ("terminal_state_ts_unix_ms", input.terminalStateUnixMS),
            ("issued_at_unix_ms", input.issuedAtUnixMS),
        ] {
            guard value >= 0 else { throw Error.negativeInteger(field) }
        }

        guard let key = try keyStore.loadCurrent(providerId: providerId) else {
            throw Error.missingCurrentReceiptKey(providerId: providerId)
        }
        let expectedKeyID = Self.receiptKeyID(publicKey: key.publicKey)
        guard input.metadata.providerReceiptKeyID == expectedKeyID else {
            throw Error.settlementFieldMismatch("provider_receipt_key_id")
        }
        let tuple = try settlementTupleObject(input: input)
        let canonicalTuple = try RFC8785JCS.canonicalString(tuple)
        let signature = try key.signature(for: Data(canonicalTuple.utf8))

        return Data(canonicalTuple.utf8).base64EncodedString()
            + "."
            + Data(signature).base64EncodedString()
    }

    private func tupleObject(
        input: ReceiptInput,
        publicKey: Curve25519.Signing.PublicKey
    ) throws -> RFC8785JCS.Value {
        // SPEC-015 §M.0 — exactly nine keys; JCS canonical order is
        // UTF-16 code-unit lexicographic, which the canonicalizer
        // computes from the object's keys. The dictionary literal here
        // is unordered; RFC8785JCS sorts before emission.
        let modelHashValue: RFC8785JCS.Value
        if let modelHash = input.modelHash {
            modelHashValue = .string(modelHash)
        } else {
            modelHashValue = .null
        }
        return .object([
            "model_hash": modelHashValue,
            "model_id": .string(input.modelId),
            "prompt_hash": .string(try PromptCanonicalizer.promptHash(for: input.request)),
            "output_hash": .string(try OutputCanonicalizer.outputHash(
                content: input.outputContent,
                toolCalls: input.outputToolCalls,
                finishReason: input.finishReason
            )),
            "provider_pubkey": .string(publicKey.rawRepresentation.base64EncodedString()),
            "receipt_version": .string(Self.receiptVersionV03),
            "ttft_ms": .int(try checkedInt(input.ttftMs, field: "ttft_ms")),
            "tokens_out": .int(try checkedInt(input.tokensOut, field: "tokens_out")),
            "unix_ts": .int(try checkedInt(input.unixTsSeconds, field: "unix_ts")),
        ])
    }

    private func checkedInt(_ value: Int64, field: String) throws -> Int {
        guard value <= Int64(Int.max) else {
            throw Error.integerOutOfRange(field)
        }
        return Int(value)
    }

    private func settlementTupleObject(input: SettlementReceiptInput) throws -> RFC8785JCS.Value {
        let normalizedContent = settlementContent(input.content)
        let deliveredBytes = Int64(normalizedContent.utf8.count)
        let outputEndResult = input.metadata.outputPrefixStartByte.addingReportingOverflow(deliveredBytes)
        guard !outputEndResult.overflow else {
            throw Error.integerOutOfRange("output_prefix_end_byte")
        }
        let outputEnd = outputEndResult.partialValue
        let output = try settlementOutputValue(
            content: normalizedContent,
            toolCalls: input.toolCalls,
            finishReason: input.finishReason,
            terminalState: input.terminalState,
            outputPrefixStartByte: input.metadata.outputPrefixStartByte,
            outputPrefixEndByte: outputEnd
        )
        let outputHash = try RFC8785JCS.sha256Hex(of: output)
        let usage = RFC8785JCS.Value.object([
            "billable_input_tokens": .int(try checkedInt(input.promptTokens, field: "billable_input_tokens")),
            "billable_output_tokens": .int(try checkedInt(input.completionTokens, field: "billable_output_tokens")),
            "delivered_output_bytes": .int(try checkedInt(deliveredBytes, field: "delivered_output_bytes")),
            "observed_input_tokens": .int(try checkedInt(input.promptTokens, field: "observed_input_tokens")),
            "observed_output_tokens": .int(try checkedInt(input.completionTokens, field: "observed_output_tokens")),
        ])
        return .object([
            "account_scope": .string(input.metadata.accountScope),
            "attempt_n": .int(try checkedInt(input.metadata.attemptN, field: "attempt_n")),
            "catalog_body_digest": .string(input.metadata.catalogBodyDigest),
            "catalog_id": .string(input.metadata.catalogID),
            "expected_catalog_model_hash": .string(input.metadata.expectedCatalogModelHash),
            "issued_at_unix_ms": .int(try checkedInt(input.issuedAtUnixMS, field: "issued_at_unix_ms")),
            "model_hash": .string(input.modelHash),
            "model_id": .string(input.metadata.modelID),
            "output_hash": .string(outputHash),
            "output_prefix_end_byte": .int(try checkedInt(outputEnd, field: "output_prefix_end_byte")),
            "output_prefix_start_byte": .int(try checkedInt(input.metadata.outputPrefixStartByte, field: "output_prefix_start_byte")),
            "prompt_hash": .string(input.metadata.promptHash),
            "provider_id": .string(input.metadata.providerID),
            "provider_receipt_key_id": .string(input.metadata.providerReceiptKeyID),
            "receipt_version": .string(Self.receiptVersionV04),
            "request_id": .string(input.metadata.requestID),
            "route_snapshot_digest": .string(input.metadata.routeSnapshotDigest),
            "route_snapshot_mode": .string(input.metadata.routeSnapshotMode),
            "route_snapshot_policy_version": .string(input.metadata.routeSnapshotPolicyVersion),
            "signature_key_alg": .string("Ed25519"),
            "terminal_state": .string(input.terminalState),
            "terminal_state_ts_unix_ms": .int(try checkedInt(input.terminalStateUnixMS, field: "terminal_state_ts_unix_ms")),
            "usage": usage,
        ])
    }

    private func settlementOutputValue(
        content: String,
        toolCalls: [ToolCall]?,
        finishReason: String,
        terminalState: String,
        outputPrefixStartByte: Int64,
        outputPrefixEndByte: Int64
    ) throws -> RFC8785JCS.Value {
        .object([
            "content": .string(content),
            "finish_reason": finishReason.isEmpty ? .null : .string(finishReason),
            "output_prefix_end_byte": .int(try checkedInt(outputPrefixEndByte, field: "output_prefix_end_byte")),
            "output_prefix_start_byte": .int(try checkedInt(outputPrefixStartByte, field: "output_prefix_start_byte")),
            "terminal_state": .string(terminalState),
            "tool_calls": settlementToolCallsValue(toolCalls),
        ])
    }

    private func settlementToolCallsValue(_ toolCalls: [ToolCall]?) -> RFC8785JCS.Value {
        guard let toolCalls, !toolCalls.isEmpty else {
            return .null
        }
        return .array(toolCalls.map { call in
            .object([
                "id": .string(call.id),
                "type": .string("function"),
                "function": .object([
                    "name": .string(call.functionName),
                    "arguments": .rawString(call.arguments),
                ]),
            ])
        })
    }

    private func deliveredOutputBytes(_ content: String) -> Int64 {
        Int64(settlementContent(content).utf8.count)
    }

    private func settlementContent(_ content: String) -> String {
        PromptCanonicalizer.normalizeLineEndings(content).precomposedStringWithCanonicalMapping
    }

    private static func receiptKeyID(publicKey: Curve25519.Signing.PublicKey) -> String {
        let digest = SHA256.hash(data: publicKey.rawRepresentation)
        return "ed25519-sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private func isASCII(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { $0.value <= 0x7f }
    }

    /// SPEC-011 R-3.3.1 / SPEC-015 §M.0: raw 64-char lowercase hex,
    /// no `sha256:` prefix.
    static func isValidModelHash(_ value: String) -> Bool {
        guard value.utf8.count == 64 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 0x30 && scalar.value <= 0x39) ||
                (scalar.value >= 0x61 && scalar.value <= 0x66)
        }
    }

    enum Error: Swift.Error, Equatable {
        case missingCurrentReceiptKey(providerId: String)
        case nonASCIIModelId
        case negativeInteger(String)
        case integerOutOfRange(String)
        case invalidModelHash
        case invalidSettlementMetadata
        case settlementFieldMismatch(String)
    }
}
