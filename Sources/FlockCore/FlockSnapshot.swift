import Foundation

/// One assistant turn's output, timestamped — the unit of throughput.
public struct TokenEvent: Sendable {
    public let timestamp: Date
    public let outputTokens: Int

    public init(timestamp: Date, outputTokens: Int) {
        self.timestamp = timestamp
        self.outputTokens = outputTokens
    }
}

/// Result of one scan: the session list plus recent token events for
/// throughput math.
public struct FlockSnapshot: Sendable {
    public let sessions: [AgentSession]
    /// Assistant-turn events across all sessions within the scanner's
    /// event window (newest scan only).
    public let recentEvents: [TokenEvent]
    public let scannedAt: Date

    public init(sessions: [AgentSession], recentEvents: [TokenEvent], scannedAt: Date) {
        self.sessions = sessions
        self.recentEvents = recentEvents
        self.scannedAt = scannedAt
    }

    /// Output tokens per minute over the trailing window.
    public func outputTokensPerMinute(window: TimeInterval, now: Date? = nil) -> Double {
        guard window > 0 else { return 0 }
        let now = now ?? scannedAt
        let cutoff = now.addingTimeInterval(-window)
        let sum = recentEvents
            .filter { $0.timestamp >= cutoff && $0.timestamp <= now }
            .reduce(0) { $0 + $1.outputTokens }
        return Double(sum) / (window / 60)
    }

    public func outputTokensPerSecond(window: TimeInterval = 60, now: Date? = nil) -> Double {
        outputTokensPerMinute(window: window, now: now) / 60
    }
}
