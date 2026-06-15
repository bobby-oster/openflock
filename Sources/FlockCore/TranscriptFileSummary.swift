import Foundation

/// One parsed transcript file, either a session's top-level transcript or a
/// sub-agent transcript belonging to it.
public struct TranscriptFileSummary: Sendable {
    public let producer: TranscriptProducer
    public let sessionId: String
    public let isSubagent: Bool
    /// Timestamp of the last model event, not the file's mtime.
    public let lastActivity: Date
    /// Shape of that last model event, for state classification.
    public var lastEvent: AgentSession.LastEvent?
    public var cwd: String?
    public var slug: String?
    public var model: String?
    public var usage: TokenUsage
    public var events: [TokenEvent]

    public init(
        producer: TranscriptProducer = .claudeCode,
        sessionId: String,
        isSubagent: Bool,
        lastActivity: Date,
        lastEvent: AgentSession.LastEvent? = nil,
        cwd: String? = nil,
        slug: String? = nil,
        model: String? = nil,
        usage: TokenUsage = TokenUsage(),
        events: [TokenEvent] = []
    ) {
        self.producer = producer
        self.sessionId = sessionId
        self.isSubagent = isSubagent
        self.lastActivity = lastActivity
        self.lastEvent = lastEvent
        self.cwd = cwd
        self.slug = slug
        self.model = model
        self.usage = usage
        self.events = events
    }
}
