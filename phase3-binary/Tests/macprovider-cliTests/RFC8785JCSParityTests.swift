import Foundation
import XCTest
@testable import macprovider_cli

final class RFC8785JCSParityTests: XCTestCase {
    func testSharedParityFixturesMatchSwiftCanonicalizer() throws {
        let fixtures = try loadFixtures()

        for fixture in fixtures {
            let value = try Self.jcsValue(from: fixture.input)
            let canonical = try RFC8785JCS.canonicalString(value)
            let actual = Data(canonical.utf8).base64EncodedString()

            XCTAssertFalse(
                fixture.expectedCanonicalB64.isEmpty,
                "Fixture \(fixture.id) has no expected canonical bytes; regenerate jcs_parity.json"
            )
            XCTAssertEqual(actual, fixture.expectedCanonicalB64, "Fixture \(fixture.id) drifted")
        }
    }

    func testRegenerateSharedParityFixturesWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["REGENERATE_JCS_PARITY"] == "1" else {
            return
        }

        let url = Self.fixtureURL()
        let data = try Data(contentsOf: url)
        guard var entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            XCTFail("Expected top-level fixture array")
            return
        }

        for index in entries.indices {
            guard let input = entries[index]["input"] else {
                XCTFail("Fixture at index \(index) is missing input")
                return
            }
            let value = try Self.jcsValue(from: input)
            let canonical = try RFC8785JCS.canonicalString(value)
            entries[index]["expected_canonical_b64"] = Data(canonical.utf8).base64EncodedString()
        }

        let output = try JSONSerialization.data(
            withJSONObject: entries,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try output.write(to: url)
    }

    private struct Fixture {
        let id: String
        let input: Any
        let expectedCanonicalB64: String
    }

    private func loadFixtures() throws -> [Fixture] {
        let data = try Data(contentsOf: Self.fixtureURL())
        guard let rawFixtures = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            XCTFail("Expected top-level fixture array")
            return []
        }

        return try rawFixtures.map { raw in
            guard let id = raw["id"] as? String else {
                throw FixtureError.invalidShape("missing id")
            }
            guard let input = raw["input"] else {
                throw FixtureError.invalidShape("missing input for \(id)")
            }
            guard let expected = raw["expected_canonical_b64"] as? String else {
                throw FixtureError.invalidShape("missing expected_canonical_b64 for \(id)")
            }
            return Fixture(id: id, input: input, expectedCanonicalB64: expected)
        }
    }

    private static func fixtureURL() -> URL {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return repoRoot
            .appendingPathComponent("phase7-verify")
            .appendingPathComponent("testdata")
            .appendingPathComponent("jcs_parity.json")
    }

    private static func jcsValue(from input: Any) throws -> RFC8785JCS.Value {
        if let object = input as? [String: Any] {
            var members: [String: RFC8785JCS.Value] = [:]
            for (key, value) in object {
                members[key] = try jcsValue(from: value)
            }
            return .object(members)
        }

        if let array = input as? [Any] {
            return .array(try array.map { try jcsValue(from: $0) })
        }

        if let string = input as? String {
            return .string(string)
        }

        if input is NSNull {
            return .null
        }

        if let number = input as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }

            let type = String(cString: number.objCType)
            if type == "d" || type == "f" {
                return .double(number.doubleValue)
            }

            let int64 = number.int64Value
            guard let int = Int(exactly: int64) else {
                throw FixtureError.invalidShape("integer \(number) does not fit Swift Int")
            }
            return .int(int)
        }

        throw FixtureError.invalidShape("unsupported JSON value \(type(of: input))")
    }

    private enum FixtureError: Error {
        case invalidShape(String)
    }
}
