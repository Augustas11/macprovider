#if DEBUG || MACPROVIDER_LAB_HARNESS
import Foundation
import XCTest
@testable import macprovider_cli

final class NativeMTPAcceptanceCorpusTests: XCTestCase {
    func testLoadsEveryRequestAndBindsOriginalBytes() throws {
        let data = try encode(fixture())
        let corpus = try NativeMTPAcceptanceCorpus.load(data: data)
        XCTAssertEqual(corpus.modelID, "zai-org/glm-5.3-flash")
        XCTAssertEqual(corpus.maxPromptTokens, 4096)
        XCTAssertEqual(corpus.qualifiedSlots, 4)
        XCTAssertEqual(corpus.maxNativeActiveRows, 1)
        XCTAssertEqual(corpus.proposalDepth, 1)
        XCTAssertEqual(corpus.minimumComparedPositions, 6400)
        XCTAssertEqual(corpus.cases.count, 200)
        XCTAssertEqual(corpus.cases.last?.request.requestID, "case-199")
        XCTAssertEqual(corpus.cases.last?.request.maxTokens, 64)
        XCTAssertEqual(corpus.digestSHA256.count, 64)
        XCTAssertEqual(corpus.digestSHA256, try NativeMTPAcceptanceCorpus.load(data: data).digestSHA256)
        XCTAssertNotEqual(corpus.digestSHA256, try NativeMTPAcceptanceCorpus.load(data: data + Data("\n".utf8)).digestSHA256)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: corpus.cases[0].rawRequestData) as? [String: Any])
        XCTAssertEqual(raw["model"] as? String, corpus.modelID)
        // Shape labels are declarations; loading never claims realized prompt
        // lengths, token parity, or an acceptance verdict.
        XCTAssertEqual(corpus.cases.filter { $0.stratum == .eightK && !$0.expectedNative }.count, 40)
    }

    func testPreservesProductionParsedToolsReasoningAndStop() throws {
        let object = changingRequest { request in
            request["tools"] = [["type": "function", "function": [
                "name": "read_file", "parameters": ["type": "object", "properties": [:]],
            ]]]
            request["reasoning_effort"] = "high"
            request["stop"] = ["END"]
            request["messages"] = [
                ["role": "user", "content": "Read the file."],
                ["role": "assistant", "content": "", "tool_calls": [[
                    "id": "call_acceptance0001", "type": "function",
                    "function": ["name": "read_file", "arguments": "{}"],
                ]]],
                ["role": "tool", "tool_call_id": "call_acceptance0001", "content": "hello"],
                ["role": "user", "content": "Explain the result."],
            ]
        }
        let corpus = try NativeMTPAcceptanceCorpus.load(data: encode(object))
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: corpus.cases.last!.rawRequestData) as? [String: Any])
        XCTAssertEqual(raw["reasoning_effort"] as? String, "high")
        XCTAssertEqual(raw["stop"] as? [String], ["END"])
        XCTAssertNotNil(raw["tools"])
    }

    func testRejectsMalformedLastRequestThroughProductionParser() throws {
        let object = changingRequest { $0["messages"] = [["role": "invalid", "content": "hello"]] }
        XCTAssertThrowsError(try NativeMTPAcceptanceCorpus.load(data: encode(object))) { error in
            XCTAssertTrue(String(describing: error).contains("case 199 rejected by production request parser"))
        }
    }

    func testRejectsSchemaMetadataAndCaseCountViolations() throws {
        for (field, value) in [
            ("schema", "unknown" as Any), ("model_id", ""),
            ("max_prompt_tokens", 8192), ("max_prompt_tokens", true),
            ("qualified_slots", 8), ("qualified_slots", "4"),
            ("max_native_active_rows", 2), ("proposal_depth", 0), ("proposal_depth", 3),
            ("proposal_depth", true), ("minimum_compared_positions", 6399),
            ("minimum_compared_positions", true), ("minimum_compared_positions", 102401),
            ("diagnostic_eligibility_bypass", false),
        ] {
            var object = fixture(); object[field] = value
            XCTAssertThrowsError(try NativeMTPAcceptanceCorpus.load(data: encode(object)), field)
        }
        var object = fixture(); object["minimum_compared_positions"] = nil
        XCTAssertThrowsError(try NativeMTPAcceptanceCorpus.load(data: encode(object)))
        for count in [199, 401] {
            var object = fixture(count: count)
            object["proposal_depth"] = 2
            XCTAssertThrowsError(try NativeMTPAcceptanceCorpus.load(data: encode(object)))
        }
        var depthTwo = fixture(); depthTwo["proposal_depth"] = 2
        XCTAssertEqual(try NativeMTPAcceptanceCorpus.load(data: encode(depthTwo)).proposalDepth, 2)
    }

    func testRejectsDuplicateIDsStrataAndFalseNativeClaims() throws {
        for change: (inout [[String: Any]]) -> Void in [
            { $0[199]["id"] = "case-0" },
            { $0[199]["id"] = 199 },
            { $0[199]["stratum"] = "8K" },
            { $0[199]["expected_native"] = 1 },
            { $0[199]["extra"] = true },
            { $0[3]["expected_native"] = true },
            { rows in for index in rows.indices { rows[index]["stratum"] = "short" } },
        ] {
            var object = fixture(); var rows = object["cases"] as! [[String: Any]]
            change(&rows); object["cases"] = rows
            XCTAssertThrowsError(try NativeMTPAcceptanceCorpus.load(data: encode(object)))
        }
        let impossible = changingRequest { $0["max_tokens"] = 1 }
        var rows = impossible["cases"] as! [[String: Any]]
        for index in rows.indices { rows[index]["expected_native"] = false }
        var object = impossible; object["cases"] = rows
        XCTAssertThrowsError(try NativeMTPAcceptanceCorpus.load(data: encode(object)))
    }

    func testRejectsRequestModelLimitsStreamAndBypass() throws {
        for change: (inout [String: Any]) -> Void in [
            { $0["model"] = "another-model" },
            { $0["max_tokens"] = 257 }, { $0["max_tokens"] = 0 }, { $0["max_tokens"] = nil },
            { $0["stream"] = true }, { $0["stream"] = 0 }, { $0["stream"] = nil },
            { $0["diagnostic_eligibility_bypass"] = true },
            { $0["diagnostic_eligibility_bypass"] = false },
        ] {
            XCTAssertThrowsError(try NativeMTPAcceptanceCorpus.load(data: encode(changingRequest(change))))
        }
    }

    func testRejectsDuplicateJSONKeysBeforeFoundationCanCollapseThem() throws {
        let data = try encode(fixture())
        let text = String(decoding: data, as: UTF8.self)
        let duplicate = text.replacingOccurrences(of: "\"proposal_depth\":1", with: "\"proposal_depth\":1,\"proposal_depth\":1")
        XCTAssertNotEqual(text, duplicate)
        XCTAssertThrowsError(try NativeMTPAcceptanceCorpus.load(data: Data(duplicate.utf8)))
    }

    private func encode(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func changingRequest(_ change: (inout [String: Any]) -> Void) -> [String: Any] {
        var object = fixture(); var rows = object["cases"] as! [[String: Any]]
        var request = rows[199]["request"] as! [String: Any]
        change(&request); rows[199]["request"] = request; object["cases"] = rows
        return object
    }

    private func fixture(count: Int = 200) -> [String: Any] {
        let strata = ["short", "1.5k", "4k", "8k", "near_boundary"]
        return [
            "schema": NativeMTPAcceptanceCorpus.schema, "model_id": "zai-org/glm-5.3-flash",
            "max_prompt_tokens": 4096, "qualified_slots": 4, "max_native_active_rows": 1,
            "proposal_depth": 1, "minimum_compared_positions": 6400,
            "cases": (0..<count).map { index -> [String: Any] in
                let stratum = strata[index % strata.count]
                return ["id": "case-\(index)", "stratum": stratum, "expected_native": stratum != "8k",
                        "request": ["model": "zai-org/glm-5.3-flash",
                                    "messages": [["role": "user", "content": "Describe a quiet harbor."]],
                                    "max_tokens": 64, "temperature": 1.0, "top_p": 0.95, "stream": false]]
            },
        ]
    }
}
#endif
