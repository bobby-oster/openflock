import SwiftUI
import FlockCore

struct MenuBarLabel: View {
    let model: FlockModel

    var body: some View {
        Text(content)
            .monospacedDigit()
    }

    /// Attention first: blocked, then waiting, then working — zero counts and
    /// stale agents omitted, so a calm flock reads short and a stuck one jumps
    /// to the front. `MenuBarExtra` renders its label as a monochrome template
    /// image (foreground colors are dropped), so the state's *shape* carries
    /// the signal here — ▲ working, ● waiting, ■ blocked. Color lives in the
    /// panel, where it actually renders.
    private var content: String {
        guard model.hasScanned else { return "OpenFlock" }

        var segments: [String] = []
        for (count, state) in [
            (model.blockedCount, AgentState.blocked),
            (model.waitingCount, .waiting),
            (model.workingCount, .working),
        ] where count > 0 {
            segments.append("\(count)\(state.glyph)")
        }
        // Nothing needs attention (idle or only stale agents) → just the name.
        guard !segments.isEmpty else { return "OpenFlock" }

        var text = segments.joined(separator: " ")
        if model.showMenuBarRate {
            text += " " + Format.rateCompact(perSecond: model.freshPerSecondNow)
        }
        return text
    }
}
