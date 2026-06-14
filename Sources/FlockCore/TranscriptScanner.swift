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
            func state(of file: TranscriptFile) -> AgentState {
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

    /// One parsed transcript file — either a session's top-level transcript
    /// or a sub-agent transcript belonging to it.
    struct TranscriptFile {
        let sessionId: String
        let isSubagent: Bool
        /// Timestamp of the last model event (not the file's mtime).
        let lastActivity: Date
        /// Shape of that last model event, for state classification.
        var lastEvent: AgentSession.LastEvent?
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
        // The shape and timestamp of the last conversation event (assistant
        // turn or user/tool-result line). Housekeeping lines — titles,
        // file-history snapshots, mode changes — are skipped so they can't
        // masquerade as model activity.
        var lastEvent: AgentSession.LastEvent?
        var lastEventTimestamp: String?

        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let entry = try? decoder.decode(TranscriptLine.self, from: Data(line)) else { continue }
            sessionId = entry.sessionId ?? sessionId
            cwd = entry.cwd ?? cwd
            slug = entry.slug ?? slug
            switch entry.type {
            case "assistant"?:
                guard let message = entry.message else { break }
                // Compaction and other injected turns carry "<synthetic>".
                if let m = message.model, m != "<synthetic>" { model = m }
                if let u = message.usage {
                    usage.add(u.tokenUsage)
                    if let cutoff = eventCutoffString, let ts = entry.timestamp, ts > cutoff,
                       let date = formatter?.date(from: ts) {
                        events.append(TokenEvent(timestamp: date, usage: u.tokenUsage))
                    }
                }
                if message.stopReason == "end_turn" {
                    lastEvent = .turnEnded
                } else if message.content?.containsToolUse == true {
                    lastEvent = .toolPending
                } else {
                    lastEvent = .streaming
                }
                lastEventTimestamp = entry.timestamp ?? lastEventTimestamp
            case "user"?:
                // A prompt or a tool result — either way the model is, or is
                // about to be, producing. Not a turn-ending event.
                lastEvent = .streaming
                lastEventTimestamp = entry.timestamp ?? lastEventTimestamp
            default:
                break  // housekeeping line — not model activity
            }
        }

        var file = TranscriptFile(
            sessionId: sessionId ?? url.deletingPathExtension().lastPathComponent,
            isSubagent: isSubagent,
            lastActivity: lastEventTimestamp.flatMap { formatter?.date(from: $0) } ?? modifiedAt
        )
        file.lastEvent = lastEvent
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
        let stopReason: String?
        let content: Content?

        enum CodingKeys: String, CodingKey {
            case model, usage, content
            case stopReason = "stop_reason"
        }
    }

    /// A message's `content` is either a plain string or an array of typed
    /// blocks. We only need to know whether a `tool_use` block is present.
    enum Content: Decodable {
        case text
        case blocks([Block])

        struct Block: Decodable { let type: String? }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let blocks = try? container.decode([Block].self) {
                self = .blocks(blocks)
            } else {
                self = .text
            }
        }

        var containsToolUse: Bool {
            if case .blocks(let blocks) = self {
                return blocks.contains { $0.type == "tool_use" }
            }
            return false
        }
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
