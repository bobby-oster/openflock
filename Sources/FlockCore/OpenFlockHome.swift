import Foundation

/// OpenFlock's shared local-state directory: `$OPENFLOCK_HOME` if set, else
/// `~/.openflock`.
///
/// Everything OpenFlock persists locally (the dismissal overlay, UI settings, …)
/// lives here, so it's shared across the app, the future CLI, and build variants
/// — rather than fragmenting per bundle id the way `UserDefaults` does (the dev
/// bundle, the release bundle, and `swift run` each get a separate defaults
/// domain, so a setting saved in one is invisible to the others).
public enum OpenFlockHome {
    public static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["OPENFLOCK_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openflock", isDirectory: true)
    }
}
