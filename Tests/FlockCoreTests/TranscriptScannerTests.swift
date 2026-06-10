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

    private func assistantLine(
        session: String, cwd: String = "/Users/dev/myproject", slug: String? = nil,
        input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheCreation: Int = 0
    ) -> String {
        let slugField = slug.map { "\"slug\":\"\($0)\"," } ?? ""
        return """
        {"type":"assistant","sessionId":"\(session)","cwd":"\(cwd)",\(slugField)"timestamp":"2026-06-10T20:00:00.000Z","message":{"model":"claude-fable-5","usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_read_input_tokens":\(cacheRead),"cache_creation_input_tokens":\(cacheCreation)}}}
        """
    }

    func testGroupsSubagentsUnderParentSession() throws {
        try writeTranscript("proj/abc-123.jsonl", lines: """
        {"type":"user","sessionId":"abc-123","cwd":"/Users/dev/myproject","slug":"fix-the-bug","timestamp":"2026-06-10T20:00:00.000Z","message":{"role":"user"}}
        \(assistantLine(session: "abc-123", slug: "fix-the-bug", input: 100, output: 50, cacheRead: 1000, cacheCreation: 25))
        not even json
        """)
        try writeTranscript("proj/abc-123/subagents/agent-a1.jsonl",
            lines: assistantLine(session: "abc-123", input: 10, output: 5, cacheRead: 100))
        try writeTranscript("proj/abc-123/subagents/agent-a2.jsonl",
            lines: assistantLine(session: "abc-123", input: 1, output: 2))
        // Unrelated second session in another project dir.
        try writeTranscript("other/def-456.jsonl",
            lines: assistantLine(session: "def-456", cwd: "/Users/dev/other", output: 7))

        let sessions = TranscriptScanner(projectsDirectory: projectsDir).scan().sessions

        XCTAssertEqual(sessions.count, 2)
        let s = try XCTUnwrap(sessions.first { $0.id == "abc-123" })
        XCTAssertEqual(s.projectPath, "/Users/dev/myproject")
        XCTAssertEqual(s.slug, "fix-the-bug")
        XCTAssertEqual(s.model, "claude-fable-5")
        XCTAssertEqual(s.subagentCount, 2)
        XCTAssertEqual(s.activeSubagentCount, 2) // just written ⇒ active
        XCTAssertEqual(s.usage.inputTokens, 111)
        XCTAssertEqual(s.usage.outputTokens, 57)
        XCTAssertEqual(s.usage.cacheReadTokens, 1100)
        XCTAssertEqual(s.usage.cacheCreationTokens, 25)
        XCTAssertEqual(s.state, .active)
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
        XCTAssertEqual(AgentSession.state(forAge: 5), .active)
        XCTAssertEqual(AgentSession.state(forAge: 59), .active)
        XCTAssertEqual(AgentSession.state(forAge: 120), .idle)
        XCTAssertEqual(AgentSession.state(forAge: 7200), .stale)
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
