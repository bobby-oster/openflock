import Foundation

/// Scans Claude Code transcripts (`~/.claude/projects/**/*.jsonl`) and
/// aggregates one `AgentSession` per transcript file.
///
/// v0 re-reads matching files on every scan; incremental tailing comes later.
public struct TranscriptScanner: Sendable {
    public var projectsDirectory: URL
    /// Transcripts whose mtime is older than this window are skipped entirely.
    public var recencyWindow: TimeInterval

    public init(
        projectsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects"),
        recencyWindow: TimeInterval = 24 * 3600
    ) {
        self.projectsDirectory = projectsDirectory
        self.recencyWindow = recencyWindow
    }

    public func scan(now: Date = Date()) -> [AgentSession] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: projectsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var sessions: [AgentSession] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard
                let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate,
                now.timeIntervalSince(modified) < recencyWindow,
                let session = parseTranscript(at: url, modifiedAt: modified, now: now)
            else { continue }
            sessions.append(session)
        }
        return sessions.sorted { $0.lastActivity > $1.lastActivity }
    }

    func parseTranscript(at url: URL, modifiedAt: Date, now: Date) -> AgentSession? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }

        let decoder = JSONDecoder()
        var usage = TokenUsage()
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
                if let u = message.usage { usage.add(u.tokenUsage) }
            }
        }

        guard let id = sessionId ?? Optional(url.deletingPathExtension().lastPathComponent) else { return nil }
        return AgentSession(
            id: id,
            projectPath: cwd ?? url.deletingLastPathComponent().lastPathComponent,
            slug: slug,
            model: model,
            usage: usage,
            lastActivity: modifiedAt,
            state: AgentSession.state(forAge: now.timeIntervalSince(modifiedAt))
        )
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
