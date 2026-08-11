import Foundation

/// Pure calendar arithmetic. This half of Burnline is exact.
public enum WindowMath {

    /// The reset-to-reset window containing `now`.
    ///
    /// The end is computed with calendar arithmetic rather than by adding
    /// 604_800 seconds, so the reset holds its wall-clock time across a DST
    /// transition — those weeks are 167 or 169 hours long.
    public static func window(for schedule: ResetSchedule, now: Date) -> Window {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = schedule.timeZone

        let components = DateComponents(
            hour: schedule.hour,
            minute: schedule.minute,
            second: 0,
            weekday: schedule.weekday
        )

        // Search backward from one second after `now` so that an instant landing
        // exactly on the reset opens the new window rather than closing the old.
        let start = calendar.nextDate(
            after: now.addingTimeInterval(1),
            matching: components,
            matchingPolicy: .nextTime,
            direction: .backward
        ) ?? now

        let end = calendar.date(byAdding: .day, value: 7, to: start)
            ?? start.addingTimeInterval(7 * 86_400)

        return Window(start: start, end: end, now: now)
    }
}
