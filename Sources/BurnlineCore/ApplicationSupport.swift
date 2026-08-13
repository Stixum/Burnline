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

    /// An empty directory for the poller's child process to run in.
    ///
    /// ⚠️ **This exists for a TCC reason, not a tidiness one.** The poller
    /// spawns `claude`, Claude Code enumerates its working directory at
    /// startup, and macOS attributes a child's TCC requests to the
    /// **responsible process** — Burnline. Running it in `$HOME` therefore made
    /// macOS ask the user for **Documents, Desktop and Downloads access on
    /// Burnline's behalf**, which is fatal for a menu bar app a stranger just
    /// downloaded. Observed 2026-08-12.
    ///
    /// `$HOME` was originally chosen because it is an already-trusted project
    /// and an unfamiliar directory makes Claude Code open a trust dialog that
    /// would hang the session invisibly. Measured 2026-08-12: **an empty
    /// subdirectory of `$HOME` produces no trust dialog** — the TUI came up and
    /// ran `/usage` with no prompt — so the trade that forced `$HOME` does not
    /// actually apply.
    ///
    /// **It must stay empty.** An empty directory cannot lead Claude Code to
    /// anything protected; that is the entire mechanism. Never write into it.
    ///
    /// ✅ **Verified end to end 2026-08-12** against a genuinely stale cache
    /// (928s): the child spawned here raised no trust dialog, rendered
    /// `/usage`, and moved `cachedUsageUtilization.fetchedAtMs`. The first
    /// attempt at this test looked like a failure only because the cache had
    /// been refreshed seconds earlier, so `/usage` served from it and had
    /// nothing to re-fetch — **check the cache's age before concluding the
    /// poller is broken.**
    ///
    /// ⚠️ Under `overrideKey` this moves outside `$HOME`, where trust may not be
    /// inherited and the child could hit a trust dialog. Only the real app
    /// spawns the poller, so this affects manual experiments, not tests.
    public static func pollWorkingDirectory() -> URL {
        let directory = directory().appendingPathComponent("poll-cwd", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
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
