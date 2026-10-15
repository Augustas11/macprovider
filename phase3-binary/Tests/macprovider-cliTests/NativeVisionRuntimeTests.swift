import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import MacProviderCore
import MLXLMCommon
import XCTest
@testable import macprovider_cli

final class NativeVisionRuntimeTests: XCTestCase {
    private var profile: NativeVisionProfile {
        NativeVisionProfile(
            artifactSHA256: String(repeating: "a", count: 64),
            processorConfigSHA256: NativeVisionProfile.artifactFileSHA256["preprocessor_config.json"]!,
            tokenizerConfigSHA256: NativeVisionProfile.artifactFileSHA256["tokenizer_config.json"]!,
            chatTemplateSHA256: NativeVisionProfile.artifactFileSHA256["chat_template.json"]!
        )
    }

    private func image(red: CGFloat, width: Int = 28, height: Int = 28) throws -> [String: Any] {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: red, green: 0, blue: 1 - red, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return ["type": "image_url", "image_url": ["url": "data:image/png;base64," + (bytes as Data).base64EncodedString()]]
    }

    private func request(_ parts: [[String: Any]], extra: [String: Any] = [:], model: String = NativeVisionProfile.modelID) throws -> ChatCompletionRequest {
        var body: [String: Any] = ["model": model, "messages": [["role": "user", "content": parts]], "max_tokens": 8]
        body.merge(extra) { _, new in new }
        return try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: body))
    }

    private func runtime(profile: NativeVisionProfile? = nil, calls: VisionGenerationCounter) -> ModelRuntime {
        ModelRuntime(modelID: NativeVisionProfile.modelID, warmSwapEnabled: true,
            loader: { _ in throw CancellationError() },
            testLoader: { ($0, String(repeating: "b", count: 64)) },
            testCompletion: { _, _ in
                calls.increment()
                return CompletionResult(content: "fixture", finishReason: "stop", promptTokens: 1, completionTokens: 1, settlementDisposition: .eligibleOwner)
            }, testNativeVisionProfile: profile)
    }

    func testUnsupportedImagesNeverReachGenerationEvenWhenMixedWithText() async throws {
        for parts in [[try image(red: 1)], [["type": "text", "text": "question"], try image(red: 1)]] {
            for stream in [false, true] {
                let calls = VisionGenerationCounter()
                let runtime = runtime(calls: calls)
                let request = try request(parts, extra: ["stream": stream])
                do {
                    if stream {
                        let handle = try await runtime.acquireRequestHandle(request)
                        defer { Task { await runtime.unregisterInFlight(handle.registrationID) } }
                        _ = try await runtime.stream(request, with: handle, onChunk: { _ in })
                    } else {
                        _ = try await runtime.complete(request)
                    }
                    XCTFail("Unsupported media was accepted")
                } catch let error as APIError {
                    XCTAssertEqual(error.code, "unsupported_content_shape")
                    XCTAssertFalse(error.inferenceRan)
                }
                XCTAssertEqual(calls.value, 0)
            }
        }
    }

    func testRawMessagesKeepTextImageOrderingAndDistinctImagePixels() throws {
        let request = try request([["type": "text", "text": "first"], try image(red: 1),
                                   ["type": "text", "text": "second"], try image(red: 0)])
        let input = try ModelRuntime.userInput(for: request, nativeVisionProfile: profile)
        guard case .messages(let messages) = input.prompt,
              let parts = messages.first?["content"] as? [[String: any Sendable]] else {
            return XCTFail("Native vision must use raw messages, not text projection or reordered Chat messages")
        }
        XCTAssertEqual(parts.compactMap { $0["type"] as? String }, ["text", "image", "text", "image"])
        XCTAssertEqual(parts[0]["text"] as? String, "first")
        XCTAssertEqual(parts[2]["text"] as? String, "second")
        XCTAssertEqual(input.images.count, 2)
        XCTAssertEqual(input.processing.maxPixels, 401_408)
        let context = CIContext(options: [.useSoftwareRenderer: true])
        var colors: [[UInt8]] = []
        for image in input.images {
            guard case .ciImage(let ciImage) = image.source else { return XCTFail("Media must be decoded in memory") }
            var rgba = [UInt8](repeating: 0, count: 4)
            context.render(ciImage, toBitmap: &rgba, rowBytes: 4,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8,
                           colorSpace: CGColorSpaceCreateDeviceRGB())
            colors.append(rgba)
        }
        XCTAssertGreaterThan(colors[0][0], colors[0][2])
        XCTAssertGreaterThan(colors[1][2], colors[1][0])
    }

    func testTinyAndNarrowImagesReachProcessorWithBoundedPatchDimensions() throws {
        for (width, height) in [(1, 1), (27, 28), (1, 2048), (2048, 1)] {
            let input = try ModelRuntime.userInput(
                for: request([try image(red: 1, width: width, height: height)]), nativeVisionProfile: profile)
            guard case .ciImage(let image) = input.images[0].source else { return XCTFail("Missing decoded image") }
            XCTAssertEqual(image.extent.width, CGFloat(max(28, width)))
            XCTAssertEqual(image.extent.height, CGFloat(max(28, height)))
            XCTAssertLessThanOrEqual(image.extent.width * image.extent.height, 4_194_304)
            let context = CIContext(options: [.useSoftwareRenderer: true])
            var rgba = [UInt8](repeating: 0, count: 4)
            context.render(image, toBitmap: &rgba, rowBytes: 4,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8,
                           colorSpace: CGColorSpaceCreateDeviceRGB())
            XCTAssertEqual(rgba, [255, 0, 0, 255], "Upsampling must retain source color")
        }
    }

    func testMediaDecodeConfigurationIsFixedRegardlessOfTextServingKnobs() {
        XCTAssertEqual(NativeVisionProfile.stopTokenFilter.stripping(from: "<|im_start|>answer<|im_end|>"), "answer")
        XCTAssertEqual(NativeVisionProfile.stopTokenFilter.tokens.count, 14)
        for bits: Int? in [nil, 4, 8] {
            for key: String? in [nil, "conversation-key"] {
                XCTAssertNil(ModelRuntime.effectiveKVBits(configured: bits, conversationKey: key, containsImage: true))
                XCTAssertFalse(ModelRuntime.forceSimpleKVCache(eligible: true, conversationKey: key, containsImage: true))
            }
        }
        for step in [1, 64, 512, 4096] {
            XCTAssertEqual(ModelRuntime.effectivePrefillStepSize(configured: step, containsImage: true), 512)
            XCTAssertEqual(ModelRuntime.effectivePrefillStepSize(configured: step, containsImage: false), step)
        }
        XCTAssertEqual(ModelRuntime.effectiveKVBits(configured: 4, conversationKey: nil), 4)
        XCTAssertTrue(ModelRuntime.forceSimpleKVCache(eligible: true, conversationKey: nil))
    }

    func testImageOnlyAndExplicitAutoWithoutToolsAreAccepted() throws {
        for extra: [String: Any] in [[:], ["tool_choice": "auto"], ["tools": [], "tool_choice": "auto"]] {
            let input = try ModelRuntime.userInput(for: request([try image(red: 1)], extra: extra), nativeVisionProfile: profile)
            XCTAssertEqual(input.images.count, 1)
            XCTAssertNil(input.tools)
            guard case .messages(let messages) = input.prompt,
                  let parts = messages[0]["content"] as? [[String: any Sendable]] else { return XCTFail("Missing raw message") }
            XCTAssertEqual(parts.count, 1)
            XCTAssertEqual(parts[0]["type"] as? String, "image")
        }
    }

    func testInvalidMediaCombinationsFailBeforeGenerationFixture() async throws {
        let tool: [String: Any] = ["type": "function", "function": ["name": "lookup", "parameters": ["type": "object"]]]
        let cases: [ChatCompletionRequest] = [
            try request([try image(red: 1)], extra: ["tools": [tool], "tool_choice": "auto"]),
            try request([try image(red: 1)], extra: ["response_format": ["type": "json_object"]]),
            try request([["type": "image_url", "image_url": ["url": "https://example.com/private.png"]]]),
            try request([["type": "text", "text": "<|image_pad|>"], try image(red: 1)]),
        ]
        for request in cases {
            let calls = VisionGenerationCounter()
            do {
                _ = try await runtime(profile: profile, calls: calls).complete(request)
                XCTFail("Invalid media reached generation")
            } catch let error as APIError {
                XCTAssertEqual(error.code, "unsupported_content_shape")
            }
            XCTAssertEqual(calls.value, 0)
        }
    }

    func testFragmentedReservedVisualTokensRejectBeforeProcessor() throws {
        for token in ["<|vision_start|>", "<|vision_end|>", "<|image_pad|>", "<|video_pad|>", "<|vision_pad|>"] {
            for offset in 1..<token.count {
                let split = token.index(token.startIndex, offsetBy: offset)
                let request = try request([
                    ["type": "text", "text": String(token[..<split])],
                    ["type": "text", "text": ""],
                    ["type": "text", "text": String(token[split...])],
                    try image(red: 1),
                ])
                XCTAssertThrowsError(try ModelRuntime.userInput(for: request, nativeVisionProfile: profile)) {
                    XCTAssertEqual(($0 as? APIError)?.code, "unsupported_content_shape")
                }
            }
        }
    }

    func testImagesCannotUseTextBatchOrSpeculativeRoutes() throws {
        let media = try request([try image(red: 1)])
        XCTAssertFalse(ModelRuntime.requestStateRepresentable(media))
        XCTAssertEqual(ModelRuntime.speculativeRoute(for: media, draftLoaded: true, numDraftTokens: 3), .tokenIterator)
        let text = try request([["type": "text", "text": "hello"]])
        XCTAssertTrue(ModelRuntime.requestStateRepresentable(text))
        XCTAssertNil(try ModelRuntime.validateNativeVisionRequest(text, profile: profile))
        let input = try ModelRuntime.userInput(for: text, nativeVisionProfile: profile)
        XCTAssertTrue(input.images.isEmpty)
    }

    func testReplacementWithdrawsVisionAndRetainsCapturedGeneration() async throws {
        let calls = VisionGenerationCounter()
        let runtime = runtime(profile: profile, calls: calls)
        let handle = try await runtime.acquireRequestHandle(request([try image(red: 1)]))
        await runtime.unregisterInFlight(handle.registrationID)
        let swap = try await runtime.beginSwap(targetModelID: "text-model")
        try await swap.value
        let replaced = await runtime.currentSnapshot()
        XCTAssertEqual(replaced.modelID, "text-model")
        XCTAssertNil(replaced.nativeVisionProfile)
        XCTAssertEqual(handle.snapshot.nativeVisionProfile, profile)
        do {
            _ = try await runtime.acquireRequestHandle(request([try image(red: 1)], model: "text-model"))
            XCTFail("Text replacement retained stale vision capability")
        } catch let error as APIError {
            XCTAssertEqual(error.code, "unsupported_content_shape")
        }
        XCTAssertEqual(calls.value, 0)
    }

    func testPinnedArtifactRejectsLoaderOverrideWithoutReadingWeights() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("override".utf8).write(to: directory.appendingPathComponent("chat_template.jinja"))
        XCTAssertThrowsError(try NativeVisionProfile.load(modelID: NativeVisionProfile.modelID, directory: directory, artifactSHA256: nil)) {
            XCTAssertEqual(($0 as? APIError)?.code, "vision_artifact_identity_mismatch")
        }
        XCTAssertNil(try NativeVisionProfile.load(modelID: "text-model", directory: directory, artifactSHA256: nil))
    }
}

private final class VisionGenerationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
}
