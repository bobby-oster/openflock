import Foundation
import Observation
import FlockCore

@Observable
@MainActor
final class FlockModel {
    private(set) var snapshot: FlockSnapshot?

    private let scanner = TranscriptScanner()
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func refresh() {
        let scanner = self.scanner
        Task.detached(priority: .utility) {
            let scanned = scanner.scan()
            await MainActor.run { [weak self] in
                self?.snapshot = scanned
            }
        }
    }

    /// Dismiss a session ("I'm no longer tracking this") — it drops out of the
    /// attention count and reads as stale. Keyed to the session's current
    /// `lastActivity`, so fresh token usage on it auto-undismisses it.
    func dismiss(_ session: AgentSession) {
        var store = DismissalStore()
        store.dismiss(session.id, at: session.lastActivity)
        refresh()
    }

    /// Undo a dismissal — the session returns to its derived state and count.
    func restore(_ session: AgentSession) {
        var store = DismissalStore()
        store.restore(session.id)
        refresh()
    }

    var sessions: [AgentSession] { snapshot?.sessions ?? [] }
    var lastScan: Date? { snapshot?.scannedAt }
    var hasMultipleProducers: Bool { Set(sessions.map(\.producer)).count > 1 }

    // Counts use `effectiveState`, so a dismissed session drops out of the
    // attention counts (working/waiting/blocked) and reads as stale.
    var workingCount: Int { sessions.filter { $0.effectiveState == .working }.count }
    var waitingCount: Int { sessions.filter { $0.effectiveState == .waiting }.count }
    var blockedCount: Int { sessions.filter { $0.effectiveState == .blocked }.count }
    var staleCount: Int { sessions.filter { $0.effectiveState == .stale }.count }

    /// Sessions plus their sub-agents.
    var agentCount: Int { sessions.reduce(0) { $0 + 1 + $1.subagentCount } }

    var totalTokens: Int { sessions.reduce(0) { $0 + $1.usage.total } }

    /// Fresh burn rate (input + output, no cache) over the last minute, tokens/second.
    var freshPerSecondNow: Double {
        snapshot?.freshTokensPerSecond(window: 60, now: Date()) ?? 0
    }

    /// Full burn rate (cache included) over the last minute, tokens/second.
    var totalPerSecondNow: Double {
        snapshot?.totalTokensPerSecond(window: 60, now: Date()) ?? 0
    }

    /// Trailing 10-minute fresh-rate average, tokens/minute.
    var freshPerMinute10m: Double {
        snapshot?.freshTokensPerMinute(window: 600, now: Date()) ?? 0
    }

    /// Whether a scan has completed yet — the menu bar shows the app name
    /// until the first snapshot lands.
    var hasScanned: Bool { snapshot != nil }
}
