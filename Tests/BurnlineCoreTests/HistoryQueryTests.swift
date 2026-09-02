import Testing
import Foundation
@testable import BurnlineCore

// A real bucket start, divisible by 900.
private let queryBase = 1_786_924_800
private let sevenDays: TimeInterval = 7 * 86_400

private func cell(bucket: Int, project: String = "burnline",
                  model: String = "claude-sonnet-5", output: Int = 0, input: Int = 0,
                  cacheWrite: Int = 0, cacheRead: Int = 0) -> HistoryRow {
    HistoryRow(bucket: bucket, project: project, model: model,
               counts: TokenCounts(input: input, output: output,
                                   cacheWrite: cacheWrite, cacheRead: cacheRead))
}

private func weekRow(start: Date, counts: TokenCounts = TokenCounts(output: 1_000),
                     finalPercent: Double? = nil) -> WindowRow {
    WindowRow(start: start, end: start.addingTimeInterval(sevenDays), counts: counts,
              finalPercent: finalPercent, finalPercentAt: nil, finalPercentSource: nil,
              boundsSource: .extrapolated, observedResetsAt: nil)
}

private func covering(_ from: Int, _ through: Int) -> Coverage {
    Coverage(records: [CoverageRecord(from: from, through: through, filledBy: "test")])
}

private func isClose(_ lhs: Double, _ rhs: Double, _ tolerance: Double = 1e-6) -> Bool {
    abs(lhs - rhs) <= tolerance * max(1, abs(lhs), abs(rhs))
}

// MARK: - Scoreboard

@Test func scoreboardRowsAreNewestFirst() {
    // The scoreboard is read top-down as "this week, last week, the week
    // before". Archive order is oldest-first (rows are appended as windows
    // close), so handing the file order straight to a list renders the whole
    // history upside down.
    let oldest = Date(timeIntervalSince1970: Double(queryBase))
    let middle = oldest.addingTimeInterval(sevenDays)
    let newest = middle.addingTimeInterval(sevenDays)

    let rows = HistoryQuery.scoreboard(
        windows: [weekRow(start: oldest), weekRow(start: newest), weekRow(start: middle)],
        cells: [],
        coverage: Coverage(records: []),
        weights: .default
    )

    #expect(rows.map(\.window.start) == [newest, middle, oldest])
}

@Test func aWindowWithNoRecordedPercentIsNotZero() {
    // 🔴 THE test for this unit. Every window in the real archive has
    // `finalPercent == nil` today — the app only started recording percentages
    // now, and no historical figure exists anywhere on disk or can be
    // reconstructed. Coalescing nil to 0 would render a week of hard work as
    // "0% used", i.e. claim a week of no usage. nil must survive the query so
    // the view is forced to render "not recorded".
    let start = Date(timeIntervalSince1970: Double(queryBase))
    let window = weekRow(start: start,
                         counts: TokenCounts(input: 5_000, output: 2_000,
                                             cacheWrite: 1_000, cacheRead: 900_000),
                         finalPercent: nil)
    let cells = [cell(bucket: queryBase, output: 2_000, input: 5_000,
                      cacheWrite: 1_000, cacheRead: 900_000)]

    let rows = HistoryQuery.scoreboard(windows: [window], cells: cells,
                                       coverage: Coverage(records: []), weights: .default)

    #expect(rows.count == 1)
    #expect(rows[0].usedPercent == nil)
    #expect(rows[0].units > 0)      // there WAS usage; only the percentage is unknown
}

@Test func aRecordedPercentIsPassedThroughUnchanged() {
    // The positive control for the test above: "nil stays nil" is only
    // meaningful if a real reading is not also being dropped or rescaled.
    let start = Date(timeIntervalSince1970: Double(queryBase))
    let rows = HistoryQuery.scoreboard(windows: [weekRow(start: start, finalPercent: 64.5)],
                                       cells: [], coverage: Coverage(records: []),
                                       weights: .default)

    #expect(rows[0].usedPercent == 64.5)
}

@Test func aGapIsNotZeroUsage() {
    // A hole in coverage means "the app was not running", not "no tokens were
    // burned". Rendering the two the same way turns an unknown week into a
    // fabricated week of idleness — the exact absence the archive exists to
    // make visible.
    let start = Date(timeIntervalSince1970: Double(queryBase))
    let firstBucket = queryBase
    let lastBucket = queryBase + Int(sevenDays) - 900
    let holeStart = queryBase + 86_400
    let holeEnd = holeStart + 3 * 900

    let holed = Coverage(records: [
        CoverageRecord(from: firstBucket, through: holeStart - 900, filledBy: "test"),
        CoverageRecord(from: holeEnd + 900, through: lastBucket, filledBy: "test"),
    ])

    let gapped = HistoryQuery.scoreboard(windows: [weekRow(start: start)], cells: [],
                                         coverage: holed, weights: .default)
    #expect(gapped[0].hasGap)

    // Positive control: the same window, fully covered, must NOT be flagged.
    let whole = HistoryQuery.scoreboard(windows: [weekRow(start: start)], cells: [],
                                        coverage: covering(firstBucket, lastBucket),
                                        weights: .default)
    #expect(!whole[0].hasGap)
}

@Test func scoreboardUnitsEqualTheSumOfThatWindowsBreakdown() {
    // 🔴 The headline and the bars beneath it must be the same quantity. They
    // are only equal if both weight from CELLS: a `WindowRow`'s counts are
    // summed across models, so weighting those loses every per-model
    // multiplier and an all-Opus week reads 1× above and 5× below — silently,
    // and plausibly enough that nobody checks.
    //
    // ⚠️ The fixture MUST use a model whose multiplier is NOT 1.0 (opus is
    // 5.0), or the bug is invisible and this test proves nothing. The last
    // expectation is what holds that: it fails the moment the fixture goes
    // back to a 1× model.
    let start = Date(timeIntervalSince1970: Double(queryBase))
    let nextStart = start.addingTimeInterval(sevenDays)

    let mine = [
        cell(bucket: queryBase, project: "burnline", model: "claude-opus-5",
             output: 2_000, input: 5_000, cacheWrite: 1_000, cacheRead: 900_000),
        cell(bucket: queryBase + 900, project: "other", model: "claude-opus-5",
             output: 400, input: 100, cacheRead: 45_000),
        cell(bucket: queryBase + 3 * 86_400, project: "burnline", model: "claude-opus-5",
             output: 55, cacheRead: 5_000),
    ]
    // A neighbouring window's cells, present in the archive the scoreboard is
    // handed. They must not leak into this row.
    let theirs = [cell(bucket: queryBase + Int(sevenDays) + 900, model: "claude-sonnet-5",
                       output: 9_999)]

    let counts = mine.reduce(TokenCounts()) {
        TokenCounts(input: $0.input + $1.input, output: $0.output + $1.output,
                    cacheWrite: $0.cacheWrite + $1.cacheWrite,
                    cacheRead: $0.cacheRead + $1.cacheRead)
    }
    let rows = HistoryQuery.scoreboard(
        windows: [weekRow(start: start, counts: counts), weekRow(start: nextStart)],
        cells: mine + theirs, coverage: Coverage(records: []), weights: .default)
    let breakdown = HistoryQuery.breakdown(cells: mine, by: .project, weights: .default,
                                           limit: 10)

    let row = rows.first { $0.window.start == start }!
    #expect(abs(row.units - breakdown.reduce(0) { $0 + $1.units }) < 1e-9)

    // The fixture's teeth: weighting the WindowRow's own counts — the same
    // tokens, with the model dimension summed away — is five times smaller.
    let fromWindowCounts = ConsumptionModel.units(for: counts,
                                                  multiplier: Weights.default.defaultMultiplier,
                                                  weights: .default)
    #expect(isClose(row.units, fromWindowCounts * 5))
}

@Test func scoreboardCountsOnlyTheCellsInsideItsOwnWindow() {
    // Units now come from the archive, not from the row, so each window has to
    // take its own slice of it — by the SAME bucket-ownership rule the gap
    // check and the burn curve use ([start, end) on the bucket START). Get
    // this wrong and every week reports the whole archive.
    let start = Date(timeIntervalSince1970: Double(queryBase))
    let nextStart = start.addingTimeInterval(sevenDays)
    let cells = [
        cell(bucket: queryBase - 900, output: 999),                       // before both
        cell(bucket: queryBase, output: 10),                              // first window
        cell(bucket: queryBase + Int(sevenDays) - 900, output: 20),       // its last bucket
        cell(bucket: queryBase + Int(sevenDays), output: 7),               // second window
    ]

    let rows = HistoryQuery.scoreboard(
        windows: [weekRow(start: start), weekRow(start: nextStart)],
        cells: cells, coverage: Coverage(records: []), weights: .default)

    #expect(rows.map(\.window.start) == [nextStart, start])
    #expect(isClose(rows[1].units, 30 * Weights.default.output))   // 10 + 20, not 999
    #expect(isClose(rows[0].units, 7 * Weights.default.output))
}

// MARK: - Re-grant note

/// A window that can be given bounds of its own, because the day a re-grant
/// fell on is measured against them and a seven-day fixture could never show
/// that. `finalPercent` deliberately differs from every `regrant.percent` below
/// — the note reports the figure the new allowance OPENED at, and the column
/// beside it already prints the final one.
private func regrantedWeek(start: Date, duration: TimeInterval = sevenDays,
                           at offset: TimeInterval, percent: Double,
                           observed: Int = 1, finalPercent: Double? = 30) -> WindowRow {
    WindowRow(start: start, end: start.addingTimeInterval(duration), counts: .zero,
              finalPercent: finalPercent,
              finalPercentAt: start.addingTimeInterval(duration - 900),
              finalPercentSource: "live", boundsSource: .observed, observedResetsAt: nil,
              regrant: WindowRow.RegrantAnnotation(at: start.addingTimeInterval(offset),
                                                   percent: percent, observed: observed))
}

@Test func aReGrantedWeekCarriesANoteSayingWhenAndAtWhat() {
    // 🔴 THE test for this state. `finalPercent` is the newest reading in the
    // window, so on a re-granted week it is the climb since the re-grant and
    // not the week's usage: this row archives 30% beside a token total larger
    // than a 91% week's, and window rows are written once. Without the note
    // that row reads as a quiet week forever.
    let start = Date(timeIntervalSince1970: Double(queryBase))
    let rows = HistoryQuery.scoreboard(
        windows: [regrantedWeek(start: start, at: 3.5 * 86_400, percent: 3,
                                finalPercent: 30)],
        cells: [], coverage: Coverage(records: []), weights: .default)

    let note = rows[0].regrantNote
    // 🔴 `3%` is `regrant.percent` — what the new allowance opened at, which on
    // the live 2026-09-01 event was 3 and not 0. Taking `finalPercent` here
    // would print the 30% already shown in the column to the left and lose the
    // only figure this note exists to add.
    #expect(note?.label == "Re-granted day 4, at 3%")
    #expect(note?.help.contains("not the week's usage") == true)
    // The row still reports Anthropic's own final figure, unchanged: the note
    // qualifies that column, it does not replace it.
    #expect(rows[0].usedPercent == 30)
}

@Test func anOrdinaryWeekCarriesNoReGrantNote() {
    // The positive control for the test above, and the mutation that matters
    // most: a note rendered on every week is a note nobody reads. `regrant`
    // being nil IS the discriminator — almost every row in the archive is one.
    let start = Date(timeIntervalSince1970: Double(queryBase))
    let rows = HistoryQuery.scoreboard(
        windows: [weekRow(start: start, finalPercent: 91)],
        cells: [], coverage: Coverage(records: []), weights: .default)

    #expect(rows[0].window.regrant == nil)
    #expect(rows[0].regrantNote == nil)
}

@Test func theDayIsMeasuredAgainstTheWindowsOwnBoundsNotAFixedWeek() {
    // ⚠️ A window is not seven days. It is 167 or 169 hours across a DST
    // transition, and `WindowLedger` can substitute an observed reset that
    // moves `end` further than that. A day is a seventh of THIS window —
    // `Window.dayIndex`, the definition the end-of-day pace target already
    // uses — so the denominator is the row's own duration.
    let start = Date(timeIntervalSince1970: Double(queryBase))

    // A window closed early by an observed reset: 3.5 days long. 2.25 days in
    // is halfway through its fifth day. Divide by a fixed seven days instead
    // and the same instant reads "day 3".
    let short = regrantedWeek(start: start, duration: 3.5 * 86_400,
                              at: 2.25 * 86_400, percent: 4)
    #expect(HistoryQuery.RegrantNote(window: short)?.label == "Re-granted day 5, at 4%")

    // A 169-hour DST week. Six real days in is 5.96 of its slightly longer
    // days — still day 6. A fixed 168-hour week puts the same instant at
    // exactly 6.0 and prints "day 7".
    let dst = regrantedWeek(start: start, duration: 169 * 3_600,
                            at: 144 * 3_600, percent: 4)
    #expect(HistoryQuery.RegrantNote(window: dst)?.label == "Re-granted day 6, at 4%")
}

@Test func aWeekReGrantedTwiceDoesNotReadAsAWeekReGrantedOnce() {
    // 🔴 The whole reason `observed` exists. `at` and `percent` describe the
    // LAST re-grant, because only the last one pairs with `finalPercent` to
    // describe a single stretch of the week — so a two-re-grant week rendered
    // with the one-re-grant wording would be a quietly false row, permanently.
    let start = Date(timeIntervalSince1970: Double(queryBase))
    let once = regrantedWeek(start: start, at: 3.5 * 86_400, percent: 3, observed: 1)
    let twice = regrantedWeek(start: start, at: 3.5 * 86_400, percent: 3, observed: 2)
    let thrice = regrantedWeek(start: start, at: 3.5 * 86_400, percent: 3, observed: 3)

    #expect(HistoryQuery.RegrantNote(window: twice)?.label
            == "Re-granted 2×, last day 4 at 3%")
    #expect(HistoryQuery.RegrantNote(window: thrice)?.label
            == "Re-granted 3×, last day 4 at 3%")
    // Same instant, same percentage, different count — the labels must differ,
    // and the count must be the number seen rather than a bare "more than one".
    #expect(HistoryQuery.RegrantNote(window: once)?.label
            != HistoryQuery.RegrantNote(window: twice)?.label)
    #expect(HistoryQuery.RegrantNote(window: twice)?.label
            != HistoryQuery.RegrantNote(window: thrice)?.label)
    #expect(HistoryQuery.RegrantNote(window: twice)?.help.contains("2 times") == true)
}

@Test func aSillyArchivedPercentageRendersRatherThanTraps() {
    // `windows.jsonl` is append-only plain JSON that any local process can
    // write, and `Int(Double)` traps outside `Int`'s range — the class of
    // defect `DisplayValue` exists for. A menu bar app renders a silly number;
    // it does not die.
    let start = Date(timeIntervalSince1970: Double(queryBase))
    let absurd = regrantedWeek(start: start, at: 86_400, percent: 1e30)
    #expect(HistoryQuery.RegrantNote(window: absurd)?.label == "Re-granted day 2, at 999%")

    // Non-finite is reported as an absence rather than as a number, which is
    // `HistoryLabels.percent`'s rule and not this type's to restate.
    let broken = regrantedWeek(start: start, at: 86_400, percent: .infinity)
    #expect(HistoryQuery.RegrantNote(window: broken)?.label == "Re-granted day 2, at —")
}

// MARK: - Burn curve

@Test func burnCurveIsCumulativeAcrossTheWindow() {
    // The question a burn curve answers is "was I ahead or behind pace", and
    // only a cumulative series answers it. Per-bucket consumption plotted
    // against a straight pace line compares a rate to a total and is
    // meaningless — and it makes an idle stretch look like a fall in usage.
    let start = Date(timeIntervalSince1970: Double(queryBase))
    let end = start.addingTimeInterval(sevenDays)
    let cells = [
        cell(bucket: queryBase, output: 10),
        cell(bucket: queryBase + 900, output: 30),
        cell(bucket: queryBase + 86_400, output: 5),
        cell(bucket: queryBase + 3 * 86_400, output: 55),
    ]

    let points = HistoryQuery.burnCurve(cells: cells, start: start, end: end, weights: .default)

    #expect(points.count == 5)      // one anchor at the origin plus four buckets
    for (previous, next) in zip(points, points.dropFirst()) {
        #expect(next.units >= previous.units)
        #expect(next.elapsedFraction > previous.elapsedFraction)
    }
    let total = cells.reduce(0.0) {
        $0 + ConsumptionModel.units(for: $1.counts, model: $1.model, weights: .default)
    }
    #expect(isClose(points.last!.units, total))
}

@Test func burnCurvesAreIndexedToWindowElapsedNotWallClock() {
    // Overlaying two weeks is only valid on a shared axis. Windows do not all
    // start on the same weekday — the reset moves whenever a new one is
    // observed — so plotting against wall clock compares Tuesday of one week
    // to Friday of another and the "same point in the week" lands in different
    // places. Fraction elapsed through the window is the axis that aligns.
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!

    let startA = Date(timeIntervalSince1970: Double(queryBase))
    let startB = startA.addingTimeInterval(3 * 86_400)
    #expect(calendar.component(.weekday, from: startA)
            != calendar.component(.weekday, from: startB))   // the premise of this test

    // One bucket in each window, both ending exactly half way through it.
    let halfway = Int(sevenDays / 2) - 900
    let curveA = HistoryQuery.burnCurve(
        cells: [cell(bucket: queryBase + halfway, output: 100)],
        start: startA, end: startA.addingTimeInterval(sevenDays), weights: .default)
    let curveB = HistoryQuery.burnCurve(
        cells: [cell(bucket: queryBase + 3 * 86_400 + halfway, output: 100)],
        start: startB, end: startB.addingTimeInterval(sevenDays), weights: .default)

    #expect(isClose(curveA.last!.elapsedFraction, 0.5))
    #expect(isClose(curveB.last!.elapsedFraction, 0.5))
    #expect(isClose(curveA.last!.elapsedFraction, curveB.last!.elapsedFraction))
}

@Test func burnCurveIgnoresCellsOutsideTheWindow() {
    // Bounds are passed in, not inferred, precisely so the CURRENT week can be
    // drawn before a WindowRow exists. A caller handing over the whole archive
    // must not get every week's tokens piled into one curve.
    let start = Date(timeIntervalSince1970: Double(queryBase))
    let cells = [
        cell(bucket: queryBase - 900, output: 999),
        cell(bucket: queryBase, output: 10),
        cell(bucket: queryBase + Int(sevenDays), output: 999),
    ]

    let points = HistoryQuery.burnCurve(cells: cells, start: start,
                                        end: start.addingTimeInterval(sevenDays),
                                        weights: .default)

    #expect(points.count == 2)
    #expect(isClose(points.last!.units, 10 * Weights.default.output))
}

@Test func hourlyKeepsTheOriginTheTotalAndOnePointPerHour() {
    // ⚠️ A week at 15-minute resolution is ~670 points per series, and three
    // series overlay. The query keeps every bucket — the totals must stay exact
    // — and only the drawn series is thinned.
    //
    // Three properties, and all three are load-bearing. The origin is what
    // makes overlaid curves start from one place. The final point is the
    // window's real total, and a chart whose last drawn value is an hour short
    // of it disagrees with the scoreboard printed above it. And the count is
    // the whole reason the function exists.
    let start = Date(timeIntervalSince1970: Double(queryBase))
    let cells = (0..<(7 * 96)).map { cell(bucket: queryBase + $0 * 900, output: 10) }

    let full = HistoryQuery.burnCurve(cells: cells, start: start,
                                      end: start.addingTimeInterval(sevenDays),
                                      weights: .default)
    let drawn = HistoryQuery.hourly(full, windowDuration: sevenDays)

    #expect(full.count == 7 * 96 + 1)              // the premise: this is worth thinning
    #expect(drawn.count <= 7 * 24 + 1)
    #expect(drawn.first == full.first)             // the (0, 0) anchor
    #expect(drawn.last == full.last)               // the true window total
    for (previous, next) in zip(drawn, drawn.dropFirst()) {
        #expect(next.elapsedFraction > previous.elapsedFraction)
        #expect(next.units >= previous.units)
    }
}

@Test func hourlyTakesTheLastPointInEachHourNotTheFirst() {
    // The series is CUMULATIVE, so the running total at the end of the hour is
    // the true total at that hour. Taking the first point would draw a curve
    // that lags its own data by an hour and undershoots every reading — a
    // plausible-looking chart that is quietly wrong.
    let start = Date(timeIntervalSince1970: Double(queryBase))
    // Three buckets, ending 15, 30 and 45 minutes in — all inside the window's
    // first hour. A fourth would end exactly on the hour mark and open the next
    // one, which is correct and would hide what this test is checking.
    let cells = (0..<3).map { cell(bucket: queryBase + $0 * 900, output: 10) }

    let full = HistoryQuery.burnCurve(cells: cells, start: start,
                                      end: start.addingTimeInterval(sevenDays),
                                      weights: .default)
    let drawn = HistoryQuery.hourly(full, windowDuration: sevenDays)

    // They collapse to one point, carrying the total of all three rather than
    // of the first.
    #expect(drawn.count == 2)
    #expect(isClose(drawn.last!.units, 30 * Weights.default.output))
}

// MARK: - Breakdown

@Test func breakdownDropsALabelThatConsumedNothing() {
    // The real archive carries a `<synthetic>` model on nine cells whose four
    // token counts are ALL ZERO — Claude Code's placeholder for an assistant
    // message it produced without an API call. In a magnitude chart that is a
    // bar with no length under a cryptic name, which reads as a defect.
    //
    // ⚠️ The rule is "zero units", not that literal string: a `<synthetic>`
    // cell that ever did carry tokens is real usage and must appear. The second
    // half of this test is what holds that distinction.
    let cells = [
        cell(bucket: queryBase, model: "claude-sonnet-5", output: 100),
        cell(bucket: queryBase + 900, model: "<synthetic>"),               // all zero
    ]

    let rows = HistoryQuery.breakdown(cells: cells, by: .model, weights: .default, limit: 10)
    #expect(rows.map(\.label) == ["claude-sonnet-5"])

    // Same label, real tokens: it is usage, and it appears.
    let earned = HistoryQuery.breakdown(
        cells: cells + [cell(bucket: queryBase + 1_800, model: "<synthetic>", output: 5)],
        by: .model, weights: .default, limit: 10)
    #expect(earned.map(\.label) == ["claude-sonnet-5", "<synthetic>"])
}

@Test func breakdownOfOneWindowReconcilesWithItsScoreboardRow() {
    // 🔴 The path the History window actually takes: the range control points
    // the breakdown at one window, and the bars must add up to the units that
    // window's scoreboard row prints. They only do if BOTH sides slice the
    // archive by the same bucket-ownership rule — hence `cells(_:in:)` rather
    // than a `start...end` filter in the view, which would differ by a bucket
    // around every reset.
    let start = Date(timeIntervalSince1970: Double(queryBase))
    let nextStart = start.addingTimeInterval(sevenDays)
    let cells = [
        cell(bucket: queryBase - 900, project: "before", output: 999),
        cell(bucket: queryBase, project: "burnline", model: "claude-opus-5", output: 10),
        cell(bucket: queryBase + Int(sevenDays) - 900, project: "other", output: 20),
        cell(bucket: queryBase + Int(sevenDays), project: "after", output: 777),
    ]
    let window = weekRow(start: start)

    let scoreboard = HistoryQuery.scoreboard(
        windows: [window, weekRow(start: nextStart)], cells: cells,
        coverage: Coverage(records: []), weights: .default)
    let bars = HistoryQuery.breakdown(cells: HistoryQuery.cells(cells, in: window),
                                      by: .project, weights: .default, limit: 10)

    #expect(bars.map(\.label).sorted() == ["burnline", "other"])   // neither neighbour leaked
    #expect(isClose(scoreboard[1].units, bars.reduce(0) { $0 + $1.units }))
}

@Test func breakdownIsSortedDescendingByUnits() {
    // The breakdown exists to answer "where did it go", so the biggest
    // consumer has to be the first row. Dictionary order is unspecified and
    // would reshuffle the table on every refresh.
    let cells = [
        cell(bucket: queryBase, project: "small", output: 1),
        cell(bucket: queryBase + 900, project: "largest", output: 100),
        cell(bucket: queryBase + 1_800, project: "middle", output: 10),
    ]

    let rows = HistoryQuery.breakdown(cells: cells, by: .project, weights: .default, limit: 10)

    #expect(rows.map(\.label) == ["largest", "middle", "small"])
    #expect(rows.allSatisfy { !$0.isOther })
}

@Test func breakdownCollapsesTheLongTail() {
    // The real archive has 18 projects and the top 5 are 82.6% of it. Rendering
    // all 18 buries the answer in noise; dropping the tail silently loses it.
    // Folding it into one labelled row does neither.
    let cells = (0..<8).map {
        cell(bucket: queryBase + $0 * 900, project: "project-\($0)", output: 100 - $0)
    }

    let rows = HistoryQuery.breakdown(cells: cells, by: .project, weights: .default, limit: 5)

    #expect(rows.count == 6)
    #expect(rows.dropLast().allSatisfy { !$0.isOther })
    #expect(rows.last!.isOther)
    #expect(rows.last!.label == HistoryQuery.otherLabel)
}

@Test func breakdownUnitsSumToTheWindowTotal() {
    // A breakdown that does not reconcile with the total it sits under is
    // worse than none: the reader cannot tell whether the tail was folded or
    // dropped. The Other row must carry the whole remainder, and the shares
    // must add to 1.
    let cells = (0..<20).map {
        cell(bucket: queryBase + $0 * 900, project: "project-\($0 % 7)",
             model: $0.isMultiple(of: 3) ? "claude-opus-5" : "claude-sonnet-5",
             output: 10 + $0, input: 100, cacheRead: 5_000)
    }
    let total = cells.reduce(0.0) {
        $0 + ConsumptionModel.units(for: $1.counts, model: $1.model, weights: .default)
    }

    let rows = HistoryQuery.breakdown(cells: cells, by: .project, weights: .default, limit: 3)

    #expect(rows.count == 4)
    #expect(rows.last!.isOther)
    #expect(isClose(rows.reduce(0) { $0 + $1.units }, total))
    #expect(isClose(rows.reduce(0) { $0 + $1.share }, 1))
}

@Test func breakdownByModelUsesTheModelMultiplier() {
    // The `by:` dimension must switch the label AND leave the weighting alone:
    // an Opus cell is five default-weight units, and a breakdown that ignored
    // the multiplier would rank a cheap model above an expensive one.
    let cells = [
        cell(bucket: queryBase, model: "claude-opus-5", output: 10),
        cell(bucket: queryBase + 900, model: "claude-sonnet-5", output: 20),
    ]

    let rows = HistoryQuery.breakdown(cells: cells, by: .model, weights: .default, limit: 10)

    #expect(rows.map(\.label) == ["claude-opus-5", "claude-sonnet-5"])
    #expect(isClose(rows[0].units, 10 * Weights.default.output * 5))
}

// MARK: - Percent of allowance

/// A tracking observation `offset` seconds into the window starting at `start`.
///
/// ⚠️ `resetsAt` is a parameter only so one test can make the two readings
/// either side of a re-grant DISAGREE about it, the way the two real capture
/// sources do. Nothing in the query is allowed to read it.
private func reading(_ percent: Double, at offset: TimeInterval,
                     from start: Date, resetsAt: Date? = nil) -> TrackingEntry {
    TrackingEntry(percent: percent, at: start.addingTimeInterval(offset),
                  resetsAt: resetsAt ?? start.addingTimeInterval(sevenDays))
}

@Test func theSeriesBreaksWhereTheAllowanceWasReGranted() {
    // 🔴 THE test for this unit, and it is the live 2026-09-01 event: 51% at
    // 17:24, then 3% at 19:01 with `resets_at` unmoved. The burn curve beside
    // this one shows NOTHING at that instant — units are monotonic and a
    // re-grant does not un-spend a token — so the percentage is the only series
    // in which the event is visible at all. That is the entire reason this
    // query exists.
    let start = Date(timeIntervalSince1970: Double(queryBase))
    let end = start.addingTimeInterval(sevenDays)
    let regrantSeen: TimeInterval = 4 * 3_600 + 5_820      // 97 minutes after the last 51%
    let entries = [
        reading(44, at: 3 * 3_600, from: start),
        reading(51, at: 4 * 3_600, from: start),           // the last of the old allowance
        reading(3, at: regrantSeen, from: start),          // the first of the new one
        reading(5, at: 6 * 3_600, from: start),
    ]

    let series = HistoryQuery.percentCurve(tracking: entries, start: start, end: end)

    #expect(series.points.map(\.percent) == [44, 51, 3, 5])
    // The flag is on the reading AFTER the drop: the one before it is the last
    // measurement of an allowance that no longer exists.
    #expect(series.points.map(\.followsRegrant) == [false, false, true, false])
    #expect(series.points.filter(\.followsRegrant).map(\.at)
            == [start.addingTimeInterval(regrantSeen)])
    #expect(series.points.map(\.allowance) == [0, 0, 1, 1])
    #expect(series.regrants.count == 1)
    #expect(series.regrants.first?.percentBefore == 51)
    #expect(series.regrants.first?.percentAfter == 3)
}

@Test func aReGrantIsSeenThoughTheTwoSourcesDisagreeAboutTheResetBySecond() {
    // 🔴 The entries' own `resetsAt` is NEVER compared. On the live event the
    // two readings carry `06:59:59.424Z` and `07:00:00Z`, because they came
    // from the two capture sources, which report one instant to different
    // precision. "The reset did not move" is established by both readings
    // falling inside ONE window — the containment this query already does — and
    // an equality test on `resetsAt` would have missed the only re-grant on
    // record. Same rule, same reason, as `WindowLedger.regrantObservations`.
    let start = Date(timeIntervalSince1970: Double(queryBase))
    let end = start.addingTimeInterval(sevenDays)
    let entries = [
        reading(51, at: 4 * 3_600, from: start, resetsAt: end.addingTimeInterval(0.424)),
        reading(3, at: 5 * 3_600, from: start, resetsAt: end.addingTimeInterval(-1)),
    ]

    let series = HistoryQuery.percentCurve(tracking: entries, start: start, end: end)

    #expect(series.regrants.count == 1)
    #expect(series.points.map(\.followsRegrant) == [false, true])
}

@Test func elapsedFractionIsMeasuredAgainstThisWindowsOwnBounds() {
    // The axis is what makes overlaying two weeks valid, and only the window
    // defines it. Two ways to get it wrong, both live: measuring from the
    // window's END rather than its start, and dividing by a hardcoded seven
    // days rather than by this window's real duration — which differs whenever
    // an observed reset moved a boundary, and across a DST week, which is 167
    // or 169 hours.
    let sixDays: TimeInterval = 6 * 86_400
    let start = Date(timeIntervalSince1970: Double(queryBase))

    let series = HistoryQuery.percentCurve(
        tracking: [reading(37, at: 3 * 86_400, from: start)],
        start: start, end: start.addingTimeInterval(sixDays))

    // Three days into a SIX-day window is halfway. Against a hardcoded week it
    // is 0.4286; measured from the end it is negative.
    #expect(series.points.count == 1)
    guard let point = series.points.first else { return }
    #expect(isClose(point.elapsedFraction, 0.5))
    #expect(!isClose(point.elapsedFraction, 3.0 / 7.0))
}

@Test func percentSeriesFromDifferentWeeksShareOneAxis() {
    // The same argument `burnCurvesAreIndexedToWindowElapsedNotWallClock`
    // makes, and it has to hold for BOTH series or the toggle between them
    // switches axes underneath the reader.
    let startA = Date(timeIntervalSince1970: Double(queryBase))
    let startB = startA.addingTimeInterval(3 * 86_400)          // a different weekday

    let a = HistoryQuery.percentCurve(
        tracking: [reading(23, at: sevenDays / 4, from: startA)],
        start: startA, end: startA.addingTimeInterval(sevenDays))
    let b = HistoryQuery.percentCurve(
        tracking: [reading(61, at: sevenDays / 4, from: startB)],
        start: startB, end: startB.addingTimeInterval(sevenDays))

    #expect(a.points.count == 1)
    #expect(b.points.count == 1)
    guard let first = a.points.first, let second = b.points.first else { return }
    #expect(isClose(first.elapsedFraction, 0.25))
    #expect(isClose(second.elapsedFraction, 0.25))
}

@Test func readingsFromOtherWindowsAreNotDrawnAndNeverLookLikeAReGrant() {
    // 🔴 The ordinary weekly reset is an 87 → 4 drop and it is NOT a re-grant.
    // Anything that lets the previous window's last reading sit beside this
    // window's first would annotate almost every week in the archive as
    // re-granted — the trap `WindowLedger` records against its own walk.
    //
    // The rule is containment of `at` in [start, end): a reading exactly at
    // `start` is this window's, one exactly at `end` belongs to the next.
    // ⚠️ Deliberately NOT the bucket-ownership rule the unit queries share — a
    // tracking entry is an instant, not a fifteen-minute bucket, and rounding
    // one to a bucket would move readings across a boundary.
    let start = Date(timeIntervalSince1970: Double(queryBase))
    let end = start.addingTimeInterval(sevenDays)
    let entries = [
        reading(87, at: -1_800, from: start),           // the previous week's last
        reading(4, at: 0, from: start),                 // exactly at start: this week's
        reading(19, at: 5 * 86_400, from: start),
        reading(2, at: sevenDays, from: start),         // exactly at end: the next week's
    ]

    let series = HistoryQuery.percentCurve(tracking: entries, start: start, end: end)

    #expect(series.points.map(\.percent) == [4, 19])
    // 87 → 4 and 19 → 2 are both material drops. Neither is inside this window.
    #expect(series.regrants.isEmpty)
}

@Test func aWeekWithNoReadingsIsEmptyRatherThanAZeroOrigin() {
    // 🔴 Missing is not zero — the distinction this feature has already been
    // bitten by. `burnCurve` opens every series with `(0, 0)` because zero
    // units consumed at a window's start is true BY DEFINITION. Nothing of the
    // sort is true of a percentage: the series exists only forward from the
    // commit that stopped pruning tracking entries, so nearly every archived
    // week has none at all, and a synthetic origin would draw those weeks as a
    // line rising from 0% — a claim about the allowance instead of an admission
    // of ignorance.
    let start = Date(timeIntervalSince1970: Double(queryBase))
    let end = start.addingTimeInterval(sevenDays)
    // Real readings, every one of them in the FOLLOWING week.
    let elsewhere = [reading(31, at: sevenDays + 3_600, from: start),
                     reading(46, at: sevenDays + 7_200, from: start)]

    let absent = HistoryQuery.percentCurve(tracking: elsewhere, start: start, end: end)
    #expect(absent.points.isEmpty)
    #expect(absent.regrants.isEmpty)
    #expect(absent.isEmpty)

    // The positive control, and the anti-origin assertion in one: a week that
    // DOES have readings begins at its first real one, not at (0, 0).
    let drawn = HistoryQuery.percentCurve(tracking: elsewhere, start: end,
                                          end: end.addingTimeInterval(sevenDays))
    #expect(drawn.points.count == 2)
    #expect(!drawn.isEmpty)
    guard let opening = drawn.points.first else { return }
    #expect(opening.percent == 31)
    #expect(!isClose(opening.elapsedFraction, 0))
}

@Test func readingsAreOrderedByTheirInstantNotByArchiveOrder() {
    // `tracking.json` is append-only and has always been written in order, so
    // ordering holds today by accident rather than by construction. A series
    // built in file order would, on any out-of-order write, draw the line
    // backwards AND invent a re-grant out of a climb read in reverse — which is
    // exactly what the reversed fixture below produces if this is unsorted.
    let start = Date(timeIntervalSince1970: Double(queryBase))
    let end = start.addingTimeInterval(sevenDays)
    let chronological = [
        reading(12, at: 3_600, from: start),
        reading(48, at: 7_200, from: start),
        reading(6, at: 10_800, from: start),            // the one real re-grant
        reading(17, at: 14_400, from: start),
    ]

    let ordered = HistoryQuery.percentCurve(tracking: chronological, start: start, end: end)
    let reversed = HistoryQuery.percentCurve(tracking: chronological.reversed(),
                                             start: start, end: end)

    #expect(ordered == reversed)
    #expect(ordered.points.map(\.percent) == [12, 48, 6, 17])
    // Read backwards this fixture shows TWO drops (17 → 6 and 48 → 12).
    #expect(ordered.regrants.count == 1)
}

@Test func repeatedReadingsAtOneInstantNeverFabricateABreak() {
    // The live `tracking.json` holds three exact duplicates among its 211
    // entries — the writer is at-least-once and reads deduplicate. Beyond that,
    // two capture sources can date one reading to the same instant.
    //
    // A drop between two readings at ONE instant is never a re-grant: a
    // re-issued allowance is an event BETWEEN observations, and the order
    // within a single instant carries no information. Sorting ascending by
    // percent inside an instant is what guarantees it — the transition within
    // an instant is then never downward — and it also makes the series
    // deterministic, which `Array.sort` does not otherwise promise.
    let start = Date(timeIntervalSince1970: Double(queryBase))
    let end = start.addingTimeInterval(sevenDays)
    let together: TimeInterval = 9_000
    // ⚠️ The disagreeing source comes FIRST, and that is the whole test.
    // Listed in ascending order this fixture passes with or without the
    // tie-break — the sort has nothing to reorder — so it could not fail for
    // the defect the paragraph above describes. Written adversarially, an
    // ordering by instant alone leaves 41 → 13 adjacent and fabricates a
    // 28-point re-grant.
    let entries = [
        reading(41, at: together, from: start),         // a disagreeing source
        reading(13, at: together, from: start),
        reading(13, at: together, from: start),         // an exact duplicate
        reading(45, at: together + 3_600, from: start),
    ]

    let series = HistoryQuery.percentCurve(tracking: entries, start: start, end: end)

    #expect(series.points.map(\.percent) == [13, 13, 41, 45])
    #expect(series.regrants.isEmpty)                    // 41 → 13 is not an event
}

@Test func theSeriesAndTheWindowLedgerAgreeOnWhatCountsAsAReGrant() {
    // The archived window row and this series describe the same event from the
    // same entries, and must never disagree about whether it happened: a row
    // annotated "re-granted" above a curve drawn straight through it — or the
    // reverse — is worse than either alone. So the threshold is read from
    // `RateLimitHighWater.materialDropPoints` in both places and restated in
    // neither, and this pins the two walks together.
    let start = Date(timeIntervalSince1970: Double(queryBase))
    let end = start.addingTimeInterval(sevenDays)
    let threshold = RateLimitHighWater.materialDropPoints
    let entries = [
        reading(63, at: 3_600, from: start),
        // Just under the threshold: two sources rounding one figure, not a
        // re-issued allowance. Must not break the line.
        reading(63 - (threshold - 0.5), at: 7_200, from: start),
        reading(71, at: 10_800, from: start),
        // Exactly at it: it does.
        reading(71 - threshold, at: 14_400, from: start),
    ]

    let series = HistoryQuery.percentCurve(tracking: entries, start: start, end: end)
    let ledger = WindowLedger.regrantObservations(in: entries)

    #expect(ledger.count == 1)                          // the fixture's premise
    #expect(series.regrants.count == ledger.count)
    #expect(series.points.filter(\.followsRegrant).map(\.at) == ledger.map(\.at))
}

@Test func twoReGrantsInOneWindowOpenThreeAllowances() {
    // A window row records only the LAST re-grant plus a count, because a row
    // is one line; the series is not so constrained, and it is the only place a
    // second one can be SEEN. Without a per-point allowance index a renderer
    // would have to find the breaks itself, which is arithmetic in a view.
    let start = Date(timeIntervalSince1970: Double(queryBase))
    let end = start.addingTimeInterval(sevenDays)
    let entries = [
        reading(50, at: 3_600, from: start),
        reading(7, at: 7_200, from: start),
        reading(29, at: 10_800, from: start),
        reading(4, at: 14_400, from: start),
        reading(16, at: 18_000, from: start),
    ]

    let series = HistoryQuery.percentCurve(tracking: entries, start: start, end: end)

    #expect(series.points.map(\.allowance) == [0, 1, 1, 2, 2])
    #expect(series.points.map(\.followsRegrant) == [false, true, false, true, false])
    #expect(series.regrants.map(\.percentBefore) == [50, 29])
    #expect(series.regrants.map(\.percentAfter) == [7, 4])
}

@Test func theMarkerSpansTheStretchTheReGrantHappenedIn() {
    // 🔴 The re-grant ITSELF is unrecoverable. On the live event the readings
    // either side were ninety-seven minutes apart and nothing recorded where
    // inside that stretch the allowance was re-issued — the gap is there
    // *because* the old code was frozen and reporting nothing. So the marker
    // carries both fractions: the last instant the old allowance is known to
    // have still held, and the first at which the new one is known to have
    // already been in force. A renderer handed one hard x can only state a time
    // nobody observed; handed both it can draw the uncertainty, and it does so
    // without measuring anything itself.
    let start = Date(timeIntervalSince1970: Double(queryBase))
    let end = start.addingTimeInterval(sevenDays)
    let series = HistoryQuery.percentCurve(
        tracking: [reading(51, at: sevenDays / 4, from: start),
                   reading(3, at: sevenDays / 2, from: start)],
        start: start, end: end)

    #expect(series.regrants.count == 1)
    guard let marker = series.regrants.first else { return }
    #expect(isClose(marker.lastKnownFraction, 0.25))
    #expect(isClose(marker.knownByFraction, 0.5))
    #expect(marker.lastKnownFraction < marker.knownByFraction)
    #expect(marker.percentBefore == 51)
    #expect(marker.percentAfter == 3)
}

@Test func theFlagTheAllowanceIndexAndTheMarkerAllNameTheSamePoint() {
    // Three views of one event, and a renderer uses all three: the allowance
    // index to break the polyline, the flag to ring the point it resumes at,
    // the marker to draw the break between them. They come out of a single walk
    // so they cannot drift, and this is what says so — a fourth caller adding
    // its own scan is the thing being prevented.
    let start = Date(timeIntervalSince1970: Double(queryBase))
    let end = start.addingTimeInterval(sevenDays)
    let entries = [
        reading(50, at: 3_600, from: start),
        reading(7, at: 7_200, from: start),
        reading(29, at: 10_800, from: start),
        reading(4, at: 14_400, from: start),
        reading(16, at: 18_000, from: start),
    ]

    let series = HistoryQuery.percentCurve(tracking: entries, start: start, end: end)

    #expect(series.points.filter(\.followsRegrant).count == series.regrants.count)
    #expect(series.points.last?.allowance == series.regrants.count)
    for (index, marker) in series.regrants.enumerated() {
        let opened = series.points.filter { $0.followsRegrant && $0.allowance == index + 1 }
        #expect(opened.count == 1)
        // ⚠️ `.first`, never `opened[0]`: a subscript on an empty array TRAPS,
        // and a trap in a test aborts the whole process — every later test in
        // the run reports nothing at all, which is how a mutation that this
        // suite does catch reads as "the build is broken".
        guard let resumed = opened.first else { continue }
        #expect(isClose(resumed.elapsedFraction, marker.knownByFraction))
        #expect(resumed.percent == marker.percentAfter)
    }
}

@Test func aWindowWhoseFirstReadingIsAlreadyPostReGrantShowsNoBreak() {
    // The same deliberate omission `WindowLedger` makes: a re-grant that
    // happened before the window's first contained reading leaves no drop to
    // see, and this archive labels what it knows rather than what it assumes.
    // An unmarked break costs the chart a note; a guessed one draws an event at
    // an instant nobody observed.
    let start = Date(timeIntervalSince1970: Double(queryBase))
    let end = start.addingTimeInterval(sevenDays)
    let entries = [
        reading(9, at: 3_600, from: start),
        reading(14, at: 7_200, from: start),
        reading(22, at: 10_800, from: start),
    ]

    let series = HistoryQuery.percentCurve(tracking: entries, start: start, end: end)

    #expect(series.regrants.isEmpty)
    #expect(series.points.allSatisfy { $0.allowance == 0 && !$0.followsRegrant })
}

@Test func aWindowWithNoDurationDrawsNothing() {
    // Bounds are passed in rather than inferred, so a caller can hand over
    // anything, and dividing by a zero duration yields infinity or NaN.
    //
    // ⚠️ What actually holds this is CONTAINMENT, not the duration guard: no
    // reading can satisfy `at >= start && at < end` when `end <= start`, so the
    // series is empty before any division happens. Said plainly because the
    // guard is unreachable defence — removing it passes this test — and a test
    // that claims to police something it cannot is worse than no test.
    let start = Date(timeIntervalSince1970: Double(queryBase))
    let series = HistoryQuery.percentCurve(
        tracking: [reading(38, at: 0, from: start)], start: start, end: start)

    #expect(series.isEmpty)
}

// MARK: - Scale

@Test func queryOverATenYearArchiveStaysOffTheHotPath() {
    // One year of the real corpus is ~27,000 cells, so a year is not a stress
    // case. Ten years is, and the archive never shrinks — retention prunes
    // transcripts, not history. This is also the only headroom evidence that
    // loading the archive off the main actor is sized right: at seconds per
    // query no amount of background loading saves the window.
    let cells = syntheticArchive(count: 270_000, projects: 18)

    let began = Date()
    let rows = HistoryQuery.breakdown(cells: cells, by: .project, weights: .default, limit: 5)
    let elapsed = Date().timeIntervalSince(began)

    #expect(rows.count == 6)
    #expect(elapsed < 2, "breakdown over \(cells.count) cells took \(elapsed)s")
}

@Test func multipliersAreResolvedOncePerQueryNotPerCell() {
    // ⚠️ `Weights.modelMultipliers` is an ORDERED, substring-matched array, so
    // resolving a model costs a walk of the list plus a `lowercased()`
    // allocation per candidate. Done per cell that is O(cells × candidates) —
    // the performance question that was measured and explicitly closed on
    // `ScanCache.units`. `ResolvedMultipliers` collapses it to one walk per
    // DISTINCT model. A rule that lives only in a comment is the failure mode
    // this project repeats most, so this pins it: the list below matches only
    // on its last entry, which makes a per-cell walk ruinous and a resolved
    // one free.
    let model = "claude-sonnet-5"
    var weights = Weights.default
    weights.modelMultipliers = (0..<199).map {
        ModelMultiplier(match: "not-a-real-model-\($0)", multiplier: 2.0)
    } + [ModelMultiplier(match: model, multiplier: 7.0)]

    let cells = (0..<100_000).map {
        cell(bucket: queryBase + $0 * 900, project: "project-\($0 % 18)", model: model, output: 1)
    }

    let began = Date()
    let rows = HistoryQuery.breakdown(cells: cells, by: .project, weights: weights, limit: 5)
    let elapsed = Date().timeIntervalSince(began)

    // The last entry really is the one that matched, so the walk was long.
    #expect(isClose(rows.reduce(0) { $0 + $1.units },
                    100_000 * Weights.default.output * 7))
    #expect(elapsed < 2, "breakdown over \(cells.count) cells took \(elapsed)s")
}

private func syntheticArchive(count: Int, projects: Int) -> [HistoryRow] {
    // Labels are interned so the generator itself is not what the timing
    // measures — only the query is timed, but a slow fixture makes the suite
    // unpleasant enough that someone deletes the test.
    let projectNames = (0..<projects).map { "project-\($0)" }
    let models = ["claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5",
                  "claude-opus-4-1", "claude-sonnet-4-5", "<synthetic>"]
    let counts = TokenCounts(input: 120, output: 400, cacheWrite: 900, cacheRead: 45_000)
    var rows: [HistoryRow] = []
    rows.reserveCapacity(count)
    for index in 0..<count {
        rows.append(HistoryRow(bucket: queryBase + index * 900,
                               project: projectNames[index % projects],
                               model: models[index % models.count],
                               counts: counts))
    }
    return rows
}
