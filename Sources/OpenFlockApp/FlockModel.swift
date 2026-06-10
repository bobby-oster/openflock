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

    var sessions: [AgentSession] { snapshot?.sessions ?? [] }
    var lastScan: Date? { snapshot?.scannedAt }

    var activeCount: Int { sessions.filter { $0.state == .active }.count }
    var idleCount: Int { sessions.filter { $0.state == .idle }.count }

    /// Sessions plus their sub-agents.
    var agentCount: Int { sessions.reduce(0) { $0 + 1 + $1.subagentCount } }

    var totalTokens: Int { sessions.reduce(0) { $0 + $1.usage.total } }

    /// Burn rate over the last minute, in output tokens/second.
    var outputPerSecondNow: Double {
        snapshot?.outputTokensPerSecond(window: 60, now: Date()) ?? 0
    }

    /// Trailing 10-minute average, in output tokens/minute.
    var outputPerMinute10m: Double {
        snapshot?.outputTokensPerMinute(window: 600, now: Date()) ?? 0
    }

    /// e.g. "3▲ 2●" — active and idle counts; app name before first scan.
    var menuBarSummary: String {
        guard snapshot != nil else { return "OpenFlock" }
        return "\(activeCount)▲ \(idleCount)●"
    }
}
