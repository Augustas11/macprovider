import Foundation
@testable import malibu_cli
import XCTest

/// SPEC-037 HIGH-8: the KV envelope's pinned dependency revisions MUST be the REAL
/// resolved pins, not fabricated strings. This test parses Package.resolved at test
/// time and fails CI if `KVBuildIdentity`'s hardcoded constants drift from the
/// resolved pins — so a dependency bump forces an explicit constant update (which,
/// by design, invalidates all prior on-disk ciphertext).
final class KVBuildIdentityDriftTests: XCTestCase {

    /// Locate Package.resolved from this test file's path (…/phase3-binary/Tests/
    /// malibu-cliTests/<this>.swift → …/phase3-binary/Package.resolved).
    private func packageResolvedURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // malibu-cliTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // phase3-binary
            .appendingPathComponent("Package.resolved")
    }

    private struct Pin {
        let revision: String?
        let version: String?
    }

    private func pins() throws -> [String: Pin] {
        let url = packageResolvedURL()
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawPins = root["pins"] as? [[String: Any]] else {
            throw XCTSkip("Package.resolved not parseable at \(url.path)")
        }
        var out: [String: Pin] = [:]
        for pin in rawPins {
            guard let identity = pin["identity"] as? String else { continue }
            let state = pin["state"] as? [String: Any]
            out[identity] = Pin(revision: state?["revision"] as? String,
                                version: state?["version"] as? String)
        }
        return out
    }

    func testMLXSwiftLMRevisionMatchesPackageResolved() throws {
        let resolved = try pins()
        let pin = try XCTUnwrap(resolved["mlx-swift-lm"], "mlx-swift-lm not pinned in Package.resolved")
        XCTAssertEqual(
            KVBuildIdentity.mlxSwiftLMRevision, pin.revision,
            "KVBuildIdentity.mlxSwiftLMRevision drifted from Package.resolved — bump the constant on a dependency change")
    }

    func testMLXSwiftVersionMatchesPackageResolved() throws {
        let resolved = try pins()
        let pin = try XCTUnwrap(resolved["mlx-swift"], "mlx-swift not pinned in Package.resolved")
        XCTAssertEqual(
            KVBuildIdentity.mlxVersion, pin.version,
            "KVBuildIdentity.mlxVersion drifted from Package.resolved — bump the constant on a dependency change")
    }
}
