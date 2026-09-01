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
                    provenAt: TimeInterval,
                    fiveHour: RateLimitCapture.Reading? = nil) -> RateLimitCapture {
    var c = capture(percent, at: t, fiveHour: fiveHour); c.provenAt = provenAt; return c
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

/// The 2026-09-01 event: Anthropic re-issued the allowance mid-window and the
/// app rejected the truth as a stale session — a rejection that would have
/// stood for three days, to the end of the window, had it not been caught the
/// same day.
///
/// The MARK coming down is load-bearing, not just the returned reading:
/// `WindowLedger` reads the reconciled value to spot the drop, and an
/// implementation that demotes one without the other looks correct for exactly
/// one rebuild.
@Test func aProvenLaterLowerReadingDemotesTheMark() {
    let (_, mark) = RateLimitHighWater.reconcile(proven(51, at: 1_000, provenAt: 1_000),
                                                 against: .empty)
    let (result, after) = RateLimitHighWater.reconcile(proven(0, at: 2_000, provenAt: 2_000),
                                                       against: mark)
    #expect(result.sevenDay.usedPercent == 0)
    #expect(after.sevenDay?.usedPercent == 0)
    #expect(after.sevenDay?.provenAt == 2_000)
    #expect(after.sevenDay?.capturedAt == 2_000)
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

/// The boundary, and it is not academic: `mintedAt` and `fetchedAtMs` are real
/// instants that can coincide at second scale. A proof no LATER than the mark's
/// evidence says nothing about which came first, so `>=` here would demote on a
/// coin toss.
@Test func aProofMintedAtExactlyTheBasisDoesNotDemote() {
    let (_, mark) = RateLimitHighWater.reconcile(proven(51, at: 1_000, provenAt: 1_000),
                                                 against: .empty)
    let (result, after) = RateLimitHighWater.reconcile(proven(0, at: 2_000, provenAt: 1_000),
                                                       against: mark)
    #expect(result.sevenDay.usedPercent == 51)
    #expect(after.sevenDay?.usedPercent == 51)
}

/// The positive half of the reconfirmation rule.
/// `anUndatedReconfirmationDoesNotAdvanceTheProvenDate` pins the freeze; on its
/// own it is also satisfied by a `provenAt` that never advances at all, which
/// leaves the demotion basis frozen at the first proof forever.
@Test func aProvenReconfirmationDoesAdvanceTheProvenDate() {
    let (_, mark) = RateLimitHighWater.reconcile(proven(51, at: 1_000, provenAt: 1_000),
                                                 against: .empty)
    let (_, after) = RateLimitHighWater.reconcile(proven(51, at: 3_000, provenAt: 3_000),
                                                  against: mark)
    #expect(after.sevenDay?.provenAt == 3_000)
}

/// `provenAt` is evidence about the value the mark HOLDS. A higher reading
/// replaces that value, so it brings its own evidence — none at all, here.
/// Merging the mark's older proof forward instead would block a genuinely newer
/// proof using evidence about a value no longer held. The reading is
/// deliberately older than the mark: that is the case
/// `aHigherReadingKeepsItsOwnDateEvenWhenOlderThanTheMark` pins for
/// `capturedAt`, and the one where the two rules visibly differ.
@Test func aHigherReadingBringsItsOwnEvidenceRatherThanInheritingTheMarks() {
    let (_, mark) = RateLimitHighWater.reconcile(proven(51, at: 1_000, provenAt: 1_000),
                                                 against: .empty)
    let (_, after) = RateLimitHighWater.reconcile(capture(60, at: 500), against: mark)

    #expect(after.sevenDay?.usedPercent == 60, "the higher branch ran")
    #expect(after.sevenDay?.provenAt == nil)
}

/// A proven confirmation can move the basis DOWN — from `capturedAt`, an
/// inferred upper bound, to the earlier instant actually proven. That is
/// acceptable because it is order-independent: the mark does not depend on
/// which session's writer happened to land first. Clamping the proof up to the
/// inferred bound would buy conservatism with a fabricated date AND lose this.
@Test func aProvenAndAnUndatedConfirmationCommute() {
    func fold(_ captures: [RateLimitCapture]) -> RateLimitHighWater {
        captures.reduce(RateLimitHighWater.empty) {
            RateLimitHighWater.reconcile($1, against: $0).highWater
        }
    }
    let provenReading = proven(51, at: 3_000, provenAt: 3_000)
    let undated = capture(51, at: 5_000)

    let provenFirst = fold([provenReading, undated])
    let undatedFirst = fold([undated, provenReading])

    #expect(provenFirst.sevenDay == undatedFirst.sevenDay)
    #expect(provenFirst.sevenDay?.capturedAt == 5_000)
    #expect(provenFirst.sevenDay?.provenAt == 3_000)
}

// MARK: - An open re-grant survives every branch

// `Mark.regrant` stays nil until an epoch is opened on a material drop, so
// dropping it inside `best()` breaks nothing today and breaks the epoch feature
// later — invisibly to that feature's own tests, which never reach this file.
// One test per branch that rebuilds a mark from an existing one, each also
// asserting the branch it targets actually ran.

private let openRegrant = RateLimitHighWater.Regrant(startedAt: 2_000, startPercent: 0)

private func markInARegrant(_ percent: Double, capturedAt: TimeInterval,
                            provenAt: TimeInterval? = nil) -> RateLimitHighWater {
    RateLimitHighWater(sevenDay: .init(resetsAt: reset, usedPercent: percent,
                                       capturedAt: capturedAt, provenAt: provenAt,
                                       regrant: openRegrant))
}

@Test func aHigherReadingKeepsAnOpenRegrant() {
    let (_, after) = RateLimitHighWater.reconcile(capture(9, at: 3_000),
                                                  against: markInARegrant(4, capturedAt: 2_500))
    #expect(after.sevenDay?.usedPercent == 9, "the higher branch ran")
    #expect(after.sevenDay?.regrant == openRegrant)
}

@Test func anEqualReadingKeepsAnOpenRegrant() {
    let (_, after) = RateLimitHighWater.reconcile(capture(4, at: 3_000),
                                                  against: markInARegrant(4, capturedAt: 2_500))
    #expect(after.sevenDay?.capturedAt == 3_000, "the equal branch ran")
    #expect(after.sevenDay?.regrant == openRegrant)
}

/// ⚠️ FIXTURE CORRECTED when Task 5 landed; the assertion is untouched. The
/// drop must be SUB-MATERIAL (4 → 3, one point). It was written as 4 → 1 when
/// nothing could open an epoch yet, which made the size of the drop arbitrary —
/// and Task 5 then turned that arbitrary 3-point gap into a material one, where
/// carrying the old epoch forward is the WRONG behaviour. A material drop
/// inside an open epoch legitimately re-bases it; see
/// `aMaterialDropInsideAnOpenEpochRebasesIt`. Do not "restore" 4 → 1: the two
/// tests would then pin contradictory rules and this one would lose the
/// carry-forward coverage it exists for.
@Test func aDemotionInsideARegrantKeepsIt() {
    let (_, after) = RateLimitHighWater.reconcile(
        proven(3, at: 3_000, provenAt: 3_000),
        against: markInARegrant(4, capturedAt: 2_500, provenAt: 2_500))
    #expect(after.sevenDay?.usedPercent == 3, "the demotion branch ran")
    #expect(after.sevenDay?.regrant == openRegrant)
}

@Test func aRejectedLowerReadingKeepsAnOpenRegrant() {
    let (_, after) = RateLimitHighWater.reconcile(capture(1, at: 3_000),
                                                  against: markInARegrant(4, capturedAt: 2_500))
    #expect(after.sevenDay?.usedPercent == 4, "the lower reading was rejected")
    #expect(after.sevenDay?.regrant == openRegrant)
}

// MARK: - A material drop opens an allowance epoch

/// The mark reconciled from a single proven 51% reading — the state the
/// 2026-09-01 event dropped from.
private func markAt51() -> RateLimitHighWater {
    RateLimitHighWater.reconcile(proven(51, at: 1_000, provenAt: 1_000), against: .empty).highWater
}

/// A 51 -> 50 flicker between two sources rounding differently is not a
/// re-grant, and opening an epoch for it corrupts the extrapolation
/// denominator. The value is still accepted; only the epoch is withheld.
@Test func aSubMaterialDropIsAcceptedButOpensNoEpoch() {
    let (result, after) = RateLimitHighWater.reconcile(proven(50, at: 2_000, provenAt: 2_000),
                                                       against: markAt51())
    #expect(result.sevenDay.usedPercent == 50, "the mark stops lying")
    #expect(after.sevenDay?.usedPercent == 50, "and the MARK itself comes down")
    #expect(after.sevenDay?.regrant == nil, "but no epoch opens")
}

/// BOUNDARY-EXACT, so a `>=` mutated to `>` dies here. Exactly 2 points.
@Test func aTwoPointDropOpensAnEpoch() {
    let (_, after) = RateLimitHighWater.reconcile(proven(49, at: 2_000, provenAt: 2_000),
                                                  against: markAt51())
    #expect(after.sevenDay?.regrant?.startPercent == 49)
    #expect(after.sevenDay?.regrant?.startedAt == 2_000, "the OPENING READING's provenAt")
}

/// 🔴 Pins the rule the spec states in prose. Every other fixture here has
/// capturedAt == provenAt, so `startedAt == 2_000` cannot tell the two apart —
/// it only rules out a `Date()` implementation. Split them and the rule becomes
/// testable.
@Test func theEpochStartsAtTheOpeningReadingsProvenDateNotItsCapturedAt() {
    let (_, after) = RateLimitHighWater.reconcile(proven(49, at: 2_500, provenAt: 2_400),
                                                  against: markAt51())
    #expect(after.sevenDay?.regrant?.startedAt == 2_400, "provenAt, not capturedAt (2_500)")
}

/// THE FLAGSHIP CASE. A re-grant to 0% is indistinguishable from a window-start
/// epoch by percentage alone — this is why the optional is the discriminator. A
/// `startPercent > 0` implementation passes every other test in this file and
/// fails this one.
@Test func aRegrantToZeroOpensAnEpoch() {
    let (_, after) = RateLimitHighWater.reconcile(proven(0, at: 2_000, provenAt: 2_000),
                                                  against: markAt51())
    #expect(after.sevenDay?.regrant != nil)
    #expect(after.sevenDay?.regrant?.startPercent == 0)
}

/// Five-hour readings share the `Mark` type and share nothing else. No
/// five-hour figure is ever extrapolated, so there is nothing for an epoch to
/// re-base — and a populated field there would be read by consumers that only
/// ever mean the weekly one.
@Test func aFiveHourDropNeverOpensAnEpoch() {
    let fiveReset: TimeInterval = 1_786_491_600
    let (_, mark) = RateLimitHighWater.reconcile(
        proven(51, at: 1_000, provenAt: 1_000,
               fiveHour: .init(usedPercent: 30, resetsAt: fiveReset)),
        against: .empty)
    let (_, after) = RateLimitHighWater.reconcile(
        proven(51, at: 2_000, provenAt: 2_000,
               fiveHour: .init(usedPercent: 10, resetsAt: fiveReset)),
        against: mark)
    #expect(after.fiveHour?.usedPercent == 10, "the drop was material, and accepted")
    #expect(after.fiveHour?.regrant == nil)
}

/// The demotion rule applies to five_hour too; only the epoch machinery is
/// withheld.
///
/// ⚠️ Narrow on purpose. The MARK side is already covered by
/// `aFiveHourDropNeverOpensAnEpoch`'s first assertion — every mutation that
/// breaks one breaks the other — so this asserts only the RETURNED CAPTURE,
/// which is what `UsageStore` emits and what the popover's five-hour row
/// reads. The two can diverge: the rejection branch hands back a reading
/// rebuilt from the mark while the demotion branch hands back the incoming
/// one, so "lowers the mark but keeps serving the old reading" is one edit
/// away, and it would show a stale five-hour figure indefinitely.
///
/// Being straight about its strength: `best()` is shared, so breaking that
/// branch today also fails `aProvenLaterLowerReadingDemotesTheMark`, and
/// breaking the five-hour assembly in `reconcile` fails
/// `theFiveHourReadingIsReconciledIndependently`. Both verified by mutation.
/// No mutation kills this test alone. It is a regression guard for the
/// five-hour path specifically, not uniquely-killable coverage — kept because
/// the five-hour reading reaches the capture through its own `best()` call
/// and its own assembly, and nothing else asserts the result of that pair.
@Test func aFiveHourMarkStillDemotesOnProvenEvidence() {
    let fiveReset: TimeInterval = 1_786_491_600
    let (_, mark) = RateLimitHighWater.reconcile(
        proven(51, at: 1_000, provenAt: 1_000,
               fiveHour: .init(usedPercent: 30, resetsAt: fiveReset)),
        against: .empty)
    let (result, _) = RateLimitHighWater.reconcile(
        proven(51, at: 2_000, provenAt: 2_000,
               fiveHour: .init(usedPercent: 4, resetsAt: fiveReset)),
        against: mark)
    #expect(result.fiveHour?.usedPercent == 4, "the RETURNED capture, not the mark")
}

/// A re-grant ends an epoch exactly as a window reset does, so a second one
/// inside an open epoch must RE-BASE rather than be swallowed. Carry the first
/// epoch forward and `unitsAtEpochStart` stays stale by the whole first epoch's
/// consumption — the same denominator error this feature exists to fix, just
/// relocated.
///
/// 🔴 `startPercent` goes 0 → 0 here, so it discriminates nothing: `startedAt`
/// is the only field that can show the re-base happened. Same lesson as the
/// flagship case, one level down.
@Test func aMaterialDropInsideAnOpenEpochRebasesIt() {
    let (_, after) = RateLimitHighWater.reconcile(
        proven(0, at: 5_500, provenAt: 5_000),
        against: markInARegrant(20, capturedAt: 2_500, provenAt: 2_500))
    #expect(after.sevenDay?.usedPercent == 0, "the demotion branch ran")
    #expect(after.sevenDay?.regrant?.startedAt == 5_000,
            "re-based to the new opening reading's provenAt, not capturedAt (5_500)")
    #expect(after.sevenDay?.regrant?.startPercent == 0)
    #expect(after.sevenDay?.provenAt == 5_000,
            "the mark's proof moves with the epoch it now describes")
}

/// 🔴 Every branch of the real `best()` builds a FRESH `Mark(...)`. Mirror that
/// structure naively and `regrant` is dropped by the very next capture — which
/// in the flagship case (re-grant to 0%, usage back to 3% within minutes)
/// closes the epoch almost immediately. Extrapolation, projection, eligibility
/// and notification identity all silently revert to the window.
///
/// The sibling `aHigherReadingKeepsAnOpenRegrant` pins the same branch from a
/// directly-constructed mark; this one opens the epoch through `reconcile`, so
/// it also covers a carry that is correct only for a hand-built `Regrant`.
@Test func anOpenEpochSurvivesASubsequentHigherReading() {
    let (_, opened) = RateLimitHighWater.reconcile(proven(0, at: 2_000, provenAt: 2_000),
                                                   against: markAt51())
    let (_, after) = RateLimitHighWater.reconcile(proven(3, at: 3_000, provenAt: 3_000),
                                                  against: opened)
    #expect(after.sevenDay?.regrant?.startedAt == 2_000)
    #expect(after.sevenDay?.regrant?.startPercent == 0)
    #expect(after.sevenDay?.usedPercent == 3, "the high-water still tracks upward")
}

/// Same trap, same cause: `provenAt` must not be dropped either, or the
/// demotion basis silently falls back to `capturedAt`.
///
/// ⚠️ The confirming reading must be UNDATED. With a proven confirm, a dropped
/// provenAt re-set from the incoming date is indistinguishable from a correct
/// carry — the test could not fail. It would also contradict Task 4's rule that
/// a proven confirmation legitimately ADVANCES provenAt.
@Test func anUndatedEqualReadingPreservesTheEpochsProvenDate() {
    let (_, opened) = RateLimitHighWater.reconcile(proven(0, at: 2_000, provenAt: 2_000),
                                                   against: markAt51())
    let (_, after) = RateLimitHighWater.reconcile(capture(0, at: 8_000), against: opened)
    #expect(after.sevenDay?.provenAt == 2_000)
    #expect(after.sevenDay?.regrant?.startedAt == 2_000)
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
