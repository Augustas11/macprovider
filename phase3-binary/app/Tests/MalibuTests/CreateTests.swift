import AppKit
import SwiftUI
import XCTest
@testable import Malibu

@MainActor
final class CreateTests: XCTestCase {
    func testSidebarIncludesCreateInRequiredOrder() {
        XCTAssertEqual(MalibuSection.allCases.map(\.title),
                       ["Chat", "Terminal", "Create", "Agents", "Tasks", "Models", "Earn", "Settings", "Diagnostics"])
        XCTAssertEqual(MalibuNavigation(persistedValue: "create").selection, .create)
    }

    func testEachProviderStateHasReadableCreatePresentation() async throws {
        let expected: [CreatePhase: String] = [.idle: "Ready to create", .downloading: "Downloading image model",
            .holdingCustomers: "Pausing earning while creating", .generating: "Creating image",
            .warm: "Image model ready", .restoring: "Restoring customer work",
            .recoveryRequired: "Language model recovery needed"]
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let transport = FakeCreateTransport()
        let store = CreateStore(transport: transport, gallery: CreateGallery(home: home))
        store.prompt = "A watercolor landscape"
        for phase in CreatePhase.allCases {
            transport.current = try status(phase: phase)
            await store.refresh(port: 8080)
            XCTAssertEqual(store.status?.phase.label, expected[phase])
            XCTAssertEqual(store.canGenerate, [.idle, .warm, .recoveryRequired].contains(phase))
            let host = NSHostingView(rootView: CreateScreen(store: store))
            host.frame = NSRect(x: 0, y: 0, width: 900, height: 900)
            host.layoutSubtreeIfNeeded()
            XCTAssertFalse(host.fittingSize.width.isNaN)
        }
        transport.current = try status(phase: .downloading)
        await store.refresh(port: 8080)
        XCTAssertEqual(store.status?.progress, 0.5)
        XCTAssertTrue(store.status?.downloadLabel?.contains("of") == true)
    }

    func testRAMGatesLargeImagesAndResetsStaleSelection() async throws {
        for ram in [8, 16, 24, 32, 64] {
            XCTAssertEqual(try status(ram: UInt64(ram)).supportsLargeImages, ram >= 32)
        }
        XCTAssertThrowsError(try CreateRequest(prompt: "Image", size: "1024x1024", steps: 4, seed: "", physicalMemory: 16 * 1_073_741_824))
        XCTAssertNoThrow(try CreateRequest(prompt: "Image", size: "1024x1024", steps: 4, seed: "", physicalMemory: 32 * 1_073_741_824))
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let transport = FakeCreateTransport(); transport.current = try status(ram: 16)
        let store = CreateStore(transport: transport, gallery: CreateGallery(home: home))
        XCTAssertEqual(store.steps, 4)
        store.size = "1024x1024"
        await store.refresh(port: 8080)
        XCTAssertEqual(store.size, "512x512")
    }

    func testUnavailableForOlderProviderAndMemoryAndDisconnectedProvider() async throws {
        XCTAssertThrowsError(try CreateStatus.parse(Data("{\"local_status_contract\":{\"capabilities\":[]}}".utf8))) {
            XCTAssertEqual($0 as? CreateFailure, .upgradeRequired)
        }
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let transport = FakeCreateTransport(); transport.failure = .upgradeRequired
        let store = CreateStore(transport: transport, gallery: CreateGallery(home: home))
        await store.refresh(port: 8080)
        XCTAssertEqual(store.unavailableReason, CreateFailure.upgradeRequired.localizedDescription)
        XCTAssertFalse(store.canGenerate)
        transport.failure = nil; transport.current = try status(available: false)
        await store.refresh(port: 8080)
        XCTAssertTrue(store.unavailableReason?.contains("memory") == true)
        XCTAssertFalse(store.canGenerate)
        transport.current = try CreateStatus.parse(JSONSerialization.data(withJSONObject: [
            "local_status_contract": ["capabilities": ["local_image_generation_v1"]],
            "local_image_generation": ["state": "idle", "physical_memory_bytes": UInt64(32 * 1_073_741_824),
                "available": false, "unavailable_reason": "Image generation requires the native MLX provider runtime."]]))
        await store.refresh(port: 8080)
        XCTAssertTrue(store.unavailableReason?.contains("native image generation runtime") == true)
        await store.refresh(port: nil)
        XCTAssertEqual(store.unavailableReason, CreateFailure.unavailable.localizedDescription)
    }

    func testRequestValidationAndLocalOnlyTransport() throws {
        for prompt in ["", "   \n", String(repeating: "x", count: 4001)] {
            XCTAssertThrowsError(try CreateRequest(prompt: prompt, size: "512x512", steps: 4, seed: "", physicalMemory: 16 * 1_073_741_824))
        }
        for seed in ["-1", "1.5", "18446744073709551616", "abc"] {
            XCTAssertThrowsError(try CreateRequest(prompt: "Image", size: "512x512", steps: 4, seed: seed, physicalMemory: 16 * 1_073_741_824))
        }
        let payload = try CreateRequest(prompt: "Image", size: "512x512", steps: 1, seed: "42", physicalMemory: 16 * 1_073_741_824)
        let body = try JSONEncoder().encode(payload)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["n"] as? Int, 1); XCTAssertEqual(object["response_format"] as? String, "b64_json")
        XCTAssertEqual(object["seed"] as? Int, 42)
        let operationID = UUID()
        for path in ["/v1/images/generations", "/v1/images/generations/cancel"] {
            let request = LocalCreateTransport.request(at: try ChatEndpoint(port: 8080), path: path, body: body, operationID: operationID)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-MacProvider-Image-Operation-ID"), operationID.uuidString)
            XCTAssertEqual(request.url?.host, "127.0.0.1")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-MacProvider-Origin"), "local-app")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            if path == "/v1/images/generations" { XCTAssertEqual(request.timeoutInterval, 3600) }
        }
    }

    func testGallerySavesPNGAtPicturesMalibuWithOwnerOnlyPermissionsAndUniqueNames() throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let gallery = CreateGallery(home: home)
        let data = try png()
        let first = try gallery.save(data), second = try gallery.save(data)
        XCTAssertEqual(first.url.deletingLastPathComponent(), home.appendingPathComponent("Pictures/Malibu", isDirectory: true))
        XCTAssertEqual(first.url.pathExtension, "png"); XCTAssertNotEqual(first, second)
        let saved = try Data(contentsOf: first.url)
        XCTAssertTrue(saved.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]))
        XCTAssertNotNil(NSBitmapImageRep(data: saved))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: first.url.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: gallery.directory.path)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(Set(try gallery.load()), Set([first, second]))
        XCTAssertThrowsError(try gallery.save(Data("not an image".utf8)))
    }

    func testGalleryRejectsSymlinkDirectoriesAndExcludesSymlinkFiles() throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let external = home.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let pictures = home.appendingPathComponent("Pictures")
        try FileManager.default.createSymbolicLink(at: pictures, withDestinationURL: external)
        XCTAssertThrowsError(try CreateGallery(home: home).save(png()))
        try FileManager.default.removeItem(at: pictures)
        try FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: pictures.appendingPathComponent("Malibu"), withDestinationURL: external)
        XCTAssertThrowsError(try CreateGallery(home: home).save(png()))
        try FileManager.default.removeItem(at: pictures.appendingPathComponent("Malibu"))
        let gallery = CreateGallery(home: home)
        let image = try gallery.save(png())
        try FileManager.default.createSymbolicLink(at: gallery.directory.appendingPathComponent("Malibu-link.png"), withDestinationURL: image.url)
        XCTAssertEqual(try gallery.load(), [image])
    }

    func testGeneratePersistsResultAndCancellationCallsProvider() async throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let transport = FakeCreateTransport(); transport.image = try png(); transport.current = try status()
        let store = CreateStore(transport: transport, gallery: CreateGallery(home: home))
        store.prompt = "A landscape"; await store.refresh(port: 8080)
        store.generate(); await store.waitForGeneration()
        XCTAssertEqual(store.images.count, 1); XCTAssertFalse(store.isRunning)
        transport.block = true
        store.generate()
        await Task.yield()
        await store.cancel(); await store.waitForGeneration()
        XCTAssertEqual(transport.cancelCount, 1)
        XCTAssertEqual(store.images.count, 1); XCTAssertFalse(store.isRunning)
    }

    func testGenerationFailureLeavesGalleryUnchangedAndAllowsRetry() async throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let transport = FakeCreateTransport(); transport.image = try png(); transport.current = try status()
        let store = CreateStore(transport: transport, gallery: CreateGallery(home: home))
        store.prompt = "A landscape"; await store.refresh(port: 8080)
        transport.generationFailure = .busy
        store.generate(); await store.waitForGeneration()
        XCTAssertTrue(store.images.isEmpty)
        XCTAssertEqual(store.notice, CreateFailure.busy.localizedDescription)
        XCTAssertFalse(store.isRunning); XCTAssertTrue(store.canGenerate)
        transport.generationFailure = nil
        store.generate(); await store.waitForGeneration()
        XCTAssertEqual(store.images.count, 1); XCTAssertNil(store.notice)
    }

    private func status(phase: CreatePhase = .idle, ram: UInt64 = 32, available: Bool = true) throws -> CreateStatus {
        try CreateStatus.parse(JSONSerialization.data(withJSONObject: [
            "local_status_contract": ["capabilities": ["local_image_generation_v1"]],
            "local_image_generation": ["state": phase.rawValue, "progress": 0.5, "downloaded_bytes": 500,
                "total_bytes": 1000, "physical_memory_bytes": ram * 1_073_741_824, "available": available,
                "unavailable_reason": "memory_code_not_for_display"]]))
    }
    private func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func png() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 512, pixelsHigh: 512,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}

@MainActor
private final class FakeCreateTransport: CreateTransport {
    var current: CreateStatus?
    var failure: CreateFailure?
    var generationFailure: CreateFailure?
    var image = Data()
    var block = false
    var cancelCount = 0
    func status(at endpoint: ChatEndpoint) async throws -> CreateStatus {
        if let failure { throw failure }
        return try XCTUnwrap(current)
    }
    func generate(at endpoint: ChatEndpoint, request: CreateRequest) async throws -> Data {
        if let generationFailure { throw generationFailure }
        while block { try await Task.sleep(for: .milliseconds(10)) }
        return image
    }
    func cancel(at endpoint: ChatEndpoint) async throws { cancelCount += 1 }
}
