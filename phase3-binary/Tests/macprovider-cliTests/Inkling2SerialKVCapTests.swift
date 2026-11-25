import Foundation
@testable import macprovider_cli
import XCTest

/// Inkling 2 sizes its own per-visit caches (`CacheList` of a sliding window or
/// `KVCacheSimple`, plus a convolution tail) and ignores `maxKVSize`. With the
/// serve cap set, mlx-swift-lm rejected every global-attention leaf
/// (`incompatibleCapacity(expected: 120000, count: 8)`), so serial chat failed.
final class Inkling2SerialKVCapTests: XCTestCase {
    func testInklingIsAModelThatSizesItsOwnKVCache() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/macprovider-cli/ModelRuntime.swift"),
            encoding: .utf8)
        guard let start = source.range(of: "static func modelSizesItsOwnKVCache("),
              let end = source.range(of: "\n    }", range: start.upperBound ..< source.endIndex)
        else { return XCTFail("modelSizesItsOwnKVCache not found") }
        XCTAssertTrue(source[start.lowerBound ..< end.lowerBound].contains("model is Inkling2Model"))
    }
}
