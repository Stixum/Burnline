import Foundation

/// What the Burnline statusline helper captured from Claude Code.
///
/// Claude Code pipes session JSON to a statusline command on every assistant
/// response, and that payload carries
/// `rate_limits.seven_day.{used_percentage,resets_at}`.
///
/// ⚠️ This comment used to claim it was "the only supported source ... no other
/// local file that exposes it". That was false when written and is false now:
/// `UtilizationStore` reads `cachedUsageUtilization` out of `~/.claude.json`
/// and `UsageUtilization.asCapture()` feeds it into this same type, competing
/// on age. What genuinely does not exist is an **API** carrying subscription
/// usage. A negative about one interface is not a negative about the system.
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
    /// Which Claude Code session produced this reading, when the payload said so.
    ///
    /// `rate_limits` is that session's own cached snapshot, refreshed only when
    /// *it* calls the API — so knowing the session is what makes an exact mint
    /// time derivable at all.
    ///
    /// Optional, and no version bump: a file written before these fields existed
    /// decodes with `nil` and keeps working.
    public var sessionId: String?
    /// That session's transcript. The app reads its tail to find the last
    /// assistant turn; the helper never touches it.
    public var transcriptPath: String?

    /// The instant at which this reading can be PROVEN to have been minted —
    /// an explicit `fetchedAtMs`, or an exact `TranscriptDating.mintedAt`.
    ///
    /// Distinct from `capturedAt`, which is a conservative upper bound. Only a
    /// proven date may demote a high-water mark: an inferred one can overstate
    /// freshness, and overstating freshness is the failure that matters.
    ///
    /// 🔴 Excluded from `CodingKeys` and defaulting to nil, so anything decoded
    /// off disk is inferred. Sound because the app never re-saves captures —
    /// `RateLimitStore.save` and `CaptureDirectory.save` are helper-side, and
    /// `UsageStore.rebuild` re-dates every candidate on every pass.
    ///
    /// Deliberately survives `correctedForRepublishing()` untouched: that
    /// method only ever narrows `capturedAt` to a more conservative estimate,
    /// while `provenAt` is the one honest fact and must never be narrowed
    /// alongside it. The two are allowed to diverge there.
    public var provenAt: TimeInterval?

    private enum CodingKeys: String, CodingKey {
        case version, capturedAt, sevenDay, fiveHour, sessionId, transcriptPath
    }

    public init(version: Int, capturedAt: TimeInterval, sevenDay: Reading, fiveHour: Reading?,
                sessionId: String? = nil, transcriptPath: String? = nil) {
        self.version = version
        self.capturedAt = capturedAt
        self.sevenDay = sevenDay
        self.fiveHour = fiveHour
        self.sessionId = sessionId
        self.transcriptPath = transcriptPath
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

    /// `capturedAt` narrowed by every piece of evidence available.
    ///
    /// `mintedAt` is the exact instant this session last called the API, which is
    /// when its `rate_limits` was refreshed — precise, where
    /// `correctedForRepublishing` only ever supplies an upper bound, needs
    /// `five_hour` to exist, and cannot see a replay younger than five hours.
    ///
    /// Both rules are applied and the **earlier** wins. They cannot both be true
    /// when they disagree, and overstating freshness is the failure that
    /// matters — a figure that looks live is acted on; one that looks old isn't.
    /// A supplied `mintedAt` is also stamped onto `provenAt`, since it's exact
    /// rather than an upper bound.
    public func dated(mintedAt: TimeInterval?) -> RateLimitCapture {
        var result = correctedForRepublishing()
        if let mintedAt {
            // A reading cannot have been minted after we saw it.
            result.capturedAt = min(result.capturedAt, mintedAt)
            result.provenAt = mintedAt
        }
        return result
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
