import Foundation

/// Finds the `claude` binary that `UsagePoller` runs.
///
/// ⚠️ **A Finder-launched app does not inherit your shell's `PATH`.**
/// LaunchServices gives it roughly `/usr/bin:/bin:/usr/sbin:/sbin`, so
/// `/usr/bin/env claude` resolves from a terminal and fails silently in the
/// installed app — the only place it matters. Homebrew's location in particular
/// is never on that PATH. Hence the explicit fallbacks.
///
/// Lives in `BurnlineCore` rather than beside the poller so the **not-found**
/// branch is testable: the app target has no test target, and that branch is
/// both the one that will rot and the one whose failure is invisible.
public enum ClaudeExecutable {

    /// Locations checked after `PATH`, in order.
    static let knownLocations = [
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        "~/.claude/local/claude",
        "~/.local/bin/claude",
    ]

    /// Every path worth stat-ing, in priority order, deduplicated.
    ///
    /// Pure so the ordering is a property that can be asserted rather than a
    /// behaviour that has to be observed on a machine that happens to have
    /// Claude Code installed in the right place.
    public static func candidates(environment: [String: String], home: String) -> [String] {
        var result: [String] = []
        var seen = Set<String>()

        func add(_ path: String) {
            guard !seen.contains(path) else { return }
            seen.insert(path)
            result.append(path)
        }

        if let path = environment["PATH"] {
            for entry in path.split(separator: ":", omittingEmptySubsequences: true) {
                // A trailing or doubled colon means "the current directory" to
                // some shells. A Finder-launched app has cwd `/`, and resolving
                // `./claude` from there is not something to do quietly.
                let trimmed = String(entry)
                guard trimmed.hasPrefix("/") else { continue }
                add("\(trimmed)/claude")
            }
        }

        for location in knownLocations {
            add(location.replacingOccurrences(of: "~", with: home))
        }
        return result
    }

    /// The first candidate that is actually executable, or `nil`.
    ///
    /// `nil` means Claude Code is installed somewhere this cannot find — nvm,
    /// asdf, a custom prefix — and the poll will do nothing. The UI must say so
    /// rather than leaving a silently dead setting.
    public static func resolve(environment: [String: String], home: String,
                               isExecutable: (String) -> Bool) -> String? {
        candidates(environment: environment, home: home).first(where: isExecutable)
    }

    public static func resolve() -> String? {
        resolve(environment: ProcessInfo.processInfo.environment,
                home: NSHomeDirectory(),
                isExecutable: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    /// The locations searched, for the "not found" message. Users install Claude
    /// Code in places we do not know about, and telling them where we looked is
    /// the difference between a bug report and a one-line fix.
    public static func searchedLocationsDescription(home: String = NSHomeDirectory()) -> String {
        knownLocations
            .map { $0.replacingOccurrences(of: "~", with: home) }
            .joined(separator: "\n")
    }
}
