import CoreGraphics
import Foundation
import ImageIO
import MacProviderCore
import XCTest

final class InlineImageInputTests: XCTestCase {
    func testAmbiguousCrossKindPartsCannotDiscardMediaOrText() throws {
        let url = try imageURL()
        let invalid: [[String: Any]] = [
            ["type": "text", "text": "question", "image_url": ["url": url]],
            ["type": "image_url", "image_url": ["url": url], "text": "lost question"],
            ["type": "image_url", "image_url": ["url": url, "text": "lost question"]],
            ["type": "text", "text": "question", "input_audio": ["data": "AAAA", "format": "wav"]],
            ["type": "input_audio", "input_audio": ["data": "AAAA", "format": "wav"], "image_url": ["url": url]],
            ["type": "input_audio", "input_audio": ["data": "AAAA", "format": "wav", "image_url": ["url": url]]],
        ]
        for part in invalid {
            assertRejected([text("question"), part])
        }
    }

    func testDuplicateMembersCannotHideOrChangeBoundMedia() {
        let bodies = [
            #"{"model":"m","messages":[{"role":"user","content":[{"type":"image_url","image_url":{"url":"data:image/png;base64,AA=="}}],"content":"hidden image"}]}"#,
            #"{"model":"m","messages":[{"role":"user","content":[{"type":"image_url","type":"text","text":"hidden image","image_url":{"url":"data:image/png;base64,AA=="}}]}]}"#,
            #"{"model":"m","messages":[{"role":"user","content":[{"type":"image_url","image_url":{"url":"first","url":"second"}}]}]}"#,
            #"{"model":"m","messages":[{"role":"user","content":[{"type":"image_url","image_url":{"url":"first"},"image_url":{"url":"second"}}]}]}"#,
            #"{"model":"m","messages":[{"role":"user","content":"first","\u0063ontent":"second"}]}"#,
        ]
        for body in bodies {
            XCTAssertThrowsError(try ChatCompletionRequest.parse(data: Data(body.utf8))) {
                XCTAssertEqual(($0 as? APIError)?.code, "invalid_json")
            }
        }
    }

    func testMixedPartsKeepOrderAndReceiptSource() throws {
        let red = try imageURL(red: 255)
        let blue = try imageURL(red: 0)
        let parts: [[String: Any]] = [text("first"), image(red), text("second"), image(blue)]
        let request = try request(parts)
        let input = try XCTUnwrap(request.validatedNativeImageInput())
        XCTAssertEqual(input.imageCount, 2)
        XCTAssertEqual(input.messages[0].parts.count, 4)
        guard case .text("first") = input.messages[0].parts[0],
              case .image(let first) = input.messages[0].parts[1],
              case .text("second") = input.messages[0].parts[2],
              case .image(let second) = input.messages[0].parts[3] else {
            return XCTFail("Ordered text/image parts were lost")
        }
        XCTAssertNotEqual(first.data, second.data)
        XCTAssertEqual(try first.decodeCGImage().width, 1)
        XCTAssertEqual(try second.decodeCGImage().height, 1)
        guard case .object(let source) = request.promptSource.messages[0] else {
            return XCTFail("Missing receipt source")
        }
        XCTAssertEqual(source["content"], try JSONValue.parse(parts))
    }

    func testImageOnlyUserParsesWithoutSyntheticText() throws {
        let request = try request([image(try imageURL())])
        XCTAssertEqual(request.messages[0].content, "")
        XCTAssertTrue(request.containsNonTextMessageContentPart)
        XCTAssertEqual(try request.validatedNativeImageInput()?.imageCount, 1)
    }

    func testTextOnlyRemainsTextAndEmptyUserStillRejects() throws {
        XCTAssertNil(try request([text("hello")]).validatedNativeImageInput())
        XCTAssertThrowsError(try request([text("")]))
    }

    func testJPEGDecodesAndMIMEMismatchRejects() throws {
        let url = try imageURL(type: "public.jpeg", mime: "image/jpeg")
        let input = try XCTUnwrap(request([image(url)]).validatedNativeImageInput())
        guard case .image(let value) = input.messages[0].parts[0] else {
            return XCTFail("Missing JPEG")
        }
        XCTAssertEqual(value.mimeType, "image/jpeg")
        XCTAssertNoThrow(try value.decodeCGImage())
        assertRejected([image(url.replacingOccurrences(of: "image/jpeg", with: "image/png"))])
    }

    func testMalformedRemoteAndUnsupportedFormatsReject() throws {
        let valid = try imageURL()
        for url in ["https://example.com/image.png", "http://127.0.0.1/image.png",
                    "data:image/gif;base64,R0lGODlh", "data:image/png;base64,%%%",
                    "data:image/png;base64,AA==", valid + "\n",
                    valid.replacingOccurrences(of: ";base64,", with: ";base64, ")] {
            assertRejected([text("describe"), image(url)])
        }
    }

    func testAudioAndNonUserImagesRejectEvenWithText() throws {
        assertRejected([text("listen"), ["type": "input_audio", "input_audio": ["data": "AAAA", "format": "wav"]]])
        assertRejected([text("describe"), image(try imageURL())], role: "system")
        assertRejected([text("describe"), image(try imageURL())], role: "assistant")
    }

    func testImageCountAndEncodedByteLimits() throws {
        let part = image(try imageURL())
        assertRejected([part, part, part], status: 413)
        let oversized = Data(repeating: 0, count: NativeImageLimits.maxBytesPerImage + 1).base64EncodedString()
        assertRejected([image("data:image/png;base64," + oversized)], status: 413)
    }

    func testDimensionAndAggregatePixelLimits() throws {
        assertRejected([image(try imageURL(width: 2049, height: 1))], status: 413)
        let large = image(try imageURL(width: 2048, height: 1025))
        assertRejected([large, large], status: 413)
    }

    func testAnimationAndChunkLengthBombRejectBeforePixelAllocation() throws {
        let url = try imageURL()
        let data = try XCTUnwrap(Data(base64Encoded: String(url.split(separator: ",")[1])))
        var animation = data
        animation.insert(contentsOf: [0, 0, 0, 8, 97, 99, 84, 76, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0], at: 33)
        assertRejected([image("data:image/png;base64," + animation.base64EncodedString())])
        var bomb = data
        bomb.replaceSubrange(8..<12, with: [255, 255, 255, 255])
        assertRejected([image("data:image/png;base64," + bomb.base64EncodedString())])
    }

    func testPNGHeaderBombTruncationAndCompressedMetadataRejectBeforeImageIO() throws {
        let url = try imageURL()
        let data = try XCTUnwrap(Data(base64Encoded: String(url.split(separator: ",")[1])))
        var dimensionBomb = data
        dimensionBomb.replaceSubrange(16..<20, with: [127, 255, 255, 255])
        assertRejected([image("data:image/png;base64," + dimensionBomb.base64EncodedString())], status: 413)
        for name in ["iCCP", "zTXt", "iTXt"] {
            var metadata = data
            metadata.insert(contentsOf: [0, 0, 0, 0] + Array(name.utf8) + [0, 0, 0, 0], at: 33)
            assertRejected([image("data:image/png;base64," + metadata.base64EncodedString())])
        }
        for cut in [1, 8, 12] {
            assertRejected([image("data:image/png;base64," + data.dropLast(cut).base64EncodedString())])
        }
    }

    func testUnsupportedDetailRejectsExplicitly() throws {
        let part: [String: Any] = ["type": "image_url", "image_url": ["url": try imageURL(), "detail": "high"]]
        assertRejected([part])
    }

    private func request(_ parts: [[String: Any]], role: String = "user") throws -> ChatCompletionRequest {
        try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: [
            "model": "vision-fixture", "messages": [["role": role, "content": parts]],
        ]))
    }

    private func assertRejected(_ parts: [[String: Any]], role: String = "user", status: Int = 400,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try request(parts, role: role).validatedNativeImageInput(), file: file, line: line) {
            XCTAssertEqual(($0 as? APIError)?.status, status, file: file, line: line)
            XCTAssertEqual(($0 as? APIError)?.code, "unsupported_content_shape", file: file, line: line)
        }
    }

    private func text(_ value: String) -> [String: Any] { ["type": "text", "text": value] }
    private func image(_ url: String) -> [String: Any] { ["type": "image_url", "image_url": ["url": url]] }

    private func imageURL(width: Int = 1, height: Int = 1, red: Int = 255,
                          type: String = "public.png", mime: String = "image/png") throws -> String {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                                             bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: CGFloat(red) / 255, green: 0, blue: red == 0 ? 1 : 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return "data:\(mime);base64," + (data as Data).base64EncodedString()
    }
}
