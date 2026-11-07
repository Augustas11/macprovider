import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

/// SPEC-036 FR-26: the scorer-only reference mode is a strict boolean from
/// YAML `compute_score_reference` or `MACPROVIDER_COMPUTE_SCORE_REFERENCE`.
final class ComputeScoreReferenceConfigTests: XCTestCase {
    private func load(yaml: String?, environment: [String: String] = [:]) throws -> AppConfig {
        try ConfigLoader.load(
            cli: CLIOverrides(),
            environment: environment,
            fileExists: { _ in yaml != nil },
            readFile: { _ in yaml ?? "" }
        )
    }

    func testDefaultsOff() throws {
        XCTAssertFalse(try load(yaml: nil).computeScoreReference)
        XCTAssertFalse(AppConfig.defaults().computeScoreReference)
    }

    func testYAMLAndEnvironmentEnable() throws {
        XCTAssertTrue(try load(yaml: "compute_score_reference: true\n").computeScoreReference)
        XCTAssertTrue(try load(yaml: nil, environment: ["MACPROVIDER_COMPUTE_SCORE_REFERENCE": "true"]).computeScoreReference)
        // The environment overrides YAML.
        XCTAssertFalse(try load(
            yaml: "compute_score_reference: true\n",
            environment: ["MACPROVIDER_COMPUTE_SCORE_REFERENCE": "false"]
        ).computeScoreReference)
    }

    func testRejectsNonBooleanValues() {
        for yaml in ["compute_score_reference: maybe\n", "compute_score_reference: 2\n", "compute_score_reference: [true]\n"] {
            XCTAssertThrowsError(try load(yaml: yaml), yaml) { error in
                XCTAssertTrue(String(describing: error).contains("compute_score_reference"), String(describing: error))
            }
        }
        XCTAssertThrowsError(try load(yaml: nil, environment: ["MACPROVIDER_COMPUTE_SCORE_REFERENCE": "sometimes"])) { error in
            XCTAssertTrue(String(describing: error).contains("MACPROVIDER_COMPUTE_SCORE_REFERENCE"), String(describing: error))
        }
    }

    func testRejectsEndpointAndNonTunneledMode() {
        for yaml in [
            "compute_score_reference: true\nendpoint_url: http://127.0.0.1:11434\n",
            "compute_score_reference: true\nws_tunneled_mode: false\n",
        ] {
            XCTAssertThrowsError(try load(yaml: yaml), yaml) { error in
                XCTAssertTrue(String(describing: error).contains("compute_score_reference"), String(describing: error))
            }
        }
        XCTAssertThrowsError(try load(
            yaml: "compute_score_reference: true\n",
            environment: ["MACPROVIDER_ENDPOINT_URL": "http://127.0.0.1:11434"]
        ))
        XCTAssertTrue(try load(yaml: "compute_score_reference: true\nws_tunneled_mode: true\n").computeScoreReference)
        XCTAssertNoThrow(try load(yaml: "endpoint_url: http://127.0.0.1:11434\n"))
    }

    func testCapabilityNames() {
        XCTAssertEqual(ComputeScoreProtocol.capability, "compute_score_v1")
        XCTAssertEqual(ComputeScoreProtocol.referenceCapability, "compute_score_reference")
    }
}
