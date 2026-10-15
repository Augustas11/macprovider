import Foundation
import XCTest
@testable import macprovider_cli

final class NativeVisionAdvertisementTests: XCTestCase {
    private let hash = String(repeating: "a", count: 64)
    private let weights = String(repeating: "b", count: 64)

    private func snapshot(state: SwapState = .ready, model: String? = NativeVisionProfile.modelID,
                          hasProfile: Bool = true, artifact: String? = nil) -> RuntimeSnapshot {
        RuntimeSnapshot(
            state: state, container: nil, modelID: model, modelHash: hash,
            modelHashAlgorithm: ModelArtifactIdentity.snapshotManifestV1,
            weightsManifestSHA256: weights,
            nativeVisionProfile: hasProfile ? NativeVisionProfile(
                artifactSHA256: artifact ?? hash,
                processorConfigSHA256: String(repeating: "c", count: 64),
                tokenizerConfigSHA256: String(repeating: "d", count: 64),
                chatTemplateSHA256: String(repeating: "e", count: 64)
            ) : nil
        )
    }

    private func message() -> [String: Any] {
        ["model_id": NativeVisionProfile.modelID, "model_hash": hash,
         "model_hash_algorithm": ModelArtifactIdentity.snapshotManifestV1,
         "weights_manifest_sha256": weights]
    }

    func testExactLoadedSnapshotAdvertisesImplementationWithoutQualificationClaim() throws {
        var message = message()
        CoordinatorClient.appendNativeVisionCapability(to: &message, snapshot: snapshot(),
            wireModelID: NativeVisionProfile.modelID, runtimeSource: nil)
        let capabilities = try XCTUnwrap(message["vision_runtime_capabilities"] as? [[String: String]])
        XCTAssertEqual(capabilities.count, 1)
        XCTAssertEqual(capabilities[0]["model_hash"], hash)
        XCTAssertEqual(capabilities[0]["media_profile"], "qwen2vl-inline-v1")
        XCTAssertEqual(capabilities[0]["runtime_revision"], KVBuildIdentity.mlxSwiftLMRevision)
        XCTAssertNil(capabilities[0]["qualification_digest"])
        XCTAssertEqual(capabilities[0].count, 8)
    }

    func testMissingOrChangedIdentityAndExternalRuntimeWithdrawCapability() {
        for runtimeSnapshot in [snapshot(hasProfile: false), snapshot(state: .loading),
                                snapshot(model: "other"), snapshot(artifact: String(repeating: "f", count: 64))] {
            var message = message()
            message["vision_runtime_capabilities"] = [["stale": "claim"]]
            CoordinatorClient.appendNativeVisionCapability(to: &message, snapshot: runtimeSnapshot,
                wireModelID: NativeVisionProfile.modelID, runtimeSource: nil)
            XCTAssertNil(message["vision_runtime_capabilities"])
        }
        var external = message()
        CoordinatorClient.appendNativeVisionCapability(to: &external, snapshot: snapshot(),
            wireModelID: NativeVisionProfile.modelID, runtimeSource: "lm_studio")
        XCTAssertNil(external["vision_runtime_capabilities"])
        for key in ["model_id", "model_hash", "model_hash_algorithm", "weights_manifest_sha256"] {
            var changed = message()
            changed[key] = "changed-after-snapshot"
            CoordinatorClient.appendNativeVisionCapability(to: &changed, snapshot: snapshot(),
                wireModelID: NativeVisionProfile.modelID, runtimeSource: nil)
            XCTAssertNil(changed["vision_runtime_capabilities"], key)
        }
    }
}
