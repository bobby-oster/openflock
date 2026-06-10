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
                    sessionList
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
            Text("\(model.activeCount) active · \(model.idleCount) idle · \(model.agentCount) agents")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var throughput: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.fill")
                .foregroundStyle(.orange)
                .font(.caption)
            Text(Format.rate(perSecond: model.outputPerSecondNow))
                .font(.callout)
                .monospacedDigit()
            Text("now")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(Format.tokens(Int(model.outputPerMinute10m)))/min")
                .font(.callout)
                .monospacedDigit()
            Text("10m avg")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var sessionList: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(model.sessions) { session in
                    SessionRow(session: session)
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

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(stateColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.slug ?? session.projectName)
                    .font(.callout)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(Format.tokens(session.usage.outputTokens)) out")
                    .font(.callout)
                    .monospacedDigit()
                (Text("Σ\(Format.tokens(session.usage.total)) · ")
                    + Text(session.lastActivity, style: .relative))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let model = session.model { parts.append(Format.modelShortName(model)) }
        if session.subagentCount > 0 {
            var sub = "\(session.subagentCount) subagents"
            if session.activeSubagentCount > 0 { sub += " (\(session.activeSubagentCount) active)" }
            parts.append(sub)
        }
        return parts.isEmpty ? "unknown model" : parts.joined(separator: " · ")
    }

    private var stateColor: Color {
        switch session.state {
        case .active: .green
        case .idle: .yellow
        case .stale: .secondary.opacity(0.4)
        }
    }
}
