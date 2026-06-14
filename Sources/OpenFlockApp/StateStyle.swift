import SwiftUI
import FlockCore

/// The single source of truth for how each agent state looks and reads —
/// shared by the menu-bar label, the panel header, and the session rows.
extension AgentState {
    var color: Color {
        switch self {
        case .working: .green
        case .waiting: .yellow
        case .blocked: .red
        case .stale: Color.secondary.opacity(0.4)
        }
    }

    /// Monochrome glyph (tinted with `color`) — chosen as a matched-weight
    /// filled-shape family: ▲ go, ● paused, ■ stopped.
    var glyph: String {
        switch self {
        case .working: "▲"
        case .waiting: "●"
        case .blocked: "■"
        case .stale: "·"
        }
    }

    var label: String {
        switch self {
        case .working: "working"
        case .waiting: "waiting"
        case .blocked: "blocked"
        case .stale: "stale"
        }
    }
}
