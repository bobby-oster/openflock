import Foundation

/// Scans transcript sources and aggregates one `AgentSession` per producer
/// session, folding sub-agent transcripts that share `(producer, sessionId)`
/// into their parent session.
///
/// v0 re-reads matching files on every scan; incremental tailing comes later.
public struct TranscriptScanner: Sendable {
    public var projectsDirectory: URL
    /// Transcripts whose mtime is older than this window are skipped entirely.
    public var recencyWindow: TimeInterval
    /// How far back to collect per-turn token events for throughput math.
    public var eventWindow: TimeInterval
    public var sources: [any TranscriptSource]
    /// Directory holding the dismissal overlay (`dismissals.json`). Defaults to
    /// `~/.openflock` (or `$OPENFLOCK_HOME`); injected in tests for hermeticity.
    public var dismissalsDirectory: URL

    public init(
        projectsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects"),
        codexSessionsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions"),
        recencyWindow: TimeInterval = 24 * 3600,
        eventWindow: TimeInterval = 15 * 60,
        sources: [any TranscriptSource]? = nil,
        dismissalsDirectory: URL = DismissalStore.defaultDirectory
    ) {
        self.projectsDirectory = projectsDirectory
        self.recencyWindow = recencyWindow
        self.eventWindow = eventWindow
        self.dismissalsDirectory = dismissalsDirectory
        self.sources = sources ?? [
            ClaudeCodeTranscriptSource(
                projectsDirectory: projectsDirectory,
                recencyWindow: recencyWindow,
                eventWindow: eventWindow
            ),
            CodexTranscriptSource(
                sessionsDirectory: codexSessionsDirectory,
                recencyWindow: recencyWindow,
                eventWindow: eventWindow
            )
        ]
    }

    public func scan(now: Date = Date()) -> FlockSnapshot {
        var files: [TranscriptFileSummary] = []
        for source in sources {
            for candidate in source.candidateFiles(now: now) {
                guard let file = source.parse(candidate, now: now) else { continue }
                files.append(file)
            }
        }

        var store = DismissalStore(directory: dismissalsDirectory)
        let sessions = Dictionary(grouping: files, by: SessionKey.init).compactMap { key, members -> AgentSession? in
            guard let newest = members.max(by: { $0.lastActivity < $1.lastActivity }) else { return nil }
            let main = members.first { !$0.isSubagent }
            let subagents = members.filter(\.isSubagent)

            var usage = TokenUsage()
            for member in members { usage.add(member.usage) }

            let primary = main ?? newest
            func state(of file: TranscriptFileSummary) -> AgentState {
                AgentSession.state(last: file.lastEvent, age: now.timeIntervalSince(file.lastActivity))
            }
            let id = "\(key.producer.rawValue):\(key.sessionId)"
            // The most recently active member drives the session's state: a
            // running sub-agent keeps the session `.working` even while the
            // parent's Task tool call sits pending.
            let derived = state(of: newest)
            return AgentSession(
                id: id,
                rawSessionId: key.sessionId,
                producer: key.producer,
                projectPath: primary.cwd ?? "?",
                slug: primary.slug,
                model: primary.model ?? newest.model,
                usage: usage,
                lastActivity: newest.lastActivity,
                state: derived,
                isDismissed: AgentSession.isDismissed(
                    lastActivity: newest.lastActivity,
                    dismissedAt: store.dismissedAt(id)
                ),
                subagentCount: subagents.count,
                activeSubagentCount: subagents.filter { state(of: $0) == .working }.count
            )
        }
        // Forget dismissals for sessions that have aged out of the scan entirely.
        store.prune(keeping: Set(sessions.map(\.id)))
        // Empty shells (opened-and-abandoned sessions) are noise once stale.
        let visible = sessions.filter { !($0.usage.total == 0 && $0.state == .stale) }
        return FlockSnapshot(
            sessions: visible.sorted { $0.lastActivity > $1.lastActivity },
            recentEvents: files.flatMap(\.events),
            scannedAt: now
        )
    }
}

private struct SessionKey: Hashable {
    let producer: TranscriptProducer
    let sessionId: String

    init(_ file: TranscriptFileSummary) {
        self.producer = file.producer
        self.sessionId = file.sessionId
    }
}
