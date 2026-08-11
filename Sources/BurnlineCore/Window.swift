import Foundation

/// A single reset-to-reset window, plus where `now` sits inside it.
public struct Window: Equatable, Sendable {
    public let start: Date
    public let end: Date
    public let now: Date

    public init(start: Date, end: Date, now: Date) {
        self.start = start
        self.end = end
        self.now = now
    }

    public var totalDuration: TimeInterval { end.timeIntervalSince(start) }

    /// 0...1, clamped. Guards a zero-length window.
    public var elapsedFraction: Double {
        guard totalDuration > 0 else { return 0 }
        return min(max(now.timeIntervalSince(start) / totalDuration, 0), 1)
    }

    /// Exact. This is the "where you should be" number.
    public var targetPercent: Double { elapsedFraction * 100 }

    /// 0...7. Day 5.0 means five full days elapsed.
    public var dayIndex: Double { elapsedFraction * 7 }

    /// Where you may be by the time the current window-day ends — the whole-day
    /// budget rather than the second-by-second one.
    ///
    /// Days are window-aligned, not calendar-aligned: a window starting Friday
    /// 02:00 has days ending at 02:00. That keeps this consistent with
    /// `dayIndex`, which the popover already shows as "Day 4.5 of 7".
    ///
    /// Rounds up, so mid-day-5 allows 5/7. Landing exactly on a boundary does
    /// *not* advance a further day — at day 5.0 the allowance is 5/7, since
    /// that day has just finished rather than just begun.
    public var endOfDayPercent: Double {
        let day = dayIndex
        let wholeDays = day.rounded(.up)
        // Exactly on a boundary (including 0) still gets the day it sits in.
        let allowed = wholeDays == day ? max(day, 1) : wholeDays
        return min(allowed * (100.0 / 7), 100)
    }

    public var timeRemaining: TimeInterval { max(0, end.timeIntervalSince(now)) }
}
