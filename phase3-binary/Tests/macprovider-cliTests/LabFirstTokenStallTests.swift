#if DEBUG || MACPROVIDER_LAB_HARNESS
import XCTest
@testable import macprovider_cli

final class LabFirstTokenStallTests: XCTestCase {
    private let key = "MACPROVIDER_LAB_FIRST_TOKEN_STALL_ARM"
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func arm(_ text: String) throws -> [String: String] {
        let url = dir.appendingPathComponent("arm")
        try Data(text.utf8).write(to: url)
        return [key: url.path]
    }

    func testUnsetRelativeAndMissingAreNoOp() {
        XCTAssertNil(LabFirstTokenStall.consume(environment: [:]))
        XCTAssertNil(LabFirstTokenStall.consume(environment: [key: ""]))
        XCTAssertNil(LabFirstTokenStall.consume(environment: [key: "relative/arm"]))
        XCTAssertNil(LabFirstTokenStall.consume(environment: [key: dir.appendingPathComponent("none").path]))
    }

    func testArmedFileHoldsOneRequestAndIsRemoved() throws {
        let env = try arm(" 150\n")
        XCTAssertEqual(LabFirstTokenStall.consume(environment: env), 150)
        XCTAssertFalse(FileManager.default.fileExists(atPath: env[key]!))
        XCTAssertNil(LabFirstTokenStall.consume(environment: env))
    }

    func testInvalidValuesDisarmWithoutHolding() throws {
        for raw in ["", "abc", "0", "-5", "nan", "inf", "901"] {
            let env = try arm(raw)
            XCTAssertNil(LabFirstTokenStall.consume(environment: env), raw)
            XCTAssertFalse(FileManager.default.fileExists(atPath: env[key]!), raw)
        }
    }

    func testMaximumIsAccepted() throws {
        XCTAssertEqual(LabFirstTokenStall.consume(environment: try arm("900")), 900)
    }
}
#endif
