import AppKit

/// Shared presentation helpers for the menu-bar status item (#664).
enum MenuBarPresentation {
    /// Icon-only: never put Serving / earnings / badges beside the glyph.
    static func buttonTitle(for snapshot: AgentSnapshot, dismissedThreshold: Double?) -> String {
        _ = snapshot
        _ = dismissedThreshold
        return ""
    }

    static var statusItemLength: CGFloat { NSStatusItem.squareLength }

    static var brandIdentity: String { MalibuBrand.constructionMarkIdentity }
}
