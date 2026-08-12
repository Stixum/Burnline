import Foundation

public enum ApplicationSupport {
    /// Redirects every Burnline data file to another directory.
    ///
    /// This exists for one reason: the `burnline-statusline` helper writes
    /// `rate-limits.json`, which is the only copy of the last real capture, and
    /// there was previously no way to exercise the helper without overwriting
    /// it. `env -i HOME=/tmp/…` does **not** work — `FileManager.urls(for:in:)`
    /// resolves the real home directory and ignores `$HOME`. This did overwrite
    /// live data three times in one session on 2026-08-11, once producing a
    /// fabricated reading the app then latched and displayed as real.
    ///
    /// ```
    /// BURNLINE_DATA_DIR=/tmp/burnline-test .build/debug/burnline-statusline < payload.json
    /// ```
    ///
    /// Confirm the export landed with `swift run BurnlineProbe`, which prints
    /// the resolved directory as its first line, before running anything that
    /// writes.
    public static let overrideKey = "BURNLINE_DATA_DIR"

    /// Whether `overrideKey` is actually in effect — what the probe reports, so
    /// "am I sandboxed?" can be answered before the helper runs rather than
    /// after.
    public static func isOverridden() -> Bool {
        isOverridden(environment: ProcessInfo.processInfo.environment)
    }

    static func isOverridden(environment: [String: String]) -> Bool {
        environment[overrideKey].map { !$0.isEmpty } ?? false
    }

    /// Pure: environment → directory URL, no filesystem side effects.
    ///
    /// **Any non-empty value is honoured, including a relative one** (resolved
    /// against the cwd). Validating the path and falling back to the real
    /// directory on a malformed value would fail *open* — the one outcome this
    /// override exists to prevent — so there is deliberately no validation to
    /// fail. Only an absent or empty value means "use the real directory",
    /// matching the usual convention that unset and empty are the same thing.
    static func resolve(environment: [String: String]) -> URL {
        if let override = environment[overrideKey], !override.isEmpty {
            // Shells expand an unquoted `~`, but `env VAR='~/x'` does not, and a
            // literal `~` directory in the cwd is a confusing way to fail.
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Burnline", isDirectory: true)
    }

    /// `~/Library/Application Support/Burnline`, or `overrideKey` if set.
    /// Created on demand.
    ///
    /// A directory that can't be created is still returned rather than falling
    /// back to the real one: writes then fail harmlessly (the helper's save is
    /// best-effort, and every load tolerates a missing file), where a fallback
    /// would silently resume writing live data.
    /// Deliberately an overload rather than a defaulted parameter. A default
    /// argument generator is emitted into each *caller's* object file, so giving
    /// this function a parameter renames the symbol every store's `init` already
    /// references — which breaks incremental builds until an unrelated file is
    /// touched. It also copies the whole environment dictionary at every call.
    public static func directory() -> URL {
        directory(environment: ProcessInfo.processInfo.environment)
    }

    public static func directory(environment: [String: String]) -> URL {
        let directory = resolve(environment: environment)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
