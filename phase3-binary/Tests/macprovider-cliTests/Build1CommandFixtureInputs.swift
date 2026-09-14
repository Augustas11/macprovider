import CryptoKit
import Foundation
@testable import macprovider_cli

/// Disposable, genuinely signed static inputs for deterministic command tests.
/// No private key is persisted; public provenance and signed bytes survive restart.
struct Build1CommandFixtureInputs {
    static let signer = "build1-command-fixture"
    let directory: URL
    let catalogKey: String
    let candidateSHA256: String
    let generatedAt: String
    let publicKeyBase64: String
    let rateVersion: String

    init(existingDirectory: URL, catalogKey: String) throws {
        directory = existingDirectory
        self.catalogKey = catalogKey
        let candidate = try Data(contentsOf: directory.appendingPathComponent("autotune-candidates"))
        candidateSHA256 = AutotuneStaticInputs.candidateCatalogSHA256(bytes: candidate)
        let object = try JSONSerialization.jsonObject(with: candidate) as! [String: Any]
        generatedAt = object["generated_at"] as! String
        publicKeyBase64 = try String(contentsOf: directory.appendingPathComponent("public-key.base64"), encoding: .utf8)
        rateVersion = try AutotuneStaticInputs.decodeRateCard(Data(contentsOf: directory.appendingPathComponent("rate-card"))).version
    }

    init(directory: URL, catalogKey: String, modelID: String, artifactSHA256: String,
         minRAMGB: Int = 1, generatedAt: String = ISO8601DateFormatter().string(from: Date())) throws {
        self.directory = directory
        self.catalogKey = catalogKey
        self.generatedAt = generatedAt
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let corpusURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/tests/fixtures/artifact_feed_conformance.json")
        let corpus = try JSONSerialization.jsonObject(with: Data(contentsOf: corpusURL)) as! [String: Any]
        var candidate = corpus["candidate"] as! [String: Any]
        var row = (candidate["rows"] as! [String: [String: Any]])["test-model"]!
        row["model_id"] = modelID
        row["model_sha256"] = artifactSHA256
        row["min_ram_gb"] = minRAMGB
        candidate["rows"] = [catalogKey: row]
        candidate["version"] = "test-catalog"
        candidate["generated_at"] = generatedAt
        let candidateBytes = try Self.encode(candidate)
        candidateSHA256 = AutotuneStaticInputs.candidateCatalogSHA256(bytes: candidateBytes)
        var artifact = corpus["feed"] as! [String: Any]
        var artifactModel = (artifact["models"] as! [String: [String: Any]])["test-model"]!
        var artifactRow = (artifactModel["artifacts"] as! [String: [String: Any]])["mlx-4bit"]!
        artifactRow["hash"] = artifactSHA256
        artifactRow["size_bytes"] = 1024
        artifactRow["min_ram_gb"] = minRAMGB
        var source = artifactRow["source_ref"] as! [String: Any]
        source["repo_id"] = modelID
        artifactRow["source_ref"] = source
        artifactModel["artifacts"] = ["mlx-4bit": artifactRow]
        artifact["models"] = [catalogKey: artifactModel]
        artifact["version"] = "test-catalog"
        artifact["release_id"] = "test-catalog"
        artifact["generated_at"] = generatedAt
        artifact["candidate_catalog_sha256"] = candidateSHA256
        var demand = try JSONSerialization.jsonObject(with: Data(AutotuneStaticInputs.bakedDemandRankJSON.utf8)) as! [String: Any]
        demand["version"] = "test-catalog"
        demand["generated_at"] = generatedAt
        // A custom fixture key needs a genuinely signed recommendable demand
        // row as well as candidate/artifact/rate rows. Preserve existing keys.
        var demandRows = demand["rows"] as! [String: Any]
        if demandRows[catalogKey] == nil {
            demandRows[catalogKey] = demandRows["qwen3-coder-30b-a3b-instruct"]!
            demand["rows"] = demandRows
        }
        var rate = try JSONSerialization.jsonObject(with: Data(AutotuneStaticInputs.bakedRateCardJSON.utf8)) as! [String: Any]
        rate["version"] = "test-catalog"
        rate["generated_at"] = generatedAt
        var rateRows = rate["rows"] as! [String: Any]
        rateRows[catalogKey] = rateRows["default"]
        rate["rows"] = rateRows
        rateVersion = try JSONDecoder().decode(RateCardProjection.self, from: Self.encode(rate)).projectionHash
        rate["version"] = rateVersion
        let key = Curve25519.Signing.PrivateKey()
        publicKeyBase64 = key.publicKey.rawRepresentation.base64EncodedString()
        try Data(publicKeyBase64.utf8)
            .write(to: directory.appendingPathComponent("public-key.base64"))
        for (name, bytes) in [("autotune-candidates", candidateBytes),
                              ("demand-rank", try Self.encode(demand)),
                              ("rate-card", try Self.encode(rate)),
                              ("catalog-artifacts", try Self.encode(artifact))] {
            try bytes.write(to: directory.appendingPathComponent(name))
            let sidecar = try Self.encode(["key_id": Self.signer, "alg": "ed25519",
                                           "signature": try key.signature(for: bytes).base64EncodedString()])
            try sidecar.write(to: directory.appendingPathComponent(name + ".sig"))
        }
    }

    func loader(includeBakedArtifact: Bool = true) -> AutotuneStaticInputs {
        let directory = directory
        let key = publicKeyBase64
        return AutotuneStaticInputs(fetch: { url in
            let allowed = ["autotune-candidates", "demand-rank", "rate-card", "catalog-artifacts"]
            let name = url.lastPathComponent
            guard allowed.contains(name) || allowed.contains(String(name.dropLast(4))) && name.hasSuffix(".sig") else {
                throw URLError(.unsupportedURL)
            }
            return try Data(contentsOf: directory.appendingPathComponent(name))
        }, trustedPublicKeys: [Self.signer: key],
           bakedArtifactFeed: includeBakedArtifact ? try? Data(contentsOf: directory.appendingPathComponent("catalog-artifacts")) : nil,
           bakedArtifactFeedSignerKeyID: includeBakedArtifact ? Self.signer : nil)
    }

    private static func encode(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
