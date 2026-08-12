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

    public var sevenDay: Mark?
    public var fiveHour: Mark?

    public init(sevenDay: Mark? = nil, fiveHour: Mark? = nil) {
        self.sevenDay = sevenDay
        self.fiveHour = fiveHour
    }

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
    private static func best(_ reading: RateLimitCapture.Reading,
                             capturedAt: TimeInterval,
                             against mark: Mark?) -> (RateLimitCapture.Reading, Mark) {
        guard let mark, mark.resetsAt == reading.resetsAt else {
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

    public func load() -> RateLimitHighWater {
        guard let data = try? Data(contentsOf: url),
              let mark = try? JSONDecoder().decode(RateLimitHighWater.self, from: data)
        else { return .empty }
        return mark
    }

    public func save(_ mark: RateLimitHighWater) throws {
        try JSONEncoder().encode(mark).write(to: url, options: .atomic)
    }
}
