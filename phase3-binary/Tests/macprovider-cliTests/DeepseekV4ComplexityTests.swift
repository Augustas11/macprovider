import Foundation
import XCTest
@testable import macprovider_cli

final class DeepseekV4ComplexityTests: XCTestCase {
    private typealias Encoding = DeepseekV4Encoding

    /// Use the fastest of three interleaved samples to discount scheduler
    /// delays. Eight times the input gets a generous 20x budget: linear work
    /// fits comfortably, while the former repeated scan/copy approaches 64x.
    private func assertSubquadratic(
        _ work: (Int) throws -> Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) rethrows {
        _ = try work(256)
        var small = UInt64.max
        var large = UInt64.max
        for _ in 0..<3 {
            var start = DispatchTime.now().uptimeNanoseconds
            XCTAssertGreaterThan(try work(256), 0, file: file, line: line)
            small = min(small, DispatchTime.now().uptimeNanoseconds - start)
            start = DispatchTime.now().uptimeNanoseconds
            XCTAssertGreaterThan(try work(2_048), 0, file: file, line: line)
            large = min(large, DispatchTime.now().uptimeNanoseconds - start)
        }
        XCTAssertLessThan(
            large, small * 20,
            "8x compact messages took \(Double(large) / Double(small))x as long",
            file: file, line: line
        )
    }

    func testRenderingManyMessagesDoesNotRescanHistoryPerMessage() throws {
        try assertSubquadratic { count in
            let messages: [Encoding.Value] = [.object(["role": .string("user"), "content": .string("q")])]
                + Array(repeating: .object(["role": .string("assistant"), "content": .string("a")]), count: count)
            return try Encoding.encodeMessages(messages, thinkingMode: .chat).utf8.count
        }
    }

    func testMergingManyAdjacentMessagesDoesNotCopyGrowingBlocks() {
        assertSubquadratic { count in
            let messages: [Encoding.Value] = (0..<count).map { index in
                .object(["role": .string(index.isMultiple(of: 2) ? "user" : "tool"), "content": .string("x")])
            }
            return Encoding.mergeToolMessages(messages).first?["content_blocks"]?.array?.count ?? 0
        }
    }

    func testMergeKeepsTaskBoundariesMetadataAndBlockOrder() throws {
        let messages: [Encoding.Value] = [
            .object(["role": .string("user"), "content": .string("a"), "task": .string("action"), "mask": .bool(true)]),
            .object(["role": .string("tool"), "content": .string("b"), "tool_call_id": .string("call-b")]),
            .object(["role": .string("user"), "content": .string("c"), "wo_eos": .bool(true)]),
            .object(["role": .string("user"), "content": .string("d")]),
            .object(["role": .string("tool"), "content": .string("e"), "tool_call_id": .string("call-e")]),
            .object(["role": .string("assistant"), "content": .string("f")]),
        ]
        let merged = Encoding.mergeToolMessages(messages)
        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged[0]["task"], .string("action"))
        XCTAssertEqual(merged[0]["mask"], .bool(true))
        XCTAssertEqual(merged[1]["wo_eos"], .bool(true))
        let first = try XCTUnwrap(merged[0]["content_blocks"]?.array)
        let second = try XCTUnwrap(merged[1]["content_blocks"]?.array)
        XCTAssertEqual(first.map { $0["text"] ?? $0["content"] }, [.string("a"), .string("b")])
        XCTAssertEqual(second.map { $0["text"] ?? $0["content"] }, [.string("c"), .string("d"), .string("e")])
        XCTAssertEqual(first[1]["tool_use_id"], .string("call-b"))
        XCTAssertEqual(second[2]["tool_use_id"], .string("call-e"))
        XCTAssertEqual(merged[2], messages[5])
    }
}
