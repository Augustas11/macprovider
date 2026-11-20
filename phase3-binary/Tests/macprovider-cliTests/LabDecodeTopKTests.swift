#if DEBUG || MACPROVIDER_LAB_HARNESS
import Foundation
import MLX
import MLXLMCommon
import XCTest
@testable import macprovider_cli

final class LabDecodeTopKTests: XCTestCase {
    override func invokeTest() {
        Device.withDefaultDevice(Device(.cpu)) {
            super.invokeTest()
        }
    }

    override class func setUp() {
        super.setUp()
        MLXTestDevice.pinProcessCPUDefaultWithoutMetallib()
    }

    func testUnsetIsOffAndLeavesComponentsUnchanged() throws {
        XCTAssertNil(try LabDecodeTopK.configuration(environment: [:]))
        XCTAssertNil(try LabDecodeTopK.configuration(environment: [LabDecodeTopK.pathKey: ""]))
        let components = try LabDecodeTopK.appending(to: GenerationComponents(), promptTokenIDs: [1], environment: [:])
        XCTAssertNil(components.logitProcessorFactory)
    }

    func testConfigurationParsesAndFailsClosed() throws {
        let path = "/private/tmp/topk.jsonl"
        XCTAssertEqual(
            try LabDecodeTopK.configuration(environment: [
                LabDecodeTopK.pathKey: path, LabDecodeTopK.indicesKey: "15, 0", LabDecodeTopK.kKey: "8",
            ]),
            LabDecodeTopK.Configuration(path: path, indices: [0, 15], k: 8))
        XCTAssertEqual(
            try LabDecodeTopK.configuration(environment: [LabDecodeTopK.pathKey: path, LabDecodeTopK.indicesKey: "3"])?.k, 5)
        for bad in [
            [LabDecodeTopK.pathKey: "relative.jsonl", LabDecodeTopK.indicesKey: "1"],
            [LabDecodeTopK.pathKey: path],
            [LabDecodeTopK.pathKey: path, LabDecodeTopK.indicesKey: "1,x"],
            [LabDecodeTopK.pathKey: path, LabDecodeTopK.indicesKey: "-1"],
            [LabDecodeTopK.pathKey: path, LabDecodeTopK.indicesKey: "1,"],
            [LabDecodeTopK.pathKey: path, LabDecodeTopK.indicesKey: "1", LabDecodeTopK.kKey: "1"],
            [LabDecodeTopK.pathKey: path, LabDecodeTopK.indicesKey: "1", LabDecodeTopK.kKey: "65"],
        ] {
            XCTAssertThrowsError(try LabDecodeTopK.configuration(environment: bad), "\(bad)")
        }
    }

    /// Drives the processor the way TokenIterator does (process, sample,
    /// didSample) and checks it records exactly the chosen indices, with the
    /// ids before each, passes logits through unchanged and keeps bf16 values.
    func testRecordsChosenIndicesWithPrefixIdsAndUnchangedLogits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("topk.jsonl")
        let components = try LabDecodeTopK.appending(
            to: GenerationComponents(), promptTokenIDs: [7, 8, 9],
            environment: [LabDecodeTopK.pathKey: file.path, LabDecodeTopK.indicesKey: "1,2", LabDecodeTopK.kKey: "3"])
        var processor = try XCTUnwrap(components.logitProcessorFactory?())
        processor.prompt(MLXArray([Int32(9)]))
        let steps: [[Float]] = [
            [0, 5, 1, 2],
            [23.875, 1, 23.375, 23.5],
            [3, 2, 1, 4],
        ]
        for values in steps {
            let logits = MLXArray(values).asType(.bfloat16).reshaped([1, 4])
            let out = processor.process(logits: logits)
            XCTAssertEqual(out.asType(.float32).asArray(Float.self), values)
            processor.didSample(token: argMax(out, axis: -1))
        }
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        let records = try lines.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0]["schema"] as? String, LabDecodeTopK.schema)
        XCTAssertEqual(records[0]["decode_index"] as? Int, 1)
        XCTAssertEqual(records[0]["prompt_token_ids"] as? [Int], [7, 8, 9])
        XCTAssertEqual(records[0]["generated_token_ids"] as? [Int], [1])
        XCTAssertEqual(records[0]["top_ids"] as? [Int], [0, 3, 2])
        XCTAssertEqual(records[0]["top_logits"] as? [Double], [23.875, 23.5, 23.375])
        XCTAssertEqual(records[0]["dtype"] as? String, "bfloat16")
        XCTAssertEqual(records[1]["decode_index"] as? Int, 2)
        XCTAssertEqual(records[1]["generated_token_ids"] as? [Int], [1, 0])
        XCTAssertEqual(records[1]["top_ids"] as? [Int], [3, 0, 1])
    }
}
#endif
