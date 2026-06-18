import Foundation

/// What an agent is doing, inferred from the *shape* of the last model event
/// in its transcript — not from raw file-modification time. (Housekeeping
/// lines like titles and file-history snapshots bump mtime without the model
/// doing anything, and a single working turn can stay silent for many minutes;
/// both fool a pure-recency heuristic, so we read the transcript instead.)
///
/// This is the purely *derived* state. It pairs with one manual overlay — a
/// user *dismissal* (`AgentSession.isDismissed`), which forces a session to
/// read as `.stale` regardless of derivation; see `AgentSession.effectiveState`.
/// So "is this demanding attention?" has two ways to land on `.stale`: this
/// case means *inferred*-abandoned (automatic, past `staleThreshold`), whereas
/// a dismissal is *user*-asserted "done" (manual, reverses on new activity).
public enum AgentState: String, Sendable, CaseIterable {
    /// Mid-turn: the model is streaming output or running a tool. Green ▲.
    case working
    /// The last turn ended (`stop_reason: end_turn`) — waiting on you. Yellow ●.
    case waiting
    /// A tool call has been pending with no result past `blockedThreshold` —
    /// almost always an unanswered permission prompt. Red ■.
    case blocked
    /// No model activity for over `staleThreshold` — *inferred* as
    /// backgrounded/abandoned (automatic; the manual sibling is a user
    /// dismissal, which also reads as stale). Gray.
    case stale
}

public struct TokenUsage: Equatable, Sendable {
    public var inputTokens = 0
    public var outputTokens = 0
    public var cacheReadTokens = 0
    public var cacheCreationTokens = 0
    public var isKnown = false

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
        isKnown = isKnown || other.isKnown
    }
}

/// One agent session: the top-level transcript plus any sub-agent transcripts
/// that share its producer and session id.
public struct AgentSession: Identifiable, Sendable {
    /// Composite identity used by SwiftUI: `producer.rawValue:rawSessionId`.
    public let id: String
    /// Producer-specific session id for display.
    public let rawSessionId: String
    /// Agent runner that produced this session.
    public let producer: TranscriptProducer
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
    /// Whether the user has dismissed this session ("I'm no longer tracking
    /// this"). A manual overlay on the derived `state` — see `effectiveState`
    /// and `DismissalStore`. Any session can be dismissed; new model activity
    /// clears it automatically, so a live agent never stays hidden.
    public let isDismissed: Bool
    /// Sub-agent transcripts seen within the scan window.
    public let subagentCount: Int
    /// Sub-agents currently in the `.working` state.
    public let activeSubagentCount: Int

    public var projectName: String {
        URL(fileURLWithPath: projectPath).lastPathComponent
    }

    /// The state the UI and the attention counts should use: a dismissed
    /// session reads as `.stale` (out of the count, grey, no label) while the
    /// purely-derived `state` stays available for introspection.
    public var effectiveState: AgentState { isDismissed ? .stale : state }

    /// The shape of the last model event in a transcript — the input to state
    /// classification. Derived from `stop_reason` and whether a tool call is
    /// still awaiting its result.
    public enum LastEvent: Sendable {
        /// Streaming output, or a tool result just landed — model is producing.
        case streaming
        /// The turn is settled and nothing is streaming: either the model ended
        /// its turn (`stop_reason: end_turn`) or the user sent a prompt the
        /// model has not started answering. Both read as `.waiting`.
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

    /// Grace beyond a dismissal's recorded `lastActivity` within which a session
    /// is still treated as dismissed. Wide enough to absorb sub-second
    /// timestamp-serialization drift through the store, far tighter than the gap
    /// before any genuine resumption (which lands seconds+ later), so it never
    /// masks real activity.
    public static let dismissalActivityTolerance: TimeInterval = 1

    /// Whether a session is *effectively dismissed*: the user marked it
    /// dismissed and no new model activity has landed since. Any state can be
    /// dismissed — the activity key is the safety net. Dismissing a genuinely
    /// `.working` session is harmless: its next model event advances
    /// `lastActivity` past `dismissedAt` and auto-undismisses it, so a live,
    /// token-burning agent can never stay hidden — a dismissal only *sticks* on
    /// a session that has actually gone quiet. Activity-keyed: a `lastActivity`
    /// past `dismissedAt` (beyond the tolerance) clears it.
    public static func isDismissed(
        lastActivity: Date, dismissedAt: Date?
    ) -> Bool {
        guard let dismissedAt else { return false }
        return lastActivity.timeIntervalSince(dismissedAt) <= dismissalActivityTolerance
    }
}
