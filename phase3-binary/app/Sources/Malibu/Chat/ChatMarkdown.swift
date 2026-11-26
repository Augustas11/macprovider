import AppKit
import SwiftUI

/// Markdown for model answers. Links and images stay text: an answer is
/// untrusted and must not open a URL or load a remote resource.
enum ChatMarkdown {
    enum Inline: Equatable {
        case text(String)
        case code(String)
        case math(String)
        case strong(String)
        case emphasis(String)
    }

    enum Block: Equatable {
        case heading(Int, String)
        case paragraph([Inline])
        case code(language: String, source: String)
        case math(String)
        case list(ordered: Bool, items: [[Inline]])
        case quote([Inline])
    }

    static let maxBlocks = 400

    static func parse(_ source: String) -> [Block] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [Block] = []
        var paragraph: [String] = []
        var index = 0
        func flushParagraph() {
            guard !paragraph.isEmpty, blocks.count < maxBlocks else { paragraph.removeAll(); return }
            blocks.append(.paragraph(inlines(paragraph.joined(separator: "\n"))))
            paragraph.removeAll()
        }
        while index < lines.count, blocks.count < maxBlocks {
            let line = lines[index]
            if line.hasPrefix("```") {
                flushParagraph()
                let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                index += 1
                var code: [String] = []
                var bytes = 0
                while index < lines.count, !lines[index].hasPrefix("```"), bytes < 64 * 1024 {
                    code.append(lines[index])
                    bytes += lines[index].utf8.count + 1
                    index += 1
                }
                if index < lines.count, lines[index].hasPrefix("```") { index += 1 }
                blocks.append(.code(language: language, source: code.joined(separator: "\n")))
                continue
            }
            if line.trimmingCharacters(in: .whitespaces) == "$$" {
                flushParagraph()
                index += 1
                var math: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces) != "$$", math.count < 40 {
                    math.append(lines[index])
                    index += 1
                }
                if index < lines.count, lines[index].trimmingCharacters(in: .whitespaces) == "$$" { index += 1 }
                blocks.append(.math(math.joined(separator: " ")))
                continue
            }
            if let heading = heading(line) {
                flushParagraph()
                blocks.append(heading)
                index += 1
                continue
            }
            if line.hasPrefix("$$"), line.hasSuffix("$$"), line.count > 4 {
                flushParagraph()
                blocks.append(.math(String(line.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)))
                index += 1
                continue
            }
            if line.isEmpty {
                flushParagraph()
                index += 1
                continue
            }
            if isListItem(line) {
                flushParagraph()
                let ordered = line.range(of: #"^[0-9]{1,3}\. "#, options: .regularExpression) != nil
                var items: [[Inline]] = []
                while index < lines.count, isListItem(lines[index]), items.count < 100 {
                    items.append(inlines(listBody(lines[index])))
                    index += 1
                }
                blocks.append(.list(ordered: ordered, items: items))
                continue
            }
            if line.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while index < lines.count, lines[index].hasPrefix(">") {
                    quoted.append(quoteBody(lines[index]))
                    index += 1
                }
                blocks.append(.quote(inlines(quoted.joined(separator: "\n"))))
                continue
            }
            paragraph.append(line)
            index += 1
        }
        flushParagraph()
        return blocks
    }

    static func plain(_ blocks: [Block]) -> String {
        blocks.map { block in
            switch block {
            case .heading(_, let text): return text
            case .paragraph(let inlines), .quote(let inlines): return plain(inlines)
            case .code(_, let source), .math(let source): return source
            case .list(_, let items): return items.map { plain($0) }.joined(separator: "\n")
            }
        }.joined(separator: "\n")
    }

    static func plain(_ inlines: [Inline]) -> String {
        inlines.map { inline in
            switch inline {
            case .text(let value), .code(let value), .math(let value), .strong(let value), .emphasis(let value):
                return value
            }
        }.joined()
    }

    private static func heading(_ line: String) -> Block? {
        let marks = line.prefix { $0 == "#" }
        guard (1...6).contains(marks.count), line.dropFirst(marks.count).hasPrefix(" ") else { return nil }
        return .heading(marks.count, String(line.dropFirst(marks.count + 1)))
    }

    private static func isListItem(_ line: String) -> Bool {
        if line.hasPrefix("- ") || line.hasPrefix("+ ") || (line.hasPrefix("* ") && !line.hasPrefix("**")) { return true }
        return line.range(of: #"^[0-9]{1,3}\. "#, options: .regularExpression) != nil
    }

    private static func listBody(_ line: String) -> String {
        if line.hasPrefix("- ") || line.hasPrefix("+ ") || line.hasPrefix("* ") { return String(line.dropFirst(2)) }
        guard let space = line.firstIndex(of: " ") else { return line }
        return String(line[line.index(after: space)...])
    }

    private static func quoteBody(_ line: String) -> String {
        var body = line.dropFirst()
        if body.hasPrefix(" ") { body = body.dropFirst() }
        return String(body)
    }

    static func inlines(_ block: String) -> [Inline] {
        let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var all: [Inline] = []
        for (offset, line) in lines.enumerated() {
            if offset > 0 { all.append(.text("\n")) }
            all.append(contentsOf: inlineLine(line))
        }
        return all
    }

    private static func inlineLine(_ line: String) -> [Inline] {
        var result: [Inline] = []
        var text = ""
        var index = line.startIndex
        func flush() {
            if !text.isEmpty { result.append(.text(text)); text = "" }
        }
        while index < line.endIndex {
            if line[index] == "`" {
                let rest = line[line.index(after: index)...]
                if let end = rest.firstIndex(of: "`") {
                    flush()
                    result.append(.code(String(rest[..<end])))
                    index = line.index(after: end)
                    continue
                }
            }
            if line[index...].hasPrefix("**"),
               let end = line[line.index(index, offsetBy: 2)...].range(of: "**") {
                flush()
                result.append(.strong(String(line[line.index(index, offsetBy: 2)..<end.lowerBound])))
                index = end.upperBound
                continue
            }
            if line[index] == "*", line.index(after: index) < line.endIndex {
                let rest = line[line.index(after: index)...]
                if let end = rest.firstIndex(of: "*"), end > rest.startIndex {
                    flush()
                    result.append(.emphasis(String(rest[..<end])))
                    index = line.index(after: end)
                    continue
                }
            }
            if line[index] == "$", line.index(after: index) < line.endIndex, line[line.index(after: index)] != "$" {
                let rest = line[line.index(after: index)...]
                if let end = rest.firstIndex(of: "$"), end > rest.startIndex, !rest[..<end].contains("\n") {
                    flush()
                    result.append(.math(String(rest[..<end])))
                    index = line.index(after: end)
                    continue
                }
            }
            if line[index] == "!" || line[index] == "[" {
                if let rendered = link(line, from: index) {
                    flush()
                    result.append(.text(rendered.text))
                    index = rendered.end
                    continue
                }
            }
            text.append(line[index])
            index = line.index(after: index)
        }
        flush()
        return result
    }

    /// `[label](url)` and `![alt](url)` become visible text. The URL is not opened.
    private static func link(_ line: String, from index: String.Index) -> (text: String, end: String.Index)? {
        var cursor = index
        if line[cursor] == "!" { cursor = line.index(after: cursor) }
        guard cursor < line.endIndex, line[cursor] == "[" else { return nil }
        guard let labelEnd = line[line.index(after: cursor)...].firstIndex(of: "]"),
              line.index(after: labelEnd) < line.endIndex, line[line.index(after: labelEnd)] == "(" else { return nil }
        let label = String(line[line.index(after: cursor)..<labelEnd])
        let urlStart = line.index(labelEnd, offsetBy: 2)
        guard let urlEnd = line[urlStart...].firstIndex(of: ")") else { return nil }
        let url = String(line[urlStart..<urlEnd])
        guard !label.isEmpty || !url.isEmpty else { return nil }
        let shown = url.isEmpty ? label : (label.isEmpty ? url : "\(label) (\(url))")
        return (shown, line.index(after: urlEnd))
    }
}

/// A small LaTeX subset rendered as Unicode. Unknown commands stay readable.
enum ChatMath {
    static func render(_ source: String) -> String {
        var output = ""
        var index = source.startIndex
        while index < source.endIndex {
            let character = source[index]
            if character == "\\" {
                let nameStart = source.index(after: index)
                var nameEnd = nameStart
                while nameEnd < source.endIndex, source[nameEnd].isLetter { nameEnd = source.index(after: nameEnd) }
                let name = String(source[nameStart..<nameEnd])
                if name == "frac" {
                    let (numerator, afterNumerator) = group(source, nameEnd)
                    let (denominator, afterDenominator) = group(source, afterNumerator)
                    output += render(numerator) + "⁄" + render(denominator)
                    index = afterDenominator
                    continue
                }
                if name == "sqrt" {
                    let (body, next) = group(source, nameEnd)
                    output += "√(" + render(body) + ")"
                    index = next
                    continue
                }
                if name == "left" || name == "right" {
                    index = nameEnd
                    if index < source.endIndex, "()[]{}|.".contains(source[index]) { index = source.index(after: index) }
                    continue
                }
                if let symbol = symbols[name] {
                    output += symbol
                    index = nameEnd
                    continue
                }
                if name.isEmpty, nameStart < source.endIndex {
                    output.append(source[nameStart])
                    index = source.index(after: nameStart)
                    continue
                }
                output += name.isEmpty ? "\\" : name
                index = nameEnd
                continue
            }
            if character == "^" || character == "_" {
                let (body, next) = groupOrCharacter(source, source.index(after: index))
                output += script(render(body), superscript: character == "^")
                index = next
                continue
            }
            if character == "{" || character == "}" {
                index = source.index(after: index)
                continue
            }
            output.append(character)
            index = source.index(after: index)
        }
        return output
    }

    private static func group(_ source: String, _ index: String.Index) -> (String, String.Index) {
        guard index < source.endIndex, source[index] == "{" else { return ("", index) }
        var depth = 0
        var cursor = index
        while cursor < source.endIndex {
            if source[cursor] == "{" { depth += 1 }
            if source[cursor] == "}" {
                depth -= 1
                if depth == 0 { return (String(source[source.index(after: index)..<cursor]), source.index(after: cursor)) }
            }
            cursor = source.index(after: cursor)
        }
        return (String(source[source.index(after: index)...]), source.endIndex)
    }

    private static func groupOrCharacter(_ source: String, _ index: String.Index) -> (String, String.Index) {
        guard index < source.endIndex else { return ("", index) }
        if source[index] == "{" { return group(source, index) }
        return (String(source[index]), source.index(after: index))
    }

    private static func script(_ text: String, superscript: Bool) -> String {
        let map = superscript ? superscripts : subscripts
        return text.map { map[String($0)] ?? String($0) }.joined()
    }

    private static let superscripts: [String: String] = Dictionary(uniqueKeysWithValues: zip(
        "0123456789+-=()ni".map(String.init), "⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻⁼⁽⁾ⁿⁱ".map(String.init)))
    private static let subscripts: [String: String] = Dictionary(uniqueKeysWithValues: zip(
        "0123456789+-=()aeox".map(String.init), "₀₁₂₃₄₅₆₇₈₉₊₋₌₍₎ₐₑₒₓ".map(String.init)))
    private static let symbols: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε",
        "theta": "θ", "lambda": "λ", "mu": "μ", "pi": "π", "sigma": "σ",
        "phi": "φ", "omega": "ω", "Gamma": "Γ", "Delta": "Δ", "Sigma": "Σ",
        "Omega": "Ω", "times": "×", "cdot": "·", "div": "÷", "pm": "±",
        "leq": "≤", "geq": "≥", "neq": "≠", "approx": "≈", "infty": "∞",
        "to": "→", "rightarrow": "→", "leftarrow": "←", "ldots": "…",
        "sum": "∑", "prod": "∏", "int": "∫", "partial": "∂", "nabla": "∇",
    ]
}

@MainActor
enum ChatClipboard {
    static func copy(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }
}

struct ChatAnswerView: View {
    let text: String
    var showsCopy = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsCopy {
                HStack {
                    Spacer()
                    Button { ChatClipboard.copy(text) } label: { Label("Copy answer", systemImage: "doc.on.doc") }
                        .labelStyle(.iconOnly)
                        .help("Copy answer")
                        .accessibilityIdentifier("malibu.chat.copy-answer")
                }
            }
            let blocks = ChatMarkdown.parse(text)
            if blocks.isEmpty {
                Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(text)
        .accessibilityIdentifier("malibu.chat.answer")
    }

    @ViewBuilder
    private func blockView(_ block: ChatMarkdown.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(text).font(level <= 2 ? .title3.weight(.semibold) : .headline)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        case .paragraph(let inlines), .quote(let inlines):
            inlineText(inlines).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, blockIsQuote(block) ? 10 : 0)
        case .code(let language, let source):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if !language.isEmpty { Text(language).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button { ChatClipboard.copy(source) } label: { Label("Copy code", systemImage: "doc.on.doc") }
                        .labelStyle(.iconOnly)
                        .help("Copy code")
                        .accessibilityIdentifier("malibu.chat.copy-code")
                }
                Text(source).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        case .math(let source):
            Text(ChatMath.render(source)).font(.system(.title3, design: .serif))
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("malibu.chat.math")
        case .list(let ordered, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(ordered ? "\(offset + 1)." : "•").foregroundStyle(.secondary)
                        inlineText(item).textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func blockIsQuote(_ block: ChatMarkdown.Block) -> Bool {
        if case .quote = block { return true }
        return false
    }

    private func inlineText(_ inlines: [ChatMarkdown.Inline]) -> Text {
        inlines.reduce(Text("")) { result, inline in
            switch inline {
            case .text(let value): return result + Text(value)
            case .code(let value): return result + Text(value).font(.system(.body, design: .monospaced))
            case .math(let value): return result + Text(ChatMath.render(value)).font(.system(.body, design: .serif))
            case .strong(let value): return result + Text(value).bold()
            case .emphasis(let value): return result + Text(value).italic()
            }
        }
    }
}
