import XCTest
@testable import FlockCore

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

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
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

        let sessions = TranscriptScanner(projectsDirectory: projectsDir).scan(now: now).sessions

        XCTAssertEqual(sessions.count, 2)
        let s = try XCTUnwrap(sessions.first { $0.id == "abc-123" })
        XCTAssertEqual(s.projectPath, "/Users/dev/myproject")
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

        let other = try XCTUnwrap(sessions.first { $0.id == "def-456" })
        XCTAssertEqual(other.subagentCount, 0)
        XCTAssertEqual(other.usage.outputTokens, 7)
    }

    func testSessionIdsAreUnique() throws {
        try writeTranscript("proj/abc-123.jsonl", lines: assistantLine(session: "abc-123", output: 1))
        try writeTranscript("proj/abc-123/subagents/agent-a1.jsonl",
            lines: assistantLine(session: "abc-123", output: 2))

        let sessions = TranscriptScanner(projectsDirectory: projectsDir).scan().sessions
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(Set(sessions.map(\.id)).count, sessions.count)
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

        let snapshot = TranscriptScanner(projectsDirectory: projectsDir).scan(now: now)

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
        let sessions = TranscriptScanner(projectsDirectory: projectsDir).scan().sessions
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

        let sessions = TranscriptScanner(projectsDirectory: projectsDir).scan().sessions
        XCTAssertEqual(sessions.map(\.id), ["live-1"])
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

        let sessions = TranscriptScanner(projectsDirectory: projectsDir).scan(now: now).sessions
        func state(_ id: String) -> AgentState? { sessions.first { $0.id == id }?.state }
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
            TranscriptScanner(projectsDirectory: projectsDir).scan(now: now).sessions.first)
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
}
