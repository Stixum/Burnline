import SwiftUI
import Charts
import BurnlineCore

/// Up to three weeks of cumulative consumption, overlaid on one elapsed axis.
///
/// The axis is **fraction elapsed through the window**, not wall clock: windows
/// do not all start on the same weekday — the reset moves whenever a new one is
/// observed — so a clock axis compares Tuesday of one week to Friday of another.
///
/// **Colour encodes recency, not identity**, so identity is carried in text:
/// the legend names every week, and the live week is also named at the end of
/// its line (`HistoryEndLabels.isLabelled`). Nothing here is distinguished by
/// colour alone.
struct HistoryBurnCurves: View {
    /// Newest first among what is drawn. 🔴 Each entry carries its OWN ramp
    /// position — this array is filtered (a week with one point or fewer is
    /// omitted) and recency is not, so `enumerated()` is the wrong index. See
    /// `HistoryOverlay`.
    let curves: [HistoryUnitCurve]
    /// Where the live window is right now — the "you are here" line.
    let nowFraction: Double

    /// Eight ticks, one per window boundary and day. Stored rather than derived
    /// in the axis builder: no view body in this codebase does arithmetic, and
    /// an axis is not an exception.
    private static let dayTicks: [Double] = [0, 1, 2, 3, 4, 5, 6, 7].map { $0 / 7 }
    private static let dayLabels = ["Start", "1", "2", "3", "4", "5", "6", "Reset"]

    /// One drawn vertex, flattened out of the nested series.
    ///
    /// ⚠️ Not a refactor for taste: `ForEach` over enumerated tuples, wrapping a
    /// `ForEach` over indices, wrapping a `LineMark` built from a subscript
    /// chain, **exceeds the type checker's budget** and fails the build with
    /// "unable to type-check this expression in reasonable time". Concrete types
    /// at the leaves are what makes a Swift Charts body compile.
    private struct Sample: Identifiable {
        let id: Int
        let series: String
        let fraction: Double
        let units: Double
    }

    /// The end of one series, where its direct label hangs.
    private struct Endpoint: Identifiable {
        let id: String
        let color: Color
        let fraction: Double
        let units: Double
        /// Whether the end of this line carries its name. Every line keeps
        /// its dot; see `HistoryEndLabels.isLabelled`.
        let isLabelled: Bool
    }

    private var samples: [Sample] {
        var result: [Sample] = []
        for curve in curves {
            for point in curve.points {
                result.append(Sample(id: result.count, series: curve.label,
                                     fraction: point.elapsedFraction, units: point.units))
            }
        }
        return result
    }

    private var endpoints: [Endpoint] {
        curves.compactMap { curve in
            guard let last = curve.points.last else { return nil }
            // ⚠️ The slot's ramp position, never `enumerated()`. Colouring by
            // array index paints the first prior week violet — "this is now" —
            // for the first quarter-hour after a reset, when the live window
            // has too few points to draw and is not in this array at all.
            return Endpoint(id: curve.label, color: Theme.curve(at: curve.rampIndex),
                            fraction: last.elapsedFraction, units: last.units,
                            isLabelled: HistoryEndLabels.isLabelled(
                                rampIndex: curve.rampIndex, seriesCount: curves.count))
        }
    }

    var body: some View {
        if curves.isEmpty {
            // The mode owns its own copy: `Sources/Burnline` has no test
            // target, and the two modes' absences mean different things.
            Text(HistoryChartMode.units.emptyMessage)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textMuted)
                .padding(.vertical, 24)
        } else {
            chart
        }
    }

    // ⚠️ Three separate builders rather than one `Chart { … }` body, for the
    // same reason `Sample` exists: the whole chart as a single expression
    // exceeds the type checker's budget and fails the build outright. Each
    // property is bounded on its own.

    @ChartContentBuilder private var lines: some ChartContent {
        ForEach(samples) { sample in
            LineMark(x: .value("Elapsed", sample.fraction),
                     y: .value("Units", sample.units),
                     // Explicit, so two series crossing at the same x are never
                     // joined into one polyline.
                     series: .value("Week", sample.series))
                .foregroundStyle(by: .value("Week", sample.series))
        }
        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
    }

    /// The dot each direct label hangs from. The labels themselves are drawn
    /// over the plot by `HistoryEndLabelOverlay`, never as annotations: see
    /// there for the collision that rule exists for.
    @ChartContentBuilder private var endDots: some ChartContent {
        ForEach(endpoints) { endpoint in
            PointMark(x: .value("Elapsed", endpoint.fraction),
                      y: .value("Units", endpoint.units))
                .symbolSize(18)
                .foregroundStyle(endpoint.color)
        }
    }

    /// Where the live window has reached. A burn curve without it is a shape
    /// with no "you are here", and the comparison it exists for — am I ahead of
    /// where I was last week — needs one.
    @ChartContentBuilder private var nowLine: some ChartContent {
        RuleMark(x: .value("Now", nowFraction))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .foregroundStyle(Theme.textMuted.opacity(0.55))
            .annotation(position: .top, alignment: .center, spacing: 1) {
                Text("now")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
            }
    }

    private var chart: some View {
        Chart {
            lines
            endDots
            nowLine
        }
        // 🔴 ONE scale. A second y-axis would let two series be scaled
        // independently, and the entire point of the overlay is that they are
        // not — a curve above another curve has to mean more units.
        //
        // ⚠️ **No `.chartYScale` at all, and that is a stated decision rather
        // than an omission**: `HistoryChartMode.units.yDomain` returns nil, so
        // Charts fits the data. Correct precisely because the unit scale is
        // arbitrary — `Weights` documents that calibration divides it out — so
        // there is no meaningful fixed ceiling to name. The percent face names
        // one, and the two answers live side by side on the mode.
        .chartXScale(domain: 0...1)
        .historyEndLabels(endpoints.filter(\.isLabelled).map {
            HistoryEndLabelOverlay.Label(text: $0.id, fraction: $0.fraction, value: $0.units)
        })
        // ⚠️ Explicit range from each week's ramp position, never
        // `prefix(count)`: `prefix` assumes the drawn array IS the recency
        // order, which is exactly the assumption that fails when a week is
        // filtered out of it.
        .chartForegroundStyleScale(domain: curves.map(\.label),
                                   range: curves.map { Theme.curve(at: $0.rampIndex) })
        // Position first, visibility outermost. A single series is already
        // named by its direct label, and a one-entry legend is furniture.
        .chartLegend(position: .bottom, alignment: .leading, spacing: 10)
        .chartLegend(HistoryEndLabels.legendIsVisible(seriesCount: curves.count)
                     ? .visible : .hidden)
        .chartXAxis {
            AxisMarks(values: Self.dayTicks) { value in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel {
                    Text(Self.dayLabels.indices.contains(value.index)
                         ? Self.dayLabels[value.index] : "")
                        .font(.system(size: 9.5)).monospacedDigit()
                        .foregroundStyle(Theme.textMuted)
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel {
                    // 🔴 Through the mode, not `HistoryLabels` directly. Both
                    // charts share one axis-label rule, which is what makes
                    // "the unit is the tell" a property rather than a habit.
                    Text(HistoryChartMode.units.axisLabel(value.as(Double.self) ?? 0))
                        .font(.system(size: 9.5)).monospacedDigit()
                        .foregroundStyle(Theme.textMuted)
                }
            }
        }
        .frame(height: 208)
    }
}
