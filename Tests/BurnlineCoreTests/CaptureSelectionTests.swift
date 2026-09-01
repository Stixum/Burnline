import Testing
import Foundation
@testable import BurnlineCore

// Selection runs BEFORE reconciliation — `UsageStore` loads every candidate,
// picks one, and only then hands it to `RateLimitHighWater`. So a candidate that
// cannot possibly postdate an open re-grant must be excluded here, upstream,
// where the choosing happens. `reconcile` sees one capture and cannot defend
// against a field it never gets shown.
//
// Two failures follow from the ordering, and the eligibility rule is the only
// defence against either:
//
// 1. **Pre-epoch.** An undated writer through the shared `rate-limits.json` — an
//    older build, the rollback script, a payload with no `session_id` — is
//    stamped `Date()` and is invisible to `correctedForRepublishing` under five
//    hours. Its `capturedAt` tracks *now*, so it out-freshens a proven-but-frozen
//    `fetchedAtMs` at selection and the proven reading never reaches `best()`.
// 2. **Post-epoch.** Once an epoch is open, an idle session replaying the
//    pre-re-grant percentage enters `best()`'s HIGHER branch, which carries no
//    proof requirement at all, and is accepted. The mark goes back to the frozen
//    figure with the epoch still open underneath it.

private let windowReset: TimeInterval = 1_786_690_800

private func capture(_ percent: Double, at captured: TimeInterval) -> RateLimitCapture {
    RateLimitCapture(version: RateLimitCapture.currentVersion, capturedAt: captured,
                     sevenDay: .init(usedPercent: percent, resetsAt: windowReset),
                     fiveHour: nil)
}

private func proven(_ percent: Double, at captured: TimeInterval,
                    provenAt: TimeInterval) -> RateLimitCapture {
    var c = capture(percent, at: captured)
    c.provenAt = provenAt
    return c
}

private func markWithRegrant(startedAt: TimeInterval, startPercent: Double,
                             usedPercent: Double = 51,
                             fiveHour: RateLimitHighWater.Mark? = nil) -> RateLimitHighWater {
    RateLimitHighWater(
        sevenDay: .init(resetsAt: windowReset, usedPercent: usedPercent,
                        capturedAt: startedAt, provenAt: startedAt,
                        regrant: .init(startedAt: startedAt, startPercent: startPercent)),
        fiveHour: fiveHour)
}

private func markWithoutRegrant(usedPercent: Double = 51) -> RateLimitHighWater {
    RateLimitHighWater(sevenDay: .init(resetsAt: windowReset, usedPercent: usedPercent,
                                       capturedAt: 1_000, provenAt: 1_000))
}

// MARK: - Eligibility

/// The pre-epoch failure. `capturedAt` on an undated writer tracks wall-clock,
/// so it beats a proven reading on freshness while carrying no evidence at all.
@Test func anUndatedCandidateIsIneligibleOnceAnEpochIsOpen() {
    let mark = markWithRegrant(startedAt: 1_000, startPercent: 0)
    let stale = capture(51, at: 9_999)                       // undated, looks fresh
    let truth = proven(3, at: 1_500, provenAt: 1_500)

    let picked = CaptureSelection.select([stale, truth], mark: mark)

    #expect(picked?.sevenDay.usedPercent == 3)
}

/// The post-epoch failure, and the reason the test is on `provenAt` and not on
/// its presence: this replay IS proven — proven to predate the re-grant. Reaching
/// `best()` it would take the higher branch, which asks for no proof, and restore
/// the frozen figure inside an open epoch.
@Test func aProvenlyPreRegrantReplayIsAlsoIneligible() {
    let mark = markWithRegrant(startedAt: 2_000, startPercent: 0, usedPercent: 3)
    let replay = proven(51, at: 9_999, provenAt: 1_000)      // minted before the re-grant

    let picked = CaptureSelection.select([replay], mark: mark)

    #expect(picked?.sevenDay.usedPercent == 3, "the mark stood in; the replay was refused")
}

/// 🔴 `>=`, not `>`. The epoch is dated by the `provenAt` of the very reading
/// that opened it, so a strict comparison makes that reading instantly
/// ineligible — the app would refuse the one capture that told it the truth.
@Test func theOpeningCaptureOfAnEpochRemainsEligible() {
    let mark = markWithRegrant(startedAt: 2_000, startPercent: 0, usedPercent: 7)
    let opening = proven(0, at: 2_000, provenAt: 2_000)

    let picked = CaptureSelection.select([opening], mark: mark)

    #expect(picked?.sevenDay.usedPercent == 0)
}

// MARK: - The stand-in

/// 🔴 Falling through to nil reverts the window to the Thursday 09:00 schedule
/// placeholder and drops the source to pace-only — a worse regression than the
/// bug being fixed.
@Test func theMarkStandsInWhenEveryCandidateIsIneligible() {
    let mark = markWithRegrant(startedAt: 1_000, startPercent: 0, usedPercent: 7)

    let picked = CaptureSelection.select([capture(51, at: 9_999)], mark: mark)

    #expect(picked?.sevenDay.usedPercent == 7)
    #expect(picked != nil, "must never be nil while a mark exists")
}

/// Eligibility excludes a whole candidate, and the five-hour reading rides along
/// inside it. Without this the popover's five-hour row blinks out for a reason
/// that has nothing to do with the five-hour window.
@Test func theStandInKeepsTheFiveHourReading() {
    let fiveHour = RateLimitHighWater.Mark(resetsAt: 1_786_700_000, usedPercent: 42,
                                           capturedAt: 1_000)
    let mark = markWithRegrant(startedAt: 1_000, startPercent: 0, usedPercent: 7,
                               fiveHour: fiveHour)

    let picked = CaptureSelection.select([capture(51, at: 9_999)], mark: mark)

    #expect(picked?.fiveHour != nil)
    #expect(picked?.fiveHour?.usedPercent == 42)
    #expect(picked?.fiveHour?.resetsAt == 1_786_700_000)
}

/// The stand-in is a reading that already happened, not one that just landed.
/// Stamping it with `Date()` — or with the ineligible candidate's timestamp —
/// would present an old figure as live and suppress the staleness warning that
/// is the user's only clue.
@Test func theStandInDoesNotFabricateFreshness() {
    let mark = markWithRegrant(startedAt: 1_000, startPercent: 0, usedPercent: 7)

    let picked = CaptureSelection.select([capture(51, at: 9_999)], mark: mark)

    #expect(picked?.capturedAt == 1_000)
    #expect(picked?.provenAt == 1_000)
}

@Test func selectingNothingWithNoMarkIsStillNothing() {
    #expect(CaptureSelection.select([], mark: .empty) == nil)
}

// MARK: - Before any epoch

/// Before any epoch exists, selection is unchanged — otherwise a machine that
/// has never seen a re-grant loses its statusline captures, which carry no
/// `provenAt` unless a transcript happened to date them.
@Test func selectionIsUnchangedWhileNoEpochIsOpen() {
    let mark = markWithoutRegrant()
    let picked = CaptureSelection.select([capture(51, at: 9_999),
                                          proven(3, at: 1_500, provenAt: 1_500)], mark: mark)
    #expect(picked?.sevenDay.usedPercent == 51)
}

// MARK: - The tie-break

/// Same falsified axiom, second location: `freshest` used to break a tie on the
/// larger figure, on the reasoning that cumulative usage makes it the later one.
/// A re-grant makes the smaller figure the later one instead.
@Test func freshestNoLongerPrefersTheHigherPercentageAtEqualTimestamps() {
    let low = proven(10, at: 5_000, provenAt: 5_000)
    let high = capture(90, at: 5_000)

    #expect(CaptureDirectory.freshest(of: [high, low])?.sevenDay.usedPercent == 10,
            "proven beats magnitude at an equal instant")
}
