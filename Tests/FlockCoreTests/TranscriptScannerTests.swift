import XCTest
@testable import FlockCore

// Parser and scanner coverage matrix:
//
// Core cases:
// - simple assistant turn: testParsesSimpleSessionFixture
// - session id fallback from filename: testFallsBackToFilenameWhenSessionIdIsMissing
// - model detection: testParsesSimpleSessionFixture
// - synthetic model ignored: testIgnoresSyntheticModelName
// - token-usage aggregation: testGroupsSubagentsUnderParentSession
// - cache-read and cache-creation tokens: testCollectsRecentTokenEventsForThroughput,
//   testParsesSimpleSessionFixture
// - recent token-event collection: testCollectsRecentTokenEventsForThroughput
// - stale zero-token session filtered: testHidesStaleZeroTokenSessions
// - housekeeping lines ignored as activity: testHousekeepingWritesDoNotCountAsActivity
// - malformed JSON line skipped: testGroupsSubagentsUnderParentSession
// - missing optional fields tolerated: testToleratesMissingOptionalTranscriptFields
//
// Claude Code cases:
// - top-level session transcript: testParsesSimpleSessionFixture
// - subagent transcript grouped into parent session: testGroupsSubagentsUnderParentSession
// - active subagent keeps parent session working: testGroupsSubagentsUnderParentSession
// - permission prompt / pending tool call becomes blocked past threshold:
//   testPermissionPromptFixtureClassifiesAsBlocked
// - tool result clears pending or blocked state: testToolResultClearsPendingBlockedState
// - completed turn becomes waiting: testStateFromLastTranscriptEvent
//
// Codex cases:
// - completed Codex fixture: testParsesCompletedCodexFixture
// - active Codex fixture: testParsesActiveCodexFixture
// - missing token_count is shown as unknown usage: testCodexSessionWithoutTokenCountKeepsUsageUnknown
// - source discovery: testCodexSourceDiscoversNestedSessionFiles
// - parse failures isolated from Claude: testCodexParseFailureDoesNotBlockClaudeSessions
// Incremental scanner cases are deferred until incremental scanning exists: appends,
// partial lines, malformed appended lines, truncation, replacement, unchanged-file
// reuse, event aging, and stale-session recency behavior.
final class TranscriptScannerTests: XCTestCase {
    var projectsDir: URL!

    override func setUpWithError() throws {
        projectsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openflock-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: projectsDir)
    }

    private func writeTranscript(_ relativePath: String, lines: String) throws {
        let url = projectsDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try lines.data(using: .utf8)!.write(to: url)
    }

    private func claudeOnlyScanner() -> TranscriptScanner {
        TranscriptScanner(sources: [ClaudeCodeTranscriptSource(projectsDirectory: projectsDir)])
    }

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    private func fixtureFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private func assistantLine(
        session: String, cwd: String = "/Users/dev/myproject", slug: String? = nil,
        input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheCreation: Int = 0,
        stopReason: String = "end_turn", toolUse: Bool = false,
        timestamp: String = "2026-06-10T20:00:00.000Z"
    ) -> String {
        let slugField = slug.map { "\"slug\":\"\($0)\"," } ?? ""
        let contentField = toolUse ? "\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\"}]," : ""
        return """
        {"type":"assistant","sessionId":"\(session)","cwd":"\(cwd)",\(slugField)"timestamp":"\(timestamp)","message":{"model":"claude-fable-5",\(contentField)"stop_reason":"\(stopReason)","usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_read_input_tokens":\(cacheRead),"cache_creation_input_tokens":\(cacheCreation)}}}
        """
    }

    func testGroupsSubagentsUnderParentSession() throws {
        let now = Date()
        let recent = iso(now.addingTimeInterval(-5))
        try writeTranscript("proj/abc-123.jsonl", lines: """
        {"type":"user","sessionId":"abc-123","cwd":"/Users/dev/myproject","slug":"fix-the-bug","timestamp":"2026-06-10T20:00:00.000Z","message":{"role":"user"}}
        \(assistantLine(session: "abc-123", slug: "fix-the-bug", input: 100, output: 50, cacheRead: 1000, cacheCreation: 25, stopReason: "tool_use", timestamp: recent))
        not even json
        """)
        try writeTranscript("proj/abc-123/subagents/agent-a1.jsonl",
            lines: assistantLine(session: "abc-123", input: 10, output: 5, cacheRead: 100, stopReason: "tool_use", timestamp: recent))
        try writeTranscript("proj/abc-123/subagents/agent-a2.jsonl",
            lines: assistantLine(session: "abc-123", input: 1, output: 2, stopReason: "tool_use", timestamp: recent))
        // Unrelated second session in another project dir.
        try writeTranscript("other/def-456.jsonl",
            lines: assistantLine(session: "def-456", cwd: "/Users/dev/other", output: 7))

        let sessions = claudeOnlyScanner().scan(now: now).sessions

        XCTAssertEqual(sessions.count, 2)
        let s = try XCTUnwrap(sessions.first { $0.rawSessionId == "abc-123" })
        XCTAssertEqual(s.id, "claudeCode:abc-123")
        XCTAssertEqual(s.projectPath, "/Users/dev/myproject")
        XCTAssertEqual(s.producer, .claudeCode)
        XCTAssertEqual(s.slug, "fix-the-bug")
        XCTAssertEqual(s.model, "claude-fable-5")
        XCTAssertEqual(s.subagentCount, 2)
        XCTAssertEqual(s.activeSubagentCount, 2) // mid-turn ⇒ working
        XCTAssertEqual(s.usage.inputTokens, 111)
        XCTAssertEqual(s.usage.outputTokens, 57)
        XCTAssertEqual(s.usage.cacheReadTokens, 1100)
        XCTAssertEqual(s.usage.cacheCreationTokens, 25)
        XCTAssertEqual(s.state, .working)
        XCTAssertEqual(s.projectName, "myproject")

        let other = try XCTUnwrap(sessions.first { $0.rawSessionId == "def-456" })
        XCTAssertEqual(other.subagentCount, 0)
        XCTAssertEqual(other.usage.outputTokens, 7)
    }

    func testParsesTranscriptSummaryFromData() throws {
        let formatter = fixtureFormatter()
        let modifiedAt = try XCTUnwrap(formatter.date(from: "2026-06-10T20:00:00.000Z"))
        let url = URL(fileURLWithPath: "session-0001.jsonl")
        let data = """
        {"type":"user","sessionId":"session-0001","cwd":"/Users/dev/myproject","slug":"fix-the-bug","timestamp":"2026-06-10T20:00:00.000Z","message":{"role":"user"}}
        \(assistantLine(session: "session-0001", slug: "fix-the-bug", input: 12, output: 8, cacheRead: 30, cacheCreation: 4, stopReason: "end_turn", timestamp: "2026-06-10T20:01:00.000Z"))
        """.data(using: .utf8)!

        // Parse through the DEFAULT Options: this exercises the parser's built-in
        // formatter. If that default can't read millisecond timestamps, the
        // lastActivity assertion below fails (it falls back to modifiedAt).
        let summary = try XCTUnwrap(ClaudeCodeTranscriptParser().parse(
            data: data,
            from: url,
            modifiedAt: modifiedAt
        ))

        XCTAssertEqual(summary.sessionId, "session-0001")
        XCTAssertEqual(summary.producer, .claudeCode)
        XCTAssertFalse(summary.isSubagent)
        XCTAssertEqual(summary.cwd, "/Users/dev/myproject")
        XCTAssertEqual(summary.slug, "fix-the-bug")
        XCTAssertEqual(summary.model, "claude-fable-5")
        XCTAssertEqual(summary.usage.inputTokens, 12)
        XCTAssertEqual(summary.usage.outputTokens, 8)
        XCTAssertEqual(summary.usage.cacheReadTokens, 30)
        XCTAssertEqual(summary.usage.cacheCreationTokens, 4)
        XCTAssertEqual(summary.lastEvent, .turnEnded)
        XCTAssertEqual(summary.lastActivity, formatter.date(from: "2026-06-10T20:01:00.000Z"))
    }

    func testParsesSimpleSessionFixture() throws {
        let formatter = fixtureFormatter()
        let data = try TranscriptFixtureLoader.data(caseName: "simple-session")
        let modifiedAt = try XCTUnwrap(formatter.date(from: "2026-06-14T12:00:10.000Z"))

        let summary = try XCTUnwrap(ClaudeCodeTranscriptParser().parse(
            data: data,
            from: URL(fileURLWithPath: "simple-session.jsonl"),
            modifiedAt: modifiedAt
        ))

        XCTAssertEqual(summary.sessionId, "session-0001")
        XCTAssertEqual(summary.producer, .claudeCode)
        XCTAssertFalse(summary.isSubagent)
        XCTAssertEqual(summary.cwd, "/Users/dev/example")
        XCTAssertEqual(summary.slug, "example-task")
        XCTAssertEqual(summary.model, "claude-fable-5")
        XCTAssertEqual(summary.usage.inputTokens, 11)
        XCTAssertEqual(summary.usage.outputTokens, 7)
        XCTAssertEqual(summary.usage.cacheReadTokens, 23)
        XCTAssertEqual(summary.usage.cacheCreationTokens, 3)
        XCTAssertEqual(summary.lastEvent, .turnEnded)
    }

    func testParsesSubagentFixture() throws {
        let formatter = fixtureFormatter()
        let data = try TranscriptFixtureLoader.data(caseName: "subagents")
        let modifiedAt = try XCTUnwrap(formatter.date(from: "2026-06-14T12:01:05.000Z"))

        let summary = try XCTUnwrap(ClaudeCodeTranscriptParser().parse(
            data: data,
            from: URL(fileURLWithPath: "session-0002/subagents/agent-0001.jsonl"),
            modifiedAt: modifiedAt
        ))

        XCTAssertEqual(summary.sessionId, "session-0002")
        XCTAssertTrue(summary.isSubagent)
        XCTAssertEqual(summary.cwd, "/Users/dev/example")
        XCTAssertEqual(summary.slug, "delegate-example")
        XCTAssertEqual(summary.model, "claude-fable-5")
        XCTAssertEqual(summary.usage.total, 20)
        XCTAssertEqual(summary.lastEvent, .toolPending)
    }

    func testParsesCompletedCodexFixture() throws {
        let formatter = fixtureFormatter()
        let data = try TranscriptFixtureLoader.data(producer: "Codex", caseName: "basic-session")
        let modifiedAt = try XCTUnwrap(formatter.date(from: "2026-06-14T12:00:06.000Z"))

        let summary = try XCTUnwrap(CodexTranscriptParser().parse(
            data: data,
            from: URL(fileURLWithPath: "basic-session.jsonl"),
            modifiedAt: modifiedAt
        ))

        XCTAssertEqual(summary.producer, .codex)
        XCTAssertEqual(summary.sessionId, "session-0001")
        XCTAssertFalse(summary.isSubagent)
        XCTAssertEqual(summary.cwd, "/Users/dev/example")
        XCTAssertEqual(summary.model, "generic-codex-model")
        XCTAssertTrue(summary.usage.isKnown)
        XCTAssertEqual(summary.usage.inputTokens, 20)
        XCTAssertEqual(summary.usage.outputTokens, 15)
        XCTAssertEqual(summary.usage.cacheReadTokens, 5)
        XCTAssertEqual(summary.usage.total, 40)
        XCTAssertEqual(summary.lastEvent, .turnEnded)
        XCTAssertEqual(summary.lastActivity, formatter.date(from: "2026-06-14T12:00:06.000Z"))
    }

    func testParsesActiveCodexFixture() throws {
        let formatter = fixtureFormatter()
        let data = try TranscriptFixtureLoader.data(producer: "Codex", caseName: "active-session")
        let modifiedAt = try XCTUnwrap(formatter.date(from: "2026-06-14T12:10:04.000Z"))

        let summary = try XCTUnwrap(CodexTranscriptParser().parse(
            data: data,
            from: URL(fileURLWithPath: "active-session.jsonl"),
            modifiedAt: modifiedAt
        ))

        XCTAssertEqual(summary.producer, .codex)
        XCTAssertEqual(summary.sessionId, "session-0002")
        XCTAssertEqual(summary.cwd, "/Users/dev/example")
        XCTAssertEqual(summary.model, "generic-codex-model")
        XCTAssertTrue(summary.usage.isKnown)
        XCTAssertEqual(summary.usage.inputTokens, 8)
        XCTAssertEqual(summary.usage.outputTokens, 5)
        XCTAssertEqual(summary.usage.cacheReadTokens, 2)
        XCTAssertEqual(summary.usage.total, 15)
        XCTAssertEqual(summary.lastEvent, .toolPending)
        XCTAssertEqual(summary.lastActivity, formatter.date(from: "2026-06-14T12:10:04.000Z"))
    }

    func testCodexSessionWithoutTokenCountKeepsUsageUnknown() throws {
        let formatter = fixtureFormatter()
        let modifiedAt = try XCTUnwrap(formatter.date(from: "2026-06-14T12:20:02.000Z"))
        let data = """
        {"type":"session_meta","timestamp":"2026-06-14T12:20:00.000Z","payload":{"id":"session-0004","cwd":"/Users/dev/example"}}
        {"type":"turn_context","timestamp":"2026-06-14T12:20:01.000Z","payload":{"turn_id":"turn-0004","cwd":"/Users/dev/example","model":"generic-codex-model"}}
        {"type":"event_msg","timestamp":"2026-06-14T12:20:02.000Z","payload":{"type":"agent_message","message":"Synthetic response complete.","phase":"final"}}
        """.data(using: .utf8)!

        let summary = try XCTUnwrap(CodexTranscriptParser().parse(
            data: data,
            from: URL(fileURLWithPath: "unknown-usage.jsonl"),
            modifiedAt: modifiedAt
        ))

        XCTAssertFalse(summary.usage.isKnown)
        XCTAssertEqual(summary.usage.total, 0)
        XCTAssertEqual(summary.lastEvent, .turnEnded)
    }

    func testPermissionPromptFixtureClassifiesAsBlocked() throws {
        let formatter = fixtureFormatter()
        let now = try XCTUnwrap(formatter.date(from: "2026-06-14T12:05:00.000Z"))
        let fixture = try TranscriptFixtureLoader.text(caseName: "permission-prompt-blocked")
        try writeTranscript("proj/session-0003.jsonl", lines: fixture)
        let url = projectsDir.appendingPathComponent("proj/session-0003.jsonl")
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)

        let session = try XCTUnwrap(
            claudeOnlyScanner().scan(now: now).sessions.first)

        XCTAssertEqual(session.id, "claudeCode:session-0003")
        XCTAssertEqual(session.rawSessionId, "session-0003")
        XCTAssertEqual(session.producer, .claudeCode)
        XCTAssertEqual(session.projectPath, "/Users/dev/example")
        XCTAssertEqual(session.slug, "permission-example")
        XCTAssertEqual(session.model, "claude-fable-5")
        XCTAssertEqual(session.usage.total, 21)
        XCTAssertEqual(session.state, .blocked)
    }

    func testSessionIdsAreUnique() throws {
        try writeTranscript("proj/abc-123.jsonl", lines: assistantLine(session: "abc-123", output: 1))
        try writeTranscript("proj/abc-123/subagents/agent-a1.jsonl",
            lines: assistantLine(session: "abc-123", output: 2))

        let sessions = claudeOnlyScanner().scan().sessions
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(Set(sessions.map(\.id)).count, sessions.count)
    }

    func testProducerIsPartOfSessionIdentity() throws {
        let now = Date()
        let claudeSummary = TranscriptFileSummary(
            producer: .claudeCode,
            sessionId: "shared-session",
            isSubagent: false,
            lastActivity: now,
            lastEvent: .turnEnded,
            cwd: "/Users/dev/claude",
            model: "claude-fable-5",
            usage: {
                var usage = TokenUsage()
                usage.outputTokens = 3
                return usage
            }()
        )
        let codexSummary = TranscriptFileSummary(
            producer: .codex,
            sessionId: "shared-session",
            isSubagent: false,
            lastActivity: now.addingTimeInterval(-1),
            lastEvent: .turnEnded,
            cwd: "/Users/dev/codex",
            model: "codex-generic",
            usage: {
                var usage = TokenUsage()
                usage.outputTokens = 5
                return usage
            }()
        )

        let snapshot = TranscriptScanner(sources: [
            StaticTranscriptSource(producer: .claudeCode, summaries: [claudeSummary]),
            StaticTranscriptSource(producer: .codex, summaries: [codexSummary]),
        ]).scan(now: now)

        XCTAssertEqual(snapshot.sessions.count, 2)
        XCTAssertEqual(snapshot.sessions.filter { $0.rawSessionId == "shared-session" }.count, 2)
        XCTAssertEqual(Set(snapshot.sessions.map(\.id)), ["claudeCode:shared-session", "codex:shared-session"])
        let claude = try XCTUnwrap(snapshot.sessions.first { $0.producer == .claudeCode })
        let codex = try XCTUnwrap(snapshot.sessions.first { $0.producer == .codex })
        XCTAssertEqual(claude.projectPath, "/Users/dev/claude")
        XCTAssertEqual(claude.usage.outputTokens, 3)
        XCTAssertEqual(codex.projectPath, "/Users/dev/codex")
        XCTAssertEqual(codex.usage.outputTokens, 5)
    }

    func testMixedProducerRawSessionIdDoesNotCollide() throws {
        let now = Date()
        try writeTranscript("proj/session-0001.jsonl", lines:
            assistantLine(session: "session-0001", output: 3, timestamp: iso(now.addingTimeInterval(-1))))

        let codexData = try TranscriptFixtureLoader.data(producer: "Codex", caseName: "basic-session")
        let codexDir = projectsDir.appendingPathComponent("codex/2026/06/14")
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        let codexURL = codexDir.appendingPathComponent("rollout-2026-06-14T12-00-00-session-0001.jsonl")
        try codexData.write(to: codexURL)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: codexURL.path)

        let snapshot = TranscriptScanner(sources: [
            ClaudeCodeTranscriptSource(projectsDirectory: projectsDir),
            CodexTranscriptSource(sessionsDirectory: projectsDir.appendingPathComponent("codex")),
        ]).scan(now: now)

        XCTAssertEqual(snapshot.sessions.count, 2)
        XCTAssertEqual(snapshot.sessions.filter { $0.rawSessionId == "session-0001" }.count, 2)
        XCTAssertEqual(Set(snapshot.sessions.map(\.id)), ["claudeCode:session-0001", "codex:session-0001"])
    }

    func testCodexSourceDiscoversNestedSessionFiles() throws {
        let formatter = fixtureFormatter()
        let now = try XCTUnwrap(formatter.date(from: "2026-06-14T12:15:00.000Z"))
        let codexRoot = projectsDir.appendingPathComponent("codex")
        let sessionDir = codexRoot.appendingPathComponent("2026/06/14")
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let sessionURL = sessionDir.appendingPathComponent("rollout-2026-06-14T12-10-00-session-0002.jsonl")
        try TranscriptFixtureLoader.data(producer: "Codex", caseName: "active-session").write(to: sessionURL)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: sessionURL.path)

        let source = CodexTranscriptSource(sessionsDirectory: codexRoot)
        let candidates = source.candidateFiles(now: now)
        let summary = try XCTUnwrap(candidates.compactMap { source.parse($0, now: now) }.first)

        XCTAssertEqual(candidates.map { $0.url.standardizedFileURL }, [sessionURL.standardizedFileURL])
        XCTAssertEqual(summary.producer, .codex)
        XCTAssertEqual(summary.sessionId, "session-0002")
        XCTAssertEqual(summary.lastEvent, .toolPending)
    }

    func testCodexParseFailureDoesNotBlockClaudeSessions() throws {
        let now = Date()
        try writeTranscript("proj/session-0005.jsonl", lines:
            assistantLine(session: "session-0005", output: 3, timestamp: iso(now.addingTimeInterval(-1))))

        let codexRoot = projectsDir.appendingPathComponent("codex")
        let sessionDir = codexRoot.appendingPathComponent("2026/06/14")
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let badURL = sessionDir.appendingPathComponent("rollout-bad.jsonl")
        try Data("not json\n".utf8).write(to: badURL)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: badURL.path)

        let snapshot = TranscriptScanner(sources: [
            ClaudeCodeTranscriptSource(projectsDirectory: projectsDir),
            CodexTranscriptSource(sessionsDirectory: codexRoot),
        ]).scan(now: now)

        XCTAssertEqual(snapshot.sessions.count, 1)
        XCTAssertEqual(snapshot.sessions.first?.producer, .claudeCode)
        XCTAssertEqual(snapshot.sessions.first?.rawSessionId, "session-0005")
    }

    func testDefaultScannerMatchesExplicitClaudeOnlySource() throws {
        let now = Date()
        let recent = iso(now.addingTimeInterval(-5))
        try writeTranscript("proj/abc-123.jsonl", lines: """
        {"type":"user","sessionId":"abc-123","cwd":"/Users/dev/myproject","slug":"fix-the-bug","timestamp":"\(recent)","message":{"role":"user"}}
        \(assistantLine(session: "abc-123", slug: "fix-the-bug", input: 100, output: 50, cacheRead: 1000, cacheCreation: 25, stopReason: "end_turn", timestamp: recent))
        """)
        try writeTranscript("proj/abc-123/subagents/agent-a1.jsonl",
            lines: assistantLine(session: "abc-123", input: 10, output: 5, cacheRead: 100, stopReason: "tool_use", timestamp: recent))

        let defaultSnapshot = claudeOnlyScanner().scan(now: now)
        let explicitSnapshot = TranscriptScanner(sources: [
            ClaudeCodeTranscriptSource(projectsDirectory: projectsDir)
        ]).scan(now: now)

        assertSameSnapshot(defaultSnapshot, explicitSnapshot)
    }

    func testFallsBackToFilenameWhenSessionIdIsMissing() throws {
        try writeTranscript("proj/fallback-0001.jsonl", lines: """
        {"type":"assistant","cwd":"/Users/dev/myproject","timestamp":"2026-06-10T20:00:00.000Z","message":{"model":"claude-fable-5","stop_reason":"end_turn","usage":{"output_tokens":3}}}
        """)

        let session = try XCTUnwrap(claudeOnlyScanner().scan().sessions.first)

        XCTAssertEqual(session.id, "claudeCode:fallback-0001")
        XCTAssertEqual(session.rawSessionId, "fallback-0001")
        XCTAssertEqual(session.projectPath, "/Users/dev/myproject")
        XCTAssertEqual(session.model, "claude-fable-5")
        XCTAssertEqual(session.usage.outputTokens, 3)
    }

    func testToleratesMissingOptionalTranscriptFields() throws {
        let formatter = fixtureFormatter()
        let modifiedAt = try XCTUnwrap(formatter.date(from: "2026-06-10T20:00:00.000Z"))
        let data = """
        {"type":"assistant","timestamp":"2026-06-10T20:00:00.000Z","message":{"usage":{"output_tokens":2}}}
        """.data(using: .utf8)!

        let summary = try XCTUnwrap(ClaudeCodeTranscriptParser().parse(
            data: data,
            from: URL(fileURLWithPath: "missing-fields-0001.jsonl"),
            modifiedAt: modifiedAt
        ))

        XCTAssertEqual(summary.sessionId, "missing-fields-0001")
        XCTAssertNil(summary.cwd)
        XCTAssertNil(summary.slug)
        XCTAssertNil(summary.model)
        XCTAssertEqual(summary.usage.outputTokens, 2)
        XCTAssertEqual(summary.lastEvent, .streaming)
    }

    func testToolResultClearsPendingBlockedState() throws {
        let now = Date()
        func ago(_ seconds: TimeInterval) -> String { iso(now.addingTimeInterval(-seconds)) }
        try writeTranscript("proj/tool-result-0001.jsonl", lines: """
        \(assistantLine(session: "tool-result-0001", output: 1, stopReason: "tool_use", toolUse: true, timestamp: ago(300)))
        {"type":"user","sessionId":"tool-result-0001","cwd":"/Users/dev/myproject","timestamp":"\(ago(10))","message":{"content":[{"type":"tool_result"}]}}
        """)

        let session = try XCTUnwrap(
            claudeOnlyScanner().scan(now: now).sessions.first)

        XCTAssertEqual(session.rawSessionId, "tool-result-0001")
        XCTAssertEqual(session.state, .working)
    }

    func testCollectsRecentTokenEventsForThroughput() throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = Date()
        let recent = formatter.string(from: now.addingTimeInterval(-30))
        let old = formatter.string(from: now.addingTimeInterval(-3600))

        try writeTranscript("proj/abc-123.jsonl", lines: """
        {"type":"assistant","sessionId":"abc-123","cwd":"/p","timestamp":"\(old)","message":{"model":"m","usage":{"input_tokens":1,"output_tokens":500}}}
        {"type":"assistant","sessionId":"abc-123","cwd":"/p","timestamp":"\(recent)","message":{"model":"m","usage":{"input_tokens":1,"output_tokens":120,"cache_read_input_tokens":479}}}
        """)

        let snapshot = claudeOnlyScanner().scan(now: now)

        // Only the recent turn lands in the event window.
        XCTAssertEqual(snapshot.recentEvents.count, 1)
        XCTAssertEqual(snapshot.recentEvents.first?.usage.outputTokens, 120)
        XCTAssertEqual(snapshot.recentEvents.first?.usage.total, 600)
        // 120 output tokens in the trailing minute → 120/min → 2/s.
        XCTAssertEqual(snapshot.outputTokensPerMinute(window: 60, now: now), 120, accuracy: 0.01)
        XCTAssertEqual(snapshot.outputTokensPerSecond(window: 60, now: now), 2, accuracy: 0.01)
        // Fresh rate adds input but not cache: 121/min.
        XCTAssertEqual(snapshot.freshTokensPerMinute(window: 60, now: now), 121, accuracy: 0.01)
        // Full rate counts cache: 600/min → 10/s.
        XCTAssertEqual(snapshot.totalTokensPerSecond(window: 60, now: now), 10, accuracy: 0.01)
        // Lifetime usage still counts both turns.
        XCTAssertEqual(snapshot.sessions.first?.usage.outputTokens, 620)
    }

    func testRateFormatting() {
        XCTAssertEqual(Format.rate(perSecond: 12.4), "12 tok/s")
        XCTAssertEqual(Format.rate(perSecond: 0.82), "0.8 tok/s")
        XCTAssertEqual(Format.rate(perSecond: 4200), "4.2k tok/s")
        XCTAssertEqual(Format.rateCompact(perSecond: 42.0), "42/s")
        XCTAssertEqual(Format.rateCompact(perSecond: 3.26), "3.3/s")
        XCTAssertEqual(Format.rateCompact(perSecond: 1_300_000), "1.3M/s")
    }

    func testIgnoresSyntheticModelName() throws {
        try writeTranscript("proj/abc-123.jsonl", lines: """
        {"type":"assistant","sessionId":"abc-123","cwd":"/p","timestamp":"2026-06-10T20:00:00.000Z","message":{"model":"claude-fable-5","usage":{"output_tokens":5}}}
        {"type":"assistant","sessionId":"abc-123","cwd":"/p","timestamp":"2026-06-10T20:01:00.000Z","message":{"model":"<synthetic>","usage":{"output_tokens":1}}}
        """)
        let sessions = claudeOnlyScanner().scan().sessions
        XCTAssertEqual(sessions.first?.model, "claude-fable-5")
    }

    func testHidesStaleZeroTokenSessions() throws {
        let url = projectsDir.appendingPathComponent("proj/empty-1.jsonl")
        try writeTranscript("proj/empty-1.jsonl", lines: """
        {"type":"user","sessionId":"empty-1","cwd":"/p","timestamp":"2026-06-10T08:00:00.000Z","message":{"role":"user"}}
        """)
        // Backdate mtime so the session is stale but within the 24h window.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-2 * 3600)], ofItemAtPath: url.path)
        try writeTranscript("proj/live-1.jsonl", lines: assistantLine(session: "live-1", output: 3))

        let sessions = claudeOnlyScanner().scan().sessions
        XCTAssertEqual(sessions.map(\.rawSessionId), ["live-1"])
    }

    func testStateInference() {
        // Streaming / mid-turn ⇒ working, even across a long silent think.
        XCTAssertEqual(AgentSession.state(last: .streaming, age: 5), .working)
        XCTAssertEqual(AgentSession.state(last: .streaming, age: 1800), .working)
        // A finished turn ⇒ waiting on the user, for up to an hour.
        XCTAssertEqual(AgentSession.state(last: .turnEnded, age: 5), .waiting)
        XCTAssertEqual(AgentSession.state(last: .turnEnded, age: 1800), .waiting)
        // A pending tool call is working while fresh, blocked once it's sat.
        XCTAssertEqual(AgentSession.state(last: .toolPending, age: 30), .working)
        XCTAssertEqual(AgentSession.state(last: .toolPending, age: 120), .blocked)
        // Past the stale threshold, anything is stale; nil ⇒ no model events.
        XCTAssertEqual(AgentSession.state(last: .turnEnded, age: 7200), .stale)
        XCTAssertEqual(AgentSession.state(last: .toolPending, age: 7200), .stale)
        XCTAssertEqual(AgentSession.state(last: nil, age: 5), .stale)
    }

    func testStateFromLastTranscriptEvent() throws {
        let now = Date()
        func ago(_ seconds: TimeInterval) -> String { iso(now.addingTimeInterval(-seconds)) }

        // waiting: the turn ended and we're holding for the user.
        try writeTranscript("p/wait.jsonl",
            lines: assistantLine(session: "wait", output: 1, stopReason: "end_turn", timestamp: ago(10)))
        // working: a streaming mid-turn assistant line.
        try writeTranscript("p/work.jsonl",
            lines: assistantLine(session: "work", output: 1, stopReason: "tool_use", timestamp: ago(10)))
        // working: a tool call still within the blocked threshold.
        try writeTranscript("p/run.jsonl",
            lines: assistantLine(session: "run", output: 1, stopReason: "tool_use", toolUse: true, timestamp: ago(30)))
        // blocked: a tool call pending well past the threshold (permission prompt).
        try writeTranscript("p/block.jsonl",
            lines: assistantLine(session: "block", output: 1, stopReason: "tool_use", toolUse: true, timestamp: ago(300)))

        let sessions = claudeOnlyScanner().scan(now: now).sessions
        func state(_ id: String) -> AgentState? { sessions.first { $0.rawSessionId == id }?.state }
        XCTAssertEqual(state("wait"), .waiting)
        XCTAssertEqual(state("work"), .working)
        XCTAssertEqual(state("run"), .working)
        XCTAssertEqual(state("block"), .blocked)
    }

    func testHousekeepingWritesDoNotCountAsActivity() throws {
        let now = Date()
        // The model finished an hour-plus ago; a fresh housekeeping line (a
        // title) must NOT make the session look active.
        try writeTranscript("p/done.jsonl", lines: """
        \(assistantLine(session: "done", output: 5, stopReason: "end_turn", timestamp: iso(now.addingTimeInterval(-4000))))
        {"type":"ai-title","sessionId":"done","cwd":"/p","timestamp":"\(iso(now.addingTimeInterval(-5)))","title":"whatever"}
        """)
        let session = try XCTUnwrap(
            claudeOnlyScanner().scan(now: now).sessions.first)
        XCTAssertEqual(session.state, .stale)
    }

    func testTokenFormatting() {
        XCTAssertEqual(Format.tokens(999), "999")
        XCTAssertEqual(Format.tokens(1200), "1.2k")
        XCTAssertEqual(Format.tokens(4_500_000), "4.5M")
    }

    func testModelShortName() {
        XCTAssertEqual(Format.modelShortName("claude-fable-5[1m]"), "fable-5")
        XCTAssertEqual(Format.modelShortName("claude-opus-4-8"), "opus-4-8")
        XCTAssertEqual(Format.modelShortName("gpt-x"), "gpt-x")
    }

    private func assertSameSnapshot(
        _ lhs: FlockSnapshot,
        _ rhs: FlockSnapshot,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(lhs.scannedAt, rhs.scannedAt, file: file, line: line)
        XCTAssertEqual(lhs.recentEvents.count, rhs.recentEvents.count, file: file, line: line)
        for (left, right) in zip(lhs.recentEvents, rhs.recentEvents) {
            XCTAssertEqual(left.timestamp, right.timestamp, file: file, line: line)
            XCTAssertEqual(left.usage, right.usage, file: file, line: line)
        }

        XCTAssertEqual(lhs.sessions.count, rhs.sessions.count, file: file, line: line)
        for (left, right) in zip(lhs.sessions, rhs.sessions) {
            XCTAssertEqual(left.id, right.id, file: file, line: line)
            XCTAssertEqual(left.rawSessionId, right.rawSessionId, file: file, line: line)
            XCTAssertEqual(left.producer, right.producer, file: file, line: line)
            XCTAssertEqual(left.projectPath, right.projectPath, file: file, line: line)
            XCTAssertEqual(left.slug, right.slug, file: file, line: line)
            XCTAssertEqual(left.model, right.model, file: file, line: line)
            XCTAssertEqual(left.usage, right.usage, file: file, line: line)
            XCTAssertEqual(left.lastActivity, right.lastActivity, file: file, line: line)
            XCTAssertEqual(left.state, right.state, file: file, line: line)
            XCTAssertEqual(left.subagentCount, right.subagentCount, file: file, line: line)
            XCTAssertEqual(left.activeSubagentCount, right.activeSubagentCount, file: file, line: line)
        }
    }
}

private struct StaticTranscriptSource: TranscriptSource {
    let producer: TranscriptProducer
    let summaries: [TranscriptFileSummary]

    func candidateFiles(now: Date) -> [TranscriptCandidate] {
        summaries.indices.map {
            TranscriptCandidate(url: URL(fileURLWithPath: "/synthetic/\($0).jsonl"), modifiedAt: now)
        }
    }

    func parse(_ candidate: TranscriptCandidate, now: Date) -> TranscriptFileSummary? {
        guard let index = Int(candidate.url.deletingPathExtension().lastPathComponent) else { return nil }
        return summaries[index]
    }
}
