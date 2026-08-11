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

    public var timeRemaining: TimeInterval { max(0, end.timeIntervalSince(now)) }
}
