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
                                 lastWritten: Date? = nil) -> [WindowRow] {
    anchored.writableRows(coverage: threeWeeks, lastWritten: lastWritten, cells: cells,
                          tracking: tracking, now: plus(days: 15, from: anchorDate))
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

@Test func aWindowRowIsNeverWrittenBeforeItsCellsAreCovered() {
    // Guards writing a window total from a partly-filled archive — the row is
    // written once, so an undercount is permanent.
    let partial = coverage(from: anchorDate, through: plus(days: 3, from: anchorDate))
    let rows = anchored.writableRows(coverage: partial, lastWritten: nil, cells: [],
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
        .writableRows(coverage: threeWeeks, lastWritten: nil, cells: [], tracking: [],
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
                      lastWritten: nil, cells: [], tracking: [], now: at(2026, 5, 16, 12))
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
                      lastWritten: nil, cells: [], tracking: [], now: at(2026, 11, 10, 12))
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
    let rows = rowsAfterAFortnight(lastWritten: anchorDate)
    #expect(rows.count == 1)
    #expect(rows.first?.start == plus(days: 7, from: anchorDate))
}

@Test func aStartASubSecondPastLastWrittenIsStillTheSameWindow() {
    // 🔴 `windows.jsonl` round-trips through `.iso8601`, which encodes WHOLE
    // seconds — so `lastWritten` comes back up to a second EARLIER than the
    // grid start it was written from, because a real anchor carries a fraction
    // (`resetsAt: 1787295600.181`, measured on this machine). Exact `<=` reads
    // that as a window it has never seen and appends it again every 60s.
    //
    // Weekly starts are seven days apart, so a 60s tolerance cannot reach the
    // neighbouring window — which this asserts by still expecting the next one.
    let fractional = WindowLedger(anchor: anchorDate.addingTimeInterval(0.181),
                                  schedule: placeholder)
    let rows = fractional.writableRows(coverage: threeWeeks, lastWritten: anchorDate,
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

    let rows = anchored.writableRows(coverage: threeWeeks, lastWritten: nil, cells: [],
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
