import Foundation

// AUDIT R1 ARCHITECT A1 / A5 fix.
//
// AgentSnapshot is now a pure domain type — no localized/formatted strings.
// - Earnings/metrics are Optional so "not reported yet" is distinct from "0".
//   The CLI stub returns 0/0/0 today; rendering that as authoritative "$0.00"
//   masked the "unimplemented" reality to the user.
// - View strings (menu-bar label, status line, earnings line) live in
//   AgentSnapshotPresenter so future locale/currency work touches one place.

struct AgentSnapshot: Equatable {
    enum State: String { case idle, starting, serving, paused, reconnecting, error }
    var state: State
    var currentModelID: String?
    var earningsUsdcToday: Double?
    var malibuAccruedToday: Double?
    var uptimeSec: Int?
    var lastError: String?

    // Whether the CLI has explicitly acknowledged a pause; distinct from
    // "we optimistically flipped the UI" — pauseAck accepted:false must NOT
    // leave the UI showing Paused.
    var pauseAcknowledged: Bool

    static let empty = AgentSnapshot(
        state: .idle,
        currentModelID: nil,
        earningsUsdcToday: nil,
        malibuAccruedToday: nil,
        uptimeSec: nil,
        lastError: nil,
        pauseAcknowledged: false
    )
}

enum AgentSnapshotPresenter {
    static func short(_ s: AgentSnapshot) -> String {
        switch s.state {
        case .idle, .starting: return "Idle"
        case .serving:
            if let usdc = s.earningsUsdcToday { return String(format: "$%.2f", usdc) }
            return "—"
        case .paused:         return "Paused"
        case .reconnecting:   return "…"
        case .error:          return "!"
        }
    }

    static func stateLine(_ s: AgentSnapshot) -> String {
        switch s.state {
        case .idle:         return "Not running"
        case .starting:     return "Starting…"
        case .serving:      return "Serving " + (s.currentModelID ?? "model")
        case .paused:       return "Paused"
        case .reconnecting: return "Reconnecting…"
        case .error:        return s.lastError ?? "Error"
        }
    }

    static func earningsLine(_ s: AgentSnapshot) -> String {
        // AUDIT R1 ARCHITECT A1: distinguish "no data yet" from "$0.00".
        switch (s.earningsUsdcToday, s.malibuAccruedToday) {
        case (nil, nil):
            return "Today: — USDC · — MALIBU (metrics not implemented)"
        case let (usdc?, malibu?):
            return String(format: "Today: $%.2f USDC · %.2f MALIBU", usdc, malibu)
        case let (usdc?, nil):
            return String(format: "Today: $%.2f USDC · — MALIBU", usdc)
        case let (nil, malibu?):
            return String(format: "Today: — USDC · %.2f MALIBU", malibu)
        }
    }
}
