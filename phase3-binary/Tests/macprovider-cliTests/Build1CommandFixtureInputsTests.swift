import CryptoKit
import Foundation
import XCTest
@testable import macprovider_cli

final class Build1CommandFixtureInputsTests: XCTestCase {
    func testSignedFixturePassesRealLoaderAndArtifactAuthority() async throws {
        let fixture = try makeFixture()
        let inputs = await fixture.loader().loadRecommendationInputs()
        XCTAssertFalse(inputs.candidate.usedFallback)
        XCTAssertTrue(inputs.candidate.warnings.isEmpty, "\(inputs.candidate.warnings)")
        XCTAssertTrue(inputs.demand.warnings.isEmpty, "\(inputs.demand.warnings)")
        XCTAssertTrue(inputs.rateCard.warnings.isEmpty, "\(inputs.rateCard.warnings)")
        XCTAssertTrue(inputs.artifactFeed.warnings.isEmpty, "\(inputs.artifactFeed.warnings)")
        XCTAssertNotNil(inputs.artifactFeed.value)
        XCTAssertEqual(inputs.candidate.signerKeyID, Build1CommandFixtureInputs.signer)
        XCTAssertNoThrow(try ModelCatalogTransactionAuthority.resolve(target: fixture.catalogKey, inputs: inputs))
    }

    func testDefaultAndExplicitNilArtifactAuthorityRemainAbsentWithoutArtifactFetch() async throws {
        let production = ModelCommandExecutionContext.production.inputs()
        XCTAssertEqual(production.trustedPublicKeys, AutotuneStaticInputs.defaultTrustedPublicKeys)
        XCTAssertNil(production.verifySignature)
        XCTAssertEqual(production.artifactFeedBakedBytes, AutotuneStaticInputs.bakedArtifactFeedBytes)
        XCTAssertEqual(production.artifactFeedBakedSignerKeyID, AutotuneStaticInputs.bakedArtifactFeedSignerKeyID)
        // This regression deliberately binds the present shipping nil gate.
        XCTAssertNil(production.artifactFeedBakedBytes)
        let fixture = try makeFixture()
        var loader = fixture.loader(includeBakedArtifact: false)
        let fetch = loader.fetch
        var artifactFetches = 0
        loader.fetch = { url in
            if url.lastPathComponent.hasPrefix("catalog-artifacts") { artifactFetches += 1 }
            return try await fetch(url)
        }
        let absent = await loader.loadRecommendationInputs()
        XCTAssertNil(absent.artifactFeed.value)
        XCTAssertEqual(artifactFetches, 0)
        let excluded = await fixture.loader().loadRecommendationInputs(includeArtifactFeed: false)
        XCTAssertNil(excluded.artifactFeed.value)
        XCTAssertTrue(excluded.artifactFeed.selectedBytes.isEmpty)
    }

    func testWrongSignerAndCrossReleaseRejectArtifactAuthority() async throws {
        for scenario in ["wrong_signer", "cross_release"] {
            let fixture = try makeFixture()
            let key = Curve25519.Signing.PrivateKey()
            let signer = scenario == "wrong_signer" ? "different-fixture-signer" : Build1CommandFixtureInputs.signer
            if scenario == "cross_release" {
                let path = fixture.directory.appendingPathComponent("catalog-artifacts")
                var feed = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
                feed["release_id"] = "different-release"
                feed["version"] = "different-release"
                try JSONSerialization.data(withJSONObject: feed, options: [.sortedKeys]).write(to: path)
            }
            let names = scenario == "wrong_signer" ? ["catalog-artifacts"] :
                ["catalog-artifacts", "autotune-candidates", "rate-card", "demand-rank"]
            for name in names {
                let bytes = try Data(contentsOf: fixture.directory.appendingPathComponent(name))
                let sidecar: [String: String] = ["key_id": signer, "alg": "ed25519",
                    "signature": try key.signature(for: bytes).base64EncodedString()]
                try JSONSerialization.data(withJSONObject: sidecar).write(to: fixture.directory.appendingPathComponent(name + ".sig"))
            }
            var loader = fixture.loader()
            loader.trustedPublicKeys[signer] = key.publicKey.rawRepresentation.base64EncodedString()
            let inputs = await loader.loadRecommendationInputs()
            XCTAssertTrue(inputs.candidate.warnings.isEmpty, scenario)
            XCTAssertNil(inputs.artifactFeed.value, scenario)
            XCTAssertFalse(inputs.artifactFeed.warnings.isEmpty, scenario)
            XCTAssertThrowsError(try ModelCatalogTransactionAuthority.resolve(target: fixture.catalogKey, inputs: inputs), scenario)
        }
    }

    private func makeFixture() throws -> Build1CommandFixtureInputs {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Build1SignedInputs-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try Build1CommandFixtureInputs(directory: root, catalogKey: "qwen3-coder-30b-a3b-instruct",
            modelID: "mlx-community/Test-Model-4bit", artifactSHA256: String(repeating: "2", count: 64))
    }
}
