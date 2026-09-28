// NativeMTPUpstreamQualificationTests.swift
// SPEC-048 Phase 0: keep the pinned upstream MTP surface explicit.

import MLX
import MLXLMCommon
import XCTest

final class NativeMTPUpstreamQualificationTests: XCTestCase {
    func testPinnedReleaseExposesSerialMTPSymbols() {
        let drafterProtocol: Any.Type = (any MTPDrafterModel).self
        let iteratorType: Any.Type = MTPSpeculativeTokenIterator.self
        let factoryType: Any.Type = MTPDrafterModelFactory.self

        XCTAssertNotNil(drafterProtocol)
        XCTAssertNotNil(iteratorType)
        XCTAssertNotNil(factoryType)
    }

    func testPinnedMLXExposesMXFP8QuantizationMode() {
        XCTAssertEqual(QuantizationMode.mxfp8.rawValue, "mxfp8")
    }
}
