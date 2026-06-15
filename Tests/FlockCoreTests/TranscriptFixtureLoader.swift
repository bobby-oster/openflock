import Foundation

enum TranscriptFixtureLoader {
    static func data(
        producer: String = "ClaudeCode",
        date: String = "2026-06-14",
        caseName: String
    ) throws -> Data {
        try Data(contentsOf: url(producer: producer, date: date, caseName: caseName))
    }

    static func text(
        producer: String = "ClaudeCode",
        date: String = "2026-06-14",
        caseName: String
    ) throws -> String {
        String(decoding: try data(producer: producer, date: date, caseName: caseName), as: UTF8.self)
    }

    static func url(
        producer: String = "ClaudeCode",
        date: String = "2026-06-14",
        caseName: String
    ) -> URL {
        fixturesRoot()
            .appendingPathComponent("Transcripts")
            .appendingPathComponent(producer)
            .appendingPathComponent(date)
            .appendingPathComponent("\(caseName).jsonl")
    }

    private static func fixturesRoot(filePath: String = #filePath) -> URL {
        URL(fileURLWithPath: filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }
}
