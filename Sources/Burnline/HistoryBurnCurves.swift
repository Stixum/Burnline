import SwiftUI
import Charts
import BurnlineCore

/// Up to three weeks of cumulative consumption, overlaid on one elapsed axis.
///
/// The axis is **fraction elapsed through the window**, not wall clock: windows
/// do not all start on the same weekday — the reset moves whenever a new one is
/// observed — so a clock axis compares Tuesday of one week to Friday of another.
///
/// **Colour encodes recency, not identity**, so identity is carried twice over
/// in text: a legend and a label on the end of each line. Nothing here is
/// distinguished by colour alone.
struct HistoryBurnCurves: View {
    let curves: [(label: String, points: [HistoryQuery.CurvePoint])]
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
        curves.enumerated().compactMap { index, curve in
            guard let last = curve.points.last else { return nil }
            return Endpoint(id: curve.label, color: Theme.curve(at: index),
                            fraction: last.elapsedFraction, units: last.units)
        }
    }

    var body: some View {
        if curves.isEmpty {
            Text("Nothing archived for these weeks yet.")
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

    /// Direct labels, so a series is identifiable without tracing a colour back
    /// to the legend.
    @ChartContentBuilder private var endLabels: some ChartContent {
        ForEach(endpoints) { endpoint in
            PointMark(x: .value("Elapsed", endpoint.fraction),
                      y: .value("Units", endpoint.units))
                .symbolSize(18)
                .foregroundStyle(endpoint.color)
                // The newest series ends at fraction 1.0, hard against the plot's
                // right edge, so its label needs pulling back inside or it is
                // clipped to nothing.
                .annotation(position: .top, alignment: .trailing, spacing: 3,
                            overflowResolution: AnnotationOverflowResolution(
                                x: .fit(to: .chart), y: .fit(to: .chart))) {
                    // ⚠️ A text token, NOT the series colour. Two of the three
                    // ramp colours are below the contrast floor for text at this
                    // size — they are legible as lines and not as labels.
                    Text(endpoint.id)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
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
            endLabels
            nowLine
        }
        // 🔴 ONE scale. A second y-axis would let two series be scaled
        // independently, and the entire point of the overlay is that they are
        // not — a curve above another curve has to mean more units.
        .chartXScale(domain: 0...1)
        .chartForegroundStyleScale(domain: curves.map(\.label),
                                   range: Array(Theme.curveRamp.prefix(curves.count)))
        // Position first, visibility outermost. A single series is already
        // named by its direct label, and a one-entry legend is furniture.
        .chartLegend(position: .bottom, alignment: .leading, spacing: 10)
        .chartLegend(curves.count >= 2 ? .visible : .hidden)
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
                    Text(HistoryLabels.units(value.as(Double.self) ?? 0))
                        .font(.system(size: 9.5)).monospacedDigit()
                        .foregroundStyle(Theme.textMuted)
                }
            }
        }
        .frame(height: 208)
    }
}
