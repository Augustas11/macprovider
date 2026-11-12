import CryptoKit
import Foundation
@testable import macprovider_cli
import XCTest

/// SPEC-037 HIGH-8: the KV envelope's tokenizer/template hashes are the REAL live
/// tokenizer-config + chat-template byte hashes, not values derived from the model
/// hash — and are nil (⇒ identity_unavailable ⇒ skip persistence) when unreachable.
final class KVTokenizerIdentityTests: XCTestCase {

    private var tempDirs: [URL] = []

    override func tearDown() {
        for url in tempDirs { try? FileManager.default.removeItem(at: url) }
        tempDirs.removeAll()
        super.tearDown()
    }

    private func makeDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tokid-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tempDirs.append(url)
        return url
    }

    private func write(_ dir: URL, _ name: String, _ contents: String) {
        try? contents.data(using: .utf8)!.write(to: dir.appendingPathComponent(name))
    }

    func testMissingTokenizerFilesYieldNilConfigHash() {
        let dir = makeDir()
        let hashes = ModelRuntime.tokenizerIdentityHashes(in: dir)
        XCTAssertNil(hashes.config, "no tokenizer files ⇒ identity unavailable")
        XCTAssertNil(hashes.template)
    }

    func testConfigHashReflectsLiveBytesAndChangesWithContent() {
        let a = makeDir()
        write(a, "tokenizer_config.json", "{\"a\":1}")
        let b = makeDir()
        write(b, "tokenizer_config.json", "{\"a\":2}")
        let ha = ModelRuntime.tokenizerIdentityHashes(in: a).config
        let hb = ModelRuntime.tokenizerIdentityHashes(in: b).config
        XCTAssertNotNil(ha)
        XCTAssertEqual(ha, ModelRuntime.tokenizerIdentityHashes(in: a).config, "hash must be stable")
        XCTAssertNotEqual(ha, hb, "different tokenizer bytes must yield a different config hash")
    }

    func testTemplateHashFromDedicatedFileAndEmbeddedField() {
        // Dedicated chat template file.
        let a = makeDir()
        write(a, "tokenizer_config.json", "{\"x\":1}")
        write(a, "chat_template.jinja", "{{ messages }}")
        let templateA = ModelRuntime.tokenizerIdentityHashes(in: a).template
        XCTAssertNotNil(templateA, "a dedicated chat template file must produce a template hash")

        // Embedded chat_template field, no dedicated file.
        let b = makeDir()
        write(b, "tokenizer_config.json", "{\"chat_template\":\"{{ messages }}\"}")
        let templateB = ModelRuntime.tokenizerIdentityHashes(in: b).template
        XCTAssertNotNil(templateB, "an embedded chat_template field must produce a template hash")

        // No template anywhere.
        let c = makeDir()
        write(c, "tokenizer_config.json", "{\"y\":1}")
        XCTAssertNil(ModelRuntime.tokenizerIdentityHashes(in: c).template, "no chat template ⇒ nil template hash")
    }

    func testHashesAreNotDerivedFromModelHash() {
        // Two models with identical tokenizer bytes must share the tokenizer hash
        // regardless of any model hash — proving the hash is tokenizer-derived.
        let a = makeDir()
        write(a, "tokenizer.json", "{\"vocab\":true}")
        let b = makeDir()
        write(b, "tokenizer.json", "{\"vocab\":true}")
        XCTAssertEqual(ModelRuntime.tokenizerIdentityHashes(in: a).config,
                       ModelRuntime.tokenizerIdentityHashes(in: b).config,
                       "identical tokenizer bytes ⇒ identical hash (tokenizer-derived, not model-derived)")
    }

    func testDeepseekRequiresItsSupportedReferenceEncoder() throws {
        let dir = makeDir()
        write(dir, "config.json", #"{"model_type":"deepseek_v4"}"#)
        write(dir, "chat_template.jinja", "unrelated template")
        XCTAssertNil(ModelRuntime.tokenizerIdentityHashes(in: dir).template)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("encoding"), withIntermediateDirectories: true)
        write(dir, "encoding/encoding_dsv4.py", "unsupported encoder revision")
        XCTAssertNil(ModelRuntime.tokenizerIdentityHashes(in: dir).template)

        write(dir, "config.json", #"{"model_type":"another_family"}"#)
        XCTAssertNotNil(ModelRuntime.tokenizerIdentityHashes(in: dir).template,
                        "other families retain their existing Jinja identity")
    }

    func testDeepseekArtifactTemplateIdentityUsesRealEncoderBytes() throws {
        guard let path = ProcessInfo.processInfo.environment["DSV4_TOKENIZER_DIR"] else {
            throw XCTSkip("set DSV4_TOKENIZER_DIR for the actual DeepSeek encoder identity check")
        }
        let artifact = URL(fileURLWithPath: path)
        let name = "encoding/encoding_dsv4.py"
        let encoder = try Data(contentsOf: artifact.appendingPathComponent(name))
        func hash(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        XCTAssertEqual(hash(encoder), DeepseekV4Encoding.referenceEncoderSHA256)
        let expected = hash(Data((name + "\u{0}").utf8) + encoder)
        XCTAssertEqual(ModelRuntime.tokenizerIdentityHashes(in: artifact).template, expected)

        let copy = makeDir()
        write(copy, "config.json", #"{"model_type":"deepseek_v4"}"#)
        try FileManager.default.createDirectory(at: copy.appendingPathComponent("encoding"), withIntermediateDirectories: true)
        try encoder.write(to: copy.appendingPathComponent(name))
        XCTAssertEqual(ModelRuntime.tokenizerIdentityHashes(in: copy).template, expected)
        try (encoder + Data([0])).write(to: copy.appendingPathComponent(name))
        XCTAssertNil(ModelRuntime.tokenizerIdentityHashes(in: copy).template,
                     "an encoder revision not implemented by the renderer must fail closed")
    }
}
