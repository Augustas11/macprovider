import Foundation
import MacProviderCore

struct ToolCall: Equatable, Sendable {
    let id: String
    let functionName: String
    let arguments: String

    init(id: String, functionName: String, arguments: String) {
        self.id = id
        self.functionName = functionName
        self.arguments = arguments
    }
}

extension ToolCall {
    var openAIObject: [String: Any] {
        [
            "id": id,
            "type": "function",
            "function": [
                "name": functionName,
                "arguments": arguments,
            ],
        ]
    }

    func openAIInitialDelta(index: Int) -> [String: Any] {
        [
            "index": index,
            "id": id,
            "type": "function",
            "function": [
                "name": functionName,
                "arguments": "",
            ],
        ]
    }

    func openAIArgumentsDelta(index: Int, fragment: String) -> [String: Any] {
        [
            "index": index,
            "function": [
                "arguments": fragment,
            ],
        ]
    }
}

enum OutputCanonicalizer {
    static let allowedFinishReasons: Set<String> = [
        "stop",
        "length",
        "tool_calls",
        "content_filter",
        "error",
    ]

    static func canonicalOutputObject(
        content: String,
        toolCalls: [ToolCall]?,
        finishReason: String
    ) throws -> RFC8785JCS.Value {
        guard allowedFinishReasons.contains(finishReason) else {
            throw Error.invalidFinishReason(finishReason)
        }
        return .object([
            "content": .string(PromptCanonicalizer.normalizeLineEndings(content)),
            "tool_calls": canonicalToolCalls(toolCalls),
            "finish_reason": .string(finishReason),
        ])
    }

    static func outputHash(
        content: String,
        toolCalls: [ToolCall]?,
        finishReason: String
    ) throws -> String {
        try RFC8785JCS.sha256Hex(of: canonicalOutputObject(
            content: content,
            toolCalls: toolCalls,
            finishReason: finishReason
        ))
    }

    private static func canonicalToolCalls(_ toolCalls: [ToolCall]?) -> RFC8785JCS.Value {
        guard let toolCalls else { return .null }
        return .array(toolCalls.map { call in
            .object([
                "id": .string(call.id),
                "type": .string("function"),
                "function": .object([
                    "name": .string(call.functionName),
                    "arguments": .rawString(call.arguments),
                ]),
            ])
        })
    }

    enum Error: Swift.Error, Equatable {
        case invalidFinishReason(String)
    }
}
