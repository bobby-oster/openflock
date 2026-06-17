import Foundation

/// A small, file-backed store for the app's persisted UI settings (panel
/// component visibility, etc.), at `OpenFlockHome/settings.json`.
///
/// It lives in `~/.openflock` rather than `UserDefaults` so settings are shared
/// across build variants and the future CLI. `UserDefaults`/`@AppStorage` is
/// keyed to bundle identity, so it silently diverges between the dev bundle, the
/// release bundle, and `swift run` — a setting toggled in one doesn't show up in
/// another. Same reasoning as the dismissal overlay.
///
/// Tolerant, like the dismissal overlay: a missing or corrupt file means "all
/// defaults", and a write happens only when a value actually changes.
public struct SettingsStore: Sendable {
    public let fileURL: URL
    private var values: [String: Bool]

    public init(directory: URL = OpenFlockHome.directory) {
        self.fileURL = directory.appendingPathComponent("settings.json")
        self.values = SettingsStore.load(from: fileURL)
    }

    /// The stored value for `key`, or `defaultValue` when it isn't set.
    public func bool(_ key: String, default defaultValue: Bool) -> Bool {
        values[key] ?? defaultValue
    }

    /// Stores `value` for `key`. Persists only when it actually changed, so an
    /// unchanged toggle never rewrites the file.
    public mutating func setBool(_ key: String, _ value: Bool) {
        guard values[key] != value else { return }
        values[key] = value
        save()
    }

    private static func load(from url: URL) -> [String: Bool] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: Bool].self, from: data)
        else { return [:] }
        return decoded
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(values) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
