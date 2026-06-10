import Foundation
import Observation
import FlockCore

@Observable
@MainActor
final class FlockModel {
    private(set) var sessions: [AgentSession] = []
    private(set) var lastScan: Date?

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
            let now = Date()
            let scanned = scanner.scan(now: now)
            await MainActor.run { [weak self] in
                self?.sessions = scanned
                self?.lastScan = now
            }
        }
    }

    var activeCount: Int { sessions.filter { $0.state == .active }.count }
    var idleCount: Int { sessions.filter { $0.state == .idle }.count }

    /// Sessions plus their sub-agents.
    var agentCount: Int { sessions.reduce(0) { $0 + 1 + $1.subagentCount } }

    var totalTokens: Int { sessions.reduce(0) { $0 + $1.usage.total } }

    /// e.g. "3▲ 2●" — active and idle counts; "–" before first scan.
    var menuBarSummary: String {
        guard lastScan != nil else { return "OpenFlock" }
        return "\(activeCount)▲ \(idleCount)●"
    }
}
