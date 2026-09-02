import Foundation

/// Where "today" ends, for the end-of-day allowance.
///
/// These differ by however far the reset sits from midnight. A window that
/// resets Friday 02:00 has window-days ending at 02:00, two hours after the
/// calendar day.
public enum DayBoundary: String, Equatable, Sendable, Codable, CaseIterable {
    /// Days aligned to the reset instant. Agrees with the "Day 4.5 of 7" row.
    case windowDay
    /// Days end at local midnight. Agrees with the wall clock.
    case calendarDay

    public var title: String {
        switch self {
        case .windowDay: return "Window day"
        case .calendarDay: return "Calendar day"
        }
    }

    /// ⚠️ The calendar-day sentence deliberately ends without a full stop:
    /// Settings appends the contrast with the reset clock to it, and only when
    /// the two actually differ. A reset at midnight has no contrast to draw.
    public var explanation: String {
        switch self {
        case .windowDay: return "Days run from the reset time, matching the day counter."
        case .calendarDay: return "Days end at midnight, matching the wall clock"
        }
    }
}
