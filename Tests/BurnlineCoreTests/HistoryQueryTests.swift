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
