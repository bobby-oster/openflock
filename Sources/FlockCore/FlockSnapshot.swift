import Foundation

/// One assistant turn's tokens, timestamped — the unit of throughput.
public struct TokenEvent: Sendable {
    public let timestamp: Date
    public let outputTokens: Int
    /// Everything the turn moved: input + output + cache read/creation.
    public let totalTokens: Int

    public init(timestamp: Date, outputTokens: Int, totalTokens: Int) {
        self.timestamp = timestamp
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
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
        perMinute(window: window, now: now, of: \.outputTokens)
    }

    public func outputTokensPerSecond(window: TimeInterval = 60, now: Date? = nil) -> Double {
        outputTokensPerMinute(window: window, now: now) / 60
    }

    /// Full-throughput tokens per minute (cache included) over the window.
    public func totalTokensPerMinute(window: TimeInterval, now: Date? = nil) -> Double {
        perMinute(window: window, now: now, of: \.totalTokens)
    }

    public func totalTokensPerSecond(window: TimeInterval = 60, now: Date? = nil) -> Double {
        totalTokensPerMinute(window: window, now: now) / 60
    }

    private func perMinute(
        window: TimeInterval, now: Date?, of value: KeyPath<TokenEvent, Int>
    ) -> Double {
        guard window > 0 else { return 0 }
        let now = now ?? scannedAt
        let cutoff = now.addingTimeInterval(-window)
        let sum = recentEvents
            .filter { $0.timestamp >= cutoff && $0.timestamp <= now }
            .reduce(0) { $0 + $1[keyPath: value] }
        return Double(sum) / (window / 60)
    }
}
