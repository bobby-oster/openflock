import Foundation

public struct ClaudeCodeTranscriptSource: TranscriptSource {
    public let producer: TranscriptProducer = .claudeCode
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

    public func candidateFiles(now: Date) -> [TranscriptCandidate] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: projectsDirectory,
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

        // Share the parser's single millisecond-UTC formatter — the lexicographic
        // cutoff compare below depends on the same format the parser assumes.
        let formatter = ClaudeCodeTranscriptParser.defaultFormatter
        let eventCutoff = now.addingTimeInterval(-eventWindow)
        let cutoffString = formatter.string(from: eventCutoff)

        var options = ClaudeCodeTranscriptParser.Options()
        options.eventCutoffString = candidate.modifiedAt >= eventCutoff ? cutoffString : nil

        return ClaudeCodeTranscriptParser().parse(
            data: data,
            from: candidate.url,
            modifiedAt: candidate.modifiedAt,
            options: options
        )
    }
}
