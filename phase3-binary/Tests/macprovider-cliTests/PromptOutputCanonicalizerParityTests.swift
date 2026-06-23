import Foundation
import XCTest
@testable import macprovider_cli

final class PromptOutputCanonicalizerParityTests: XCTestCase {
    func testSharedCanonFixturesMatchSwiftCanonicalizers() throws {
        if ProcessInfo.processInfo.environment["REGENERATE_CANON_FIXTURES"] == "1" {
            return
        }

        let fixtures = try loadFixtures()
        for fixture in fixtures.prompt {
            let request = try parseRequest(fixture.request)
            let canonical = try RFC8785JCS.canonicalString(PromptCanonicalizer.canonicalPromptObject(for: request))
            XCTAssertEqual(Data(canonical.utf8).base64EncodedString(), fixture.expectedCanonicalB64, "Prompt fixture \(fixture.id) canonical drifted")
            XCTAssertEqual(try PromptCanonicalizer.promptHash(for: request), fixture.expectedHashHex, "Prompt fixture \(fixture.id) hash drifted")
        }

        for fixture in fixtures.output {
            let output = try Self.outputSource(from: fixture.response)
            let canonical = try RFC8785JCS.canonicalString(OutputCanonicalizer.canonicalOutputObject(
                content: output.content,
                toolCalls: output.toolCalls,
                finishReason: output.finishReason
            ))
            XCTAssertEqual(Data(canonical.utf8).base64EncodedString(), fixture.expectedCanonicalB64, "Output fixture \(fixture.id) canonical drifted")
            XCTAssertEqual(
                try OutputCanonicalizer.outputHash(content: output.content, toolCalls: output.toolCalls, finishReason: output.finishReason),
                fixture.expectedHashHex,
                "Output fixture \(fixture.id) hash drifted"
            )
        }
    }

    func testRegenerateSharedCanonFixturesWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["REGENERATE_CANON_FIXTURES"] == "1" else {
            return
        }

        let url = Self.fixtureURL()
        let data = try Data(contentsOf: url)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var prompt = root["prompt"] as? [[String: Any]],
              var output = root["output"] as? [[String: Any]] else {
            XCTFail("Expected top-level prompt/output fixture arrays")
            return
        }

        for index in prompt.indices {
            guard let request = prompt[index]["request"] as? [String: Any] else {
                XCTFail("Prompt fixture \(index) missing request")
                return
            }
            let parsed = try parseRequest(request)
            let canonical = try RFC8785JCS.canonicalString(PromptCanonicalizer.canonicalPromptObject(for: parsed))
            prompt[index]["expected_canonical_b64"] = Data(canonical.utf8).base64EncodedString()
            prompt[index]["expected_hash_hex"] = try PromptCanonicalizer.promptHash(for: parsed)
        }

        for index in output.indices {
            guard let response = output[index]["response"] as? [String: Any] else {
                XCTFail("Output fixture \(index) missing response")
                return
            }
            let source = try Self.outputSource(from: response)
            let canonical = try RFC8785JCS.canonicalString(OutputCanonicalizer.canonicalOutputObject(
                content: source.content,
                toolCalls: source.toolCalls,
                finishReason: source.finishReason
            ))
            output[index]["expected_canonical_b64"] = Data(canonical.utf8).base64EncodedString()
            output[index]["expected_hash_hex"] = try OutputCanonicalizer.outputHash(
                content: source.content,
                toolCalls: source.toolCalls,
                finishReason: source.finishReason
            )
        }

        root["prompt"] = prompt
        root["output"] = output

        let regenerated = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try regenerated.write(to: url)
    }

    private struct CanonFixtures {
        let prompt: [PromptFixture]
        let output: [OutputFixture]
    }

    private struct PromptFixture {
        let id: String
        let request: [String: Any]
        let expectedCanonicalB64: String
        let expectedHashHex: String
    }

    private struct OutputFixture {
        let id: String
        let response: [String: Any]
        let expectedCanonicalB64: String
        let expectedHashHex: String
    }

    private struct OutputSource {
        let content: String
        let toolCalls: [ToolCall]?
        let finishReason: String
    }

    private func loadFixtures() throws -> CanonFixtures {
        let data = try Data(contentsOf: Self.fixtureURL())
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let prompt = root["prompt"] as? [[String: Any]],
              let output = root["output"] as? [[String: Any]] else {
            throw FixtureError.invalidShape("expected prompt/output arrays")
        }
        return CanonFixtures(
            prompt: try prompt.map(Self.promptFixture),
            output: try output.map(Self.outputFixture)
        )
    }

    private static func promptFixture(_ raw: [String: Any]) throws -> PromptFixture {
        guard let id = raw["id"] as? String,
              let request = raw["request"] as? [String: Any],
              let expectedCanonicalB64 = raw["expected_canonical_b64"] as? String,
              let expectedHashHex = raw["expected_hash_hex"] as? String else {
            throw FixtureError.invalidShape("invalid prompt fixture")
        }
        return PromptFixture(id: id, request: request, expectedCanonicalB64: expectedCanonicalB64, expectedHashHex: expectedHashHex)
    }

    private static func outputFixture(_ raw: [String: Any]) throws -> OutputFixture {
        guard let id = raw["id"] as? String,
              let response = raw["response"] as? [String: Any],
              let expectedCanonicalB64 = raw["expected_canonical_b64"] as? String,
              let expectedHashHex = raw["expected_hash_hex"] as? String else {
            throw FixtureError.invalidShape("invalid output fixture")
        }
        return OutputFixture(id: id, response: response, expectedCanonicalB64: expectedCanonicalB64, expectedHashHex: expectedHashHex)
    }

    private static func outputSource(from response: [String: Any]) throws -> OutputSource {
        guard let choices = response["choices"] as? [Any], let first = choices.first as? [String: Any] else {
            throw FixtureError.invalidShape("response.choices missing")
        }
        guard let message = first["message"] as? [String: Any] else {
            throw FixtureError.invalidShape("response.choices[0].message missing")
        }
        guard let finishReason = first["finish_reason"] as? String else {
            throw FixtureError.invalidShape("response.choices[0].finish_reason missing")
        }

        let content: String
        if let rawContent = message["content"], !(rawContent is NSNull) {
            guard let string = rawContent as? String else {
                throw FixtureError.invalidShape("response content must be string/null/missing")
            }
            content = string
        } else {
            content = ""
        }

        var toolCalls: [ToolCall]?
        if let rawToolCalls = message["tool_calls"], !(rawToolCalls is NSNull) {
            guard let calls = rawToolCalls as? [[String: Any]] else {
                throw FixtureError.invalidShape("tool_calls must be array")
            }
            toolCalls = try calls.map { call in
                guard let id = call["id"] as? String,
                      let function = call["function"] as? [String: Any],
                      let name = function["name"] as? String,
                      let arguments = function["arguments"] as? String else {
                    throw FixtureError.invalidShape("invalid tool call")
                }
                return ToolCall(id: id, functionName: name, arguments: arguments)
            }
        }

        return OutputSource(content: content, toolCalls: toolCalls, finishReason: finishReason)
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
            .appendingPathComponent("canon_fixtures.json")
    }

    private enum FixtureError: Error {
        case invalidShape(String)
    }
}
