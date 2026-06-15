import Foundation

public enum TranscriptProducer: String, Sendable {
    case claudeCode
    case codex
}

public struct TranscriptCandidate: Sendable {
    public let url: URL
    public let modifiedAt: Date

    public init(url: URL, modifiedAt: Date) {
        self.url = url
        self.modifiedAt = modifiedAt
    }
}

public protocol TranscriptSource: Sendable {
    var producer: TranscriptProducer { get }

    func candidateFiles(now: Date) -> [TranscriptCandidate]
    func parse(_ candidate: TranscriptCandidate, now: Date) -> TranscriptFileSummary?
}
