import ArgumentParser
import Darwin
import Foundation
import XCTest
@testable import macprovider_cli

final class ModelsSubcommandTests: XCTestCase {
    func testModelsStatusReturnsStatusResponse() async throws {
        let socketPath = try makeSocketPath()
        let server = ControlSocketServer(socketPath: socketPath, modelRuntime: makeRuntime(modelID: "old-model"))
        try await server.start()

        let command = try ModelsStatusCommand.parse(["--ctl-socket-path", socketPath.path])
        let capture = await captureOutput {
            try await command.run()
        }
        await server.stop()

        XCTAssertNil(capture.error)
        XCTAssertTrue(capture.stdout.contains("old-model"))
        XCTAssertTrue(capture.stdout.contains("status_response"))
    }

    func testModelsStatusCase1ENOENT() async throws {
        let socketPath = try makeSocketPath()
        let command = try ModelsStatusCommand.parse(["--ctl-socket-path", socketPath.path])

        let capture = await captureOutput {
            try await command.run()
        }

        XCTAssertEqual(capture.error as? ExitCode, ExitCode(4))
        XCTAssertTrue(capture.stderr.contains("is not running on this host"))
        XCTAssertTrue(capture.stderr.contains(socketPath.path))
    }

    func testModelsStatusCase2ECONNREFUSED() async throws {
        let socketPath = try makeSocketPath()
        try FileManager.default.createDirectory(at: socketPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: socketPath.path, contents: Data())
        let command = try ModelsStatusCommand.parse(["--ctl-socket-path", socketPath.path])

        let capture = await captureOutput {
            try await command.run()
        }

        XCTAssertEqual(capture.error as? ExitCode, ExitCode(4))
        XCTAssertTrue(capture.stderr.contains("stale control socket"))
    }

    func testModelsListDisabledModePrintsIdleTableAndExitsZero() async throws {
        let socketPath = try makeSocketPath()
        let command = try ModelsListCommand.parse([
            "--ctl-socket-path", socketPath.path,
            "--model", "old-model",
            "--supported-models", "old-model",
        ])

        let capture = await captureOutput {
            try await command.run()
        }

        XCTAssertNil(capture.error)
        XCTAssertTrue(capture.stdout.contains("serve not running; warm-swap disabled"))
        XCTAssertTrue(capture.stdout.contains("old-model\tidle"))
        XCTAssertTrue(capture.stderr.contains("macprovider-cli serve is not running on this host"))
    }

    func testModelsListJSONFallbackIsOneStrictObject() async throws {
        let socketPath = try makeSocketPath()
        let command = try ModelsListCommand.parse([
            "--json",
            "--ctl-socket-path", socketPath.path,
            "--model", "mlx-community/Qwen2.5-7B-Instruct-4bit",
            "--supported-models", "mlx-community/Qwen2.5-7B-Instruct-4bit",
        ])

        let capture = await captureOutput { try await command.run() }
        XCTAssertNil(capture.error)
        let lines = capture.stdout.split(whereSeparator: \.isNewline)
        XCTAssertEqual(lines.count, 1)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["schema_version"] as? String, "models_list.v1")
        XCTAssertEqual(object["source"] as? String, "config_fallback")
        XCTAssertEqual(object["warm_swap_available"] as? Bool, false)
        XCTAssertNil(object["current_model_id"] as? String)
        let rows = try XCTUnwrap(object["rows"] as? [[String: Any]])
        XCTAssertEqual(rows.first?["action_model_id"] as? String, "mlx-community/Qwen2.5-7B-Instruct-4bit")
        XCTAssertEqual(rows.first?["state"] as? String, "idle")
        XCTAssertNotNil(rows.first?["weights_present_locally"] as? Bool)
    }

    func testModelsListJSONFallbackDeduplicatesModelIDsIgnoringCase() async throws {
        let socketPath = try makeSocketPath()
        let command = try ModelsListCommand.parse([
            "--json",
            "--ctl-socket-path", socketPath.path,
            "--model", "Org/Model",
            "--supported-models", "Org/Model,org/model,Other/Model",
        ])

        let capture = await captureOutput { try await command.run() }
        XCTAssertNil(capture.error)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(capture.stdout.split(whereSeparator: \.isNewline).first!.utf8)
            ) as? [String: Any]
        )
        let rows = try XCTUnwrap(object["rows"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["action_model_id"] as? String }, ["Org/Model", "Other/Model"])
    }

    func testModelsListConnectedPreservesSupportedModelWithoutRuntimeAuthority() async throws {
        let socketPath = try makeSocketPath()
        let server = ControlSocketServer(
            socketPath: socketPath,
            modelRuntime: makeRuntime(modelID: "old-model")
        )
        try await server.start()

        let command = try ModelsListCommand.parse([
            "--json",
            "--ctl-socket-path", socketPath.path,
            "--model", "old-model",
            "--supported-models", "old-model,uninstalled-model",
        ])
        let capture = await captureOutput { try await command.run() }
        await server.stop()

        XCTAssertNil(capture.error)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(capture.stdout.split(whereSeparator: \.isNewline).first!.utf8)
            ) as? [String: Any]
        )
        let rows = try XCTUnwrap(object["rows"] as? [[String: Any]])
        let uninstalled = try XCTUnwrap(rows.first { ($0["action_model_id"] as? String) == "uninstalled-model" })
        XCTAssertEqual(uninstalled["state"] as? String, "idle")
        XCTAssertEqual(uninstalled["weights_present_locally"] as? Bool, false)
    }

    func testModelsSwitchSuccess() async throws {
        let socketPath = try makeSocketPath()
        let runtime = makeRuntime(modelID: "old-model") { target in
            try await Task.sleep(nanoseconds: 50_000_000)
            return (target, "hash")
        }
        let server = ControlSocketServer(socketPath: socketPath, modelRuntime: runtime)
        try await server.start()

        let command = try ModelsSwitchCommand.parse([
            "new-model",
            "--supported-models", "old-model,new-model",
            "--model", "old-model",
            "--ctl-socket-path", socketPath.path,
            "--switch-state-path", makeStatePath().path,
        ])
        let capture = await captureOutput {
            try await command.run()
        }
        await server.stop()

        XCTAssertNil(capture.error)
        XCTAssertTrue(capture.stderr.contains("state=loading"))
        XCTAssertTrue(capture.stderr.contains("state=draining"))
        XCTAssertTrue(capture.stderr.contains("state=loaded"))
    }

    func testModelsSwitchJSONEmitsAuthoritativeTerminalLoadedEvent() async throws {
        let socketPath = try makeSocketPath()
        let server = ControlSocketServer(
            socketPath: socketPath,
            modelRuntime: makeRuntime(modelID: "old-model") { target in (target, "hash") },
            supportedModels: ["old-model", "new-model"]
        )
        try await server.start()
        let command = try ModelsSwitchCommand.parse([
            "new-model", "--json",
            "--supported-models", "old-model,new-model",
            "--model", "old-model",
            "--ctl-socket-path", socketPath.path,
            "--switch-state-path", makeStatePath().path,
        ])

        let capture = await captureOutput { try await command.run() }
        await server.stop()

        XCTAssertNil(capture.error)
        let decoder = JSONDecoder()
        let events = try capture.stdout
            .split(whereSeparator: \.isNewline)
            .map { try decoder.decode(ModelSwitchEventWire.self, from: Data($0.utf8)) }
        XCTAssertTrue(events.contains { $0.phase == "loading" })
        XCTAssertTrue(events.contains { $0.phase == "draining" })
        let terminal = try XCTUnwrap(events.last)
        XCTAssertEqual(terminal.schemaVersion, "model_switch_event.v1")
        XCTAssertEqual(terminal.type, "terminal")
        XCTAssertEqual(terminal.phase, "loaded")
        XCTAssertEqual(terminal.fromModelID, "old-model")
    }

    func testModelsSwitchReportsDrainingWhileInFlightRequestFinishes() async throws {
        let socketPath = try makeSocketPath()
        let providerStatus = makeProviderStatus(modelID: "old-model", modelHash: "old-hash")
        let requestStartedAt = await providerStatus.beginRequest()
        let runtime = makeRuntime(modelID: "old-model") { target in
            (target, "hash")
        }
        await runtime.setProviderStatus(providerStatus)
        let server = ControlSocketServer(
            socketPath: socketPath,
            modelRuntime: runtime,
            supportedModels: ["old-model", "new-model"]
        )
        try await server.start()

        let command = try ModelsSwitchCommand.parse([
            "new-model",
            "--supported-models", "old-model,new-model",
            "--model", "old-model",
            "--ctl-socket-path", socketPath.path,
            "--switch-state-path", makeStatePath().path,
        ])
        let release = Task {
            try await Task.sleep(nanoseconds: 250_000_000)
            await providerStatus.finishRequest(startedAt: requestStartedAt, completion: nil, failed: false)
        }
        let capture = await captureOutput {
            try await command.run()
        }
        try await release.value
        await server.stop()

        XCTAssertNil(capture.error)
        XCTAssertTrue(capture.stderr.contains("switch_progress state=loading"))
        XCTAssertTrue(capture.stderr.contains("switch_progress state=draining"))
        XCTAssertTrue(capture.stderr.contains("switch_progress state=loaded"))
    }

    func testModelsSwitchPreFlightRejection() async throws {
        let socketPath = try makeSocketPath()
        let command = try ModelsSwitchCommand.parse([
            "C",
            "--supported-models", "A,B",
            "--model", "A",
            "--ctl-socket-path", socketPath.path,
        ])

        let capture = await captureOutput {
            try await command.run()
        }

        XCTAssertEqual(capture.error as? ExitCode, ExitCode(2))
        XCTAssertTrue(capture.stderr.contains("switch target C not in --supported-models"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath.path))
    }

    func testModelsSwitchJSONPreFlightRejectionEmitsTerminalEvent() async throws {
        let socketPath = try makeSocketPath()
        let command = try ModelsSwitchCommand.parse([
            "C", "--json",
            "--supported-models", "A,B",
            "--model", "A",
            "--ctl-socket-path", socketPath.path,
        ])

        let capture = await captureOutput { try await command.run() }

        XCTAssertEqual(capture.error as? ExitCode, ExitCode(2))
        let line = try XCTUnwrap(capture.stdout.split(whereSeparator: \.isNewline).first)
        let event = try JSONDecoder().decode(ModelSwitchEventWire.self, from: Data(line.utf8))
        XCTAssertEqual(event.type, "terminal")
        XCTAssertEqual(event.phase, "failed")
        XCTAssertEqual(event.reason, "not_in_supported_models")
        XCTAssertFalse(event.transactionID.isEmpty)
    }

    func testAdoptRecommendationSuccessAppliesOwnedConfigAndSwitches() async throws {
        let socketPath = try makeSocketPath()
        let fixture = try AdoptionFixture(current: "old-model", target: "new-model")
        let server = ControlSocketServer(
            socketPath: socketPath,
            modelRuntime: makeRuntime(
                modelID: "old-model",
                targetAuthority: fixture.targetAuthority
            ) { target in (target, fixture.artifactSHA256) },
            supportedModels: ["old-model", "new-model"]
        )
        try await server.start()
        let command = try ModelsAdoptRecommendationCommand.parse([
            "--json",
            "--config", fixture.config.path,
            "--recommendation-json", fixture.recommendation.path,
            "--ctl-socket-path", socketPath.path,
            "--switch-state-path", makeStatePath().path,
        ])

        let capture = await captureOutput { try await command.run() }
        await server.stop()

        XCTAssertNil(capture.error)
        let events = try decodeAdoptionEvents(capture.stdout)
        XCTAssertEqual(events.first?.type, "accepted")
        XCTAssertEqual(events.last?.type, "completed")
        let post = try String(contentsOf: fixture.config)
        XCTAssertTrue(post.contains("model: new-model\n"))
        XCTAssertTrue(post.contains("coordinator_endpoint: https://coordinator.example\n"))
    }

    func testAdoptRecommendationRollsBackOwnedConfigWhenSwitchFails() async throws {
        let socketPath = try makeSocketPath()
        let fixture = try AdoptionFixture(current: "old-model", target: "new-model")
        let before = try String(contentsOf: fixture.config)
        let server = ControlSocketServer(
            socketPath: socketPath,
            modelRuntime: makeRuntime(
                modelID: "old-model",
                targetAuthority: fixture.targetAuthority
            ) { _ in throw ModelsSubcommandTestError.unexpectedContainerLoader },
            supportedModels: ["old-model", "new-model"]
        )
        try await server.start()
        let command = try ModelsAdoptRecommendationCommand.parse([
            "--json",
            "--config", fixture.config.path,
            "--recommendation-json", fixture.recommendation.path,
            "--ctl-socket-path", socketPath.path,
            "--switch-state-path", makeStatePath().path,
        ])

        let capture = await captureOutput { try await command.run() }
        await server.stop()

        XCTAssertEqual(capture.error as? ExitCode, ExitCode(5))
        let terminal = try XCTUnwrap(decodeAdoptionEvents(capture.stdout).last)
        XCTAssertEqual(terminal.type, "failed")
        XCTAssertEqual(terminal.rollbackState, "rolled_back")
        let post = try String(contentsOf: fixture.config)
        XCTAssertTrue(post.contains("model: old-model\n"))
        XCTAssertTrue(post.contains("max_context_override: 4000\n"))
        XCTAssertTrue(post.contains("coordinator_endpoint: https://coordinator.example"))
        XCTAssertFalse(post.contains("model: new-model\n"))
        XCTAssertFalse(before.isEmpty)
    }

    func testAdoptRecommendationMalformedJSONEmitsTypedTerminalWithoutMutation() async throws {
        let fixture = try AdoptionFixture(current: "old-model", target: "new-model")
        let bad = fixture.dir.appendingPathComponent("bad.json")
        try Data(#"{"schema_version":"wrong"}"#.utf8).write(to: bad)
        let command = try ModelsAdoptRecommendationCommand.parse([
            "--json",
            "--config", fixture.config.path,
            "--recommendation-json", bad.path,
            "--ctl-socket-path", try makeSocketPath().path,
        ])

        let capture = await captureOutput { try await command.run() }

        XCTAssertEqual(capture.error as? ExitCode, ExitCode(2))
        let terminal = try XCTUnwrap(decodeAdoptionEvents(capture.stdout).last)
        XCTAssertEqual(terminal.schemaVersion, "model_adoption_event.v1")
        XCTAssertEqual(terminal.type, "failed")
        XCTAssertEqual(terminal.reason, "invalid_recommendation")
        XCTAssertTrue(try String(contentsOf: fixture.config).contains("model: old-model\n"))
    }

    func testAdoptRecommendationRejectsStaleRecommendationWithoutMutation() async throws {
        let fixture = try AdoptionFixture(current: "old-model", target: "new-model")
        let stale = try String(contentsOf: fixture.recommendation).replacingOccurrences(
            of: AdoptionFixture.generatedAt,
            with: "2020-01-01T00:00:00Z"
        )
        try Data(stale.utf8).write(to: fixture.recommendation)
        let command = try ModelsAdoptRecommendationCommand.parse([
            "--json",
            "--config", fixture.config.path,
            "--recommendation-json", fixture.recommendation.path,
            "--ctl-socket-path", try makeSocketPath().path,
        ])

        let capture = await captureOutput { try await command.run() }

        XCTAssertEqual(capture.error as? ExitCode, ExitCode(2))
        XCTAssertEqual(try XCTUnwrap(decodeAdoptionEvents(capture.stdout).last).reason, "invalid_recommendation")
        XCTAssertTrue(try String(contentsOf: fixture.config).contains("model: old-model\n"))
    }

    func testAdoptionRecoveryRepairsFailedRollbackBeforeCancelCleanup() async throws {
        let fixture = try AdoptionFixture(current: "old-model", target: "new-model")
        let applier = ConfigApplier(configPath: fixture.config)
        let before = try applier.recommendationOwnedFieldValues()
        var after = before
        after["model"] = "new-model"
        _ = try applier.restoreRecommendationOwnedFields(after, now: Date())
        let journalRoot = fixture.dir.appendingPathComponent("journals", isDirectory: true)
        let journalStore = RecommendationAdoptionJournalStore(root: journalRoot)
        let transactionID = UUID().uuidString.lowercased()
        var record = RecommendationAdoptionJournalRecord(
            transactionID: transactionID,
            fromModelID: "old-model",
            targetModelID: "new-model",
            recommendationSHA256: String(repeating: "a", count: 64),
            configPath: fixture.config.standardizedFileURL.path,
            preApplyConfigSHA256: String(repeating: "b", count: 64),
            postApplyConfigSHA256: String(repeating: "c", count: 64),
            redactedBackupPath: "redacted",
            recommendationOwnedFieldsBefore: before,
            recommendationOwnedFieldsAfter: after,
            now: Date()
        )
        var pendingRecord: RecommendationAdoptionJournalRecord? = record
        XCTAssertFalse(ModelsAdoptRecommendationCommand.persistCancelPending(
            record: &pendingRecord,
            rollback: "rollback_failed",
            journalStore: journalStore
        ))
        record = try XCTUnwrap(pendingRecord)
        let socketPath = try makeSocketPath()
        let server = ControlSocketServer(
            socketPath: socketPath,
            modelRuntime: makeRuntime(modelID: "old-model")
        )
        try await server.start()

        try await ModelsAdoptRecommendationCommand.recoverPendingTransactions(
            store: journalStore,
            configPath: fixture.config,
            socketPath: socketPath
        )
        await server.stop()

        XCTAssertEqual(try applier.recommendationOwnedFieldValues(), before)
        XCTAssertTrue(try journalStore.records(for: fixture.config).isEmpty)
    }

    func testAdoptionRecoveryDoesNotOverwriteConcurrentLockedConfigMutation() async throws {
        let fixture = try AdoptionFixture(current: "old-model", target: "new-model")
        let applier = ConfigApplier(configPath: fixture.config)
        let before = try applier.recommendationOwnedFieldValues()
        var after = before
        after["model"] = "new-model"
        _ = try applier.restoreRecommendationOwnedFields(after, now: Date())
        let journalStore = RecommendationAdoptionJournalStore(
            root: fixture.dir.appendingPathComponent("journals", isDirectory: true)
        )
        try journalStore.write(RecommendationAdoptionJournalRecord(
            transactionID: UUID().uuidString.lowercased(),
            fromModelID: "old-model",
            targetModelID: "new-model",
            recommendationSHA256: String(repeating: "a", count: 64),
            configPath: fixture.config.standardizedFileURL.path,
            preApplyConfigSHA256: String(repeating: "b", count: 64),
            postApplyConfigSHA256: String(repeating: "c", count: 64),
            redactedBackupPath: "redacted",
            recommendationOwnedFieldsBefore: before,
            recommendationOwnedFieldsAfter: after,
            now: Date()
        ))
        let socketPath = try makeSocketPath()
        let server = ControlSocketServer(
            socketPath: socketPath,
            modelRuntime: makeRuntime(modelID: "old-model")
        )
        try await server.start()

        let lockURL = fixture.config.deletingLastPathComponent()
            .appendingPathComponent(".config.yaml.lock")
        let lockFD = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        XCTAssertGreaterThanOrEqual(lockFD, 0)
        guard lockFD >= 0 else {
            await server.stop()
            return
        }
        XCTAssertEqual(flock(lockFD, LOCK_EX), 0)
        let recovery = Task {
            try await ModelsAdoptRecommendationCommand.recoverPendingTransactions(
                store: journalStore,
                configPath: fixture.config,
                socketPath: socketPath
            )
        }

        // Give the old implementation enough time to take its stale snapshot
        // before blocking only for restore. The fixed implementation blocks
        // before both snapshot and restore.
        try await Task.sleep(nanoseconds: 150_000_000)
        let concurrentText = try String(contentsOf: fixture.config)
            .replacingOccurrences(of: "model: new-model", with: "model: concurrent-model")
        try Data(concurrentText.utf8).write(to: fixture.config, options: .atomic)
        XCTAssertEqual(flock(lockFD, LOCK_UN), 0)
        _ = close(lockFD)

        do {
            try await recovery.value
            XCTFail("Expected recovery to reject the concurrent config state")
        } catch let error as RecommendationAdoptionJournalError {
            XCTAssertEqual(error, .invalidJournal)
        }
        await server.stop()

        XCTAssertEqual(try applier.recommendationOwnedFieldValues()["model"], "concurrent-model")
        XCTAssertEqual(try journalStore.records(for: fixture.config).count, 1)
    }

    func testAdoptionRecoveryRestoresPreRepairConfigWhenRuntimeFenceIsLost() async throws {
        let fixture = try AdoptionFixture(current: "old-model", target: "new-model")
        let applier = ConfigApplier(configPath: fixture.config)
        let before = try applier.recommendationOwnedFieldValues()
        var after = before
        after["model"] = "new-model"
        _ = try applier.restoreRecommendationOwnedFields(after, now: Date())
        let journalStore = RecommendationAdoptionJournalStore(
            root: fixture.dir.appendingPathComponent("journals", isDirectory: true)
        )
        try journalStore.write(RecommendationAdoptionJournalRecord(
            transactionID: UUID().uuidString.lowercased(),
            fromModelID: "old-model",
            targetModelID: "new-model",
            recommendationSHA256: String(repeating: "a", count: 64),
            configPath: fixture.config.standardizedFileURL.path,
            preApplyConfigSHA256: String(repeating: "b", count: 64),
            postApplyConfigSHA256: String(repeating: "c", count: 64),
            redactedBackupPath: "redacted",
            recommendationOwnedFieldsBefore: before,
            recommendationOwnedFieldsAfter: after,
            now: Date()
        ))
        var claimCount = 0

        do {
            try await ModelsAdoptRecommendationCommand.recoverPendingTransactions(
                store: journalStore,
                configPath: fixture.config,
                socketPath: try makeSocketPath(),
                recoveryClaim: { _, _, _, _ in
                    claimCount += 1
                    return (
                        currentModelID: claimCount < 3 ? "old-model" : "manual-model",
                        runtimeState: .ready
                    )
                }
            )
            XCTFail("Expected recovery to reject a lost runtime fence")
        } catch let error as RecommendationAdoptionJournalError {
            XCTAssertEqual(error, .invalidJournal)
        }

        XCTAssertEqual(claimCount, 3)
        XCTAssertEqual(try applier.recommendationOwnedFieldValues(), after)
        XCTAssertEqual(try journalStore.records(for: fixture.config).count, 1)
    }

    func testRecommendationAdoptionLockSerializesSameConfigUntilOwnerFinishes() throws {
        let fixture = try AdoptionFixture(current: "old-model", target: "new-model")
        let lockRoot = fixture.dir.appendingPathComponent("locks", isDirectory: true)
        let first = try RecommendationAdoptionLock.acquire(configPath: fixture.config, root: lockRoot)

        XCTAssertThrowsError(
            try RecommendationAdoptionLock.acquire(configPath: fixture.config, root: lockRoot)
        ) { error in
            XCTAssertEqual(error as? RecommendationAdoptionJournalError, .busy)
        }
        withExtendedLifetime(first) {}
    }

    func testRecommendationAdoptionLockCanonicalizesSymlinkAliases() throws {
        let fixture = try AdoptionFixture(current: "old-model", target: "new-model")
        let alias = fixture.dir.appendingPathComponent("config-link.yaml")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.config)
        let lockRoot = fixture.dir.appendingPathComponent("locks", isDirectory: true)
        let first = try RecommendationAdoptionLock.acquire(configPath: fixture.config, root: lockRoot)

        XCTAssertThrowsError(
            try RecommendationAdoptionLock.acquire(configPath: alias, root: lockRoot)
        ) { error in
            XCTAssertEqual(error as? RecommendationAdoptionJournalError, .busy)
        }
        withExtendedLifetime(first) {}
    }

    func testAdoptionRecoveryRejectsTargetRuntimeWithoutDurableCommitMarker() async throws {
        let fixture = try AdoptionFixture(current: "old-model", target: "new-model")
        let applier = ConfigApplier(configPath: fixture.config)
        let before = try applier.recommendationOwnedFieldValues()
        var after = before
        after["model"] = "new-model"
        _ = try applier.restoreRecommendationOwnedFields(after, now: Date())
        let journalStore = RecommendationAdoptionJournalStore(
            root: fixture.dir.appendingPathComponent("journals", isDirectory: true)
        )
        try journalStore.write(RecommendationAdoptionJournalRecord(
            transactionID: UUID().uuidString.lowercased(),
            fromModelID: "old-model",
            targetModelID: "new-model",
            recommendationSHA256: String(repeating: "a", count: 64),
            configPath: fixture.config.standardizedFileURL.path,
            preApplyConfigSHA256: String(repeating: "b", count: 64),
            postApplyConfigSHA256: String(repeating: "c", count: 64),
            redactedBackupPath: "redacted",
            recommendationOwnedFieldsBefore: before,
            recommendationOwnedFieldsAfter: after,
            now: Date()
        ))
        let socketPath = try makeSocketPath()
        let server = ControlSocketServer(
            socketPath: socketPath,
            modelRuntime: makeRuntime(modelID: "new-model")
        )
        try await server.start()

        do {
            try await ModelsAdoptRecommendationCommand.recoverPendingTransactions(
                store: journalStore,
                configPath: fixture.config,
                socketPath: socketPath
            )
            XCTFail("Expected recovery to reject an uncommitted target runtime")
        } catch let error as RecommendationAdoptionJournalError {
            XCTAssertEqual(error, .invalidJournal)
        }
        await server.stop()

        XCTAssertEqual(try applier.recommendationOwnedFieldValues(), after)
        XCTAssertEqual(try journalStore.records(for: fixture.config).count, 1)
    }

    func testAdoptionRecoveryFinishesDurablyCommittedTargetConfig() async throws {
        let fixture = try AdoptionFixture(current: "old-model", target: "new-model")
        let applier = ConfigApplier(configPath: fixture.config)
        let before = try applier.recommendationOwnedFieldValues()
        var after = before
        after["model"] = "new-model"
        let journalStore = RecommendationAdoptionJournalStore(
            root: fixture.dir.appendingPathComponent("journals", isDirectory: true)
        )
        var record = RecommendationAdoptionJournalRecord(
            transactionID: UUID().uuidString.lowercased(),
            fromModelID: "old-model",
            targetModelID: "new-model",
            recommendationSHA256: String(repeating: "a", count: 64),
            configPath: fixture.config.standardizedFileURL.path,
            preApplyConfigSHA256: String(repeating: "b", count: 64),
            postApplyConfigSHA256: String(repeating: "c", count: 64),
            redactedBackupPath: "redacted",
            recommendationOwnedFieldsBefore: before,
            recommendationOwnedFieldsAfter: after,
            now: Date()
        )
        record.phase = .runtimeCommitted
        record.runtimeCommitObserved = true
        try journalStore.write(record)
        let socketPath = try makeSocketPath()
        let server = ControlSocketServer(
            socketPath: socketPath,
            modelRuntime: makeRuntime(modelID: "new-model")
        )
        try await server.start()

        try await ModelsAdoptRecommendationCommand.recoverPendingTransactions(
            store: journalStore,
            configPath: fixture.config,
            socketPath: socketPath
        )
        await server.stop()

        XCTAssertEqual(try applier.recommendationOwnedFieldValues(), after)
        XCTAssertTrue(try journalStore.records(for: fixture.config).isEmpty)
    }

    func testAdoptionRecoveryFinishesIssuedSwitchWhenTargetRuntimeCommitted() async throws {
        let fixture = try AdoptionFixture(current: "old-model", target: "new-model")
        let applier = ConfigApplier(configPath: fixture.config)
        let before = try applier.recommendationOwnedFieldValues()
        var after = before
        after["model"] = "new-model"
        let journalStore = RecommendationAdoptionJournalStore(
            root: fixture.dir.appendingPathComponent("journals", isDirectory: true)
        )
        var record = RecommendationAdoptionJournalRecord(
            transactionID: UUID().uuidString.lowercased(),
            fromModelID: "old-model",
            targetModelID: "new-model",
            recommendationSHA256: String(repeating: "a", count: 64),
            configPath: fixture.config.standardizedFileURL.path,
            preApplyConfigSHA256: String(repeating: "b", count: 64),
            postApplyConfigSHA256: String(repeating: "c", count: 64),
            redactedBackupPath: "redacted",
            recommendationOwnedFieldsBefore: before,
            recommendationOwnedFieldsAfter: after,
            now: Date()
        )
        record.phase = .switchIssued
        try journalStore.write(record)
        let socketPath = try makeSocketPath()
        let server = ControlSocketServer(
            socketPath: socketPath,
            modelRuntime: makeRuntime(modelID: "new-model")
        )
        try await server.start()

        try await ModelsAdoptRecommendationCommand.recoverPendingTransactions(
            store: journalStore,
            configPath: fixture.config,
            socketPath: socketPath
        )
        await server.stop()

        XCTAssertEqual(try applier.recommendationOwnedFieldValues(), after)
        XCTAssertTrue(try journalStore.records(for: fixture.config).isEmpty)
    }

    func testModelsBrowseJSONArgumentFailureEmitsCatalogError() async throws {
        let command = try ModelsBrowseCommand.parse(["--json", "--limit", "0"])

        let capture = await captureOutput { try await command.run() }

        XCTAssertEqual(capture.error as? ExitCode, ExitCode(2))
        let line = try XCTUnwrap(capture.stdout.split(whereSeparator: \.isNewline).first)
        let error = try JSONDecoder().decode(ModelCatalogErrorWire.self, from: Data(line.utf8))
        XCTAssertEqual(error.schemaVersion, "model_catalog_error.v1")
        XCTAssertEqual(error.code, "invalid_argument")
    }

    func testServerSideRejectsSwitchWhenNotInSupportedModels() async throws {
        let socketPath = try makeSocketPath()
        let server = ControlSocketServer(
            socketPath: socketPath,
            modelRuntime: makeRuntime(modelID: "A"),
            supportedModels: ["A", "B"]
        )
        try await server.start()

        let connection = try await ControlSocketClient.connect(socketPath: socketPath)
        try await connection.send(.switchRequest(targetModelID: "C", requestedAtMs: nowMs()))
        let response = try await connection.receive(timeout: 1)
        await connection.close()
        await server.stop()

        XCTAssertEqual(
            response,
            .switchAck(accepted: false, reason: .notInSupportedModels, currentTarget: nil, secondsRemaining: nil)
        )
    }

    func testModelsSwitchConcurrentRejection() async throws {
        let socketPath = try makeSocketPath()
        let runtime = makeRuntime(modelID: "old-model") { target in
            try await Task.sleep(nanoseconds: 300_000_000)
            return (target, "hash")
        }
        let server = ControlSocketServer(socketPath: socketPath, modelRuntime: runtime)
        try await server.start()

        let first = try await ControlSocketClient.connect(socketPath: socketPath)
        try await first.send(.statusRequest)
        _ = try await first.receive(timeout: 1)
        try await first.send(.switchRequest(targetModelID: "slow-model", requestedAtMs: nowMs()))
        _ = try await first.receive(timeout: 1)
        _ = try await first.receive(timeout: 1)

        let command = try ModelsSwitchCommand.parse([
            "other-model",
            "--supported-models", "old-model,slow-model,other-model",
            "--model", "old-model",
            "--ctl-socket-path", socketPath.path,
        ])
        let capture = await captureOutput {
            try await command.run()
        }

        await first.close()
        await server.stop()

        XCTAssertEqual(capture.error as? ExitCode, ExitCode(3))
        XCTAssertTrue(capture.stderr.contains("provider is already loading slow-model"))
    }

    private func makeSocketPath() throws -> URL {
        let dir = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("mpm-\(getpid())-\(Int.random(in: 0 ... 999_999))")
        return dir.appendingPathComponent("ctl.sock")
    }

    private func makeStatePath() -> URL {
        URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("mpm-state-\(getpid())-\(Int.random(in: 0 ... 999_999))")
            .appendingPathComponent("last-switch.ts")
    }

    private func makeRuntime(
        modelID: String?,
        targetAuthority: (modelID: String, authority: ModelRuntimeTargetAuthority)? = nil,
        loader: @escaping @Sendable (String) async throws -> (String, String?) = { target in (target, "hash") }
    ) -> ModelRuntime {
        ModelRuntime(
            modelID: modelID,
            warmSwapEnabled: true,
            targetAuthorities: targetAuthority.map { [$0.modelID: $0.authority] } ?? [:],
            authorizedSwitchModelIDs: targetAuthority.map { [$0.modelID] } ?? [],
            loader: { _ in throw ModelsSubcommandTestError.unexpectedContainerLoader },
            testLoader: loader
        )
    }

    private func makeProviderStatus(modelID: String?, modelHash: String?) -> ProviderStatus {
        ProviderStatus(
            modelID: modelID,
            modelLoaded: modelID != nil,
            capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: 1),
            modelHash: modelHash
        )
    }

    private func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private func decodeAdoptionEvents(_ stdout: String) throws -> [ModelAdoptionEventWire] {
        try stdout.split(whereSeparator: \.isNewline).compactMap {
            let data = Data($0.utf8)
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["schema_version"] as? String == "model_adoption_event.v1" else {
                return nil
            }
            return try JSONDecoder().decode(ModelAdoptionEventWire.self, from: data)
        }
    }
}

private enum ModelsSubcommandTestError: Error {
    case unexpectedContainerLoader
}

private struct AdoptionFixture {
    static let generatedAt = ISO8601DateFormatter().string(from: Date())

    let dir: URL
    let config: URL
    let recommendation: URL
    let artifact: URL
    let artifactSHA256: String
    let targetModelID: String

    var targetAuthority: (modelID: String, authority: ModelRuntimeTargetAuthority) {
        (
            targetModelID,
            ModelRuntimeTargetAuthority(
                modelArgument: artifact.path,
                artifactSHA256: artifactSHA256,
                catalogRevision: String(repeating: "1", count: 40)
            )
        )
    }

    init(current: String, target: String) throws {
        dir = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("mpm-adopt-\(getpid())-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        artifact = dir.appendingPathComponent("artifact", isDirectory: true)
        try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: artifact.appendingPathComponent("model.safetensors"))
        artifactSHA256 = try ModelArtifactVerifier.canonicalArtifactHash(directory: artifact)
        targetModelID = target
        config = dir.appendingPathComponent("config.yaml")
        try Data("""
        model: \(current)
        supported_models:
          - \(current)
          - \(target)
        max_context_override: 4000
        max_concurrency_override: 1
        coordinator_endpoint: https://coordinator.example
        """.utf8).write(to: config)
        recommendation = dir.appendingPathComponent("recommendation.json")
        try Data("""
        {
          "schema_version": "autotune_recommend.v1",
          "generated_at": "\(Self.generatedAt)",
          "hardware": {
            "chip": "Apple Test",
            "memory_gb": 16,
            "binary_version": "1.8.90"
          },
          "inputs": {
            "rate_card_version": "test-catalog",
            "demand_rank_version": "test-catalog",
            "candidate_catalog_version": "test-catalog"
          },
          "recommended_model": "\(target)",
          "warnings": [],
          "candidates": [
            {"model": "\(target)", "eligible": true}
          ],
          "serve_config": {
            "model": "\(target)",
            "model_artifact_path": "\(artifact.path)",
            "model_artifact_sha256": "\(artifactSHA256)",
            "model_catalog_key": "test-key",
            "model_catalog_model_id": "\(target)",
            "model_catalog_revision": "\(String(repeating: "1", count: 40))",
            "model_catalog_sha256": "\(artifactSHA256)",
            "model_catalog_version": "test-catalog",
            "model_catalog_hash": "\(String(repeating: "2", count: 64))",
            "max_context_override": 4000,
            "max_concurrency_override": 1,
            "donor_mode": false
          }
        }
        """.utf8).write(to: recommendation)
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
