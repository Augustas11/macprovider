import ArgumentParser
import Darwin
import Foundation
import XCTest
@testable import macprovider_cli

final class BYOMOfferDryRunTests: XCTestCase {
    func testOfferCommandRequiresDryRunJSONFlags() async throws {
        let command = try ModelsOfferCommand.parse(["ollama:tiny-offer-1b-q4", "--dry-run", "--skip-ollama"])
        let capture = await captureBYOMOfferOutput {
            try await command.run()
        }

        XCTAssertTrue(capture.stdout.isEmpty)
        XCTAssertTrue(capture.stderr.contains("dry-run JSON-only"))
        XCTAssertEqual((capture.error as? ExitCode), ExitCode(2))
    }

    func testOfferDryRunCommandEmitsUnknownWithoutReflectingUnsafeTarget() async throws {
        let root = try temporaryBYOMOfferDirectory("byom-offer-command")
        let unsafeTarget = "http://192.168.1.10:11434/private-model?api_key=secret"
        let command = try ModelsOfferCommand.parse([
            unsafeTarget,
            "--dry-run",
            "--json",
            "--skip-ollama",
            "--local-discovery-namespace-path", root.appendingPathComponent("ns").path,
            "--mlx-cache-dir", root.appendingPathComponent("hf", isDirectory: true).path,
        ])
        let capture = await captureBYOMOfferOutput {
            try await command.run()
        }

        XCTAssertNil(capture.error)
        let object = try jsonObject(capture.stdout)
        XCTAssertEqual(object["schema"] as? String, "model_admission_offer_dry_run.v1")
        XCTAssertEqual(object["candidate_id"] as? String, "unknown")
        XCTAssertEqual(object["served_model_ref"] as? String, "unknown")
        XCTAssertEqual(object["would_submit"] as? Bool, false)
        XCTAssertFalse((capture.stdout + capture.stderr).contains(unsafeTarget))
        XCTAssertFalse((capture.stdout + capture.stderr).contains("api_key"))
    }

    func testOfferDryRunUnknownCandidatePreservesDiscoveryWarnings() async throws {
        let root = try temporaryBYOMOfferDirectory("byom-offer-unknown-warnings")

        let document = await BYOMOfferDryRunRunner(
            target: "missing-model",
            environment: BYOMDiscoveryEnvironment(
                namespaceURL: root.appendingPathComponent("ns"),
                mlxCacheRoot: root.appendingPathComponent("hf", isDirectory: true),
                ollamaOrigin: "http://192.168.1.10:11434"
            ),
            httpClient: BYOMOfferStubHTTPClient(tagsBody: #"{"models":[]}"#)
        ).dryRun()

        XCTAssertEqual(document.candidateID, "unknown")
        XCTAssertEqual(document.servedModelRef, "unknown")
        XCTAssertEqual(document.reasonCode, "candidate_not_found")
        XCTAssertEqual(document.wouldSubmit, false)
        XCTAssertTrue(document.warnings.contains("candidate_id_unstable"))
        XCTAssertTrue(document.warnings.contains("adapter_rejected_non_loopback"))
        XCTAssertTrue(document.warnings.contains("adapter_unavailable"))
        XCTAssertEqual(document.providerGuidance.transitionReasonCode, "candidate_not_found")
    }

    func testOfferDryRunForNonCatalogCandidateDoesNotSubmitAndHasNoEarningPath() async throws {
        let root = try temporaryBYOMOfferDirectory("byom-offer-noncatalog")
        let namespace = root.appendingPathComponent("ns")
        try writeBYOMOfferNamespace(at: namespace)
        let client = BYOMOfferStubHTTPClient(tagsBody: #"{"models":[{"name":"tiny-offer-1b-q4"}]}"#)

        let document = await BYOMOfferDryRunRunner(
            target: "ollama:tiny-offer-1b-q4",
            environment: BYOMDiscoveryEnvironment(
                namespaceURL: namespace,
                mlxCacheRoot: root.appendingPathComponent("hf", isDirectory: true),
                ollamaOrigin: "http://127.0.0.1:11434"
            ),
            httpClient: client
        ).dryRun()

        XCTAssertEqual(document.schema, "model_admission_offer_dry_run.v1")
        XCTAssertEqual(document.servedModelRef, "ollama:tiny-offer-1b-q4")
        XCTAssertNil(document.catalogModelKey)
        // A discoverable, offerable, non-catalog candidate WOULD submit a v0.1
        // non-earning offer (SPEC-047-R002 permits omitting the evaluation
        // digest for offers confined to non-earning states). It is never
        // settlement-capable and never earns.
        XCTAssertEqual(document.wouldSubmit, true)
        XCTAssertEqual(document.likelyAdmissionState, "offerable")
        XCTAssertEqual(document.likelyAdmissionStateSource, "local_default")
        XCTAssertEqual(document.reasonCode, "no_trusted_catalog_match")
        XCTAssertEqual(document.providerGuidance.nextAction, "submit_offer")
        XCTAssertEqual(document.providerGuidance.stateMeaningKey, "byom.offer_dry_run.no_earning_path_v0_1")
        XCTAssertEqual(document.providerGuidance.earningPathClass, "no_earning_path_in_v0_1")
        XCTAssertEqual(client.postCount, 0)   // dry-run NEVER submits, regardless of would_submit

        let encoded = try ModelSwitchingWireCodec.encode(document)
        XCTAssertFalse(encoded.contains("prompt_rate"))
        XCTAssertFalse(encoded.contains("completion_rate"))
        XCTAssertFalse(encoded.contains("provider_share"))
        XCTAssertFalse(encoded.contains("payout"))
        XCTAssertFalse(encoded.contains("usd_per"))
    }

    func testOfferDryRunEmitsExactClosedTopLevelSchema() async throws {
        let root = try temporaryBYOMOfferDirectory("byom-offer-schema")
        let namespace = root.appendingPathComponent("ns")
        try writeBYOMOfferNamespace(at: namespace)
        let client = BYOMOfferStubHTTPClient(tagsBody: #"{"models":[{"name":"tiny-offer-1b-q4"}]}"#)

        let document = await BYOMOfferDryRunRunner(
            target: "ollama:tiny-offer-1b-q4",
            environment: BYOMDiscoveryEnvironment(
                namespaceURL: namespace,
                mlxCacheRoot: root.appendingPathComponent("hf", isDirectory: true),
                ollamaOrigin: "http://127.0.0.1:11434"
            ),
            httpClient: client
        ).dryRun()

        let encoded = try ModelSwitchingWireCodec.encode(document)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
        XCTAssertEqual(
            Set(object.keys),
            [
                "schema", "generated_at", "cli_version", "candidate_id", "served_model_ref",
                "catalog_model_key", "would_submit", "likely_admission_state",
                "likely_admission_state_source", "provider_guidance", "reason_code", "warnings",
            ],
            "model_admission_offer_dry_run.v1 must be a closed top-level schema (SPEC-047-R002)"
        )
        XCTAssertEqual(object["schema"] as? String, "model_admission_offer_dry_run.v1")
        XCTAssertEqual(object["would_submit"] as? Bool, true)
    }

    func testOfferDryRunForCatalogCandidateReportsMissingTrustedBindingWithoutRates() async throws {
        let root = try temporaryBYOMOfferDirectory("byom-offer-catalog")
        let namespace = root.appendingPathComponent("ns")
        try writeBYOMOfferNamespace(at: namespace)
        let client = BYOMOfferStubHTTPClient(tagsBody: #"{"models":[{"name":"qwen3-8b"}]}"#)

        let document = await BYOMOfferDryRunRunner(
            target: "ollama:qwen3-8b",
            environment: BYOMDiscoveryEnvironment(
                namespaceURL: namespace,
                mlxCacheRoot: root.appendingPathComponent("hf", isDirectory: true),
                ollamaOrigin: "http://127.0.0.1:11434"
            ),
            httpClient: client
        ).dryRun()

        // A catalog-matched candidate with an unverified binding WOULD submit,
        // but is not settlement-capable until the binding is trusted-verified.
        XCTAssertEqual(document.wouldSubmit, true)
        XCTAssertEqual(document.catalogModelKey, "qwen3-8b")
        XCTAssertEqual(document.reasonCode, "catalog_binding_unverified")
        XCTAssertTrue(document.warnings.contains("catalog_match_unverified"))
        XCTAssertEqual(document.providerGuidance.nextAction, "submit_offer")
        XCTAssertEqual(document.providerGuidance.earningPathClass, "not_earning_yet_catalog_or_receipt_path_exists")
        XCTAssertEqual(document.providerGuidance.stateMeaningKey, "byom.offer_dry_run.catalog_path_missing_trusted_binding")
        XCTAssertEqual(client.postCount, 0)   // dry-run NEVER submits

        let encoded = try ModelSwitchingWireCodec.encode(document)
        XCTAssertFalse(encoded.contains("prompt_rate"))
        XCTAssertFalse(encoded.contains("completion_rate"))
        XCTAssertFalse(encoded.contains("provider_share"))
        XCTAssertFalse(encoded.contains("settlement_capable"))
        XCTAssertFalse(encoded.contains("catalog_priced"))
    }

    func testOfferDryRunBlocksInvalidNamespaceWithoutSubmitting() async throws {
        let root = try temporaryBYOMOfferDirectory("byom-offer-namespace")
        let cache = root.appendingPathComponent("hf", isDirectory: true)
        let namespace = root.appendingPathComponent("ns")
        try Data(repeating: 0x11, count: 32).write(to: namespace)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: namespace.path)
        try createBYOMOfferMLXSnapshot(cacheRoot: cache, modelID: "mlx-community/Tiny-1B-4bit")
        let before = try recursiveBYOMOfferPaths(cache)

        let document = await BYOMOfferDryRunRunner(
            target: "mlx-community/Tiny-1B-4bit",
            environment: BYOMDiscoveryEnvironment(namespaceURL: namespace, mlxCacheRoot: cache, ollamaOrigin: nil),
            httpClient: BYOMOfferStubHTTPClient(tagsBody: #"{"models":[]}"#)
        ).dryRun()

        XCTAssertEqual(document.wouldSubmit, false)
        XCTAssertEqual(document.likelyAdmissionState, "local_only")
        XCTAssertEqual(document.reasonCode, "candidate_id_unstable")
        XCTAssertTrue(document.candidateID.hasPrefix("byom_unstable_"))
        XCTAssertTrue(document.warnings.contains("candidate_id_unstable"))
        XCTAssertTrue(document.warnings.contains("namespace_permission_invalid"))
        XCTAssertEqual(document.providerGuidance.nextAction, "fix_local_blocker")
        XCTAssertEqual(document.providerGuidance.earningPathClass, "local_inventory_only")
        let after = try recursiveBYOMOfferPaths(cache)
        XCTAssertEqual(before, after)
    }

    func testOfferDryRunDoesNotCreateMissingNamespace() async throws {
        let root = try temporaryBYOMOfferDirectory("byom-offer-readonly-namespace")
        let cache = root.appendingPathComponent("hf", isDirectory: true)
        let namespace = root.appendingPathComponent("ns")
        try createBYOMOfferMLXSnapshot(cacheRoot: cache, modelID: "mlx-community/Tiny-1B-4bit")

        let document = await BYOMOfferDryRunRunner(
            target: "mlx-community/Tiny-1B-4bit",
            environment: BYOMDiscoveryEnvironment(namespaceURL: namespace, mlxCacheRoot: cache, ollamaOrigin: nil),
            httpClient: BYOMOfferStubHTTPClient(tagsBody: #"{"models":[]}"#)
        ).dryRun()

        XCTAssertEqual(document.wouldSubmit, false)
        XCTAssertEqual(document.reasonCode, "candidate_id_unstable")
        XCTAssertTrue(document.candidateID.hasPrefix("byom_unstable_"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: namespace.path))
    }

    private func temporaryBYOMOfferDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private func writeBYOMOfferNamespace(at url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        try Data(repeating: 0x22, count: 32).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func createBYOMOfferMLXSnapshot(cacheRoot: URL, modelID: String) throws {
        let repo = cacheRoot
            .appendingPathComponent("models--" + modelID.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent("0123456789abcdef0123456789abcdef01234567", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try Data(#"{"max_position_embeddings":2048}"#.utf8).write(to: repo.appendingPathComponent("config.json"))
        try Data(repeating: 0x7a, count: 128).write(to: repo.appendingPathComponent("model.safetensors"))
    }

    private func recursiveBYOMOfferPaths(_ root: URL) throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        var result: [String] = []
        for case let url as URL in enumerator {
            result.append(String(url.path.dropFirst(root.path.count + 1)))
        }
        return result.sorted()
    }

    private func jsonObject(_ stdout: String) throws -> [String: Any] {
        let line = try XCTUnwrap(stdout.split(whereSeparator: \.isNewline).first { line in
            line.trimmingCharacters(in: .whitespaces).hasPrefix("{")
        })
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }
}

private final class BYOMOfferStubHTTPClient: BYOMDiscoveryHTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private let tagsBody: String
    private var gets = 0
    private var posts = 0

    var getCount: Int {
        lock.withLock { gets }
    }

    var postCount: Int {
        lock.withLock { posts }
    }

    init(tagsBody: String) {
        self.tagsBody = tagsBody
    }

    func get(_ url: URL, maxHeaderBytes: Int, maxBodyBytes: Int) async throws -> BYOMHTTPResponse {
        lock.withLock {
            gets += 1
        }
        return BYOMHTTPResponse(statusCode: 200, headers: [("content-type", "application/json")], body: Data(tagsBody.utf8))
    }

    func post(_ url: URL, jsonBody: Data, maxHeaderBytes: Int, maxBodyBytes: Int) async throws -> BYOMHTTPResponse {
        lock.withLock {
            posts += 1
        }
        return BYOMHTTPResponse(statusCode: 500, headers: [], body: Data())
    }
}

private struct BYOMOfferCapturedOutput {
    let stdout: String
    let stderr: String
    let error: Error?
}

private func captureBYOMOfferOutput(_ body: () async throws -> Void) async -> BYOMOfferCapturedOutput {
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    let savedStdout = dup(STDOUT_FILENO)
    let savedStderr = dup(STDERR_FILENO)
    dup2(stdoutPipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
    dup2(stderrPipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

    let error: Error?
    do {
        try await body()
        error = nil
    } catch let caught {
        error = caught
    }

    fflush(stdout)
    fflush(stderr)
    dup2(savedStdout, STDOUT_FILENO)
    dup2(savedStderr, STDERR_FILENO)
    close(savedStdout)
    close(savedStderr)
    stdoutPipe.fileHandleForWriting.closeFile()
    stderrPipe.fileHandleForWriting.closeFile()

    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    return BYOMOfferCapturedOutput(
        stdout: String(decoding: stdoutData, as: UTF8.self),
        stderr: String(decoding: stderrData, as: UTF8.self),
        error: error
    )
}
