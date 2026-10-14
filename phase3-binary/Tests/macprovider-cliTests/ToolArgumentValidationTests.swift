import Foundation
import XCTest
@testable import macprovider_cli

final class ToolArgumentValidationTests: XCTestCase {
    func testFamilyArgumentAcceptanceCorpus() throws {
        let depth32 = "{\"v\":" + String(repeating: "[", count: 31) + "0" + String(repeating: "]", count: 31) + "}"
        let depth33 = "{\"v\":" + String(repeating: "[", count: 32) + "0" + String(repeating: "]", count: 32) + "}"
        let fixtures: [(String, String, Bool, Bool)] = [
            ("empty", "{}", true, true),
            ("nested containers", #"{"a":[{},[true,false,null],{"b":1}]}"#, true, true),
            ("escaped duplicate", #"{"a":1,"\u0061":2}"#, false, false),
            ("nested duplicate", #"{"a":[{"b":1,"b":2}]}"#, false, false),
            ("unicode", #"{"é":"👩🏽‍💻","emoji":"\uD83D\uDE00"}"#, true, true),
            ("escaped syntax", #"{"quote":"\\\"","slash":"\\","line":"\n"}"#, true, true),
            ("unescaped control", "{\"a\":\"line\nvalue\"}", false, false),
            ("unpaired low surrogate", #"{"a":"\uDC00"}"#, false, false),
            ("unpaired surrogate", #"{"a":"\uD800"}"#, false, false),
            ("canonical equivalent keys", #"{"é":1,"e\u0301":2}"#, false, false),
            ("numbers", #"{"a":[0,-0,1,-1,1.5,1e2,1E-2,1e+2]}"#, true, true),
            ("leading zero", #"{"a":01}"#, false, false),
            ("leading plus", #"{"a":+1}"#, false, false),
            ("missing fraction", #"{"a":1.}"#, false, false),
            ("missing exponent", #"{"a":1e}"#, false, false),
            ("JSON whitespace", "{\r\n\t\"a\" : [ true, null ] }", true, true),
            ("non-JSON whitespace", "{\u{00a0}\"a\":1}", false, false),
            ("combining key start", "{\"\u{0301}key\":1}", false, true),
            ("depth 32", depth32, true, true),
            ("depth 33", depth33, false, false),
        ]
        for (name, arguments, qwenAccepts, harmonyAccepts) in fixtures {
            let data = try JSONSerialization.data(withJSONObject: ["name": "lookup", "arguments": arguments])
            let raw = "<tool_call>" + String(decoding: data, as: UTF8.self) + "</tool_call>"
            let qwen = ToolCallParser.parseToolCalls(
                rawOutput: raw, modelID: "mlx-community/Qwen2.5-7B-Instruct-4bit", allowedFunctionNames: ["lookup"]
            )
            XCTAssertEqual(qwen.toolCalls.count == 1, qwenAccepts, "Qwen: \(name)")
            XCTAssertEqual(qwen.cleanedContent, qwenAccepts ? nil : raw, "Qwen fallback: \(name)")
            if qwenAccepts {
                XCTAssertEqual(qwen.toolCalls.first?.arguments, arguments, "Qwen bytes: \(name)")
            }
            let llama = ToolCallParser.parseToolCalls(
                rawOutput: "<|python_tag|>" + String(decoding: data, as: UTF8.self) + "<|eom_id|>",
                modelID: "mlx-community/Llama-3.3-70B-Instruct-4bit", allowedFunctionNames: ["lookup"]
            )
            XCTAssertEqual(llama.toolCalls.count == 1, qwenAccepts, "Llama: \(name)")
            let decoded = [91_001: "commentary to=functions.lookup", 91_002: arguments]
            let harmony = HarmonyResponseParser.parse(
                tokenIDs: [HarmonyResponseParser.channelTokenID, 91_001, HarmonyResponseParser.messageTokenID, 91_002, HarmonyResponseParser.callTokenID],
                decode: { $0.map { decoded[$0] ?? "" }.joined() },
                allowedFunctionNames: ["lookup"]
            )
            XCTAssertEqual(harmony.toolCalls.count == 1, harmonyAccepts, "Harmony: \(name)")
            XCTAssertEqual(harmony.failure, harmonyAccepts ? nil : .malformed, "Harmony failure: \(name)")
            if harmonyAccepts {
                XCTAssertEqual(harmony.toolCalls.first?.arguments, arguments, "Harmony bytes: \(name)")
            }
        }
    }
}
