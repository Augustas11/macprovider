import Foundation
import MLXHuggingFace
import MLXLMCommon
import Tokenizers

/// Chat-template constructs the pinned swift-jinja (2.5.1) parser rejects but
/// Jinja2 accepts, rewritten before parsing into the form both engines read
/// identically. The artifact's own template bytes are never changed (they are
/// part of the hashed snapshot); only the string handed to the renderer is.
///
/// One rewrite exists: numeric attribute access. Jinja2 parses `x.0` as the
/// subscript `x[0]` (`Getitem(x, Const(0))`, the same node `x[0]` produces),
/// while swift-jinja's parser expects an identifier after `.` and throws
/// "Expected identifier but found number." GLM-5.3-Flash's template uses
/// `m.content.0.type`, `tr.output.0.type`, `entry.output.0.type` and
/// `m.content.0.output`.
///
/// The rewrite is exact and narrow: inside `{{ }}` / `{% %}` only, outside
/// string literals, a `.` followed by an integer is rewritten to `[<integer>]`
/// only when the `.` follows an identifier, `]` or `)`. Template text, string
/// literals and float literals (`1.5`) are untouched. A template the pinned
/// parser already accepts can contain no such access, so this changes nothing
/// for any template that renders today.
enum ChatTemplateCompatibility {
    struct Result: Equatable {
        let template: String
        let numericAttributeRewrites: Int
    }

    static func rewrite(_ template: String) -> Result {
        let chars = Array(template)
        var out = String()
        out.reserveCapacity(template.utf8.count + 16)
        var index = 0
        var rewrites = 0
        var inTag = false
        var quote: Character?

        func isIdentifierChar(_ c: Character) -> Bool { c == "_" || c.isASCIILetter || c.isASCIIDigit }

        /// Whether the `.` at `dot` follows an identifier, `]` or `)`.
        func followsAccessTarget(_ dot: Int) -> Bool {
            guard dot > 0 else { return false }
            let previous = chars[dot - 1]
            if previous == "]" || previous == ")" { return true }
            guard isIdentifierChar(previous) else { return false }
            var start = dot - 1
            while start > 0, isIdentifierChar(chars[start - 1]) { start -= 1 }
            // A run starting with a digit is a number literal (`1.5`).
            return !chars[start].isASCIIDigit
        }

        while index < chars.count {
            let c = chars[index]
            if !inTag {
                if c == "{", index + 1 < chars.count, chars[index + 1] == "%" || chars[index + 1] == "{" {
                    inTag = true
                    out.append(c)
                    out.append(chars[index + 1])
                    index += 2
                } else {
                    out.append(c)
                    index += 1
                }
                continue
            }
            if let open = quote {
                out.append(c)
                if c == "\\", index + 1 < chars.count {
                    out.append(chars[index + 1])
                    index += 2
                    continue
                }
                if c == open { quote = nil }
                index += 1
                continue
            }
            if c == "'" || c == "\"" {
                quote = c
                out.append(c)
                index += 1
                continue
            }
            if c == "%" || c == "}", index + 1 < chars.count, chars[index + 1] == "}" {
                inTag = false
                out.append(c)
                out.append("}")
                index += 2
                continue
            }
            if c == ".", index + 1 < chars.count, chars[index + 1].isASCIIDigit, followsAccessTarget(index) {
                var end = index + 1
                while end < chars.count, chars[end].isASCIIDigit { end += 1 }
                // `x.0abc` is not an integer access; leave it to the parser.
                if end == chars.count || !isIdentifierChar(chars[end]) {
                    out.append("[")
                    out.append(contentsOf: chars[(index + 1) ..< end])
                    out.append("]")
                    rewrites += 1
                    index = end
                    continue
                }
            }
            out.append(c)
            index += 1
        }
        return Result(template: out, numericAttributeRewrites: rewrites)
    }

    /// The template swift-transformers would select for a plain chat request:
    /// `chat_template.jinja` when present, else a string `chat_template` in
    /// `tokenizer_config.json`. Named template lists are left alone.
    static func configuredTemplate(in directory: URL) -> String? {
        let jinja = directory.appendingPathComponent("chat_template.jinja")
        if let data = try? Data(contentsOf: jinja), let text = String(data: data, encoding: .utf8) {
            return text
        }
        let config = directory.appendingPathComponent("tokenizer_config.json")
        guard let data = try? Data(contentsOf: config),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["chat_template"] as? String
    }
}

private extension Character {
    var isASCIILetter: Bool { isASCII && isLetter }
    var isASCIIDigit: Bool { isASCII && isNumber }
}

/// Loads the swift-transformers tokenizer as `#huggingFaceTokenizerLoader()`
/// does. When the configured chat template needs a `ChatTemplateCompatibility`
/// rewrite, the returned tokenizer renders the rewritten template as a literal
/// through the same swift-transformers path (same context, same
/// `lstripBlocks`/`trimBlocks` options, `add_generation_prompt` true);
/// a DeepSeek-V4 artifact (no template) renders through
/// `DeepseekV4ChatTokenizer`; otherwise it is the stock adaptor, unchanged.
struct ChatTemplateCompatTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await Tokenizers.AutoTokenizer.from(modelFolder: directory)
        if DeepseekV4ChatTokenizer.applies(to: directory) {
            return DeepseekV4ChatTokenizer(upstream: upstream)
        }
        if let template = ChatTemplateCompatibility.configuredTemplate(in: directory) {
            let result = ChatTemplateCompatibility.rewrite(template)
            if result.numericAttributeRewrites > 0 {
                FileHandle.standardError.write(Data(
                    "event=chat_template_compat rewrite=numeric_attribute_access count=\(result.numericAttributeRewrites)\n".utf8
                ))
                return LiteralChatTemplateTokenizer(upstream: upstream, template: result.template)
            }
        }
        return #adaptHuggingFaceTokenizer(upstream)
    }
}

/// The stock adaptor's behaviour with a literal chat template.
struct LiteralChatTemplateTokenizer: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer
    let template: String

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages,
                chatTemplate: .literal(template),
                addGenerationPrompt: true,
                truncation: false,
                maxLength: nil,
                tools: tools,
                additionalContext: additionalContext
            )
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
