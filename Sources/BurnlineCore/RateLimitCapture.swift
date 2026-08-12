import Foundation

/// What the Burnline statusline helper captured from Claude Code.
///
/// This is the only supported source of true subscription usage — there is no
/// API, no CLI and no other local file that exposes it. Claude Code pipes
/// session JSON to a statusline command on every assistant response, and that
/// payload carries `rate_limits.seven_day.{used_percentage,resets_at}`.
///
/// Timestamps stay as unix seconds because that is what the helper writes;
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

    /// Whether the five-hour block proves this payload is a replay of a cached
    /// reading rather than something fresh.
    ///
    /// Every open Claude Code session runs the statusline on its own timer and
    /// republishes the `rate_limits` block from *its own* last API response, so
    /// an idle session rewrites this file forever with a reading that never
    /// changes. A payload produced while the current five-hour window ended at
    /// `T` cannot have been produced after `T` — so a five-hour window that had
    /// already expired at stamping time dates the payload as a replay.
    ///
    /// **Sufficient, not necessary.** `five_hour` is absent on some plans, and a
    /// replay less than five hours old hasn't outlived its own window yet. This
    /// catches the case that actually bites: a session idle for hours.
    public var isRepublishedCache: Bool {
        guard let fiveHour else { return false }
        return fiveHour.resetsAt < capturedAt
    }

    /// The same capture, dated to the latest instant it could actually have been
    /// produced.
    ///
    /// The percentage is left alone: it is a real reading and the best available.
    /// Discarding it would drop the app to pace-only on a Mac where every session
    /// is idle, which is precisely the situation being detected. Only the
    /// timestamp was a lie, and an honest one lets the popover's existing
    /// "Extrapolated" styling tell the truth by itself.
    ///
    /// Idempotent: a corrected capture has `capturedAt == fiveHour.resetsAt`,
    /// and the test above is strict.
    public func correctedForRepublishing() -> RateLimitCapture {
        guard isRepublishedCache, let fiveHour else { return self }
        var corrected = self
        corrected.capturedAt = fiveHour.resetsAt
        return corrected
    }
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

    /// Written by the `burnline-statusline` helper. Absent until Claude Code
    /// has produced at least one response with the statusline configured.
    /// Corrected on the way in, not just on the way out of the helper: this file
    /// has many writers. The rollback script, or an older build still sitting in
    /// someone's bundle, will keep stamping replays with `Date()`.
    public func load() -> RateLimitCapture? {
        guard let data = try? Data(contentsOf: url),
              let capture = try? JSONDecoder().decode(RateLimitCapture.self, from: data),
              capture.isCompatible
        else { return nil }
        return capture.correctedForRepublishing()
    }

    /// Written by the `burnline-statusline` helper after every assistant
    /// response.
    ///
    /// `.atomic` is required, not tidiness: `UsageStore` re-reads this file on a
    /// 10-second timer and must never observe a partial write. Foundation
    /// implements it as a write-to-temporary plus rename, matching the
    /// `> tmp && mv -f` contract of the shell script this replaced.
    public func save(_ capture: RateLimitCapture) throws {
        try JSONEncoder().encode(capture).write(to: url, options: .atomic)
    }
}
