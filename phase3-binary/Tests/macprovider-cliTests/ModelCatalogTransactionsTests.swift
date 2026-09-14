import ArgumentParser
import CryptoKit
import Darwin
import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

final class ModelCatalogTransactionsTests: XCTestCase {
    func testFailedLockInitializationCannotCloseReusedDescriptor() throws {
        let root = try tempDir()
        let lockURL = root.appendingPathComponent("held-lock")
        let owner = try ModelCatalogFileLock(lockURL)
        defer { withExtendedLifetime(owner) {} }
        let sentinelURL = root.appendingPathComponent("unrelated-evidence")
        let sentinelSource = open(sentinelURL.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(sentinelSource, 0)
        guard sentinelSource >= 0 else { throw POSIXError(.EIO) }
        defer { close(sentinelSource) }
        var reused: Int32 = -1
        defer { if reused >= 0 { close(reused) } }
        XCTAssertThrowsError(try ModelCatalogFileLock(lockURL, nonblocking: true, afterFailureClose: { closed in
            // Reuse the exact released descriptor before a throwing initializer
            // could run deinit. This never overwrites another live descriptor.
            reused = fcntl(sentinelSource, F_DUPFD_CLOEXEC, closed)
            XCTAssertEqual(reused, closed)
        })) { error in
            guard case ModelCatalogTransactionError.busy = error else { return XCTFail("unexpected lock failure: \(error)") }
        }
        XCTAssertGreaterThanOrEqual(reused, 0)
        XCTAssertNotEqual(fcntl(reused, F_GETFD), -1, "failed initialization closed unrelated evidence")
        var sourceInfo = stat(), reusedInfo = stat()
        XCTAssertEqual(fstat(sentinelSource, &sourceInfo), 0)
        XCTAssertEqual(fstat(reused, &reusedInfo), 0)
        XCTAssertEqual(sourceInfo.st_ino, reusedInfo.st_ino)
        XCTAssertThrowsError(try ModelCatalogFileLock(lockURL, nonblocking: true))
    }

    func testContentionRetryStopsAtFirstMutationAndRejectsUnsafeErrors() throws {
        let store = ModelCatalogTransactionStore(root: try tempDir().appendingPathComponent(".transactions"))
        var attempts = 0
        let value: Int = try store.retryBeforeMutation { beginMutation in
            attempts += 1
            if attempts < 3 { throw ModelCatalogTransactionError.busy }
            try beginMutation()
            return attempts
        }
        XCTAssertEqual(value, 3)
        attempts = 0
        XCTAssertThrowsError(try store.retryBeforeMutation { beginMutation in
            attempts += 1; try beginMutation(); throw ModelCatalogTransactionError.busy
        })
        XCTAssertEqual(attempts, 1)
        attempts = 0
        XCTAssertThrowsError(try store.retryBeforeMutation { _ in
            attempts += 1; throw ModelCatalogTransactionError.invalidTransaction
        })
        XCTAssertEqual(attempts, 1)
    }

    func testContentionBudgetCannotReachPublicationAndOwnerLockRemainsImmediate() async throws {
        let root = try tempDir()
        let inputs = try fixtureInputs()
        let authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: inputs)
        var config = AppConfig.defaults(configPath: root.appendingPathComponent("config.yaml").path)
        config.modelArtifactRoot = root.appendingPathComponent("models").path
        let store = ModelCatalogTransactionStore.forConfig(config)
        let id = try store.reserve(authority: authority, kind: "prepare_model")
        let original = try Data(contentsOf: store.root.appendingPathComponent(id + ".json"))
        let owner = try store.ownerLock(id)
        defer { withExtendedLifetime(owner) {} }
        let runner = ModelCatalogTransactionRunner(config: config, configPath: URL(fileURLWithPath: config.configPath), store: store,
            inputs: { XCTFail("contending runner reached authority fetch"); return inputs },
            adoptionLockRoot: root.appendingPathComponent("locks"))
        let ownerStart = Date()
        do { try await runner.run(id: id, target: authority.row.modelID, kind: "prepare_model"); XCTFail("live owner was replaced") }
        catch ModelCatalogTransactionError.busy { }
        catch { XCTFail("unexpected owner contention error: \(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(ownerStart), 1)
        XCTAssertEqual(try Data(contentsOf: store.root.appendingPathComponent(id + ".json")), original)
        var publications = 0
        let budgetStart = Date()
        XCTAssertThrowsError(try store.retryBeforeMutation { beginMutation in
            if Date().timeIntervalSince(budgetStart) < 9 { throw ModelCatalogTransactionError.busy }
            try beginMutation(); publications += 1
        }) { error in
            guard case ModelCatalogTransactionError.busy = error else { return XCTFail("unexpected budget error: \(error)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(budgetStart), 9)
        XCTAssertEqual(publications, 0)
        XCTAssertEqual(try Data(contentsOf: store.root.appendingPathComponent(id + ".json")), original)
    }

    func testEvaluationSuccessDeltaReplaysExactEventAndOnlyCleanupBookkeeping() throws {
        let store = ModelCatalogTransactionStore(root: try tempDir().appendingPathComponent(".transactions"))
        let authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: fixtureInputs())
        let id = try store.reserve(authority: authority, kind: "evaluate_model")
        var record = try store.load(id, target: authority.row.modelID)
        record.startedAt = Date(); record.committed = true; record.resultSHA256 = String(repeating: "a", count: 64)
        store.append(&record, state: "running", stage: "evaluating")
        for initialCleanup in [false, true] {
            record.cleanupRequired = initialCleanup
            let cleanupRequired = !initialCleanup
            let terminal = try store.evaluationSuccessTerminal(preterminal: record, cleanupRequired: cleanupRequired)
            let event = try XCTUnwrap(terminal.events.last)
            let replayed = try store.evaluationSuccessTerminal(preterminal: record, cleanupRequired: cleanupRequired, event: event)
            XCTAssertEqual(try store.canonicalData(replayed), try store.canonicalData(terminal))
            XCTAssertEqual(event.warningCode, cleanupRequired ? "staging_cleanup_required" : nil)
            var stripped = terminal; stripped.cleanupRequired = initialCleanup; stripped.events.removeLast()
            XCTAssertEqual(try store.canonicalData(stripped), try store.canonicalData(record))
            for (field, badValue): (String, Any) in [
                ("transaction_id", UUID().uuidString.lowercased()), ("operation_generation", UUID().uuidString.lowercased()),
                ("event_sequence", 1), ("state", "failed"), ("error_code", "transaction_failed")
            ] {
                var wire = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
                wire[field] = badValue
                let badEvent = try JSONDecoder().decode(ModelCatalogTransactionEvent.self, from: JSONSerialization.data(withJSONObject: wire))
                XCTAssertThrowsError(try store.evaluationSuccessTerminal(preterminal: record, cleanupRequired: cleanupRequired, event: badEvent), field)
            }
            XCTAssertThrowsError(try store.evaluationSuccessTerminal(preterminal: terminal, cleanupRequired: cleanupRequired))
        }
    }

    func testAuthorityBindsExactPrimaryAndRejectsDegradedInputs() throws {
        let inputs = try fixtureInputs()
        let authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: inputs)
        XCTAssertEqual(authority.modelKey, "test-model")
        XCTAssertEqual(authority.row.modelID, "mlx-community/Test-Model-4bit")
        XCTAssertGreaterThan(try XCTUnwrap(authority.estimatedBytes), 0)
        XCTAssertThrowsError(try ModelCatalogTransactionAuthority.resolve(target: "wrong", inputs: inputs))
        for warning in [AutotuneRecommendWarning.catalogArtifactFeedStale, .catalogArtifactFeedIntegrityFailure, .catalogArtifactFeedUpdateRequired] {
            var bad = inputs; bad.artifactFeed.warnings.insert(warning)
            XCTAssertThrowsError(try ModelCatalogTransactionAuthority.resolve(target: authority.modelKey, inputs: bad))
        }
        var bad = inputs; bad.candidate.signerKeyID = "another-signer"
        XCTAssertThrowsError(try ModelCatalogTransactionAuthority.resolve(target: authority.modelKey, inputs: bad))
        bad = inputs; bad.artifactFeed.value = nil
        XCTAssertThrowsError(try ModelCatalogTransactionAuthority.resolve(target: authority.modelKey, inputs: bad))
        var fallback = inputs; fallback.artifactFeed.usedFallback = true
        fallback.artifactFeed.warnings = [.catalogArtifactFeedFallbackUsed]
        XCTAssertEqual(try ModelCatalogTransactionAuthority.resolve(target: authority.modelKey, inputs: fallback).source, "static_signed")
    }

    func testCC08ReadBindingCoversAllFourSignedSelectionsAndTrustClasses() throws {
        let original = try fixtureInputs()
        let binding = ModelCatalogSignedInputBinding(original)
        XCTAssertEqual(binding, ModelCatalogSignedInputBinding(original))

        var mutations: [ModelCatalogRecommendationInputs] = []
        var changed = original; changed.candidate.selectedBytes.append(0); mutations.append(changed)
        changed = original; changed.artifactFeed.selectedBytes.append(0); mutations.append(changed)
        changed = original; changed.rateCard.selectedBytes.append(0); mutations.append(changed)
        changed = original; changed.demand.selectedBytes.append(0); mutations.append(changed)
        changed = original; changed.candidate.signerKeyID = "other"; mutations.append(changed)
        changed = original; changed.artifactFeed.signerKeyID = "other"; mutations.append(changed)
        changed = original; changed.rateCard.signerKeyID = "other"; mutations.append(changed)
        changed = original; changed.demand.signerKeyID = "other"; mutations.append(changed)
        changed = original; changed.candidate.value.version += "-changed"; mutations.append(changed)
        changed = original; changed.artifactFeed.value = nil; mutations.append(changed)
        changed = original; changed.rateCard.value.version += "-changed"; mutations.append(changed)
        changed = original; changed.demand.value.version += "-changed"; mutations.append(changed)
        changed = original; changed.candidate.warnings.insert(.candidateCatalogUpdateRequired); mutations.append(changed)
        changed = original; changed.artifactFeed.warnings.insert(.catalogArtifactFeedIntegrityFailure); mutations.append(changed)
        changed = original; changed.rateCard.warnings.insert(.rateCardStale); mutations.append(changed)
        changed = original; changed.demand.warnings.insert(.demandRankFallbackUsed); mutations.append(changed)
        changed = original; changed.candidate.usedFallback.toggle(); mutations.append(changed)
        changed = original; changed.artifactFeed.usedFallback.toggle(); mutations.append(changed)
        changed = original; changed.rateCard.usedFallback.toggle(); mutations.append(changed)
        changed = original; changed.demand.usedFallback.toggle(); mutations.append(changed)

        for mutation in mutations {
            XCTAssertNotEqual(binding, ModelCatalogSignedInputBinding(mutation))
        }
    }

    func testReservationBindingIdempotentCancelAndClosedReplay() throws {
        let store = ModelCatalogTransactionStore(root: try tempDir().appendingPathComponent(".transactions"))
        let authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: fixtureInputs())
        let id = try store.reserve(authority: authority, kind: "prepare_model")
        XCTAssertEqual(id, try store.reserve(authority: authority, kind: "prepare_model"))
        XCTAssertThrowsError(try store.reconcile(id, target: "other"))
        XCTAssertThrowsError(try store.reconcile(UUID().uuidString.lowercased(), target: authority.row.modelID))
        let cancelled = try self.reconcileEventually(store, id, target: authority.row.modelID, cancel: true)
        XCTAssertEqual(cancelled.events.map(\.state), ["queued", "cancel_requested", "cancelled"])
        XCTAssertEqual(cancelled.events, try self.reconcileEventually(store, id, target: authority.row.modelID, cancel: true).events)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(cancelled.events.last)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schema", "transaction_id", "transaction_kind", "operation_generation", "model_key", "event_sequence", "emitted_at", "state", "progress", "error_code", "warning_code"])
        XCTAssertEqual(object["schema"] as? String, "model_catalog_transaction_event.v1")
        XCTAssertTrue(object["error_code"] is NSNull)
        XCTAssertThrowsError(try store.result(id, target: authority.row.modelID))
    }

    func testLiveOwnerRemainsCancellableAndCrashFailsClosed() throws {
        let store = ModelCatalogTransactionStore(root: try tempDir().appendingPathComponent(".transactions"))
        let authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: fixtureInputs())
        let id = try store.reserve(authority: authority, kind: "prepare_model")
        var owner: ModelCatalogFileLock? = try store.ownerLock(id)
        let receipt = try store.captureActiveReceipt(selector: .init(transactionID: id,
            target: authority.row.modelID, kind: "prepare_model",
            operationGeneration: try XCTUnwrap(store.load(id, target: authority.row.modelID).operationGeneration)),
            heldOwner: owner)
        var record = receipt.record; record.startedAt = Date()
        store.append(&record, state: "running", stage: "preparing")
        try store.commit(record: record, receipt: receipt)
        XCTAssertFalse(try self.reconcileEventually(store, id, target: authority.row.modelID).terminal)
        XCTAssertThrowsError(try store.ownerLock(id))
        let cancelled = try self.reconcileEventually(store, id, target: authority.row.modelID, cancel: true)
        XCTAssertEqual(cancelled.events.last?.state, "cancel_requested")
        XCTAssertThrowsError(try store.check(id, target: authority.row.modelID))
        withExtendedLifetime(owner) {}; owner = nil
        let recovered = try self.reconcileEventually(store, id, target: authority.row.modelID)
        XCTAssertEqual(recovered.events.last?.state, "failed")
        XCTAssertEqual(recovered.events.last?.errorCode, "owner_interrupted")
        XCTAssertEqual(recovered.events, try self.reconcileEventually(store, id, target: authority.row.modelID, cancel: true).events)
    }

    func testCleanupRejectsSymlinkAndPreservesOutsideAndPublished() throws {
        let root = try tempDir()
        let store = ModelCatalogTransactionStore(root: root.appendingPathComponent(".transactions"))
        try store.secure()
        let id = UUID().uuidString.lowercased()
        let outside = try tempDir()
        let file = outside.appendingPathComponent("keep")
        try Data("keep".utf8).write(to: file)
        let staging = try store.stagingURL(id)
        XCTAssertEqual(symlink(outside.path, staging.path), 0)
        XCTAssertThrowsError(try store.cleanup(id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertThrowsError(try store.stagingURL("../../escape"))
        try FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        try Data("partial".utf8).write(to: staging.appendingPathComponent("part"))
        try store.cleanup(id); try store.cleanup(id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testJournalRejectsSymlinkAndWorldReadableRecord() throws {
        let root = try tempDir()
        let store = ModelCatalogTransactionStore(root: root.appendingPathComponent(".transactions"))
        let authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: fixtureInputs())
        let id = try store.reserve(authority: authority, kind: "prepare_model")
        let file = store.root.appendingPathComponent(id + ".json")
        XCTAssertEqual(chmod(file.path, 0o644), 0)
        XCTAssertThrowsError(try store.reconcile(id, target: authority.row.modelID))
        let moved = root.appendingPathComponent("outside.json")
        try FileManager.default.moveItem(at: file, to: moved)
        XCTAssertEqual(symlink(moved.path, file.path), 0)
        XCTAssertThrowsError(try store.reconcile(id, target: authority.row.modelID))
    }

    func testResolverUsesConfigThenAbsoluteEnvironmentThenIsolatedHome() throws {
        let home = try tempDir()
        var config = AppConfig.defaults(); config.modelArtifactRoot = home.appendingPathComponent("configured").path
        let env = ["MACPROVIDER_MODEL_ARTIFACT_ROOT": home.appendingPathComponent("environmental").path, "HF_HUB_CACHE": home.appendingPathComponent("hub").path]
        XCTAssertEqual(CachedModelArtifactResolver.forConfig(config, environment: env, homeDirectory: home).durableRoot.path, config.modelArtifactRoot)
        XCTAssertEqual(CachedModelArtifactResolver.forConfig(nil, environment: env, homeDirectory: home).durableRoot.path, env["MACPROVIDER_MODEL_ARTIFACT_ROOT"])
        XCTAssertEqual(CachedModelArtifactResolver.forConfig(nil, environment: ["MACPROVIDER_MODEL_ARTIFACT_ROOT": "relative"], homeDirectory: home).durableRoot,
                       home.appendingPathComponent("Library/Application Support/macprovider/models"))
    }

    func testPreparationOwnerPublishesVerifiedBytesAndPreservesConfiguration() async throws {
        let root = try tempDir()
        let source = try tempDir()
        try Data("weights".utf8).write(to: source.appendingPathComponent("weights.safetensors"))
        try Data(#"{"max_position_embeddings":4096}"#.utf8).write(to: source.appendingPathComponent("config.json"))
        let sha = try ModelArtifactVerifier.canonicalArtifactHash(directory: source)
        let inputs = try fixtureInputs(artifactSHA256: sha)
        let authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: inputs)
        var config = AppConfig.defaults(configPath: root.appendingPathComponent("config.yaml").path)
        config.modelArtifactRoot = root.appendingPathComponent("models").path
        config.supportedModels = ["test-model", "incumbent"]
        let configPath = URL(fileURLWithPath: config.configPath)
        let incumbent = Data("model: incumbent\n".utf8)
        try incumbent.write(to: configPath)
        let store = ModelCatalogTransactionStore.forConfig(config)
        let id = try store.reserve(authority: authority, kind: "prepare_model")
        let runner = ModelCatalogTransactionRunner(config: config, configPath: configPath, store: store,
            inputs: { inputs }, downloader: fixtureDownloader(root: root, readyArtifact: true), adoptionLockRoot: root.appendingPathComponent("locks"))
        try await runner.run(id: id, target: authority.row.modelID, kind: "prepare_model")
        let record = try self.reconcileEventually(store, id, target: authority.row.modelID)
        XCTAssertTrue(record.committed)
        XCTAssertEqual(record.events.last?.state, "succeeded")
        XCTAssertEqual(record.events, try self.reconcileEventually(store, id, target: authority.row.modelID, cancel: true).events)
        let artifact = try CachedModelArtifactResolver.forConfig(config).durableStore.artifactURL(modelID: authority.row.modelID,
            revision: authority.row.modelRevision!, sha256: sha)
        XCTAssertEqual(try ModelArtifactVerifier.canonicalArtifactHash(directory: artifact), sha)
        XCTAssertEqual(try Data(contentsOf: configPath), incumbent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store.stagingURL(id).path))
        XCTAssertThrowsError(try store.result(id, target: authority.row.modelID))
        let discovered = DurableModelDiscovery(root: resolverRoot(config), namespace: Data(repeating: 7, count: 32),
            catalogMatcher: modelCatalogDiscoveryMatcher(inputs: inputs)).discover()
        XCTAssertEqual(discovered.count, 1)
        XCTAssertEqual(discovered.first?.readinessState, "ready")
        let restarted = DurableModelDiscovery(root: resolverRoot(config), namespace: Data(repeating: 7, count: 32),
            catalogMatcher: modelCatalogDiscoveryMatcher(inputs: inputs)).discover()
        XCTAssertEqual(discovered.first?.candidateID, restarted.first?.candidateID)
    }

    func testCancellationDuringAuthorityFetchTerminatesThroughOwnerInterface() async throws {
        let root = try tempDir()
        let inputs = try fixtureInputs()
        let authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: inputs)
        var config = AppConfig.defaults(configPath: root.appendingPathComponent("config.yaml").path)
        config.modelArtifactRoot = root.appendingPathComponent("models").path
        let store = ModelCatalogTransactionStore.forConfig(config)
        let id = try store.reserve(authority: authority, kind: "prepare_model")
        let runner = ModelCatalogTransactionRunner(config: config, configPath: URL(fileURLWithPath: config.configPath), store: store,
            inputs: { try? await Task.sleep(nanoseconds: 30_000_000_000); return inputs },
            adoptionLockRoot: root.appendingPathComponent("locks"))
        let originalSelector = try XCTUnwrap(store.load(id, target: authority.row.modelID).selector)
        var journal: ModelCatalogFileLock? = try ModelCatalogFileLock(store.root.appendingPathComponent(".journal-lock"))
        defer { withExtendedLifetime(journal) {} }
        let work = Task { try await runner.run(id: id, target: authority.row.modelID, kind: "prepare_model") }
        try await Task.sleep(nanoseconds: 100_000_000)
        withExtendedLifetime(journal) {}; journal = nil
        do {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline, try self.reconcileEventually(store, id, target: authority.row.modelID).startedAt == nil {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertNotNil(try self.reconcileEventually(store, id, target: authority.row.modelID).startedAt)
            XCTAssertEqual(try self.reconcileEventually(store, id, target: authority.row.modelID, cancel: true).events.last?.state, "cancel_requested")
            do { try await work.value; XCTFail("cancelled owner succeeded") }
            catch is CancellationError { }
            catch ModelCatalogTransactionError.cancelled { }
            catch { XCTFail("owner failed outside cancellation: \(error)") }
            XCTAssertEqual(try store.load(id, target: authority.row.modelID).selector, originalSelector)
            XCTAssertEqual(try self.reconcileEventually(store, id, target: authority.row.modelID).events.last?.state, "cancelled")
            XCTAssertFalse(FileManager.default.fileExists(atPath: try store.stagingURL(id).path))
        } catch {
            _ = try? self.reconcileEventually(store, id, target: authority.row.modelID, cancel: true)
            _ = try? await work.value
            throw error
        }
    }

    func testRecommendationResultCommitRejectsRefreshedRateAndFeedDrift() throws {
        let original = try fixtureInputs()
        XCTAssertNoThrow(try ModelCatalogTransactionRunner.validateRecommendationInputs(initial: original, fresh: original))
        var changed = original; changed.rateCard.selectedBytes.append(32)
        XCTAssertThrowsError(try ModelCatalogTransactionRunner.validateRecommendationInputs(initial: original, fresh: changed))
        changed = original; changed.demand.selectedBytes.append(32)
        XCTAssertThrowsError(try ModelCatalogTransactionRunner.validateRecommendationInputs(initial: original, fresh: changed))
        changed = original; changed.candidate.signerKeyID = "substituted"
        XCTAssertThrowsError(try ModelCatalogTransactionRunner.validateRecommendationInputs(initial: original, fresh: changed))
        changed = original; changed.rateCard.warnings.insert(.rateCardStale)
        XCTAssertThrowsError(try ModelCatalogTransactionRunner.validateRecommendationInputs(initial: original, fresh: changed))
    }

    private func resolverRoot(_ config: AppConfig) -> URL { CachedModelArtifactResolver.forConfig(config).durableRoot }

    func testOwnerRejectsCorruptTransferAndAuthorityDriftWithoutPublishing() async throws {
        for scenario in ["corrupt", "drift", "metadata_cancel", "transfer_cancel", "before_publish_cancel", "partial_write_failure"] {
            let root = try tempDir()
            let source = try tempDir()
            try Data("weights".utf8).write(to: source.appendingPathComponent("weights.bin"))
            let sha = try ModelArtifactVerifier.canonicalArtifactHash(directory: source)
            let inputs = try fixtureInputs(artifactSHA256: sha)
            let authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: inputs)
            var config = AppConfig.defaults(configPath: root.appendingPathComponent("config.yaml").path)
            config.modelArtifactRoot = root.appendingPathComponent("models").path
            config.supportedModels = ["test-model"]
            let bytes = Data("model: incumbent\n".utf8)
            try bytes.write(to: URL(fileURLWithPath: config.configPath))
            let store = ModelCatalogTransactionStore.forConfig(config)
            let id = try store.reserve(authority: authority, kind: "prepare_model")
            var calls = 0
            let transfers = Build1TransferCounter()
            let downloader = HuggingFaceSnapshotDownloader(fetch: { request in
                if scenario == "metadata_cancel" {
                    _ = try self.reconcileEventually(store, id, target: authority.row.modelID, cancel: true)
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                }
                let metadata = scenario == "partial_write_failure" ? #"{"siblings":[{"rfilename":"a.bin"},{"rfilename":"b.bin"}]}"# : #"{"siblings":[{"rfilename":"weights.bin"}]}"#
                return (Data(metadata.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }, download: { request in
                let transfer = await transfers.increment()
                if scenario == "partial_write_failure" && transfer > 1 { throw POSIXError(.ENOSPC) }
                if scenario == "transfer_cancel" {
                    _ = try self.reconcileEventually(store, id, target: authority.row.modelID, cancel: true)
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                }
                let file = root.appendingPathComponent("transfer")
                try Data((scenario == "corrupt" ? "wrong" : "weights").utf8).write(to: file)
                return (file, URLResponse(url: request.url!, mimeType: nil, expectedContentLength: 7, textEncodingName: nil))
            })
            let runner = ModelCatalogTransactionRunner(config: config, configPath: URL(fileURLWithPath: config.configPath), store: store,
                inputs: {
                    calls += 1
                    if calls > 1, scenario == "before_publish_cancel" {
                        _ = try? self.reconcileEventually(store, id, target: authority.row.modelID, cancel: true)
                    }
                    var value = inputs
                    if calls > 1, scenario == "drift" { value.artifactFeed.warnings.insert(.catalogArtifactFeedStale) }
                    return value
                }, downloader: downloader, adoptionLockRoot: root.appendingPathComponent("locks"))
            do { try await runner.run(id: id, target: authority.row.modelID, kind: "prepare_model"); XCTFail(scenario) } catch {}
            let record = try self.reconcileEventually(store, id, target: authority.row.modelID)
            if scenario == "partial_write_failure" {
                let completedTransfers = await transfers.snapshot()
                XCTAssertEqual(completedTransfers, 2)
            }
            XCTAssertEqual(record.events.last?.state, scenario.contains("cancel") ? "cancelled" : "failed", scenario)
            let destination = try CachedModelArtifactResolver.forConfig(config).durableStore.artifactURL(
                modelID: authority.row.modelID, revision: authority.row.modelRevision!, sha256: sha)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), scenario)
            XCTAssertFalse(FileManager.default.fileExists(atPath: try store.stagingURL(id).path), scenario)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: config.configPath)), bytes)
        }
    }

    func testExactSelectorsRejectStaleGenerationAndWrongKindWithoutJournalMutation() throws {
        let root = try tempDir()
        let store = ModelCatalogTransactionStore(root: root.appendingPathComponent("transactions"))
        let authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: fixtureInputs())
        let reservation = try store.reserveOperation(authority: authority, kind: "prepare_model")
        let selector = ModelCatalogTransactionSelector(transactionID: reservation.transactionID, target: authority.row.modelID,
            kind: "prepare_model", operationGeneration: reservation.operationGeneration)
        let path = store.root.appendingPathComponent(reservation.transactionID + ".json")
        let before = try Data(contentsOf: path)
        for wrong in [
            ModelCatalogTransactionSelector(transactionID: selector.transactionID, target: selector.target, kind: selector.kind, operationGeneration: UUID().uuidString.lowercased()),
            ModelCatalogTransactionSelector(transactionID: selector.transactionID, target: selector.target, kind: "evaluate_model", operationGeneration: selector.operationGeneration),
            ModelCatalogTransactionSelector(transactionID: selector.transactionID, target: "wrong/model", kind: selector.kind, operationGeneration: selector.operationGeneration)
        ] {
            XCTAssertThrowsError(try store.reconcile(wrong, cancel: true))
            XCTAssertEqual(try Data(contentsOf: path), before)
        }
        XCTAssertEqual(try self.reconcileEventually(store, selector, cancel: true).events.last?.state, "cancelled")
    }

    func testOwnerHashCopyDiskTimeoutAndCleanupFailures() async throws {
        for scenario in ["hash_chunk", "copy_chunk", "disk_full", "timeout", "cleanup_failure", "after_publish_cancel", "publication_race", "published_mutation", "seal_tamper"] {
            let root = try tempDir()
            let source = try tempDir()
            let weights = ["hash_chunk", "copy_chunk"].contains(scenario) ? Data(repeating: 0x61, count: 3 * 1024 * 1024) : Data("weights".utf8)
            try weights.write(to: source.appendingPathComponent("weights.bin"))
            let sha = try ModelArtifactVerifier.canonicalArtifactHash(directory: source)
            let inputs = try fixtureInputs(artifactSHA256: sha)
            let authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: inputs)
            var config = AppConfig.defaults(configPath: root.appendingPathComponent("config.yaml").path)
            config.modelArtifactRoot = root.appendingPathComponent("models").path
            config.supportedModels = ["test-model"]
            let incumbent = Data("model: incumbent\n".utf8)
            try incumbent.write(to: URL(fileURLWithPath: config.configPath))
            let store = ModelCatalogTransactionStore.forConfig(config)
            let id = try store.reserve(authority: authority, kind: "prepare_model")
            var runner = ModelCatalogTransactionRunner(config: config, configPath: URL(fileURLWithPath: config.configPath), store: store,
                inputs: { if scenario == "timeout" { try? await Task.sleep(nanoseconds: 30_000_000_000) }; return inputs },
                downloader: fixtureDownloader(root: root, weights: weights), adoptionLockRoot: root.appendingPathComponent("locks"))
            if scenario == "disk_full" { runner.availableBytes = { _ in 0 } }
            if scenario == "timeout" { runner.timeoutSeconds = 0.1 }
            if scenario == "cleanup_failure" { runner.cleanupOwned = { _, _ in throw POSIXError(.EACCES) } }
            let destination = try CachedModelArtifactResolver.forConfig(config).durableStore.artifactURL(
                modelID: authority.row.modelID, revision: authority.row.modelRevision!, sha256: sha)
            let foreignBytes = Data("other verified object must remain".utf8)
            var chunks = 0
            runner.boundary = { point in
                if scenario == "publication_race" && point == "before_publish" {
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                    try foreignBytes.write(to: destination.appendingPathComponent("weights.bin"))
                }
                if scenario == "published_mutation" && point == "before_terminal" {
                    try foreignBytes.write(to: destination.appendingPathComponent("weights.bin"))
                }
                if scenario == "seal_tamper" && point == "before_terminal" {
                    try store.writePrivate(Data("tampered seal".utf8), to: store.root.appendingPathComponent(id + ".seal"))
                }
                if point == scenario && ["hash_chunk", "copy_chunk"].contains(scenario) {
                    chunks += 1
                    if chunks < 3 { return }
                }
                if point == scenario || (scenario == "after_publish_cancel" && point == "before_terminal") {
                    _ = try self.reconcileEventually(store, id, target: authority.row.modelID, cancel: true)
                }
            }
            do { try await runner.run(id: id, target: authority.row.modelID, kind: "prepare_model") }
            catch { XCTAssertFalse(["cleanup_failure", "after_publish_cancel"].contains(scenario), scenario) }
            if ["hash_chunk", "copy_chunk"].contains(scenario) { XCTAssertGreaterThanOrEqual(chunks, 3) }
            let record = try self.reconcileEventually(store, id, target: authority.row.modelID)
            let success = ["cleanup_failure", "after_publish_cancel"].contains(scenario)
            let failure = ["disk_full", "publication_race", "published_mutation", "seal_tamper"].contains(scenario)
            XCTAssertEqual(record.events.last?.state, success ? "succeeded" : (scenario == "timeout" ? "timed_out" : (failure ? "failed" : "cancelled")), scenario)
            let preserved = ["publication_race", "published_mutation", "seal_tamper"].contains(scenario)
            XCTAssertEqual(FileManager.default.fileExists(atPath: destination.path), success || preserved, scenario)
            if ["publication_race", "published_mutation"].contains(scenario) {
                XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("weights.bin")), foreignBytes)
                let current = DurableModelDiscovery(root: resolverRoot(config), namespace: Data(repeating: 7, count: 32),
                    catalogMatcher: modelCatalogDiscoveryMatcher(inputs: inputs)).discover()
                XCTAssertFalse(current.contains { $0.readinessState == "ready" })
            }
            if scenario == "seal_tamper" {
                XCTAssertEqual(try ModelArtifactVerifier.canonicalArtifactHash(directory: destination), sha)
                XCTAssertThrowsError(try store.validatedPreparationSeal(record))
            }
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: config.configPath)), incumbent)
            if scenario == "cleanup_failure" {
                XCTAssertTrue(record.cleanupRequired)
                XCTAssertEqual(record.events.last?.warningCode, "staging_cleanup_required")
                try store.cleanup(id)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: try store.stagingURL(id).path), scenario)
        }
    }

    func testPreparationOwnerLossAtPersistedBoundariesReconcilesTruth() async throws {
        for stopAt in ["started", "publication_intent", "published", "before_terminal"] {
            let root = try tempDir()
            let source = try tempDir()
            try Data("weights".utf8).write(to: source.appendingPathComponent("weights.bin"))
            let sha = try ModelArtifactVerifier.canonicalArtifactHash(directory: source)
            let inputs = try fixtureInputs(artifactSHA256: sha)
            let authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: inputs)
            var config = AppConfig.defaults(configPath: root.appendingPathComponent("config.yaml").path)
            config.modelArtifactRoot = root.appendingPathComponent("models").path
            config.supportedModels = ["test-model"]
            let store = ModelCatalogTransactionStore.forConfig(config)
            let id = try store.reserve(authority: authority, kind: "prepare_model")
            var runner = ModelCatalogTransactionRunner(config: config, configPath: URL(fileURLWithPath: config.configPath), store: store,
                inputs: { inputs }, downloader: fixtureDownloader(root: root), adoptionLockRoot: root.appendingPathComponent("locks"))
            runner.boundary = { point in
                // Throwing before the final journal write releases the same OS owner lock;
                // actual process-death coverage is separately exercised by the child guard.
                if point == stopAt || point == "before_terminal" { throw ModelCatalogTransactionError.interrupted }
            }
            do { try await runner.run(id: id, target: authority.row.modelID, kind: "prepare_model"); XCTFail(stopAt) } catch {}
            let recovered = try self.reconcileEventually(store, id, target: authority.row.modelID)
            XCTAssertEqual(recovered.events.last?.state, ["published", "before_terminal"].contains(stopAt) ? "succeeded" : "failed", stopAt)
            XCTAssertFalse(FileManager.default.fileExists(atPath: try store.stagingURL(id).path))
        }
    }

    func testOwnedPreparationHeartbeatAndAdoptionLockExcludeConcurrentWork() async throws {
        let root = try tempDir()
        let inputs = try fixtureInputs()
        let authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: inputs)
        var config = AppConfig.defaults(configPath: root.appendingPathComponent("config.yaml").path)
        config.modelArtifactRoot = root.appendingPathComponent("models").path
        config.supportedModels = ["test-model"]
        let store = ModelCatalogTransactionStore.forConfig(config)
        let id = try store.reserve(authority: authority, kind: "prepare_model")
        let locks = root.appendingPathComponent("locks")
        let configURL = URL(fileURLWithPath: config.configPath)
        let runner = ModelCatalogTransactionRunner(config: config, configPath: configURL, store: store,
            inputs: { try? await Task.sleep(nanoseconds: 30_000_000_000); return inputs }, adoptionLockRoot: locks)
        let work = Task { try await runner.run(id: id, target: authority.row.modelID, kind: "prepare_model") }
        do {
            let deadline = Date().addingTimeInterval(8)
            var observed: ModelCatalogTransactionRecord?
            while Date() < deadline {
                let current = try self.reconcileEventually(store, id, target: authority.row.modelID)
                if current.events.count >= 3 { observed = current; break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            let heartbeat = try XCTUnwrap(observed)
            XCTAssertEqual(heartbeat.events.last?.state, "running")
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let start = try XCTUnwrap(formatter.date(from: heartbeat.events[1].emittedAt))
            let latest = try XCTUnwrap(formatter.date(from: heartbeat.events.last!.emittedAt))
            XCTAssertLessThanOrEqual(latest.timeIntervalSince(start), 10)
            XCTAssertThrowsError(try RecommendationAdoptionLock.acquire(configPath: configURL, root: locks))
            do { try await runner.run(id: id, target: authority.row.modelID, kind: "prepare_model"); XCTFail("second owner admitted") } catch {}
            _ = try self.reconcileEventually(store, id, target: authority.row.modelID, cancel: true)
            do { try await work.value; XCTFail("cancelled owner succeeded") } catch {}
            let after = try RecommendationAdoptionLock.acquire(configPath: configURL, root: locks)
            withExtendedLifetime(after) {}
        } catch {
            _ = try? self.reconcileEventually(store, id, target: authority.row.modelID, cancel: true)
            _ = try? await work.value
            throw error
        }
    }

    func testLongVerificationKeepsHeartbeatAndCancellationAvailable() async throws {
        let root = try tempDir(), source = try tempDir()
        try Data("weights".utf8).write(to: source.appendingPathComponent("weights.bin"))
        let sha = try ModelArtifactVerifier.canonicalArtifactHash(directory: source)
        let inputs = try fixtureInputs(artifactSHA256: sha)
        let authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: inputs)
        var config = AppConfig.defaults(configPath: root.appendingPathComponent("config.yaml").path)
        config.modelArtifactRoot = root.appendingPathComponent("models").path; config.supportedModels = [authority.modelKey]
        let store = ModelCatalogTransactionStore.forConfig(config)
        let reservation = try store.reserveOperation(authority: authority, kind: "prepare_model")
        let selector = ModelCatalogTransactionSelector(transactionID: reservation.transactionID, target: authority.row.modelID,
            kind: "prepare_model", operationGeneration: reservation.operationGeneration)
        let contender = try store.reserveOperation(authority: authority, kind: "evaluate_model")
        let maintenance = Process()
        maintenance.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        maintenance.arguments = ["xctest", "-XCTest", "macprovider_cliTests.ModelCatalogTransactionsTests/testBlockedMaintenanceSubprocessEntry", Bundle(for: Self.self).bundlePath]
        maintenance.environment = ["PATH": "/usr/bin:/bin", "HOME": root.path, "TMPDIR": root.path,
            "BUILD1_MAINTENANCE_ROOT": root.path, "BUILD1_MAINTENANCE_JOURNAL": store.root.path]
        maintenance.standardOutput = FileHandle.nullDevice; maintenance.standardError = FileHandle.nullDevice
        defer {
            try? Data("release".utf8).write(to: root.appendingPathComponent("maintenance-release"))
            let stop = Date().addingTimeInterval(3)
            while maintenance.isRunning && Date() < stop { usleep(20_000) }
            if maintenance.isRunning {
                maintenance.terminate()
                let terminated = Date().addingTimeInterval(3)
                while maintenance.isRunning && Date() < terminated { usleep(20_000) }
                XCTAssertFalse(maintenance.isRunning, "maintenance helper did not terminate during cleanup")
            }
        }
        let barrier = Build1VerificationBarrier()
        var runner = ModelCatalogTransactionRunner(config: config, configPath: URL(fileURLWithPath: config.configPath), store: store,
            inputs: { inputs }, downloader: fixtureDownloader(root: root), adoptionLockRoot: root.appendingPathComponent("locks"))
        runner.boundary = { if $0 == "seal_verification" { barrier.blockOnce() } }
        let task = Task { try await runner.run(id: reservation.transactionID, target: authority.row.modelID, kind: "prepare_model") }
        do {
            let deadline = Date().addingTimeInterval(25)
            while !barrier.entered && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
            XCTAssertTrue(barrier.entered)
            try maintenance.run()
            let marker = root.appendingPathComponent("maintenance-blocked")
            while !FileManager.default.fileExists(atPath: marker.path) && Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
            XCTAssertThrowsError(try store.ownerLock(contender.transactionID)) { error in
                guard case ModelCatalogTransactionError.busy = error else {
                    return XCTFail("expected the distinct maintenance UUID owner lock to be held: \(error)")
                }
            }
            let beganMaintenance = Date()
            var record = try self.reconcileEventually(store, selector)
            while (record.events.count < 4 || Date().timeIntervalSince(beganMaintenance) < 10.2) && Date() < deadline {
                try await Task.sleep(nanoseconds: 50_000_000)
                record = try self.reconcileEventually(store, selector)
            }
            XCTAssertGreaterThanOrEqual(record.events.count, 4)
            XCTAssertTrue(maintenance.isRunning)
            let persisted = record.events.filter { $0.state == "running" }
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let times = try persisted.map { try XCTUnwrap(formatter.date(from: $0.emittedAt)) }
            for pair in zip(times, times.dropFirst()) { XCTAssertLessThanOrEqual(pair.1.timeIntervalSince(pair.0), 10) }
            let began = Date()
            XCTAssertEqual(try self.reconcileEventually(store, selector, cancel: true).events.last?.state, "cancel_requested")
            XCTAssertLessThan(Date().timeIntervalSince(began), 1)
            barrier.release()
            do { try await task.value; XCTFail("cancelled verification succeeded") } catch {}
            XCTAssertEqual(try self.reconcileEventually(store, selector).events.last?.state, "cancelled")
            XCTAssertFalse(FileManager.default.fileExists(atPath: try store.stagingURL(reservation.transactionID).path))
            try Data("release".utf8).write(to: root.appendingPathComponent("maintenance-release"))
            let stopped = Date().addingTimeInterval(3)
            while maintenance.isRunning && Date() < stopped { try await Task.sleep(nanoseconds: 20_000_000) }
            XCTAssertFalse(maintenance.isRunning)
            if !maintenance.isRunning { XCTAssertEqual(maintenance.terminationStatus, 75) }
        } catch {
            barrier.release()
            _ = try? self.reconcileEventually(store, selector, cancel: true)
            _ = try? await task.value
            throw error
        }
    }

    func testContendedJournalAndCleanupRootReplacementFailWithoutOutsideMutation() throws {
        let root = try tempDir(), store = ModelCatalogTransactionStore(root: root.appendingPathComponent("transactions"))
        let authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: fixtureInputs())
        let reservation = try store.reserveOperation(authority: authority, kind: "prepare_model")
        let selector = ModelCatalogTransactionSelector(transactionID: reservation.transactionID, target: authority.row.modelID,
            kind: "prepare_model", operationGeneration: reservation.operationGeneration)
        var lock: ModelCatalogFileLock? = try ModelCatalogFileLock(store.root.appendingPathComponent(".journal-lock"))
        let before = try Data(contentsOf: store.root.appendingPathComponent(reservation.transactionID + ".json"))
        let began = Date()
        XCTAssertThrowsError(try store.reconcile(selector, cancel: true))
        XCTAssertLessThan(Date().timeIntervalSince(began), 1)
        XCTAssertEqual(try Data(contentsOf: store.root.appendingPathComponent(reservation.transactionID + ".json")), before)
        withExtendedLifetime(lock) {}; lock = nil
        let staging = try store.stagingURL(reservation.transactionID)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: staging.appendingPathComponent("owned"))
        let moved = root.appendingPathComponent("old-transactions")
        var replaced = false
        XCTAssertThrowsError(try store.cleanup(reservation.transactionID) {
            if !replaced {
                replaced = true
                try FileManager.default.moveItem(at: store.root, to: moved)
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                try Data("outside".utf8).write(to: staging.appendingPathComponent("keep"))
            }
        })
        XCTAssertEqual(try Data(contentsOf: staging.appendingPathComponent("keep")), Data("outside".utf8))
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent("staging-" + reservation.transactionID).appendingPathComponent("owned")), Data("keep".utf8))
    }

    func testShortRecoveryDoesNotTraverseOneHundredThousandStagingEntries() throws {
        let root = try tempDir(), store = ModelCatalogTransactionStore(root: root.appendingPathComponent("transactions"))
        let authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: fixtureInputs())
        let reservation = try store.reserveOperation(authority: authority, kind: "prepare_model")
        let selector = ModelCatalogTransactionSelector(transactionID: reservation.transactionID, target: authority.row.modelID,
            kind: "prepare_model", operationGeneration: reservation.operationGeneration)
        try store.locked {
            var record = try store.load(selector); record.startedAt = Date()
            store.append(&record, state: "running", stage: "preparing"); try store.write(record)
        }
        let staging = try store.stagingURL(reservation.transactionID)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let fd = open(staging.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(fd, 0); defer { close(fd) }
        for index in 0...100_000 {
            let file = openat(fd, "part-" + String(index), O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard file >= 0 else { throw POSIXError(.EIO) }; close(file)
        }
        let began = Date()
        let recovered = try self.reconcileEventually(store, selector, cancel: true)
        XCTAssertLessThan(Date().timeIntervalSince(began), 2)
        XCTAssertTrue(recovered.cleanupRequired)
        XCTAssertEqual(recovered.events.last?.state, "failed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.appendingPathComponent("part-100000").path))
        XCTAssertThrowsError(try store.cleanup(reservation.transactionID))
    }

    func testUnconfirmedCommandRejectsBeforeConfigurationOrJournalAccess() async throws {
        let root = try tempDir()
        let missing = root.appendingPathComponent("missing.yaml").path
        let command = try ModelsPrepareCommand.parse(["untrusted/target", "--transaction-id", UUID().uuidString.lowercased(), "--operation-generation", UUID().uuidString.lowercased(), "--config", missing, "--json"])
        do { try await command.run(); XCTFail("unconfirmed preparation accepted") }
        catch { XCTAssertTrue(String(describing: error).contains("--confirm")) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testActualOwnerProcessDeathAtPreparationJournalBoundaries() throws {
        for point in ["reserved", "started", "publication_intent", "published", "before_terminal", "watchdog_publication_intent", "watchdog_published"] {
            let root = try tempDir()
            let source = root.appendingPathComponent("source")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
            try Data("weights".utf8).write(to: source.appendingPathComponent("weights.bin"))
            let sha = try ModelArtifactVerifier.canonicalArtifactHash(directory: source)
            let inputs = try fixtureInputs(artifactSHA256: sha)
            let authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: inputs)
            var config = AppConfig.defaults(configPath: root.appendingPathComponent("config.yaml").path)
            config.modelArtifactRoot = root.appendingPathComponent("models").path
            let incumbent = Data("model: incumbent\n".utf8)
            try incumbent.write(to: URL(fileURLWithPath: config.configPath))
            let store = ModelCatalogTransactionStore.forConfig(config)
            let id = try store.reserve(authority: authority, kind: "prepare_model")
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            child.arguments = ["xctest", "-XCTest", "macprovider_cliTests.ModelCatalogTransactionsTests/testPreparationCrashSubprocessEntry", Bundle(for: Self.self).bundlePath]
            child.environment = ["PATH": "/usr/bin:/bin", "HOME": root.path, "TMPDIR": root.path,
                "BUILD1_CRASH_ROOT": root.path, "BUILD1_CRASH_POINT": point, "BUILD1_CRASH_ID": id, "BUILD1_CRASH_SHA": sha]
            child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
            let began = Date()
            try child.run()
            let deadline = Date().addingTimeInterval(15)
            while child.isRunning && Date() < deadline { usleep(20_000) }
            if child.isRunning {
                child.terminate()
                let cleanupDeadline = Date().addingTimeInterval(3)
                while child.isRunning && Date() < cleanupDeadline { usleep(20_000) }
                XCTAssertFalse(child.isRunning, "owner helper survived termination at " + point)
                XCTFail("owner helper timed out at " + point)
                throw ModelCatalogTransactionError.timedOut
            }
            let watchdog = point.hasPrefix("watchdog_")
            XCTAssertEqual(child.terminationStatus, watchdog ? 70 : 77, point)
            if watchdog { XCTAssertLessThan(Date().timeIntervalSince(began), 12.5) }
            let record = try self.reconcileEventually(store, id, target: authority.row.modelID)
            let expected = point == "reserved" ? "queued" : (["published", "before_terminal", "watchdog_published"].contains(point) ? "succeeded" : "failed")
            XCTAssertEqual(record.events.last?.state, expected, point)
            let leftover = ["publication_intent", "published", "watchdog_publication_intent", "watchdog_published"].contains(point)
            XCTAssertEqual(FileManager.default.fileExists(atPath: try store.stagingURL(id).path), leftover, point)
            XCTAssertEqual(record.cleanupRequired, leftover, point)
            if leftover { try store.cleanup(id) }
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: config.configPath)), incumbent)
            let destination = try CachedModelArtifactResolver.forConfig(config).durableStore.artifactURL(
                modelID: authority.row.modelID, revision: authority.row.modelRevision!, sha256: sha)
            XCTAssertEqual(FileManager.default.fileExists(atPath: destination.path), expected == "succeeded", point)
        }
    }

    func testPreparationCrashSubprocessEntry() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["BUILD1_CRASH_ROOT"], let point = env["BUILD1_CRASH_POINT"],
              let id = env["BUILD1_CRASH_ID"], let sha = env["BUILD1_CRASH_SHA"] else { return }
        if point == "reserved" { _exit(77) }
        let root = URL(fileURLWithPath: path)
        let inputs = try fixtureInputs(artifactSHA256: sha)
        let authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: inputs)
        var config = AppConfig.defaults(configPath: root.appendingPathComponent("config.yaml").path)
        config.modelArtifactRoot = root.appendingPathComponent("models").path; config.supportedModels = ["test-model"]
        let store = ModelCatalogTransactionStore.forConfig(config)
        var runner = ModelCatalogTransactionRunner(config: config, configPath: URL(fileURLWithPath: config.configPath), store: store,
            inputs: { inputs }, downloader: fixtureDownloader(root: root), adoptionLockRoot: root.appendingPathComponent("locks"))
        runner.boundary = { boundary in
            if point == "watchdog_" + boundary {
                // The real owner retains its journal lock while a filesystem-like
                // stall prevents heartbeat fsync. Its independent guard must exit.
                Thread.sleep(forTimeInterval: 30)
                _exit(79)
            }
            if boundary == point { _exit(77) }
        }
        try await runner.run(id: id, target: authority.row.modelID, kind: "prepare_model")
        _exit(78)
    }

    func testRealPreparedRecommendationOwnerUsesMeasuredProbeAndRestoresLifecycle() async throws {
        for scenario in ["success", "cancel", "timeout", "pressure", "missing", "corrupt", "result_cancel", "foreground", "unrelated_managed", "rate_drift", "pre_result_cancel"] {
            let root = try tempDir()
            let fixture = try Build1FixtureProvider.compile(in: root.appendingPathComponent("provider"),
                options: .init(readyDelayMS: 0, tokenDelayMS: ["cancel", "timeout"].contains(scenario) ? 50 : 1, tokenCount: 100))
            let source = root.appendingPathComponent("source")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
            try Data("weights".utf8).write(to: source.appendingPathComponent("weights.safetensors"))
            try Data(#"{"max_position_embeddings":4096}"#.utf8).write(to: source.appendingPathComponent("config.json"))
            let sha = try ModelArtifactVerifier.canonicalArtifactHash(directory: source)
            let key = "qwen3-coder-30b-a3b-instruct"
            let inputs = try fixtureInputs(artifactSHA256: sha, catalogKey: key)
            let authority = try ModelCatalogTransactionAuthority.resolve(target: key, inputs: inputs)
            var config = AppConfig.defaults(configPath: root.appendingPathComponent("config.yaml").path)
            config.modelArtifactRoot = root.appendingPathComponent("models").path; config.supportedModels = [key]
            let configURL = URL(fileURLWithPath: config.configPath)
            let incumbent = Data("model: incumbent\n".utf8); try incumbent.write(to: configURL)
            let store = ModelCatalogTransactionStore.forConfig(config)
            let prepareID = try store.reserve(authority: authority, kind: "prepare_model")
            let preparation = ModelCatalogTransactionRunner(config: config, configPath: configURL, store: store,
                inputs: { inputs }, downloader: fixtureDownloader(root: root, readyArtifact: true), adoptionLockRoot: root.appendingPathComponent("locks"))
            try await preparation.run(id: prepareID, target: authority.row.modelID, kind: "prepare_model")
            let artifact = try CachedModelArtifactResolver.forConfig(config).durableStore.artifactURL(
                modelID: authority.row.modelID, revision: authority.row.modelRevision!, sha256: sha)
            if scenario == "missing" { try FileManager.default.removeItem(at: artifact) }
            if scenario == "corrupt" { try Data("corrupt".utf8).write(to: artifact.appendingPathComponent("weights.safetensors")) }
            let id = try store.reserve(authority: authority, kind: "evaluate_model")
            let secret = root.appendingPathComponent("test-secret")
            try Data(repeating: 7, count: 32).write(to: secret); XCTAssertEqual(chmod(secret.path, 0o600), 0)
            var lifecycle: [String] = []
            var candidates: [CandidateProviderRunner] = []
            var runner = ModelCatalogTransactionRunner(config: config, configPath: configURL, store: store,
                inputs: { inputs }, adoptionLockRoot: root.appendingPathComponent("locks"))
            runner.managedContext = (configURL, secret)
            runner.detectConflict = { scenario == "foreground" ? .foreground(pid: getpid(), argv: ["fixture"]) : .launchdManaged(pid: nil) }
            if scenario == "unrelated_managed" { runner.managedContext.config = root.appendingPathComponent("another-config.yaml") }
            runner.drainer = ProviderDrainer(plistURL: root.appendingPathComponent("fixture.plist"),
                launchctlRunner: { _, args in lifecycle.append(args[0]) }, portIsOpen: { _ in false },
                launchdRestoreGuardStarter: { _, _ in ProviderLaunchdRestoreGuard(dismissHandler: { lifecycle.append("dismiss") }) })
            runner.hardware = { identity in .init(machine: "Fixture", chip: "Apple M4 Pro", memoryGB: 64, bandwidthTier: .a,
                osVersion: "fixture", binaryVersion: "fixture", diversificationID: identity.diversificationID, hardwareIdentityHash: identity.cacheIdentityHash) }
            runner.port = try Build1FixtureProvider.unusedPort()
            if scenario == "timeout" { runner.timeoutSeconds = 1 }
            runner.benchmarker = { resolver, logs, check in
                let spy = HuggingFaceSnapshotDownloader(fetch: { _ in XCTFail("metadata downloader invoked during prepared evaluation"); throw CancellationError() },
                    download: { _ in XCTFail("weight downloader invoked during prepared evaluation"); throw CancellationError() })
                let offline = CachedModelArtifactResolver(hubRoot: root.appendingPathComponent("empty-hf"), durableRoot: resolver.durableRoot, downloader: spy)
                return AutotuneRecommendationBenchmarker(telemetryDirectory: logs, artifactResolver: offline,
                    runnerFactory: {
                        let child = try CandidateProviderRunner(providerBinaryPath: fixture.binaryURL.path, configPath: configURL.path, logDirectory: logs, publicationCheck: check)
                        candidates.append(child); return child
                    }, prober: Stage1Prober(readyTimeoutSec: 5, stopGraceSeconds: 0.2, probeIdleTimeoutSec: 10, probeTotalTimeoutSec: 10),
                    safetySampler: Build1OwnerSafetySampler(critical: scenario == "pressure"))
            }
            var inputReads = 0
            runner.inputs = {
                inputReads += 1
                var value = inputs
                if inputReads > 1 && scenario == "rate_drift" { value.rateCard.warnings.insert(.rateCardStale) }
                if inputReads > 1 && scenario == "pre_result_cancel" { _ = try? self.reconcileEventually(store, id, target: authority.row.modelID, cancel: true) }
                return value
            }
            let resultBarrier = Build1VerificationBarrier()
            let resultWrites = Build1LockedCounter()
            defer { resultBarrier.release() }
            let originalSelector = try XCTUnwrap(store.load(id, target: authority.row.modelID).selector)
            runner.boundary = { point in
                if scenario == "success", point == "before_result_capture" { resultBarrier.blockOnce() }
                if point == "result_written" { resultWrites.increment() }
                if scenario == "result_cancel", point == "before_terminal" { _ = try self.reconcileEventually(store, id, target: authority.row.modelID, cancel: true) }
            }
            let work = Task { try await runner.run(id: id, target: authority.row.modelID, kind: "evaluate_model") }
            if scenario == "cancel" {
                let deadline = Date().addingTimeInterval(8)
                while Date() < deadline {
                    if (try? fixture.observations().contains { $0["event"] as? String == "chat" }) == true { break }
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                _ = try self.reconcileEventually(store, id, target: authority.row.modelID, cancel: true)
            }
            if scenario == "success" {
                let deadline = Date().addingTimeInterval(8)
                while !resultBarrier.entered && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
                XCTAssertTrue(resultBarrier.entered)
                var journal: ModelCatalogFileLock? = try ModelCatalogFileLock(store.root.appendingPathComponent(".journal-lock"))
                resultBarrier.release()
                try await Task.sleep(nanoseconds: 100_000_000)
                withExtendedLifetime(journal) {}; journal = nil
            }
            let successful = ["success", "result_cancel"].contains(scenario)
            do { try await work.value; XCTAssertTrue(successful, scenario) }
            catch { XCTAssertFalse(successful, "\(scenario): \(error)") }
            XCTAssertEqual(try Data(contentsOf: configURL), incumbent, scenario)
            XCTAssertFalse(MacProviderPortProbe.isOpen(runner.port), scenario)
            XCTAssertTrue(candidates.allSatisfy { $0.activeProcessIdentifierForTesting() == nil }, scenario)
            if let pid = (try? String(contentsOf: fixture.pidURL)).flatMap(Int32.init) {
                XCTAssertNotEqual(kill(pid, 0), 0, "fixture process survived " + scenario)
            }
            if ["missing", "corrupt", "foreground", "unrelated_managed"].contains(scenario) {
                XCTAssertTrue(candidates.isEmpty, scenario); XCTAssertTrue(lifecycle.isEmpty, scenario)
            } else { XCTAssertEqual(lifecycle, ["bootout", "bootstrap", "dismiss"], scenario) }
            let record = try self.reconcileEventually(store, id, target: authority.row.modelID)
            XCTAssertEqual(record.events.last?.state, successful ? "succeeded" : (["cancel", "pre_result_cancel"].contains(scenario) ? "cancelled" : (scenario == "timeout" ? "timed_out" : "failed")), scenario)
            XCTAssertEqual(record.selector, originalSelector, scenario)
            if successful {
                XCTAssertEqual(resultWrites.count, 1, scenario)
                let data = try store.result(id, target: authority.row.modelID)
                let parsed = try ModelsAdoptRecommendationCommand.parseRecommendation(data: data)
                try ModelsAdoptRecommendationCommand.validateSignedCatalogBinding(recommendation: parsed, catalogKey: key, row: authority.row)
                let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                let rows = try XCTUnwrap(document["candidates"] as? [[String: Any]])
                let selected = try XCTUnwrap(rows.first { $0["model"] as? String == key })
                let explanation = try XCTUnwrap(selected["explanation"] as? [String: Any])
                let measured = try XCTUnwrap(explanation["measured_tps"] as? NSNumber).doubleValue
                XCTAssertGreaterThan(measured, 100)
                XCTAssertNotEqual(measured, authority.row.benchGate.minSustainedTPS)
                XCTAssertEqual(explanation["throughput_source"] as? String, "measured")
                XCTAssertEqual(parsed.core.modelArtifactSHA256, sha)
                XCTAssertEqual(parsed.core.modelCatalogModelID, authority.row.modelID)
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("empty-hf").path))
                let resultURL = store.root.appendingPathComponent(id + ".result")
                try Data("substituted".utf8).write(to: resultURL)
                XCTAssertThrowsError(try store.result(id, target: authority.row.modelID))
                try data.write(to: resultURL)
            } else { XCTAssertThrowsError(try store.result(id, target: authority.row.modelID), scenario) }
        }
    }

    func testActualEvaluationOwnerDeathPreservesOnlyDigestBoundCommittedResult() async throws {
        for point in ["during_probe", "watchdog_during_probe", "result_written", "result_committed", "before_terminal",
                      "success_binding_published", "success_binding_referenced", "success_terminal_published",
                      "cleanup_failed_success_binding_published", "cleanup_resolved_success_binding_published",
                      "watchdog_success_binding_published", "watchdog_success_binding_referenced", "watchdog_success_terminal_published"] {
            let root = try tempDir()
            let provider = try Build1FixtureProvider.compile(in: root.appendingPathComponent("provider"),
                options: .init(readyDelayMS: 0, tokenDelayMS: point.contains("during_probe") ? 200 : 1, tokenCount: 100))
            let source = root.appendingPathComponent("source")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
            try Data("weights".utf8).write(to: source.appendingPathComponent("weights.safetensors"))
            try Data(#"{"max_position_embeddings":4096}"#.utf8).write(to: source.appendingPathComponent("config.json"))
            let sha = try ModelArtifactVerifier.canonicalArtifactHash(directory: source)
            let key = "qwen3-coder-30b-a3b-instruct"
            let inputs = try fixtureInputs(artifactSHA256: sha, catalogKey: key)
            let authority = try ModelCatalogTransactionAuthority.resolve(target: key, inputs: inputs)
            var config = AppConfig.defaults(configPath: root.appendingPathComponent("config.yaml").path)
            config.modelArtifactRoot = root.appendingPathComponent("models").path; config.supportedModels = [key]
            let configURL = URL(fileURLWithPath: config.configPath)
            let incumbent = Data("model: incumbent\nmodel_artifact_root: \(config.modelArtifactRoot!)\n".utf8)
            try incumbent.write(to: configURL)
            let store = ModelCatalogTransactionStore.forConfig(config)
            let prepareID = try store.reserve(authority: authority, kind: "prepare_model")
            let preparation = ModelCatalogTransactionRunner(config: config, configPath: configURL, store: store,
                inputs: { inputs }, downloader: fixtureDownloader(root: root, readyArtifact: true), adoptionLockRoot: root.appendingPathComponent("locks"))
            try await preparation.run(id: prepareID, target: authority.row.modelID, kind: "prepare_model")
            let id = try store.reserve(authority: authority, kind: "evaluate_model")
            let port = try Build1FixtureProvider.unusedPort()
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            child.arguments = ["xctest", "-XCTest", "macprovider_cliTests.ModelCatalogTransactionsTests/testEvaluationCrashSubprocessEntry", Bundle(for: Self.self).bundlePath]
            child.environment = ["PATH": "/usr/bin:/bin", "HOME": root.path, "TMPDIR": root.path,
                "BUILD1_EVAL_ROOT": root.path, "BUILD1_EVAL_POINT": point, "BUILD1_EVAL_ID": id, "BUILD1_EVAL_SHA": sha, "BUILD1_EVAL_PORT": String(port)]
            child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
            let ownerBegan = Date()
            try child.run()
            var journalLock: ModelCatalogFileLock?
            defer { withExtendedLifetime(journalLock) {} }
            var contentionBegan: Date?
            if point.contains("during_probe") {
                let activeDeadline = Date().addingTimeInterval(10)
                var sawChat = false
                while child.isRunning && Date() < activeDeadline {
                    sawChat = (try? provider.observations().contains { $0["event"] as? String == "chat" }) == true
                    if sawChat { break }
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                XCTAssertTrue(sawChat, "fixture never began real probe")
                if point == "watchdog_during_probe" {
                    journalLock = try ModelCatalogFileLock(store.root.appendingPathComponent(".journal-lock"))
                    contentionBegan = Date()
                } else { XCTAssertEqual(kill(child.processIdentifier, SIGKILL), 0) }
            }
            let deadline = Date().addingTimeInterval(20)
            while child.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
            if child.isRunning {
                child.terminate()
                let cleanupDeadline = Date().addingTimeInterval(3)
                while child.isRunning && Date() < cleanupDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
                XCTAssertFalse(child.isRunning, "evaluation owner survived termination")
                XCTFail("evaluation owner helper timed out")
                throw ModelCatalogTransactionError.timedOut
            }
            XCTAssertEqual(child.terminationStatus, point.hasPrefix("watchdog_") ? 70 : (point == "during_probe" ? SIGKILL : 77), point)
            if point.hasPrefix("watchdog_success_") { XCTAssertLessThan(Date().timeIntervalSince(ownerBegan), 12.5) }
            if let contentionBegan { XCTAssertLessThan(Date().timeIntervalSince(contentionBegan), 12.5) }
            withExtendedLifetime(journalLock) {}; journalLock = nil
            let stopDeadline = Date().addingTimeInterval(5)
            while MacProviderPortProbe.isOpen(port) && Date() < stopDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
            XCTAssertFalse(MacProviderPortProbe.isOpen(port))
            if let pid = (try? String(contentsOf: provider.pidURL)).flatMap(Int32.init) {
                while kill(pid, 0) == 0 && Date() < stopDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
                XCTAssertNotEqual(kill(pid, 0), 0, "fixture survived owner death")
            }
            XCTAssertEqual(try Data(contentsOf: configURL), incumbent)
            let resultURL = store.root.appendingPathComponent(id + ".result")
            let original = try? store.readPrivate(resultURL)
            let bindingURL = store.root.appendingPathComponent(id + ".success-binding")
            let bindingBytes = try? store.readPrivate(bindingURL)
            let binding = try bindingBytes.map { try JSONDecoder().decode(ModelTransactionSuccessBinding.self, from: $0) }
            var expectedTerminalBytes: Data?
            if let binding {
                let before = try store.load(id, target: authority.row.modelID)
                let expected = before.terminal ? before : try store.evaluationSuccessTerminal(preterminal: before,
                    cleanupRequired: binding.terminalDelta.cleanupRequired, event: binding.terminalEvent)
                expectedTerminalBytes = try store.canonicalData(expected)
                XCTAssertEqual(SHA256.hash(data: expectedTerminalBytes!).map { String(format: "%02x", $0) }.joined(), binding.terminalPrimarySHA256, point)
                XCTAssertEqual(binding.terminalDelta.cleanupRequired, point.hasPrefix("cleanup_failed_"), point)
                if point.hasPrefix("cleanup_resolved_") { XCTAssertTrue(before.cleanupRequired) }
                if point.hasPrefix("cleanup_failed_") { XCTAssertFalse(before.cleanupRequired) }
                if !before.terminal {
                    let beforeBytes = try store.readPrivate(store.root.appendingPathComponent(id + ".json"))
                    var replayOwner: ModelCatalogFileLock? = try store.ownerLock(id)
                    XCTAssertThrowsError(try store.reconcile(try XCTUnwrap(before.selector), cancel: true))
                    XCTAssertEqual(try store.readPrivate(store.root.appendingPathComponent(id + ".json")), beforeBytes)
                    XCTAssertEqual(try store.readPrivate(bindingURL), bindingBytes)
                    withExtendedLifetime(replayOwner) {}; replayOwner = nil
                }
            }
            let record = try self.reconcileEventually(store, id, target: authority.row.modelID, cancel: binding != nil)
            if let expectedTerminalBytes {
                XCTAssertEqual(try store.readPrivate(store.root.appendingPathComponent(id + ".json")), expectedTerminalBytes, point)
                XCTAssertEqual(try store.readPrivate(bindingURL), bindingBytes, point)
                XCTAssertEqual(record.events.last, binding?.terminalEvent, point)
                XCTAssertEqual(try self.reconcileEventually(store, id, target: authority.row.modelID, cancel: true).events, record.events, point)
            }
            if ["during_probe", "watchdog_during_probe", "result_written"].contains(point) {
                XCTAssertEqual(record.events.last?.state, "failed")
                XCTAssertThrowsError(try store.result(id, target: authority.row.modelID))
            } else {
                XCTAssertEqual(record.events.last?.state, "succeeded")
                let original = try XCTUnwrap(original)
                XCTAssertEqual(try store.result(id, target: authority.row.modelID), original)
                if point.hasPrefix("cleanup_failed_") {
                    let successDigest = try store.successDigest(record)
                    let recovery = try XCTUnwrap(makeModelCatalogRecoveries(store: store).first { $0.action.transactionID == id })
                    XCTAssertEqual(recovery.targetModelID, authority.row.modelID)
                    let cleanupGeneration = try XCTUnwrap(recovery.action.operationGeneration)
                    let command = try ModelsCleanupStagingCommand.parse([id, "--model", authority.row.modelID,
                        "--operation-generation", cleanupGeneration, "--config", configURL.path, "--confirm", "--json"])
                    try await command.run()
                    let updated = try store.reconcile(try XCTUnwrap(record.selector))
                    XCTAssertFalse(updated.cleanupRequired)
                    XCTAssertFalse(FileManager.default.fileExists(atPath: try store.stagingURL(id).path))
                    XCTAssertEqual(try store.successDigest(updated), successDigest)
                    XCTAssertEqual(try store.readPrivate(bindingURL), bindingBytes)
                    XCTAssertEqual(try store.result(id, target: authority.row.modelID), original)
                    XCTAssertEqual(try Data(contentsOf: configURL), incumbent)
                    XCTAssertEqual(try store.load(id, target: authority.row.modelID, cleanup: true).events.last?.state, "succeeded")
                }
                try Data("substitution".utf8).write(to: resultURL)
                XCTAssertThrowsError(try store.result(id, target: authority.row.modelID))
                var historical = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
                historical["generated_at"] = "2020-01-01T00:00:00Z"
                let historicalBytes = try JSONSerialization.data(withJSONObject: historical, options: [.sortedKeys])
                var historicalRecord = record
                historicalRecord.resultSHA256 = SHA256.hash(data: historicalBytes).map { String(format: "%02x", $0) }.joined()
                XCTAssertEqual(try store.validatedCommittedResult(historicalRecord, data: historicalBytes), historicalBytes)
                // Historical parsing is independent of current action age. It does
                // not authorize replacing a result protected by a success binding.
                XCTAssertThrowsError(try store.result(id, target: authority.row.modelID))
                XCTAssertThrowsError(try ModelsAdoptRecommendationCommand.parseRecommendation(data: historicalBytes))
            }
        }
    }

    func testEvaluationCrashSubprocessEntry() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["BUILD1_EVAL_ROOT"], let point = env["BUILD1_EVAL_POINT"], let id = env["BUILD1_EVAL_ID"],
              let sha = env["BUILD1_EVAL_SHA"], let port = env["BUILD1_EVAL_PORT"].flatMap(Int.init) else { return }
        let root = URL(fileURLWithPath: path)
        let key = "qwen3-coder-30b-a3b-instruct"
        let inputs = try fixtureInputs(artifactSHA256: sha, catalogKey: key)
        let authority = try ModelCatalogTransactionAuthority.resolve(target: key, inputs: inputs)
        var config = AppConfig.defaults(configPath: root.appendingPathComponent("config.yaml").path)
        config.modelArtifactRoot = root.appendingPathComponent("models").path; config.supportedModels = [key]
        let configURL = URL(fileURLWithPath: config.configPath)
        var store = ModelCatalogTransactionStore.forConfig(config)
        let publicationPoint = point.replacingOccurrences(of: "watchdog_", with: "")
            .replacingOccurrences(of: "cleanup_failed_", with: "").replacingOccurrences(of: "cleanup_resolved_", with: "")
        store.retentionBoundary = { boundary in
            if boundary == publicationPoint {
                if point.hasPrefix("watchdog_") { usleep(30_000_000) }
                _exit(77)
            }
        }
        var runner = ModelCatalogTransactionRunner(config: config, configPath: configURL, store: store,
            inputs: { inputs }, adoptionLockRoot: root.appendingPathComponent("locks"))
        runner.port = port; runner.detectConflict = { .none }
        runner.hardware = { identity in .init(machine: "Fixture", chip: "Apple M4 Pro", memoryGB: 64, bandwidthTier: .a,
            osVersion: "fixture", binaryVersion: "fixture", diversificationID: identity.diversificationID, hardwareIdentityHash: identity.cacheIdentityHash) }
        runner.benchmarker = { resolver, logs, check in
            AutotuneRecommendationBenchmarker(telemetryDirectory: logs, artifactResolver: resolver,
                runnerFactory: { try CandidateProviderRunner(providerBinaryPath: root.appendingPathComponent("provider/fixture-provider").path,
                    configPath: configURL.path, logDirectory: logs, publicationCheck: check) },
                prober: Stage1Prober(readyTimeoutSec: 5, stopGraceSeconds: 0.2), safetySampler: Build1OwnerSafetySampler(critical: false))
        }
        if point.hasPrefix("cleanup_failed_") || point.hasPrefix("cleanup_resolved_") {
            runner.cleanupOwned = { store, id in
                let staging = try store.stagingURL(id)
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                try Data("owned partial".utf8).write(to: staging.appendingPathComponent("partial"))
                if point.hasPrefix("cleanup_failed_") { throw POSIXError(.EACCES) }
                let selector = try XCTUnwrap(store.load(id, target: authority.row.modelID).selector)
                _ = try store.update(selector) { $0.cleanupRequired = true }
                try store.cleanup(id)
            }
        }
        runner.boundary = { if $0 == point { _exit(77) } }
        try await runner.run(id: id, target: authority.row.modelID, kind: "evaluate_model")
        _exit(78)
    }

    func testActualCleanupOwnerFencePreservesOriginalTruthAndRemainingStaging() throws {
        let root = try tempDir()
        let authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: fixtureInputs())
        let configURL = root.appendingPathComponent("config.yaml")
        let durableRoot = root.appendingPathComponent("models")
        let configBytes = Data("model: incumbent\nmodel_artifact_root: \(durableRoot.path)\n".utf8)
        try configBytes.write(to: configURL)
        let store = ModelCatalogTransactionStore(root: durableRoot.appendingPathComponent(".transactions"))
        let reserved = try store.reserveOperation(authority: authority, kind: "prepare_model")
        let originalSelector = ModelCatalogTransactionSelector(transactionID: reserved.transactionID, target: authority.row.modelID,
            kind: "prepare_model", operationGeneration: reserved.operationGeneration)
        _ = try store.update(originalSelector) { record in
            record.cleanupRequired = true
            store.append(&record, state: "failed", error: "fixture_interrupted")
        }
        let originalBytes = try store.readPrivate(store.root.appendingPathComponent(reserved.transactionID + ".json"))
        let staging = try store.stagingURL(reserved.transactionID)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let directory = open(staging.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw POSIXError(.EIO) }
        for index in 0..<5_000 {
            let file = openat(directory, "part-" + String(index), O_CREAT | O_EXCL | O_WRONLY, 0o600)
            guard file >= 0 else { close(directory); throw POSIXError(.EIO) }; close(file)
        }
        close(directory)
        let cleanup = try store.reserveCleanup(id: reserved.transactionID, target: authority.row.modelID)
        let selector = ModelCatalogTransactionSelector(transactionID: cleanup.transactionID, target: authority.row.modelID,
            kind: "cleanup_staging", operationGeneration: cleanup.operationGeneration)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = ["xctest", "-XCTest", "macprovider_cliTests.ModelCatalogTransactionsTests/testCleanupWatchdogSubprocessEntry", Bundle(for: Self.self).bundlePath]
        child.environment = ["PATH": "/usr/bin:/bin", "HOME": root.path, "TMPDIR": root.path,
            "BUILD1_CLEANUP_CONFIG": configURL.path, "BUILD1_CLEANUP_ID": selector.transactionID,
            "BUILD1_CLEANUP_TARGET": selector.target, "BUILD1_CLEANUP_GENERATION": selector.operationGeneration]
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        var journalLock: ModelCatalogFileLock?
        defer {
            withExtendedLifetime(journalLock) {}; journalLock = nil
            if child.isRunning {
                child.terminate()
                let stopped = Date().addingTimeInterval(3)
                while child.isRunning && Date() < stopped { usleep(20_000) }
                XCTAssertFalse(child.isRunning, "cleanup helper did not terminate")
            }
        }
        try child.run()
        let startedDeadline = Date().addingTimeInterval(8)
        var running = false
        while child.isRunning && Date() < startedDeadline {
            running = (try? store.load(selector).events.last?.state) == "running"
            if running { break }; usleep(5_000)
        }
        XCTAssertTrue(running, "actual cleanup command did not start")
        journalLock = try ModelCatalogFileLock(store.root.appendingPathComponent(".journal-lock"))
        let began = Date(), deadline = Date().addingTimeInterval(13)
        while child.isRunning && Date() < deadline { usleep(20_000) }
        XCTAssertFalse(child.isRunning, "cleanup watchdog did not exit")
        if child.isRunning {
            child.terminate()
            let stopped = Date().addingTimeInterval(3)
            while child.isRunning && Date() < stopped { usleep(20_000) }
        }
        guard !child.isRunning else { throw ModelCatalogTransactionError.timedOut }
        // Cooperative cleanup may finish its failure exit after the eight-second
        // fence; otherwise the independent watchdog exits70 by ten seconds.
        XCTAssertTrue([Int32(1), Int32(70)].contains(child.terminationStatus))
        XCTAssertGreaterThan(Date().timeIntervalSince(began), 7)
        XCTAssertLessThan(Date().timeIntervalSince(began), 12.5)
        withExtendedLifetime(journalLock) {}; journalLock = nil
        XCTAssertEqual(try store.readPrivate(store.root.appendingPathComponent(reserved.transactionID + ".json")), originalBytes)
        XCTAssertEqual(try Data(contentsOf: configURL), configBytes)
        XCTAssertGreaterThan(try FileManager.default.contentsOfDirectory(atPath: staging.path).count, 0)
        let recovered = try self.reconcileEventually(store, selector)
        XCTAssertEqual(recovered.events.last?.state, "failed")
        XCTAssertTrue(recovered.cleanupRequired)
        let released = try store.ownerLock(selector.transactionID)
        withExtendedLifetime(released) {}
    }

    func testCleanupWatchdogSubprocessEntry() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let config = environment["BUILD1_CLEANUP_CONFIG"], let id = environment["BUILD1_CLEANUP_ID"],
              let target = environment["BUILD1_CLEANUP_TARGET"], let generation = environment["BUILD1_CLEANUP_GENERATION"] else { return }
        let command = try ModelsCleanupStagingCommand.parse([id, "--model", target, "--operation-generation", generation,
            "--config", config, "--confirm", "--json"])
        try await command.run()
        _exit(78)
    }

    func testBlockedMaintenanceSubprocessEntry() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["BUILD1_MAINTENANCE_ROOT"], let journal = environment["BUILD1_MAINTENANCE_JOURNAL"] else { return }
        let root = URL(fileURLWithPath: path)
        var store = ModelCatalogTransactionStore(root: URL(fileURLWithPath: journal))
        store.retentionBoundary = { point in
            guard point == "bulk_read" else { return }
            try Data("blocked".utf8).write(to: root.appendingPathComponent("maintenance-blocked"))
            while !FileManager.default.fileExists(atPath: root.appendingPathComponent("maintenance-release").path) { usleep(20_000) }
        }
        do { try store.maintainRetention(); _exit(74) }
        catch ModelCatalogTransactionError.busy { _exit(75) }
        catch { _exit(76) }
    }

    private func reconcileEventually(_ store: ModelCatalogTransactionStore, _ id: String, target: String,
                                     cancel: Bool = false, original: Bool = false) throws -> ModelCatalogTransactionRecord {
        try retryBusy { try store.reconcile(id, target: target, cancel: cancel, original: original) }
    }
    private func reconcileEventually(_ store: ModelCatalogTransactionStore, _ selector: ModelCatalogTransactionSelector,
                                     cancel: Bool = false) throws -> ModelCatalogTransactionRecord {
        try retryBusy { try store.reconcile(selector, cancel: cancel) }
    }
    private func retryBusy<T>(_ body: () throws -> T) throws -> T {
        let deadline = Date().addingTimeInterval(2)
        while true {
            do { return try body() }
            catch ModelCatalogTransactionError.busy {
                guard Date() < deadline else { throw ModelCatalogTransactionError.busy }
                usleep(10_000)
            }
            catch ModelCatalogRetentionError.changed {
                guard Date() < deadline else { throw ModelCatalogTransactionError.busy }
                usleep(10_000)
            }
        }
    }

    private func fixtureDownloader(root: URL, readyArtifact: Bool = false, weights: Data = Data("weights".utf8)) -> HuggingFaceSnapshotDownloader {
        HuggingFaceSnapshotDownloader(fetch: { request in
            (Data((readyArtifact ? #"{"siblings":[{"rfilename":"weights.safetensors"},{"rfilename":"config.json"}]}"# : #"{"siblings":[{"rfilename":"weights.bin"}]}"#).utf8),
             HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, download: { request in
            let path = root.appendingPathComponent("transfer-" + UUID().uuidString)
            try (request.url!.lastPathComponent == "config.json" ? Data(#"{"max_position_embeddings":4096}"#.utf8) : weights).write(to: path)
            return (path, URLResponse(url: request.url!, mimeType: nil, expectedContentLength: 7, textEncodingName: nil))
        })
    }

    private func fixtureInputs(artifactSHA256: String? = nil, catalogKey: String = "test-model") throws -> ModelCatalogRecommendationInputs {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/tests/fixtures/artifact_feed_conformance.json")
        let corpus = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var candidateObject = try XCTUnwrap(corpus["candidate"] as? [String: Any])
        var feed = try XCTUnwrap(corpus["feed"] as? [String: Any])
        if let artifactSHA256 {
            var rows = candidateObject["rows"] as! [String: [String: Any]]
            rows["test-model"]!["model_sha256"] = artifactSHA256
            candidateObject["rows"] = rows
            var models = feed["models"] as! [String: [String: Any]]
            var model = models["test-model"]!
            var artifacts = model["artifacts"] as! [String: [String: Any]]
            let primary = model["primary_artifact_id"] as! String
            artifacts[primary]!["hash"] = artifactSHA256
            artifacts[primary]!["size_bytes"] = 1024
            model["artifacts"] = artifacts; models["test-model"] = model; feed["models"] = models
        }
        if catalogKey != "test-model" {
            var rows = candidateObject["rows"] as! [String: Any]
            rows[catalogKey] = rows.removeValue(forKey: "test-model"); candidateObject["rows"] = rows
            var models = feed["models"] as! [String: Any]
            models[catalogKey] = models.removeValue(forKey: "test-model"); feed["models"] = models
        }
        let candidate = try JSONSerialization.data(withJSONObject: candidateObject, options: [.sortedKeys, .withoutEscapingSlashes])
        feed["candidate_catalog_sha256"] = AutotuneStaticInputs.candidateCatalogSHA256(bytes: candidate)
        let bytes = try JSONSerialization.data(withJSONObject: feed, options: [.sortedKeys, .withoutEscapingSlashes])
        let signer = "fixture-only"
        let qualified = try XCTUnwrap(AutotuneStaticInputs.usableArtifactFeed(bakedBytes: bytes, bakedSignerKeyID: signer,
            candidateBytes: candidate, candidateSignerKeyID: signer, now: ISO8601DateFormatter().date(from: "2026-07-11T00:00:00Z")!))
        let demand = Data(AutotuneStaticInputs.bakedDemandRankJSON.utf8)
        let rate = Data(AutotuneStaticInputs.bakedRateCardJSON.utf8)
        return (.init(value: try AutotuneStaticInputs.decodeDemandRank(demand), selectedBytes: demand, warnings: [], usedFallback: false, signerKeyID: signer),
                .init(value: try AutotuneStaticInputs.decodeSignedStaticCandidateCatalog(candidate), selectedBytes: candidate, warnings: [], usedFallback: false, signerKeyID: signer),
                .init(value: try AutotuneStaticInputs.decodeRateCard(rate), selectedBytes: rate, warnings: [], usedFallback: false, signerKeyID: signer),
                .init(value: qualified, selectedBytes: bytes, warnings: [], usedFallback: false, signerKeyID: signer))
    }
    private func tempDir() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ModelCatalogTransactionsTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}

private struct Build1OwnerSafetySampler: ProbeSafetySampling {
    let critical: Bool
    func sample() -> ProbeSafetySample { .init(pressureLevel: critical ? .critical : .normal, thermalState: .nominal) }
}

private final class Build1VerificationBarrier: @unchecked Sendable {
    private let condition = NSCondition()
    private var didEnter = false
    private var released = false
    var entered: Bool { condition.lock(); defer { condition.unlock() }; return didEnter }
    func blockOnce() {
        condition.lock(); defer { condition.unlock() }
        if didEnter { return }; didEnter = true
        let deadline = Date().addingTimeInterval(20)
        while !released && condition.wait(until: deadline) {}
    }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
}

private actor Build1TransferCounter {
    private var count = 0
    func increment() -> Int { count += 1; return count }
    func snapshot() -> Int { count }
}

private final class Build1LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func increment() { lock.lock(); value += 1; lock.unlock() }
}
