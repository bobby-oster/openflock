import SwiftUI
import FlockCore

/// Panel component visibility, persisted across launches.
enum ComponentToggles {
    static let throughput = "component.throughput"
    static let sessionList = "component.sessionList"
    static let menuBarRate = "component.menuBarRate"
}

struct FlockPanel: View {
    let model: FlockModel

    @AppStorage(ComponentToggles.throughput) private var showThroughput = true
    @AppStorage(ComponentToggles.sessionList) private var showSessionList = true
    @AppStorage(ComponentToggles.menuBarRate) private var showMenuBarRate = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if showThroughput {
                Divider()
                throughput
            }
            if showSessionList {
                Divider()
                if model.sessions.isEmpty {
                    Text("No agent sessions in the last 24h")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 24)
                } else {
                    sessionList(showProducerBadges: model.hasMultipleProducers)
                }
            }
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 360)
    }

    private var header: some View {
        HStack {
            Text("OpenFlock")
                .font(.headline)
            Spacer()
            Text(headerSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Attention-first counts, zero states omitted: "1 blocked · 2 working · 5 agents".
    private var headerSummary: String {
        var parts: [String] = []
        if model.blockedCount > 0 { parts.append("\(model.blockedCount) blocked") }
        if model.waitingCount > 0 { parts.append("\(model.waitingCount) waiting") }
        if model.workingCount > 0 { parts.append("\(model.workingCount) working") }
        if model.staleCount > 0 { parts.append("\(model.staleCount) stale") }
        parts.append("\(model.agentCount) agents")
        return parts.joined(separator: " · ")
    }

    private var throughput: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.fill")
                .foregroundStyle(.orange)
                .font(.caption)
            VStack(alignment: .leading, spacing: 1) {
                Text(Format.rate(perSecond: model.freshPerSecondNow))
                    .font(.callout)
                    .monospacedDigit()
                Text("now · \(Format.rateCompact(perSecond: model.totalPerSecondNow)) w/ cache")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(Format.tokens(Int(model.freshPerMinute10m)))/min")
                    .font(.callout)
                    .monospacedDigit()
                Text("10m avg")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func sessionList(showProducerBadges: Bool) -> some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(model.sessions) { session in
                    SessionRow(session: session, showProducerBadge: showProducerBadges, model: model)
                }
            }
        }
        // ScrollView collapses to zero height inside a MenuBarExtra window
        // unless given an explicit frame.
        .frame(height: min(CGFloat(model.sessions.count) * 42, 320))
    }

    private var footer: some View {
        HStack {
            if let lastScan = model.lastScan {
                Text("Updated \(lastScan, style: .relative) ago")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Menu {
                Toggle("Throughput", isOn: $showThroughput)
                Toggle("Session list", isOn: $showSessionList)
                Toggle("Burn rate in menu bar", isOn: $showMenuBarRate)
            } label: {
                Image(systemName: "switch.2")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .controlSize(.small)
        }
    }
}

struct SessionRow: View {
    let session: AgentSession
    let showProducerBadge: Bool
    let model: FlockModel
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(session.effectiveState.color)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(session.projectName)
                        .font(.callout)
                        .lineLimit(1)
                    if showProducerBadge {
                        Text(session.producer.badgeLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(.secondary.opacity(0.35), lineWidth: 1)
                            )
                    }
                }
                Text(subtitle)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .help(session.slug ?? session.rawSessionId)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(session.usage.isKnown ? "\(Format.tokens(session.usage.outputTokens)) out" : "— out")
                    .font(.callout)
                    .monospacedDigit()
                (Text("\(session.usage.isKnown ? "Σ\(Format.tokens(session.usage.total))" : "Σ—") · ")
                    + Text(session.lastActivity, style: .relative))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            dismissControl
                .frame(width: 18)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    /// Hover-revealed and bi-directional: ✕ to dismiss a waiting/blocked
    /// session, ↩ to restore a dismissed one. Working and auto-stale rows get an
    /// empty slot of the same width, so nothing shifts. The list is sorted by
    /// `lastActivity`, which a dismissal never changes — so the row never moves
    /// out from under the cursor.
    @ViewBuilder private var dismissControl: some View {
        if session.isDismissed {
            rowButton(symbol: "arrow.uturn.backward", help: "Restore — track this session again") {
                model.restore(session)
            }
        } else if session.state == .waiting || session.state == .blocked {
            rowButton(symbol: "xmark", help: "Dismiss — stop counting this session") {
                model.dismiss(session)
            }
        } else {
            Color.clear
        }
    }

    private func rowButton(symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        // Revealed on hover; hidden (and non-clickable) otherwise.
        .opacity(isHovered ? 1 : 0)
        .disabled(!isHovered)
    }

    private var subtitle: AttributedString {
        var parts: [String] = []
        if let model = session.model { parts.append(Format.modelShortName(model)) }
        if session.subagentCount > 0 {
            var sub = "\(session.subagentCount) subagents"
            if session.activeSubagentCount > 0 { sub += " (\(session.activeSubagentCount) active)" }
            parts.append(sub)
        }
        let detail = parts.isEmpty ? "unknown model" : parts.joined(separator: " · ")

        var result = AttributedString()
        // Lead the actionable states with a colored word; working/stale don't
        // need one — the dot already says it.
        if session.effectiveState == .blocked || session.effectiveState == .waiting {
            var badge = AttributedString(session.effectiveState.label + " · ")
            badge.foregroundColor = session.effectiveState.color
            result += badge
        }
        var rest = AttributedString(detail)
        rest.foregroundColor = .secondary
        result += rest
        return result
    }
}

private extension TranscriptProducer {
    var badgeLabel: String {
        switch self {
        case .claudeCode: "Claude"
        case .codex: "Codex"
        }
    }
}
