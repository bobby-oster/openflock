import Foundation

public struct CodexTranscriptSource: TranscriptSource {
    public let producer: TranscriptProducer = .codex
    public var sessionsDirectory: URL
    /// Transcripts whose mtime is older than this window are skipped entirely.
    public var recencyWindow: TimeInterval
    /// How far back to collect per-turn token events for throughput math.
    public var eventWindow: TimeInterval

    public init(
        sessionsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions"),
        recencyWindow: TimeInterval = 24 * 3600,
        eventWindow: TimeInterval = 15 * 60
    ) {
        self.sessionsDirectory = sessionsDirectory
        self.recencyWindow = recencyWindow
        self.eventWindow = eventWindow
    }

    public func candidateFiles(now: Date) -> [TranscriptCandidate] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var candidates: [TranscriptCandidate] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard
                let modifiedAt = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate,
                now.timeIntervalSince(modifiedAt) < recencyWindow
            else { continue }
            candidates.append(TranscriptCandidate(url: url, modifiedAt: modifiedAt))
        }
        return candidates
    }

    public func parse(_ candidate: TranscriptCandidate, now: Date) -> TranscriptFileSummary? {
        guard let data = try? Data(contentsOf: candidate.url) else { return nil }
        let eventCutoff = now.addingTimeInterval(-eventWindow)
        return CodexTranscriptParser().parse(
            data: data,
            from: candidate.url,
            modifiedAt: candidate.modifiedAt,
            options: CodexTranscriptParser.Options(eventCutoff: eventCutoff)
        )
    }
}
