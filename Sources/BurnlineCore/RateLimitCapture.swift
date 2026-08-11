import Foundation

/// What the Burnline statusline script captured from Claude Code.
///
/// This is the only supported source of true subscription usage — there is no
/// API, no CLI and no other local file that exposes it. Claude Code pipes
/// session JSON to a statusline script on every assistant response, and that
/// payload carries `rate_limits.seven_day.{used_percentage,resets_at}`.
///
/// Timestamps stay as unix seconds because that is what the script writes;
/// `Date` accessors sit on top rather than needing custom decoders.
public struct RateLimitCapture: Equatable, Sendable, Codable {
    public static let currentVersion = 1

    public struct Reading: Equatable, Sendable, Codable {
        public var usedPercent: Double
        public var resetsAt: TimeInterval

        public init(usedPercent: Double, resetsAt: TimeInterval) {
            self.usedPercent = usedPercent
            self.resetsAt = resetsAt
        }

        public var resetsDate: Date { Date(timeIntervalSince1970: resetsAt) }
    }

    public var version: Int
    public var capturedAt: TimeInterval
    public var sevenDay: Reading
    public var fiveHour: Reading?

    public init(version: Int, capturedAt: TimeInterval, sevenDay: Reading, fiveHour: Reading?) {
        self.version = version
        self.capturedAt = capturedAt
        self.sevenDay = sevenDay
        self.fiveHour = fiveHour
    }

    public var capturedDate: Date { Date(timeIntervalSince1970: capturedAt) }
    public var isCompatible: Bool { version == Self.currentVersion }
}

/// Where the usage figure came from. Drives what the popover claims.
public enum UsageSource: Equatable, Sendable {
    /// Exact, straight from Claude Code.
    case live(capturedAt: Date)
    /// Estimated from the user's own `/usage` readings.
    case calibrated
    /// No usage figure at all — the pace target alone.
    case paceOnly
}

public struct RateLimitStore: Sendable {
    private let url: URL

    public init(directory: URL = ApplicationSupport.directory()) {
        url = directory.appendingPathComponent("rate-limits.json")
    }

    /// Written by `~/.claude/burnline-statusline.sh`. Absent until Claude Code
    /// has produced at least one response with the statusline configured.
    public func load() -> RateLimitCapture? {
        guard let data = try? Data(contentsOf: url),
              let capture = try? JSONDecoder().decode(RateLimitCapture.self, from: data),
              capture.isCompatible
        else { return nil }
        return capture
    }
}
