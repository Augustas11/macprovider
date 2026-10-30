import Foundation
import XCTest
@testable import macprovider_cli

final class NativeMTPBenchCampaignTests: XCTestCase {
    func testManifestRequiresLabScopeAndOrderedDepths() throws {
        XCTAssertThrowsError(try NativeMTPBenchCampaign.requireScope(labBuild: false, permitted: true))
        XCTAssertThrowsError(try NativeMTPBenchCampaign.requireScope(labBuild: true, permitted: false))
        XCTAssertNoThrow(try NativeMTPBenchCampaign.requireScope(labBuild: true, permitted: true))
        XCTAssertNoThrow(try decode(steps()).validateStructure())
        var reordered = steps()
        reordered.swapAt(0, 1)
        XCTAssertThrowsError(try decode(reordered).validateStructure())
    }

    func testFrozenGroupSelectionPreservesOriginalIndicesAndLegacyCoverage() throws {
        XCTAssertEqual(try NativeMTPBenchCampaign.selectedFrozenGroupIndices(nil), Array(0..<19))
        XCTAssertEqual(try NativeMTPBenchCampaign.selectedFrozenGroupIndices(Array(12..<19)),
            [12, 13, 14, 15, 16, 17, 18])
        XCTAssertEqual(try NativeMTPBenchCampaign.selectedFrozenGroupIndices([0, 18]), [0, 18])
        // The caller may validate against its derived corpus geometry too.
        XCTAssertEqual(try NativeMTPBenchCampaign.selectedFrozenGroupIndices(nil, totalGroupCount: 3), [0, 1, 2])
        XCTAssertThrowsError(try NativeMTPBenchCampaign.selectedFrozenGroupIndices([3], totalGroupCount: 3))
        XCTAssertThrowsError(try NativeMTPBenchCampaign.selectedFrozenGroupIndices(nil, totalGroupCount: 0))
    }

    func testFrozenGroupSelectionRejectsEmptyDuplicateUnorderedAndOutOfRangeIndices() {
        for selection in [[], [12, 12], [13, 12], [-1], [19]] as [[Int]] {
            XCTAssertThrowsError(try NativeMTPBenchCampaign.selectedFrozenGroupIndices(selection),
                "invalid selection: \(selection)")
        }
    }

    func testManifestFrozenGroupSelectorValidationPrecedesInputLoading() throws {
        var selected = steps()
        selected[0]["frozen_group_indices"] = Array(12..<19)
        XCTAssertEqual(try decode(selected).steps[0].frozenGroupIndices, Array(12..<19))
        XCTAssertNil(try decode(steps()).steps[0].frozenGroupIndices)
        XCTAssertNoThrow(try decode(selected).validateStructure())
        for invalid in [[], [12, 12], [13, 12], [-1], [19]] as [[Int]] {
            var records = steps()
            records[0]["frozen_group_indices"] = invalid
            XCTAssertThrowsError(try decode(records).validateStructure())
        }
        for index in [4, 8] {
            var records = steps()
            records[index]["frozen_group_indices"] = [12]
            XCTAssertThrowsError(try decode(records).validateStructure())
        }
        for invalid in ["12", [12.5], [true]] as [Any] {
            var records = steps()
            records[0]["frozen_group_indices"] = invalid
            XCTAssertThrowsError(try decode(records))
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        var records = steps()
        records[0]["frozen_group_indices"] = [] as [Int]
        let manifest = root.appendingPathComponent("invalid-selector.json")
        try JSONSerialization.data(withJSONObject: ["schema": "macprovider.native-mtp-resident-campaign.v1",
            "steps": records]).write(to: manifest)
        XCTAssertThrowsError(try NativeMTPBenchCampaign.load(path: manifest.path)) {
            XCTAssertTrue(String(describing: $0).contains("frozen_group_indices"),
                "selector rejection must precede opening nonexistent policy/model inputs")
        }
    }

    func testManifestRequiresDistinctFrozenAndMatrixOutputsAndExactSustainedBinding() throws {
        var duplicate = steps()
        duplicate[1]["out"] = duplicate[0]["out"]
        XCTAssertThrowsError(try decode(duplicate).validateStructure())
        var colliding = steps()
        colliding[0]["out"] = colliding[7]["policy"]
        XCTAssertThrowsError(try decode(colliding).validateStructure())
        var noncanonical = steps()
        noncanonical[0]["requests"] = "/campaign/sub/../requests.json"
        XCTAssertThrowsError(try decode(noncanonical).validateStructure())
        var changedPolicy = steps()
        changedPolicy[8]["policy_sha256"] = String(repeating: "b", count: 64)
        XCTAssertThrowsError(try decode(changedPolicy).validateStructure())
        var wrongRequests = steps()
        wrongRequests[0]["requests_sha256"] = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try decode(wrongRequests).validateStructure())
    }

    func testChangedPolicyBytesFailBeforePolicyParsingOrModelLoading() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = root.appendingPathComponent("changed.json")
        try Data("changed immutable policy".utf8).write(to: policy)
        var records = steps()
        for index in records.indices { records[index]["policy"] = policy.path }
        let path = root.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: ["schema": "macprovider.native-mtp-resident-campaign.v1", "steps": records]).write(to: path)
        XCTAssertThrowsError(try NativeMTPBenchCampaign.load(path: path.path)) {
            XCTAssertTrue(String(describing: $0).contains("checksum mismatch"))
        }
        let existing = root.appendingPathComponent("existing.jsonl")
        try Data("retained measurement".utf8).write(to: existing)
        for index in records.indices {
            records[index]["policy_sha256"] = NativeMTPLabCBInputs.sha(try Data(contentsOf: policy))
        }
        records[0]["out"] = existing.path
        try JSONSerialization.data(withJSONObject: ["schema": "macprovider.native-mtp-resident-campaign.v1", "steps": records]).write(to: path)
        XCTAssertThrowsError(try NativeMTPBenchCampaign.load(path: path.path)) {
            XCTAssertTrue(String(describing: $0).contains("fresh frozen and matrix outputs"))
        }
        XCTAssertEqual(try String(contentsOf: existing), "retained measurement")
    }

    actor Counter {
        private var count = 0
        func next() -> Int { count += 1; return count }
        func value() -> Int { count }
    }

    func testResidentWeightsLoadOnceAcrossConcurrentRequestsAndRejectIdentityChange() async throws {
        let resident = NativeMTPBenchResident<Int>()
        let loads = Counter()
        async let first = resident.value(identity: "same-artifact") { await loads.next() }
        async let second = resident.value(identity: "same-artifact") { await loads.next() }
        let values = try await (first, second)
        XCTAssertEqual(values.0, 1)
        XCTAssertEqual(values.1, 1)
        let count = await loads.value()
        XCTAssertEqual(count, 1)
        do {
            _ = try await resident.value(identity: "different-artifact") { 99 }
            XCTFail("Changing the resident artifact must fail closed")
        } catch { }
    }

    private func decode(_ steps: [[String: Any]]) throws -> NativeMTPBenchCampaign {
        try JSONDecoder().decode(NativeMTPBenchCampaign.self, from: JSONSerialization.data(
            withJSONObject: ["schema": "macprovider.native-mtp-resident-campaign.v1", "steps": steps]))
    }

    private func steps() -> [[String: Any]] {
        ["frozen", "matrix", "sustained"].flatMap { kind in
            [1, 2, 3, 5].map { depth in
                let phase = kind == "sustained" ? "matrix" : kind
                var step: [String: Any] = ["kind": kind, "depth": depth,
                    "policy": "/campaign/\(phase)-\(depth).json", "policy_sha256": String(repeating: "a", count: 64),
                    "out": "/campaign/\(phase)-\(depth).jsonl"]
                if kind == "frozen" {
                    step["requests"] = "/campaign/requests.json"
                    step["requests_sha256"] = "01bb9294714fcc95c7dc8540b460c309f8c5ff782214d24b3e95d4e4297b9383"
                    step["long_token_ids"] = "/campaign/long.json"
                    step["long_token_ids_sha256"] = "1d64f1cd35c336489c5c00edc65fa69740735250300bf26b7c960feaa3d41bc5"
                }
                return step
            }
        }
    }
}
