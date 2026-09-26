import ArgumentParser
import CryptoKit
import Foundation
import XCTest
@testable import macprovider_cli

/// Build 1 Lane A milestone 3: the measured artifact-bound staging input.
///
/// The assembler tests use a small fixture artifact whose snapshot-manifest
/// digest plays the signed authority digest, so a real private record and a
/// real `GET /v1/status` body can be produced. The command tests cover the
/// staging-only guards, the resolver seams, and the unmeasured-feed blocker
/// through the real signed-feed validator.
final class Build1LaneAStagingInputTests: XCTestCase {
    private struct RecordedFixture {
        let durableRoot: URL
        let authority: Build1LaneAArtifactAuthority
        let binding: Build1LaneAStatusArtifactBinding
        var context: ProviderBuild1LaneAStatusContext {
            ProviderBuild1LaneAStatusContext(recordState: .recorded, reason: "private_record_verified", binding: binding)
        }
    }

    // MARK: - Assembler

    func testReadyWhenAuthorityRecordAndStatusAgree() async throws {
        let fixture = try makeRecordedFixture(payload: "staging-input-ready")
        let status = try await makeStatus(fixture)

        let report = Build1LaneAStagingInputAssembler.assemble(
            authority: .success(fixture.authority),
            privateRecord: fixture.context,
            status: .observed(source: .statusCaptureFile, object: status)
        )

        XCTAssertEqual(report.state, .ready)
        XCTAssertEqual(report.blockers, [])
        XCTAssertEqual(report.artifactAuthority.state, .verified)
        XCTAssertTrue(report.artifactAuthority.measuredSize)
        XCTAssertEqual(report.artifactAuthority.sizeBytes, fixture.authority.sizeBytes)
        XCTAssertEqual(report.artifactAuthority.releaseID, fixture.authority.releaseID)
        XCTAssertEqual(report.artifactAuthority.feedSHA256, fixture.authority.feedSHA256)
        XCTAssertEqual(report.privateRecord.state, .recorded)
        XCTAssertTrue(report.privateRecord.matchesAuthority)
        XCTAssertEqual(report.privateRecord.artifactIdentityDigest, fixture.binding.artifactIdentityDigest)
        XCTAssertEqual(report.privateRecord.receiptSHA256, fixture.binding.receiptSHA256)
        XCTAssertEqual(report.privateRecord.inventoryGeneration, 1)
        XCTAssertEqual(report.statusCorrelation.state, .correlated)
        XCTAssertEqual(report.statusCorrelation.reason, "status_matches_private_record_and_authority_path_observed")
        XCTAssertEqual(report.statusCorrelation.source, .statusCaptureFile)
        XCTAssertTrue(report.statusCorrelation.matchesPrivateRecord)
        XCTAssertTrue(report.statusCorrelation.matchesAuthority)
        XCTAssertEqual(report.statusCorrelation.providerID, "provider-a")
        XCTAssertEqual(report.statusCorrelation.modelHash, fixture.authority.hash)
        XCTAssertEqual(report.statusCorrelation.evidenceState, "correlated")

        let object = report.jsonObject()
        XCTAssertEqual(object["schema"] as? String, "build1_lane_a_staging_input.v1")
        XCTAssertEqual(object["state"] as? String, "staging_input_ready")
        XCTAssertEqual(object["physical_acceptance"] as? Bool, false)
        let boundary = try XCTUnwrap(object["proof_boundary"] as? [String: Any])
        for key in ["physical_acceptance", "grants_admission", "grants_settlement", "production_activation", "rewards_or_payouts", "descriptor_pinned_runtime_custody"] {
            XCTAssertEqual(boundary[key] as? Bool, false, key)
        }
        XCTAssertEqual(boundary["staging_input_only"] as? Bool, true)
        let correlation = try XCTUnwrap(object["status_correlation"] as? [String: Any])
        let custody = try XCTUnwrap(correlation["runtime_custody"] as? [String: Any])
        XCTAssertEqual(custody["descriptor_pinned_runtime_custody"] as? Bool, false)
        XCTAssertEqual(custody["observation_scope"] as? String, "path_observed")
        let handoff = try XCTUnwrap(object["handoff"] as? [String: Any])
        XCTAssertEqual(handoff["catalog_key"] as? String, Build1LaneAPrepareProfile.catalogKey)
        XCTAssertEqual(handoff["model_id"] as? String, Build1LaneAPrepareProfile.artifactModelID)
        XCTAssertEqual(handoff["artifact_sha256"] as? String, Build1LaneAPrepareProfile.artifactHash)
        XCTAssertEqual(handoff["release_id"] as? String, fixture.authority.releaseID)
        XCTAssertEqual(handoff["next_required_steps"] as? [String], Build1LaneAStagingInput.nextRequiredSteps)
        let line = try report.jsonLine()
        XCTAssertFalse(line.contains(fixture.durableRoot.path), "no private path may leak")
        XCTAssertFalse(line.contains(Build1LaneAPreparationRecorder.authorityLeaf))
    }

    func testAuthorityFailuresBlockAndSkipDownstreamEvidence() async throws {
        let fixture = try makeRecordedFixture(payload: "authority-failures")
        let status = try await makeStatus(fixture)
        let cases: [(Build1LaneAArtifactAuthorityError, Build1LaneAStagingInput.ArtifactAuthority.State, String, [String])] = [
            (.stagingCoordinatorUnavailable, .unavailable, "staging_coordinator_required", []),
            (.staticCatalogUnavailable, .unavailable, "static_catalog_unavailable", []),
            (.staticCatalogTupleMismatch, .mismatch, "static_catalog_tuple_mismatch", []),
            (.artifactAuthorityUnavailable([]), .unavailable, "artifact_feed_not_served", []),
            (
                .artifactAuthorityUnavailable(["catalog_artifact_feed_integrity_failure"]),
                .unavailable,
                "artifact_feed_rejected",
                ["catalog_artifact_feed_integrity_failure"]
            ),
            (.artifactTupleMismatch, .mismatch, "artifact_tuple_mismatch", []),
        ]
        for (error, state, reason, warnings) in cases {
            let report = Build1LaneAStagingInputAssembler.assemble(
                authority: .failure(error),
                privateRecord: fixture.context,
                status: .observed(source: .statusCaptureFile, object: status)
            )
            XCTAssertEqual(report.state, .blocked, reason)
            XCTAssertEqual(report.blockers, [reason, "private_record_not_evaluated", "status_not_evaluated"], reason)
            XCTAssertEqual(report.artifactAuthority.state, state, reason)
            XCTAssertEqual(report.artifactAuthority.warnings, warnings, reason)
            XCTAssertFalse(report.artifactAuthority.measuredSize, reason)
            XCTAssertNil(report.artifactAuthority.sizeBytes, reason)
            XCTAssertEqual(report.privateRecord.state, .notEvaluated, reason)
            XCTAssertNil(report.privateRecord.artifactIdentityDigest, reason)
            XCTAssertEqual(report.statusCorrelation.state, .notEvaluated, reason)
            // Observed status fields are still reported for diagnostics.
            XCTAssertEqual(report.statusCorrelation.modelHash, fixture.authority.hash, reason)
            XCTAssertFalse(report.statusCorrelation.matchesPrivateRecord, reason)
        }
    }

    func testGuardedRunReportsNothingEvaluated() {
        let report = Build1LaneAStagingInputAssembler.assemble(
            authority: nil,
            privateRecord: nil,
            status: .notEvaluated,
            preconditionBlockers: ["unsupported_profile"]
        )
        XCTAssertEqual(report.state, .blocked)
        XCTAssertEqual(report.blockers, [
            "unsupported_profile", "artifact_authority_not_evaluated", "private_record_not_evaluated", "status_not_evaluated",
        ])
        XCTAssertEqual(report.artifactAuthority.state, .notEvaluated)
        XCTAssertEqual(report.privateRecord.state, .notEvaluated)
        XCTAssertEqual(report.statusCorrelation.state, .notEvaluated)
        XCTAssertEqual(report.statusCorrelation.source, .unavailable)
    }

    func testPrivateRecordStatesBlockAndSkipStatus() async throws {
        let fixture = try makeRecordedFixture(payload: "record-states")
        let status = try await makeStatus(fixture)
        let cases: [(ProviderBuild1LaneAStatusContext?, Build1LaneAStagingInput.PrivateRecord.State, String)] = [
            (nil, .unavailable, "private_record_unavailable"),
            (ProviderBuild1LaneAStatusContext(recordState: .missing, reason: "private_record_missing", binding: nil), .missing, "private_record_missing"),
            (ProviderBuild1LaneAStatusContext(recordState: .invalid, reason: "private_record_invalid", binding: nil), .invalid, "private_record_invalid"),
            (ProviderBuild1LaneAStatusContext(recordState: .unavailable, reason: "private_record_unavailable", binding: nil), .unavailable, "private_record_unavailable"),
        ]
        for (context, state, reason) in cases {
            let report = Build1LaneAStagingInputAssembler.assemble(
                authority: .success(fixture.authority),
                privateRecord: context,
                status: .observed(source: .localStatusEndpoint, object: status)
            )
            XCTAssertEqual(report.state, .blocked, reason)
            XCTAssertEqual(report.blockers, [reason, "status_not_evaluated"], reason)
            XCTAssertEqual(report.artifactAuthority.state, .verified, reason)
            XCTAssertEqual(report.privateRecord.state, state, reason)
            XCTAssertFalse(report.privateRecord.matchesAuthority, reason)
            XCTAssertEqual(report.statusCorrelation.state, .notEvaluated, reason)
            XCTAssertEqual(report.statusCorrelation.source, .localStatusEndpoint, reason)
        }
    }

    func testPrivateRecordDeclaredSizeMustMatchMeasuredAuthority() async throws {
        let fixture = try makeRecordedFixture(payload: "size-mismatch")
        let status = try await makeStatus(fixture)
        var remeasured = fixture.authority
        remeasured.sizeBytes += 1

        let report = Build1LaneAStagingInputAssembler.assemble(
            authority: .success(remeasured),
            privateRecord: fixture.context,
            status: .observed(source: .statusCaptureFile, object: status)
        )

        XCTAssertEqual(report.state, .blocked)
        XCTAssertEqual(report.blockers, ["private_record_size_mismatch", "status_not_evaluated"])
        XCTAssertEqual(report.privateRecord.state, .sizeMismatch)
        XCTAssertFalse(report.privateRecord.matchesAuthority)
        XCTAssertEqual(report.privateRecord.estimatedBytes, Int64(fixture.authority.sizeBytes))
        XCTAssertEqual(report.privateRecord.artifactIdentityDigest, fixture.binding.artifactIdentityDigest)
        XCTAssertEqual(report.statusCorrelation.state, .notEvaluated)
    }

    func testStatusWithoutLaneAEvidenceBlocks() async throws {
        let fixture = try makeRecordedFixture(payload: "no-evidence")
        let status = try await makeStatus(fixture, laneAContext: .some(nil))
        XCTAssertNil(status["build1_lane_a"])

        let report = Build1LaneAStagingInputAssembler.assemble(
            authority: .success(fixture.authority),
            privateRecord: fixture.context,
            status: .observed(source: .localStatusEndpoint, object: status)
        )

        XCTAssertEqual(report.state, .blocked)
        XCTAssertEqual(report.blockers, ["status_evidence_missing"])
        XCTAssertEqual(report.statusCorrelation.state, .missing)
        XCTAssertNil(report.statusCorrelation.evidenceState)
        XCTAssertEqual(report.statusCorrelation.modelHash, fixture.authority.hash)
    }

    func testStatusEvidenceNotCorrelatedBlocks() async throws {
        let fixture = try makeRecordedFixture(payload: "runtime-hash-drift")
        let status = try await makeStatus(fixture, runtimeModelHash: String(repeating: "1", count: 64))

        let report = Build1LaneAStagingInputAssembler.assemble(
            authority: .success(fixture.authority),
            privateRecord: fixture.context,
            status: .observed(source: .statusCaptureFile, object: status)
        )

        XCTAssertEqual(report.state, .blocked)
        XCTAssertEqual(report.blockers, ["status_not_correlated"])
        XCTAssertEqual(report.statusCorrelation.state, .unbound)
        XCTAssertEqual(report.statusCorrelation.evidenceState, "unbound")
        XCTAssertEqual(report.statusCorrelation.evidenceReason, "model_hash_mismatch")
        XCTAssertFalse(report.statusCorrelation.matchesPrivateRecord)
    }

    func testStatusBoundToAnotherPrivateRecordBlocks() async throws {
        let fixture = try makeRecordedFixture(payload: "root-a")
        // Same bytes recorded under a different durable root: the receipt and
        // root identity differ, so a status body from that provider is not
        // evidence for this record.
        let other = try makeRecordedFixture(payload: "root-a")
        XCTAssertEqual(other.authority.hash, fixture.authority.hash)
        XCTAssertNotEqual(other.binding.rootIdentityDigest, fixture.binding.rootIdentityDigest)
        let status = try await makeStatus(other)

        let report = Build1LaneAStagingInputAssembler.assemble(
            authority: .success(fixture.authority),
            privateRecord: fixture.context,
            status: .observed(source: .statusCaptureFile, object: status)
        )

        XCTAssertEqual(report.state, .blocked)
        XCTAssertEqual(report.blockers, ["status_private_record_mismatch"])
        XCTAssertEqual(report.statusCorrelation.state, .mismatch)
        XCTAssertEqual(report.statusCorrelation.evidenceState, "correlated")
        XCTAssertFalse(report.statusCorrelation.matchesPrivateRecord)
        XCTAssertFalse(report.statusCorrelation.matchesAuthority)
    }

    func testStatusArtifactReleaseMustMatchAuthority() async throws {
        let fixture = try makeRecordedFixture(payload: "release-drift")
        var status = try await makeStatus(fixture)
        var evidence = try XCTUnwrap(status["build1_lane_a"] as? [String: Any])
        var artifact = try XCTUnwrap(evidence["artifact"] as? [String: Any])
        artifact["release_id"] = "some-other-release"
        evidence["artifact"] = artifact
        status["build1_lane_a"] = evidence

        let report = Build1LaneAStagingInputAssembler.assemble(
            authority: .success(fixture.authority),
            privateRecord: fixture.context,
            status: .observed(source: .statusCaptureFile, object: status)
        )

        XCTAssertEqual(report.state, .blocked)
        XCTAssertEqual(report.blockers, ["status_artifact_mismatch"])
        XCTAssertEqual(report.statusCorrelation.state, .mismatch)
        XCTAssertTrue(report.statusCorrelation.matchesPrivateRecord)
        XCTAssertFalse(report.statusCorrelation.matchesAuthority)
    }

    func testStatusClaimingUnknownCustodyScopeIsRefused() async throws {
        let fixture = try makeRecordedFixture(payload: "custody-claim")
        var status = try await makeStatus(fixture)
        var evidence = try XCTUnwrap(status["build1_lane_a"] as? [String: Any])
        evidence["runtime_custody"] = [
            "descriptor_pinned_runtime_custody": true,
            "observation_scope": "descriptor_pinned",
        ]
        status["build1_lane_a"] = evidence

        let report = Build1LaneAStagingInputAssembler.assemble(
            authority: .success(fixture.authority),
            privateRecord: fixture.context,
            status: .observed(source: .statusCaptureFile, object: status)
        )

        XCTAssertEqual(report.state, .blocked)
        XCTAssertEqual(report.blockers, ["status_runtime_custody_scope_unexpected"])
        XCTAssertEqual(report.statusCorrelation.state, .invalid)
        let custody = try XCTUnwrap((report.jsonObject()["status_correlation"] as? [String: Any])?["runtime_custody"] as? [String: Any])
        XCTAssertEqual(custody["descriptor_pinned_runtime_custody"] as? Bool, false, "the report never echoes a custody claim it did not verify")
    }

    func testStatusUnsupportedSchemaIsRefused() async throws {
        let fixture = try makeRecordedFixture(payload: "schema-drift")
        var status = try await makeStatus(fixture)
        var evidence = try XCTUnwrap(status["build1_lane_a"] as? [String: Any])
        evidence["schema"] = "build1_lane_a_status_evidence.v2"
        status["build1_lane_a"] = evidence

        let report = Build1LaneAStagingInputAssembler.assemble(
            authority: .success(fixture.authority),
            privateRecord: fixture.context,
            status: .observed(source: .statusCaptureFile, object: status)
        )

        XCTAssertEqual(report.blockers, ["status_evidence_schema_unsupported"])
        XCTAssertEqual(report.statusCorrelation.state, .invalid)
    }

    func testStatusModelNotLoadedBlocks() async throws {
        let fixture = try makeRecordedFixture(payload: "not-loaded")
        var status = try await makeStatus(fixture)
        status["model_loaded"] = false

        let report = Build1LaneAStagingInputAssembler.assemble(
            authority: .success(fixture.authority),
            privateRecord: fixture.context,
            status: .observed(source: .statusCaptureFile, object: status)
        )

        XCTAssertEqual(report.blockers, ["status_model_not_serving"])
        XCTAssertEqual(report.statusCorrelation.state, .unbound)
        XCTAssertTrue(report.statusCorrelation.matchesPrivateRecord)
        XCTAssertTrue(report.statusCorrelation.matchesAuthority)
        XCTAssertEqual(report.statusCorrelation.modelLoaded, false)
    }

    func testStatusUnavailableBlocks() throws {
        let fixture = try makeRecordedFixture(payload: "status-unavailable")

        let report = Build1LaneAStagingInputAssembler.assemble(
            authority: .success(fixture.authority),
            privateRecord: fixture.context,
            status: .unavailable(source: .localStatusEndpoint, reason: "local_status_unavailable")
        )

        XCTAssertEqual(report.state, .blocked)
        XCTAssertEqual(report.blockers, ["local_status_unavailable"])
        XCTAssertEqual(report.statusCorrelation.state, .unavailable)
        XCTAssertEqual(report.statusCorrelation.source, .localStatusEndpoint)
        XCTAssertNil(report.statusCorrelation.modelHash)
    }

    // MARK: - Command

    func testCommandRequiresJSON() async throws {
        let command = try ModelsStagingInputCommand.parse([
            Build1LaneAPrepareProfile.catalogKey,
            "--coordinator-url", "wss://api-staging.malibu.tech/ws/provider",
        ])
        let capture = await captureOutput { try await command.run() }
        XCTAssertEqual(capture.error as? ExitCode, ExitCode(2))
        XCTAssertEqual(capture.stdout, "")
        XCTAssertTrue(capture.stderr.contains("pass --json"))
    }

    func testCommandGuardsEmitBlockedReportWithoutConsultingAuthority() async throws {
        let cases: [([String], [String])] = [
            (
                [Build1LaneAPrepareProfile.catalogKey, "--json", "--profile", "other", "--coordinator-url", "wss://api-staging.malibu.tech/ws/provider"],
                ["unsupported_profile"]
            ),
            (
                ["qwen/qwen2.5-7b-instruct", "--json", "--coordinator-url", "wss://api-staging.malibu.tech/ws/provider"],
                ["unsupported_model_tuple"]
            ),
            (
                [Build1LaneAPrepareProfile.catalogKey, "--json", "--coordinator-url", "wss://coordinator.malibu.tech/ws/provider"],
                ["staging_coordinator_required"]
            ),
            (
                [Build1LaneAPrepareProfile.catalogKey, "--json"],
                ["staging_coordinator_required"]
            ),
        ]
        for (arguments, guardBlockers) in cases {
            let capture = try await withAuthoritySeam({ _ in
                XCTFail("authority must not be consulted after a guard refusal")
                throw Build1LaneAArtifactAuthorityError.stagingCoordinatorUnavailable
            }) {
                let command = try ModelsStagingInputCommand.parse(arguments)
                return await captureOutput { try await command.run() }
            }
            XCTAssertEqual(capture.error as? ExitCode, ExitCode(2), arguments.joined(separator: " "))
            let object = try decodeReport(capture.stdout)
            XCTAssertEqual(object["state"] as? String, "blocked")
            XCTAssertEqual(
                object["blockers"] as? [String],
                guardBlockers + ["artifact_authority_not_evaluated", "private_record_not_evaluated", "status_not_evaluated"],
                arguments.joined(separator: " ")
            )
            XCTAssertTrue(capture.stderr.contains("models staging-input blocked"))
        }
    }

    func testCommandAssemblesReadyInputFromStatusCaptureFile() async throws {
        let fixture = try makeRecordedFixture(payload: "command-ready")
        let config = try writeConfig(durableRoot: fixture.durableRoot)
        let status = try await makeStatus(fixture)
        let capturePath = try writeStatusCapture(status)

        let capture = try await withAuthoritySeam({ coordinatorURL in
            XCTAssertEqual(coordinatorURL, "wss://api-staging.malibu.tech/ws/provider")
            return fixture.authority
        }) {
            try await withLocalStatusSeam({ _ in
                XCTFail("a status capture file must be used instead of the live endpoint")
                throw ModelsStagingInputError.captureUnreadable
            }) {
                let command = try ModelsStagingInputCommand.parse([
                    Build1LaneAPrepareProfile.artifactModelID,
                    "--json",
                    "--coordinator-url", "wss://api-staging.malibu.tech/ws/provider",
                    "--config", config.path,
                    "--status-capture", capturePath.path,
                ])
                return await captureOutput { try await command.run() }
            }
        }

        XCTAssertNil(capture.error, capture.stderr)
        let object = try decodeReport(capture.stdout)
        XCTAssertEqual(object["state"] as? String, "staging_input_ready")
        XCTAssertEqual(object["blockers"] as? [String], [])
        let authority = try XCTUnwrap(object["artifact_authority"] as? [String: Any])
        XCTAssertEqual(authority["state"] as? String, "verified")
        XCTAssertEqual(authority["measured_size"] as? Bool, true)
        XCTAssertEqual(authority["size_bytes"] as? Int, fixture.authority.sizeBytes)
        let record = try XCTUnwrap(object["private_record"] as? [String: Any])
        XCTAssertEqual(record["state"] as? String, "recorded")
        XCTAssertEqual(record["artifact_identity_digest"] as? String, fixture.binding.artifactIdentityDigest)
        let correlation = try XCTUnwrap(object["status_correlation"] as? [String: Any])
        XCTAssertEqual(correlation["state"] as? String, "correlated")
        XCTAssertEqual(correlation["source"] as? String, "status_capture_file")
        XCTAssertTrue(capture.stderr.contains("grants no admission, settlement, earnings, rewards, payouts, or production activation"))
        XCTAssertFalse(capture.stdout.contains(fixture.durableRoot.path))
        XCTAssertFalse(capture.stdout.contains(capturePath.path))
        XCTAssertFalse(capture.stdout.contains(config.path))
    }

    func testCommandUsesLiveLocalStatusWhenNoCaptureIsGiven() async throws {
        let fixture = try makeRecordedFixture(payload: "command-live")
        let config = try writeConfig(durableRoot: fixture.durableRoot, port: 48321)
        let status = try await makeStatus(fixture)

        let capture = try await withAuthoritySeam({ _ in fixture.authority }) {
            try await withLocalStatusSeam({ port in
                XCTAssertEqual(port, 48321)
                return status
            }) {
                let command = try ModelsStagingInputCommand.parse([
                    Build1LaneAPrepareProfile.catalogKey,
                    "--json",
                    "--coordinator-url", "http://127.0.0.1:8080",
                    "--config", config.path,
                ])
                return await captureOutput { try await command.run() }
            }
        }

        XCTAssertNil(capture.error, capture.stderr)
        let object = try decodeReport(capture.stdout)
        XCTAssertEqual(object["state"] as? String, "staging_input_ready")
        let correlation = try XCTUnwrap(object["status_correlation"] as? [String: Any])
        XCTAssertEqual(correlation["source"] as? String, "local_status_endpoint")
    }

    func testCommandReportsLiveStatusFailureAsBlocker() async throws {
        let fixture = try makeRecordedFixture(payload: "command-live-down")
        let config = try writeConfig(durableRoot: fixture.durableRoot)

        let capture = try await withAuthoritySeam({ _ in fixture.authority }) {
            try await withLocalStatusSeam({ _ in throw URLError(.cannotConnectToHost) }) {
                let command = try ModelsStagingInputCommand.parse([
                    Build1LaneAPrepareProfile.catalogKey,
                    "--json",
                    "--coordinator-url", "wss://api-staging.malibu.tech/ws/provider",
                    "--config", config.path,
                ])
                return await captureOutput { try await command.run() }
            }
        }

        XCTAssertEqual(capture.error as? ExitCode, ExitCode(2))
        let object = try decodeReport(capture.stdout)
        XCTAssertEqual(object["state"] as? String, "blocked")
        XCTAssertEqual(object["blockers"] as? [String], ["local_status_unavailable"])
        XCTAssertEqual((object["private_record"] as? [String: Any])?["state"] as? String, "recorded")
    }

    func testCommandBlocksWhenPrivateStateWasNeverPreparedAndStillReportsObservedStatus() async throws {
        // A durable root that no prepare run ever bootstrapped has no private
        // state authority at all; the status resolver reports that as
        // `private_record_unavailable`, the same word `GET /v1/status` uses.
        let fixture = try makeRecordedFixture(payload: "command-missing-record")
        let emptyRoot = try tempDir().appendingPathComponent("durable", isDirectory: true)
        let config = try writeConfig(durableRoot: emptyRoot)
        let capturePath = try writeStatusCapture(try await makeStatus(fixture))

        let capture = try await withAuthoritySeam({ _ in fixture.authority }) {
            let command = try ModelsStagingInputCommand.parse([
                Build1LaneAPrepareProfile.catalogKey,
                "--json",
                "--coordinator-url", "wss://api-staging.malibu.tech/ws/provider",
                "--config", config.path,
                "--status-capture", capturePath.path,
            ])
            return await captureOutput { try await command.run() }
        }

        XCTAssertEqual(capture.error as? ExitCode, ExitCode(2))
        let object = try decodeReport(capture.stdout)
        XCTAssertEqual(object["blockers"] as? [String], ["private_record_unavailable", "status_not_evaluated"])
        XCTAssertEqual((object["private_record"] as? [String: Any])?["state"] as? String, "unavailable")
        let correlation = try XCTUnwrap(object["status_correlation"] as? [String: Any])
        XCTAssertEqual(correlation["state"] as? String, "not_evaluated")
        XCTAssertEqual(correlation["model_hash"] as? String, fixture.authority.hash)
        XCTAssertFalse(FileManager.default.fileExists(atPath: emptyRoot.appendingPathComponent(Build1LaneAPreparationRecorder.authorityLeaf).path), "a read-only input must not bootstrap private state")
    }

    func testCommandRefusesUnreadableStatusCaptures() async throws {
        let fixture = try makeRecordedFixture(payload: "command-bad-capture")
        let config = try writeConfig(durableRoot: fixture.durableRoot)
        let base = try tempDir()
        let missing = base.appendingPathComponent("missing.json")
        let directory = base.appendingPathComponent("dir", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let array = base.appendingPathComponent("array.json")
        try Data("[]".utf8).write(to: array)
        let symlink = base.appendingPathComponent("link.json")
        let real = try writeStatusCapture(try await makeStatus(fixture))
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: real)

        for path in [missing, directory, array, symlink] {
            let capture = try await withAuthoritySeam({ _ in fixture.authority }) {
                let command = try ModelsStagingInputCommand.parse([
                    Build1LaneAPrepareProfile.catalogKey,
                    "--json",
                    "--coordinator-url", "wss://api-staging.malibu.tech/ws/provider",
                    "--config", config.path,
                    "--status-capture", path.path,
                ])
                return await captureOutput { try await command.run() }
            }
            XCTAssertEqual(capture.error as? ExitCode, ExitCode(2), path.path)
            let object = try decodeReport(capture.stdout)
            XCTAssertEqual(object["blockers"] as? [String], ["status_capture_unreadable"], path.path)
            XCTAssertEqual((object["status_correlation"] as? [String: Any])?["source"] as? String, "status_capture_file", path.path)
        }
    }

    func testCommandBlocksOnUnmeasuredArtifactFeedThroughRealValidator() async throws {
        // The staging feed publishes `size_bytes: null` for the Lane A primary
        // artifact: the strict feed decoder refuses it, so no measured
        // artifact-bound staging input exists and nothing downstream is read.
        let fixture = try Self.signedLaneAFeed(laneASizeBytes: NSNull())
        let inputs = AutotuneStaticInputs(
            fetch: { url in url.path.hasSuffix(".sig") ? fixture.sidecarBytes : fixture.feedBytes },
            trustedPublicKeys: fixture.trustedPublicKeys,
            now: { ISO8601DateFormatter.autotuneInternet.date(from: "2026-09-19T01:00:00Z")! }
        )
        let config = try writeConfig(durableRoot: try tempDir().appendingPathComponent("durable", isDirectory: true))

        let capture = try await withStaticInputsSeam(inputs) {
            let command = try ModelsStagingInputCommand.parse([
                Build1LaneAPrepareProfile.catalogKey,
                "--json",
                "--coordinator-url", "wss://api-staging.malibu.tech/ws/provider",
                "--config", config.path,
                "--status-capture", "/nonexistent/status.json",
            ])
            return await captureOutput { try await command.run() }
        }

        XCTAssertEqual(capture.error as? ExitCode, ExitCode(2))
        let object = try decodeReport(capture.stdout)
        XCTAssertEqual(object["state"] as? String, "blocked")
        XCTAssertEqual(object["blockers"] as? [String], ["artifact_feed_rejected", "private_record_not_evaluated", "status_capture_unreadable"])
        let authority = try XCTUnwrap(object["artifact_authority"] as? [String: Any])
        XCTAssertEqual(authority["state"] as? String, "unavailable")
        XCTAssertEqual(authority["measured_size"] as? Bool, false)
        XCTAssertEqual(authority["warnings"] as? [String], ["catalog_artifact_feed_integrity_failure"])
        XCTAssertTrue(authority["size_bytes"] is NSNull)
    }

    func testCommandVerifiesMeasuredSignedFeedThroughRealValidator() async throws {
        let fixture = try Self.signedLaneAFeed(laneASizeBytes: 2_345_678_901)
        let inputs = AutotuneStaticInputs(
            fetch: { url in url.path.hasSuffix(".sig") ? fixture.sidecarBytes : fixture.feedBytes },
            trustedPublicKeys: fixture.trustedPublicKeys,
            // The baked catalog was regenerated on 2026-09-25. Keep the
            // validator clock after that authority timestamp while remaining
            // inside its freshness window.
            now: { ISO8601DateFormatter.autotuneInternet.date(from: "2026-09-25T01:00:00Z")! }
        )
        let durable = try tempDir().appendingPathComponent("durable", isDirectory: true)
        let config = try writeConfig(durableRoot: durable)

        let capture = try await withStaticInputsSeam(inputs) {
            try await withLocalStatusSeam({ _ in throw URLError(.cannotConnectToHost) }) {
                let command = try ModelsStagingInputCommand.parse([
                    Build1LaneAPrepareProfile.catalogKey,
                    "--json",
                    "--coordinator-url", "wss://api-staging.malibu.tech/ws/provider",
                    "--config", config.path,
                ])
                return await captureOutput { try await command.run() }
            }
        }

        XCTAssertEqual(capture.error as? ExitCode, ExitCode(2))
        let object = try decodeReport(capture.stdout)
        // The private root was never prepared and the live status endpoint is
        // down: both are reported, neither is hidden behind the other.
        XCTAssertEqual(object["blockers"] as? [String], ["private_record_unavailable", "local_status_unavailable"])
        let authority = try XCTUnwrap(object["artifact_authority"] as? [String: Any])
        XCTAssertEqual(authority["state"] as? String, "verified")
        XCTAssertEqual(authority["measured_size"] as? Bool, true)
        XCTAssertEqual(authority["size_bytes"] as? Int, 2_345_678_901)
        XCTAssertEqual(authority["artifact_sha256"] as? String, Build1LaneAPrepareProfile.artifactHash)
        XCTAssertEqual(authority["artifact_hash_algorithm"] as? String, ModelArtifactIdentity.snapshotManifestV1)
        XCTAssertEqual(authority["release_id"] as? String, fixture.releaseID)
        XCTAssertEqual(authority["signer_key_id"] as? String, fixture.signerKeyID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: durable.path), "a read-only input never creates the durable root")
    }

    // MARK: - Status observation freshness

    func testStatusCaptureInsideObservationWindowIsAccepted() async throws {
        let fixture = try makeRecordedFixture(payload: "capture-fresh")
        let status = try await makeStatus(fixture)
        let observedAt = try observedAt(of: status)

        // 4 s after observation is still inside the producer's 5 s window.
        let report = Build1LaneAStagingInputAssembler.assemble(
            authority: .success(fixture.authority),
            privateRecord: fixture.context,
            status: .observed(source: .statusCaptureFile, object: status),
            now: observedAt.addingTimeInterval(4)
        )

        XCTAssertEqual(report.state, .ready)
        XCTAssertEqual(report.blockers, [])
        XCTAssertEqual(report.statusCorrelation.state, .correlated)
        XCTAssertEqual(report.statusCorrelation.validForMS, RouterHandler.statusObservationValidityMS)
        XCTAssertNotNil(report.statusCorrelation.observedAt)
        let correlation = try XCTUnwrap(report.jsonObject()["status_correlation"] as? [String: Any])
        XCTAssertEqual(correlation["valid_for_ms"] as? Int, RouterHandler.statusObservationValidityMS)
        XCTAssertNotNil(correlation["observed_at"] as? String)
    }

    func testStaleStatusCaptureBlocksAsExpired() async throws {
        let fixture = try makeRecordedFixture(payload: "capture-stale")
        let status = try await makeStatus(fixture)
        let observedAt = try observedAt(of: status)

        // Just past observed_at + valid_for_ms: the same bytes that were a
        // valid status a moment ago are now a replay.
        let report = Build1LaneAStagingInputAssembler.assemble(
            authority: .success(fixture.authority),
            privateRecord: fixture.context,
            status: .observed(source: .statusCaptureFile, object: status),
            now: observedAt.addingTimeInterval(6)
        )

        XCTAssertEqual(report.state, .blocked)
        XCTAssertEqual(report.blockers, ["status_capture_expired"])
        XCTAssertEqual(report.statusCorrelation.state, .expired)
        XCTAssertEqual(report.statusCorrelation.reason, "status_capture_expired")
        XCTAssertFalse(report.statusCorrelation.matchesPrivateRecord)
        XCTAssertFalse(report.statusCorrelation.matchesAuthority)
        XCTAssertEqual(report.privateRecord.state, .recorded)

        let live = Build1LaneAStagingInputAssembler.assemble(
            authority: .success(fixture.authority),
            privateRecord: fixture.context,
            status: .observed(source: .localStatusEndpoint, object: status),
            now: observedAt.addingTimeInterval(6)
        )
        XCTAssertEqual(live.blockers, ["local_status_expired"])
        XCTAssertEqual(live.statusCorrelation.state, .expired)
    }

    func testMalformedStatusObservationBlocksAsInvalid() async throws {
        let fixture = try makeRecordedFixture(payload: "capture-malformed")
        let status = try await makeStatus(fixture)
        let observedAt = try observedAt(of: status)
        let farFuture = ISO8601DateFormatter().string(from: observedAt.addingTimeInterval(3_600))

        var cases: [(String, [String: Any])] = []
        func variant(_ label: String, _ mutate: (inout [String: Any]) -> Void) {
            var copy = status
            mutate(&copy)
            cases.append((label, copy))
        }
        variant("no_observation") { $0["observation"] = nil }
        variant("observation_not_object") { $0["observation"] = "later" }
        variant("no_contract") { $0["local_status_contract"] = nil }
        variant("contract_version") { $0["local_status_contract"] = ["version": 2, "minimum_reader_version": 1, "lifecycle_owner": "macprovider_cli"] }
        variant("reader_too_old") { $0["local_status_contract"] = ["version": 1, "minimum_reader_version": 2, "lifecycle_owner": "macprovider_cli"] }
        variant("lifecycle_owner") { $0["local_status_contract"] = ["version": 1, "minimum_reader_version": 1, "lifecycle_owner": "other"] }
        variant("no_service_instance") { $0["service_instance"] = nil }
        variant("service_role") { $0["service_instance"] = ["role": "doctor"] }
        variant("observed_at_missing") { $0["observation"] = ["valid_for_ms": 5_000] }
        variant("observed_at_garbage") { $0["observation"] = ["observed_at": "yesterday", "valid_for_ms": 5_000] }
        variant("observed_at_future") { $0["observation"] = ["observed_at": farFuture, "valid_for_ms": 5_000] }
        variant("valid_for_ms_missing") { $0["observation"] = ["observed_at": ISO8601DateFormatter().string(from: observedAt)] }
        variant("valid_for_ms_zero") { $0["observation"] = ["observed_at": ISO8601DateFormatter().string(from: observedAt), "valid_for_ms": 0] }
        variant("valid_for_ms_negative") { $0["observation"] = ["observed_at": ISO8601DateFormatter().string(from: observedAt), "valid_for_ms": -5_000] }
        variant("valid_for_ms_huge") { $0["observation"] = ["observed_at": ISO8601DateFormatter().string(from: observedAt), "valid_for_ms": 86_400_000] }
        variant("valid_for_ms_string") { $0["observation"] = ["observed_at": ISO8601DateFormatter().string(from: observedAt), "valid_for_ms": "5000"] }

        for (label, object) in cases {
            let report = Build1LaneAStagingInputAssembler.assemble(
                authority: .success(fixture.authority),
                privateRecord: fixture.context,
                status: .observed(source: .statusCaptureFile, object: object),
                now: observedAt.addingTimeInterval(1)
            )
            XCTAssertEqual(report.state, .blocked, label)
            XCTAssertEqual(report.blockers, ["status_capture_invalid"], label)
            XCTAssertEqual(report.statusCorrelation.state, .invalid, label)
            XCTAssertFalse(report.statusCorrelation.matchesPrivateRecord, label)
            XCTAssertFalse(report.statusCorrelation.matchesAuthority, label)

            let live = Build1LaneAStagingInputAssembler.assemble(
                authority: .success(fixture.authority),
                privateRecord: fixture.context,
                status: .observed(source: .localStatusEndpoint, object: object),
                now: observedAt.addingTimeInterval(1)
            )
            XCTAssertEqual(live.blockers, ["local_status_invalid"], label)
        }
    }

    func testStatusObservationValidatorBoundaries() async throws {
        let fixture = try makeRecordedFixture(payload: "validator-boundaries")
        let status = try await makeStatus(fixture)
        let observedAt = try observedAt(of: status)
        let validity = Double(RouterHandler.statusObservationValidityMS) / 1_000
        typealias Validity = Build1LaneAStagingInputAssembler.StatusObservationValidity

        XCTAssertEqual(Build1LaneAStagingInputAssembler.validateStatusObservation(status, now: observedAt), Validity.valid)
        XCTAssertEqual(Build1LaneAStagingInputAssembler.validateStatusObservation(status, now: observedAt.addingTimeInterval(validity)), Validity.valid)
        XCTAssertEqual(Build1LaneAStagingInputAssembler.validateStatusObservation(status, now: observedAt.addingTimeInterval(validity + 0.5)), Validity.expired)
        // Observation timestamps slightly ahead of the command clock are
        // tolerated; far-future ones are not a plausible observation.
        XCTAssertEqual(Build1LaneAStagingInputAssembler.validateStatusObservation(status, now: observedAt.addingTimeInterval(-0.5)), Validity.valid)
        XCTAssertEqual(Build1LaneAStagingInputAssembler.validateStatusObservation(status, now: observedAt.addingTimeInterval(-5)), Validity.invalid)
        XCTAssertEqual(Build1LaneAStagingInputAssembler.validateStatusObservation([:], now: observedAt), Validity.invalid)
        XCTAssertEqual(Build1LaneAStagingInputAssembler.validateStatusObservation(["observation": NSNull()], now: observedAt), Validity.invalid)
    }

    func testCommandRejectsReplayedStatusCapture() async throws {
        // The audit scenario: a capture that was a valid ready input while
        // the provider served is replayed after its observation window.
        let fixture = try makeRecordedFixture(payload: "command-replayed-capture")
        let config = try writeConfig(durableRoot: fixture.durableRoot)
        var status = try await makeStatus(fixture)
        var observation = try XCTUnwrap(status["observation"] as? [String: Any])
        observation["observed_at"] = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))
        status["observation"] = observation
        let capturePath = try writeStatusCapture(status)

        let capture = try await withAuthoritySeam({ _ in fixture.authority }) {
            try await withLocalStatusSeam({ _ in
                XCTFail("a status capture file must be used instead of the live endpoint")
                throw ModelsStagingInputError.captureUnreadable
            }) {
                let command = try ModelsStagingInputCommand.parse([
                    Build1LaneAPrepareProfile.catalogKey,
                    "--json",
                    "--coordinator-url", "wss://api-staging.malibu.tech/ws/provider",
                    "--config", config.path,
                    "--status-capture", capturePath.path,
                ])
                return await captureOutput { try await command.run() }
            }
        }

        XCTAssertEqual(capture.error as? ExitCode, ExitCode(2))
        XCTAssertTrue(capture.stderr.contains("status_capture_expired"), capture.stderr)
        let object = try decodeReport(capture.stdout)
        XCTAssertEqual(object["state"] as? String, "blocked")
        XCTAssertEqual(object["blockers"] as? [String], ["status_capture_expired"])
        XCTAssertEqual((object["private_record"] as? [String: Any])?["state"] as? String, "recorded")
        let correlation = try XCTUnwrap(object["status_correlation"] as? [String: Any])
        XCTAssertEqual(correlation["state"] as? String, "expired")
        XCTAssertEqual(correlation["source"] as? String, "status_capture_file")
        XCTAssertEqual(correlation["valid_for_ms"] as? Int, RouterHandler.statusObservationValidityMS)
        XCTAssertEqual(correlation["matches_private_record"] as? Bool, false)
        XCTAssertEqual(correlation["matches_authority"] as? Bool, false)
    }

    func testCommandBlocksOnMalformedLiveStatusWithoutCrashing() async throws {
        let fixture = try makeRecordedFixture(payload: "command-live-malformed")
        let config = try writeConfig(durableRoot: fixture.durableRoot, port: 48322)

        let bodies: [[String: Any]] = [
            [:],
            ["status": "ready", "model_loaded": true],
            ["observation": "soon", "local_status_contract": 1, "service_instance": NSNull()],
        ]
        for body in bodies {
            let capture = try await withAuthoritySeam({ _ in fixture.authority }) {
                try await withLocalStatusSeam({ _ in body }) {
                    let command = try ModelsStagingInputCommand.parse([
                        Build1LaneAPrepareProfile.catalogKey,
                        "--json",
                        "--coordinator-url", "http://127.0.0.1:8080",
                        "--config", config.path,
                    ])
                    return await captureOutput { try await command.run() }
                }
            }
            XCTAssertEqual(capture.error as? ExitCode, ExitCode(2))
            let object = try decodeReport(capture.stdout)
            XCTAssertEqual(object["state"] as? String, "blocked")
            XCTAssertEqual(object["blockers"] as? [String], ["local_status_invalid"])
            let correlation = try XCTUnwrap(object["status_correlation"] as? [String: Any])
            XCTAssertEqual(correlation["state"] as? String, "invalid")
            XCTAssertEqual(correlation["source"] as? String, "local_status_endpoint")
        }
    }

    // MARK: - Local status port

    func testCommandRejectsInvalidConfiguredPortWithoutFetching() async throws {
        let fixture = try makeRecordedFixture(payload: "command-bad-port")

        for port in [-1, 0, 65_536, 70_000] {
            let config = try writeConfig(durableRoot: fixture.durableRoot, port: port)
            let capture = try await withAuthoritySeam({ _ in fixture.authority }) {
                try await withLocalStatusSeam({ fetched in
                    XCTFail("port \(fetched) must be rejected before any fetch")
                    throw URLError(.badURL)
                }) {
                    let command = try ModelsStagingInputCommand.parse([
                        Build1LaneAPrepareProfile.catalogKey,
                        "--json",
                        "--coordinator-url", "wss://api-staging.malibu.tech/ws/provider",
                        "--config", config.path,
                    ])
                    return await captureOutput { try await command.run() }
                }
            }

            XCTAssertEqual(capture.error as? ExitCode, ExitCode(2), "port \(port)")
            let object = try decodeReport(capture.stdout)
            XCTAssertEqual(object["state"] as? String, "blocked", "port \(port)")
            XCTAssertEqual(object["blockers"] as? [String], ["local_status_port_invalid"], "port \(port)")
            XCTAssertEqual((object["private_record"] as? [String: Any])?["state"] as? String, "recorded", "port \(port)")
            let correlation = try XCTUnwrap(object["status_correlation"] as? [String: Any])
            XCTAssertEqual(correlation["state"] as? String, "unavailable", "port \(port)")
            XCTAssertEqual(correlation["source"] as? String, "local_status_endpoint", "port \(port)")
        }
    }

    func testObserveStatusPortRangeBoundaries() async throws {
        for port in [1, 65_535] {
            let observation = await withLocalStatusSeam({ fetched in
                XCTAssertEqual(fetched, port)
                return ["port": fetched]
            }) {
                await ModelsStagingInputCommand.observeStatus(capturePath: nil, port: port)
            }
            guard case .observed(let source, let object) = observation else {
                return XCTFail("port \(port) must reach the endpoint")
            }
            XCTAssertEqual(source, .localStatusEndpoint)
            XCTAssertEqual(object["port"] as? Int, port)
        }
        for port in [0, 65_536] {
            let observation = try await withLocalStatusSeam({ _ in
                XCTFail("port \(port) must not be fetched")
                throw URLError(.badURL)
            }) {
                await ModelsStagingInputCommand.observeStatus(capturePath: nil, port: port)
            }
            guard case .unavailable(let source, let reason) = observation else {
                return XCTFail("port \(port) must be unavailable")
            }
            XCTAssertEqual(source, .localStatusEndpoint)
            XCTAssertEqual(reason, "local_status_port_invalid")
        }
    }

    private func observedAt(of status: [String: Any]) throws -> Date {
        let observation = try XCTUnwrap(status["observation"] as? [String: Any])
        let text = try XCTUnwrap(observation["observed_at"] as? String)
        return try XCTUnwrap(ISO8601DateFormatter().date(from: text))
    }

    // MARK: - Fixtures

    private func makeRecordedFixture(payload: String) throws -> RecordedFixture {
        let durableRoot = try tempDir().appendingPathComponent("durable", isDirectory: true)
        let staging = try tempDir()
        try Data(payload.utf8).write(to: staging.appendingPathComponent("weights.bin"))
        let hash = try ModelArtifactVerifier.canonicalArtifactHash(directory: staging)
        let authority = Build1LaneAArtifactAuthority(
            catalogKey: Build1LaneAPrepareProfile.catalogKey,
            modelID: Build1LaneAPrepareProfile.artifactModelID,
            revision: Build1LaneAPrepareProfile.artifactRevision,
            artifactID: Build1LaneAPrepareProfile.artifactID,
            hashAlgorithm: ModelArtifactIdentity.snapshotManifestV1,
            hash: hash,
            sizeBytes: payload.utf8.count,
            feedSHA256: String(repeating: "a", count: 64),
            feedSignerKeyID: "test-signer",
            releaseID: "test-release"
        )
        _ = try DurableModelArtifactStore(root: durableRoot).adoptVerifiedStaging(
            staging: staging,
            modelID: authority.modelID,
            revision: authority.revision,
            sha256: authority.hash
        )
        let recorder = Build1LaneAPreparationRecorder(durableRoot: durableRoot)
        let session = try recorder.open()
        _ = try session.record(authority: authority, adoptedSHA256: authority.hash, adoptedBytes: Int64(payload.utf8.count))
        session.close()
        let binding = try XCTUnwrap(recorder.readStatusArtifactBinding(
            catalogKey: authority.catalogKey,
            expectedArtifactSHA256: authority.hash,
            expectedReleaseID: authority.releaseID
        ))
        return RecordedFixture(durableRoot: durableRoot, authority: authority, binding: binding)
    }

    /// A real `GET /v1/status` body for the fixture, built by the same
    /// composer `serve` uses, with the Lane A evidence block correlated.
    private func makeStatus(
        _ fixture: RecordedFixture,
        runtimeModelHash: String? = nil,
        laneAContext: ProviderBuild1LaneAStatusContext?? = nil
    ) async throws -> [String: Any] {
        let status = ProviderStatus(
            modelID: Build1LaneAPrepareProfile.artifactModelID,
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 50_000, maxConcurrencyOverride: 4),
            modelHash: runtimeModelHash ?? fixture.authority.hash,
            modelHashAlgorithm: ModelArtifactIdentity.snapshotManifestV1,
            weightsManifestSHA256: String(repeating: "b", count: 64)
        )
        let context = ProviderCatalogStatusContext(
            trust: nil,
            donorMode: false,
            catalogKey: Build1LaneAPrepareProfile.catalogKey,
            catalogModelID: Build1LaneAPrepareProfile.artifactModelID,
            modelRevision: Build1LaneAPrepareProfile.artifactRevision,
            artifactSHA256: fixture.authority.hash,
            modelArtifactSHA256: fixture.authority.hash,
            configuredReleaseID: fixture.authority.releaseID,
            configuredCatalogDigest: nil,
            build1LaneA: laneAContext ?? fixture.context
        )
        return RouterHandler.statusResponse(
            await status.snapshot(),
            providerID: "provider-a",
            coordinatorURL: nil,
            catalogStatus: context
        )
    }

    private func writeStatusCapture(_ status: [String: Any]) throws -> URL {
        let url = try tempDir().appendingPathComponent("status.json")
        try JSONSerialization.data(withJSONObject: status, options: [.sortedKeys]).write(to: url)
        return url
    }

    private func writeConfig(durableRoot: URL, port: Int? = nil) throws -> URL {
        let url = try tempDir().appendingPathComponent("config.yaml")
        var yaml = "model_artifact_root: \(durableRoot.path)\n"
        if let port {
            yaml += "port: \(port)\n"
        }
        try Data(yaml.utf8).write(to: url)
        return url
    }

    private func tempDir() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macprovider-lane-a-staging-input-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func decodeReport(_ stdout: String) throws -> [String: Any] {
        let lines = stdout.split(whereSeparator: \.isNewline)
        XCTAssertEqual(lines.count, 1, "exactly one JSON line is expected: \(stdout)")
        let line = try XCTUnwrap(lines.first)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    private func withAuthoritySeam<T>(
        _ resolve: @escaping @Sendable (String?) async throws -> Build1LaneAArtifactAuthority,
        _ body: () async throws -> T
    ) async rethrows -> T {
        let original = ModelsStagingInputCommand.resolveAuthority
        ModelsStagingInputCommand.resolveAuthority = resolve
        defer { ModelsStagingInputCommand.resolveAuthority = original }
        return try await body()
    }

    private func withLocalStatusSeam<T>(
        _ fetch: @escaping @Sendable (Int) async throws -> [String: Any],
        _ body: () async throws -> T
    ) async rethrows -> T {
        let original = ModelsStagingInputCommand.fetchLocalStatus
        ModelsStagingInputCommand.fetchLocalStatus = fetch
        defer { ModelsStagingInputCommand.fetchLocalStatus = original }
        return try await body()
    }

    private func withStaticInputsSeam<T>(
        _ inputs: AutotuneStaticInputs,
        _ body: () async throws -> T
    ) async rethrows -> T {
        let original = Build1LaneAArtifactAuthorityResolver.makeStaticInputs
        Build1LaneAArtifactAuthorityResolver.makeStaticInputs = { _ in inputs }
        defer { Build1LaneAArtifactAuthorityResolver.makeStaticInputs = original }
        return try await body()
    }

    private struct SignedLaneAFeed {
        var feedBytes: Data
        var sidecarBytes: Data
        var trustedPublicKeys: [String: String]
        var releaseID: String
        var signerKeyID: String
    }

    /// A release-bound artifact feed for the baked candidate catalog, signed
    /// by a throwaway test key registered under the baked signer key id.
    /// `laneASizeBytes` is the Lane A primary artifact `size_bytes` value
    /// (an `Int`, or `NSNull()` for an unmeasured feed).
    private static func signedLaneAFeed(laneASizeBytes: Any) throws -> SignedLaneAFeed {
        let candidateBytes = Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8)
        let catalog = try AutotuneStaticInputs.decodeSignedStaticCandidateCatalog(candidateBytes)
        let generatedAt = try XCTUnwrap(ArtifactFeed.rawGeneratedAt(in: candidateBytes))
        var models: [String: Any] = [:]
        for key in catalog.rows.keys.sorted() {
            let row = catalog.rows[key]!
            if row.runtimeStatus == "blocked" {
                continue
            }
            let sizeBytes: Any = key == Build1LaneAPrepareProfile.catalogKey ? laneASizeBytes : 1
            models[key] = [
                "rate_class": "class-3b",
                "primary_artifact_id": Build1LaneAPrepareProfile.artifactID,
                "artifacts": [
                    Build1LaneAPrepareProfile.artifactID: [
                        "runtime_format": "mlx_safetensors",
                        "quantization": "4bit",
                        "source_ref": [
                            "kind": "huggingface_revision",
                            "repo_id": row.modelID,
                            "revision": row.modelRevision,
                        ],
                        "hash_algorithm": ModelArtifactIdentity.snapshotManifestV1,
                        "hash": try XCTUnwrap(row.modelSHA256),
                        "size_bytes": sizeBytes,
                        "min_ram_gb": row.minRAMGB,
                        "allowed_runtime_sources": [Build1LaneAPrepareProfile.runtimeSource],
                        "verification_status": "verified",
                        "verified_at": "2026-09-02",
                    ],
                ],
            ]
        }
        let feed: [String: Any] = [
            "version": catalog.version,
            "generated_at": generatedAt,
            "policy_version": catalog.policyVersion,
            "source": ArtifactFeed.source,
            "release_id": catalog.version,
            "candidate_catalog_sha256": AutotuneStaticInputs.candidateCatalogSHA256(bytes: candidateBytes),
            "models": models,
        ]
        let feedBytes = try JSONSerialization.data(withJSONObject: feed, options: [.sortedKeys, .withoutEscapingSlashes])
        let privateKey = Curve25519.Signing.PrivateKey()
        let keyID = AutotuneStaticInputs.bakedCatalogSignerKeyID ?? AutotuneStaticInputs.keyID
        let signature = try privateKey.signature(for: feedBytes).base64EncodedString()
        let sidecarBytes = Data("{\"key_id\":\"\(keyID)\",\"alg\":\"ed25519\",\"signature\":\"\(signature)\"}".utf8)
        var trustedPublicKeys = AutotuneStaticInputs.defaultTrustedPublicKeys
        trustedPublicKeys[keyID] = privateKey.publicKey.rawRepresentation.base64EncodedString()
        return SignedLaneAFeed(
            feedBytes: feedBytes,
            sidecarBytes: sidecarBytes,
            trustedPublicKeys: trustedPublicKeys,
            releaseID: catalog.version,
            signerKeyID: keyID
        )
    }
}

private struct CapturedOutput {
    let stdout: String
    let stderr: String
    let error: Error?
}

private func captureOutput(_ body: () async throws -> Void) async -> CapturedOutput {
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
    return CapturedOutput(
        stdout: String(decoding: stdoutData, as: UTF8.self),
        stderr: String(decoding: stderrData, as: UTF8.self),
        error: error
    )
}
