import Foundation

/// The pace references the percent chart draws: the whole-week diagonal, and
/// after a re-grant a second line for the allowance in force.
///
/// **Why there are two (History check fix 5, chosen by Sean 2026-11-26).**
/// After a mid-week re-grant the new allowance's curve restarts near 0% under
/// the whole-week diagonal, so it read "far under pace" against a line drawn
/// for an allowance that had ended (on the 24 Nov re-grant, 1% at day 4.2
/// against a diagonal at 60%).
///
/// 🔴 **The whole-week diagonal does not move.** The pace TARGET does not
/// re-base (`CLAUDE.md`: "Extrapolation and projection re-base onto the
/// epoch; the pace target does not"): the popover's pace figure and the menu
/// bar are untouched. The second line is an addition on the chart only, and it
/// starts where the projection's epoch starts, so the chart and the popover's
/// "Rate since re-grant" row measure the new allowance from the same point.
///
/// Geometry lives here, not in the view, because `Sources/Burnline` has no
/// test target.
public enum HistoryPace {
    /// A straight dashed line on the elapsed-by-percent plane.
    public struct Segment: Equatable, Sendable {
        public let fromFraction: Double
        public let fromPercent: Double
        public let toFraction: Double
        public let toPercent: Double

        public init(fromFraction: Double, fromPercent: Double,
                    toFraction: Double, toPercent: Double) {
            self.fromFraction = fromFraction
            self.fromPercent = fromPercent
            self.toFraction = toFraction
            self.toPercent = toPercent
        }

        /// The point `t` of the way along the line (0 at its start, 1 at its
        /// end), on both axes.
        public func point(along t: Double) -> (fraction: Double, percent: Double) {
            (fromFraction + (toFraction - fromFraction) * t,
             fromPercent + (toPercent - fromPercent) * t)
        }
    }

    /// How far along the re-based line its label hangs.
    ///
    /// ⚠️ **Not the midpoint.** The whole-week label already hangs at the
    /// diagonal's midpoint, and on the first synthetic shot the two labels
    /// printed over each other ("pacpace since re-grant"). The two lines
    /// converge at the reset, so the gap between them is widest near the
    /// re-grant; a third of the way along leaves room above the line and
    /// below the diagonal, clear of the ring's "re-granted" label.
    public static let sinceRegrantLabelPosition = 0.3

    /// The window's own pace: none of the allowance at the start, all of it at
    /// the reset. Calendar arithmetic, so it is the one line that cannot be
    /// wrong, and it is the same whether or not the week was re-granted.
    public static let wholeWeek = Segment(fromFraction: 0, fromPercent: 0, toFraction: 1,
                                          toPercent: HistoryChartMode.fullAllowance)

    public static let wholeWeekLabel = "pace"
    public static let sinceRegrantLabel = "pace since re-grant"

    /// Pace for the allowance in force at the end of the series: from its
    /// first reading (the ring) to the whole allowance at the reset.
    ///
    /// - **The LAST re-grant only.** An earlier re-granted allowance has ended
    ///   too and has no pace left to keep.
    /// - **From the first reading after the drop, at its own figure, never 0
    ///   at the drop.** The re-grant instant is unrecoverable (see
    ///   `HistoryQuery.RegrantMarker`); the first reading is the earliest
    ///   proof the new allowance was in force, which is also where
    ///   `Snapshot.Regrant` opens the projection's epoch.
    /// - **Nil when there is no line to draw**: no re-grant, a re-grant first
    ///   seen at the reset, or a new allowance already at the whole allowance.
    public static func sinceRegrant(_ series: HistoryQuery.PercentSeries) -> Segment? {
        guard let regrant = series.regrants.last,
              regrant.knownByFraction.isFinite, regrant.percentAfter.isFinite,
              regrant.knownByFraction < 1,
              regrant.percentAfter < HistoryChartMode.fullAllowance else { return nil }
        return Segment(fromFraction: regrant.knownByFraction, fromPercent: regrant.percentAfter,
                       toFraction: 1, toPercent: HistoryChartMode.fullAllowance)
    }
}
