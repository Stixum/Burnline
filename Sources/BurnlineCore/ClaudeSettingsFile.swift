import Foundation

/// Reads and writes `~/.claude/settings.json`.
///
/// This is somebody else's configuration file, and the only one Burnline ever
/// writes outside its own directory. Three rules follow from that:
///
/// 1. A backup is written before any mutation.
/// 2. A file that exists but cannot be parsed is an **error**, never an empty
///    dictionary. Treating a broken file as "no file" would have us write a
///    fresh one straight over it.
/// 3. Every key we do not own is carried across untouched.
public struct ClaudeSettingsFile: Sendable {
    public let url: URL

    /// Redirects the settings directory, for exercising the onboarding without
    /// touching your own Claude Code configuration.
    ///
    /// Same contract as `ApplicationSupport.overrideKey`, and it exists for the
    /// same reason: there was previously no way to test a write path except by
    /// aiming it at live data. `NSHomeDirectory()` ignores `$HOME`, so
    /// `env -i HOME=/tmp/…` does **not** sandbox this.
    ///
    /// ```
    /// BURNLINE_CLAUDE_DIR=/tmp/claude-test swift run Burnline
    /// ```
    public static let overrideKey = "BURNLINE_CLAUDE_DIR"

    public init(directory: URL) {
        url = directory.appendingPathComponent("settings.json")
    }

    /// Deliberately an overload rather than a defaulted parameter, matching
    /// `ApplicationSupport.directory()` — a default argument generator is
    /// emitted into each caller's object file, which renames the symbol every
    /// caller references and breaks incremental builds.
    public init() {
        self.init(directory: Self.defaultDirectory())
    }

    public static func defaultDirectory() -> URL {
        resolveDirectory(environment: ProcessInfo.processInfo.environment)
    }

    /// Pure: environment → directory URL, no filesystem side effects.
    ///
    /// Burnline is unsandboxed, which is what lets it reach `~/.claude` at all
    /// with no entitlement work. Any non-empty override is honoured with no
    /// validation — rejecting a malformed value and falling back to the real
    /// `~/.claude` would fail *open*, the one outcome this exists to prevent.
    static func resolveDirectory(environment: [String: String]) -> URL {
        if let override = environment[overrideKey], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
    }

    /// `nil` when the file does not exist; throws when it exists and cannot be
    /// read as a JSON object. See rule 2 on the type.
    public func read() throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return object
    }

    /// Claude Code's transcript retention, when the settings name one. How far
    /// back the history heal can trust the transcripts to be complete.
    ///
    /// Only a whole number counts. `JSONSerialization` hands back an
    /// `NSNumber`, which bridges `7.5` to nil but `true` to 1 — so a boolean is
    /// refused explicitly rather than read as a one-day period.
    public static func cleanupPeriodDays(in settings: [String: Any]?) -> Int? {
        guard let number = settings?["cleanupPeriodDays"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        return number as? Int
    }

    /// Backs the current file up, then writes `settings` atomically.
    ///
    /// Key order is not preserved — `JSONSerialization` reorders. Accepted: the
    /// alternative is a surgical text edit of arbitrary JSON, which is most
    /// fragile exactly where being wrong is most expensive. The *content* is
    /// preserved exactly, and the backup makes the original layout recoverable.
    public func write(_ settings: [String: Any], backupSuffix: String? = nil) throws {
        let suffix = backupSuffix ?? String(Int(Date().timeIntervalSince1970))

        // ⚠️ Through the link, not over it. A dotfiles manager leaves this as a
        // symlink into a repository; an atomic write renames a new file over
        // the path it is given, which replaced the link with a plain file, and
        // `copyItem` on the link made a backup that was only another link.
        let target = url.resolvingSymlinksInPath()

        if FileManager.default.fileExists(atPath: target.path) {
            let backup = url.deletingLastPathComponent()
                .appendingPathComponent("settings.json.burnline-backup-\(suffix)")
            try? FileManager.default.removeItem(at: backup)
            try FileManager.default.copyItem(at: target, to: backup)
        }

        // Encode before creating anything: a dictionary that cannot be
        // serialized must fail without having touched the filesystem.
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: target, options: .atomic)
    }
}
