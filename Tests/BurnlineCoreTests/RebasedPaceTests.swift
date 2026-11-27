import Testing
import Foundation
@testable import BurnlineCore

// History check fix 5 (2026-11-26, Sean chose "add a re-based segment"): after
// a mid-week re-grant the new allowance's curve restarted at 1% under the
// whole-week diagonal and read "far under pace" against a line drawn for the
// allowance that had ended. The chart now draws a second dashed line, from
// the new allowance's first reading to the whole allowance at the reset. The
// whole-week diagonal stays: the pace TARGET does not re-base.

private let base = Date(timeIntervalSince1970: 1_786_924_800)
private let week: TimeInterval = 7 * 86_400

private func entry(_ percent: Double, day: Double) -> TrackingEntry {
    TrackingEntry(percent: percent, at: base.addingTimeInterval(day * 86_400),
                  resetsAt: base.addingTimeInterval(week))
}

private func curve(_ entries: [TrackingEntry]) -> HistoryQuery.PercentSeries {
    HistoryQuery.percentCurve(tracking: entries, start: base, end: base.addingTimeInterval(week))
}

@Test func aReGrantedWeekGetsPaceFromItsFirstNewReadingToTheReset() throws {
    // Sean's week: 99% at day 4.200, 1% at day 4.203.
    let series = curve([entry(60, day: 3), entry(99, day: 4.200),
                        entry(1, day: 4.203), entry(41, day: 5.422)])
    let segment = try #require(HistoryPace.sinceRegrant(series))
    let ring = try #require(series.points.first(where: { $0.followsRegrant }))

    // It starts ON the ring: the first reading of the new allowance, where the
    // popover's projection epoch starts too.
    #expect(segment.fromFraction == ring.elapsedFraction)
    #expect(segment.fromPercent == 1)
    #expect(segment.toFraction == 1)
    #expect(segment.toPercent == HistoryChartMode.fullAllowance)
}

@Test func theWholeWeekDiagonalDoesNotMoveWhenTheWeekIsReGranted() {
    // 🔴 The CLAUDE.md rule this fix had to keep: the target does not re-base.
    // The re-based line is an addition, never a replacement.
    #expect(HistoryPace.wholeWeek
            == HistoryPace.Segment(fromFraction: 0, fromPercent: 0, toFraction: 1,
                                   toPercent: HistoryChartMode.fullAllowance))
}

@Test func aWeekWithoutAReGrantHasNoSecondPaceLine() {
    let series = curve([entry(10, day: 1), entry(30, day: 3), entry(50, day: 5)])
    #expect(HistoryPace.sinceRegrant(series) == nil)
}

@Test func anEmptyWeekHasNoSecondPaceLine() {
    #expect(HistoryPace.sinceRegrant(curve([])) == nil)
}

@Test func twoReGrantsRebaseOnTheLaterOne() throws {
    // The earlier re-granted allowance has ended too: only the one in force
    // at the end of the week has a pace to keep.
    let series = curve([entry(51, day: 1), entry(3, day: 1.1),
                        entry(40, day: 3), entry(2, day: 3.5), entry(20, day: 5)])
    let segment = try #require(HistoryPace.sinceRegrant(series))
    let lastRing = try #require(series.points.last(where: { $0.followsRegrant }))
    #expect(segment.fromFraction == lastRing.elapsedFraction)
    #expect(segment.fromPercent == 2)
}

@Test func aNewAllowanceAlreadyAtTheLimitHasNoPaceToDraw() {
    // A line from 100% to 100% is no target; nothing is drawn.
    let series = curve([entry(99, day: 2), entry(100, day: 2.1), entry(50, day: 3)])
    // 99 → 100 is not a drop and 100 → 50 opens an allowance at 50, so build
    // the degenerate case directly.
    let degenerate = HistoryQuery.PercentSeries(
        points: series.points,
        regrants: [.init(lastKnownFraction: 0.3, percentBefore: 100,
                         knownByFraction: 0.31, percentAfter: 100)])
    #expect(HistoryPace.sinceRegrant(degenerate) == nil)
}

@Test func aReGrantFirstSeenAtTheResetHasNoPaceToDraw() {
    let degenerate = HistoryQuery.PercentSeries(
        points: [],
        regrants: [.init(lastKnownFraction: 0.99, percentBefore: 90,
                         knownByFraction: 1, percentAfter: 2)])
    #expect(HistoryPace.sinceRegrant(degenerate) == nil)
}

@Test func theTwoPaceLinesAreNamedApart() {
    #expect(HistoryPace.wholeWeekLabel == "pace")
    #expect(HistoryPace.sinceRegrantLabel == "pace since re-grant")
}

// Source-text pins, as in `HistoryReloadWiringTests`: the app target has no
// tests, so these fail if a view stops drawing what Core decided.

private func appSource(_ file: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let text = try String(contentsOf: root.appendingPathComponent("Sources/Burnline/\(file)"),
                          encoding: .utf8)
    return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

@Test func thePercentChartDrawsTheRebasedPaceFromCore() throws {
    let chart = try appSource("HistoryPercentTrend.swift")
    #expect(chart.contains("guard let segment = HistoryPace.sinceRegrant(curve.series) else { continue }"))
    #expect(chart.contains("pace rebasedPace regrantSpans"))
    #expect(chart.contains("Text(HistoryPace.sinceRegrantLabel)"))
    // The whole-week diagonal is still drawn, from the same Core value.
    #expect(chart.contains("HistoryPace.wholeWeek.toPercent"))
}

@Test func thePopoverLegendIsTheNamedFigure() throws {
    let popover = try appSource("PopoverView.swift")
    #expect(popover.contains("Text(snapshot.usedLegend)"))
    #expect(!popover.contains("% used\" } ?? \"usage unknown\""))
}
