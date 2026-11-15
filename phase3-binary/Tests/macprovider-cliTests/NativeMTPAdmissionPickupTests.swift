import CryptoKit
import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

/// SPEC-048-R013 admission pickup: the delay bound, the once-per-release
/// record, the wait for requests in flight, and the guards of the check.
/// The trigger, no-duplicate, no-loop and drain cases are in
/// `CoordinatorClientTests`.
final class NativeMTPAdmissionPickupTests: XCTestCase {
    func testJitterStaysInsideItsBoundForAnySample() {
        let range = NativeMTPAdmissionPickup.jitterRangeSeconds
        XCTAssertEqual(range.lowerBound, 60)
        XCTAssertEqual(range.upperBound, 1800)
        XCTAssertEqual(NativeMTPAdmissionPickup.jitterSeconds(unit: 0), range.lowerBound)
        XCTAssertEqual(NativeMTPAdmissionPickup.jitterSeconds(unit: 1), range.upperBound)
        XCTAssertEqual(NativeMTPAdmissionPickup.jitterSeconds(unit: 0.5), 930)
        let samples: [Double] = [-1, -0.0001, 0.25, 0.9999, 1.0001, 2, 1e308, -Double.infinity, Double.infinity, Double.nan]
        for unit in samples {
            XCTAssertTrue(range.contains(NativeMTPAdmissionPickup.jitterSeconds(unit: unit)), "unit \(unit)")
        }
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<1_000 {
            let unit = Double.random(in: 0...1, using: &generator)
            XCTAssertTrue(range.contains(NativeMTPAdmissionPickup.jitterSeconds(unit: unit)))
        }
        // The default sample source feeds the same mapping.
        let hooks = NativeMTPAdmissionPickup.Hooks(newlyActivatable: { _ in .notActivatable }, claim: { _ in false }, supervised: { false })
        for _ in 0..<1_000 {
            XCTAssertTrue(range.contains(NativeMTPAdmissionPickup.jitterSeconds(unit: hooks.randomUnit())))
        }
    }

    private func temporaryStoreURL() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-mtp-admission-pickup-store-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent(NativeMTPAdmissionPickupStore.fileName)
    }

    func testStoreClaimsAReleaseOnceAcrossInstances() throws {
        let url = temporaryStoreURL()
        let first = NativeMTPAdmissionPickupStore(url: url)
        XCTAssertFalse(first.contains("release-b"))
        XCTAssertTrue(first.claim("release-b"))
        XCTAssertFalse(first.claim("release-b"))
        // A later process reads the same record.
        let second = NativeMTPAdmissionPickupStore(url: url)
        XCTAssertTrue(second.contains("release-b"))
        XCTAssertFalse(second.claim("release-b"))
        XCTAssertTrue(second.claim("release-c"))
        XCTAssertFalse(first.claim("release-c"))

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        // Only digests are stored, never the release id text.
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("release-b"))
        XCTAssertTrue(text.contains(NativeMTPAdmissionPickupStore.digest("release-b")))
    }

    func testStoreKeepsABoundedHistory() {
        let store = NativeMTPAdmissionPickupStore(url: temporaryStoreURL())
        for index in 0..<(NativeMTPAdmissionPickupStore.maxEntries + 4) {
            XCTAssertTrue(store.claim("release-\(index)"))
        }
        XCTAssertTrue(store.contains("release-\(NativeMTPAdmissionPickupStore.maxEntries + 3)"))
        XCTAssertFalse(store.contains("release-0"))
    }

    /// A record that cannot be made durable claims nothing, so doubt never restarts.
    func testStoreThatCannotBeWrittenOrTrustedClaimsNothing() throws {
        let blocked = temporaryStoreURL()
        try FileManager.default.createDirectory(at: blocked.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The parent path is a file, so no record can be written under it.
        let file = blocked.deletingLastPathComponent().appendingPathComponent("plain-file")
        try Data("x".utf8).write(to: file)
        XCTAssertFalse(NativeMTPAdmissionPickupStore(url: file.appendingPathComponent("store.json")).claim("release-b"))

        // A symlink in place of the record is refused.
        let target = blocked.deletingLastPathComponent().appendingPathComponent("elsewhere.json")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: blocked, withDestinationURL: target)
        let store = NativeMTPAdmissionPickupStore(url: blocked)
        XCTAssertFalse(store.claim("release-b"))
        XCTAssertEqual(try Data(contentsOf: target), Data("{}".utf8))
    }

    func testPendingStatusObject() {
        let notBefore = Date(timeIntervalSince1970: 1_800_000_000)
        let scheduled = NativeMTPAdmissionPendingStatus(releaseID: "release-b", phase: .scheduled, drainNotBefore: notBefore)
        XCTAssertEqual(scheduled.statusObject()["release_id"] as? String, "release-b")
        XCTAssertEqual(scheduled.statusObject()["phase"] as? String, "scheduled")
        XCTAssertEqual(scheduled.statusObject()["drain_not_before"] as? String, ISO8601DateFormatter().string(from: notBefore))
        let waiting = NativeMTPAdmissionPendingStatus(releaseID: "release-b", phase: .waitingForIdle, drainNotBefore: nil)
        XCTAssertEqual(waiting.statusObject()["phase"] as? String, "waiting_for_idle")
        XCTAssertNil(waiting.statusObject()["drain_not_before"])
        XCTAssertEqual(NativeMTPAdmissionPendingStatus.Phase.restartRequired.rawValue, "restart_required")
    }

    private func status() -> ProviderStatus {
        ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 2)
        )
    }

    func testWaitUntilIdleForRestartReturnsOnlyAtZeroInFlight() async throws {
        let status = status()
        let first = await status.beginRequest(requestID: "one")
        let second = await status.beginRequest(requestID: "two")
        let done = LockedBox(false)
        let wait = Task {
            let outcome = await status.waitUntilIdleForRestart(pollNanoseconds: 5_000_000)
            done.set(true)
            return outcome
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(done.get())
        await status.finishRequest(startedAt: first, completion: nil, failed: false)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(done.get(), "one request is still in flight")
        await status.finishRequest(startedAt: second, completion: nil, failed: false)
        let outcome = await wait.value
        XCTAssertEqual(outcome, .idle)
    }

    /// Past its deadline the wait gives up without cutting anything and
    /// lowers the fence, so the provider can serve again.
    func testWaitUntilIdleForRestartExpiresWithoutCutting() async throws {
        let status = status()
        let startedAt = await status.beginRequest(requestID: "one")
        let outcome = await status.waitUntilIdleForRestart(
            deadline: Date().addingTimeInterval(0.2), pollNanoseconds: 5_000_000
        )
        XCTAssertEqual(outcome, .expired)
        let inFlight = await status.requestsInFlightCount()
        XCTAssertEqual(inFlight, 1)
        await status.setState(.ready, reason: "abandoned")
        let snapshot = await status.snapshot()
        XCTAssertEqual(snapshot.status, .ready)
        let admitted = await status.admitRequest(requestID: "two")
        guard case .admitted(let second) = admitted else { return XCTFail("serving again after the cap") }
        await status.finishRequest(startedAt: startedAt, completion: nil, failed: false)
        await status.finishRequest(startedAt: second, completion: nil, failed: false)
    }

    /// Under the fence no state that admits requests can be published.
    func testRestartFenceHoldsReadyBusyAndDegraded() async throws {
        let status = status()
        let startedAt = await status.beginRequest(requestID: "one")
        let wait = Task { await status.waitUntilIdleForRestart(pollNanoseconds: 5_000_000) }
        try await Task.sleep(nanoseconds: 100_000_000)
        for state in [ProviderHealthState.ready, .busy, .degraded] {
            await status.setState(state, reason: "other_path")
            let snapshot = await status.snapshot()
            XCTAssertEqual(snapshot.status, .draining, "\(state)")
        }
        await status.finishRequest(startedAt: startedAt, completion: nil, failed: false)
        let outcome = await wait.value
        XCTAssertEqual(outcome, .idle)
    }

    func testWaitUntilIdleForRestartStopsOnlyWhenCancelled() async throws {
        let status = status()
        let startedAt = await status.beginRequest(requestID: "one")
        let wait = Task { await status.waitUntilIdleForRestart(pollNanoseconds: 5_000_000) }
        try await Task.sleep(nanoseconds: 100_000_000)
        wait.cancel()
        let outcome = await wait.value
        XCTAssertEqual(outcome, .cancelled)
        let inFlight = await status.requestsInFlightCount()
        XCTAssertEqual(inFlight, 1, "a cancelled wait cuts nothing")
        await status.finishRequest(startedAt: startedAt, completion: nil, failed: false)
    }

    /// The check asks the network for nothing when a restart could not help:
    /// mode not `auto`, a draft model, or a startup set that already named
    /// the loaded model.
    func testCheckGuardsRefuseBeforeAnyFetch() async {
        let fetches = LockedBox(0)
        let fetcher: NativeMTPAdmissionFeed.Fetcher = { _, _ in
            fetches.update { $0 += 1 }
            return NativeMTPAdmissionFeed.FetchResponse(statusCode: 404, body: Data())
        }
        let envelope = CoordinatorClient.CatalogEnvelope(
            releaseID: "release-b",
            policyVersion: "policy-a",
            candidateSHA256: String(repeating: "c", count: 64),
            signerKeyID: "operator-2026-01",
            rowIdentity: String(repeating: "b", count: 64),
            modelSHA256: String(repeating: "d", count: 64)
        )
        let binding = ServeCommand.VerifiedModelRuntimeBinding(
            authorityPath: "/nonexistent/model",
            authoritySHA256: String(repeating: "d", count: 64),
            loadPath: "/nonexistent/model",
            loadSHA256: String(repeating: "d", count: 64),
            nativeMTPResolvedArtifactAuthority: nil
        )
        func check(_ mutate: (inout AppConfig) -> Void, startup: SmallMRoute.NativeMTPAdmission) async -> NativeMTPAdmissionPickup.Check {
            var config = AppConfig.defaults(configPath: "/tmp/macprovider-test.yaml")
            config.model = "model-a"
            config.modelCatalogKey = "model-a"
            config.modelArtifactSHA256 = String(repeating: "d", count: 64)
            config.nativeMTPMode = .auto
            mutate(&config)
            return await ServeCommand.nativeMTPAdmissionNewlyActivatable(
                config: config,
                startupAdmission: startup,
                envelope: envelope,
                binding: binding,
                slotCount: 1,
                probeRoot: FileManager.default.temporaryDirectory
                    .appendingPathComponent("native-mtp-admission-probe-\(UUID().uuidString)", isDirectory: true),
                admissionFetcher: fetcher,
                admissionProbe: { _, _, _, _ in nil }
            )
        }
        let modeOff = await check({ $0.nativeMTPMode = .off }, startup: .none)
        XCTAssertEqual(modeOff, .notActivatable)
        let draft = await check({ $0.draftModel = "org/draft" }, startup: .none)
        XCTAssertEqual(draft, .notActivatable)
        let alreadyNamed = await check({ _ in }, startup: .entryForModel)
        // Named by an operator-placed set (no feed sidecar path): a release cannot supersede it.
        XCTAssertEqual(alreadyNamed, .notActivatable)
        let noDigest = await check({ $0.modelArtifactSHA256 = nil }, startup: .none)
        XCTAssertEqual(noDigest, .notActivatable)
        XCTAssertEqual(fetches.get(), 0)
    }

    /// Only the installed LaunchAgent's process counts as restarted on exit;
    /// an orphaned `serve` also has parent 1 but would stay down.
    private static let dist = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("dist", isDirectory: true)

    /// The job a shipped provider plist describes, as launchd runs it: its
    /// label (which launchd exports as `XPC_SERVICE_NAME`) and the
    /// environment the plist itself sets.
    private func launchdJob(plistAt relativePath: String) throws -> (label: String, environment: [String: String]) {
        let text = try String(contentsOf: Self.dist.appendingPathComponent(relativePath), encoding: .utf8)
        func strings(afterKey key: String, in text: String) -> String? {
            guard let keyRange = text.range(of: "<key>\(key)</key>"),
                  let open = text.range(of: "<string>", range: keyRange.upperBound..<text.endIndex),
                  let close = text.range(of: "</string>", range: open.upperBound..<text.endIndex)
            else { return nil }
            return String(text[open.upperBound..<close.lowerBound])
        }
        let label = try XCTUnwrap(strings(afterKey: "Label", in: text), relativePath)
        var environment = ["XPC_SERVICE_NAME": label]
        if text.contains("<key>MACPROVIDER_LAUNCHD_DOMAIN</key>") {
            environment["MACPROVIDER_LAUNCHD_DOMAIN"] = "gui/501"
        }
        return (label, environment)
    }

    /// Every shipped provider plist yields a process the pickup may restart,
    /// including the templates that set no `MACPROVIDER_LAUNCHD_DOMAIN`; an
    /// orphaned `serve` also has parent 1 but would stay down.
    func testSupervisedForEveryShippedProviderPlistAndNotForAnOrphan() throws {
        for template in ["launchd-plist-template.plist", "compatibility-set-assets/provider-launch-agent.plist.template"] {
            let job = try launchdJob(plistAt: template)
            XCTAssertEqual(job.label, ProviderConflictDetector.launchdLabel, template)
            XCTAssertNil(job.environment["MACPROVIDER_LAUNCHD_DOMAIN"], "\(template) sets no domain key; the label must be enough")
            XCTAssertTrue(NativeMTPAdmissionPickup.supervisedByLaunchd(parentPID: 1, environment: job.environment), template)
            XCTAssertFalse(NativeMTPAdmissionPickup.supervisedByLaunchd(parentPID: 4242, environment: job.environment), template)
        }
        // The installer's own plist names the same label.
        let installer = try String(contentsOf: Self.dist.appendingPathComponent("install.sh"), encoding: .utf8)
        XCTAssertTrue(installer.contains("<string>\(ProviderConflictDetector.launchdLabel)</string>"))
        XCTAssertTrue(NativeMTPAdmissionPickup.supervisedByLaunchd(parentPID: 1, environment: ["MACPROVIDER_LAUNCHD_DOMAIN": "gui/501"]))

        // Orphaned or foreground processes: parent 1 without the job identity,
        // another job's identity, or a shell parent.
        XCTAssertFalse(NativeMTPAdmissionPickup.supervisedByLaunchd(parentPID: 1, environment: [:]))
        XCTAssertFalse(NativeMTPAdmissionPickup.supervisedByLaunchd(parentPID: 1, environment: ["XPC_SERVICE_NAME": "0"]))
        XCTAssertFalse(NativeMTPAdmissionPickup.supervisedByLaunchd(parentPID: 1, environment: ["XPC_SERVICE_NAME": "com.apple.Terminal"]))
        XCTAssertFalse(NativeMTPAdmissionPickup.supervisedByLaunchd(parentPID: 1, environment: ["MACPROVIDER_LAUNCHD_DOMAIN": " "]))
    }

    // MARK: - The check's branches

    private static let model = "org/model"
    private static let digest = String(repeating: "d", count: 64)

    /// A signed set naming `model`, written like a fetched set, plus static
    /// inputs that trust its key.
    private func signedSet(named: String) throws -> (sidecar: URL, inputs: AutotuneStaticInputs) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-mtp-pickup-set-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let key = Curve25519.Signing.PrivateKey()
        let body = Data(#"{"entries":[{"artifact_hash":"\#(Self.digest)","model_key":"\#(named)"}]}"#.utf8)
        let sidecar = directory.appendingPathComponent(NativeMTPAdmissionFeed.sidecarFileName)
        try body.write(to: sidecar)
        let signature = try key.signature(for: body).base64EncodedString()
        try Data(#"{"key_id":"\#(AutotuneStaticInputs.keyID)","alg":"ed25519","signature":"\#(signature)"}"#.utf8)
            .write(to: directory.appendingPathComponent(NativeMTPAdmissionFeed.signatureFileName))
        let inputs = AutotuneStaticInputs(
            fetch: { _ in throw URLError(.cannotConnectToHost) },
            trustedPublicKeys: [AutotuneStaticInputs.keyID: key.publicKey.rawRepresentation.base64EncodedString()]
        )
        return (sidecar, inputs)
    }

    private func authority() -> NativeMTPResolvedArtifactAuthority {
        NativeMTPResolvedArtifactAuthority.uncheckedForTesting(
            releaseID: "release-b", signerKeyID: AutotuneStaticInputs.keyID, feedSHA256: String(repeating: "f", count: 64),
            modelKey: Self.model, artifactID: "artifact", hashAlgorithm: NativeMTPResolvedArtifactAuthority.nativeMTPHashAlgorithm,
            hash: Self.digest, verificationStatus: "verified", targetURLPath: "/nonexistent/model", targetSHA256: Self.digest
        )
    }

    private func runCheck(
        startup: SmallMRoute.NativeMTPAdmission,
        startupSidecar: URL? = nil,
        inputs: AutotuneStaticInputs = AutotuneStaticInputs(fetch: { _ in throw URLError(.cannotConnectToHost) }),
        resolution: ServeCommand.NativeMTPAdmissionResolution,
        probe: @escaping (URL) -> String? = { _ in nil }
    ) async -> NativeMTPAdmissionPickup.Check {
        var config = AppConfig.defaults(configPath: "/tmp/macprovider-test.yaml")
        config.model = Self.model
        config.modelCatalogKey = Self.model
        config.modelArtifactSHA256 = Self.digest
        config.nativeMTPMode = .auto
        var binding = ServeCommand.VerifiedModelRuntimeBinding(
            authorityPath: "/nonexistent/model", authoritySHA256: Self.digest,
            loadPath: "/nonexistent/model", loadSHA256: Self.digest,
            nativeMTPResolvedArtifactAuthority: nil
        )
        binding.nativeMTPAdmissionSidecarPath = startupSidecar?.path
        return await ServeCommand.nativeMTPAdmissionNewlyActivatable(
            config: config,
            startupAdmission: startup,
            envelope: CoordinatorClient.CatalogEnvelope(
                releaseID: "release-b", policyVersion: "policy-a", candidateSHA256: String(repeating: "c", count: 64),
                signerKeyID: "operator-2026-01", rowIdentity: String(repeating: "b", count: 64), modelSHA256: Self.digest
            ),
            binding: binding,
            slotCount: 1,
            staticInputs: inputs,
            probeRoot: FileManager.default.temporaryDirectory
                .appendingPathComponent("native-mtp-admission-probe-\(UUID().uuidString)", isDirectory: true),
            resolve: { _ in resolution },
            admissionProbe: { sidecar, _, _, _ in probe(sidecar) }
        )
    }

    /// A definite "nothing for this model" is final; only unresolved inputs
    /// are worth another check.
    func testCheckClassifiesNoEntryAsFinalAndUnresolvedInputsAsRetryable() async {
        let noEntry = await runCheck(startup: .none, resolution: .noEntry)
        XCTAssertEqual(noEntry, .notActivatable)
        let unavailable = await runCheck(startup: .none, resolution: .unavailable)
        XCTAssertEqual(unavailable, .unavailable)
    }

    func testCheckIgnoresAReleaseWhenTheSetIsOperatorPlaced() async {
        let resolution = ServeCommand.NativeMTPAdmissionResolution.admitted(
            ServeCommand.NativeMTPResolvedAdmission(authority: authority(), sidecarPath: nil)
        )
        let check = await runCheck(startup: .none, resolution: resolution)
        XCTAssertEqual(check, .notActivatable)
    }

    func testCheckFollowsTheLoaderAdmissionStageForTheNewSet() async throws {
        let new = try signedSet(named: Self.model)
        let resolution = ServeCommand.NativeMTPAdmissionResolution.admitted(
            ServeCommand.NativeMTPResolvedAdmission(authority: authority(), sidecarPath: new.sidecar.path)
        )
        let admitted = await runCheck(startup: .none, inputs: new.inputs, resolution: resolution)
        XCTAssertEqual(admitted, .activatable)
        let refused = await runCheck(startup: .none, inputs: new.inputs, resolution: resolution, probe: { _ in "admission_rejected" })
        XCTAssertEqual(refused, .notActivatable)
        // A set that names another model only is a definite no, before the loader stage runs.
        let other = try signedSet(named: "org/other")
        let otherResolution = ServeCommand.NativeMTPAdmissionResolution.admitted(
            ServeCommand.NativeMTPResolvedAdmission(authority: authority(), sidecarPath: other.sidecar.path)
        )
        let probed = LockedBox(0)
        let notNamed = await runCheck(startup: .none, inputs: other.inputs, resolution: otherResolution, probe: { _ in
            probed.update { $0 += 1 }
            return nil
        })
        XCTAssertEqual(notNamed, .notActivatable)
        XCTAssertEqual(probed.get(), 0)
    }

    /// The set the process started on named the model: a restart helps only
    /// if that set's tuple is refused where the new set's is admitted.
    func testCheckComparesTheStartupSetAtTupleLevel() async throws {
        let new = try signedSet(named: Self.model)
        let startupSidecar = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-mtp-startup-\(UUID().uuidString).json")
        let resolution = ServeCommand.NativeMTPAdmissionResolution.admitted(
            ServeCommand.NativeMTPResolvedAdmission(authority: authority(), sidecarPath: new.sidecar.path)
        )
        // The startup set already admits this tuple: nothing new, no restart.
        let alreadyAdmitted = await runCheck(
            startup: .entryForModel, startupSidecar: startupSidecar, inputs: new.inputs, resolution: resolution
        )
        XCTAssertEqual(alreadyAdmitted, .notActivatable)
        // The startup set named the model for another tuple; the new set admits this one.
        let newTuple = await runCheck(
            startup: .entryForModel, startupSidecar: startupSidecar, inputs: new.inputs, resolution: resolution,
            probe: { $0.path == startupSidecar.path ? "admission_rejected" : nil }
        )
        XCTAssertEqual(newTuple, .activatable)
    }

    /// The production resolve against the compiled-in signed feeds: a model
    /// the artifact feed does not name is a definite no and fetches no
    /// admission member; a model it names whose admission members cannot be
    /// fetched is unresolved.
    func testResolveClassifiesAgainstTheCompiledInFeeds() async throws {
        let now = try AutotuneStaticInputs.decodeCandidateCatalog(
            Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8)
        ).generatedAt.addingTimeInterval(3_600)
        let inputs = AutotuneStaticInputs(fetch: { _ in throw URLError(.cannotConnectToHost) }, now: { now })
        let loaded = await inputs.loadRecommendationInputs(includeArtifactFeed: true)
        let feed = try XCTUnwrap(loaded.artifactFeed.value)
        XCTAssertTrue(loaded.artifactFeed.warnings.blockingArtifactFeedWarnings.isEmpty)
        let releaseID = loaded.candidate.value.version
        XCTAssertEqual(feed.releaseID, releaseID)
        let catalogDigest = AutotuneStaticInputs.candidateCatalogSHA256(bytes: loaded.candidate.selectedBytes)
        let fetches = LockedBox(0)
        let failing: NativeMTPAdmissionFeed.Fetcher = { _, _ in
            fetches.update { $0 += 1 }
            return NativeMTPAdmissionFeed.FetchResponse(statusCode: 503, body: Data())
        }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-mtp-resolve-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: scratch) }
        func resolve(modelKey: String, hash: String) async -> ServeCommand.NativeMTPAdmissionResolution {
            var config = AppConfig.defaults(configPath: "/tmp/macprovider-test.yaml")
            config.nativeMTPMode = .auto
            config.modelCatalogKey = modelKey
            return await ServeCommand.resolveNativeMTPAdmission(
                config: config, releaseID: releaseID, catalogDigest: catalogDigest,
                authorityPath: scratch.appendingPathComponent("model").path, authoritySHA256: hash,
                staticInputs: inputs, artifactResolver: CachedModelArtifactResolver(),
                admissionRoot: scratch.appendingPathComponent("probe"), admissionFetcher: failing
            )
        }
        guard case .noEntry = await resolve(modelKey: "org/not-in-the-feed", hash: Self.digest) else {
            return XCTFail("a model the artifact feed does not name is a definite no")
        }
        XCTAssertEqual(fetches.get(), 0)

        let identity = try XCTUnwrap(feed.artifactIdentities().first {
            $0.isPrimary && $0.hashAlgorithm == NativeMTPResolvedArtifactAuthority.nativeMTPHashAlgorithm
                && $0.verificationStatus == "verified"
        })
        guard case .unavailable = await resolve(modelKey: identity.catalogKey, hash: identity.hash) else {
            return XCTFail("admission members that cannot be fetched leave the release unresolved")
        }
        XCTAssertGreaterThan(fetches.get(), 0)
        // Another release id than the feeds carry is unresolved, not a definite no.
        var config = AppConfig.defaults(configPath: "/tmp/macprovider-test.yaml")
        config.nativeMTPMode = .auto
        config.modelCatalogKey = identity.catalogKey
        guard case .unavailable = await ServeCommand.resolveNativeMTPAdmission(
            config: config, releaseID: releaseID + "-next", catalogDigest: catalogDigest,
            authorityPath: scratch.appendingPathComponent("model").path, authoritySHA256: identity.hash,
            staticInputs: inputs, artifactResolver: CachedModelArtifactResolver(),
            admissionRoot: scratch.appendingPathComponent("probe"), admissionFetcher: failing
        ) else {
            return XCTFail("feeds that do not carry the release yet are unresolved")
        }
    }

    func testHooksAreBuiltOnlyWhereAReleaseCanChangeNativeMTP() {
        var config = AppConfig.defaults(configPath: "/tmp/macprovider-test.yaml")
        config.nativeMTPMode = .auto
        let binding = ServeCommand.VerifiedModelRuntimeBinding(
            authorityPath: "/nonexistent/model",
            authoritySHA256: String(repeating: "d", count: 64),
            loadPath: "/nonexistent/model",
            loadSHA256: String(repeating: "d", count: 64),
            nativeMTPResolvedArtifactAuthority: nil
        )
        func hooks(
            _ config: AppConfig, binding: ServeCommand.VerifiedModelRuntimeBinding?, trust: Bool = true, excluded: Bool = false
        ) -> NativeMTPAdmissionPickup.Hooks? {
            ServeCommand.nativeMTPAdmissionPickupHooks(
                config: config, startupAdmission: .none, binding: binding, hasCatalogTrust: trust, slotCount: 1,
                excluded: excluded, store: NativeMTPAdmissionPickupStore(url: temporaryStoreURL())
            )
        }
        XCTAssertNotNil(hooks(config, binding: binding))
        XCTAssertNil(hooks(config, binding: nil))
        XCTAssertNil(hooks(config, binding: binding, trust: false))
        XCTAssertNil(hooks(config, binding: binding, excluded: true))
        var off = config
        off.nativeMTPMode = .off
        XCTAssertNil(hooks(off, binding: binding))
    }
}
