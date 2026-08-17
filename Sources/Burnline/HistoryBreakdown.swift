import SwiftUI
import Charts
import BurnlineCore

/// Where the units went, by project or by model, for one period.
///
/// **A single violet hue, and identity comes from the label gutter.** This is a
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

    /// The label gutter, and the gap between it and the plot's leading edge.
    ///
    /// 🔴 **Fixed, not fitted.** Swift Charts' own leading `AxisValueLabel` drew
    /// the names *inside* the plot area, straight across the bars, and long ones
    /// (`TokenEstimator`, `seanmccauley`, `ConcertTracker/iOS` — collision
    /// disambiguation puts a slash in real project names) were unreadable while
    /// short ones hid behind their own bar. The gutter is the fix, and it has to
    /// be a constant: sized to the widest label it would jump every time the
    /// dimension toggle moved between project and model names, and the bars —
    /// whose whole job is comparison by length — would change length with it.
    ///
    /// 118 fits ~18 characters at 11pt SF Pro. Past that the name truncates and
    /// the tooltip carries it in full; a wider gutter would buy a few more
    /// characters at the cost of the plot, which is what the reader is here for.
    private static let labelWidth: CGFloat = 118
    private static let labelGap: CGFloat = 10

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
            // ⚠️ Without this the selected segment inherits the *system* accent
            // and renders macOS blue in an app whose accent is violet — a defect
            // that is invisible in the source and only shows in a screenshot.
            //
            // `.tint` genuinely lands here, unlike on `.borderedProminent`,
            // which ignores it and comes out a grey system pill (see
            // `AccentButtonStyle`). The two are not interchangeable evidence:
            // verified by screenshot that the selected segment matches the bar
            // fill below it.
            .tint(Theme.accent)
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

    /// A label gutter beside the plot, rather than an axis inside it.
    ///
    /// The two columns stay in register because neither one is laid out against
    /// the other: every label occupies exactly `rowHeight`, and the plot's frame
    /// is `rowHeight` times the row count over a categorical scale, so band *n*
    /// and label *n* both centre on the same line. Both axes are hidden, so the
    /// plot area is the frame and Charts contributes no inset of its own.
    private var chart: some View {
        HStack(alignment: .top, spacing: Self.labelGap) {
            labels
            plot
        }
    }

    /// The identity channel. Colour carries none of it — one violet is the
    /// entire series — so these names are the only thing telling the reader
    /// which bar is which, and they cannot be allowed to land on a bar.
    private var labels: some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(rows, id: \.label) { row in
                // ⚠️ Text tokens, never the series colour: same rule as the
                // value labels, and for the same reason.
                Text(row.label)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: Self.labelWidth, height: Self.rowHeight, alignment: .trailing)
                    // Truncation loses information, so the full name stays
                    // reachable. Two projects can differ only past the ellipsis.
                    .help(row.label)
            }
        }
    }

    private var plot: some View {
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
        // 🔴 The names live in `labels`, in their own gutter. Do not put them
        // back on the axis: a leading `AxisMarks` here reserves no space, so
        // Charts draws the labels over the bars.
        .chartYAxis(.hidden)
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
