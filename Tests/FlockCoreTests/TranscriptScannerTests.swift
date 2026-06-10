import XCTest
@testable import FlockCore

final class TranscriptScannerTests: XCTestCase {
    func testParsesAssistantUsageAndSessionMetadata() throws {
        let lines = """
        {"type":"user","sessionId":"abc-123","cwd":"/Users/dev/myproject","slug":"fix-the-bug","timestamp":"2026-06-10T20:00:00.000Z","message":{"role":"user"}}
        {"type":"assistant","sessionId":"abc-123","cwd":"/Users/dev/myproject","timestamp":"2026-06-10T20:00:05.000Z","message":{"model":"claude-fable-5","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":1000,"cache_creation_input_tokens":25}}}
        {"type":"assistant","sessionId":"abc-123","cwd":"/Users/dev/myproject","timestamp":"2026-06-10T20:00:10.000Z","message":{"model":"claude-fable-5","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":100,"cache_creation_input_tokens":0}}}
        not even json
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("openflock-test-\(UUID().uuidString).jsonl")
        try lines.data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let now = Date()
        let session = TranscriptScanner().parseTranscript(
            at: url, modifiedAt: now.addingTimeInterval(-30), now: now)

        let s = try XCTUnwrap(session)
        XCTAssertEqual(s.id, "abc-123")
        XCTAssertEqual(s.projectPath, "/Users/dev/myproject")
        XCTAssertEqual(s.slug, "fix-the-bug")
        XCTAssertEqual(s.model, "claude-fable-5")
        XCTAssertEqual(s.usage.inputTokens, 110)
        XCTAssertEqual(s.usage.outputTokens, 55)
        XCTAssertEqual(s.usage.cacheReadTokens, 1100)
        XCTAssertEqual(s.usage.cacheCreationTokens, 25)
        XCTAssertEqual(s.usage.total, 1290)
        XCTAssertEqual(s.state, .active)
        XCTAssertEqual(s.projectName, "myproject")
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
