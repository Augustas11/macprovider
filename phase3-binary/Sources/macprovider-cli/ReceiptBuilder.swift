import CryptoKit
import Foundation
import MacProviderCore

struct ReceiptInput {
    let modelId: String
    let request: ChatCompletionRequest
    let outputContent: String
    let outputToolCalls: [ToolCall]?
    let finishReason: String
    let ttftMs: Int64
    let tokensOut: Int64
    let unixTsSeconds: Int64
}
struct ReceiptBuilder: Sendable {
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
        .object([
            "model_id": .string(input.modelId),
            "prompt_hash": .string(try PromptCanonicalizer.promptHash(for: input.request)),
            "output_hash": .string(try OutputCanonicalizer.outputHash(
                content: input.outputContent,
                toolCalls: input.outputToolCalls,
                finishReason: input.finishReason
            )),
            "provider_pubkey": .string(publicKey.rawRepresentation.base64EncodedString()),
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

    enum Error: Swift.Error, Equatable {
        case missingCurrentReceiptKey(providerId: String)
        case nonASCIIModelId
        case negativeInteger(String)
        case integerOutOfRange(String)
    }
}
