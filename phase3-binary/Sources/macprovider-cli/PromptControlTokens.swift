import Foundation
import Hub
import Jinja
import MLXLMCommon
import MacProviderCore
import Tokenizers

// SPEC-018 §3.14: control tokens enter a prompt only where the chat template
// itself writes them, and they leave the output only as the token IDs the
// model sampled. Request text never becomes a control token, and text the
// model writes with ordinary tokens never acts as one.

/// The added tokens that carry prompt and output structure for one tokenizer:
/// every special added token, plus each non-special added token the chat
/// template writes or an output parser reads (for example `<think>` and
/// `<tool_call>`, which several families mark non-special).
struct ControlTokenTable: Sendable, Equatable {
    struct AddedToken: Sendable, Equatable {
        let content: String
        let id: Int
        let special: Bool
        let lstrip: Bool
        let rstrip: Bool
    }

    /// Markers the output parsers read as text (`ReasoningOutput`,
    /// `ToolCallParser`, the DSML reader). They are control tokens whenever
    /// the tokenizer defines them as added tokens.
    static let parserMarkers: Set<String> = [
        "<think>", "</think>",
        "<tool_call>", "</tool_call>", "<tool_response>", "</tool_response>",
        "<arg_key>", "</arg_key>", "<arg_value>", "</arg_value>",
        "<|tool_call>", "<tool_call|>",
        "｜DSML｜",
    ]

    let idsByText: [String: Int]
    let textsByID: [Int: String]
    let ids: Set<Int>
    /// Every special added token (control or not), for `skipSpecialTokens`.
    let specialIDs: Set<Int>
    let matcher: ControlTextMatcher

    init(addedTokens: [AddedToken], structuralSources: [String]) {
        var map: [String: Int] = [:]
        for token in addedTokens {
            let text = token.content
            // A whitespace-only added token is formatting, not structure.
            guard !text.isEmpty, !text.unicodeScalars.allSatisfy({ $0.properties.isWhitespace }) else { continue }
            let structural = token.special
                || Self.parserMarkers.contains(text)
                // Short non-special pieces are vocabulary, not markup.
                || (text.unicodeScalars.count >= 3
                    && structuralSources.contains { $0.range(of: text, options: .literal) != nil })
            if structural { map[text] = token.id }
        }
        idsByText = map
        textsByID = Dictionary(map.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        ids = Set(map.values)
        specialIDs = Set(addedTokens.filter(\.special).map(\.id))
        matcher = ControlTextMatcher(texts: Array(map.keys))
    }

    /// The `added_tokens` of a `tokenizer.json` as swift-transformers reads them.
    static func addedTokens(in tokenizerData: Config) -> [AddedToken] {
        tokenizerData["addedTokens"].array(or: []).compactMap { entry in
            guard let id = entry["id"].integer(), let content = entry.content.string() else { return nil }
            return AddedToken(
                content: content,
                id: id,
                special: entry["special"].boolean(or: false),
                lstrip: entry["lstrip"].boolean(or: false),
                rstrip: entry["rstrip"].boolean(or: false)
            )
        }
    }

    static func == (lhs: ControlTokenTable, rhs: ControlTokenTable) -> Bool {
        lhs.idsByText == rhs.idsByText
    }
}

/// Finds control texts by Unicode scalar, independent of grapheme breaking.
struct ControlTextMatcher: Sendable {
    /// Candidates per first scalar, longest first.
    private let byFirst: [Unicode.Scalar: [[Unicode.Scalar]]]
    /// Proper prefixes and proper suffixes (two scalars or more) of every text.
    private let properPrefixes: Set<[Unicode.Scalar]>
    private let properSuffixes: Set<[Unicode.Scalar]>
    /// Lowercased pieces of two scalars or more that a template could turn
    /// into a control text by adding only delimiters around them (for
    /// example `tool_call` inside `'<' ~ key ~ '>'`).
    private let cores: Set<String>
    let maxLength: Int

    static let delimiters: Set<Unicode.Scalar> = ["<", ">", "|", "/", "[", "]", "｜", "\"", "'", "{", "}"]

    init(texts: [String]) {
        var byFirst: [Unicode.Scalar: [[Unicode.Scalar]]] = [:]
        var prefixes = Set<[Unicode.Scalar]>()
        var suffixes = Set<[Unicode.Scalar]>()
        var maxLength = 0
        var cores = Set<String>()
        for text in texts {
            let scalars = Array(text.unicodeScalars)
            guard let first = scalars.first else { continue }
            let leading = scalars.prefix(while: { Self.delimiters.contains($0) }).count
            let trailing = scalars.reversed().prefix(while: { Self.delimiters.contains($0) }).count
            if leading + trailing < scalars.count {
                for start in 0...leading {
                    for end in (scalars.count - trailing)...scalars.count where end - start >= 2 {
                        var piece = String.UnicodeScalarView()
                        piece.append(contentsOf: scalars[start..<end])
                        cores.insert(String(piece).lowercased())
                    }
                }
            }
            byFirst[first, default: []].append(scalars)
            maxLength = max(maxLength, scalars.count)
            if scalars.count > 2 {
                for length in 2..<scalars.count {
                    prefixes.insert(Array(scalars.prefix(length)))
                    suffixes.insert(Array(scalars.suffix(length)))
                }
            }
        }
        self.byFirst = byFirst.mapValues { $0.sorted { $0.count > $1.count } }
        properPrefixes = prefixes
        properSuffixes = suffixes
        self.cores = cores
        self.maxLength = maxLength
    }

    /// Whether a whole request string (as written, trimmed, or with the
    /// separator rewrites templates apply to keys) is such a piece.
    func isCore(_ string: String) -> Bool {
        guard !cores.isEmpty else { return false }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return [string, trimmed, Self.keyNormalized(trimmed)].contains { cores.contains($0.lowercased()) }
    }

    /// The rewrite templates apply to schema keys before writing them.
    static func keyNormalized(_ string: String) -> String {
        string.replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
    }

    var isEmpty: Bool { byFirst.isEmpty }

    /// The lengths of every control text that starts at `index`, longest first.
    func lengths(in scalars: [Unicode.Scalar], at index: Int) -> [Int] {
        guard index < scalars.count, let candidates = byFirst[scalars[index]] else { return [] }
        return candidates.compactMap { candidate in
            guard index + candidate.count <= scalars.count else { return nil }
            for offset in 1..<candidate.count where scalars[index + offset] != candidate[offset] { return nil }
            return candidate.count
        }
    }

    func isProperPrefix(_ scalars: ArraySlice<Unicode.Scalar>) -> Bool { properPrefixes.contains(Array(scalars)) }
    func isProperSuffix(_ scalars: ArraySlice<Unicode.Scalar>) -> Bool { properSuffixes.contains(Array(scalars)) }
}

// MARK: - Prompt side

/// Replaces control text inside request strings with per-request
/// placeholders before the template renders, and restores it afterwards.
///
/// Every full occurrence of a control text is replaced. So is a fragment of
/// two scalars or more at either end of a string (raw or whitespace-trimmed)
/// that the template's own adjacent text could complete into a control text
/// (for example a value ending in `<tool_call` before a template-written `>`).
/// Placeholders are private-use scalars around a random decimal nonce, so the
/// template's string operations (`trim`, `upper`, `tojson`) leave them intact.
final class PromptTextShield: @unchecked Sendable {
    static let open: Unicode.Scalar = "\u{E000}"
    static let close: Unicode.Scalar = "\u{E001}"

    private let matcher: ControlTextMatcher
    let nonce: String
    private(set) var literals: [String] = []
    private var indexByLiteral: [String: Int] = [:]

    init(matcher: ControlTextMatcher, nonce: String? = nil) {
        self.matcher = matcher
        self.nonce = nonce ?? String((0..<16).map { _ in "0123456789".randomElement()! })
    }

    /// Whether any request string carried control text.
    var changed: Bool { !literals.isEmpty }

    /// One placeholder per distinct literal, so equal request strings stay
    /// equal for the template's comparisons.
    private func placeholder(for literal: String) -> String {
        let index: Int
        if let existing = indexByLiteral[literal] {
            index = existing
        } else {
            index = literals.count
            literals.append(literal)
            indexByLiteral[literal] = index
        }
        return "\(Self.open)\(nonce)-\(index)\(Self.close)"
    }

    /// `wholeString`: also replace a string (keeping its surrounding
    /// whitespace outside the placeholder) that is entirely a control-text
    /// core, or whose key-normalized form (`$` removed, `-` and space as `_`,
    /// as templates rewrite schema keys) holds control text the raw form does
    /// not. Off for message roles and `type` values, which templates compare
    /// with their own literals and the API holds to fixed vocabularies.
    func sanitize(_ string: String, wholeString: Bool = true) -> String {
        guard !matcher.isEmpty else { return string }
        let scalars = Array(string.unicodeScalars)
        guard !scalars.isEmpty else { return string }
        if wholeString {
            let isSpace: (Unicode.Scalar) -> Bool = { $0.properties.isWhitespace }
            if let first = scalars.firstIndex(where: { !isSpace($0) }),
               let last = scalars.lastIndex(where: { !isSpace($0) }) {
                var coreView = String.UnicodeScalarView()
                coreView.append(contentsOf: scalars[first...last])
                let core = String(coreView)
                let normalized = ControlTextMatcher.keyNormalized(core)
                if matcher.isCore(core)
                    || (normalized != core && !controlRanges(Array(normalized.unicodeScalars)).isEmpty) {
                    var output = String.UnicodeScalarView()
                    output.append(contentsOf: scalars[..<first])
                    output.append(contentsOf: placeholder(for: core).unicodeScalars)
                    output.append(contentsOf: scalars[(last + 1)...])
                    return String(output)
                }
            }
        }
        let ranges = controlRanges(scalars)
        guard !ranges.isEmpty else { return string }
        var output = String.UnicodeScalarView()
        var cursor = 0
        for range in ranges {
            output.append(contentsOf: scalars[cursor..<range.lowerBound])
            var literal = String.UnicodeScalarView()
            literal.append(contentsOf: scalars[range])
            output.append(contentsOf: placeholder(for: String(literal)).unicodeScalars)
            cursor = range.upperBound
        }
        output.append(contentsOf: scalars[cursor...])
        return String(output)
    }

    /// Full control-text occurrences, and the boundary fragments (two
    /// scalars or more, at the raw and whitespace-trimmed ends) adjacent
    /// template text could complete. Sorted and non-overlapping.
    func controlRanges(_ scalars: [Unicode.Scalar]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var index = 0
        while index < scalars.count {
            if let length = matcher.lengths(in: scalars, at: index).first {
                ranges.append(index..<(index + length))
                index += length
            } else {
                index += 1
            }
        }
        let isSpace: (Unicode.Scalar) -> Bool = { $0.properties.isWhitespace }
        var starts = [0]
        if let first = scalars.firstIndex(where: { !isSpace($0) }), first > 0 { starts.append(first) }
        var ends = [scalars.count]
        if let last = scalars.lastIndex(where: { !isSpace($0) }), last + 1 < scalars.count { ends.append(last + 1) }
        let longest = max(0, matcher.maxLength - 1)
        func overlapsExisting(_ range: Range<Int>) -> Bool { ranges.contains { $0.overlaps(range) } }
        for start in starts where longest >= 2 {
            for length in stride(from: min(longest, scalars.count - start), through: 2, by: -1) {
                let range = start..<(start + length)
                if matcher.isProperSuffix(scalars[range]) {
                    if !overlapsExisting(range) { ranges.append(range) }
                    break
                }
            }
        }
        for end in ends where longest >= 2 {
            for length in stride(from: min(longest, end), through: 2, by: -1) {
                let range = (end - length)..<end
                if matcher.isProperPrefix(scalars[range]) {
                    if !overlapsExisting(range) { ranges.append(range) }
                    break
                }
            }
        }
        return ranges.sorted { $0.lowerBound < $1.lowerBound }
    }

    /// Request text split across adjacent parts of one array (text parts or
    /// strings a template concatenates) must not form control text across a
    /// part boundary; such a request is refused (`400`), since no single
    /// part holds the text to replace.
    func checkAdjacentParts(_ texts: [String]) throws {
        guard texts.count >= 2, !matcher.isEmpty else { return }
        // Templates may trim each part before joining them.
        let trimmed = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if trimmed != texts { try checkAdjacentPartsExactly(trimmed) }
        try checkAdjacentPartsExactly(texts)
    }

    private func checkAdjacentPartsExactly(_ texts: [String]) throws {
        var scalars: [Unicode.Scalar] = []
        var boundaries: [Int] = []
        for (index, text) in texts.enumerated() {
            if index > 0 { boundaries.append(scalars.count) }
            scalars += text.unicodeScalars
        }
        for range in controlRanges(scalars) where boundaries.contains(where: { range.lowerBound < $0 && $0 < range.upperBound }) {
            _ = range
            throw PromptControlTokenError.controlTextAcrossParts
        }
        var joined = String.UnicodeScalarView()
        joined.append(contentsOf: scalars)
        let whole = String(joined).trimmingCharacters(in: .whitespacesAndNewlines)
        if matcher.isCore(whole), !texts.contains(where: { matcher.isCore($0) }) {
            throw PromptControlTokenError.controlTextAcrossParts
        }
    }

    /// Runs of adjacent text items (strings, or objects with a string
    /// `text`) anywhere in a request value.
    func checkAdjacentParts(in value: Jinja.Value) throws {
        switch value {
        case .array(let items):
            var run: [String] = []
            for item in items {
                switch item {
                case .string(let text): run.append(text)
                case .object(let members):
                    if case .string(let text)? = members[.string("text")] { run.append(text) } else {
                        try checkAdjacentParts(run); run = []
                    }
                default:
                    try checkAdjacentParts(run); run = []
                }
                try checkAdjacentParts(in: item)
            }
            try checkAdjacentParts(run)
        case .object(let members):
            for member in members.values { try checkAdjacentParts(in: member) }
        default:
            return
        }
    }

    func checkAdjacentParts(in value: DeepseekV4Encoding.Value) throws {
        switch value {
        case .array(let items):
            var run: [String] = []
            for item in items {
                if case .string(let text) = item { run.append(text) }
                else if case .string(let text)? = item["text"] { run.append(text) }
                else { try checkAdjacentParts(run); run = [] }
                try checkAdjacentParts(in: item)
            }
            try checkAdjacentParts(run)
        case .object(let members):
            for member in members { try checkAdjacentParts(in: member.value) }
        default:
            return
        }
    }

    func sanitize(_ value: Jinja.Value) -> Jinja.Value {
        switch value {
        case .string(let string):
            return .string(sanitize(string))
        case .array(let items):
            return .array(items.map { self.sanitize($0) })
        case .object(let members):
            var result = members
            result.removeAll()
            for (key, member) in members {
                let sanitizedKey: ObjectKey
                var structural = false
                if case .string(let text) = key {
                    sanitizedKey = .string(sanitize(text))
                    structural = Self.structuralValueKeys.contains(text)
                } else {
                    sanitizedKey = key
                }
                if structural, case .string(let text) = member {
                    result[sanitizedKey] = .string(sanitize(text, wholeString: false))
                } else {
                    result[sanitizedKey] = self.sanitize(member)
                }
            }
            return .object(result)
        default:
            return value
        }
    }

    func sanitize(_ value: DeepseekV4Encoding.Value) -> DeepseekV4Encoding.Value {
        switch value {
        case .string(let string):
            return .string(sanitize(string))
        case .array(let items):
            return .array(items.map { self.sanitize($0) })
        case .object(let members):
            return .object(members.map { member in
                if Self.structuralValueKeys.contains(member.key), case .string(let text) = member.value {
                    return DeepseekV4Encoding.Value.Member(key: member.key, value: .string(sanitize(text, wholeString: false)))
                }
                return DeepseekV4Encoding.Value.Member(key: self.sanitize(member.key), value: self.sanitize(member.value))
            })
        default:
            return value
        }
    }

    /// Puts the original text back: raw placeholders as the literal, and
    /// placeholders a `tojson(ensure_ascii=True)` escaped as the literal
    /// escaped the same way. A placeholder the template altered otherwise
    /// fails the request rather than reaching the model.
    static let structuralValueKeys: Set<String> = ["role", "type"]

    func restore(_ text: String) throws -> String {
        guard changed else { return text }
        // One pass: each placeholder is parsed where it starts.
        let scalars = Array(text.unicodeScalars)
        let nonceScalars = Array(nonce.unicodeScalars)
        let escapedOpen = Array("\\ue000".unicodeScalars)
        let escapedClose = Array("\\ue001".unicodeScalars)
        func lowered(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
            (scalar.value >= 65 && scalar.value <= 90) ? Unicode.Scalar(scalar.value + 32)! : scalar
        }
        func matches(_ pattern: [Unicode.Scalar], at index: Int, caseInsensitive: Bool = false) -> Bool {
            guard index + pattern.count <= scalars.count else { return false }
            for offset in pattern.indices {
                let actual = caseInsensitive ? lowered(scalars[index + offset]) : scalars[index + offset]
                if actual != pattern[offset] { return false }
            }
            return true
        }
        /// The literal index and end of a placeholder body after its opener.
        func body(at start: Int, close: [Unicode.Scalar], caseInsensitive: Bool) -> (Int, Int)? {
            guard matches(nonceScalars, at: start), start + nonceScalars.count < scalars.count,
                  scalars[start + nonceScalars.count] == "-" else { return nil }
            var cursor = start + nonceScalars.count + 1
            var value = 0
            var digits = 0
            while cursor < scalars.count, let digit = Int(String(scalars[cursor])), scalars[cursor].isASCII, digits < 9 {
                value = value * 10 + digit
                digits += 1
                cursor += 1
            }
            guard digits > 0, value < literals.count, matches(close, at: cursor, caseInsensitive: caseInsensitive) else { return nil }
            return (value, cursor + close.count)
        }
        var output = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            if scalars[index] == Self.open, let (literal, end) = body(at: index + 1, close: [Self.close], caseInsensitive: false) {
                output.append(contentsOf: literals[literal].unicodeScalars)
                index = end
            } else if matches(escapedOpen, at: index, caseInsensitive: true),
                      let (literal, end) = body(at: index + escapedOpen.count, close: escapedClose, caseInsensitive: true) {
                output.append(contentsOf: Self.asciiJSONEscaped(literals[literal]).unicodeScalars)
                index = end
            } else {
                output.append(scalars[index])
                index += 1
            }
        }
        let result = String(output)
        // The nonce is 16 random digits; any trace of it means a placeholder
        // was changed rather than carried.
        if result.range(of: nonce, options: .literal) != nil {
            throw PromptControlTokenError.placeholderAltered
        }
        return result
    }

    /// `json.dumps(literal, ensure_ascii=True)` without the quotes.
    static func asciiJSONEscaped(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 || scalar.value > 0x7E && scalar.value != 0x7F {
                    if scalar.value > 0xFFFF {
                        let v = scalar.value - 0x10000
                        out += String(format: "\\u%04x\\u%04x", 0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF))
                    } else {
                        out += String(format: "\\u%04x", scalar.value)
                    }
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }
}

enum PromptControlTokenError: Error, CustomStringConvertible {
    case placeholderAltered
    case controlTokenInText
    case anchorMissing
    case controlTextAcrossParts

    var description: String {
        switch self {
        case .placeholderAltered: return "the chat template altered request text that holds control-token text"
        case .controlTokenInText: return "request text encoded to a control token"
        case .anchorMissing: return "segment encoding anchor missing"
        case .controlTextAcrossParts: return "adjacent content parts form model control text"
        }
    }

    var apiError: APIError {
        APIError(
            status: 400,
            message: "The model's prompt encoding does not accept this conversation: \(description)",
            code: "invalid_request",
            param: "messages"
        )
    }
}

/// Encodes a rendered prompt so that control tokens come only from the
/// template.
///
/// When no request string carries control text, the prompt is rendered from
/// the request unchanged and encoded exactly as before (one `encode` of the
/// whole string), so benign prompts keep their token IDs byte for byte.
/// Otherwise the prompt is rendered with placeholders, split at the control
/// tokens the template wrote, and each text section is encoded with a
/// tokenizer that does not match control tokens. A section after a control
/// token is encoded behind a private special anchor so it gets the same
/// non-first-section pre-tokenization as in a whole-string encode.
final class PromptControlTokenEncoder: @unchecked Sendable {
    let upstream: PreTrainedTokenizer
    let control: ControlTokenTable
    private let plain: PreTrainedTokenizer
    private let anchor: String
    private let anchorID: Int
    private let splitter: NSRegularExpression?

    init(tokenizerConfig: Config, tokenizerData: Config, upstream: PreTrainedTokenizer, structuralSources: [String]) throws {
        self.upstream = upstream
        let added = ControlTokenTable.addedTokens(in: tokenizerData)
        let table = ControlTokenTable(addedTokens: added, structuralSources: structuralSources)
        control = table

        // The whole-string encoder's added-token pattern, built the same way.
        let pattern = added
            .sorted { $0.content.count > $1.content.count }
            .map { token -> String in
                let escaped = NSRegularExpression.escapedPattern(for: token.content)
                return "\(token.lstrip ? #"\s*"# : "")(\(escaped))\(token.rstrip ? #"\s*"# : "")"
            }
            .joined(separator: "|")
        splitter = added.isEmpty ? nil : try? NSRegularExpression(pattern: pattern, options: [])

        let usedIDs = Set(added.map(\.id))
        var anchorID = -1_000_003
        while usedIDs.contains(anchorID) { anchorID -= 1 }
        self.anchorID = anchorID
        anchor = "\u{E002}" + String((0..<24).map { _ in "0123456789".randomElement()! }) + "\u{E003}"

        var data = tokenizerData.dictionary(or: [:])
        var plainAdded = tokenizerData["addedTokens"].array(or: []).filter { entry in
            guard let content = entry.content.string() else { return true }
            return table.idsByText[content] == nil
        }
        plainAdded.append(Config([
            "id": Config(anchorID),
            "content": Config(anchor),
            "special": Config(true),
            "lstrip": Config(false),
            "rstrip": Config(false),
            "normalized": Config(false),
            "single_word": Config(false),
        ] as [BinaryDistinctString: Config]))
        data["added_tokens"] = Config(plainAdded)
        plain = try PreTrainedTokenizer(tokenizerConfig: tokenizerConfig, tokenizerData: Config(data))
        // A tokenizer model that does not take the anchor into its vocabulary
        // (Unigram) encodes later sections as first sections instead.
        anchorUsable = plain.encode(text: anchor, addSpecialTokens: false) == [anchorID]
    }

    private let anchorUsable: Bool

    /// The prompt token IDs for `render`, which renders the request it is
    /// given (the original, or the shielded copy).
    func encodePrompt<Input>(
        _ input: Input,
        check: (Input, PromptTextShield) throws -> Void,
        sanitize: (Input, PromptTextShield) -> Input,
        render: (Input) throws -> String
    ) throws -> [Int] {
        let shield = PromptTextShield(matcher: control.matcher)
        do {
            try check(input, shield)
        } catch let error as PromptControlTokenError {
            throw error.apiError
        }
        let shielded = sanitize(input, shield)
        guard shield.changed else {
            return upstream.encode(text: try render(input), addSpecialTokens: false)
        }
        do {
            return try encodeSegments(try render(shielded), shield: shield)
        } catch let error as PromptControlTokenError {
            throw error.apiError
        }
    }

    func encodeSegments(_ rendered: String, shield: PromptTextShield) throws -> [Int] {
        let text = rendered as NSString
        var ids: [Int] = []
        var cursor = 0
        if let splitter {
            for match in splitter.matches(in: rendered, options: [], range: NSRange(location: 0, length: text.length)) {
                var content: String?
                for group in 1..<max(1, match.numberOfRanges) where match.range(at: group).location != NSNotFound {
                    content = text.substring(with: match.range(at: group))
                    break
                }
                guard let content, let id = control.idsByText[content] else { continue }
                if match.range.location > cursor {
                    let section = text.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                    ids += try encodeText(try shield.restore(section), first: cursor == 0)
                }
                ids.append(id)
                cursor = match.range.location + match.range.length
            }
        }
        if cursor < text.length {
            let section = text.substring(from: cursor)
            ids += try encodeText(try shield.restore(section), first: cursor == 0)
        }
        return ids
    }

    /// Text encoded with control-token matching off.
    func encodeText(_ text: String, first: Bool) throws -> [Int] {
        guard !text.isEmpty else { return [] }
        var ids: [Int]
        if first || !anchorUsable {
            ids = plain.encode(text: text, addSpecialTokens: false)
        } else {
            ids = plain.encode(text: anchor + text, addSpecialTokens: false)
            guard ids.first == anchorID else { throw PromptControlTokenError.anchorMissing }
            ids.removeFirst()
        }
        guard !ids.contains(where: { control.ids.contains($0) || $0 == anchorID }) else {
            throw PromptControlTokenError.controlTokenInText
        }
        return ids
    }
}

// MARK: - Chat template rendering

/// Renders the tokenizer's chat template to a string exactly as
/// swift-transformers' `PreTrainedTokenizer.applyChatTemplate` does
/// (template selection, `lstripBlocks`/`trimBlocks`, generation prompt on,
/// context keys and special-token attributes), with the
/// `ChatTemplateCompatibility` rewrite applied to a single template.
final class ChatTemplatePromptRenderer: @unchecked Sendable {
    private enum Source {
        case single(String)
        case named([String: String])
    }

    private static let specialTokenAttributes: Set<String> = [
        "bos_token", "eos_token", "unk_token", "sep_token", "pad_token", "cls_token", "mask_token",
        "additional_special_tokens",
    ]

    private let source: Source?
    private let specialTokenContext: [String: Jinja.Value]
    private let lock = NSLock()
    private var compiled: [String: Jinja.Template] = [:]
    let numericAttributeRewrites: Int

    init(tokenizerConfig: Config) {
        let value: Config = tokenizerConfig.chatTemplate
        var rewrites = 0
        if let array = value.array() {
            var named: [String: String] = [:]
            for item in array {
                if let name = item["name"].string(), let template = item["template"].string() { named[name] = template }
            }
            source = .named(named)
        } else if let string = value.string() {
            let result = ChatTemplateCompatibility.rewrite(string)
            rewrites = result.numericAttributeRewrites
            source = .single(result.template)
        } else {
            source = nil
        }
        numericAttributeRewrites = rewrites

        var context: [String: Jinja.Value] = [:]
        for (key, value) in tokenizerConfig.dictionary(or: [:]) where Self.specialTokenAttributes.contains(key.string) {
            if value.isNull() { continue }
            if let string = value.string() {
                context[key.string] = .string(string)
            } else if let dictionary = value.dictionary() {
                if let content = Config(dictionary).content.string() { context[key.string] = .string(content) }
            } else if let array = value.array() {
                let strings = array.compactMap { $0.string() }
                if strings.count == array.count { context[key.string] = .array(strings.map { .string($0) }) }
            }
        }
        specialTokenContext = context
    }

    var hasTemplate: Bool { source != nil }

    /// The text of every template the tokenizer can select.
    var templateTexts: [String] {
        switch source {
        case .single(let text)?: return [text]
        case .named(let named)?: return Array(named.values)
        case nil: return []
        }
    }

    private func template(tools: [[String: any Sendable]]?) throws -> Jinja.Template {
        let text: String
        switch source {
        case .single(let single)?:
            text = single
        case .named(let named)?:
            if let tools, !tools.isEmpty, let toolUse = named["tool_use"] {
                text = toolUse
            } else if let fallback = named["default"] {
                text = fallback
            } else {
                throw MLXLMCommon.TokenizerError.missingChatTemplate
            }
        case nil:
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
        lock.lock()
        defer { lock.unlock() }
        if let cached = compiled[text] { return cached }
        let template = try Jinja.Template(text, with: .init(lstripBlocks: true, trimBlocks: true))
        compiled[text] = template
        return template
    }

    struct Input {
        var messages: [Jinja.Value]
        var tools: [Jinja.Value]?
        var additionalContext: [String: Jinja.Value]
        let toolSpecs: [[String: any Sendable]]?
    }

    func input(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> Input {
        Input(
            messages: try messages.map { try Jinja.Value(any: $0) },
            tools: try tools.map { try $0.map { try Jinja.Value(any: $0) } },
            additionalContext: try (additionalContext ?? [:]).mapValues { try Jinja.Value(any: $0) },
            toolSpecs: tools
        )
    }

    /// Assistant messages whose string content holds `</think>` and that have
    /// no string `reasoning_content`, with the text before the first
    /// `</think>` moved to `reasoning_content` the way templates split it
    /// (`content.split('</think>')[0].split('<think>')[-1]`, content after the
    /// last `</think>`). Nil when no message qualifies.
    static func splittingInlineReasoning(_ messages: [[String: any Sendable]]) -> [[String: any Sendable]]? {
        var changed = false
        let result = messages.map { message -> [String: any Sendable] in
            guard message["role"] as? String == "assistant",
                  !(message["reasoning_content"] is String),
                  let content = message["content"] as? String,
                  content.contains("</think>") else { return message }
            let pieces = content.components(separatedBy: "</think>")
            guard let head = pieces.first, let last = pieces.last else { return message }
            var copy = message
            copy["reasoning_content"] = head.components(separatedBy: "<think>").last ?? head
            copy["content"] = last
            changed = true
            return copy
        }
        return changed ? result : nil
    }

    static func check(_ input: Input, _ shield: PromptTextShield) throws {
        for message in input.messages { try shield.checkAdjacentParts(in: message) }
        for tool in input.tools ?? [] { try shield.checkAdjacentParts(in: tool) }
    }

    static func sanitize(_ input: Input, _ shield: PromptTextShield) -> Input {
        var result = input
        result.messages = input.messages.map { shield.sanitize($0) }
        result.tools = input.tools.map { tools in tools.map { shield.sanitize($0) } }
        result.additionalContext = input.additionalContext.mapValues { shield.sanitize($0) }
        return result
    }

    func render(_ input: Input) throws -> String {
        var context: [String: Jinja.Value] = [
            "messages": .array(input.messages),
            "add_generation_prompt": .boolean(true),
        ]
        if let tools = input.tools { context["tools"] = .array(tools) }
        for (key, value) in input.additionalContext { context[key] = value }
        for (key, value) in specialTokenContext { context[key] = value }
        return try template(tools: input.toolSpecs).render(context)
    }
}

// MARK: - Output side

/// Marks control text that the model wrote with ordinary tokens.
///
/// The decoded text of a generation feeds text parsers (reasoning split,
/// tool-call grammars, the grammar gate's reasoning close). A control text
/// that came from ordinary tokens gets `mark` before its last scalar, so no
/// parser can read it as structure; text a real control token produced is
/// left as is. `strip` removes every mark where text leaves the runtime, so
/// buyers see exactly the text the model wrote.
///
/// The mark goes before the last scalar of an occurrence, which arrives with
/// the token that completes the occurrence: marking stays prefix-stable for
/// incremental decoders.
enum ControlTextShield {
    // A noncharacter cannot be written as a literal.
    static let mark = Unicode.Scalar(UInt32(0xFDD0))!
    static let markString = String(Character(mark))

    /// Removes every U+FDD0. The noncharacter is reserved for internal use
    /// (Unicode §23.7); one the model writes itself is removed as well, so
    /// stripping is idempotent and can run at every boundary and before
    /// validation.
    static func strip(_ text: String) -> String {
        guard text.unicodeScalars.contains(mark) else { return text }
        var scalars = text.unicodeScalars
        scalars.removeAll { $0 == mark }
        return String(scalars)
    }

    static func strip(_ text: String?) -> String? { text.map { strip($0) } }

    /// Marks every occurrence of a control text in `scalars` that does not
    /// start at one of `realStarts` with its own length (a real control
    /// token's text).
    static func marked(
        _ scalars: [Unicode.Scalar],
        matcher: ControlTextMatcher,
        real: [Int: Int],
        from searchStart: Int = 0
    ) -> [Int] {
        var positions: [Int] = []
        guard !matcher.isEmpty else { return positions }
        // coverEnd[i]: the furthest end of a real range that starts at or
        // before i and covers i (linear in the text and the ranges).
        var coverEnd = [Int](repeating: -1, count: scalars.count)
        var furthest = -1
        var startsAt: [Int: Int] = [:]
        for (start, length) in real where start + length > 0 && start < scalars.count {
            let from = max(0, start)
            startsAt[from] = max(startsAt[from] ?? 0, start + length)
        }
        for index in scalars.indices {
            if let end = startsAt[index] { furthest = max(furthest, end) }
            if furthest > index { coverEnd[index] = furthest }
        }
        var index = max(0, searchStart)
        while index < scalars.count {
            for length in matcher.lengths(in: scalars, at: index) {
                // A real token's own text, or text inside it, stays as is.
                if coverEnd[index] >= index + length { continue }
                positions.append(index + length - 1)
            }
            index += 1
        }
        return positions
    }

    static func insertingMarks(_ scalars: [Unicode.Scalar], at positions: [Int]) -> String {
        let set = Set(positions)
        var view = String.UnicodeScalarView()
        for (index, scalar) in scalars.enumerated() {
            if set.contains(index) { view.append(mark) }
            view.append(scalar)
        }
        return String(view)
    }

    /// Whole-sequence decode with marks. `decode` is the tokenizer's plain
    /// decode. A real control token's text starts where the decode of the
    /// tokens before it ends; one that does not line up is left unproven and
    /// gets marked like ordinary text.
    static func decode(
        tokenIds: [Int],
        skipSpecialTokens: Bool,
        control: ControlTokenTable,
        decode: ([Int], Bool) -> String
    ) -> String {
        let text = decode(tokenIds, skipSpecialTokens)
        let scalars = Array(text.unicodeScalars)
        // Fast exit: no control text anywhere.
        var any = false
        for index in scalars.indices where !control.matcher.lengths(in: scalars, at: index).isEmpty {
            any = true
            break
        }
        guard any else { return text }
        // Offsets of the real control tokens. Decoding the ordinary runs
        // between them is linear; when their concatenation is not the whole
        // decode (a decoder that rewrites across runs), each offset comes from
        // the decode of the tokens before it.
        var visible: [(index: Int, text: [Unicode.Scalar])] = []
        for (index, id) in tokenIds.enumerated() {
            guard let expected = control.textsByID[id] else { continue }
            if skipSpecialTokens, control.specialIDs.contains(id) { continue }
            visible.append((index, Array(expected.unicodeScalars)))
        }
        var starts: [Int] = []
        var assembled: [Unicode.Scalar] = []
        var runStart = 0
        for entry in visible {
            assembled += decode(Array(tokenIds[runStart..<entry.index]), skipSpecialTokens).unicodeScalars
            starts.append(assembled.count)
            assembled += entry.text
            runStart = entry.index + 1
        }
        assembled += decode(Array(tokenIds[runStart...]), skipSpecialTokens).unicodeScalars
        if assembled != scalars {
            starts = visible.map { decode(Array(tokenIds[..<$0.index]), skipSpecialTokens).unicodeScalars.count }
        }
        var real: [Int: Int] = [:]
        for (entry, start) in zip(visible, starts) {
            guard start + entry.text.count <= scalars.count,
                  Array(scalars[start..<(start + entry.text.count)]) == entry.text
            else { continue }
            real[start] = entry.text.count
        }
        return insertingMarks(scalars, at: marked(scalars, matcher: control.matcher, real: real))
    }
}

/// Incremental counterpart of `ControlTextShield.decode` for decoders that
/// return their full text after each token. Work per token is bounded by
/// the appended text plus the longest control text: the decoder's earlier
/// text is checked with one prefix comparison and never rescanned. A decoder
/// that revises earlier text (a provisional cleanup tail) gets a full
/// recompute for that token.
final class ControlTextIncrementalShield: @unchecked Sendable {
    private let control: ControlTokenTable
    private var previous = ""
    private var previousCount = 0
    private var output = ""
    /// Real control-token text ranges, by absolute scalar offset, in order.
    private var real: [(start: Int, length: Int)] = []
    /// Ranges before this index end before the current window.
    private var active = 0
    /// The last scalars of `previous`, up to the longest control text.
    private var tail: [Unicode.Scalar] = []

    init(control: ControlTokenTable) {
        self.control = control
    }

    func shielded(token: Int, fullText: String) -> String {
        guard fullText.utf8.starts(with: previous.utf8),
              let deltaText = String(bytes: fullText.utf8.dropFirst(previous.utf8.count), encoding: .utf8)
        else { return recompute(token: token, fullText) }
        let deltaScalars = Array(deltaText.unicodeScalars)
        let base = previousCount - tail.count
        var window = tail + deltaScalars
        let total = previousCount + deltaScalars.count
        if let text = control.textsByID[token] {
            let expected = Array(text.unicodeScalars)
            if window.count >= expected.count, Array(window.suffix(expected.count)) == expected {
                real.append((total - expected.count, expected.count))
            }
        }
        while active < real.count, real[active].start + real[active].length <= base { active += 1 }
        var windowReal: [Int: Int] = [:]
        for range in real[active...] {
            windowReal[range.start - base] = max(windowReal[range.start - base] ?? 0, range.length)
        }
        let positions = ControlTextShield.marked(window, matcher: control.matcher, real: windowReal)
            .filter { $0 >= tail.count }
            .map { $0 - tail.count }
        output += ControlTextShield.insertingMarks(deltaScalars, at: positions)
        previous = fullText
        previousCount = total
        let keep = max(0, control.matcher.maxLength - 1)
        window.removeFirst(max(0, window.count - keep))
        tail = window
        return output
    }

    /// A decoder revised earlier text: mark the whole text again, keeping
    /// the real ranges whose text is still in place.
    private func recompute(token: Int, _ fullText: String) -> String {
        let scalars = Array(fullText.unicodeScalars)
        // A kept range must still hold a control text of its length.
        real = real.filter { range in
            guard range.start >= 0, range.start + range.length <= scalars.count else { return false }
            let piece = Array(scalars[range.start..<(range.start + range.length)])
            return control.matcher.lengths(in: piece, at: 0).contains(range.length)
        }
        if let text = control.textsByID[token] {
            let expected = Array(text.unicodeScalars)
            if scalars.count >= expected.count, Array(scalars.suffix(expected.count)) == expected,
               real.last.map({ $0.start != scalars.count - expected.count }) ?? true {
                real.append((scalars.count - expected.count, expected.count))
            }
        }
        active = 0
        var all: [Int: Int] = [:]
        for range in real { all[range.start] = max(all[range.start] ?? 0, range.length) }
        output = ControlTextShield.insertingMarks(scalars, at: ControlTextShield.marked(scalars, matcher: control.matcher, real: all))
        previous = fullText
        previousCount = scalars.count
        tail = Array(scalars.suffix(max(0, control.matcher.maxLength - 1)))
        return output
    }
}

/// A tokenizer whose prompt encoding and output decoding follow §3.14.
protocol ControlTokenAware {
    var controlTokens: ControlTokenTable? { get }
}

extension ControlTokenTable {
    /// The control-token table of a loaded tokenizer, through wrappers.
    static func of(_ tokenizer: any MLXLMCommon.Tokenizer) -> ControlTokenTable? {
        (tokenizer as? ControlTokenAware)?.controlTokens
    }
}

// MARK: - Runtime boundary

extension StreamChunk {
    func strippingControlTextMarks() -> StreamChunk {
        switch self {
        case .content(let text): return .content(ControlTextShield.strip(text))
        case .reasoning(let text): return .reasoning(ControlTextShield.strip(text))
        case .toolCallDelta(let delta):
            return .toolCallDelta(StreamToolCallDelta(
                index: delta.index,
                id: delta.id,
                type: delta.type,
                functionName: ControlTextShield.strip(delta.functionName),
                arguments: ControlTextShield.strip(delta.arguments)
            ))
        }
    }
}

extension ToolCall {
    func strippingControlTextMarks() -> ToolCall {
        ToolCall(id: id, functionName: ControlTextShield.strip(functionName), arguments: ControlTextShield.strip(arguments))
    }
}

extension CompletionResult {
    func strippingControlTextMarks() -> CompletionResult {
        let mark = ControlTextShield.mark
        let marked = content.unicodeScalars.contains(mark)
            || reasoningContent?.unicodeScalars.contains(mark) == true
            || toolCalls?.contains { $0.functionName.unicodeScalars.contains(mark) || $0.arguments.unicodeScalars.contains(mark) } == true
        guard marked else { return self }
        var result = CompletionResult(
            content: ControlTextShield.strip(content),
            finishReason: finishReason,
            promptTokens: promptTokens,
            cachedPromptTokens: cachedPromptTokens,
            kvCacheBytesReused: kvCacheBytesReused,
            completionTokens: completionTokens,
            generatedCompletionTokens: generatedCompletionTokens,
            ttftMilliseconds: ttftMilliseconds,
            generationMilliseconds: generationMilliseconds,
            toolCalls: toolCalls?.map { $0.strippingControlTextMarks() },
            modelHashObserved: modelHashObserved,
            settlementDisposition: settlementDisposition,
            specDecodeDraftedTokens: specDecodeDraftedTokens,
            specDecodeAcceptedTokens: specDecodeAcceptedTokens,
            specDecodeGeneration: specDecodeGeneration,
            loopbackPrefixCompletionTokens: loopbackPrefixCompletionTokens,
            shardGroupEvidence: shardGroupEvidence,
            reasoningContent: ControlTextShield.strip(reasoningContent),
            reasoningTokens: reasoningTokens,
            stopSequence: stopSequence
        )
        result.ttftMilliseconds = ttftMilliseconds
        return result
    }
}
