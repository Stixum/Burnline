import Foundation
import Testing
@testable import BurnlineCore

// A re-granted week's Completed-weeks row names the figure the allowance
// reached before it was re-granted. Sean chose the wording on 2026-11-26:
// "Re-granted day 5 at 99%, opened at 1%". The week of 20–27 Nov reached 99%,
// was re-granted, and climbed again to ~80%; the row printed only the ~80%
// and "opened at 1%", so a week that used about 1.8 allowances read as an
// ordinary 80% week. The earlier figure is read from `tracking.json`, which
// is never pruned, so rows already written by older builds gain it too.

// MARK: - Fixtures

private let peakBase = Date(timeIntervalSince1970: 1_795_158_000) // 2026-11-20 07:00:00Z
private let peakWeek: TimeInterval = 7 * 86_400

private func reading(_ percent: Double, hours: Double) -> TrackingEntry {
    TrackingEntry(percent: percent, at: peakBase.addingTimeInterval(hours * 3_600),
                  resetsAt: peakBase.addingTimeInterval(peakWeek))
}

/// The 2026-11-26 week in miniature: climb to 99, re-granted to 1, climb to 80.
private let reGrantedSeries: [TrackingEntry] = [
    reading(40, hours: 30), reading(97, hours: 90), reading(99, hours: 100.8),
    reading(1, hours: 100.9), reading(30, hours: 111), reading(80, hours: 167),
]

private func row(regrantAt hours: Double?, percent: Double = 1, observed: Int = 1) -> WindowRow {
    WindowRow(start: peakBase, end: peakBase.addingTimeInterval(peakWeek),
              counts: .zero, finalPercent: 80,
              finalPercentAt: peakBase.addingTimeInterval(167 * 3_600),
              finalPercentSource: "live", boundsSource: .observed, observedResetsAt: nil,
              regrant: hours.map {
                  WindowRow.RegrantAnnotation(at: peakBase.addingTimeInterval($0 * 3_600),
                                              percent: percent, observed: observed)
              })
}

// MARK: - The figure before the re-grant

@Test func theFigureBeforeTheReGrantIsTheReadingJustBeforeTheDrop() {
    #expect(WindowLedger.percentBeforeLastRegrant(of: row(regrantAt: 100.9),
                                                  in: reGrantedSeries) == 99)
}

@Test func anOrdinaryWeekHasNoFigureBeforeAReGrant() {
    #expect(WindowLedger.percentBeforeLastRegrant(of: row(regrantAt: nil),
                                                  in: reGrantedSeries) == nil)
}

@Test func readingsThatDisagreeWithTheRowAboutTheReGrantGiveNoFigure() {
    // The row says the re-grant was at hour 50; the readings put their drop at
    // hour 100.9. Printing 99% beside the row's day would join two accounts of
    // the week. Say less instead.
    #expect(WindowLedger.percentBeforeLastRegrant(of: row(regrantAt: 50),
                                                  in: reGrantedSeries) == nil)
}

@Test func withNoReadingsLeftTheFigureIsUnknown() {
    // A set-aside or emptied tracking file: the row keeps its old wording.
    #expect(WindowLedger.percentBeforeLastRegrant(of: row(regrantAt: 100.9), in: []) == nil)
}

@Test func readingsFromTheWeeksEitherSideDoNotCount() {
    // The ordinary reset is a big drop too (87 → 4). Only this window's own
    // readings may be walked.
    let before = TrackingEntry(percent: 87, at: peakBase.addingTimeInterval(-600),
                               resetsAt: peakBase)
    // The next week's reset after it is the drop that matters: walked over
    // the whole file it becomes the "last re-grant", and the row's own 99% is
    // lost.
    let nextWeek = TrackingEntry(percent: 3, at: peakBase.addingTimeInterval(peakWeek + 600),
                                 resetsAt: peakBase.addingTimeInterval(2 * peakWeek))
    let series = [before, reading(4, hours: 1), reading(60, hours: 50),
                  reading(99, hours: 100.8), reading(1, hours: 100.9),
                  reading(80, hours: 167), nextWeek]
    #expect(WindowLedger.percentBeforeLastRegrant(of: row(regrantAt: 100.9),
                                                  in: series) == 99)
}

@Test func aWeekReGrantedTwiceTakesTheFigureBeforeTheLastReGrant() {
    let series = [reading(50, hours: 20), reading(2, hours: 21), reading(70, hours: 90),
                  reading(3, hours: 91), reading(40, hours: 160)]
    #expect(WindowLedger.percentBeforeLastRegrant(of: row(regrantAt: 91, percent: 3, observed: 2),
                                                  in: series) == 70)
}

// MARK: - The row's words

@Test func aReGrantedWeekSaysWhatItReachedBeforeTheReGrant() {
    let rows = HistoryQuery.scoreboard(windows: [row(regrantAt: 100.9)], cells: [],
                                       coverage: Coverage(records: []), weights: .default,
                                       tracking: reGrantedSeries)
    let note = rows[0].regrantNote
    #expect(note?.label == "Re-granted day 5 at 99%, opened at 1%")
    #expect(note?.help.contains("when it stood at 99%") == true)
    #expect(note?.help.contains("not the week's usage") == true)
    // The figure column is untouched: still Anthropic's newest reading.
    #expect(rows[0].usedPercent == 80)
}

@Test func aWeekReGrantedTwiceSaysWhatItReachedBeforeTheLastOne() {
    let series = [reading(50, hours: 20), reading(2, hours: 21), reading(70, hours: 90),
                  reading(3, hours: 91), reading(40, hours: 160)]
    let rows = HistoryQuery.scoreboard(windows: [row(regrantAt: 91, percent: 3, observed: 2)],
                                       cells: [], coverage: Coverage(records: []),
                                       weights: .default, tracking: series)
    #expect(rows[0].regrantNote?.label == "Re-granted 2×, last day 4 at 70%, opened at 3%")
}

@Test func withoutTheReadingsTheRowKeepsItsEarlierWording() {
    let rows = HistoryQuery.scoreboard(windows: [row(regrantAt: 100.9)], cells: [],
                                       coverage: Coverage(records: []), weights: .default,
                                       tracking: [])
    #expect(rows[0].regrantNote?.label == "Re-granted day 5, opened at 1%")
}

// MARK: - Wiring

// A source-text pin, in the style of `HistoryReloadWiringTests`: the scoreboard
// is built in `HistoryLoader` (app target, no tests), and an empty `tracking`
// there would quietly bring the shorter wording back.
@Test func theHistoryLoaderHandsTheScoreboardItsReadings() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let loader = try String(contentsOf: root.appendingPathComponent("Sources/Burnline/HistoryLoader.swift"),
                            encoding: .utf8)
        .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    #expect(loader.contains("HistoryQuery.scoreboard(windows: archive.windows, cells: archive.cells, coverage: archive.coverage, weights: weights, tracking: archive.tracking)"))
}
