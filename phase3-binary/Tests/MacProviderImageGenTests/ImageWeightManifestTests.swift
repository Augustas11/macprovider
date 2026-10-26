import CryptoKit
import Foundation
import XCTest
@testable import MacProviderImageGen

final class ImageWeightManifestTests: XCTestCase {
    func testManifestPinsFP16FilesAndRevision() {
        XCTAssertEqual(SDXLTurboManifest.revision.count, 40)
        XCTAssertEqual(SDXLTurboManifest.files.count, 13)
        XCTAssertEqual(Set(SDXLTurboManifest.files.map(\.path)).count, 13)
        XCTAssertGreaterThan(SDXLTurboManifest.totalBytes, 6_000_000_000)
        XCTAssertLessThan(SDXLTurboManifest.totalBytes, 7_000_000_000)
        for file in SDXLTurboManifest.files {
            XCTAssertEqual(file.sha256.count, 64)
            XCTAssertNotNil(file.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression))
            XCTAssertGreaterThan(file.size, 0)
            if file.path.hasSuffix(".safetensors") {
                XCTAssertTrue(file.path.hasSuffix(".fp16.safetensors"))
            }
        }
    }

    func testVerifiedFixtureAcceptedAndBadHashRejected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture")
        let data = Data("image-model-fixture".utf8)
        try data.write(to: url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertNoThrow(try ImageWeightFile(path: "fixture", size: Int64(data.count), sha256: digest).verify(at: url))
        XCTAssertThrowsError(try ImageWeightFile(path: "fixture", size: Int64(data.count), sha256: String(repeating: "0", count: 64)).verify(at: url))
    }

    func testWrongSizeAndSymlinkRejected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture")
        let link = directory.appendingPathComponent("link")
        try Data([1, 2, 3]).write(to: url)
        let file = ImageWeightFile(path: "fixture", size: 4, sha256: String(repeating: "0", count: 64))
        XCTAssertThrowsError(try file.verify(at: url))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        XCTAssertThrowsError(try file.verify(at: link))
    }

    func testLongPromptFitsCLIPPositionsAndPreservesEOS() {
        let tokenizer = CLIPTokenizer(merges: [], vocabulary: [
            "<|startoftext|>": 0, "<|endoftext|>": 2, "a</w>": 1,
        ])
        let tokens = tokenizer.tokenize(text: String(repeating: "a ", count: 400))
        XCTAssertEqual(tokens.count, 77)
        XCTAssertEqual(tokens.first, 0)
        XCTAssertEqual(tokens.last, 2)
        XCTAssertEqual(tokenizer.tokenize(text: "a"), [0, 1, 2])
    }

    func testBackendValidationWithoutLoadingWeights() async throws {
        let backend = SDXLTurboBackend(modelDirectory: FileManager.default.temporaryDirectory)
        do {
            _ = try await backend.generate(prompt: "", size: 512, steps: 4, seed: 0)
            XCTFail("Empty prompt should fail")
        } catch ImageRuntimeError.invalidRequest { }
        do {
            _ = try await backend.generate(prompt: "a cloud", size: 512, steps: 4, seed: 0)
            XCTFail("Unloaded model should fail")
        } catch ImageRuntimeError.notLoaded { }
        await backend.unload()
    }
}
