import Foundation
import MacProviderCore
import NIO
import NIOHTTP1
import XCTest
@testable import macprovider_cli

final class LocalImageGenerationTests: XCTestCase {
    private func request(_ values: [String: Any] = [:]) throws -> LocalImageRequest {
        var body: [String: Any] = ["prompt": "A blue sea", "size": "512x512", "steps": 4, "n": 1, "response_format": "b64_json"]
        body.merge(values) { _, new in new }
        return try JSONDecoder().decode(LocalImageRequest.self, from: JSONSerialization.data(withJSONObject: body))
    }

    func testRequestValidation() throws {
        let valid = try request(["seed": 42])
        XCTAssertEqual(valid.seed, 42); XCTAssertEqual(valid.pixels, 512); XCTAssertEqual(valid.steps, 4)
        for values: [String: Any] in [["prompt": " "], ["prompt": String(repeating: "x", count: 4001)],
            ["size": "256x256"], ["steps": 0], ["steps": 5], ["steps": 1.5], ["steps": true],
            ["seed": -1], ["n": 2], ["response_format": "url"], ["prompt": NSNull()]] {
            XCTAssertThrowsError(try request(values), "\(values)")
        }
        for steps in 1...4 { XCTAssertEqual(try request(["steps": steps]).steps, steps) }
        XCTAssertEqual(try request(["size": "1024x1024"]).pixels, 1024)
        XCTAssertThrowsError(try JSONDecoder().decode(LocalImageRequest.self, from: Data("{}".utf8)))
    }

    func testLocalAccessRejectsMissingDuplicateAndCoordinatorForwarding() throws {
        let local = HTTPHeaders([("X-MacProvider-Origin", "local-app")])
        XCTAssertNoThrow(try RouterHandler.validateImageAccess(headers: local, peerIsLoopback: true))
        for headers in [HTTPHeaders(), HTTPHeaders([("X-MacProvider-Origin", "coordinator")]),
            HTTPHeaders([("X-MacProvider-Origin", "local-app"), ("X-MacProvider-Origin", "local-app")]),
            HTTPHeaders([("X-MacProvider-Origin", "local-app"), ("X-MacProvider-Origin", "coordinator")]),
            HTTPHeaders([("X-MacProvider-Origin", "local-app"), ("X-MacProvider-Settlement-Metadata", "invalid")]),
            HTTPHeaders([("X-MacProvider-Origin", "local-app"), ("X-MacProvider-Privacy-Class", "private")])] {
            XCTAssertThrowsError(try RouterHandler.validateImageAccess(headers: headers, peerIsLoopback: true))
        }
        XCTAssertThrowsError(try RouterHandler.validateImageAccess(headers: local, peerIsLoopback: false))
    }

    func testHTTPRouteReturnsOpenAIImageShapeWithoutBuyerAccounting() async throws {
        let events = ImageEvents()
        let images = service(events: events, available: 32_000_000_000)
        let status = ProviderStatus(modelID: "fixture", modelLoaded: true, capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: 1))
        let runtime = ModelRuntime(modelID: "fixture", warmSwapEnabled: false,
            loader: { _ in throw CocoaError(.fileReadUnknown) }, testLoader: { ($0, "fixture-hash") })
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let channel = try await ServerBootstrap(group: group).childChannelInitializer { channel in
            channel.pipeline.configureHTTPServerPipeline().flatMap {
                channel.pipeline.addHandler(RouterHandler(modelID: "fixture", providerID: nil, coordinatorURL: nil,
                    modelRuntime: runtime, providerStatus: status, warmSwapEnabled: false, maxBodyBytes: 100_000,
                    images: images))
            }
        }.bind(host: "127.0.0.1", port: 0).get()
        do {
            let port = try XCTUnwrap(channel.localAddress?.port)
            for origin in ["local-app", "coordinator", ""] {
                var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/v1/images/generations")))
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                if !origin.isEmpty { request.setValue(origin, forHTTPHeaderField: "X-MacProvider-Origin") }
                request.httpBody = Data("{\"prompt\":\"A blue sea\"}".utf8)
                let (data, response) = try await URLSession.shared.data(for: request)
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, origin == "local-app" ? 200 : 403)
                if origin == "local-app" {
                    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                    XCTAssertNotNil(object["created"] as? Int)
                    let results = try XCTUnwrap(object["data"] as? [[String: String]])
                    XCTAssertEqual(results, [["b64_json": Data("png".utf8).base64EncodedString()]])
                }
            }
            for path in ["/v1/images/generations", "/v1/images/generations/cancel"] {
                var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(path)")))
                request.httpMethod = "GET"
                let (_, response) = try await URLSession.shared.data(for: request)
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 405)
                XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Allow"), "POST")
            }
            let snapshot = await status.snapshot()
            XCTAssertEqual(snapshot.requestsTotal, 0)
            await images.restore()
            try await channel.close().get(); try await group.shutdownGracefully()
        } catch {
            try? await channel.close().get(); try? await group.shutdownGracefully(); throw error
        }
    }

    func testMemoryDecisionTableAcrossRAMAndPresetSizes() {
        for gib in [4, 8, 16, 24, 32, 64] {
            for pixels in [512, 1024] {
                for available in [UInt64(0), UInt64(64_000_000_000)] {
                    let d = LocalImageMemoryDecision.evaluate(physicalBytes: UInt64(gib) * 1_073_741_824, availableBytes: available, pixels: pixels)
                    XCTAssertEqual(d.quantized, gib <= 16)
                    XCTAssertEqual(d.requiresHold, available == 0)
                    XCTAssertEqual(d.unavailableReason != nil, gib <= 8 || (pixels == 1024 && gib < 32))
                }
            }
        }
        for (gib, pixels, threshold): (Int, Int, UInt64) in [(16, 512, 8_900_000_000), (32, 512, 11_700_000_000), (32, 1024, 14_800_000_000)] {
            XCTAssertTrue(LocalImageMemoryDecision.evaluate(physicalBytes: UInt64(gib) * 1_073_741_824, availableBytes: threshold - 1, pixels: pixels).requiresHold)
            XCTAssertFalse(LocalImageMemoryDecision.evaluate(physicalBytes: UInt64(gib) * 1_073_741_824, availableBytes: threshold, pixels: pixels).requiresHold)
        }
    }

    func testHoldGeneratesWarmThenRestoresInOrder() async throws {
        let events = ImageEvents()
        let service = service(events: events)
        let data = try await service.generate(request())
        XCTAssertEqual(data, Data("png".utf8))
        let warm = await service.state
        XCTAssertEqual(warm, .warm)
        let generated = await events.values
        XCTAssertEqual(generated, ["pause", "drain", "unload_language", "prepare", "generate"])
        await service.restore()
        let restored = await events.values
        XCTAssertEqual(restored, generated + ["unload_image", "restore_language", "resume"])
        let idle = await service.state
        XCTAssertEqual(idle, .idle)
    }

    func testFailureRestoresAndReleasesSingleFlight() async throws {
        let events = ImageEvents()
        let service = service(events: events, failure: true)
        do { _ = try await service.generate(request()); XCTFail("Expected backend failure") } catch {}
        let values = await events.values
        XCTAssertEqual(Array(values.suffix(3)), ["unload_image", "restore_language", "resume"])
        let idle = await service.state
        XCTAssertEqual(idle, .idle)
    }

    func testDrainTimeoutResumesWithoutUnloadingLanguage() async throws {
        let events = ImageEvents()
        let service = LocalImageGeneration(backend: FakeImageBackend(events: events, failure: false, blocking: false),
            lifecycle: LocalCreativeLifecycle(pause: { await events.add("pause") },
                drain: { await events.add("drain"); throw CocoaError(.fileReadUnknown) },
                unloadLanguage: { await events.add("unload_language") },
                restoreLanguage: { await events.add("restore_language") }, resume: { await events.add("resume") }),
            physicalBytes: 16 * 1_073_741_824, availableBytes: { 0 })
        do { _ = try await service.generate(request()); XCTFail("Expected drain failure") } catch {}
        let values = await events.values
        XCTAssertEqual(values, ["pause", "drain", "unload_image", "resume"])
    }

    func testPartialUnloadFailureStillAttemptsRestoration() async throws {
        let events = ImageEvents()
        let service = LocalImageGeneration(backend: FakeImageBackend(events: events, failure: false, blocking: false),
            lifecycle: LocalCreativeLifecycle(pause: { await events.add("pause") }, drain: { await events.add("drain") },
                unloadLanguage: { await events.add("unload_language"); throw CocoaError(.fileReadUnknown) },
                restoreLanguage: { await events.add("restore_language") }, resume: { await events.add("resume") }),
            physicalBytes: 16 * 1_073_741_824, availableBytes: { 0 })
        do { _ = try await service.generate(request()); XCTFail("Expected unload failure") } catch {}
        let values = await events.values
        XCTAssertEqual(Array(values.suffix(3)), ["unload_image", "restore_language", "resume"])
    }

    func testCancelRestoresAfterBackendStops() async throws {
        let events = ImageEvents()
        let service = service(events: events, blocking: true)
        let task = Task { try await service.generate(request()) }
        await waitForGenerating(service)
        await service.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("\(error)") }
        let values = await events.values
        XCTAssertEqual(Array(values.suffix(4)), ["generation_stopped", "unload_image", "restore_language", "resume"])
        let idle = await service.state
        XCTAssertEqual(idle, .idle)
    }

    func testDownloadProgressAndCancellationRestoreCustomerServing() async throws {
        let events = ImageEvents()
        let service = LocalImageGeneration(backend: BlockingDownloadImageBackend(events: events),
            lifecycle: LocalCreativeLifecycle(pause: { await events.add("pause") }, drain: { await events.add("drain") },
                unloadLanguage: { await events.add("unload_language") }, restoreLanguage: { await events.add("restore_language") },
                resume: { await events.add("resume") }), physicalBytes: 16 * 1_073_741_824, availableBytes: { 0 })
        let task = Task { try await service.generate(request()) }
        var snapshot: [String: Any] = [:]
        for _ in 0..<200 {
            snapshot = await service.status()
            if snapshot["progress"] as? Double == 0.5 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(snapshot["state"] as? String, "downloading")
        XCTAssertEqual(snapshot["downloaded_bytes"] as? Int64, 50)
        XCTAssertEqual(snapshot["total_bytes"] as? Int64, 100)
        XCTAssertEqual(snapshot["progress"] as? Double, 0.5)
        await service.cancel()
        do { _ = try await task.value; XCTFail("Expected download cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let values = await events.values
        XCTAssertEqual(values, ["pause", "drain", "unload_language", "download_stopped", "unload_image", "restore_language", "resume"])
        let idle = await service.state
        XCTAssertEqual(idle, .idle)
    }

    func testCancelledDrainReleasesHoldWithoutUnloadingLanguage() async throws {
        let events = ImageEvents()
        let service = LocalImageGeneration(backend: FakeImageBackend(events: events, failure: false, blocking: false),
            lifecycle: LocalCreativeLifecycle(pause: { await events.add("pause") },
                drain: { await events.add("drain"); try await Task.sleep(nanoseconds: 30_000_000_000) },
                unloadLanguage: { await events.add("unload_language") }, restoreLanguage: { await events.add("restore_language") },
                resume: { await events.add("resume") }), physicalBytes: 16 * 1_073_741_824, availableBytes: { 0 })
        let task = Task { try await service.generate(request()) }
        for _ in 0..<200 {
            if await events.values.contains("drain") { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let holding = await service.state
        XCTAssertEqual(holding, .holdingCustomers)
        await service.cancel()
        do { _ = try await task.value; XCTFail("Expected drain cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let values = await events.values
        XCTAssertEqual(values, ["pause", "drain", "unload_image", "resume"])
    }

    func testSingleFlightReturns429() async throws {
        let service = service(events: ImageEvents(), blocking: true)
        let first = Task { try await service.generate(request()) }
        await waitForGenerating(service)
        do { _ = try await service.generate(request()); XCTFail("Expected busy") }
        catch let error as APIError { XCTAssertEqual(error.status, 429); XCTAssertEqual(error.code, "image_generation_busy") }
        await service.cancel(); _ = try? await first.value
    }

    func testWarmDeadlineRestoresWithoutAnotherRequest() async throws {
        let events = ImageEvents()
        let service = service(events: events, warmNanoseconds: 10_000_000)
        _ = try await service.generate(request())
        for _ in 0..<200 {
            if await service.state == .idle { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let idle = await service.state
        XCTAssertEqual(idle, .idle)
        let values = await events.values
        XCTAssertEqual(values.last, "resume")
    }

    func testSufficientMemoryDoesNotPauseOrUnloadLanguage() async throws {
        let events = ImageEvents()
        let service = service(events: events, available: 32_000_000_000)
        _ = try await service.generate(request()); await service.restore()
        let values = await events.values
        XCTAssertEqual(values, ["prepare", "generate", "unload_image"])
    }

    func testStatusCapabilityAndStates() async throws {
        XCTAssertTrue(RouterHandler.localStatusCapabilities.contains("local_image_generation_v1"))
        XCTAssertEqual(Set(LocalImageState.allCases.map(\.rawValue)), Set(["idle", "downloading", "holding_customers", "generating", "warm", "restoring", "recovery_required"]))
        let service = service(events: ImageEvents())
        let status = await service.status()
        XCTAssertEqual(status["state"] as? String, "idle")
        XCTAssertEqual(status["available"] as? Bool, true)
        XCTAssertEqual(status["physical_memory_bytes"] as? UInt64, 16 * 1_073_741_824)
    }

    func testCreativeHoldPreservesOperatorPauseAndFencesAdmission() async {
        let status = ProviderStatus(modelID: "fixture", modelLoaded: true, capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: 1))
        await status.setOperatorPauseFence(true)
        await status.setLocalCreativeHold(true)
        await status.setLocalCreativeHold(false)
        let paused = await status.operatorPauseFence
        XCTAssertTrue(paused)
        let admission = await status.beginRequestIfAccepting()
        XCTAssertNil(admission)
    }

    func testCreativeHoldReloadsThroughSwapEvenWhenOperatorSwapIsDisabled() async throws {
        let status = ProviderStatus(modelID: "fixture", modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: 1))
        let runtime = ModelRuntime(modelID: "fixture", warmSwapEnabled: false,
            loader: { _ in throw CocoaError(.fileReadUnknown) },
            testLoader: { ($0, "fixture-hash") },
            testCompletion: { _, _ in throw CocoaError(.fileReadUnknown) })
        await runtime.setProviderStatus(status)
        await status.setLocalCreativeHold(true)
        try await runtime.unloadForLocalCreativeHold()
        let unloaded = await runtime.isLoaded
        let unloadedSnapshot = await runtime.currentSnapshot()
        XCTAssertFalse(unloaded)
        XCTAssertNil(unloadedSnapshot.modelID)
        do {
            _ = try await runtime.beginSwap(targetModelID: "other")
            XCTFail("Creative hold must fence ordinary model swaps")
        } catch let error as APIError { XCTAssertEqual(error.code, "local_creative_hold") }
        try await runtime.restoreAfterLocalCreativeHold()
        let restored = await runtime.isLoaded
        let restoredSnapshot = await runtime.currentSnapshot()
        XCTAssertTrue(restored)
        XCTAssertEqual(restoredSnapshot.modelID, "fixture")
        // Restoration cannot reopen admission before the creative hold is released.
        let heldAdmission = await status.beginRequestIfAccepting()
        XCTAssertNil(heldAdmission)
        await status.setLocalCreativeHold(false)
        let admission = await status.beginRequestIfAccepting()
        XCTAssertNotNil(admission)
        if let admission { await status.finishRequest(startedAt: admission, completion: nil, failed: false) }
    }

    func testRestoreFailureReleasesCreativePauseAndReportsError() async throws {
        let events = ImageEvents()
        let service = LocalImageGeneration(backend: FakeImageBackend(events: events, failure: true, blocking: false),
            lifecycle: LocalCreativeLifecycle(pause: { await events.add("pause") }, drain: { await events.add("drain") },
                unloadLanguage: { await events.add("unload_language") },
                restoreLanguage: { await events.add("restore_language"); throw CocoaError(.fileReadUnknown) },
                resume: { await events.add("resume") }),
            physicalBytes: 16 * 1_073_741_824, availableBytes: { 0 })
        do { _ = try await service.generate(request()); XCTFail("Expected failure") } catch {}
        let values = await events.values
        XCTAssertEqual(values.filter { $0 == "restore_language" }.count, 3)
        XCTAssertEqual(values.last, "resume")
        let snapshot = await service.status()
        XCTAssertEqual(snapshot["state"] as? String, "recovery_required")
        XCTAssertTrue((snapshot["last_error"] as? String)?.contains("Could not reload") == true)
    }

    func testStaleRequestCancellationCannotCancelSuccessorOrItsWarmLease() async throws {
        let events = ImageEvents()
        let backend = ControlledImageBackend(events: events)
        let service = LocalImageGeneration(backend: backend,
            lifecycle: LocalCreativeLifecycle(pause: {}, drain: {}, unloadLanguage: {}, restoreLanguage: {}, resume: {}),
            physicalBytes: 32 * 1_073_741_824, availableBytes: { 32_000_000_000 })
        let firstID = UUID(), secondID = UUID()
        _ = try await service.generate(request(), operationID: firstID)
        await backend.blockNext()
        let second = Task { try await service.generate(request(), operationID: secondID) }
        await waitForGenerating(service)
        await service.cancel(operationID: firstID)
        let generating = await service.state
        XCTAssertEqual(generating, .generating)
        await backend.release()
        _ = try await second.value
        await service.cancel(operationID: firstID)
        let warm = await service.state
        XCTAssertEqual(warm, .warm)
        await service.cancel(operationID: secondID)
        let idle = await service.state
        XCTAssertEqual(idle, .idle)
    }

    func testEveryFailurePathReopensAdmissionAndOrdinaryRuntimeRecovery() async throws {
        for scenario in CreativeFailureScenario.allCases {
            let reloads = CreativeReloadControl()
            let status = ProviderStatus(modelID: "fixture", modelLoaded: true,
                capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: 1))
            let runtime = ModelRuntime(modelID: "fixture", warmSwapEnabled: true,
                loader: { _ in throw CocoaError(.fileReadUnknown) },
                testLoader: { try await reloads.load($0) },
                testCompletion: { _, _ in throw CocoaError(.fileReadUnknown) })
            await runtime.setProviderStatus(status)
            let backend = RecoveryImageBackend(scenario: scenario)
            let service = LocalImageGeneration(backend: backend,
                lifecycle: LocalCreativeLifecycle(
                    pause: { await status.setLocalCreativeHold(true) },
                    drain: {
                        if scenario == .drainTimeout { throw URLError(.timedOut) }
                    },
                    unloadLanguage: { try await runtime.unloadForLocalCreativeHold() },
                    restoreLanguage: { try await runtime.restoreAfterLocalCreativeHold() },
                    resume: { await status.setLocalCreativeHold(false) },
                    abandonLanguage: { await runtime.abandonLocalCreativeHold() }),
                physicalBytes: 16 * 1_073_741_824, availableBytes: { 0 })
            if scenario == .restoreExhausted { await reloads.setFailures(3) }
            if scenario == .restoreRetry { await reloads.setFailures(1) }
            let task = Task { try await service.generate(request()) }
            if scenario == .cancel {
                await waitForGenerating(service)
                await service.cancel()
            }
            do { _ = try await task.value; XCTFail("Expected failure: \(scenario)") } catch {}
            let held = await status.localCreativeHold
            XCTAssertFalse(held, "\(scenario)")
            let imageState = await service.state
            XCTAssertEqual(imageState, scenario == .restoreExhausted ? .recoveryRequired : .idle, "\(scenario)")
            let loaded = await runtime.isLoaded
            XCTAssertEqual(loaded, scenario != .restoreExhausted, "\(scenario)")
            if scenario == .restoreExhausted {
                let attempts = await reloads.attempts
                XCTAssertEqual(attempts, 3)
                await service.restore()
                let stillFailed = await service.state
                XCTAssertEqual(stillFailed, .recoveryRequired)
            } else {
                let admission = await status.beginRequestIfAccepting()
                XCTAssertNotNil(admission, "\(scenario)")
                if let admission { await status.finishRequest(startedAt: admission, completion: nil, failed: false) }
            }
            // The normal warm swap must never encounter a leftover creative owner,
            // even when the model could not be restored during cleanup.
            let swap = try await runtime.beginSwap(targetModelID: "recovered")
            try await swap.value
            let recovered = await runtime.currentSnapshot()
            XCTAssertEqual(recovered.modelID, "recovered", "\(scenario)")
            let admission = await status.beginRequestIfAccepting()
            XCTAssertNotNil(admission, "\(scenario)")
            if let admission { await status.finishRequest(startedAt: admission, completion: nil, failed: false) }
        }
    }

    private func waitForGenerating(_ service: LocalImageGeneration) async {
        for _ in 0..<200 {
            if await service.state == .generating { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Image backend did not begin generation")
    }

    private func service(events: ImageEvents, failure: Bool = false, blocking: Bool = false,
                         available: UInt64 = 0, warmNanoseconds: UInt64 = 120_000_000_000) -> LocalImageGeneration {
        LocalImageGeneration(backend: FakeImageBackend(events: events, failure: failure, blocking: blocking),
            lifecycle: LocalCreativeLifecycle(pause: { await events.add("pause") }, drain: { await events.add("drain") },
                unloadLanguage: { await events.add("unload_language") }, restoreLanguage: { await events.add("restore_language") },
                resume: { await events.add("resume") }), physicalBytes: 16 * 1_073_741_824,
            availableBytes: { available }, warmNanoseconds: warmNanoseconds)
    }
}

private actor ImageEvents {
    var values: [String] = []
    func add(_ value: String) { values.append(value) }
}
private struct FakeImageBackend: LocalImageBackend {
    let events: ImageEvents
    let failure: Bool
    let blocking: Bool
    func prepare(quantized: Bool, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        await events.add("prepare"); progress(50, 100)
    }
    func generate(_ request: LocalImageRequest) async throws -> Data {
        await events.add("generate")
        if failure { throw CocoaError(.fileReadUnknown) }
        if blocking {
            do { try await Task.sleep(nanoseconds: 30_000_000_000) }
            catch { await events.add("generation_stopped"); throw error }
        }
        return Data("png".utf8)
    }
    func unload() async { await events.add("unload_image") }
}

private struct BlockingDownloadImageBackend: LocalImageBackend {
    let events: ImageEvents
    func prepare(quantized: Bool, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        progress(50, 100)
        do { try await Task.sleep(nanoseconds: 30_000_000_000) }
        catch { await events.add("download_stopped"); throw error }
    }
    func generate(_ request: LocalImageRequest) async throws -> Data {
        XCTFail("Cancelled download must never reach generation")
        throw CancellationError()
    }
    func unload() async { await events.add("unload_image") }
}

private enum CreativeFailureScenario: CaseIterable, Sendable {
    case backendCrash, downloadTimeout, generationTimeout, drainTimeout, cancel, restoreRetry, restoreExhausted
}
private struct RecoveryImageBackend: LocalImageBackend {
    let scenario: CreativeFailureScenario
    func prepare(quantized: Bool, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        if scenario == .downloadTimeout { throw URLError(.timedOut) }
    }
    func generate(_ request: LocalImageRequest) async throws -> Data {
        if scenario == .cancel { try await Task.sleep(nanoseconds: 30_000_000_000) }
        if scenario == .generationTimeout { throw URLError(.timedOut) }
        throw CocoaError(.fileReadUnknown)
    }
    func unload() async {}
}
private actor CreativeReloadControl {
    private var failures = 0
    private(set) var attempts = 0
    func setFailures(_ count: Int) { failures = count }
    func load(_ modelID: String) throws -> (String, String?) {
        attempts += 1
        if failures > 0 { failures -= 1; throw CocoaError(.fileReadUnknown) }
        return (modelID, "fixture-hash")
    }
}
private actor ControlledImageBackend: LocalImageBackend {
    let events: ImageEvents
    private var blocked = false
    init(events: ImageEvents) { self.events = events }
    func blockNext() { blocked = true }
    func release() { blocked = false }
    func prepare(quantized: Bool, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {}
    func generate(_ request: LocalImageRequest) async throws -> Data {
        while blocked { try await Task.sleep(nanoseconds: 5_000_000) }
        return Data("png".utf8)
    }
    func unload() async { await events.add("unload_image") }
}
