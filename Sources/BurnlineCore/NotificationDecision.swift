import Foundation

/// Which threshold notifications to emit for a snapshot, and the marks that
/// record them. Pure — no clock reads, no I/O — mirroring `PollDecision`, so
/// the only part of this feature that can be subtly wrong is fully tested.
///
/// "Crossing" is defined without previous-snapshot state: a signal fires when
/// its value is at or past the threshold and no suppressing mark exists. So
/// enabling mid-window while already past a threshold fires on the next
/// evaluation, and a capture correcting the estimate downward then climbing
/// back does not re-fire — the mark from the first crossing still stands.
public enum NotificationDecision {
    public enum Signal: String, Sendable {
        case behindPace = "behind-pace"
        case weekly
        case fiveHour = "five-hour"
    }

    /// One notification to deliver. Body text is assembled here, not in the
    /// app layer, so it is tested; word + number, never color alone.
    public struct Emission: Equatable, Sendable {
        public let signal: Signal
        public let title: String
        public let body: String
        public var identifier: String { "burnline.\(signal.rawValue)" }
    }

    public static func evaluate(snapshot: Snapshot,
                                settings: NotificationSettings,
                                targetMode: TargetMode,
                                marks: NotificationMarks,
                                timeZone: TimeZone = .current)
    -> (emissions: [Emission], marks: NotificationMarks) {
        guard settings.enabled else { return ([], marks) }

        var emissions: [Emission] = []
        var updated = marks
        let weeklyReset = snapshot.window.end.timeIntervalSince1970

        // Behind pace: delta is positive-means-under-budget, so "behind by N
        // points" is delta <= -N. Evaluated against the user's configured
        // Compare-against mode — the same number the popover headline shows.
        if let delta = snapshot.delta(targetMode), delta <= -settings.behindPacePoints,
           !NotificationMarks.suppresses(marks.behindPace, resetsAt: weeklyReset,
                                         threshold: settings.behindPacePoints) {
            let day = DisplayValue.floor(min(snapshot.window.dayIndex, 6)) + 1
            emissions.append(Emission(
                signal: .behindPace,
                title: "Behind pace",
                body: "\(DisplayValue.whole(-delta)) points over target, day \(day) of 7"))
            updated.behindPace = NotificationMarks.Mark(
                resetsAt: weeklyReset, threshold: settings.behindPacePoints)
        }

        // Weekly: the displayed estimate, extrapolation included. Monotonic
        // between captures, so once-per-window is the chatter defence.
        if let estimate = snapshot.estimatedPercent, estimate >= settings.weeklyPercent,
           !NotificationMarks.suppresses(marks.weekly, resetsAt: weeklyReset,
                                         threshold: settings.weeklyPercent) {
            emissions.append(Emission(
                signal: .weekly,
                title: "Weekly usage at \(DisplayValue.whole(estimate))%",
                body: "Resets \(resetDescription(snapshot.window.end, timeZone: timeZone))"))
            updated.weekly = NotificationMarks.Mark(
                resetsAt: weeklyReset, threshold: settings.weeklyPercent)
        }

        // 5-hour: the capture's own figure, never extrapolated. The mark keys
        // on this window's *own* reset — it rolls several times inside one
        // weekly window and neither says anything about the other.
        if let five = snapshot.fiveHour, five.usedPercent >= settings.fiveHourPercent,
           !NotificationMarks.suppresses(marks.fiveHour,
                                         resetsAt: five.resetsAt.timeIntervalSince1970,
                                         threshold: settings.fiveHourPercent) {
            emissions.append(Emission(
                signal: .fiveHour,
                title: "5-hour window at \(DisplayValue.whole(five.usedPercent))%",
                body: "Resets in \(five.remainingDescription)"))
            updated.fiveHour = NotificationMarks.Mark(
                resetsAt: five.resetsAt.timeIntervalSince1970,
                threshold: settings.fiveHourPercent)
        }

        return (emissions, updated)
    }

    /// "Tuesday 9:00 PM" — the weekly reset in the user's own clock.
    static func resetDescription(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEE jmm")
        return formatter.string(from: date)
    }
}
