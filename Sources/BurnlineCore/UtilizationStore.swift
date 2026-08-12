import Foundation

/// Reads the `cachedUsageUtilization` block out of `~/.claude.json`.
///
/// ⚠️ **That file also holds hundreds of project paths** — for consultancy work,
/// client names. Only the utilization block is ever extracted, and the raw file
/// is never copied, logged, or surfaced in diagnostics. `BurnlineProbe` prints
/// figures, never JSON.
///
/// A **class**, not a struct like the other stores, because it caches: the
/// rebuild runs every 10 seconds against a 160 KB file, and re-parsing an
/// unchanged one forever is pure waste. Used only from `UsageStore`, which is
/// `@MainActor`, so no cross-actor sharing is involved.
public final class UtilizationStore {
    private let path: URL
    private var cachedKey: FileKey?
    private var cached: UsageUtilization?

    /// Test observability: proves the cache actually prevents re-parsing.
    private(set) public var parseCount = 0

    /// Redirects the config this reads, the counterpart to `BURNLINE_DATA_DIR`.
    ///
    /// ⚠️ **`NSHomeDirectory()` ignores `$HOME`** — verified 2026-08-12, exactly
    /// like `FileManager.urls(for:in:)`. Without this override there is no way to
    /// exercise the utilization source, or screenshot the per-model row, without
    /// reading the user's real `~/.claude.json` — a file holding hundreds of
    /// project paths.
    public static let overrideKey = "BURNLINE_CLAUDE_CONFIG"

    /// Any non-empty value wins, including a relative path. As with
    /// `BURNLINE_DATA_DIR`, validating and falling back to the real config would
    /// fail *open* — straight back to reading the file this exists to avoid.
    static func defaultPath(environment: [String: String]) -> URL {
        if let override = environment[overrideKey], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude.json")
    }

    public convenience init() {
        self.init(path: Self.defaultPath(environment: ProcessInfo.processInfo.environment))
    }

    /// Injectable so tests never touch the real config. **No test may read the
    /// user's own `~/.claude.json`.**
    public init(path: URL) {
        self.path = path
    }

    /// Both parts matter. Size alone misses an edit that replaces bytes without
    /// changing length, and a whole-second mtime misses two writes in the same
    /// second — either failure shows up as a figure that silently stops moving.
    private struct FileKey: Equatable {
        let modifiedAt: Date
        let size: Int
    }

    private func currentKey() -> FileKey? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
              let modifiedAt = attrs[.modificationDate] as? Date,
              let size = attrs[.size] as? Int
        else { return nil }
        return FileKey(modifiedAt: modifiedAt, size: size)
    }

    /// `nil` when the file is missing, unreadable, mid-write, or predates the
    /// field — all of which simply mean this source contributes nothing and the
    /// statusline path carries on untouched.
    public func load() -> UsageUtilization? {
        guard let key = currentKey() else {
            cachedKey = nil
            cached = nil
            return nil
        }
        if key == cachedKey { return cached }

        cachedKey = key
        cached = parse()
        return cached
    }

    private func parse() -> UsageUtilization? {
        parseCount += 1
        // Claude Code rewrites this file from another process; a read can land
        // mid-write. A decode failure is expected occasionally and must cost
        // nothing more than one skipped refresh.
        guard let data = try? Data(contentsOf: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let block = root["cachedUsageUtilization"],
              let blockData = try? JSONSerialization.data(withJSONObject: block)
        else { return nil }
        return try? JSONDecoder().decode(UsageUtilization.self, from: blockData)
    }
}
