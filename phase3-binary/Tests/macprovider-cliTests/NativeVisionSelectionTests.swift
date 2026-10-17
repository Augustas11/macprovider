import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

/// #2016: a catalog-bound provider serves Qwen2-VL under the normalized rate-card
/// key; the verified catalog model id selects the vision profile, the per-file
/// pins stay the gate, and a vision runtime never attaches paged KV.
final class NativeVisionSelectionTests: XCTestCase {
    private let servedKey = "qwen2-vl-2b-instruct"
    private let artifactHash = String(repeating: "a", count: 64)
    private let weights = String(repeating: "b", count: 64)

    func testServedHFIDSelectsProfileDirectly() {
        XCTAssertEqual(NativeVisionProfile.selectionModelID(
            servedModelID: NativeVisionProfile.modelID, configuredModelID: nil, verifiedCatalogModelID: nil
        ), NativeVisionProfile.modelID)
    }

    func testConfiguredServedKeySelectsProfileByVerifiedCatalogModelID() {
        XCTAssertEqual(NativeVisionProfile.selectionModelID(
            servedModelID: servedKey, configuredModelID: servedKey,
            verifiedCatalogModelID: NativeVisionProfile.modelID
        ), NativeVisionProfile.modelID)
    }

    func testServedKeyWithoutVerifiedCatalogBindingOrAfterSwapDoesNotSelect() {
        // No verified catalog binding (ModelRuntime passes nil without model_artifact_sha256).
        XCTAssertNil(NativeVisionProfile.selectionModelID(
            servedModelID: servedKey, configuredModelID: servedKey, verifiedCatalogModelID: nil))
        // The catalog id binds only the configured model, never a warm-swap target.
        XCTAssertNil(NativeVisionProfile.selectionModelID(
            servedModelID: "other-model", configuredModelID: servedKey,
            verifiedCatalogModelID: NativeVisionProfile.modelID))
        XCTAssertNil(NativeVisionProfile.selectionModelID(
            servedModelID: nil, configuredModelID: nil, verifiedCatalogModelID: NativeVisionProfile.modelID))
    }

    func testLookalikeIdentitiesDoNotSelect() {
        for lookalike in [servedKey, NativeVisionProfile.modelID + "-evil",
                          "mlx-community/Qwen2-VL-7B-Instruct-4bit", " " + NativeVisionProfile.modelID] {
            XCTAssertNil(NativeVisionProfile.selectionModelID(
                servedModelID: lookalike, configuredModelID: lookalike, verifiedCatalogModelID: nil), lookalike)
            XCTAssertNil(NativeVisionProfile.selectionModelID(
                servedModelID: servedKey, configuredModelID: servedKey, verifiedCatalogModelID: lookalike), lookalike)
        }
    }

    func testSelectedIdentityStillRequiresPinnedArtifactBytes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-vision-selection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in NativeVisionProfile.artifactFileSHA256.keys {
            try Data("not the pinned bytes".utf8).write(to: directory.appendingPathComponent(name))
        }
        let selected = NativeVisionProfile.selectionModelID(
            servedModelID: servedKey, configuredModelID: servedKey,
            verifiedCatalogModelID: NativeVisionProfile.modelID)
        XCTAssertThrowsError(try NativeVisionProfile.load(
            modelID: selected, directory: directory, artifactSHA256: nil)) { error in
            XCTAssertEqual((error as? APIError)?.code, "vision_artifact_identity_mismatch")
        }
        // Not selected: no profile, and the directory is never inspected.
        XCTAssertNil(try NativeVisionProfile.load(
            modelID: NativeVisionProfile.selectionModelID(
                servedModelID: servedKey, configuredModelID: servedKey, verifiedCatalogModelID: nil),
            directory: directory, artifactSHA256: nil))
    }

    func testVisionRuntimeSkipsPagedKVAutomatically() {
        let enabled = PagedKVConfig(enabled: true, blockSizeTokens: 16, maxPhysicalBlocks: 8)
        XCTAssertTrue(enabled.effectiveEnabled)
        XCTAssertEqual(ModelRuntime.pagedKVSkipReason(config: enabled, nativeVision: true), "native_vision_profile")
        XCTAssertNil(ModelRuntime.pagedKVSkipReason(config: enabled, nativeVision: false))
        let disabled = PagedKVConfig(enabled: false, blockSizeTokens: 16, maxPhysicalBlocks: 8)
        XCTAssertNil(ModelRuntime.pagedKVSkipReason(config: disabled, nativeVision: true))
    }

    func testBuyerHFModelIDAndLocalServedKeyBothValidate() throws {
        let hfRequest = try request(model: NativeVisionProfile.modelID)
        XCTAssertNoThrow(try hfRequest.validateModelMatches(
            servedKey, aliases: modelIDAliasList(NativeVisionProfile.modelID)))
        XCTAssertThrowsError(try hfRequest.validateModelMatches(servedKey, aliases: []))
        XCTAssertNoThrow(try request(model: servedKey).validateModelMatches(
            servedKey, aliases: modelIDAliasList(NativeVisionProfile.modelID)))
    }

    func testCatalogBoundSnapshotAdvertisesWireHFModelID() throws {
        var message = message(modelID: NativeVisionProfile.modelID)
        CoordinatorClient.appendNativeVisionCapability(
            to: &message, snapshot: snapshot(model: servedKey),
            wireModelID: NativeVisionProfile.modelID, runtimeSource: nil, configuredModelID: servedKey)
        let capabilities = try XCTUnwrap(message["vision_runtime_capabilities"] as? [[String: String]])
        XCTAssertEqual(capabilities.first?["model_id"], NativeVisionProfile.modelID)

        // Served key is not the configured (loaded) model: no wire mapping, no claim.
        var unconfigured = self.message(modelID: NativeVisionProfile.modelID)
        CoordinatorClient.appendNativeVisionCapability(
            to: &unconfigured, snapshot: snapshot(model: servedKey),
            wireModelID: NativeVisionProfile.modelID, runtimeSource: nil, configuredModelID: "other")
        XCTAssertNil(unconfigured["vision_runtime_capabilities"])

        // Wire id that is not the profile's HF id never advertises.
        var keyWire = self.message(modelID: servedKey)
        CoordinatorClient.appendNativeVisionCapability(
            to: &keyWire, snapshot: snapshot(model: servedKey),
            wireModelID: servedKey, runtimeSource: nil, configuredModelID: servedKey)
        XCTAssertNil(keyWire["vision_runtime_capabilities"])
    }

    func testBakedCatalogBindsServedKeyToVisionProfile() throws {
        let rateCard = try AutotuneStaticInputs.decodeRateCard(Data(AutotuneStaticInputs.bakedRateCardJSON.utf8))
        let catalogKey = "mlx-community/qwen2-vl-2b-instruct-4bit"
        let match = try XCTUnwrap(rateCard.rowForRecommendation(modelKey: catalogKey))
        XCTAssertEqual(match.key, servedKey)
        XCTAssertEqual(match.row.promptRatePerMtok, 13_500)
        XCTAssertEqual(match.row.promptCacheHitRatePerMtok, 3_375)
        XCTAssertEqual(match.row.completionRatePerMtok, 27_000)
        let served = rateCard.servedModelKey(modelKey: catalogKey, rateCardKey: match.key)
        XCTAssertEqual(served, servedKey)

        let catalog = try AutotuneStaticInputs.decodeSignedStaticCandidateCatalog(
            Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8))
        let row = try XCTUnwrap(catalog.rows[catalogKey])
        XCTAssertEqual(row.runtimeStatus, "recommendable")
        XCTAssertEqual(row.modelID, NativeVisionProfile.modelID)
        XCTAssertEqual(row.modelRevision, NativeVisionProfile.modelRevision)
        XCTAssertEqual(row.modelSHA256, "5c65f865d25fa86c34bab436334c13307496e0e905cd0a6c8bef33312cc12773")
        XCTAssertEqual(NativeVisionProfile.selectionModelID(
            servedModelID: served, configuredModelID: served, verifiedCatalogModelID: row.modelID
        ), NativeVisionProfile.modelID)
    }

    private func request(model: String) throws -> ChatCompletionRequest {
        try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: [
            "model": model, "messages": [["role": "user", "content": "hi"]], "max_tokens": 8,
        ]))
    }

    private func snapshot(model: String) -> RuntimeSnapshot {
        RuntimeSnapshot(
            state: .ready, container: nil, modelID: model, modelHash: artifactHash,
            modelHashAlgorithm: ModelArtifactIdentity.snapshotManifestV1,
            weightsManifestSHA256: weights,
            nativeVisionProfile: NativeVisionProfile(
                artifactSHA256: artifactHash,
                processorConfigSHA256: String(repeating: "c", count: 64),
                tokenizerConfigSHA256: String(repeating: "d", count: 64),
                chatTemplateSHA256: String(repeating: "e", count: 64)
            )
        )
    }

    private func message(modelID: String) -> [String: Any] {
        ["model_id": modelID, "model_hash": artifactHash,
         "model_hash_algorithm": ModelArtifactIdentity.snapshotManifestV1,
         "weights_manifest_sha256": weights]
    }
}
