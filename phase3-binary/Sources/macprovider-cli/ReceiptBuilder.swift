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
///   `--enable-warm-swap=false` per SPEC-011 R-3.3.0. JSON `null`
///   per §M.2.3.
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
struct ReceiptBuilder: Sendable {
    /// SPEC-015 §M.0 wire-shape discriminant. ASCII string `"3"`.
    static let receiptVersionV03 = "3"

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
    }
}
