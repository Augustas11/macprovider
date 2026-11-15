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
        for unit in [-1, -0.0001, 0.25, 0.9999, 1.0001, 2, 1e308, -.infinity, .infinity, .nan] {
            XCTAssertTrue(range.contains(NativeMTPAdmissionPickup.jitterSeconds(unit: unit)), "unit \(unit)")
        }
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<1_000 {
            let unit = Double.random(in: 0...1, using: &generator)
            XCTAssertTrue(range.contains(NativeMTPAdmissionPickup.jitterSeconds(unit: unit)))
        }
        // The default sample source feeds the same mapping.
        let hooks = NativeMTPAdmissionPickup.Hooks(newlyActivatable: { _ in false }, claim: { _ in false }, supervised: { false })
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
            let idle = await status.waitUntilIdleForRestart(pollNanoseconds: 5_000_000)
            done.set(true)
            return idle
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(done.get())
        await status.finishRequest(startedAt: first, completion: nil, failed: false)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(done.get(), "one request is still in flight")
        await status.finishRequest(startedAt: second, completion: nil, failed: false)
        let idle = await wait.value
        XCTAssertTrue(idle)
    }

    func testWaitUntilIdleForRestartStopsOnlyWhenCancelled() async throws {
        let status = status()
        let startedAt = await status.beginRequest(requestID: "one")
        let wait = Task { await status.waitUntilIdleForRestart(pollNanoseconds: 5_000_000) }
        try await Task.sleep(nanoseconds: 100_000_000)
        wait.cancel()
        let idle = await wait.value
        XCTAssertFalse(idle)
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
        func check(_ mutate: (inout AppConfig) -> Void, startup: SmallMRoute.NativeMTPAdmission) async -> Bool {
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
        XCTAssertFalse(modeOff)
        let draft = await check({ $0.draftModel = "org/draft" }, startup: .none)
        XCTAssertFalse(draft)
        let alreadyNamed = await check({ _ in }, startup: .entryForModel)
        XCTAssertFalse(alreadyNamed)
        let noDigest = await check({ $0.modelArtifactSHA256 = nil }, startup: .none)
        XCTAssertFalse(noDigest)
        XCTAssertEqual(fetches.get(), 0)
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
