import Foundation
import MacProviderCore
import XCTest

/// The Swift copy of the SPEC-018 §3.1 family rule against the shared
/// cross-language fixture (`testdata/tool-grammar-families.json`, #2355). The
/// Go coordinator, the gateway and the buyer-UX suite assert the same cases.
final class ToolGrammarFamilyFixtureTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Case: Decodable {
            let model: String
            let family: String
        }

        let schema: String
        let cases: [Case]
    }

    private static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("testdata/tool-grammar-families.json")

    func testFamilyMatchesTheSharedFixture() throws {
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: Self.fixture))
        XCTAssertEqual(fixture.schema, "macprovider.tool-grammar-families.v1")
        XCTAssertFalse(fixture.cases.isEmpty)
        var covered = Set<String>()
        for item in fixture.cases {
            XCTAssertEqual(ToolCallGrammar.family(modelID: item.model)?.rawValue ?? "", item.family, item.model)
            covered.insert(item.family)
        }
        // Every family the provider parses has at least one fixture case.
        for grammar in ToolCallGrammar.allCases {
            XCTAssertTrue(covered.contains(grammar.rawValue), "no fixture case for \(grammar.rawValue)")
        }
    }
}
