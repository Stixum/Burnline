import SwiftUI
import Charts
import BurnlineCore

/// Up to three weeks of Anthropic's own percentage, overlaid on one elapsed
/// axis, broken wherever the allowance was re-granted.
///
/// **The sibling of `HistoryBurnCurves`, and the reason there are two.** That
/// chart plots cumulative units, and units are monotonic by construction — a
/// re-grant does not un-spend a token, so a re-granted week's unit curve looks
/// perfectly ordinary while the scoreboard beside it reports 3%. The percentage
/// is the only series the event is visible in.
///
/// **Colour still encodes recency, not identity** — the same ramp, the same
/// legend, the same direct label on the end of each line. Nothing here is
/// distinguished by colour alone, and no new token was minted: green, amber and
/// red stay reserved for the delta.
struct HistoryPercentTrend: View {
    /// Newest first among what is drawn. 🔴 Each entry carries its OWN ramp
    /// position, because a week can have readings and no cells or cells and no
    /// readings — see `HistoryPercentCurve.rampIndex`.
    let curves: [HistoryPercentCurve]
    /// Where the live window is right now — the "you are here" line.
    let nowFraction: Double

    /// Eight ticks, one per window boundary and day. Same axis as the unit
    /// curve, deliberately: the toggle swaps the y quantity and nothing else,
    /// so a shape a reader has learned in one mode still sits where they left
    /// it in the other.
    private static let dayTicks: [Double] = [0, 1, 2, 3, 4, 5, 6, 7].map { $0 / 7 }
    private static let dayLabels = ["Start", "1", "2", "3", "4", "5", "6", "Reset"]

    // ⚠️ Concrete leaf types, for the reason `HistoryBurnCurves.Sample` spells
    // out: a `ForEach` over enumerated tuples wrapping a mark built from a
    // subscript chain **exceeds the type checker's budget and fails the build
    // outright**. Every mark below reads whole fields off a flat struct.

    /// One drawn vertex.
    private struct Sample: Identifiable {
        let id: Int
        /// The COLOUR key — the week. Constant across a re-grant, because a
        /// re-granted week is still one week and still one colour.
        let week: String
        /// The POLYLINE key — the week *and* the allowance.
        ///
        /// 🔴 This is the whole break. Swift Charts joins `LineMark`s that
        /// share a `series:` value, so putting the allowance index in the key
        /// costs nothing and buys the one thing the chart must not draw: a
        /// segment plunging 51% → 3%, a descent that never happened. The
        /// allowance is `HistoryQuery`'s to decide and is read, never measured
        /// here.
        ///
        /// A `#` separator is safe even though a week's label is free text: the
        /// suffix is an `Int` and contains no `#`, so **the last `#` is always
        /// the separator** and two distinct (week, allowance) pairs cannot spell
        /// one key.
        let segment: String
        let fraction: Double
        let percent: Double
    }

    /// A re-grant, as the STRETCH it is.
    ///
    /// 🔴 **Never collapsed to one x.** The re-grant instant is unrecoverable:
    /// on the live 2026-09-01 event the readings either side were 51% and 3%,
    /// ninety-seven minutes apart, and the gap exists precisely because nothing
    /// was reporting across it. A single vertical rule would state a moment
    /// nobody observed. Both ends are carried so the drawing can say "somewhere
    /// in here" and mean it.
    private struct Span: Identifiable {
        let id: Int
        let color: Color
        let fromFraction: Double
        let fromPercent: Double
        let toFraction: Double
        let toPercent: Double
    }

    /// The hollow ring, on the first reading of the new allowance.
    private struct Ring: Identifiable {
        let id: Int
        let color: Color
        let fraction: Double
        let percent: Double
    }

    /// The end of one series, where its direct label hangs.
    private struct Endpoint: Identifiable {
        let id: String
        let color: Color
        let fraction: Double
        let percent: Double
        /// Which side of the point the label hangs on.
        ///
        /// ⚠️ **Layout geometry, not a figure** — nothing a reader is shown
        /// comes from this, the same standing this has in
        /// `HistoryBreakdown.xDomain`. A fixed `.trailing` always reaches back
        /// LEFT over the stretch the line just came from, and for the live
        /// week that stretch is where a re-grant's ring and dashed drop sit: a
        /// week ending a few hours after a re-grant printed its name straight
        /// across the event. Hanging the label on the side the line has not
        /// reached yet clears it, and only a right-half endpoint keeps
        /// `.trailing`, where extending right would run off the plot.
        let alignment: Alignment
    }

    /// Two vertices of the pace diagonal. A `RuleMark` draws verticals and
    /// horizontals only, so the diagonal has to be a two-point `LineMark`.
    private struct PacePoint: Identifiable {
        let id: Int
        let fraction: Double
        let percent: Double
    }

    // MARK: - Marks

    private var samples: [Sample] {
        var result: [Sample] = []
        for curve in curves {
            for point in curve.series.points {
                result.append(Sample(id: result.count,
                                     week: curve.label,
                                     segment: "\(curve.label)#\(point.allowance)",
                                     fraction: point.elapsedFraction,
                                     percent: point.percent))
            }
        }
        return result
    }

    private var spans: [Span] {
        var result: [Span] = []
        for curve in curves {
            let color = Theme.curve(at: curve.rampIndex)
            for marker in curve.series.regrants {
                result.append(Span(id: result.count, color: color,
                                   fromFraction: marker.lastKnownFraction,
                                   fromPercent: marker.percentBefore,
                                   toFraction: marker.knownByFraction,
                                   toPercent: marker.percentAfter))
            }
        }
        return result
    }

    /// 🔴 Read off `followsRegrant`, never measured here. That flag marks the
    /// reading AFTER the drop — the earliest proof the new allowance was
    /// already in force — and the query walks the series once so the flag, the
    /// allowance index and the marker can never disagree.
    private var rings: [Ring] {
        var result: [Ring] = []
        for curve in curves {
            let color = Theme.curve(at: curve.rampIndex)
            for point in curve.series.points where point.followsRegrant {
                result.append(Ring(id: result.count, color: color,
                                   fraction: point.elapsedFraction, percent: point.percent))
            }
        }
        return result
    }

    private var endpoints: [Endpoint] {
        curves.compactMap { curve in
            guard let last = curve.series.points.last else { return nil }
            return Endpoint(id: curve.label, color: Theme.curve(at: curve.rampIndex),
                            fraction: last.elapsedFraction, percent: last.percent,
                            alignment: last.elapsedFraction < 0.5 ? .leading : .trailing)
        }
    }

    private var pacePoints: [PacePoint] {
        [PacePoint(id: 0, fraction: 0, percent: 0),
         PacePoint(id: 1, fraction: 1, percent: HistoryChartMode.fullAllowance)]
    }

    var body: some View {
        if curves.isEmpty {
            Text(HistoryChartMode.percent.emptyMessage)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 24)
        } else {
            chart
        }
    }

    // ⚠️ Separate builders rather than one `Chart { … }` body, for the same
    // reason the leaf structs exist: the whole chart as a single expression
    // exceeds the type checker's budget and fails the build. Each property is
    // bounded on its own.

    /// The one line on this chart that cannot be wrong: pace is calendar
    /// arithmetic, so "half the week gone" is exactly half the allowance.
    ///
    /// Dashed and muted because it is a reference, not a measurement — the same
    /// grammar as the `now` rule. Percent is the only axis this app can plot it
    /// on at all: on the unit axis the target has no fixed height, because the
    /// unit scale is arbitrary by construction.
    ///
    /// ⚠️ **It describes ONE allowance across the window.** After a re-grant the
    /// later segment measures an allowance that began mid-week, so the diagonal
    /// is not its pace target and being under it proves nothing. The break, the
    /// band and the ring are what say so; the diagonal deliberately does not
    /// fork, because a second diagonal would have to start at a moment nobody
    /// observed.
    @ChartContentBuilder private var pace: some ChartContent {
        ForEach(pacePoints) { point in
            LineMark(x: .value("Elapsed", point.fraction),
                     y: .value("Percent", point.percent),
                     series: .value("Series", "pace"))
        }
        // An explicit style, never `by:` — so the pace line stays out of the
        // foreground-style scale and out of the legend, which name weeks.
        .foregroundStyle(Theme.textMuted.opacity(0.45))
        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

        // A zero-area point carrying nothing but the label. An unlabelled
        // diagonal across a chart is a mystery, and the legend below names
        // weeks only.
        //
        // ⚠️ **At the diagonal's MIDPOINT, not its top end.** Hung at (1, 100)
        // it landed on any prior week that finished near its allowance — a full
        // week is the common case, not an edge — and rendered `Aug 20 – Aug
        // 2pace7`. Every series' direct label is at ITS OWN endpoint, and no
        // series ends in the middle of the plot, so the centre of the diagonal
        // is the one place on it that nothing else can claim.
        PointMark(x: .value("Elapsed", 0.5),
                  y: .value("Percent", HistoryChartMode.fullAllowance / 2))
            .symbolSize(0)
            .annotation(position: .topLeading, spacing: 2,
                        overflowResolution: AnnotationOverflowResolution(
                            x: .fit(to: .chart), y: .fit(to: .chart))) {
                Text("pace")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
            }
    }

    /// The band and the dashed drop — the two halves of one honest statement.
    ///
    /// The **band** answers *when*: a faint slab across the stretch between the
    /// last reading of the old allowance and the first of the new one, which is
    /// all anyone knows. It is drawn full height because the uncertainty is
    /// about the x axis alone.
    ///
    /// The **drop** answers *how far*: a dashed segment from the old reading to
    /// the new one. 🔴 **Dashed, never solid** — a solid vertical reads as
    /// "burned 51% instantly", and consumption is exactly what did not happen.
    /// Dashed says *event*, matching the grammar the `now` rule already uses.
    @ChartContentBuilder private var regrantSpans: some ChartContent {
        ForEach(spans) { span in
            RectangleMark(xStart: .value("Elapsed", span.fromFraction),
                          xEnd: .value("Elapsed", span.toFraction))
                .foregroundStyle(Theme.textMuted.opacity(0.12))
        }

        ForEach(spans) { span in
            LineMark(x: .value("Elapsed", span.fromFraction),
                     y: .value("Percent", span.fromPercent),
                     series: .value("Series", "drop-\(span.id)"))
                .foregroundStyle(span.color)
            LineMark(x: .value("Elapsed", span.toFraction),
                     y: .value("Percent", span.toPercent),
                     series: .value("Series", "drop-\(span.id)"))
                .foregroundStyle(span.color)
        }
        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
    }

    @ChartContentBuilder private var lines: some ChartContent {
        ForEach(samples) { sample in
            LineMark(x: .value("Elapsed", sample.fraction),
                     y: .value("Percent", sample.percent),
                     series: .value("Series", sample.segment))
                .foregroundStyle(by: .value("Week", sample.week))
        }
        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
    }

    /// A hollow ring on the first reading of the new allowance.
    ///
    /// Background-filled and stroked in the series colour, so it reads as an
    /// opening rather than a data point — the line arrives dashed and starts
    /// again from inside it. The fill is `Theme.background` rather than clear
    /// because the band and the pace line pass underneath.
    @ChartContentBuilder private var ringMarks: some ChartContent {
        ForEach(rings) { ring in
            PointMark(x: .value("Elapsed", ring.fraction),
                      y: .value("Percent", ring.percent))
                .symbol {
                    Circle()
                        .fill(Theme.background)
                        .overlay(Circle().strokeBorder(ring.color, lineWidth: 2))
                        .frame(width: 10, height: 10)
                }
                // ⚠️ **On the ring, not above the band.** Hung off the band's
                // top edge the word shared a row with the `now` rule's label
                // and rendered `re-grantednow` — and a re-grant is always
                // recent just after it happens, so that was the first thing a
                // user would ever see. Beside the ring it names the event it
                // belongs to, in the emptiest part of the plot: the first
                // reading of a new allowance is low by definition.
                .annotation(position: .trailing, spacing: 5,
                            overflowResolution: AnnotationOverflowResolution(
                                x: .fit(to: .chart), y: .fit(to: .chart))) {
                    // ⚠️ A text token, NOT the series colour. Two of the three
                    // ramp colours are below the contrast floor for text at
                    // this size — legible as lines, not as labels.
                    Text("re-granted")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
        }
    }

    /// Direct labels, so a series is identifiable without tracing a colour back
    /// to the legend.
    @ChartContentBuilder private var endLabels: some ChartContent {
        ForEach(endpoints) { endpoint in
            PointMark(x: .value("Elapsed", endpoint.fraction),
                      y: .value("Percent", endpoint.percent))
                .symbolSize(18)
                .foregroundStyle(endpoint.color)
                .annotation(position: .top, alignment: endpoint.alignment, spacing: 3,
                            overflowResolution: AnnotationOverflowResolution(
                                x: .fit(to: .chart), y: .fit(to: .chart))) {
                    // ⚠️ A text token, NOT the series colour. Same rule, same
                    // reason as the marker label above.
                    Text(endpoint.id)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
        }
    }

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
        scaled(plot)
    }

    /// Applies the mode's y ceiling, or lets Charts fit when the mode names
    /// none.
    ///
    /// ⚠️ **`if let`, deliberately not `?? someFallback`.** `yDomain` returns an
    /// optional so that "fit the data" is an answer a mode gives rather than a
    /// silence, and a coalescing fallback here would quietly convert that
    /// answer back into whatever constant sat on the right-hand side. The nil
    /// branch is the units mode's axis, written down.
    @ViewBuilder private func scaled<V: View>(_ chart: V) -> some View {
        if let domain = HistoryChartMode.percent.yDomain(for: curves.map(\.series)) {
            chart.chartYScale(domain: domain)
        } else {
            chart
        }
    }

    private var plot: some View {
        Chart {
            pace
            regrantSpans
            lines
            ringMarks
            endLabels
            nowLine
        }
        .chartXScale(domain: 0...1)
        // Explicit range rather than `prefix(count)`: the ramp position is the
        // week's recency, and this chart's array is filtered independently of
        // the unit chart's.
        .chartForegroundStyleScale(domain: curves.map(\.label),
                                   range: curves.map { Theme.curve(at: $0.rampIndex) })
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
                    // 🔴 Through the mode, which is what makes `50%` rather
                    // than `50` a property rather than a habit. The unit is
                    // how a reader knows which mode the toggle is in.
                    Text(HistoryChartMode.percent.axisLabel(value.as(Double.self) ?? 0))
                        .font(.system(size: 9.5)).monospacedDigit()
                        .foregroundStyle(Theme.textMuted)
                }
            }
        }
        .frame(height: 208)
    }
}
