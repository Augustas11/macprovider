import Foundation

// SPEC-001-R017 *Configuration*: the warm-set keys of the provider config
// file (`warm_models`, `warm_model_limits`, and `supported_models` when a
// member is added), edited as text so every other line is kept byte for byte.
// This one file is compiled into both macprovider-cli and Malibu.app
// (phase3-binary/app/project.yml), so both writers keep the warm set valid the
// same way. It must stay free of types that exist in only one of the targets.

/// One further model's own context and slots (`warm_model_limits`). A field
/// left nil keeps the primary's value for that model.
struct WarmSetConfigLimits: Equatable, Sendable {
    var contextTokens: Int?
    var slots: Int?

    init(contextTokens: Int? = nil, slots: Int? = nil) {
        self.contextTokens = contextTokens
        self.slots = slots
    }

    var isEmpty: Bool { contextTokens == nil && slots == nil }
}

enum WarmSetConfigTextError: Error, Equatable, CustomStringConvertible {
    /// A warm-set key is written in a form this editor does not rewrite.
    case unsupportedLayout(key: String)
    /// The primary `model` is never one of the further models.
    case primaryModel(String)

    var description: String {
        switch self {
        case let .unsupportedLayout(key):
            return "\(key) is written in a form that cannot be edited automatically; edit it by hand"
        case let .primaryModel(model):
            return "\(model) is the main model; it is always loaded"
        }
    }
}

enum WarmSetConfigText {
    static let modelKey = "model"
    static let warmModelsKey = "warm_models"
    static let limitsKey = "warm_model_limits"
    static let supportedModelsKey = "supported_models"
    static let contextTokensKey = "context_tokens"
    static let slotsKey = "slots"

    struct Limit: Equatable, Sendable {
        var modelID: String
        var limits: WarmSetConfigLimits
    }

    /// The warm-set keys as the file states them.
    struct Snapshot: Equatable, Sendable {
        var model: String?
        var warmModels: [String]
        var limits: [Limit]
        /// Nil when the key is absent.
        var supportedModels: [String]?

        func limits(for modelID: String) -> WarmSetConfigLimits? {
            let key = WarmSetConfigText.fold(modelID)
            return limits.first { WarmSetConfigText.fold($0.modelID) == key }?.limits
        }

        func isWarm(_ modelID: String) -> Bool {
            let key = WarmSetConfigText.fold(modelID)
            return warmModels.contains { WarmSetConfigText.fold($0) == key }
        }
    }

    static func fold(_ modelID: String) -> String {
        modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func read(_ text: String) throws -> Snapshot {
        let document = Document(text)
        return Snapshot(
            model: try document.block(modelKey).flatMap { try parseBlockScalar($0.inline, key: modelKey) },
            warmModels: try document.block(warmModelsKey).map(parseList) ?? [],
            limits: try document.block(limitsKey).map(parseLimits) ?? [],
            supportedModels: try document.block(supportedModelsKey).map(parseList)
        )
    }

    /// The text with the file's own `model` taken out of `warm_models` and
    /// `warm_model_limits`, so a write that changes the primary never leaves
    /// a config `serve` refuses. Text that needs no change is returned as is.
    static func removingPrimary(from text: String) throws -> String {
        let document = Document(text)
        guard let model = try document.block(modelKey).flatMap({ try parseBlockScalar($0.inline, key: modelKey) }),
              document.block(warmModelsKey) != nil || document.block(limitsKey) != nil else {
            return text
        }
        return try removing(model, from: text)
    }

    /// Adds `modelID` to `warm_models` (kept in place when it is there) and
    /// sets its limits exactly: nil or empty limits remove its entry. When
    /// `supported_models` is present it gains the model, so the further
    /// models stay a subset of it.
    static func setting(_ modelID: String, limits: WarmSetConfigLimits?, in text: String) throws -> String {
        let id = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshot = try read(text)
        if let model = snapshot.model, fold(model) == fold(id) {
            throw WarmSetConfigTextError.primaryModel(model)
        }
        var document = Document(text)
        if !snapshot.isWarm(id) {
            document.replace(warmModelsKey, with: renderList(warmModelsKey, snapshot.warmModels + [id]))
        }
        var entries = snapshot.limits.filter { fold($0.modelID) != fold(id) }
        if let limits, !limits.isEmpty {
            if let index = snapshot.limits.firstIndex(where: { fold($0.modelID) == fold(id) }) {
                entries.insert(Limit(modelID: snapshot.limits[index].modelID, limits: limits), at: index)
            } else {
                entries.append(Limit(modelID: id, limits: limits))
            }
        }
        if entries != snapshot.limits {
            document.replace(limitsKey, with: renderLimits(entries))
        }
        if let supported = snapshot.supportedModels, !supported.contains(where: { fold($0) == fold(id) }) {
            document.replace(supportedModelsKey, with: renderList(supportedModelsKey, supported + [id]))
        }
        return document.text
    }

    /// Takes `modelID` out of `warm_models` and `warm_model_limits`;
    /// `supported_models` keeps it (it states willingness only).
    static func removing(_ modelID: String, from text: String) throws -> String {
        let key = fold(modelID)
        let snapshot = try read(text)
        var document = Document(text)
        let warm = snapshot.warmModels.filter { fold($0) != key }
        if warm != snapshot.warmModels {
            document.replace(warmModelsKey, with: warm.isEmpty ? nil : renderList(warmModelsKey, warm))
        }
        let limits = snapshot.limits.filter { fold($0.modelID) != key }
        if limits != snapshot.limits {
            document.replace(limitsKey, with: renderLimits(limits))
        }
        return document.text
    }

    // MARK: Rendering

    /// A plain scalar when YAML reads it back as the same string, else a
    /// double-quoted one.
    static func renderScalar(_ value: String) -> String {
        let plainBytes = value.utf8.allSatisfy { byte in
            (0x61...0x7A).contains(byte) || (0x41...0x5A).contains(byte) || (0x30...0x39).contains(byte)
                || [0x2D, 0x5F, 0x2E, 0x2F].contains(byte)
        }
        let reserved: Set<String> = ["true", "false", "yes", "no", "on", "off", "null", "y", "n"]
        let plain = !value.isEmpty && plainBytes && value.first != "-" && value.first != "."
            && Double(value) == nil && !reserved.contains(value.lowercased())
        guard !plain else { return value }
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    private static func renderList(_ key: String, _ items: [String]) -> [String] {
        ["\(key): [\(items.map(renderScalar).joined(separator: ", "))]"]
    }

    private static func renderLimits(_ entries: [Limit]) -> [String]? {
        let kept = entries.filter { !$0.limits.isEmpty }
        guard !kept.isEmpty else { return nil }
        return ["\(limitsKey):"] + kept.map { entry in
            var fields: [String] = []
            if let context = entry.limits.contextTokens { fields.append("\(contextTokensKey): \(context)") }
            if let slots = entry.limits.slots { fields.append("\(slotsKey): \(slots)") }
            return "  \(renderScalar(entry.modelID)): {\(fields.joined(separator: ", "))}"
        }
    }

    // MARK: Parsing

    private static func parseList(_ block: Document.Block) throws -> [String] {
        let key = block.key
        if !block.inline.isEmpty {
            if block.inline.hasPrefix("[") {
                guard case let .sequence(items)? = try? FlowParser.parse(block.inline) else {
                    throw WarmSetConfigTextError.unsupportedLayout(key: key)
                }
                return try items.map { item in
                    guard case let .scalar(value) = item else { throw WarmSetConfigTextError.unsupportedLayout(key: key) }
                    return value
                }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            }
            guard let scalar = try parseBlockScalar(block.inline, key: key) else { return [] }
            return scalar.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        var items: [String] = []
        for line in block.children {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard trimmed.hasPrefix("-") else { throw WarmSetConfigTextError.unsupportedLayout(key: key) }
            let rest = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            guard let value = try parseBlockScalar(rest, key: key) else { continue }
            let item = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !item.isEmpty { items.append(item) }
        }
        return items
    }

    private static func parseLimits(_ block: Document.Block) throws -> [Limit] {
        let key = block.key
        if !block.inline.isEmpty {
            if isNull(block.inline) { return [] }
            guard block.inline.hasPrefix("{"), case let .mapping(pairs)? = try? FlowParser.parse(block.inline) else {
                throw WarmSetConfigTextError.unsupportedLayout(key: key)
            }
            return try pairs.map { try limit(id: $0.key, value: $0.value, key: key) }
        }
        var result: [Limit] = []
        var childIndent: Int?
        var current: (id: String, fields: [(String, FlowValue)])?
        func flush() throws {
            if let current {
                result.append(try limit(id: current.id, value: .mapping(current.fields.map { MappingPair(key: $0.0, value: $0.1) }), key: key))
            }
            current = nil
        }
        for line in block.children {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix { $0 == " " }.count
            guard indent > 0, !line.contains("\t") else { throw WarmSetConfigTextError.unsupportedLayout(key: key) }
            if childIndent == nil { childIndent = indent }
            guard let (name, rest) = splitKey(trimmed) else { throw WarmSetConfigTextError.unsupportedLayout(key: key) }
            if indent == childIndent {
                try flush()
                if rest.isEmpty {
                    current = (name, [])
                } else if rest.hasPrefix("{") {
                    guard let value = try? FlowParser.parse(rest) else { throw WarmSetConfigTextError.unsupportedLayout(key: key) }
                    result.append(try limit(id: name, value: value, key: key))
                } else if isNull(rest) {
                    result.append(Limit(modelID: name, limits: WarmSetConfigLimits()))
                } else {
                    throw WarmSetConfigTextError.unsupportedLayout(key: key)
                }
            } else if indent > childIndent!, current != nil {
                guard let value = try? FlowParser.parse(rest) else { throw WarmSetConfigTextError.unsupportedLayout(key: key) }
                current!.fields.append((name, value))
            } else {
                throw WarmSetConfigTextError.unsupportedLayout(key: key)
            }
        }
        try flush()
        return result
    }

    private static func limit(id: String, value: FlowValue, key: String) throws -> Limit {
        var limits = WarmSetConfigLimits()
        switch value {
        case .null:
            break
        case let .mapping(fields):
            for field in fields {
                if case .null = field.value { continue }
                guard case let .scalar(raw) = field.value, let number = Int(raw) else {
                    throw WarmSetConfigTextError.unsupportedLayout(key: key)
                }
                switch field.key {
                case contextTokensKey: limits.contextTokens = number
                case slotsKey: limits.slots = number
                default: throw WarmSetConfigTextError.unsupportedLayout(key: key)
                }
            }
        default:
            throw WarmSetConfigTextError.unsupportedLayout(key: key)
        }
        return Limit(modelID: id.trimmingCharacters(in: .whitespacesAndNewlines), limits: limits)
    }

    /// `name: rest` with `name` plain or quoted; nil when the line has no key.
    private static func splitKey(_ line: String) -> (String, String)? {
        var parser = FlowParser(line)
        guard let name = try? parser.scalar(inKey: true), parser.consume(":") else { return nil }
        return (name, parser.remainder.trimmingCharacters(in: .whitespaces))
    }

    private static func isNull(_ inline: String) -> Bool {
        ["", "~", "null", "Null", "NULL"].contains(strippingComment(inline).trimmingCharacters(in: .whitespaces))
    }

    /// A block-context scalar (plain text may hold `,` or `[`), comment
    /// removed; nil for YAML null.
    private static func parseBlockScalar(_ inline: String, key: String) throws -> String? {
        let text = strippingComment(inline).trimmingCharacters(in: .whitespaces)
        if isNull(text) { return nil }
        guard text.first == "\"" || text.first == "'" else { return text }
        guard case let .scalar(value)? = try? FlowParser.parse(text) else {
            throw WarmSetConfigTextError.unsupportedLayout(key: key)
        }
        return value
    }

    // MARK: Document

    /// The config as lines, with each top-level key's block: its line and
    /// the indented (or `- `) lines right after it.
    struct Document {
        struct Block {
            let key: String
            /// The value after `key:` on the key line, comment removed.
            let inline: String
            let children: [String]
            let range: Range<Int>
        }

        private(set) var lines: [String]
        private let newline: String

        init(_ text: String) {
            newline = text.contains("\r\n") ? "\r\n" : "\n"
            var lines: [String] = []
            text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byLines) { _, _, enclosing, _ in
                lines.append(String(text[enclosing]))
            }
            self.lines = lines
        }

        var text: String { lines.joined() }

        private static func content(_ raw: String) -> String {
            var line = raw
            while line.hasSuffix("\n") || line.hasSuffix("\r") { line.removeLast() }
            return line
        }

        func block(_ key: String) -> Block? {
            for (index, raw) in lines.enumerated() {
                let line = Self.content(raw)
                guard line.hasPrefix("\(key):") else { continue }
                let after = line.dropFirst(key.count + 1)
                guard after.isEmpty || after.first == " " || after.first == "\t" else { continue }
                var end = index + 1
                while end < lines.count {
                    let next = Self.content(lines[end])
                    guard let first = next.first, first == " " || first == "\t" || first == "-" else { break }
                    end += 1
                }
                return Block(
                    key: key,
                    inline: WarmSetConfigText.strippingComment(String(after)).trimmingCharacters(in: .whitespaces),
                    children: lines[(index + 1)..<end].map(Self.content),
                    range: index..<end)
            }
            return nil
        }

        /// Replaces the key's block, appends it when absent, or removes it
        /// when `rendered` is nil.
        mutating func replace(_ key: String, with rendered: [String]?) {
            let newLines = (rendered ?? []).map { $0 + newline }
            if let block = block(key) {
                var replacement = newLines
                // The last line of the file keeps its missing terminator.
                if block.range.upperBound == lines.count, let last = lines.last, !last.hasSuffix("\n"), !replacement.isEmpty {
                    replacement[replacement.count - 1].removeLast(newline.count)
                }
                lines.replaceSubrange(block.range, with: replacement)
            } else if !newLines.isEmpty {
                if let last = lines.last, !last.hasSuffix("\n") {
                    lines[lines.count - 1] = last + newline
                }
                lines.append(contentsOf: newLines)
            }
        }
    }

    /// The text before an unquoted ` #` comment.
    static func strippingComment(_ value: String) -> String {
        var quote: Character?
        var previous: Character = " "
        var index = value.startIndex
        while index < value.endIndex {
            let char = value[index]
            if let open = quote {
                if char == open { quote = nil }
            } else if char == "\"" || char == "'", [" ", "\t", ",", "[", "{", ":"].contains(previous) {
                // A quote opens a quoted scalar only where one can start.
                quote = char
            } else if char == "#", previous == " " || previous == "\t" {
                return String(value[..<index])
            }
            previous = char
            index = value.index(after: index)
        }
        return value
    }

    // MARK: Flow values

    enum FlowValue: Equatable {
        case null
        case scalar(String)
        case sequence([FlowValue])
        case mapping([MappingPair])
    }

    struct MappingPair: Equatable {
        let key: String
        let value: FlowValue
    }

    struct FlowParser {
        private let chars: [Character]
        private var index = 0

        init(_ text: String) { chars = Array(text) }

        enum Failure: Error { case malformed }

        var remainder: String { String(chars[min(index, chars.count)...]) }

        /// One complete flow value; only a comment may follow it.
        static func parse(_ text: String) throws -> FlowValue {
            var parser = FlowParser(WarmSetConfigText.strippingComment(text))
            let value = try parser.value()
            parser.skipSpace()
            guard parser.index == parser.chars.count else { throw Failure.malformed }
            return value
        }

        mutating func skipSpace() {
            while index < chars.count, chars[index] == " " || chars[index] == "\t" { index += 1 }
        }

        mutating func consume(_ char: Character) -> Bool {
            skipSpace()
            guard index < chars.count, chars[index] == char else { return false }
            index += 1
            return true
        }

        mutating func value() throws -> FlowValue {
            skipSpace()
            guard index < chars.count else { return .null }
            switch chars[index] {
            case "[":
                index += 1
                var items: [FlowValue] = []
                if consume("]") { return .sequence(items) }
                repeat {
                    items.append(try value())
                } while consume(",")
                guard consume("]") else { throw Failure.malformed }
                return .sequence(items)
            case "{":
                index += 1
                var pairs: [MappingPair] = []
                if consume("}") { return .mapping(pairs) }
                repeat {
                    let key = try scalar(inKey: true)
                    guard consume(":") else { throw Failure.malformed }
                    pairs.append(MappingPair(key: key, value: try value()))
                } while consume(",")
                guard consume("}") else { throw Failure.malformed }
                return .mapping(pairs)
            case "\"", "'":
                return .scalar(try scalar(inKey: false))
            default:
                let raw = try scalar(inKey: false)
                return ["", "~", "null", "Null", "NULL"].contains(raw) ? .null : .scalar(raw)
            }
        }

        /// A quoted or plain scalar. A plain one ends at a flow indicator, or
        /// at `: ` / a final `:` when it is a key.
        mutating func scalar(inKey: Bool) throws -> String {
            skipSpace()
            guard index < chars.count else { return "" }
            let open = chars[index]
            if open == "\"" || open == "'" {
                index += 1
                var out = ""
                while index < chars.count {
                    let char = chars[index]
                    index += 1
                    if char == open {
                        if open == "'", index < chars.count, chars[index] == "'" {
                            out.append("'"); index += 1; continue
                        }
                        return out
                    }
                    if open == "\"", char == "\\", index < chars.count {
                        let escaped = chars[index]
                        index += 1
                        switch escaped {
                        case "n": out.append("\n")
                        case "t": out.append("\t")
                        case "r": out.append("\r")
                        case "u":
                            guard index + 4 <= chars.count,
                                  let code = UInt32(String(chars[index..<(index + 4)]), radix: 16),
                                  let unicode = Unicode.Scalar(code) else { throw Failure.malformed }
                            out.unicodeScalars.append(unicode)
                            index += 4
                        default: out.append(escaped)
                        }
                        continue
                    }
                    out.append(char)
                }
                throw Failure.malformed
            }
            var out = ""
            while index < chars.count {
                let char = chars[index]
                if char == "," || char == "]" || char == "}" || char == "[" || char == "{" { break }
                if char == ":" {
                    let next = index + 1 < chars.count ? chars[index + 1] : " "
                    if next == " " || next == "\t" || next == "," || next == "}" || next == "]" || (inKey && index + 1 == chars.count) {
                        break
                    }
                }
                out.append(char)
                index += 1
            }
            return out.trimmingCharacters(in: .whitespaces)
        }
    }
}
