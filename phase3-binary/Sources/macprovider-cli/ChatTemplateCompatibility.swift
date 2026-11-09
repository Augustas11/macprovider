import CryptoKit
import Foundation
import Hub
import MLXHuggingFace
import MLXLMCommon
import Tokenizers

/// Chat-template constructs the pinned swift-jinja (2.5.1) parser rejects but
/// Jinja2 accepts, rewritten before parsing into the form both engines read
/// identically. The artifact's own template bytes are never changed (they are
/// part of the hashed snapshot); only the string handed to the renderer is.
///
/// The first rewrite is numeric attribute access. Jinja2 parses `x.0` as the
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
///
/// The second removes message-tag scanning from one exact template, the
/// Solstice-AI uncensored GLM-5.3-Flash build's (SPEC-018 §3.14). That template
/// reads `[default]`, `[regular]`, `{REASON:`, `[MODE:` and `[L0]`..`[L10]` out of
/// every message, tool results included, so file contents could switch thinking
/// off, and it deletes some of those tags from the text. The rewrite is keyed on
/// the template's SHA-256, never on the model name. The `reasoning_effort`,
/// `enable_thinking`, `regular` and `mode` template variables keep working.
enum ChatTemplateCompatibility {
    struct Result: Equatable {
        let template: String
        let numericAttributeRewrites: Int
        var messageTagScanRemoved = false
        /// A template of this family whose bytes are not the reviewed ones.
        var messageTagScanKept = false
    }

    static let messageTagScanTemplateSHA256 = "1b927d9aaebbc9d98823db0bb746a199123724577f900fd62859b1de810e6d43"

    static func rewrite(_ template: String) -> Result {
        let scan = removingMessageTagScan(template)
        var result = rewriteNumericAttributes(scan.template ?? template)
        result.messageTagScanRemoved = scan.template != nil
        result.messageTagScanKept = scan.kept
        return result
    }

    /// The single `event=chat_template_compat` line for a loaded template, nil
    /// when nothing was rewritten and nothing needs a warning.
    static func logLine(_ result: Result) -> String? {
        var rewrites: [String] = []
        if result.numericAttributeRewrites > 0 { rewrites.append("numeric_attribute_access") }
        if result.messageTagScanRemoved { rewrites.append("message_tag_scan") }
        var fields = ["event=chat_template_compat"]
        if !rewrites.isEmpty {
            fields.append("rewrite=\(rewrites.joined(separator: ","))")
            fields.append("count=\(result.numericAttributeRewrites)")
        }
        if result.messageTagScanKept {
            fields.append("warning=message_tag_scan_kept reason=template_sha256_mismatch")
        }
        return fields.count > 1 ? fields.joined(separator: " ") + "\n" : nil
    }

    private static func removingMessageTagScan(_ template: String) -> (template: String?, kept: Bool) {
        let digest = SHA256.hash(data: Data(template.utf8)).map { String(format: "%02x", $0) }.joined()
        guard digest == messageTagScanTemplateSHA256 else {
            return (nil, template.contains("PROTIUM-1.0") && template.contains("{REASON:"))
        }
        var text = template
        let spans = [
            ("{%- for msg in messages %}\n    {%- if msg.content is string and ('[regular]'", "{%- endfor %}\n", ""),
            ("{%- for msg in messages -%}\n    {%- set txt = msg.content", "{%- endfor -%}\n{%- set target_mode", "{%- set target_mode"),
            ("{{- t | replace('[regular]', '')", "-}}", "{{- t -}}"),
        ]
        for (start, end, replacement) in spans {
            guard let lower = text.range(of: start),
                  let upper = text.range(of: end, range: lower.upperBound ..< text.endIndex)
            else { return (nil, true) }
            text.replaceSubrange(lower.lowerBound ..< upper.upperBound, with: replacement)
        }
        return (text, false)
    }

    static func rewriteNumericAttributes(_ template: String) -> Result {
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
/// does (`PreTrainedTokenizer` from the folder's `tokenizer_config.json`,
/// `tokenizer.json` and chat template). Prompts render through
/// `ChatTemplatePromptRenderer` (the same context and options, with the
/// `ChatTemplateCompatibility` rewrite) and encode through
/// `PromptControlTokenEncoder` (SPEC-018 §3.14); a DeepSeek-V4 artifact (no
/// template) renders through `DeepseekV4ChatTokenizer`.
struct ChatTemplateCompatTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        if DeepseekV4ChatTokenizer.applies(to: directory) {
            return try await DeepseekV4ChatTokenizer.load(from: directory)
        }
        let config = LanguageModelConfigurationFromHub(modelFolder: directory)
        guard let tokenizerConfig = try await config.tokenizerConfig else {
            throw Tokenizers.TokenizerError.missingConfig
        }
        let tokenizerData = try await config.tokenizerData
        let upstream = try PreTrainedTokenizer(tokenizerConfig: tokenizerConfig, tokenizerData: tokenizerData)
        let renderer = ChatTemplatePromptRenderer(tokenizerConfig: tokenizerConfig)
        if let line = renderer.compatibilityLogLine {
            FileHandle.standardError.write(Data(line.utf8))
        }
        let encoder = try PromptControlTokenEncoder(
            tokenizerConfig: tokenizerConfig,
            tokenizerData: tokenizerData,
            upstream: upstream,
            structuralSources: renderer.templateTexts
        )
        return ChatTemplateTokenizer(upstream: upstream, renderer: renderer, encoder: encoder)
    }
}

/// A Hugging Face tokenizer with a Jinja chat template, encoding prompts and
/// decoding output by control-token ID (SPEC-018 §3.14).
struct ChatTemplateTokenizer: MLXLMCommon.Tokenizer, ControlTokenAware {
    let upstream: PreTrainedTokenizer
    let renderer: ChatTemplatePromptRenderer
    let encoder: PromptControlTokenEncoder

    var controlTokens: ControlTokenTable? { encoder.control }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        ControlTextShield.decode(
            tokenIds: tokenIds,
            skipSpecialTokens: skipSpecialTokens,
            control: encoder.control
        ) { upstream.decode(tokens: $0, skipSpecialTokens: $1) }
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
        var input = try renderer.input(messages: messages, tools: tools, additionalContext: additionalContext)
        // Assistant history that carries its reasoning inline
        // (`<think>…</think>answer`) is split here, as templates that read
        // `reasoning_content` split it themselves, so the think markers come
        // from the template rather than from history text (SPEC-018 §3.14).
        // The split is used only when the template renders it to exactly the
        // text it renders for the inline form.
        if let split = ChatTemplatePromptRenderer.splittingInlineReasoning(messages) {
            let splitInput = try renderer.input(messages: split, tools: tools, additionalContext: additionalContext)
            if let original = try? renderer.render(input), let candidate = try? renderer.render(splitInput), original == candidate {
                input = splitInput
            }
        }
        return try encoder.encodePrompt(
            input, check: ChatTemplatePromptRenderer.check, sanitize: ChatTemplatePromptRenderer.sanitize, render: renderer.render)
    }
}
