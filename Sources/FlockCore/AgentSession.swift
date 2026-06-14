import Foundation

/// What an agent is doing, inferred from the *shape* of the last model event
/// in its transcript — not from raw file-modification time. (Housekeeping
/// lines like titles and file-history snapshots bump mtime without the model
/// doing anything, and a single working turn can stay silent for many minutes;
/// both fool a pure-recency heuristic, so we read the transcript instead.)
public enum AgentState: String, Sendable, CaseIterable {
    /// Mid-turn: the model is streaming output or running a tool. Green ▲.
    case working
    /// The last turn ended (`stop_reason: end_turn`) — waiting on you. Yellow ●.
    case waiting
    /// A tool call has been pending with no result past `blockedThreshold` —
    /// almost always an unanswered permission prompt. Red ■.
    case blocked
    /// No model activity for over `staleThreshold` — backgrounded/abandoned. Gray.
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
    /// Timestamp of the most recent *model* event (assistant turn or tool
    /// result) across the session and its sub-agents — not the file's mtime,
    /// which housekeeping writes bump without the model doing anything.
    public let lastActivity: Date
    public let state: AgentState
    /// Sub-agent transcripts seen within the scan window.
    public let subagentCount: Int
    /// Sub-agents currently in the `.working` state.
    public let activeSubagentCount: Int

    public var projectName: String {
        URL(fileURLWithPath: projectPath).lastPathComponent
    }

    /// The shape of the last model event in a transcript — the input to state
    /// classification. Derived from `stop_reason` and whether a tool call is
    /// still awaiting its result.
    public enum LastEvent: Sendable {
        /// Streaming output, or a tool result just landed — model is producing.
        case streaming
        /// `stop_reason: end_turn` — the turn finished, waiting on the user.
        case turnEnded
        /// A tool call with no result yet — running if fresh, blocked if not.
        case toolPending
    }

    /// A pending tool call older than this is treated as blocked (an
    /// unanswered permission prompt). Sits above the p99 tool latency (~65s),
    /// so genuinely slow tools rarely trip it — and when they do, the next
    /// scan clears it the moment the result lands.
    public static let blockedThreshold: TimeInterval = 90
    /// No model activity for longer than this ⇒ stale (backgrounded/abandoned).
    public static let staleThreshold: TimeInterval = 3600

    /// Classify an agent from the shape of its last model event and how long
    /// ago that event occurred. A nil `last` means no model events at all.
    public static func state(last: LastEvent?, age: TimeInterval) -> AgentState {
        guard let last, age < staleThreshold else { return .stale }
        switch last {
        case .streaming: return .working
        case .turnEnded: return .waiting
        case .toolPending: return age < blockedThreshold ? .working : .blocked
        }
    }
}
