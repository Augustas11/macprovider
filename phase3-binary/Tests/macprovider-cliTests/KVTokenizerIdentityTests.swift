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
}
