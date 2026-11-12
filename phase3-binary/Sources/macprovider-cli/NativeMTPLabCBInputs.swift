import CryptoKit
import Foundation

/// Campaign-specific retained qualification for the isolated native bench.
/// This context is never read by serve or supplied through provider config.
struct NativeMTPLabCBInputs {
    static let throughputSHA = "18401ac67846cabf1d669a44c6b6c7a24e0afc9a7728918aea7605e9789d6cf4"
    static let paritySHA = "3192fedb46677e357d9983de532e948ec85501313af03842c923223446a68995"
    static let originalIdentitySHA = "a79326e3800cc893c3f17ff0f49d0cf4ef5b5accc304a91a06e38fa602f7b4fa"
    let directory: URL
    let providerCommit: String

    static func requireInputs(_ inputs: Self?, deepseek: Bool) throws {
        if deepseek && inputs == nil {
            throw NativeMTPBenchError.assertionFailed("DeepSeek native bench requires --lab-cb-inputs retained qualification")
        }
    }

    func load(tuple: ContinuousBatchingRequestedTuple, slots: Int) async throws -> ContinuousBatchingPolicyLoadResult {
        #if DEBUG || MACPROVIDER_LAB_HARNESS
        try Self.requireScope(labHarnessBuild: true, fixtureHooksPermitted: NativeMTPQualificationScope.permitsFixtureHooks)
        func read(_ name: String, sha expected: String? = nil) throws -> Data {
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            guard data.count <= 8 * 1024 * 1024, expected.map({ Self.sha(data) == $0 }) ?? true else {
                throw NativeMTPBenchError.assertionFailed("retained CB input digest mismatch: \(name)")
            }
            return data
        }
        // These immutable records passed the operator-amended >=1.8x gate.
        // Verify their exact bytes; never create a fresh benchmark here.
        _ = try read("throughput-r4.json", sha: Self.throughputSHA)
        _ = try read("parity-r4.json", sha: Self.paritySHA)
        _ = try read("original-identity.json", sha: Self.originalIdentitySHA)
        let package = try read("qualification.json")
        guard let binding = try JSONSerialization.jsonObject(with: package) as? [String: Any],
              binding["schema"] as? String == "macprovider.2151-retained-cb-lab-rebind.v1",
              binding["operator_authorized_identity_rebind"] as? Bool == true,
              binding["provider_commit"] as? String == providerCommit,
              binding["fork_revision"] as? String == KVBuildIdentity.mlxSwiftLMRevision,
              binding["decode_path_digest"] as? String == DecodePathIdentity.digest,
              binding["throughput_sha256"] as? String == Self.throughputSHA,
              binding["parity_sha256"] as? String == Self.paritySHA,
              binding["original_identity_sha256"] as? String == Self.originalIdentitySHA,
              let executable = Bundle.main.executableURL,
              binding["binary_sha256"] as? String == Self.sha(try Data(contentsOf: executable)),
              tuple.modelID == "deepseek/deepseek-v4-flash", (1...4).contains(slots)
        else { throw NativeMTPBenchError.assertionFailed("retained CB authorized identity rebind mismatch") }
        let cdhash = PrivacyCodeSignature.readSelf().cdhashHex
        guard cdhash.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else {
            throw NativeMTPBenchError.assertionFailed("lab CB executable CDHash unavailable")
        }
        let signer = Curve25519.Signing.PrivateKey() // Never serialized or written.
        let keyID = "native-mtp-retained-cb-lab-2151"
        let publicKey = signer.publicKey.rawRepresentation.base64EncodedString()
        let catalog = Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8)
        let value = try AutotuneStaticInputs.decodeCandidateCatalog(catalog)
        let catalogSHA = Self.sha(catalog)
        guard let catalogObject = try JSONSerialization.jsonObject(with: catalog) as? [String: Any],
              let generated = catalogObject["generated_at"] as? String,
              let tokenizerSHA = tuple.tokenizerSHA256, let templateSHA = tuple.chatTemplateSHA256 else {
            throw NativeMTPBenchError.assertionFailed("lab CB catalog timestamp or actual tokenizer/template identity missing")
        }
        // Structural schema field only; no timed feature withdrawal is added.
        let expires = "9999-12-31T23:59:59Z"
        var entry: [String: Any] = [
            "model_key": tuple.modelID, "model_id": tuple.modelID, "model_sha256": tuple.modelSHA256,
            "tokenizer_sha256": tokenizerSHA,
            "chat_template_sha256": templateSHA,
            "cache_class": tuple.cacheClass, "kv_dtype": tuple.kvDType.rawValue,
            "requires_moe": tuple.requiresMoE, "hardware_class": tuple.hardwareClass,
            "metallib_sha256": tuple.metallibSHA256, "kernel_identifier": tuple.kernelIdentifier,
            "rollout": "on", "cached_turns_accepted": false, "max_served_slots": 4,
            "provenance": ["source": "operator_review", "status": "qualified",
                "evidence_id": "pr2151-retained-qmv-r4-1.872158058822497",
                "package_manifest_sha256": Self.sha(package), "studio_campaign_sha256": Self.throughputSHA,
                "provider_cli_version": CoordinatorClient.binaryVersion, "live_executable_cdhash": cdhash],
        ]
        entry["tuple_sha256"] = try ContinuousBatchingSignedPolicy.tupleSHA256(
            releaseID: value.version, policyVersion: value.policyVersion, generatedAt: generated,
            expiresAt: expires, candidateCatalogSHA256: catalogSHA, signerKeyID: keyID, entry: entry)
        let policy = try Self.json([
            "schema_version": ContinuousBatchingSignedPolicy.schemaVersion, "release_id": value.version,
            "policy_version": value.policyVersion, "generated_at": generated, "expires_at": expires,
            "candidate_catalog_sha256": catalogSHA, "signer_key_id": keyID, "entries": [entry],
        ])
        func signature(_ data: Data) throws -> Data {
            try Self.json(["key_id": keyID, "alg": "ed25519", "signature": signer.signature(for: data).base64EncodedString()])
        }
        let catalogSignature = try signature(catalog)
        let policySignature = try signature(policy)
        let verified = try await Self.verify(catalog: catalog, catalogSignature: catalogSignature,
            policy: policy, policySignature: policySignature, keyID: keyID, publicKey: publicKey)
        try Self.requireAdmission(verified, tuple: tuple, slots: slots)
        // Retain only public keys, signed payloads and binding receipts.
        let receipt = directory.appendingPathComponent("verified-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: receipt, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        for (name, data) in ["autotune-candidates": catalog, "autotune-candidates.sig": catalogSignature,
                             "continuous-batching-policy": policy, "continuous-batching-policy.sig": policySignature,
                             "public-key.json": try Self.json(["key_id": keyID, "public_key_base64": publicKey]),
                             "qualification.json": package] {
            try data.write(to: receipt.appendingPathComponent(name), options: .withoutOverwriting)
        }
        return verified
        #else
        try Self.requireScope(labHarnessBuild: false, fixtureHooksPermitted: NativeMTPQualificationScope.permitsFixtureHooks)
        throw NativeMTPBenchError.assertionFailed("lab CB inputs require a lab harness build")
        #endif
    }

    static func requireScope(labHarnessBuild: Bool, fixtureHooksPermitted: Bool) throws {
        guard labHarnessBuild && fixtureHooksPermitted else {
            throw NativeMTPBenchError.assertionFailed("isolated lab CB qualification scope required")
        }
    }

    /// Exercise both canonical verifiers, with real Ed25519 verification.
    /// Fetch is a closed byte inventory, never network or a global trust override.
    static func verify(catalog: Data, catalogSignature: Data, policy: Data, policySignature: Data,
                       keyID: String, publicKey: String) async throws -> ContinuousBatchingPolicyLoadResult {
        let files = ["autotune-candidates": catalog, "autotune-candidates.sig": catalogSignature,
                     "continuous-batching-policy": policy, "continuous-batching-policy.sig": policySignature]
        let inputs = AutotuneStaticInputs(fetch: { url in
            guard let data = files[url.lastPathComponent] else {
                throw NativeMTPBenchError.assertionFailed("unexpected lab CB input URL")
            }
            return data
        }, trustedPublicKeys: [keyID: publicKey])
        let selected = await inputs.loadCandidateCatalog()
        guard !selected.usedFallback, selected.signerKeyID == keyID else {
            throw NativeMTPBenchError.assertionFailed("lab CB catalog verification failed")
        }
        let result = await inputs.loadContinuousBatchingPolicy(candidateCatalog: selected)
        guard result.status == .liveVerified, result.signerKeyID == keyID else {
            throw NativeMTPBenchError.assertionFailed("lab CB signed policy verification failed")
        }
        return result
    }

    static func requireAdmission(_ result: ContinuousBatchingPolicyLoadResult,
                                 tuple: ContinuousBatchingRequestedTuple, slots: Int) throws {
        guard result.admitsContinuousBatching(modelFamily: "deepseek_v4", tuple: tuple),
              let entry = result.selection.entries.first(where: { $0.tuple.modelID == tuple.modelID }),
              entry.rollout == .on, entry.maxServedSlots == 4, (1...4).contains(slots),
              entry.tuple.tokenizerSHA256 == tuple.tokenizerSHA256,
              entry.tuple.chatTemplateSHA256 == tuple.chatTemplateSHA256 else {
            throw NativeMTPBenchError.assertionFailed("verified lab CB policy does not admit actual runtime tuple")
        }
    }

    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
