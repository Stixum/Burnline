import Foundation

/// The typed fallback schedule. Exact arithmetic on a guess.
public enum WindowMath {

    /// The reset-to-reset window containing `now`, from the schedule the user
    /// typed. Used only until a reset has been observed: once one has, the
    /// window comes from `SnapshotBuilder.windowFromReset` instead.
    ///
    /// ⚠️ **Wall-clock on purpose, and therefore not Anthropic's rule.** The
    /// real reset is fixed in UTC and every week is 168 hours
    /// (`SnapshotBuilder.weekSeconds`). A typed "Friday 2:00" has no UTC
    /// instant to hold — nothing says which side of a clock change it was
    /// read on — so it holds the wall-clock time, and a week containing a DST
    /// transition is 167 or 169 hours here. The cost: after a clock change the
    /// typed time is an hour off the real reset until the user moves it or a
    /// capture lands.
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
