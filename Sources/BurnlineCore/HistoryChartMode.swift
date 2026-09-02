import Foundation

/// Which series the History window's one chart area is drawing.
///
/// 🔴 **A toggle is a mode you can occupy without noticing, and these two modes
/// know different things.** They are not two views of one quantity. Units are
/// cumulative and monotonic by construction — nothing un-spends a token — and
/// they see Claude Code on this Mac alone. A percentage is Anthropic's own
/// reading, it counts every machine, it can FALL, and it is flat wherever
/// nothing reported. Reading one while believing it is the other is a wrong
/// conclusion, not a cosmetic slip.
///
/// **That is why every string the toggle changes lives here rather than in the
/// view.** `Sources/Burnline` has no test target, so a subtitle written inline
/// in a `body` is a rule nothing can hold upright; four of them scattered
/// through a switch is four rules nothing can hold upright. Here they are one
/// value with a test that says the two modes never describe themselves the
/// same way.
///
/// `axisLabel` is the strongest of them: it is the single place either chart
/// turns a number into a y-axis tick, which makes **"the unit is the tell"** a
/// property of the type rather than a habit of whoever wrote the axis builder.
public enum HistoryChartMode: Hashable, CaseIterable, Sendable {
    /// Cumulative weighted units. Every retained week, and blind off this Mac.
    ///
    /// First, and therefore the default: it is the mode that has data for every
    /// archived week, and a toggle whose default can be empty teaches the
    /// reader that the window is broken.
    case units
    /// Anthropic's own percentage of the weekly allowance. Only from the
    /// update that started retaining the readings, forward.
    case percent

    /// The whole allowance, on the scale Anthropic reports it — the percent
    /// axis' ceiling and the far end of the pace diagonal.
    ///
    /// Named rather than spelled `100` at three call sites, because two of them
    /// are geometry and one is a domain, and a bare `100` in a chart body is
    /// indistinguishable from a magic layout constant.
    public static let fullAllowance: Double = 100

    /// The segment label. One word each: the control sits beside a heading and
    /// a subtitle that already carry the sentence.
    public var title: String {
        switch self {
        case .units: return "Units"
        case .percent: return "Percent"
        }
    }

    /// What the chart plots, printed beside the section heading.
    ///
    /// 🔴 **Required mitigation, not a caption.** Each line names its own
    /// quantity and its own axis, so switching modes visibly replaces the claim
    /// rather than leaving one that fits either series.
    ///
    /// ⚠️ The units line used to be pinned as *verbatim what the History window
    /// printed before the toggle existed* — continuity through the transition,
    /// which mattered while readers were carrying an expectation across it. That
    /// transition is over; both lines were reworded together in the 2026-09-01
    /// copy review, into the History window's own vocabulary (a **week**, not a
    /// window) and the app's one name for what Anthropic caps (a **limit**).
    public var subtitle: String {
        switch self {
        case .units:
            return "cumulative units by fraction of the week elapsed"
        case .percent:
            return "Anthropic's percentage of the weekly limit, as captured"
        }
    }

    /// What this series cannot see.
    ///
    /// The two blind spots are opposite, and each one is invisible from inside
    /// the other mode: a units curve with no reported usage looks like a quiet
    /// week, and a percent trend across a capture gap looks like a flat one.
    /// The units line names the re-grant explicitly because that is the case
    /// this whole feature exists for — a re-granted week's unit curve looks
    /// perfectly ordinary, and nothing else on screen would say so.
    public var caveat: String {
        switch self {
        case .units:
            return "Counts Claude Code on this Mac only; anything burned elsewhere is missing. "
                + "Units never fall, so a mid-window re-grant leaves no mark here."
        case .percent:
            // ⚠️ "only recent weeks", never "from this update forward". The
            // second is true on the day it ships and quietly false afterwards:
            // a reader six months later has no idea which update, and the
            // sentence describes a moment they were not present for. What they
            // can check is which weeks have readings.
            return "Anthropic's figure, so it counts every machine. It is flat wherever "
                + "nothing reported, and only recent weeks have readings."
        }
    }

    /// Nothing to draw. 🔴 **Never "nothing was used".**
    ///
    /// The two absences have different causes and different futures, and saying
    /// so is the difference between a reader waiting for data that is coming
    /// and one waiting for data that can never arrive: a week with no cells may
    /// still be filled by the next scan, while a closed week with no readings
    /// had them deleted and cannot get them back.
    public var emptyMessage: String {
        switch self {
        case .units:
            return "Nothing archived for these weeks yet."
        case .percent:
            // Same rule as `caveat`: the permanence is the load-bearing half
            // and it survives without dating itself to a release nobody
            // remembers. `cannot` stays — a reader who thinks the data is
            // still coming waits for something that can never arrive.
            return "No percentage readings for these weeks. Burnline began keeping them "
                + "recently; earlier weeks cannot get any."
        }
    }

    /// This mode's y-axis tick.
    ///
    /// 🔴 **The mode indicator.** `4.0B` versus `50%` is what tells a reader
    /// which series they are looking at when the shapes happen to resemble each
    /// other, so a bare number here is not a formatting slip — it is the
    /// indicator going missing. Both charts route their axis through this, so
    /// there is one place to get it wrong and one place tests can watch.
    public func axisLabel(_ value: Double) -> String {
        switch self {
        case .units: return HistoryLabels.units(value)
        case .percent: return HistoryLabels.percent(value)
        }
    }

    // MARK: - Percent axis

    /// The percent chart's y domain.
    ///
    /// 🔴 **A member, not a free function on the percent series, and it returns
    /// an OPTIONAL so that auto-fit is a stated answer rather than a silence.**
    /// The test this whole type is built to pass is: *would someone adding a
    /// third mode know what to fill in?* A `nil` case here is the compiler
    /// asking them what their axis ceiling is; the same rule parked on
    /// `PercentSeries` would scatter mode knowledge across two types and leave
    /// the units mode's auto-fit written down nowhere at all.
    ///
    /// - `.units` → **nil, meaning let Charts fit the data.** Correct precisely
    ///   because the unit scale IS arbitrary: `Weights` documents that
    ///   calibration divides it out, so there is no meaningful fixed ceiling to
    ///   name and no comparison a fixed one would protect.
    /// - `.percent` → **the whole allowance, fixed, never fitted.** A
    ///   percentage is the one figure in this app whose scale is not arbitrary,
    ///   which is exactly what makes fitting the units axis right and fitting
    ///   this one wrong.
    ///
    /// Three things break under an auto-fitted percent domain, all of them
    /// quietly:
    /// - a week that reached 12% renders identically to one that reached 95%,
    ///   which is the misread this chart exists to prevent;
    /// - the pace diagonal stops being the plot area's diagonal, so "above the
    ///   line" stops meaning "ahead of pace" and starts meaning nothing;
    /// - a re-grant's drop is scaled by whatever else happens to be on screen,
    ///   so the same event looks different in different weeks.
    ///
    /// The one thing the ceiling must never do is hide a reading. A reading
    /// past 100 is not obviously impossible — `used_percentage` is Anthropic's
    /// number, not ours — so the ceiling lifts to the next ten above it rather
    /// than clipping it out of the plot, which would be a measurement the chart
    /// silently declined to draw.
    public func yDomain(
        for readings: [HistoryQuery.PercentSeries]
    ) -> ClosedRange<Double>? {
        // The units mode ignores its argument, and that asymmetry is the point:
        // one mode names a ceiling and the other declines to, in one place a
        // reader can see both.
        guard case .percent = self else { return nil }

        // Non-finite readings are FILTERED, not clamped, for two reasons that
        // are both about this function and neither about `Int`:
        //
        // - `max` propagates a NaN in a way that depends on argument order, so
        //   one poisoned reading could hand back `0...nan` — a domain Charts
        //   divides the axis by — and whether it did would depend on where in
        //   the array the reading happened to sit.
        // - an infinite reading lifts the ceiling to infinity, which collapses
        //   every real curve onto the baseline.
        //
        // ⚠️ Nothing on disk can reach this: `HistoryStore.JSON.decoder` keeps
        // the default `.throw` strategy for non-conforming floats, so a NaN in
        // `tracking.json` fails its line rather than arriving here. This is
        // defence for a PUBLIC entry point — `PercentSeries` can be built by
        // any caller — and it is written down because otherwise the next reader
        // deletes it as dead code.
        let observed = readings
            .flatMap(\.points)
            .map(\.percent)
            .filter { $0.isFinite }
            .max() ?? 0
        guard observed > Self.fullAllowance else { return 0...Self.fullAllowance }
        // Floor-then-add, so the top reading is never drawn ON the frame where
        // half its stroke is clipped away.
        return 0...((observed / 10).rounded(.down) * 10 + 10)
    }
}
