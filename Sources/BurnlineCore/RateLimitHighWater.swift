import Foundation

/// The highest reading seen inside a given window, so a stale capture can't drag
/// the figure backwards.
///
/// **Why this is needed.** Several Claude Code sessions can be open at once, and
/// every one of them runs the statusline script on its own `refreshInterval`
/// timer, writing the same `rate-limits.json`. Nothing coordinates them: the
/// last writer wins, and "last" has nothing to do with "freshest". Each session
/// carries the `rate_limits` block from *its own* last API response, so a
/// session sitting idle for an hour clobbers a current reading with an old one
/// twice a minute. Observed 2026-08-11 with five sessions open, two of them
/// ~5 hours old.
///
/// **Why taking the maximum is sound.** Usage inside a fixed window is
/// cumulative. It cannot go down. So a reading lower than one already observed
/// in the same window is necessarily staler — never a correction. The only case
/// this would suppress is a genuine downward revision by Anthropic mid-window,
/// which isn't a thing cumulative usage does; if it ever happened, the mark
/// clears by itself at the next reset.
public struct RateLimitHighWater: Equatable, Sendable, Codable {

    /// A reading on disk that the high-water mark overrode, kept so the popover
    /// can say so.
    ///
    /// Without this the app silently disagrees with the user's own terminal
    /// status line — which reads as a broken app rather than as the protection
    /// it is. `BurnlineProbe` has always printed it; the UI never did.
    public struct RejectedReading: Equatable, Sendable {
        public let reportedPercent: Double
        public let usingPercent: Double

        public init(reportedPercent: Double, usingPercent: Double) {
            self.reportedPercent = reportedPercent
            self.usingPercent = usingPercent
        }

        /// Assembled here, like `FiveHourStatus.rowValue`, so no view body does
        /// formatting of its own.
        public var rowValue: String {
            "said \(DisplayValue.whole(reportedPercent))%, kept \(DisplayValue.whole(usingPercent))%"
        }
    }

    /// What the file said versus what is being shown, when the two differ.
    ///
    /// `nil` in the ordinary case — this surfaces as an exceptions-only row, per
    /// the portfolio status-chip standard.
    public static func rejection(onDisk: RateLimitCapture,
                                 resolved: RateLimitCapture) -> RejectedReading? {
        let reported = onDisk.sevenDay.usedPercent
        let using = resolved.sevenDay.usedPercent
        guard using > reported else { return nil }
        return RejectedReading(reportedPercent: reported, usingPercent: using)
    }

    /// A high-water mark for one reading, tied to the window it was taken in.
    public struct Mark: Equatable, Sendable, Codable {
        public var resetsAt: TimeInterval
        public var usedPercent: Double
        public var capturedAt: TimeInterval

        public init(resetsAt: TimeInterval, usedPercent: Double, capturedAt: TimeInterval) {
            self.resetsAt = resetsAt
            self.usedPercent = usedPercent
            self.capturedAt = capturedAt
        }
    }

    /// Bump when the *meaning* of a stored mark changes, not merely its shape.
    ///
    /// Marks written before capture dating existed hold a `capturedAt` taken
    /// straight from `Date()` — a republished reading stamped as fresh. Since a
    /// mark ties on percentage, the "equal re-confirmation takes the later date"
    /// rule then preserves that stale timestamp for the rest of the window. The
    /// only symptom is a figure that looks fresher than it is, which is exactly
    /// the class of bug this file exists to prevent.
    ///
    /// Same treatment as `ScanCache`: discard, never migrate. This is derived
    /// state and rebuilds from the next capture.
    public static let currentVersion = 1

    public var version: Int
    public var sevenDay: Mark?
    public var fiveHour: Mark?

    public init(version: Int = RateLimitHighWater.currentVersion,
                sevenDay: Mark? = nil, fiveHour: Mark? = nil) {
        self.version = version
        self.sevenDay = sevenDay
        self.fiveHour = fiveHour
    }

    public var isCompatible: Bool { version == Self.currentVersion }

    public static let empty = RateLimitHighWater()

    /// Returns the capture to trust, and the mark to persist.
    ///
    /// The seven-day and five-hour readings carry independent reset instants and
    /// are reconciled separately — a five-hour window rolls several times inside
    /// one weekly window, so one says nothing about the other.
    public static func reconcile(_ capture: RateLimitCapture,
                                 against highWater: RateLimitHighWater)
    -> (capture: RateLimitCapture, highWater: RateLimitHighWater) {

        let (sevenDay, sevenMark) = best(capture.sevenDay,
                                         capturedAt: capture.capturedAt,
                                         against: highWater.sevenDay)

        var fiveHour: RateLimitCapture.Reading?
        var fiveMark: Mark?
        if let reading = capture.fiveHour {
            let (resolved, mark) = best(reading, capturedAt: capture.capturedAt,
                                        against: highWater.fiveHour)
            fiveHour = resolved
            fiveMark = mark
        }
        // A capture with no five-hour block must not resurrect an earlier one:
        // the plan may simply not report it.

        // The seven-day reading is the one the headline figure comes from, so it
        // owns the capture's age. Reporting a rejected reading's timestamp would
        // present a stale number as having just landed.
        let resolved = RateLimitCapture(version: capture.version,
                                        capturedAt: sevenMark.capturedAt,
                                        sevenDay: sevenDay,
                                        fiveHour: fiveHour)

        return (resolved, RateLimitHighWater(sevenDay: sevenMark, fiveHour: fiveMark))
    }

    /// Equal counts as fresh: re-reporting the same percentage is a new
    /// confirmation of it, so the age moves even though the value doesn't — but
    /// only ever *forwards*. Timestamps stopped being monotonic once a
    /// republished payload started being dated by its own expired five-hour
    /// window (see `RateLimitCapture.correctedForRepublishing`), so a replay of
    /// a value already confirmed more recently must not pull the age backwards.
    ///
    /// A strictly *higher* reading keeps its own date even when that date is
    /// older, because it is new information and the figure is only as fresh as
    /// the moment it was actually learned.
    /// Two sources describe the same window to different precision: the
    /// statusline reports whole epoch seconds (`1786690800`), while
    /// `cachedUsageUtilization` reports `2026-08-14T06:59:59.424563+00:00` — the
    /// same instant, 0.58s earlier. Found against real data 2026-08-12.
    ///
    /// Exact equality would treat those as different windows, so each source
    /// would keep its own mark and the protection would silently degrade
    /// whenever they alternate. Real windows are five hours or seven days apart,
    /// so a minute of tolerance cannot merge two of them.
    static let sameWindowTolerance: TimeInterval = 60

    private static func isSameWindow(_ a: TimeInterval, _ b: TimeInterval) -> Bool {
        abs(a - b) <= sameWindowTolerance
    }

    private static func best(_ reading: RateLimitCapture.Reading,
                             capturedAt: TimeInterval,
                             against mark: Mark?) -> (RateLimitCapture.Reading, Mark) {
        guard let mark, isSameWindow(mark.resetsAt, reading.resetsAt) else {
            return (reading, Mark(resetsAt: reading.resetsAt,
                                  usedPercent: reading.usedPercent,
                                  capturedAt: capturedAt))
        }
        if reading.usedPercent < mark.usedPercent {
            return (RateLimitCapture.Reading(usedPercent: mark.usedPercent,
                                             resetsAt: mark.resetsAt),
                    mark)
        }
        let confirmedAt = reading.usedPercent == mark.usedPercent
            ? max(capturedAt, mark.capturedAt)
            : capturedAt
        return (reading, Mark(resetsAt: reading.resetsAt,
                              usedPercent: reading.usedPercent,
                              capturedAt: confirmedAt))
    }
}

public struct HighWaterStore: Sendable {
    private let url: URL

    public init(directory: URL = ApplicationSupport.directory()) {
        url = directory.appendingPathComponent("rate-limit-highwater.json")
    }

    /// A mark with no version, or a version this build doesn't know, is
    /// discarded. A pre-versioning file has no `version` key at all, so the
    /// decode itself fails — which is the intended migration, not an accident.
    public func load() -> RateLimitHighWater {
        guard let data = try? Data(contentsOf: url),
              let mark = try? JSONDecoder().decode(RateLimitHighWater.self, from: data),
              mark.isCompatible
        else { return .empty }
        return mark
    }

    public func save(_ mark: RateLimitHighWater) throws {
        try JSONEncoder().encode(mark).write(to: url, options: .atomic)
    }
}
