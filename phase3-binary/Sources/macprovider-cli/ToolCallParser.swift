import Foundation

enum ToolCallParser {
    static func parseToolCalls(
        rawOutput: String,
        modelID: String,
        allowedFunctionNames: Set<String>? = nil
    ) -> (cleanedContent: String?, toolCalls: [ToolCall]) {
        let format = ToolCallFormat.detect(modelID: modelID, rawOutput: rawOutput)
        guard let format else {
            return (nilIfBlank(rawOutput), [])
        }

        do {
            let parsed = try parseDelimited(rawOutput, format: format)
            if let allowedFunctionNames,
               parsed.toolCalls.contains(where: { !allowedFunctionNames.contains($0.functionName) })
            {
                fputs("warning: tool-call output contains undeclared function for \(modelID)\n", stderr)
                return (nilIfBlank(rawOutput), [])
            }
            return parsed
        } catch {
            fputs("warning: malformed tool-call output for \(modelID): \(error)\n", stderr)
            return (nilIfBlank(rawOutput), [])
        }
    }

    private static func parseDelimited(_ rawOutput: String, format: ToolCallFormat) throws -> (cleanedContent: String?, toolCalls: [ToolCall]) {
        var searchStart = rawOutput.startIndex
        var cleaned = ""
        var calls: [ToolCall] = []

        while let startRange = rawOutput.range(of: format.startDelimiter, range: searchStart..<rawOutput.endIndex) {
            cleaned += rawOutput[searchStart..<startRange.lowerBound]
            let bodyStart = startRange.upperBound
            guard let endRange = rawOutput.range(of: format.endDelimiter, range: bodyStart..<rawOutput.endIndex) else {
                throw ParseError.missingEndDelimiter
            }
            let body = String(rawOutput[bodyStart..<endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            calls.append(try parseCall(body, argumentKey: format.argumentKey))
            searchStart = endRange.upperBound
        }

        cleaned += rawOutput[searchStart..<rawOutput.endIndex]
        guard !calls.isEmpty else {
            return (nilIfBlank(rawOutput), [])
        }
        return (nilIfBlank(cleaned), calls)
    }

    private static func parseCall(_ rawJSON: String, argumentKey: String) throws -> ToolCall {
        guard let data = rawJSON.data(using: .utf8) else {
            throw ParseError.invalidUTF8
        }
        let parsed = try JSONSerialization.jsonObject(with: data)
        guard let object = parsed as? [String: Any],
              let name = object["name"] as? String,
              !name.isEmpty
        else {
            throw ParseError.invalidShape
        }

        let rawArguments = object[argumentKey] ?? object["arguments"] ?? object["parameters"]
        let arguments = try argumentsString(rawArguments)
        return ToolCall(id: "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())", functionName: name, arguments: arguments)
    }

    private static func argumentsString(_ rawArguments: Any?) throws -> String {
        guard let rawArguments else {
            return "{}"
        }
        if rawArguments is NSNull {
            throw ParseError.invalidArguments
        }
        if let string = rawArguments as? String {
            guard string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                return "{}"
            }
            guard let data = string.data(using: .utf8),
                  try JSONSerialization.jsonObject(with: data) is [String: Any]
            else {
                throw ParseError.invalidArguments
            }
            return string
        }
        guard let argumentObject = rawArguments as? [String: Any],
              JSONSerialization.isValidJSONObject(argumentObject)
        else {
            throw ParseError.invalidArguments
        }
        let data = try JSONSerialization.data(withJSONObject: argumentObject, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private static func nilIfBlank(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private enum ParseError: Error {
        case missingEndDelimiter
        case invalidUTF8
        case invalidShape
        case invalidArguments
    }
}

private enum ToolCallFormat {
    case qwen25
    case llama33

    var startDelimiter: String {
        switch self {
        case .qwen25:
            return "<tool_call>"
        case .llama33:
            return "<|python_tag|>"
        }
    }

    var endDelimiter: String {
        switch self {
        case .qwen25:
            return "</tool_call>"
        case .llama33:
            return "<|eom_id|>"
        }
    }

    var argumentKey: String {
        switch self {
        case .qwen25:
            return "arguments"
        case .llama33:
            return "parameters"
        }
    }

    static func detect(modelID: String, rawOutput: String) -> ToolCallFormat? {
        if modelID.localizedCaseInsensitiveContains("llama-3.3") || rawOutput.contains("<|python_tag|>") {
            return .llama33
        }
        if modelID.localizedCaseInsensitiveContains("qwen2.5") || rawOutput.contains("<tool_call>") {
            return .qwen25
        }
        return nil
    }
}
