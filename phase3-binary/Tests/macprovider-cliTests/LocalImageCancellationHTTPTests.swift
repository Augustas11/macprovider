import Foundation
import MacProviderCore
import NIO
import NIOHTTP1
import XCTest
@testable import macprovider_cli

final class LocalImageCancellationHTTPTests: XCTestCase {
    func testDisconnectedCompletedRequestCannotCancelSuccessorOnAnotherConnection() async throws {
        let backend = CancellationHTTPBackend()
        let images = LocalImageGeneration(backend: backend,
            lifecycle: LocalCreativeLifecycle(pause: {}, drain: {}, unloadLanguage: {}, restoreLanguage: {}, resume: {}),
            physicalBytes: 32 * 1_073_741_824, availableBytes: { 32_000_000_000 })
        let status = ProviderStatus(modelID: "fixture", modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: 1))
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
        let firstSession = URLSession(configuration: .ephemeral)
        let secondSession = URLSession(configuration: .ephemeral)
        do {
            let port = try XCTUnwrap(channel.localAddress?.port)
            let firstID = UUID(), secondID = UUID()
            func request(_ path: String, id: UUID?) -> URLRequest {
                var value = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/images/\(path)")!)
                value.httpMethod = "POST"
                value.setValue("application/json", forHTTPHeaderField: "Content-Type")
                value.setValue("local-app", forHTTPHeaderField: "X-MacProvider-Origin")
                if let id { value.setValue(id.uuidString, forHTTPHeaderField: "X-MacProvider-Image-Operation-ID") }
                value.httpBody = Data("{\"prompt\":\"sea\"}".utf8)
                return value
            }
            let (_, firstResponse) = try await firstSession.data(for: request("generations", id: firstID))
            XCTAssertEqual((firstResponse as? HTTPURLResponse)?.statusCode, 200)
            let second = Task { try await secondSession.data(for: request("generations", id: secondID)) }
            for _ in 0..<200 {
                if await backend.calls == 2 { break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            let calls = await backend.calls
            XCTAssertEqual(calls, 2)
            firstSession.invalidateAndCancel()
            // A delayed Stop from the disconnected connection carries A's ID.
            let (_, cancelResponse) = try await secondSession.data(for: request("generations/cancel", id: firstID))
            XCTAssertEqual((cancelResponse as? HTTPURLResponse)?.statusCode, 200)
            let (_, unscopedResponse) = try await secondSession.data(for: request("generations/cancel", id: nil))
            XCTAssertEqual((unscopedResponse as? HTTPURLResponse)?.statusCode, 400)
            await backend.release()
            let (_, secondResponse) = try await second.value
            XCTAssertEqual((secondResponse as? HTTPURLResponse)?.statusCode, 200)
            await images.restore()
            secondSession.invalidateAndCancel()
            try await channel.close().get()
            try await group.shutdownGracefully()
        } catch {
            await backend.release()
            firstSession.invalidateAndCancel(); secondSession.invalidateAndCancel()
            await images.cancel()
            try? await channel.close().get(); try? await group.shutdownGracefully()
            throw error
        }
    }
}

private actor CancellationHTTPBackend: LocalImageBackend {
    private(set) var calls = 0
    private var released = false
    func prepare(quantized: Bool, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {}
    func generate(_ request: LocalImageRequest) async throws -> Data {
        calls += 1
        if calls == 2 {
            while !released { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        return Data("png".utf8)
    }
    func release() { released = true }
    func unload() async {}
}
