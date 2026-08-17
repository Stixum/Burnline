import SwiftUI
import Charts
import BurnlineCore

/// Where the units went, by project or by model, for one period.
///
/// **A single violet hue, and identity comes from the axis label.** This is a
/// magnitude question — which of these is biggest — and a categorical palette
/// here is the classic anti-pattern: it spends the reader's attention on
/// distinguishing colours that carry nothing, and it makes the chart illegible
/// to anyone who cannot separate them.
///
/// The range control is not decoration. The scoreboard above prints one number
/// per week and these bars have to add up to whichever of them is selected, or
/// the two reconcile with nothing.
struct HistoryBreakdown: View {
    let rows: [HistoryQuery.BreakdownRow]
    let total: Double
    /// Newest first — the range control's options, beside "All coverage".
    let windows: [WindowRow]
    @Binding var dimension: HistoryQuery.Dimension
    @Binding var range: HistoryRange

    /// One bar plus a 2px gap. The plot's height is this times the row count,
    /// which is what makes the gap exactly 2 rather than whatever an even
    /// division of a fixed frame happens to leave.
    private static let rowHeight: CGFloat = 16
    private static let barHeight: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            controls
            if rows.isEmpty {
                Text("Nothing archived for this period.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textMuted)
                    .padding(.vertical, 20)
            } else {
                chart
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Picker("", selection: $dimension) {
                ForEach(HistoryQuery.Dimension.allCases, id: \.self) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 168)

            Picker("", selection: $range) {
                ForEach(windows, id: \.start) { window in
                    Text(HistoryLabels.windowRange(start: window.start, end: window.end))
                        .tag(HistoryRange.window(start: window.start))
                }
                Divider()
                Text("All coverage").tag(HistoryRange.allCoverage)
            }
            .labelsHidden()
            .frame(width: 190)

            Spacer()

            // The figure the bars add up to. Without it the chart is a set of
            // proportions with no denominator.
            Text("\(HistoryLabels.units(total)) units")
                .font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var chart: some View {
        Chart(rows, id: \.label) { row in
            BarMark(x: .value("Units", row.units),
                    y: .value(dimension.title, row.label),
                    height: .fixed(Self.barHeight))
                // One hue. The folded tail is the same violet at lower opacity —
                // still one hue, and it is labelled "Other" besides.
                .foregroundStyle(Theme.accent.opacity(row.isOther ? 0.45 : 1))
                // Swift Charts has no per-corner control, so 4px lands on both
                // ends; every bar starts at the same baseline, so the leading
                // ends round identically and read as one edge.
                .cornerRadius(4)
                .annotation(position: .trailing, spacing: 6,
                            overflowResolution: AnnotationOverflowResolution(
                                x: .fit(to: .chart), y: .disabled)) {
                    // ⚠️ Text tokens, never the series colour. A value painted
                    // in the bar's own violet reads as part of the bar and drops
                    // below the contrast floor that text has to clear.
                    HStack(spacing: 6) {
                        Text(HistoryLabels.units(row.units))
                            .foregroundStyle(Theme.textSecondary)
                        Text(HistoryLabels.share(row.share))
                            .foregroundStyle(Theme.textMuted)
                    }
                    .font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
                }
        }
        // Explicit, so the order is the query's descending rank rather than
        // whatever a categorical scale infers.
        .chartYScale(domain: rows.map(\.label))
        .chartXScale(domain: xDomain)
        // 🔴 The values are direct-labelled on every bar, so a gridline ruler
        // across the plot would be a second, redundant encoding of the same
        // numbers — and a linear axis under a near-degenerate distribution
        // invites reading the small bars off the ticks, which is exactly the
        // precision they do not have.
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                // The identity channel. Colour carries none of it.
                AxisValueLabel {
                    Text(value.as(String.self) ?? "")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(height: CGFloat(rows.count) * Self.rowHeight)
    }

    /// Headroom past the longest bar for the labels that hang off its end.
    ///
    /// Layout geometry, not a figure: nothing a reader is shown comes from this
    /// number, and the bars stay proportional to their own units either way.
    private var xDomain: ClosedRange<Double> {
        let longest = rows.map(\.units).max() ?? 0
        return 0...(longest > 0 ? longest * 1.24 : 1)
    }
}
