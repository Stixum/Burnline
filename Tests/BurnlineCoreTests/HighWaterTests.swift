import Testing
import Foundation
@testable import BurnlineCore

private let reset: TimeInterval = 1_786_690_800

private func highWaterScratch() -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("burnline-highwater-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func capture(_ percent: Double, at captured: TimeInterval,
                     resetsAt: TimeInterval = reset,
                     fiveHour: RateLimitCapture.Reading? = nil) -> RateLimitCapture {
    RateLimitCapture(version: 1, capturedAt: captured,
                     sevenDay: .init(usedPercent: percent, resetsAt: resetsAt),
                     fiveHour: fiveHour)
}

private func proven(_ percent: Double, at t: TimeInterval,
                    provenAt: TimeInterval) -> RateLimitCapture {
    var c = capture(percent, at: t); c.provenAt = provenAt; return c
}

/// Several Claude Code sessions run the statusline script concurrently, each on
/// its own timer, each carrying the rate_limits block from its own last API
/// response — and they all overwrite the same file blind. An idle session
/// therefore replaces a fresh reading with a stale one twice a minute.
@Test func aLowerReadingInsideTheSameWindowIsRejectedAsStale() {
    let fresh = capture(65, at: 1_000)
    let (_, mark) = RateLimitHighWater.reconcile(fresh, against: .empty)

    let stale = capture(64, at: 2_000)
    let (result, _) = RateLimitHighWater.reconcile(stale, against: mark)

    #expect(result.sevenDay.usedPercent == 65)
}

/// Rejecting the value must also reject its timestamp, or the popover reports a
/// three-minute-old figure as having just landed.
@Test func aRejectedReadingDoesNotRefreshTheCaptureAge() {
    let fresh = capture(65, at: 1_000)
    let (_, mark) = RateLimitHighWater.reconcile(fresh, against: .empty)

    let (result, _) = RateLimitHighWater.reconcile(capture(64, at: 9_999), against: mark)

    #expect(result.capturedAt == 1_000)
}

@Test func aHigherReadingIsAdoptedAndBecomesTheNewMark() {
    let (_, mark) = RateLimitHighWater.reconcile(capture(64, at: 1_000), against: .empty)
    let (result, updated) = RateLimitHighWater.reconcile(capture(70, at: 2_000), against: mark)

    #expect(result.sevenDay.usedPercent == 70)
    #expect(result.capturedAt == 2_000)
    #expect(updated.sevenDay?.usedPercent == 70)
}

/// Re-reporting the same percentage is a fresh confirmation of it, so the age
/// must move even though the value doesn't.
@Test func anEqualReadingRefreshesTheAge() {
    let (_, mark) = RateLimitHighWater.reconcile(capture(64, at: 1_000), against: .empty)
    let (result, _) = RateLimitHighWater.reconcile(capture(64, at: 5_000), against: mark)

    #expect(result.capturedAt == 5_000)
}

/// The mark is only meaningful inside the window it was taken in. A new window
/// starts from nothing, or the previous week's high would pin the new one.
@Test func aNewWindowDiscardsTheEarlierMark() {
    let (_, mark) = RateLimitHighWater.reconcile(capture(90, at: 1_000), against: .empty)

    let nextWindow = capture(4, at: 2_000, resetsAt: reset + 7 * 86_400)
    let (result, updated) = RateLimitHighWater.reconcile(nextWindow, against: mark)

    #expect(result.sevenDay.usedPercent == 4)
    #expect(updated.sevenDay?.resetsAt == reset + 7 * 86_400)
}

// MARK: - Demotion, when the lower reading can be PROVEN to be the later one

/// The 2026-09-01 event: Anthropic re-issued the allowance mid-window and
/// the app rejected the truth as a stale session for three days.
@Test func aProvenLaterLowerReadingDemotesTheMark() {
    let (_, mark) = RateLimitHighWater.reconcile(proven(51, at: 1_000, provenAt: 1_000),
                                                 against: .empty)
    let (result, _) = RateLimitHighWater.reconcile(proven(0, at: 2_000, provenAt: 2_000),
                                                   against: mark)
    #expect(result.sevenDay.usedPercent == 0)
}

/// POSITIVE CONTROL for the test above: the identical fixture with an
/// INFERRED date must still be rejected. If this passes as 0, provenance is
/// decorative and the stale-session defence is gone.
@Test func anInferredLowerReadingNeverDemotes() {
    let (_, mark) = RateLimitHighWater.reconcile(proven(51, at: 1_000, provenAt: 1_000),
                                                 against: .empty)
    let (result, _) = RateLimitHighWater.reconcile(capture(0, at: 2_000), against: mark)
    #expect(result.sevenDay.usedPercent == 51)
}

/// An undated replayer must not creep the demotion basis forward, or it
/// outruns a frozen proven date indefinitely.
@Test func anUndatedReconfirmationDoesNotAdvanceTheProvenDate() {
    let (_, mark) = RateLimitHighWater.reconcile(proven(51, at: 1_000, provenAt: 1_000),
                                                 against: .empty)
    let (_, after) = RateLimitHighWater.reconcile(capture(51, at: 9_000), against: mark)
    #expect(after.sevenDay?.provenAt == 1_000)
    #expect(after.sevenDay?.capturedAt == 9_000, "display age still moves")
}

// MARK: - The 5-hour reading has the same problem and its own window

@Test func theFiveHourReadingIsReconciledIndependently() {
    let fiveReset: TimeInterval = 1_786_491_600
    let high = capture(64, at: 1_000,
                       fiveHour: .init(usedPercent: 30, resetsAt: fiveReset))
    let (_, mark) = RateLimitHighWater.reconcile(high, against: .empty)

    let low = capture(64, at: 2_000,
                      fiveHour: .init(usedPercent: 3, resetsAt: fiveReset))
    let (result, _) = RateLimitHighWater.reconcile(low, against: mark)

    #expect(result.fiveHour?.usedPercent == 30)
}

@Test func aFiveHourWindowThatHasRolledStartsOver() {
    let old: TimeInterval = 1_786_491_600
    let high = capture(64, at: 1_000, fiveHour: .init(usedPercent: 90, resetsAt: old))
    let (_, mark) = RateLimitHighWater.reconcile(high, against: .empty)

    let rolled = capture(64, at: 2_000,
                         fiveHour: .init(usedPercent: 2, resetsAt: old + 5 * 3_600))
    let (result, _) = RateLimitHighWater.reconcile(rolled, against: mark)

    #expect(result.fiveHour?.usedPercent == 2)
}

/// A capture with no five-hour block must not resurrect an earlier one.
@Test func anAbsentFiveHourReadingStaysAbsent() {
    let high = capture(64, at: 1_000,
                       fiveHour: .init(usedPercent: 30, resetsAt: 1_786_491_600))
    let (_, mark) = RateLimitHighWater.reconcile(high, against: .empty)

    let (result, _) = RateLimitHighWater.reconcile(capture(64, at: 2_000), against: mark)

    #expect(result.fiveHour == nil)
}

// MARK: - Schema version

/// A mark written before capture dating existed carries a `capturedAt` that the
/// old code took straight from `Date()` — a republished reading stamped as
/// fresh. Because the mark ties on percentage, the "equal re-confirmation takes
/// the later date" rule then preserves that stale timestamp for the rest of the
/// window. Hit for real on 2026-08-11 and cleared by hand; every upgrading user
/// would hit it once, with no symptom except a figure that looks fresher than
/// it is. Discard rather than migrate — it rebuilds from the next capture.
@Test func aHighWaterFileWithoutAVersionIsDiscarded() throws {
    let directory = highWaterScratch()
    let legacy = #"{"sevenDay":{"resetsAt":9000,"usedPercent":69,"capturedAt":1000}}"#
    try Data(legacy.utf8).write(to: directory.appendingPathComponent("rate-limit-highwater.json"))

    #expect(HighWaterStore(directory: directory).load() == .empty)
}

@Test func anIncompatibleHighWaterVersionIsDiscarded() throws {
    let directory = highWaterScratch()
    let future = #"{"version":99,"sevenDay":{"resetsAt":9000,"usedPercent":69,"capturedAt":1000}}"#
    try Data(future.utf8).write(to: directory.appendingPathComponent("rate-limit-highwater.json"))

    #expect(HighWaterStore(directory: directory).load() == .empty)
}

/// A v1 mark has no provenAt and no regrant. Loading one would present a
/// pre-versioning claim as a proven date. Discard, never migrate — the same
/// rule ScanCache uses.
///
/// ⚠️ POSITIVE CONTROL: the v1 fixture carries 99%, a value that would be
/// glaringly visible if it were migrated rather than dropped. Without a
/// distinctive value, "discarded" and "loaded but equal" look identical.
@Test func aVersionOneHighWaterFileIsDiscardedNotMigrated() throws {
    let dir = highWaterScratch()
    let legacy = #"{"version":1,"sevenDay":{"resetsAt":1,"usedPercent":99,"capturedAt":1}}"#
    try Data(legacy.utf8).write(to: dir.appendingPathComponent("rate-limit-highwater.json"))

    let loaded = HighWaterStore(directory: dir).load()

    #expect(loaded.sevenDay == nil, "a v1 mark must not survive")
    #expect(loaded.sevenDay?.usedPercent != 99, "99 would prove it was migrated")
}

@Test func highWaterRoundTripsAtTheCurrentVersion() throws {
    let directory = highWaterScratch()
    let store = HighWaterStore(directory: directory)
    let mark = RateLimitHighWater(
        sevenDay: .init(resetsAt: 9_000, usedPercent: 69, capturedAt: 1_000))

    try store.save(mark)
    #expect(store.load() == mark)
    #expect(store.load().version == RateLimitHighWater.currentVersion)
}

// MARK: - Sub-second disagreement between sources

/// ⚠️ Found against real data 2026-08-12. The statusline reports `resets_at` as
/// whole epoch seconds (`1786690800`); `cachedUsageUtilization` reports the same
/// instant as `2026-08-14T06:59:59.424563+00:00` — 0.58s earlier. Exact equality
/// treats those as two different windows, so each source would keep its own mark
/// and the stale-session protection would silently degrade whenever the two
/// alternate. Windows are hours or days apart; a tolerance costs nothing.
@Test func twoSourcesReportingTheSameWindowSubSecondApartShareAMark() {
    let fromStatusline = capture(75, at: 5_000, resetsAt: 1_786_690_800)
    let (_, mark) = RateLimitHighWater.reconcile(fromStatusline, against: .empty)

    let fromUtilization = capture(70, at: 9_000, resetsAt: 1_786_690_799.424563)
    let (result, _) = RateLimitHighWater.reconcile(fromUtilization, against: mark)

    // Same window, lower reading -> rejected as stale, not adopted as a new one.
    #expect(result.sevenDay.usedPercent == 75)
}

/// The counterweight: a genuinely different window must still start clean, or
/// last week's high would pin this one forever. Five-hour windows are the
/// tightest real spacing at five hours apart.
@Test func windowsFarApartStillGetSeparateMarks() {
    let earlier = capture(90, at: 5_000, resetsAt: 1_786_690_800)
    let (_, mark) = RateLimitHighWater.reconcile(earlier, against: .empty)

    let fiveHoursLater = capture(10, at: 9_000, resetsAt: 1_786_690_800 + 18_000)
    let (result, _) = RateLimitHighWater.reconcile(fiveHoursLater, against: mark)

    #expect(result.sevenDay.usedPercent == 10)
}
