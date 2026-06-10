import Foundation

/// Activity state inferred from transcript recency.
/// Blocked detection (unanswered permission request as the last transcript
/// event) is a planned refinement; recency is the v0 heuristic.
public enum AgentState: String, Sendable, CaseIterable {
    /// Transcript written to within the last minute.
    case active
    /// Recent session, but no writes for over a minute.
    case idle
    /// No writes for over an hour.
    case stale
}

public struct TokenUsage: Equatable, Sendable {
    public var inputTokens = 0
    public var outputTokens = 0
    public var cacheReadTokens = 0
    public var cacheCreationTokens = 0

    public init() {}

    public var total: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens
    }

    /// Non-cache tokens: what the model freshly read and wrote this turn.
    public var fresh: Int { inputTokens + outputTokens }

    public mutating func add(_ other: TokenUsage) {
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        cacheReadTokens += other.cacheReadTokens
        cacheCreationTokens += other.cacheCreationTokens
    }
}

/// One Claude Code session: the top-level transcript plus any sub-agent
/// transcripts (`<sessionId>/subagents/agent-*.jsonl`) that share its id.
public struct AgentSession: Identifiable, Sendable {
    /// Claude Code session id (top-level transcript filename stem).
    public let id: String
    /// Working directory the session runs in.
    public let projectPath: String
    /// Human-readable session slug, when the transcript provides one.
    public let slug: String?
    /// Most recent model seen in the top-level transcript.
    public let model: String?
    /// Aggregate usage across the session and all its sub-agents.
    public let usage: TokenUsage
    /// Most recent write across the session and all its sub-agents.
    public let lastActivity: Date
    public let state: AgentState
    /// Sub-agent transcripts seen within the scan window.
    public let subagentCount: Int
    /// Sub-agents whose transcript was written to within the last minute.
    public let activeSubagentCount: Int

    public var projectName: String {
        URL(fileURLWithPath: projectPath).lastPathComponent
    }

    public static func state(forAge age: TimeInterval) -> AgentState {
        switch age {
        case ..<60: .active
        case ..<3600: .idle
        default: .stale
        }
    }
}
