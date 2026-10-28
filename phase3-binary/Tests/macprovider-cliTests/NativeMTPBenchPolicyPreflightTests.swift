#if DEBUG || MACPROVIDER_LAB_HARNESS
import Foundation
import XCTest
import MacProviderCore
@testable import macprovider_cli

/// `native-mtp-bench --validate-policy-only` is the pre-downtime check: every
/// frozen field the bench compares before its first model load must refuse by
/// name, and the cross-process hash cache must give the uncached digest.
final class NativeMTPBenchPolicyPreflightTests: XCTestCase {
    private static let templateURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("docs/research/spec048-r015/policy-template.json")

    private static let swiftStdout = "Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)"

    private func policy(_ edit: (inout [String: Any]) -> Void = { _ in }) throws -> NativeMTPBenchPolicy {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: Self.templateURL)) as? [String: Any]
        )
        object["hw_model"] = "Mac15,14"
        object["chip"] = "Apple M3 Ultra"
        object["ram_gb"] = 256
        object["os_build"] = "26A434"
        object["xcode_build_version"] = "unknown"
        object["swift_version"] = Self.swiftStdout
        object["provider_commit"] = String(repeating: "a", count: 40)
        object["mlx_fork_revision"] = NativeMTPHardwareE2ERunner.upstreamRevision
        edit(&object)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-mtp-preflight-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try NativeMTPBenchPolicy.load(from: url)
    }

    private func environment(
        hwModel: String = "Mac15,14",
        chip: String = "Apple M3 Ultra",
        ramGB: Int = 256,
        osBuild: String = "26A434",
        xcode: String = "unknown",
        swift: String = swiftStdout,
        commit: String = String(repeating: "a", count: 40)
    ) -> NativeMTPBenchEnvironment {
        NativeMTPBenchEnvironment(
            hwModel: hwModel, chip: chip, ramGB: ramGB, osVersion: "Version 27.0.1 (Build 26A434)",
            osBuild: osBuild, xcodeBuildVersion: xcode, swiftVersion: swift, providerCommit: commit
        )
    }

    private func assertRefuses(_ field: String, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), field, file: file, line: line) { error in
            XCTAssertTrue(String(describing: error).contains("\(field) mismatch"), "\(error)", file: file, line: line)
        }
    }

    func testMatchingEnvironmentPasses() throws {
        XCTAssertNoThrow(try policy().validateObserved(environment: environment()))
    }

    func testEveryEnvironmentFieldMismatchRefusesByName() throws {
        let frozen = try policy()
        assertRefuses("hw_model") { try frozen.validateObserved(environment: environment(hwModel: "Mac16,9")) }
        assertRefuses("chip") { try frozen.validateObserved(environment: environment(chip: "Apple M4 Max")) }
        assertRefuses("ram_gb") { try frozen.validateObserved(environment: environment(ramGB: 128)) }
        assertRefuses("os_build") { try frozen.validateObserved(environment: environment(osBuild: "26A435")) }
        assertRefuses("xcode_build_version") { try frozen.validateObserved(environment: environment(xcode: "17A100")) }
        assertRefuses("swift_version") { try frozen.validateObserved(environment: environment(swift: "Apple Swift version 6.3.4")) }
        assertRefuses("provider_commit") {
            try frozen.validateObserved(environment: environment(commit: String(repeating: "b", count: 40)))
        }
        // The runtime revision is compiled in, so the frozen side moves.
        let otherRuntime = try policy { $0["mlx_fork_revision"] = String(repeating: "c", count: 40) }
        assertRefuses("mlx_fork_revision") { try otherRuntime.validateObserved(environment: environment()) }
    }

    /// Window 4 (2026-10-25): a policy frozen from `xcrun swift --version` with
    /// stderr merged carried the driver line; the bench reads stdout only.
    func testStderrMergedSwiftVersionIsRefused() throws {
        let merged = try policy { $0["swift_version"] = "swift-driver version: 1.148.6 " + Self.swiftStdout }
        assertRefuses("swift_version") { try merged.validateObserved(environment: environment()) }
    }

    func testEveryArtifactFieldMismatchRefusesByName() throws {
        let frozen = try policy()
        let target = frozen.targetSHA256, mtp = frozen.mtpSHA256, tokenizer = frozen.tokenizerSHA256
        let other = String(repeating: "f", count: 64)
        XCTAssertNoThrow(try frozen.validateObserved(modelID: frozen.modelID, targetSHA256: target, mtpSHA256: mtp, tokenizerSHA256: tokenizer))
        assertRefuses("model_id") {
            try frozen.validateObserved(modelID: "other/model", targetSHA256: target, mtpSHA256: mtp, tokenizerSHA256: tokenizer)
        }
        assertRefuses("target_sha256") {
            try frozen.validateObserved(modelID: frozen.modelID, targetSHA256: other, mtpSHA256: mtp, tokenizerSHA256: tokenizer)
        }
        assertRefuses("mtp_sha256") {
            try frozen.validateObserved(modelID: frozen.modelID, targetSHA256: target, mtpSHA256: other, tokenizerSHA256: tokenizer)
        }
        assertRefuses("tokenizer_sha256") {
            try frozen.validateObserved(modelID: frozen.modelID, targetSHA256: target, mtpSHA256: mtp, tokenizerSHA256: other)
        }
    }

    /// Window 5 (2026-10-25): the tools/history profile carried a tool_call id
    /// the production parser refuses, found only after the provider was paused.
    func testEveryRequestProfileParsesThroughTheProductionValidator() throws {
        for shape in ["plain_text", "tools_history_reasoning"] {
            for (temperature, topP) in [(0.0, 1.0), (1.0, 0.95)] {
                let request = try NativeMTPBenchRequests.make(
                    modelID: "zai-org/glm-5.3-flash", requestID: "validate", prompt: "p", maxTokens: 128,
                    temperature: temperature, topP: topP, requestShape: shape
                )
                XCTAssertFalse(request.topLevelKeys.contains("chat_template_kwargs"))
                XCTAssertEqual(request.reasoningEffort, shape == "tools_history_reasoning" ? "high" : nil)
            }
        }
        XCTAssertFalse(ChatCompletionRequest.isAcceptedToolCallID("call_baseline_read"))
    }

    func testPersistentHashCacheGivesTheUncachedDigestAndRehashesChangedFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-mtp-preflight-\(UUID().uuidString)", isDirectory: true)
        let snapshot = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{}".utf8).write(to: snapshot.appendingPathComponent("config.json"))
        try Data(repeating: 7, count: 4096).write(to: snapshot.appendingPathComponent("model.safetensors"))
        let store = root.appendingPathComponent("cache/identity-cache.json")

        let uncached = try MLXSnapshotIdentity.compute(directory: snapshot).digest
        XCTAssertEqual(try NativeMTPBenchIdentityCache(persistentURL: store).identity(directory: snapshot).digest, uncached)
        let entries = try JSONDecoder().decode([String: [NativeMTPBenchIdentityCache.Entry]].self, from: Data(contentsOf: store))
        XCTAssertEqual(entries.values.first?.count, 2)

        // A later process reuses a stored hash only for an identical stamp:
        // plant a wrong hash to prove reuse, then rewrite the file.
        var planted = entries
        let key = try XCTUnwrap(planted.keys.first)
        planted[key] = planted[key]!.map {
            $0.stamp.relativePath == "model.safetensors"
                ? NativeMTPBenchIdentityCache.Entry(stamp: $0.stamp, sha256: String(repeating: "0", count: 64)) : $0
        }
        try JSONEncoder().encode(planted).write(to: store)
        XCTAssertNotEqual(try NativeMTPBenchIdentityCache(persistentURL: store).identity(directory: snapshot).digest, uncached)

        try Data(repeating: 8, count: 4096).write(to: snapshot.appendingPathComponent("model.safetensors"))
        let rewritten = try MLXSnapshotIdentity.compute(directory: snapshot).digest
        XCTAssertNotEqual(rewritten, uncached)
        XCTAssertEqual(try NativeMTPBenchIdentityCache(persistentURL: store).identity(directory: snapshot).digest, rewritten)

        // A malformed store is an empty one.
        try Data("not json".utf8).write(to: store)
        XCTAssertEqual(try NativeMTPBenchIdentityCache(persistentURL: store).identity(directory: snapshot).digest, rewritten)
    }
}
#endif
