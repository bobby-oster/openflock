import Foundation

/// Parses one Codex JSONL rollout transcript into a file-level summary.
public struct CodexTranscriptParser {
    public static let defaultFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public struct Options {
        public var eventCutoff: Date?
        public var formatter: ISO8601DateFormatter

        public init(
            eventCutoff: Date? = nil,
            formatter: ISO8601DateFormatter = CodexTranscriptParser.defaultFormatter
        ) {
            self.eventCutoff = eventCutoff
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

        let decoder = JSONDecoder()
        var sessionId: String?
        var cwd: String?
        var model: String?
        var usage = TokenUsage()
        var events: [TokenEvent] = []
        var lastActivity: Date?
        var lastEvent: AgentSession.LastEvent?
        var openToolCalls = Set<String>()

        func parseTimestamp(_ timestamp: String?) -> Date? {
            timestamp.flatMap { options.formatter.date(from: $0) }
        }

        func markMeaningful(_ line: CodexTranscriptLine) {
            guard let date = parseTimestamp(line.timestamp) else { return }
            if lastActivity.map({ date >= $0 }) ?? true {
                lastActivity = date
            }
        }

        for lineData in data.split(separator: UInt8(ascii: "\n")) {
            guard let line = try? decoder.decode(CodexTranscriptLine.self, from: Data(lineData)) else {
                continue
            }

            switch line.type {
            case "session_meta":
                sessionId = line.payload.id ?? sessionId
                cwd = line.payload.cwd ?? cwd
                markMeaningful(line)
            case "turn_context":
                cwd = line.payload.cwd ?? cwd
                model = line.payload.model ?? model
                markMeaningful(line)
            case "response_item":
                switch line.payload.type {
                case "function_call", "custom_tool_call":
                    if let callId = line.payload.callId { openToolCalls.insert(callId) }
                    lastEvent = .toolPending
                    markMeaningful(line)
                case "function_call_output", "custom_tool_call_output":
                    if let callId = line.payload.callId { openToolCalls.remove(callId) }
                    lastEvent = openToolCalls.isEmpty ? .streaming : .toolPending
                    markMeaningful(line)
                case "message":
                    lastEvent = line.payload.role == "user" ? .streaming : .turnEnded
                    markMeaningful(line)
                case "reasoning":
                    lastEvent = .streaming
                    markMeaningful(line)
                default:
                    break
                }
            case "event_msg":
                switch line.payload.type {
                case "token_count":
                    if let tokenUsage = line.payload.info?.totalTokenUsage?.tokenUsage {
                        usage = tokenUsage
                    } else if let tokenUsage = line.payload.info?.lastTokenUsage?.tokenUsage {
                        usage.add(tokenUsage)
                    }
                    if let date = parseTimestamp(line.timestamp) {
                        markMeaningful(line)
                        if let cutoff = options.eventCutoff, date >= cutoff {
                            let eventUsage = line.payload.info?.lastTokenUsage?.tokenUsage
                                ?? line.payload.info?.totalTokenUsage?.tokenUsage
                            if let eventUsage {
                                events.append(TokenEvent(timestamp: date, usage: eventUsage))
                            }
                        }
                    }
                    lastEvent = openToolCalls.isEmpty ? .streaming : .toolPending
                case "agent_message":
                    lastEvent = line.payload.phase == "final" ? .turnEnded : .streaming
                    markMeaningful(line)
                default:
                    break
                }
            default:
                break
            }
        }

        guard let sessionId else { return nil }

        return TranscriptFileSummary(
            producer: .codex,
            sessionId: sessionId,
            isSubagent: false,
            lastActivity: lastActivity ?? modifiedAt,
            lastEvent: lastEvent,
            cwd: cwd,
            model: model,
            usage: usage,
            events: events
        )
    }
}

private struct CodexTranscriptLine: Decodable {
    struct Payload: Decodable {
        struct Info: Decodable {
            let lastTokenUsage: Usage?
            let totalTokenUsage: Usage?

            enum CodingKeys: String, CodingKey {
                case lastTokenUsage = "last_token_usage"
                case totalTokenUsage = "total_token_usage"
            }
        }

        struct Usage: Decodable {
            let inputTokens: Int?
            let cachedInputTokens: Int?
            let outputTokens: Int?
            let reasoningOutputTokens: Int?

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case cachedInputTokens = "cached_input_tokens"
                case outputTokens = "output_tokens"
                case reasoningOutputTokens = "reasoning_output_tokens"
            }

            var tokenUsage: TokenUsage {
                var usage = TokenUsage()
                usage.isKnown = true
                usage.inputTokens = inputTokens ?? 0
                usage.outputTokens = (outputTokens ?? 0) + (reasoningOutputTokens ?? 0)
                usage.cacheReadTokens = cachedInputTokens ?? 0
                return usage
            }
        }

        let id: String?
        let cwd: String?
        let model: String?
        let type: String?
        let role: String?
        let phase: String?
        let callId: String?
        let info: Info?

        enum CodingKeys: String, CodingKey {
            case id, cwd, model, type, role, phase, info
            case callId = "call_id"
        }
    }

    let type: String?
    let timestamp: String?
    let payload: Payload
}
