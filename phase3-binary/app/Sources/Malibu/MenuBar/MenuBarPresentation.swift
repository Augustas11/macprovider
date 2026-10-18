import AppKit

/// Shared presentation helpers for the menu-bar status item (#664).
enum MenuBarPresentation {
    /// Icon-only: never put Serving / earnings / badges beside the glyph.
    static func buttonTitle(for snapshot: AgentSnapshot, dismissedThreshold: Double?) -> String {
        _ = snapshot
        _ = dismissedThreshold
        return ""
    }

    /// Variable length sized to the re-cut glyph, so AppKit never shrinks it.
    static var statusItemLength: CGFloat { NSStatusItem.variableLength }

    /// State badge for the glyph. Colour is never the only signal: each state
    /// also has its own VoiceOver label.
    static func badge(for snapshot: AgentSnapshot) -> MalibuMenuBarIcon.Badge {
        if snapshot.state == .paused { return .paused }
        if snapshot.thermalState?.isMenuBarAttention == true { return .attention }
        return AgentSnapshotPresenter.statusPill(snapshot).tone == .attention ? .attention : .none
    }

    static var brandIdentity: String { MalibuBrand.constructionMarkIdentity }
}
