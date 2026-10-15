import Foundation
import ImageIO
import CoreGraphics

/// The initial native vision profile. Caps apply before allocating decoded pixels.
public enum NativeImageLimits {
    public static let maxImages = 2
    public static let maxBytesPerImage = 1024 * 1024
    public static let maxAggregateBytes = 2 * 1024 * 1024
    public static let maxDimension = 2048
    public static let maxAggregatePixels = 4_194_304
}

public enum NativeImagePart: Sendable {
    case text(String)
    case image(ValidatedInlineImage)
}

public struct NativeImageMessage: Sendable {
    public let role: String
    public let parts: [NativeImagePart]
}

public struct NativeImageInput: Sendable {
    public let messages: [NativeImageMessage]
    public let imageCount: Int
}

/// Immutable bytes admitted from the receipt-bound data URL. Never refetched.
/// Construction is private so decoding cannot bypass metadata and size checks.
public struct ValidatedInlineImage: Sendable {
    public let data: Data
    public let width: Int
    public let height: Int
    public let mimeType: String
    public let orientation: Int32

    fileprivate init(url: String) throws {
        let prefix: String
        let expectedType: String
        if url.hasPrefix("data:image/png;base64,") {
            prefix = "data:image/png;base64,"
            mimeType = "image/png"
            expectedType = "public.png"
        } else if url.hasPrefix("data:image/jpeg;base64,") {
            prefix = "data:image/jpeg;base64,"
            mimeType = "image/jpeg"
            expectedType = "public.jpeg"
        } else {
            throw imageError("Native images require inline PNG or JPEG base64 data URLs")
        }
        let encoded = url.dropFirst(prefix.count)
        guard !encoded.isEmpty,
              encoded.utf8.count <= ((NativeImageLimits.maxBytesPerImage + 2) / 3) * 4 else {
            throw imageError("Image exceeds the encoded byte limit", status: 413)
        }
        // Foundation's strict decoder plus round-trip comparison excludes
        // whitespace, alternate alphabets, omitted padding and nonzero pad bits.
        guard let bytes = Data(base64Encoded: String(encoded)),
              bytes.base64EncodedString() == encoded else {
            throw imageError("Image base64 must use canonical padded encoding")
        }
        guard bytes.count <= NativeImageLimits.maxBytesPerImage else {
            throw imageError("Image exceeds 1 MiB", status: 413)
        }
        if expectedType == "public.png" { try validatePNGEnvelope(bytes) }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(bytes as CFData, options),
              CGImageSourceGetType(source) as String? == expectedType,
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw imageError("Image must be a complete, single-frame PNG or JPEG matching its MIME type")
        }
        guard width > 0, height > 0,
              width <= NativeImageLimits.maxDimension,
              height <= NativeImageLimits.maxDimension else {
            throw imageError("Image dimensions must be between 1 and 2048 pixels", status: 413)
        }
        self.data = bytes
        self.width = width
        self.height = height
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        guard (1...8).contains(orientation) else {
            throw imageError("Invalid image orientation")
        }
        self.orientation = Int32(orientation)
    }

    /// Called inside the admitted native processor, after aggregate caps pass.
    /// Eager decode ensures malformed pixel data fails before model generation.
    public func decodeCGImage() throws -> CGImage {
        let options = [
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, options),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              image.width == width, image.height == height else {
            throw imageError("Image pixels cannot be decoded")
        }
        return image
    }
}

/// Bound IHDR before ImageIO parses metadata. Compressed ancillary metadata
/// could otherwise expand independently of the decoded pixel count.
private func validatePNGEnvelope(_ data: Data) throws {
    guard data.count >= 33,
          data.prefix(8).elementsEqual([137, 80, 78, 71, 13, 10, 26, 10]),
          pngUInt32(data, at: 8) == 13,
          data[12..<16].elementsEqual([73, 72, 68, 82]) else {
        throw imageError("Invalid PNG header")
    }
    let width = pngUInt32(data, at: 16)
    let height = pngUInt32(data, at: 20)
    guard width > 0, height > 0,
          width <= NativeImageLimits.maxDimension,
          height <= NativeImageLimits.maxDimension else {
        throw imageError("Image dimensions must be between 1 and 2048 pixels", status: 413)
    }
    var offset = 8
    while offset <= data.count - 12 {
        let length = pngUInt32(data, at: offset)
        guard length <= data.count - offset - 12 else {
            throw imageError("Invalid PNG chunk length")
        }
        let type = data[(offset + 4)..<(offset + 8)]
        if type.elementsEqual([97, 99, 84, 76]) { // acTL, even a single APNG frame
            throw imageError("Animated images are unsupported")
        }
        if type.elementsEqual([105, 67, 67, 80]) // iCCP
            || type.elementsEqual([122, 84, 88, 116]) // zTXt
            || type.elementsEqual([105, 84, 88, 116]) { // iTXt
            throw imageError("PNG compressed or international text metadata is unsupported")
        }
        if type.elementsEqual([73, 69, 78, 68]) { // IEND
            guard length == 0, offset + 12 == data.count else {
                throw imageError("Invalid PNG end marker")
            }
            return
        }
        offset += length + 12
    }
    throw imageError("PNG is missing its end marker")
}

private func pngUInt32(_ data: Data, at offset: Int) -> Int {
    (0..<4).reduce(0) { ($0 << 8) | Int(data[offset + $1]) }
}

extension ChatCompletionRequest {
    /// Preserves ordered raw content. A non-text request never returns nil:
    /// unsupported content throws instead of falling back to text projection.
    public func validatedNativeImageInput() throws -> NativeImageInput? {
        guard containsNonTextMessageContentPart else { return nil }
        var count = 0
        var bytes = 0
        var pixels = 0
        var result: [NativeImageMessage] = []
        for message in promptSource.messages {
            guard case .object(let object) = message,
                  case .string(let role) = object["role"] else {
                throw imageError("Invalid native vision message")
            }
            guard role == "system" || role == "user" || role == "assistant",
                  object["tool_calls"] == nil || object["tool_calls"] == .null,
                  object["tool_call_id"] == nil || object["tool_call_id"] == .null else {
                throw imageError("Native image requests do not support tool history")
            }
            var parts: [NativeImagePart] = []
            switch object["content"] {
            case .string(let text):
                parts.append(.text(text))
            case .array(let rawParts):
                for rawPart in rawParts {
                    guard case .object(let part) = rawPart else {
                        throw imageError("Invalid native vision content part")
                    }
                    switch part["type"] {
                    case .string("text"):
                        guard case .string(let text) = part["text"] else {
                            throw imageError("Invalid native vision text part")
                        }
                        parts.append(.text(text))
                    case .string("image_url"):
                        guard role == "user",
                              case .object(let imageURL) = part["image_url"],
                              case .string(let url) = imageURL["url"] else {
                            throw imageError("Images are supported only in user messages")
                        }
                        guard imageURL["detail"] == nil || imageURL["detail"] == .null
                            || imageURL["detail"] == .string("auto") else {
                            throw imageError("Native images support only detail auto")
                        }
                        count += 1
                        guard count <= NativeImageLimits.maxImages else {
                            throw imageError("At most two images are supported per request", status: 413)
                        }
                        let image = try ValidatedInlineImage(url: url)
                        bytes += image.data.count
                        pixels += image.width * image.height
                        guard bytes <= NativeImageLimits.maxAggregateBytes,
                              pixels <= NativeImageLimits.maxAggregatePixels else {
                            throw imageError("Images exceed aggregate byte or pixel limits", status: 413)
                        }
                        parts.append(.image(image))
                    default:
                        throw imageError("Native vision supports only text and inline image parts")
                    }
                }
            default:
                throw imageError("Native image messages require text or ordered content parts")
            }
            result.append(NativeImageMessage(role: role, parts: parts))
        }
        guard count > 0 else { throw imageError("Unsupported native media content") }
        return NativeImageInput(messages: result, imageCount: count)
    }
}

private func imageError(_ message: String, status: Int = 400) -> APIError {
    APIError(status: status, message: message, code: "unsupported_content_shape", param: "messages", retryable: false)
}
