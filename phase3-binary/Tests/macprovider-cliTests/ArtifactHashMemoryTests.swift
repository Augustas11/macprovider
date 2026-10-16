import Darwin
import XCTest
@testable import macprovider_cli

/// Hashing a weight shard must not keep its bytes resident. `FileHandle`
/// returns autoreleased buffers; a chunk loop without its own pool holds the
/// whole file until the caller's pool drains, which doubled the load peak of
/// a 186 GB model (weights plus every shard's bytes) and got it killed.
final class ArtifactHashMemoryTests: XCTestCase {
    private static let fileBytes = 512 * 1024 * 1024
    private static let allowedGrowth = 128 * 1024 * 1024

    private func physFootprint() throws -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        // A failed probe must fail the test, not read as zero growth.
        guard result == KERN_SUCCESS else { throw NSError(domain: "task_info", code: Int(result)) }
        return Int(info.phys_footprint)
    }

    private func sparseShard() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hash-memory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("model-00001-of-00001.safetensors")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(Self.fileBytes))
        try handle.close()
        return url
    }

    func testWeightManifestHashDoesNotRetainShardBytes() throws {
        let shard = try sparseShard()
        let before = try physFootprint()
        XCTAssertNotNil(try ModelRuntime.modelWeightArtifactManifestHash(in: shard.deletingLastPathComponent()))
        let growth = try physFootprint() - before
        XCTAssertLessThan(growth, Self.allowedGrowth, "hashing a \(Self.fileBytes >> 20) MB shard kept \(growth >> 20) MB resident")
    }

    func testArtifactSizeAndHashDoesNotRetainFileBytes() throws {
        let shard = try sparseShard()
        let before = try physFootprint()
        let (size, _) = try ModelArtifactVerifier.sizeAndSHA256(of: shard)
        let growth = try physFootprint() - before
        XCTAssertEqual(size, UInt64(Self.fileBytes))
        XCTAssertLessThan(growth, Self.allowedGrowth, "hashing a \(Self.fileBytes >> 20) MB file kept \(growth >> 20) MB resident")
    }
}
