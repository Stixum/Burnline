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

    /// Where you may be once the current day ends — the whole-day budget rather
    /// than the second-by-second one.
    ///
    /// Both boundaries take the next day-end **strictly after** `now`, so the
    /// reading is always "end of today" in the ordinary sense: sitting exactly
    /// on a boundary means that day has just begun, and the allowance runs to
    /// the following one.
    public func endOfDayPercent(boundary: DayBoundary, timeZone: TimeZone) -> Double {
        let end: Date
        switch boundary {
        case .windowDay:
            let nextDay = dayIndex.rounded(.down) + 1
            end = start.addingTimeInterval(nextDay / 7 * totalDuration)
        case .calendarDay:
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            guard let midnight = calendar.nextDate(
                after: now,
                matching: DateComponents(hour: 0, minute: 0, second: 0),
                matchingPolicy: .nextTime
            ) else { return 100 }
            end = midnight
        }

        guard totalDuration > 0 else { return 100 }
        let fraction = end.timeIntervalSince(start) / totalDuration
        return min(max(fraction, 0), 1) * 100
    }

    public var timeRemaining: TimeInterval { max(0, end.timeIntervalSince(now)) }
}
