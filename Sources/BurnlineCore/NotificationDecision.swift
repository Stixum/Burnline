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
        /// A per-model weekly limit graded `warning` or worse by Anthropic.
        case modelWeekly = "model-weekly"
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
        // The allowance the weekly signals are measuring. Anthropic sometimes
        // re-issues the allowance *inside* a window without moving
        // `resets_at`, and usage then climbs from zero and can cross the same
        // threshold again — a genuinely new event. Keyed on the reset alone
        // that second crossing is silent forever. With no re-grant open the
        // epoch is the window's own start, so the ordinary case is unchanged.
        let weeklyEpoch = (snapshot.regrant?.startedAt ?? snapshot.window.start)
            .timeIntervalSince1970

        // Behind pace: delta is positive-means-under-budget, so "behind by N
        // points" is delta <= -N. Evaluated against the user's configured
        // Compare-against mode — the same number the popover headline shows.
        if let delta = snapshot.delta(targetMode), delta <= -settings.behindPacePoints,
           !NotificationMarks.suppresses(marks.behindPace, resetsAt: weeklyReset,
                                         threshold: settings.behindPacePoints,
                                         epochStartedAt: weeklyEpoch) {
            let day = DisplayValue.floor(min(snapshot.window.dayIndex, 6)) + 1
            emissions.append(Emission(
                signal: .behindPace,
                title: "Behind pace",
                body: "\(DisplayValue.points(-delta)) behind pace, day \(day) of 7"))
            updated.behindPace = NotificationMarks.Mark(
                resetsAt: weeklyReset, threshold: settings.behindPacePoints,
                epochStartedAt: weeklyEpoch)
        }

        // Weekly: the displayed estimate, extrapolation included. Monotonic
        // between captures, so once-per-window is the chatter defence.
        if let estimate = snapshot.estimatedPercent, estimate >= settings.weeklyPercent,
           !NotificationMarks.suppresses(marks.weekly, resetsAt: weeklyReset,
                                         threshold: settings.weeklyPercent,
                                         epochStartedAt: weeklyEpoch) {
            emissions.append(Emission(
                signal: .weekly,
                title: "Weekly usage at \(DisplayValue.whole(estimate))%",
                body: "Resets \(resetDescription(snapshot.window.end, timeZone: timeZone))"))
            updated.weekly = NotificationMarks.Mark(
                resetsAt: weeklyReset, threshold: settings.weeklyPercent,
                epochStartedAt: weeklyEpoch)
        }

        // 5-hour: the capture's own figure, never extrapolated. The mark keys
        // on this window's *own* reset — it rolls several times inside one
        // weekly window and neither says anything about the other.
        //
        // 🔴 And on this window's own START as its epoch, never `weeklyEpoch`.
        // A weekly re-grant re-arming the five-hour signal would contradict the
        // independence rule above: the weekly allowance says nothing about a
        // window that resets several times inside it.
        if let five = snapshot.fiveHour, five.usedPercent >= settings.fiveHourPercent,
           !NotificationMarks.suppresses(marks.fiveHour,
                                         resetsAt: five.resetsAt.timeIntervalSince1970,
                                         threshold: settings.fiveHourPercent,
                                         epochStartedAt: five.startedAt.timeIntervalSince1970) {
            emissions.append(Emission(
                signal: .fiveHour,
                title: "5-hour window at \(DisplayValue.whole(five.usedPercent))%",
                body: "Resets in \(five.remainingDescription)"))
            updated.fiveHour = NotificationMarks.Mark(
                resetsAt: five.resetsAt.timeIntervalSince1970,
                threshold: settings.fiveHourPercent,
                epochStartedAt: five.startedAt.timeIntervalSince1970)
        }

        // Per-model weekly (Fable on Sean's plan): Anthropic's own grade, no
        // threshold of ours. It can stop a model's work while the all-models
        // figure above has room (2026-11-26: Fable 94% `critical`, all models
        // 74% `normal`, and no alert). Fires once per grade per allowance: a
        // warning, then a critical, never the same grade twice and never on the
        // way back down.
        //
        // Only for the window on screen: a cached block from a week that has
        // ended, or an entry with no reset at all, cannot be placed in it.
        // Keyed on the weekly epoch, so a re-grant re-arms it.
        if let scoped = snapshot.scopedWeekly,
           let level = ModelLimitAlert.level(scoped.rowStyle),
           let resetsAt = scoped.resetsAt,
           abs(resetsAt.timeIntervalSince(snapshot.window.end)) <= WindowLedger.sameResetTolerance,
           !ModelLimitAlert.suppresses(marks.modelWeekly, resetsAt: weeklyReset,
                                       level: level, epochStartedAt: weeklyEpoch) {
            emissions.append(Emission(
                signal: .modelWeekly,
                title: "\(scoped.rowLabel) limit at \(DisplayValue.whole(scoped.percent))%",
                body: "Anthropic grades it \(scoped.gradeWord ?? "raised"). "
                    + "Resets \(resetDescription(snapshot.window.end, timeZone: timeZone))."))
            updated.modelWeekly = NotificationMarks.Mark(
                resetsAt: weeklyReset, threshold: level, epochStartedAt: weeklyEpoch)
        }

        return (emissions, updated)
    }

    /// The per-model alert's grades, as the mark's `threshold`: a warning is 1,
    /// critical is 2. A mark suppresses its own grade and every lower one, so
    /// a warning after a critical says nothing new.
    enum ModelLimitAlert {
        static func level(_ style: UsageUtilization.ScopedLimit.Style) -> Double? {
            switch style {
            case .plain: nil
            case .warning: 1
            case .critical: 2
            }
        }

        static func suppresses(_ mark: NotificationMarks.Mark?, resetsAt: TimeInterval,
                               level: Double, epochStartedAt: TimeInterval) -> Bool {
            guard let mark else { return false }
            return abs(mark.resetsAt - resetsAt) <= WindowLedger.sameResetTolerance
                && abs(mark.epochStartedAt - epochStartedAt) <= WindowLedger.sameResetTolerance
                && mark.threshold >= level
        }
    }

    /// "Tuesday 9:00 PM" — the weekly reset in the user's own clock, to the
    /// minute. Through `ResetSchedule.description` like every other surface:
    /// formatted raw, a reset half a second short of midnight read as the
    /// previous day at 11:59 PM.
    static func resetDescription(_ date: Date, timeZone: TimeZone) -> String {
        ResetSchedule.description(of: date, .full, on: timeZone)
    }
}
