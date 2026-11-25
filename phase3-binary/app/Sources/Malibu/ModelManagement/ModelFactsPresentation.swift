import Foundation
import SwiftUI

/// SPEC-044-R015 capability badges, in display order.
enum MalibuModelCapability: String, CaseIterable, Identifiable, Sendable {
    case reasoning
    case tools
    case vision

    var id: String { rawValue }

    var title: String {
        switch self {
        case .reasoning: return String(localized: "Reasoning", comment: "Model capability badge: the model reasons before answering")
        case .tools: return String(localized: "Tools", comment: "Model capability badge: the model can call tools")
        case .vision: return String(localized: "Vision", comment: "Model capability badge: the model accepts images")
        }
    }
}

/// SPEC-044-R015 model facts as Malibu shows them. The CLI projection is the
/// only source; Malibu never infers a capability or a context window.
enum MalibuModelFacts {
    static let contextLengthRange = 1_024...16_777_216

    /// The capabilities Malibu knows, unique and sorted. An unknown value is
    /// dropped rather than rejected: facts are display only.
    static func knownCapabilities(_ raw: [String]) -> [String] {
        Array(Set(raw.filter { MalibuModelCapability(rawValue: $0) != nil })).sorted()
    }

    static func capabilities(_ raw: [String]) -> [MalibuModelCapability] {
        MalibuModelCapability.allCases.filter { raw.contains($0.rawValue) }
    }

    /// "256K", "1M", "40K": binary units, as model cards write context
    /// windows (262,144 tokens is "256K").
    static func contextShort(_ tokens: Int) -> String {
        let mebi = 1_048_576
        if tokens >= mebi, tokens % mebi == 0 { return "\(tokens / mebi)M" }
        if tokens >= mebi {
            return (Double(tokens) / Double(mebi)).formatted(.number.precision(.fractionLength(0...1))) + "M"
        }
        return "\(Int((Double(tokens) / 1_024).rounded()))K"
    }

    /// The row's context label, e.g. "256K context".
    static func contextLabel(_ row: MalibuModelRow) -> String? {
        row.contextLength.map {
            String(localized: "\(contextShort($0)) context", comment: "Model row: declared context window, e.g. 256K context")
        }
    }

    /// The detail pane's context value, e.g. "256K tokens (262,144)".
    static func contextDetail(_ tokens: Int) -> String {
        String(localized: "\(contextShort(tokens)) tokens (\(tokens.formatted()))", comment: "Model detail: declared context window")
    }

    static func badgeTitles(_ row: MalibuModelRow) -> [String] {
        row.capabilities.map(\.title)
    }

    /// Badges and context in one phrase for accessibility labels and
    /// rendered strings, e.g. "Reasoning, Tools, 256K context".
    static func summary(_ row: MalibuModelRow) -> String? {
        let parts = badgeTitles(row) + [contextLabel(row)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

/// SPEC-044-R015: a capability badge, tinted apart from status badges.
struct MalibuCapabilityBadge: View {
    let capability: MalibuModelCapability

    var body: some View {
        Text(capability.title)
            .font(.caption2.weight(.medium))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
            .fixedSize()
    }
}
