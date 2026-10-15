import CoreImage
import CryptoKit
import Foundation
import MLXLMCommon
import MacProviderCore

/// The one native vision tuple implemented by issue #2016.  This is an
/// implementation identity, not a statement that any provider is qualified to
/// receive buyer image traffic; routing owns that separate, evidence-bound gate.
struct NativeVisionProfile: Equatable, Sendable {
    static let identifier = "qwen2vl-inline-v1"
    static let modelID = "mlx-community/Qwen2-VL-2B-Instruct-4bit"
    static let modelRevision = "01af461cdb9574acc09084a0ef94e216e142b085"
    static let runtime = "mlx_cache"
    static let processorMaxPixels = 512 * 28 * 28
    static let prefillStepSize = 512
    static let processorMinimumAxis = 28
    static let configSHA256 = "3c6bdaacede67a811e0e122def203d9465301416a3df11835a2f238e1f349b9e"
    static let weightsSHA256 = "3534d3dcfaacd0cd00e935469bc34b6d692b2ba0749c5d9ee422f3f2175cf992"

    // Exact special-token set in the pinned tokenizer config. Captured by the
    // profile, so a warm replacement cannot inherit another model's filter.
    static let stopTokenFilter = StopTokenFilter(tokens: [
        "<|endoftext|>", "<|im_start|>", "<|im_end|>",
        "<|object_ref_start|>", "<|object_ref_end|>", "<|box_start|>", "<|box_end|>",
        "<|quad_start|>", "<|quad_end|>", "<|vision_start|>", "<|vision_end|>",
        "<|vision_pad|>", "<|image_pad|>", "<|video_pad|>",
    ])

    let artifactSHA256: String?
    let processorConfigSHA256: String
    let tokenizerConfigSHA256: String
    let chatTemplateSHA256: String

    static func supports(modelID: String?) -> Bool {
        modelID?.caseInsensitiveCompare(Self.modelID) == .orderedSame
    }

    static func load(modelID: String?, directory: URL, artifactSHA256: String?) throws -> Self? {
        guard supports(modelID: modelID) else { return nil }
        // Pin every processor/tokenizer/weight input, including fallback tokenizer
        // files. Unexpected loader overrides (notably chat_template.jinja and
        // additional safetensors shards) must never change the verified tuple.
        let expected = artifactFileSHA256
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let allowed = Set(expected.keys).union(["README.md", ".gitattributes", ".cache"])
        guard entries.allSatisfy({ allowed.contains($0.lastPathComponent) }) else {
            throw identityError()
        }
        for (name, hash) in expected {
            guard try digest(directory.appendingPathComponent(name)) == hash else {
                throw identityError()
            }
        }
        let actualArtifact = try ModelArtifactVerifier.canonicalArtifactHash(directory: directory)
        guard artifactSHA256 == nil || artifactSHA256 == actualArtifact else {
            throw identityError()
        }
        let processor = expected["preprocessor_config.json"]!
        let tokenizer = expected["tokenizer_config.json"]!
        let template = expected["chat_template.json"]!
        return Self(
            artifactSHA256: actualArtifact,
            processorConfigSHA256: processor,
            tokenizerConfigSHA256: tokenizer,
            chatTemplateSHA256: template
        )
    }

    static let artifactFileSHA256: [String: String] = [
        "config.json": configSHA256,
        "model.safetensors": weightsSHA256,
        "model.safetensors.index.json": "ddc9492d4ec6dc9031d4f96050be9a233a451a3a0c07720fbbffc0b950e69669",
        "preprocessor_config.json": "56fd296c1d6dc1ae216c84b39b10381784a02ff42db425dbf02683b42a7e3f65",
        "tokenizer_config.json": "eb3c5a310899d7d65feec0dee4dff9067d7bc4ad2a17e2005bc9163f1ace0531",
        "chat_template.json": "94174d7176c52a7192f96fc34eb2cf23c7c2059d63cdbfadca1586ba89731fb7",
        "tokenizer.json": "091aa7594dc2fcfbfa06b9e3c22a5f0562ac14f30375c13af7309407a0e67b8a",
        "added_tokens.json": "7fa54985b58718a8fdb4f4d97484c4bd908db114847675e4bf3afe3e1d5d7bd4",
        "merges.txt": "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5",
        "special_tokens_map.json": "76862e765266b85aa9459767e33cbaf13970f327a0e88d1c65846c2ddd3a1ecd",
        "vocab.json": "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910",
    ]

    static func identityError() -> APIError {
        APIError(status: 503, message: "Native vision artifact identity is not supported",
                 type: "server_error", code: "vision_artifact_identity_mismatch")
    }

    /// The Qwen processor expands literal image-pad tokens against the frame
    /// array. User-supplied visual tokens could shift that association or trap
    /// its padding replacement, even in an otherwise text-only request.
    static func validateText(_ text: String) throws {
        for token in ["<|vision_start|>", "<|vision_end|>", "<|image_pad|>", "<|video_pad|>", "<|vision_pad|>"] {
            guard !text.contains(token) else {
                throw APIError(status: 400, message: "Reserved visual tokens are unsupported in message text",
                               code: "unsupported_content_shape", param: "messages")
            }
        }
    }

    static func userInput(from input: NativeImageInput) throws -> UserInput {
        var images: [UserInput.Image] = []
        let messages: [Message] = try input.messages.map { message in
            var parts: [[String: any Sendable]] = []
            for part in message.parts {
                switch part {
                case .text(let text):
                    try validateText(text)
                    parts.append(["type": "text", "text": text])
                case .image(let image):
                    let oriented = CIImage(cgImage: try image.decodeCGImage())
                        .oriented(forExifOrientation: image.orientation)
                    images.append(.ciImage(processorImage(oriented)))
                    parts.append(["type": "image"])
                }
            }
            return ["role": message.role, "content": parts]
        }
        return UserInput(prompt: .messages(messages), images: images,
                         processing: .init(maxPixels: processorMaxPixels))
    }

    /// Qwen's patch processor requires both axes >= 28. Enlarge only deficient
    /// axes before its ordinary resize, retaining every source pixel. Nearest
    /// sampling avoids invented colors in tiny images. Independent axis floors
    /// also keep narrow 1x2048 inputs within the processor's aspect-ratio bound;
    /// neither dimension can exceed the original admission cap of 2048.
    static func processorImage(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let width = max(CGFloat(processorMinimumAxis), extent.width)
        let height = max(CGFloat(processorMinimumAxis), extent.height)
        let normalized = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        guard width != extent.width || height != extent.height else { return normalized }
        return normalized.samplingNearest().transformed(by: CGAffineTransform(
            scaleX: width / extent.width, y: height / extent.height))
    }

    private static func digest(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
