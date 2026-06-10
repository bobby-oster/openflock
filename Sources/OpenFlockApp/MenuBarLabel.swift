import SwiftUI
import FlockCore

struct MenuBarLabel: View {
    let model: FlockModel
    @AppStorage(ComponentToggles.menuBarRate) private var showMenuBarRate = false

    var body: some View {
        Text(text)
            .monospacedDigit()
    }

    private var text: String {
        var summary = model.menuBarSummary
        if showMenuBarRate, model.snapshot != nil {
            summary += " " + Format.rateCompact(perSecond: model.totalPerSecondNow)
        }
        return summary
    }
}
