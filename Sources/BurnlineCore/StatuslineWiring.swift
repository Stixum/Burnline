import Foundation

/// What `~/.claude/settings.json` currently says about the statusline, and what
/// Burnline is allowed to do about it.
///
/// Pure by design. This is the part that must never be wrong — it decides
/// whether the app is about to overwrite somebody else's configuration — so the
/// decision is tested against a dictionary rather than against the filesystem,
/// and the file I/O lives separately in `ClaudeSettingsFile`.
public enum StatuslineWiring {

    public enum State: Equatable, Sendable {
        /// No settings file at all. Safe to create one.
        case noSettingsFile
        /// A settings file with no `statusLine` key. Safe to add one.
        case notConfigured
        /// Ours, pointing at this bundle. Nothing to do.
        case configured
        /// Ours, pointing somewhere else — a moved bundle, or the pre-1.0
        /// hand-installed shell script. Safe to repoint.
        case stalePath(current: String)
        /// Someone else's statusline. **Burnline does not win this.** The user
        /// is shown their own command and the snippet, and decides.
        case conflict(command: String)

        /// Whether "Set up automatically" should be offered.
        public var isAutomaticallyFixable: Bool {
            switch self {
            case .noSettingsFile, .notConfigured, .stalePath: true
            case .configured, .conflict: false
            }
        }
    }

    /// Default cadence, in seconds.
    ///
    /// Load-bearing rather than arbitrary: between captures the app extrapolates
    /// from local token counts alone, which see only Claude Code on this Mac. A
    /// slow refresh is therefore a wrong number, not merely a late one.
    public static let refreshInterval = 30

    /// Recognises a command as Burnline's own.
    ///
    /// Matches on the trailing component so a moved bundle is still recognised,
    /// and accepts the pre-1.0 shell script so early adopters are migrated
    /// rather than treated as a conflict.
    ///
    /// This is deliberately generous. Being wrong in this direction repoints a
    /// command that already named `burnline-statusline`; being wrong in the
    /// other direction means refusing to repair a user's own moved install.
    static func isOurs(_ command: String) -> Bool {
        command.hasSuffix("/burnline-statusline")
            || command.hasSuffix("/burnline-statusline.sh")
    }

    public static func state(settings: [String: Any]?, helperPath: String) -> State {
        guard let settings else { return .noSettingsFile }
        guard let raw = settings["statusLine"] else { return .notConfigured }

        guard let statusLine = raw as? [String: Any] else {
            // A shape we don't recognise. Describe it and refuse, rather than
            // guessing at a structure we might overwrite.
            return .conflict(command: (raw as? String) ?? String(describing: raw))
        }

        let command = statusLine["command"] as? String ?? ""
        guard isOurs(command) else { return .conflict(command: command) }
        return command == helperPath ? .configured : .stalePath(current: command)
    }

    /// The settings dictionary with our statusline installed.
    ///
    /// Every other key is carried across untouched — including a
    /// `refreshInterval` the user has customised. Burnline owns the `command`
    /// and nothing else.
    public static func merged(into settings: [String: Any], helperPath: String) -> [String: Any] {
        var result = settings
        var statusLine = (settings["statusLine"] as? [String: Any]) ?? [:]
        statusLine["type"] = "command"
        statusLine["command"] = helperPath
        if statusLine["refreshInterval"] == nil {
            statusLine["refreshInterval"] = refreshInterval
        }
        result["statusLine"] = statusLine
        return result
    }

    /// The snippet shown for hand-merging: for the conflict case, and for anyone
    /// who would rather an app did not edit their configuration file.
    public static func snippet(helperPath: String) -> String {
        """
        "statusLine": {
          "type": "command",
          "command": "\(helperPath)",
          "refreshInterval": \(refreshInterval)
        }
        """
    }
}
