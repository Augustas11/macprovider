import Foundation
@testable import MacProviderCore
@testable import macprovider_cli
import XCTest

final class DeepseekV4PoolAdmissionTests: XCTestCase {
    private let config = PagedKVConfig(enabled: true, blockSizeTokens: 32, maxPhysicalBlocks: 64)
    private let identity = "deepseek/deepseek-v4-flash"
    private let modelSHA = String(repeating: "d", count: 64)

    private var capabilities: PagedKVRuntimeModelCapabilities {
        PagedKVRuntimeModelCapabilities(
            modelFamily: "deepseek_v4", requiresMoEDispatch: true,
            hybridDecoderArchitectureVerified: true,
            deepseekV4Pool: DeepseekV4PoolLayout(config: [
                "model_type": "deepseek_v4", "num_hidden_layers": 3,
                "compress_ratios": [0, 4, 128], "sliding_window": 128
            ])
        )
    }

    private var environment: PagedKVRuntimeMeasurementEnvironment {
        PagedKVRuntimeMeasurementEnvironment(
            metallibCandidatePaths: { ["/fixture/default.metallib"] },
            fileExists: { _ in true }, readFileData: { _ in Data("fixture".utf8) },
            hardwareFingerprint: {
                MachineFingerprint(ramGB: 64, chip: "Apple M-test", osVersion: "test", binaryVersion: "test")
            },
            // A row-pool identity must not reuse the paged gather identity.
            registeredKernelIdentifier: { "fixture-paged-gather" }
        )
    }

    private func proof(exact: Bool = true, ragged: Bool = true, membership: Bool = true,
                       topology: Bool = true, tokens: Int = 48) -> DeepseekV4RowPoolParityProof {
        DeepseekV4RowPoolParityProof(
            layerCount: 3, tokensPerRow: tokens, exactParity: exact,
            raggedOffsets: ragged, membershipTransitionParity: membership, topologyVerified: topology
        )
    }

    private func parity(_ proof: DeepseekV4RowPoolParityProof?) -> PagedKVRuntimeParityProbeResult {
        PagedKVRuntimeParityProbeResult(
            established: true, nLayers: 3, nNew: 48, gatherKernelCalls: 0,
            maxLogicalBlocks: 0, nonIdentityPermutation: false, rowPoolProof: proof
        )
    }

    private var isolation: PagedKVRuntimeMoEProbeResult {
        PagedKVRuntimeMoEProbeResult(
            proven: true, rowsDecodedInSharedForward: 2, rowFailures: 0, crossRowDivergences: 0,
            sharedForwardParityProven: true, parityTokensCompared: 48, challengeDistinguishing: true
        )
    }

    private func measure(_ parity: PagedKVRuntimeParityProbeResult,
                         capabilities: PagedKVRuntimeModelCapabilities? = nil,
                         isolation: PagedKVRuntimeMoEProbeResult? = nil) -> PagedKVRuntimeMeasurement? {
        ModelRuntime.measurePagedKVRuntime(
            config: config, modelID: identity, modelSHA256: modelSHA,
            tokenizerSHA256: nil, chatTemplateSHA256: nil,
            modelCapabilities: capabilities ?? self.capabilities, parityProbe: parity,
            moeProbe: isolation ?? self.isolation, environment: environment
        )
    }

    func testDeepseekV4PoolProofRequiresExactRaggedMembershipAndTopology() {
        for invalid in [proof(exact: false), proof(ragged: false), proof(membership: false),
                        proof(topology: false), proof(tokens: 47)] {
            XCTAssertFalse(invalid.established)
            XCTAssertNil(measure(parity(invalid)))
        }
        XCTAssertNil(measure(parity(nil)))
        XCTAssertNotNil(measure(parity(proof())))
    }

    func testDeepseekV4RejectsPagedGatherProofAndUnverifiedArchitecture() {
        let gather = PagedKVRuntimeParityProbeResult(
            established: true, nLayers: 3, nNew: 48, gatherKernelCalls: 288,
            maxLogicalBlocks: 3, nonIdentityPermutation: true
        )
        XCTAssertNil(measure(gather))
        XCTAssertNil(measure(parity(proof()), capabilities: PagedKVRuntimeModelCapabilities(
            modelFamily: "deepseek_v4", requiresMoEDispatch: true
        )))
        XCTAssertNil(measure(parity(proof()), capabilities: PagedKVRuntimeModelCapabilities(
            modelFamily: "deepseek_v4", requiresMoEDispatch: true,
            hybridDecoderArchitectureVerified: true
        )))
        XCTAssertNil(measure(parity(proof()), isolation: .failClosed))
    }

    func testPagedFamilyRejectsRowPoolProof() {
        XCTAssertNil(measure(parity(proof()), capabilities: PagedKVRuntimeModelCapabilities(
            modelFamily: "qwen", requiresMoEDispatch: false
        )))
        XCTAssertNotEqual(ModelRuntime.pagedKVParityLabelSuffix(modelFamily: "deepseek_v4"),
                          ModelRuntime.pagedKVParityLabelSuffix(modelFamily: "glm5_next"))
    }

    func testDeepseekV4DescriptorBindsDistinctRowPoolIdentityAndFailsClosedOnTopology() throws {
        let measurement = try XCTUnwrap(measure(parity(proof())))
        let observed = measurement.observedRuntimeIdentity
        XCTAssertEqual(observed.kernelIdentifier, PagedKVAttachGate.deepseekV4RowPoolBridgeIdentifier)
        let gates = PagedKVGates(
            identityAvailable: true, observedHardwareClass: observed.hardwareClass,
            metallibAvailable: true, kernelRegistered: true, parityEstablished: true,
            hardwareSizingProof: measurement.hardwareSizingProof,
            observedMetallibSHA256: observed.metallibSHA256,
            observedKernelIdentifier: observed.kernelIdentifier, observedParityLabel: observed.parityLabel,
            moeDispatchProven: true, engineBridgeAvailable: true, observedRuntimeIdentity: observed
        )
        let attached = ModelRuntime.pagedKVAttachDecision(
            config: config, modelID: identity, modelHash: modelSHA,
            tokenizerSHA256: nil, chatTemplateSHA256: nil, kvBitsOverride: nil,
            runtimeCacheClass: "mixed", gates: gates, modelCapabilities: capabilities
        )
        XCTAssertNotNil(attached.descriptor)
        let unverified = ModelRuntime.pagedKVAttachDecision(
            config: config, modelID: identity, modelHash: modelSHA,
            tokenizerSHA256: nil, chatTemplateSHA256: nil, kvBitsOverride: nil,
            runtimeCacheClass: "mixed", gates: gates,
            modelCapabilities: PagedKVRuntimeModelCapabilities(modelFamily: "deepseek_v4", requiresMoEDispatch: true)
        )
        XCTAssertNil(unverified.descriptor)
    }
}
