import Foundation

/// A small, file-backed overlay recording which sessions the user has dismissed
/// ("I'm no longer tracking this"). Keyed by `AgentSession.id` (the composite
/// `producer:rawSessionId`), valued by the session's `lastActivity` at the
/// moment of dismissal.
///
/// Dismissal is *activity-keyed*: a session stays dismissed only while its
/// `lastActivity` has not advanced past the stored timestamp, so any new model
/// event (fresh token usage, a finished turn, a tool result) silently clears it
/// — no timer, no polling. The classification rule lives in
/// `AgentSession.isDismissed(state:lastActivity:dismissedAt:)`.
///
/// This is a derived UX overlay, not a source of truth: a missing or corrupt
/// file means "nothing dismissed" and never fails a scan. It lives next to the
/// tools OpenFlock observes — `~/.openflock/dismissals.json` by default,
/// relocatable via `OPENFLOCK_HOME` (mirrors `CODEX_HOME` / `CLAUDE_CONFIG_DIR`,
/// and is the test-injection seam).
public struct DismissalStore: Sendable {
    /// The JSON file backing this store.
    public let fileURL: URL
    private var entries: [String: Date]

    /// Loads (tolerantly) from `directory/dismissals.json`.
    public init(directory: URL = DismissalStore.defaultDirectory) {
        self.fileURL = directory.appendingPathComponent("dismissals.json")
        self.entries = DismissalStore.load(from: fileURL)
    }

    /// `$OPENFLOCK_HOME`, or `~/.openflock` when unset.
    public static var defaultDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["OPENFLOCK_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openflock", isDirectory: true)
    }

    /// When the session was dismissed, or `nil` if it has no dismissal recorded.
    public func dismissedAt(_ id: String) -> Date? { entries[id] }

    /// Records `id` as dismissed at `date` (the session's `lastActivity`). Persists.
    public mutating func dismiss(_ id: String, at date: Date) {
        entries[id] = date
        save()
    }

    /// Clears any dismissal for `id`. Persists only if one existed.
    public mutating func restore(_ id: String) {
        if entries.removeValue(forKey: id) != nil { save() }
    }

    /// Drops entries whose session is no longer present in a scan. Persists —
    /// and returns `true` — only when the set actually changed, so an unchanged
    /// scan never rewrites the file.
    @discardableResult
    public mutating func prune(keeping ids: Set<String>) -> Bool {
        let before = entries.count
        entries = entries.filter { ids.contains($0.key) }
        guard entries.count != before else { return false }
        save()
        return true
    }

    // MARK: - Persistence (tolerant load, atomic save)

    private static func load(from url: URL) -> [String: Date] {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        let formatter = DismissalStore.formatter()
        return raw.reduce(into: [String: Date]()) { result, pair in
            if let date = formatter.date(from: pair.value) { result[pair.key] = date }
        }
    }

    private func save() {
        let formatter = DismissalStore.formatter()
        let raw = entries.mapValues { formatter.string(from: $0) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(raw) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
