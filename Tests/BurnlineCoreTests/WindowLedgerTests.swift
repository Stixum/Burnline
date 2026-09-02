import Testing
import Foundation
@testable import BurnlineCore

private let newYork = TimeZone(identifier: "America/New_York")!

private var ledgerCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = newYork
    return calendar
}

private func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    ledgerCalendar.date(from: DateComponents(year: year, month: month, day: day,
                                             hour: hour, minute: minute))!
}

private func plus(days: Int, from date: Date) -> Date {
    ledgerCalendar.date(byAdding: .day, value: days, to: date)!
}

/// Thursday 09:00 — the shipped `BurnlineSettings` placeholder, and nothing
/// ever writes the real reset back over it. Every anchored fixture below uses
/// it deliberately: it disagrees with the anchor grid, so an implementation
/// that reaches for the schedule when a capture is dead produces different
/// bounds and fails rather than passing quietly.
private let placeholder = ResetSchedule(weekday: 5, hour: 9, minute: 0, timeZone: newYork)

/// Tuesday 14:23 — not the placeholder's weekday, not its time, and not on a
/// 15-minute bucket boundary either.
private let anchorDate = at(2026, 5, 12, 14, 23)

private func coverage(from: Date, through: Date) -> Coverage {
    Coverage(records: [CoverageRecord(from: Int(from.timeIntervalSince1970),
                                      through: Int(through.timeIntervalSince1970),
                                      filledBy: "test")])
}

/// Coverage over the anchor window and the two that follow it.
private var threeWeeks: Coverage {
    coverage(from: anchorDate, through: plus(days: 21, from: anchorDate))
}

private var anchored: WindowLedger {
    WindowLedger(anchor: anchorDate, schedule: placeholder)
}

private func cell(daysIn: Int, output: Int) -> HistoryRow {
    let date = plus(days: daysIn, from: anchorDate)
    let start = Bucket.start(ofKey: Bucket.key(for: date))
    return HistoryRow(bucket: Int(start.timeIntervalSince1970), project: "Burnline",
                      model: "claude-opus-5", counts: TokenCounts(output: output))
}

private func rowsAfterAFortnight(tracking: [TrackingEntry] = [],
                                 cells: [HistoryRow] = [],
                                 written: [WindowRow] = []) -> [WindowRow] {
    anchored.writableRows(coverage: threeWeeks, written: written, cells: cells,
                          tracking: tracking, now: plus(days: 15, from: anchorDate))
}

/// A row already on disk for `[start, start + 7d)`, as `windows.jsonl` gives it
/// back: `.iso8601` encodes WHOLE seconds, so any fraction the grid carried is
/// gone by the time it is read.
private func writtenWindow(startingAt start: Date) -> WindowRow {
    let truncated = Date(timeIntervalSince1970: start.timeIntervalSince1970.rounded(.down))
    return WindowRow(start: truncated, end: plus(days: 7, from: truncated), counts: .zero,
                     finalPercent: nil, finalPercentAt: nil, finalPercentSource: nil,
                     boundsSource: .extrapolated, observedResetsAt: nil)
}

@Test func windowsEndingAFTERTheAnchorAreStillWritten() {
    // 🔴 THE test. The anchor is a reset observed just before a quit; two more
    // windows closed while the app was down. Their ends are anchor+7d and
    // anchor+14d, which a grid that only steps BACKWARD from the anchor never
    // produces — so no row is written for either, silently, which is the exact
    // absence this feature exists to cover.
    let rows = rowsAfterAFortnight()
    #expect(rows.count == 2)
    #expect(rows.map(\.end) == [plus(days: 7, from: anchorDate),
                                plus(days: 14, from: anchorDate)])
    #expect(rows.first?.start == anchorDate)
    #expect(rows.last?.start == plus(days: 7, from: anchorDate))
}

@Test func thirtyOneDaysOfCoverageQualifiesEveryWholeWindowInsideIt() {
    // Day one over a real corpus: 31 days of gapless coverage that starts two
    // hours INTO the oldest window on the grid. Three whole windows sit inside
    // it and all three must be written; the partial one must not, and an
    // implementation that stops walking at the first window it cannot cover
    // returns nothing at all.
    let start = plus(days: -28, from: anchorDate).addingTimeInterval(2 * 3_600)
    let thirtyOneDays = coverage(from: start, through: anchorDate)
    let cells = [cell(daysIn: -25, output: 7), cell(daysIn: -18, output: 11),
                 cell(daysIn: -11, output: 13), cell(daysIn: -4, output: 17)]

    let rows = anchored.writableRows(coverage: thirtyOneDays, written: [],
                                     cells: cells, tracking: [],
                                     now: plus(days: 2, from: anchorDate))

    #expect(rows.count == 3)
    #expect(rows.map(\.start) == [plus(days: -21, from: anchorDate),
                                  plus(days: -14, from: anchorDate),
                                  plus(days: -7, from: anchorDate)])
    // The oldest window is genuinely short of coverage and stays absent — the
    // stop on a fix that simply writes everything.
    #expect(!rows.contains { $0.start == plus(days: -28, from: anchorDate) })
    #expect(rows.map(\.output) == [11, 13, 17])
}

@Test func aWindowRowIsNeverWrittenBeforeItsCellsAreCovered() {
    // Guards writing a window total from a partly-filled archive — the row is
    // written once, so an undercount is permanent.
    let partial = coverage(from: anchorDate, through: plus(days: 3, from: anchorDate))
    let rows = anchored.writableRows(coverage: partial, written: [], cells: [],
                                     tracking: [], now: plus(days: 10, from: anchorDate))
    #expect(rows.isEmpty)
}

@Test func aPercentageSurvivesAnAbsence() {
    // Guards dropping the tracked reading for a window that closed while the
    // app was down. Anthropic's own figure is unrecoverable once gone.
    let entry = TrackingEntry(percent: 87, at: plus(days: 3, from: anchorDate),
                              resetsAt: plus(days: 7, from: anchorDate))
    let rows = rowsAfterAFortnight(tracking: [entry])
    #expect(rows.first?.finalPercent == 87)
    #expect(rows.first?.finalPercentAt == entry.at)
    #expect(rows.first?.finalPercentSource == "live")
}

@Test func aNewerEntryFromTheNextWindowIsNotUsed() {
    // 🔴 Guards `tracking.last`, which passes every other test here. The 4%
    // belongs to the window that is still running; attributing it to the
    // closed one records a week of heavy usage as almost none.
    let closed = TrackingEntry(percent: 87, at: plus(days: 3, from: anchorDate),
                               resetsAt: plus(days: 7, from: anchorDate))
    let current = TrackingEntry(percent: 4, at: plus(days: 8, from: anchorDate),
                                resetsAt: plus(days: 14, from: anchorDate))
    let rows = rowsAfterAFortnight(tracking: [closed, current])
    #expect(rows.count == 2)
    #expect(rows.first?.finalPercent == 87)
    #expect(rows.last?.finalPercent == 4)
}

@Test func anEntryExactlyOnTheBoundaryBelongsToTheLaterWindow() {
    // Matches WindowMath's convention: an instant landing exactly on the reset
    // opens the new window rather than closing the old one.
    let boundary = plus(days: 7, from: anchorDate)
    let entry = TrackingEntry(percent: 33, at: boundary,
                              resetsAt: plus(days: 14, from: anchorDate))
    let rows = rowsAfterAFortnight(tracking: [entry])
    #expect(rows.count == 2)
    #expect(rows.first?.finalPercent == nil)
    #expect(rows.last?.finalPercent == 33)
}

@Test func anObservedResetSubSecondOffTheAnchorStillEarnsObserved() {
    // 🔴 The two capture sources report the same reset to different precision
    // — statusline whole seconds, utilization `…59.424563Z`, measured 0.58s
    // apart. Under exact equality this window comes back `.extrapolated` and
    // `.observed` is dead code no real data can ever reach.
    let end = plus(days: 7, from: anchorDate)
    let entry = TrackingEntry(percent: 87, at: plus(days: 3, from: anchorDate),
                              resetsAt: end.addingTimeInterval(-0.576))
    let rows = rowsAfterAFortnight(tracking: [entry])
    #expect(rows.first?.boundsSource == .observed)
    #expect(rows.first?.observedResetsAt == entry.resetsAt)
    // Within tolerance the grid boundary stands; the observation only labels it.
    #expect(rows.first?.end == end)
}

@Test func aFilledWindowWithNoTrackingIsExtrapolatedAndNull() {
    // Guards inventing a percentage, and guards overstating provenance:
    // bounds rolled back from an anchor are an inference, not an observation.
    let rows = rowsAfterAFortnight()
    #expect(rows.first?.boundsSource == .extrapolated)
    #expect(rows.first?.finalPercent == nil)
    #expect(rows.first?.finalPercentAt == nil)
    #expect(rows.first?.finalPercentSource == nil)
    #expect(rows.first?.observedResetsAt == nil)
}

@Test func withNoAnchorButAPastObservationRowsAreDeferred() {
    // 🔴 A machine where captures work has a placeholder schedule forever.
    // Writing rows from it would put every historical boundary on Thursday
    // 09:00 and attribute every total to the wrong seven-day slice — and rows
    // are written once. Deferring costs nothing.
    let rows = WindowLedger(anchor: nil, schedule: placeholder, hasEverObservedAReset: true)
        .writableRows(coverage: threeWeeks, written: [], cells: [], tracking: [],
                      now: plus(days: 15, from: anchorDate))
    #expect(rows.isEmpty)
}

@Test func aMachineThatHasNeverSeenACaptureUsesTheSchedule() {
    // ⚠️ Its own coverage fixture on purpose: a schedule-derived window lands
    // on Thursday 09:00, days away from the anchor grid every other test uses,
    // so sharing their coverage would return no rows for a fixture reason and
    // prove nothing about the schedule path.
    let previousReset = at(2026, 5, 7, 9)
    let reset = at(2026, 5, 14, 9)
    let rows = WindowLedger(anchor: nil, schedule: placeholder)
        .writableRows(coverage: coverage(from: previousReset, through: reset),
                      written: [], cells: [], tracking: [], now: at(2026, 5, 16, 12))
    #expect(rows.count == 1)
    #expect(rows.first?.start == previousReset)
    #expect(rows.first?.end == reset)
    #expect(rows.first?.boundsSource == .schedule)
}

@Test func boundsRollBackAcrossADSTBoundaryByCalendarDays() {
    // 1 Nov 2026 is the fall-back, so this window is 169 hours. Roll back
    // 604_800 seconds instead of 7 calendar days and the reset slides an hour
    // off its wall-clock time, mis-slicing an hour of tokens into the
    // neighbouring week — and every week after it, cumulatively.
    let dstAnchor = at(2026, 11, 4, 14, 23)
    let previous = at(2026, 10, 28, 14, 23)
    let rows = WindowLedger(anchor: dstAnchor, schedule: placeholder)
        .writableRows(coverage: coverage(from: previous, through: dstAnchor),
                      written: [], cells: [], tracking: [], now: at(2026, 11, 10, 12))
    #expect(rows.count == 1)
    #expect(rows.first?.start == previous)
    #expect(rows.first?.end == dstAnchor)
    let hours = (rows.first?.end.timeIntervalSince(previous) ?? 0) / 3600
    #expect(hours == 169)
    #expect(hours != 168)
}

@Test func recoverAnchorTakesTheNewestObservedReset() {
    // The manifest is the anchor's home; written rows are its recovery source,
    // and only the newest observation is a usable anchor.
    func row(observed: Date?) -> WindowRow {
        WindowRow(start: anchorDate, end: plus(days: 7, from: anchorDate), counts: .zero,
                  finalPercent: nil, finalPercentAt: nil, finalPercentSource: nil,
                  boundsSource: observed == nil ? .extrapolated : .observed,
                  observedResetsAt: observed)
    }
    let newest = at(2026, 5, 12, 14, 23)
    let rows = [row(observed: at(2026, 4, 28, 14, 23)), row(observed: nil),
                row(observed: newest), row(observed: at(2026, 5, 5, 14, 23))]
    #expect(WindowLedger.recoverAnchor(from: rows) == newest)
    #expect(WindowLedger.recoverAnchor(from: [row(observed: nil)]) == nil)
    #expect(WindowLedger.recoverAnchor(from: []) == nil)
}

@Test func aWindowTotalCountsOnlyTheCellsInsideIt() {
    // Guards summing the whole archive into every row, and guards a window
    // total that leaks the next week's tokens across the boundary.
    let cells = [cell(daysIn: 2, output: 40), cell(daysIn: 3, output: 2),
                 cell(daysIn: 9, output: 1_000), cell(daysIn: -2, output: 500)]
    let rows = rowsAfterAFortnight(cells: cells)
    #expect(rows.count == 2)
    #expect(rows.first?.output == 42)
    #expect(rows.last?.output == 1_000)
}

@Test func aWindowAlreadyWrittenIsNotWrittenAgain() {
    // The archive is append-only, so a second pass over the same window would
    // double it rather than replace it.
    let rows = rowsAfterAFortnight(written: [writtenWindow(startingAt: anchorDate)])
    #expect(rows.count == 1)
    #expect(rows.first?.start == plus(days: 7, from: anchorDate))
}

@Test func aStartASubSecondPastAWrittenRowIsStillTheSameWindow() {
    // 🔴 `windows.jsonl` round-trips through `.iso8601`, which encodes WHOLE
    // seconds — so a written row comes back up to a second EARLIER than the
    // grid start it went out as, because a real anchor carries a fraction
    // (`resetsAt: 1787295600.181`, measured on this machine). Read exactly,
    // that is a window the ledger has never seen and it appends it again every
    // 60s. It shipped: the archive held five identical rows.
    //
    // Weekly windows are seven days long, so a minute of tolerance cannot reach
    // the neighbouring one — which this asserts by still expecting the next
    // window, whose start the written row's end overhangs by that same 0.181s.
    let fractional = WindowLedger(anchor: anchorDate.addingTimeInterval(0.181),
                                  schedule: placeholder)
    let rows = fractional.writableRows(coverage: threeWeeks,
                                       written: [writtenWindow(startingAt: anchorDate)],
                                       cells: [], tracking: [],
                                       now: plus(days: 15, from: anchorDate))
    #expect(rows.count == 1)
    // The one row is the NEXT window, carrying the anchor's fraction. Compared
    // loosely on purpose: seven days of separation is what identifies it, and
    // `0.181` does not survive a `Double` round trip exactly.
    let offset = rows.first?.start.timeIntervalSince(plus(days: 7, from: anchorDate))
    #expect(abs(offset ?? .infinity) < 1)
}

@Test func anObservationBeyondToleranceMovesTheGridAndTheNextWindowWithIt() {
    // The beyond-tolerance branch: a reset someone actually SAW, far enough
    // from the inferred grid that it is a correction rather than precision
    // noise. The observation wins — the grid is an inference — and writing it
    // back must carry the NEXT window's start with it, or the two windows
    // overlap and a bucket is counted twice.
    //
    // Added because this branch was implemented beyond spec and shipped
    // uncovered, and it silently changes window boundaries.
    let gridEnd = plus(days: 7, from: anchorDate)
    let realReset = gridEnd.addingTimeInterval(6 * 3_600)      // 6h off, far beyond 60s
    let entry = TrackingEntry(percent: 55,
                              at: gridEnd.addingTimeInterval(-3_600),
                              resetsAt: realReset)

    let rows = anchored.writableRows(coverage: threeWeeks, written: [], cells: [],
                                     tracking: [entry],
                                     now: plus(days: 20, from: anchorDate))

    let first = rows.first { $0.start == anchorDate }
    #expect(first?.end == realReset)
    #expect(first?.boundsSource == .observed)
    #expect(first?.observedResetsAt == realReset)

    // The correction propagates: the next window starts where this one ended,
    // so the grid stays contiguous and non-overlapping.
    #expect(rows.contains { $0.start == realReset })
    #expect(!rows.contains { $0.start == gridEnd })
}

// MARK: - Re-grant annotation

/// A capture inside the FIRST window of the anchored fixture, `days` in.
/// Its `resetsAt` is that window's grid end, which is what a real capture
/// inside a window reports.
private func observed(_ percent: Double, dayIn days: Int) -> TrackingEntry {
    TrackingEntry(percent: percent, at: plus(days: days, from: anchorDate),
                  resetsAt: plus(days: 7, from: anchorDate))
}

@Test func aReGrantedWeekIsAnnotatedAndKeepsAnthropicsLastReading() {
    // The shape measured live on 2026-09-01: 51% → 3% with `resets_at`
    // UNMOVED, then a climb. Such a week's token total exceeds a 91% week's
    // while its `finalPercent` reads 30, so with no annotation the row is
    // silently wrong-looking — and a window row is written once, so that is
    // wrong forever.
    //
    // 🔴 `regrant.percent` is 3, NOT 0. Ninety-seven minutes separated those
    // two real readings — the stretch where the old code was frozen and
    // recording nothing — so the first post-re-grant observation was already
    // at 3%. The annotation records what was SEEN, and the exact re-grant
    // instant is unrecoverable: it happened somewhere inside that gap.
    //
    // 🔴 `finalPercent` stays 30, the newest reading. Never 51 + 30 = 81: the
    // two epochs need not even be against the same allowance size, and this
    // field is documented as Anthropic's own figure, not Burnline's
    // arithmetic.
    let before = observed(51, dayIn: 1)
    let after = observed(3, dayIn: 2)
    let latest = observed(30, dayIn: 4)
    let rows = rowsAfterAFortnight(tracking: [before, after, latest])

    #expect(rows.first?.finalPercent == 30)
    #expect(rows.first?.finalPercentAt == latest.at)
    // The instant is the first OBSERVATION after the re-grant, never the
    // entry before the drop — that one is the last reading of the allowance
    // that ended.
    #expect(rows.first?.regrant?.at == after.at)
    #expect(rows.first?.regrant?.at != before.at)
    #expect(rows.first?.regrant?.percent == 3)
    #expect(rows.first?.regrant?.observed == 1)
}

@Test func aWeekThatOnlyClimbedIsNotAnnotated() {
    // The stop on annotating every week that has a tracking series at all.
    let rows = rowsAfterAFortnight(tracking: [observed(10, dayIn: 1), observed(37, dayIn: 3),
                                              observed(64, dayIn: 5)])
    #expect(rows.first?.finalPercent == 64)
    // One absent value, not three. A row that half-claims a re-grant is
    // unspellable now that the optional is the discriminator.
    #expect(rows.first?.regrant == nil)
}

@Test func aDropOfExactlyTheMaterialThresholdIsARegrant() {
    // Boundary-exact: `RateLimitHighWater.materialDropPoints` is 2, and the
    // rule is `>=`. The stop on `>`, and on this file restating the threshold
    // — the archive and the live path must agree on what counts as a re-grant,
    // or a week is annotated while no epoch ever opened, or the reverse.
    let rows = rowsAfterAFortnight(tracking: [observed(40, dayIn: 1), observed(38, dayIn: 3),
                                              observed(45, dayIn: 5)])
    #expect(rows.first?.regrant?.at == plus(days: 3, from: anchorDate))
    #expect(rows.first?.regrant?.percent == 38)
    #expect(rows.first?.regrant?.observed == 1)
    #expect(rows.first?.finalPercent == 45)
}

@Test func aSubMaterialDipIsNoiseAndIsNotAnnotated() {
    // 40 → 38.1 is 1.9 points. Two sources rounding the same figure
    // differently is far likelier than a re-issued allowance, which is why the
    // live path withholds the epoch below the threshold. The archive must
    // withhold the annotation on the same evidence.
    let rows = rowsAfterAFortnight(tracking: [observed(40, dayIn: 1), observed(38.1, dayIn: 3),
                                              observed(44, dayIn: 5)])
    #expect(rows.first?.finalPercent == 44)
    #expect(rows.first?.regrant == nil)
}

@Test func aSecondReGrantIsTheOneRecordedAndTheCountSaysThereWereTwo() {
    // 🔴 The decision, pinned. `regrant.at` is the LAST re-grant in the
    // window: `finalPercent` is the climb since that one, so the pair
    // describes a single stretch of the week only if the instant is the last.
    // Record the first and `finalPercent − regrant.percent` spans two
    // allowances — the same category of arithmetic the spec rejected by name
    // in 51 + 30 = 81. It also matches the live path, where a material drop
    // inside an open epoch REPLACES the `Regrant` wholesale.
    //
    // The count is what stops the row claiming there was exactly one. Rows are
    // written once, and this archive already labels what it cannot say
    // (`CoverageRecord.truncated`, `verified`).
    let rows = rowsAfterAFortnight(tracking: [
        observed(51, dayIn: 1), observed(3, dayIn: 2), observed(20, dayIn: 3),
        observed(6, dayIn: 4), observed(33, dayIn: 5)])
    #expect(rows.first?.regrant?.at == plus(days: 4, from: anchorDate))
    #expect(rows.first?.regrant?.percent == 6)
    #expect(rows.first?.regrant?.observed == 2)
    #expect(rows.first?.finalPercent == 33)
}

@Test func theResetBetweenTwoWindowsIsNotAReGrant() {
    // 🔴 87% closing one window and 4% opening the next is the weekly reset,
    // not a re-issued allowance. An implementation that walks the whole series
    // and hands each drop to the window CONTAINING the lower reading annotates
    // the second window every single week — quietly, and forever.
    let closing = observed(87, dayIn: 3)
    let opening = TrackingEntry(percent: 4, at: plus(days: 8, from: anchorDate),
                                resetsAt: plus(days: 14, from: anchorDate))
    let rows = rowsAfterAFortnight(tracking: [closing, opening])
    #expect(rows.count == 2)
    #expect(rows.first?.finalPercent == 87)
    #expect(rows.last?.finalPercent == 4)
    #expect(rows.allSatisfy { $0.regrant == nil })
}

@Test func aDropIsAReGrantEvenWhenTheTwoSourcesDisagreeAboutTheReset() {
    // 🔴 Measured on the live series, 211 entries: the two readings either
    // side of the real 2026-09-01 drop carry `2026-09-04T06:59:59Z` and
    // `…07:00:00Z` — the statusline's whole seconds against the utilization
    // file's fraction, the same one-second disagreement `sameResetTolerance`
    // exists for.
    //
    // So a rule phrased as "a drop with `resets_at` UNMOVED" and implemented
    // as equality would have missed the only re-grant this project has ever
    // seen. What establishes that the window did not reset is CONTAINMENT of
    // both readings in one window; the entries' own `resetsAt` is never
    // compared, and must not be.
    let end = plus(days: 7, from: anchorDate)
    let before = TrackingEntry(percent: 51, at: plus(days: 1, from: anchorDate),
                               resetsAt: end.addingTimeInterval(-1))
    let after = TrackingEntry(percent: 3, at: plus(days: 2, from: anchorDate), resetsAt: end)
    let latest = TrackingEntry(percent: 30, at: plus(days: 4, from: anchorDate), resetsAt: end)

    let rows = rowsAfterAFortnight(tracking: [before, after, latest])
    #expect(rows.first?.regrant?.at == after.at)
    #expect(rows.first?.regrant?.percent == 3)
    #expect(rows.first?.regrant?.observed == 1)
    #expect(rows.first?.finalPercent == 30)
}

@Test func twoReadingsAtOneInstantAreOneMomentNotAReGrant() {
    // 🔴 The probe that found this, run both ways round. `tracking.json`
    // stores `at` through `.iso8601`, which truncates to whole seconds, while
    // `HistoryWriter.observe` dedupes on FULL equality — so two readings dated
    // to the same second both survive routinely, in whichever order they
    // landed.
    //
    // Ordered by instant alone, that pair reads as a DROP or as a RISE
    // depending on the order: measured on the previous implementation,
    // `[49, 51, 55]` at one instant annotated a re-grant that never happened
    // while `[51, 49, 55]` missed one. Neither is an event. Two readings
    // sharing an instant are two sources describing one moment.
    let instant = plus(days: 2, from: anchorDate)
    let end = plus(days: 7, from: anchorDate)
    func series(_ percents: [Double]) -> [TrackingEntry] {
        percents.map { TrackingEntry(percent: $0, at: instant, resetsAt: end) }
    }

    // The shared ordering, directly: one total order whatever the file said.
    let asRising = WindowLedger.contained(series([49, 51, 55]), from: anchorDate, to: end)
    let asFalling = WindowLedger.contained(series([51, 49, 55]), from: anchorDate, to: end)
    #expect(asRising.map(\.percent) == [49, 51, 55])
    #expect(asFalling.map(\.percent) == [49, 51, 55])
    #expect(WindowLedger.regrantObservations(in: asRising).isEmpty)
    #expect(WindowLedger.regrantObservations(in: asFalling).isEmpty)

    // And through the row, which is where it was measured.
    for order in [[49, 51, 55], [51, 49, 55]] as [[Double]] {
        let rows = rowsAfterAFortnight(tracking: series(order))
        #expect(rows.first?.regrant == nil)
        #expect(rows.first?.finalPercent == 55)
    }
}

@Test func aReadingExactlyOnTheWindowStartIsInsideIt() {
    // Containment is `[start, end)`, the convention
    // `anEntryExactlyOnTheBoundaryBelongsToTheLaterWindow` already pins for
    // `finalPercent`. Here it decides whether the reading a drop is measured
    // FROM exists at all: exclude the boundary and this window holds two
    // readings, no pair spans the re-grant, and the annotation vanishes.
    let onTheBoundary = TrackingEntry(percent: 51, at: anchorDate,
                                      resetsAt: plus(days: 7, from: anchorDate))
    let rows = rowsAfterAFortnight(tracking: [onTheBoundary, observed(3, dayIn: 2),
                                              observed(30, dayIn: 4)])
    #expect(rows.first?.regrant?.at == plus(days: 2, from: anchorDate))
    #expect(rows.first?.regrant?.percent == 3)
    #expect(rows.first?.regrant?.observed == 1)
    #expect(rows.first?.finalPercent == 30)
}

@Test func aResetReadingExactlyOnTheBoundaryIsNotThisWeeksReGrant() {
    // 🔴 The sibling of `theResetBetweenTwoWindowsIsNotAReGrant`, one instant
    // tighter: that one dates the opening reading to day 8, which a `[start,
    // end]` containment still excludes. At EXACTLY the reset, an inclusive
    // upper bound admits it into the week it ends — and 87 → 4 then annotates
    // the closing week as re-granted. Every ordinary week, forever, because a
    // row is written once.
    let closing = observed(87, dayIn: 3)
    let opening = TrackingEntry(percent: 4, at: plus(days: 7, from: anchorDate),
                                resetsAt: plus(days: 14, from: anchorDate))
    let rows = rowsAfterAFortnight(tracking: [closing, opening])
    #expect(rows.count == 2)
    #expect(rows.first?.finalPercent == 87)
    #expect(rows.last?.finalPercent == 4)
    #expect(rows.allSatisfy { $0.regrant == nil })
}

@Test func finalPercentComesFromTheRowsOwnSeriesNotTheGridsNewest() {
    // 🔴 A row may not contradict itself. `finalPercent` used to be chosen
    // against the GRID's end while the annotation came from the substituted
    // bounds — so a reset observed six hours late made them different
    // readings, and the row reported `finalPercent` 51 from BEFORE the
    // re-grant beside an annotation at 3. `finalPercent − regrant.percent`
    // then reads 48: a subtraction across two allowances, invented by the
    // archive, which is the fabrication this feature exists to refuse.
    //
    // Both now come from one series taken on the row's own bounds, so
    // `finalPercentAt >= regrant.at` holds by construction.
    let gridEnd = plus(days: 7, from: anchorDate)
    let realReset = gridEnd.addingTimeInterval(6 * 3_600)
    let last = TrackingEntry(percent: 51, at: gridEnd.addingTimeInterval(-3_600),
                             resetsAt: realReset)
    let after = TrackingEntry(percent: 3, at: gridEnd.addingTimeInterval(3_600),
                              resetsAt: realReset)
    let latest = TrackingEntry(percent: 30, at: gridEnd.addingTimeInterval(4 * 3_600),
                               resetsAt: realReset)

    let rows = anchored.writableRows(coverage: threeWeeks, written: [], cells: [],
                                     tracking: [last, after, latest],
                                     now: plus(days: 20, from: anchorDate))
    let first = rows.first { $0.start == anchorDate }
    #expect(first?.end == realReset)
    #expect(first?.finalPercent == 30)
    #expect(first?.finalPercentAt == latest.at)
    #expect(first?.regrant?.at == after.at)
    #expect(first?.regrant?.percent == 3)
    #expect(first?.regrant?.observed == 1)
    // The contradiction, stated as the invariant it is.
    #expect((first?.finalPercentAt ?? .distantPast) >= (first?.regrant?.at ?? .distantFuture))
}
