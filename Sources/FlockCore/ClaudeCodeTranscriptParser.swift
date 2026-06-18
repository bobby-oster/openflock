import Foundation

/// Parses one Claude Code JSONL transcript into a file-level summary.
public struct ClaudeCodeTranscriptParser {
    /// Claude Code timestamps are uniformly millisecond-precision UTC
    /// (`YYYY-MM-DDTHH:MM:SS.mmmZ`). A formatter without `.withFractionalSeconds`
    /// fails to parse every one of them, so `lastActivity` would fall back to the
    /// file mtime and token events would never be collected. `TranscriptScanner`
    /// also relies on this exact format for its lexicographic event-cutoff compare.
    /// This is the single source of truth for that format; keep callers on it.
    public static let defaultFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public struct Options {
        public var eventCutoffString: String?
        public var formatter: ISO8601DateFormatter

        public init(
            eventCutoffString: String? = nil,
            formatter: ISO8601DateFormatter = ClaudeCodeTranscriptParser.defaultFormatter
        ) {
            self.eventCutoffString = eventCutoffString
            self.formatter = formatter
        }
    }

    public init() {}

    public func parseFile(at url: URL, options: Options = Options()) -> TranscriptFileSummary? {
        guard
            let modifiedAt = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate,
            let data = try? Data(contentsOf: url)
        else { return nil }

        return parse(data: data, from: url, modifiedAt: modifiedAt, options: options)
    }

    func parse(
        data: Data,
        from url: URL,
        modifiedAt: Date,
        options: Options = Options()
    ) -> TranscriptFileSummary? {
        guard !data.isEmpty else { return nil }

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
        // turn or user/tool-result line). Housekeeping lines are skipped so
        // they cannot masquerade as model activity.
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
                    if let cutoff = options.eventCutoffString, let ts = entry.timestamp, ts > cutoff,
                       let date = options.formatter.date(from: ts) {
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
                // A `user` line carries the user's role, but not every one is a
                // human turn or model activity. Skip the lines that are neither,
                // so they cannot masquerade as activity:
                //   • injected meta lines (`isMeta`) — system reminders, etc.
                //   • CLI control artifacts — slash-command echoes, local-command
                //     output, interrupt markers — matched on Claude Code's
                //     wrapper tags, not any specific command.
                // Skipping leaves the session resting on its prior model event,
                // so a finished turn followed only by, say, a `/exit` echo stays
                // `.waiting` (and dismissable) instead of being revived as
                // activity. Anything that remains — a fresh prompt or a
                // tool_result — means the model is, or is about to be, producing,
                // so a reply flips the session back to working immediately.
                if entry.isMeta == true { break }
                if entry.message?.content?.isControlArtifact == true { break }
                lastEvent = .streaming
                lastEventTimestamp = entry.timestamp ?? lastEventTimestamp
            default:
                break
            }
        }

        return TranscriptFileSummary(
            sessionId: sessionId ?? url.deletingPathExtension().lastPathComponent,
            isSubagent: isSubagent,
            lastActivity: lastEventTimestamp.flatMap { options.formatter.date(from: $0) } ?? modifiedAt,
            lastEvent: lastEvent,
            cwd: cwd,
            slug: slug,
            model: model,
            usage: usage,
            events: events
        )
    }
}

/// One line of a transcript file. Top-level keys are camelCase; usage keys
/// are snake_case, hence the explicit CodingKeys on Usage only.
private struct TranscriptLine: Decodable {
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
    /// blocks. We inspect it for a `tool_use` block and for the textual content
    /// used to recognize CLI control artifacts.
    enum Content: Decodable {
        case text(String)
        case blocks([Block])

        struct Block: Decodable {
            let type: String?
            let text: String?
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let blocks = try? container.decode([Block].self) {
                self = .blocks(blocks)
            } else if let string = try? container.decode(String.self) {
                self = .text(string)
            } else {
                self = .text("")
            }
        }

        var containsToolUse: Bool {
            if case .blocks(let blocks) = self {
                return blocks.contains { $0.type == "tool_use" }
            }
            return false
        }

        /// The textual content, flattened across any text blocks, for marker tests.
        private var flatText: String {
            switch self {
            case .text(let string): return string
            case .blocks(let blocks): return blocks.compactMap(\.text).joined(separator: " ")
            }
        }

        /// A CLI-emitted control line that carries the `user` role but is not a
        /// human turn: a slash-command echo, local-command output, or an
        /// interrupt marker. Matched on Claude Code's wrapper tags, so it covers
        /// every command — and every user — rather than one prompting style.
        var isControlArtifact: Bool {
            let text = flatText
            let markers = [
                "<command-name>", "<command-message>", "<command-args>",
                "<local-command-stdout>", "<local-command-stderr>",
                "[Request interrupted",
            ]
            return markers.contains { text.contains($0) }
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
            u.isKnown = true
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
    /// Marks an injected housekeeping line (system reminders, command echoes)
    /// that carries the `user` role but is not a conversation event.
    let isMeta: Bool?
}
