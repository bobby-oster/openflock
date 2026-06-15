import Foundation

/// Scans Claude Code transcripts (`~/.claude/projects/**/*.jsonl`) and
/// aggregates one `AgentSession` per session, folding sub-agent transcripts
/// (`<project>/<sessionId>/subagents/agent-*.jsonl`, which share the parent's
/// `sessionId`) into their parent session.
///
/// v0 re-reads matching files on every scan; incremental tailing comes later.
public struct TranscriptScanner: Sendable {
    public var projectsDirectory: URL
    /// Transcripts whose mtime is older than this window are skipped entirely.
    public var recencyWindow: TimeInterval
    /// How far back to collect per-turn token events for throughput math.
    public var eventWindow: TimeInterval

    public init(
        projectsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects"),
        recencyWindow: TimeInterval = 24 * 3600,
        eventWindow: TimeInterval = 15 * 60
    ) {
        self.projectsDirectory = projectsDirectory
        self.recencyWindow = recencyWindow
        self.eventWindow = eventWindow
    }

    public func scan(now: Date = Date()) -> FlockSnapshot {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: projectsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return FlockSnapshot(sessions: [], recentEvents: [], scannedAt: now) }

        // Share the parser's single millisecond-UTC formatter — the lexicographic
        // cutoff compare below depends on the same format the parser assumes.
        let formatter = ClaudeCodeTranscriptParser.defaultFormatter
        let eventCutoff = now.addingTimeInterval(-eventWindow)
        let cutoffString = formatter.string(from: eventCutoff)

        var options = ClaudeCodeTranscriptParser.Options()
        let parser = ClaudeCodeTranscriptParser()
        var files: [TranscriptFileSummary] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard
                let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate,
                now.timeIntervalSince(modified) < recencyWindow
            else { continue }
            options.eventCutoffString = modified >= eventCutoff ? cutoffString : nil
            guard let file = parser.parseFile(at: url, options: options) else { continue }
            files.append(file)
        }

        let sessions = Dictionary(grouping: files, by: \.sessionId).compactMap { id, members -> AgentSession? in
            guard let newest = members.max(by: { $0.lastActivity < $1.lastActivity }) else { return nil }
            let main = members.first { !$0.isSubagent }
            let subagents = members.filter(\.isSubagent)

            var usage = TokenUsage()
            for member in members { usage.add(member.usage) }

            let primary = main ?? newest
            func state(of file: TranscriptFileSummary) -> AgentState {
                AgentSession.state(last: file.lastEvent, age: now.timeIntervalSince(file.lastActivity))
            }
            return AgentSession(
                id: id,
                projectPath: primary.cwd ?? "?",
                slug: primary.slug,
                model: primary.model ?? newest.model,
                usage: usage,
                lastActivity: newest.lastActivity,
                // The most recently active member drives the session's state:
                // a running sub-agent keeps the session `.working` even while
                // the parent's Task tool call sits pending.
                state: state(of: newest),
                subagentCount: subagents.count,
                activeSubagentCount: subagents.filter { state(of: $0) == .working }.count
            )
        }
        // Empty shells (opened-and-abandoned sessions) are noise once stale.
        let visible = sessions.filter { !($0.usage.total == 0 && $0.state == .stale) }
        return FlockSnapshot(
            sessions: visible.sorted { $0.lastActivity > $1.lastActivity },
            recentEvents: files.flatMap(\.events),
            scannedAt: now
        )
    }
}
