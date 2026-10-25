#if DEBUG || MACPROVIDER_LAB_HARNESS
import Foundation
import MacProviderCore
import MLXLMCommon

/// Tokenizer-only preregistration. Uses the same request renderer and default
/// message generator as the GLM lab fixture, without allocating model weights
/// or creating an MLX array. The frozen corpus is checked again at execution.
enum NativeMTPAcceptanceCorpusBuilder {
    static func make(targetDirectory: URL, modelID: String) async throws -> Data {
        guard modelID == "zai-org/glm-5.3-flash" else {
            throw NativeMTPHardwareE2EError.assertionFailed("acceptance corpus is GLM-specific")
        }
        let tokenizer = try await ChatTemplateCompatTokenizerLoader().load(from: targetDirectory)
        var cases: [[String: Any]] = []
        for stratum in NativeMTPAcceptanceCorpus.Stratum.allCases {
            let target: Int
            switch stratum {
            case .short: target = 256
            case .onePointFiveK: target = 1536
            case .fourK, .nearBoundary: target = 4072
            case .eightK: target = 8192
            }
            let count = stratum == .short ? 120 : 20
            for offset in 0..<count {
                let index = cases.count
                func object(_ padding: Int) -> [String: Any] {
                    requestObject(modelID: modelID, index: index, padding: padding)
                }
                let (padding, count) = try await NativeMTPBenchPrompts.fewestReachingSalts(target: target) { padding in
                    let request = try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: object(padding)))
                    let input = try ModelRuntime.userInput(for: request)
                    return try tokenizer.applyChatTemplate(
                        messages: DefaultMessageGenerator().generate(from: input),
                        tools: input.tools, additionalContext: input.additionalContext
                    ).count
                }
                guard contains(count, stratum: stratum) else {
                    throw NativeMTPHardwareE2EError.assertionFailed("acceptance prompt outside preregistered stratum")
                }
                cases.append([
                    "id": "acceptance-\(stratum.rawValue)-\(offset)",
                    "stratum": stratum.rawValue,
                    "expected_native": stratum != .eightK,
                    "request": object(padding),
                ])
            }
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "schema": NativeMTPAcceptanceCorpus.schema,
            "model_id": modelID,
            "max_prompt_tokens": 4096,
            "qualified_slots": 4,
            "max_native_active_rows": 1,
            "proposal_depth": 1,
            "minimum_compared_positions": 6400,
            "cases": cases,
        ], options: [.sortedKeys])
        _ = try NativeMTPAcceptanceCorpus.load(data: data)
        return data
    }

    static func contains(_ tokens: Int, stratum: NativeMTPAcceptanceCorpus.Stratum) -> Bool {
        switch stratum {
        case .short: (1...512).contains(tokens)
        case .onePointFiveK: (1505...1566).contains(tokens)
        case .fourK: (4015...4096).contains(tokens)
        case .eightK: (8029...8355).contains(tokens)
        case .nearBoundary: (4032...4096).contains(tokens)
        }
    }

    static func requestObject(modelID: String, index: Int, padding: Int) -> [String: Any] {
        let tools = index % 3 != 0
        let sampled = index % 3 != 1
        let context = "Acceptance fixture \(index). Context:" + String(repeating: " x", count: padding)
        let instruction: String
        if tools {
            instruction = "Use minimal reasoning, then immediately call read_file for settings.json. The earlier file does not contain the answer."
        } else if index % 19 == 0 {
            instruction = "Answer with only OK."
        } else if index % 20 == 0 {
            instruction = "Amber and violet are equally valid. Choose either, then list 100 distinct short observations about that color."
        } else {
            instruction = "List 100 distinct short practical observations about a harbor, separated by semicolons. Continue until all 100 are listed."
        }
        let prompt = context + "\n\n" + instruction
        var object: [String: Any] = [
            "model": modelID,
            "messages": [["role": "user", "content": prompt]],
            "max_tokens": 128,
            "temperature": sampled ? 1.0 : 0.0,
            "top_p": sampled ? 0.95 : 1.0,
            "stream": false,
        ]
        if tools {
            object["tools"] = [["type": "function", "function": [
                "name": "read_file", "description": "Read a project file.",
                "parameters": ["type": "object", "properties": ["path": ["type": "string"]], "required": ["path"]],
            ]]]
            object["messages"] = [
                ["role": "user", "content": "Read main.swift before answering."],
                ["role": "assistant", "content": "", "reasoning_content": "I need to inspect the source first.", "tool_calls": [[
                    "id": "call_acceptancecase0001", "type": "function", "function": ["name": "read_file", "arguments": "{\"path\":\"main.swift\"}"],
                ]]],
                ["role": "tool", "tool_call_id": "call_acceptancecase0001", "content": "func main() { print(42) }"],
                ["role": "user", "content": prompt],
            ]
            object["reasoning_effort"] = "high"
        } else if index % 17 == 0 {
            object["stop"] = [";"]
        }
        return object
    }
}
#endif
