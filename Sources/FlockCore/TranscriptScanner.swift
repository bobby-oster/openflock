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

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let eventCutoff = now.addingTimeInterval(-eventWindow)
        let cutoffString = formatter.string(from: eventCutoff)

        var files: [TranscriptFile] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard
                let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate,
                now.timeIntervalSince(modified) < recencyWindow,
                let file = parseTranscript(
                    at: url, modifiedAt: modified,
                    eventCutoffString: modified >= eventCutoff ? cutoffString : nil,
                    formatter: formatter)
            else { continue }
            files.append(file)
        }

        let sessions = Dictionary(grouping: files, by: \.sessionId).compactMap { id, members -> AgentSession? in
            guard let newest = members.max(by: { $0.lastActivity < $1.lastActivity }) else { return nil }
            let main = members.first { !$0.isSubagent }
            let subagents = members.filter(\.isSubagent)

            var usage = TokenUsage()
            for member in members { usage.add(member.usage) }

            let primary = main ?? newest
            return AgentSession(
                id: id,
                projectPath: primary.cwd ?? "?",
                slug: primary.slug,
                model: primary.model ?? newest.model,
                usage: usage,
                lastActivity: newest.lastActivity,
                state: AgentSession.state(forAge: now.timeIntervalSince(newest.lastActivity)),
                subagentCount: subagents.count,
                activeSubagentCount: subagents.filter {
                    AgentSession.state(forAge: now.timeIntervalSince($0.lastActivity)) == .active
                }.count
            )
        }
        return FlockSnapshot(
            sessions: sessions.sorted { $0.lastActivity > $1.lastActivity },
            recentEvents: files.flatMap(\.events),
            scannedAt: now
        )
    }

    /// One parsed transcript file — either a session's top-level transcript
    /// or a sub-agent transcript belonging to it.
    struct TranscriptFile {
        let sessionId: String
        let isSubagent: Bool
        let lastActivity: Date
        var cwd: String?
        var slug: String?
        var model: String?
        var usage = TokenUsage()
        var events: [TokenEvent] = []
    }

    /// `eventCutoffString` enables token-event collection: ISO8601 timestamps
    /// are lexicographically ordered, so a raw string compare filters old
    /// lines without the cost of date-parsing every one. Pass nil to skip.
    func parseTranscript(
        at url: URL, modifiedAt: Date,
        eventCutoffString: String? = nil,
        formatter: ISO8601DateFormatter? = nil
    ) -> TranscriptFile? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }

        let isSubagent = url.deletingLastPathComponent().lastPathComponent == "subagents"
            || url.lastPathComponent.hasPrefix("agent-")

        let decoder = JSONDecoder()
        var usage = TokenUsage()
        var events: [TokenEvent] = []
        var model: String?
        var sessionId: String?
        var cwd: String?
        var slug: String?

        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let entry = try? decoder.decode(TranscriptLine.self, from: Data(line)) else { continue }
            sessionId = entry.sessionId ?? sessionId
            cwd = entry.cwd ?? cwd
            slug = entry.slug ?? slug
            if let message = entry.message, entry.type == "assistant" {
                model = message.model ?? model
                if let u = message.usage {
                    usage.add(u.tokenUsage)
                    if let cutoff = eventCutoffString, let ts = entry.timestamp, ts > cutoff,
                       let date = formatter?.date(from: ts) {
                        events.append(TokenEvent(timestamp: date, outputTokens: u.outputTokens ?? 0))
                    }
                }
            }
        }

        var file = TranscriptFile(
            sessionId: sessionId ?? url.deletingPathExtension().lastPathComponent,
            isSubagent: isSubagent,
            lastActivity: modifiedAt
        )
        file.cwd = cwd
        file.slug = slug
        file.model = model
        file.usage = usage
        file.events = events
        return file
    }
}

/// One line of a transcript file. Top-level keys are camelCase; usage keys
/// are snake_case — hence the explicit CodingKeys on Usage only.
struct TranscriptLine: Decodable {
    struct Message: Decodable {
        let model: String?
        let usage: Usage?
    }

    struct Usage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheReadInputTokens: Int?
        let cacheCreationInputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
        }

        var tokenUsage: TokenUsage {
            var u = TokenUsage()
            u.inputTokens = inputTokens ?? 0
            u.outputTokens = outputTokens ?? 0
            u.cacheReadTokens = cacheReadInputTokens ?? 0
            u.cacheCreationTokens = cacheCreationInputTokens ?? 0
            return u
        }
    }

    let type: String?
    let sessionId: String?
    let cwd: String?
    let slug: String?
    let timestamp: String?
    let message: Message?
}
