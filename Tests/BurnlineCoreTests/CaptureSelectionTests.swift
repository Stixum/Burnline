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

/// ⚠️ `capturedAt` and `provenAt` default to `startedAt` only because most tests
/// have no reason to separate them. They are three same-typed fields and an
/// implementation can confuse them silently, so
/// `theBarIsTheEpochStartNotTheMarksOwnDate` splits all three.
private func markWithRegrant(startedAt: TimeInterval, startPercent: Double,
                             usedPercent: Double = 51,
                             capturedAt: TimeInterval? = nil,
                             provenAt: TimeInterval? = nil,
                             fiveHour: RateLimitHighWater.Mark? = nil) -> RateLimitHighWater {
    RateLimitHighWater(
        sevenDay: .init(resetsAt: windowReset, usedPercent: usedPercent,
                        capturedAt: capturedAt ?? startedAt,
                        provenAt: provenAt ?? startedAt,
                        regrant: .init(startedAt: startedAt, startPercent: startPercent)),
        fiveHour: fiveHour)
}

private func capture(_ percent: Double, at captured: TimeInterval,
                     resetsAt: TimeInterval) -> RateLimitCapture {
    RateLimitCapture(version: RateLimitCapture.currentVersion, capturedAt: captured,
                     sevenDay: .init(usedPercent: percent, resetsAt: resetsAt),
                     fiveHour: nil)
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

/// 🔴 `regrant.startedAt` is fixed for the life of the epoch; the mark's own
/// `capturedAt` and `provenAt` advance on every equal-or-higher confirmation.
/// Comparing against either of those same-typed siblings compiles silently and
/// ratchets the bar up behind the readings that must clear it — here, a genuine
/// post-re-grant reading proven at 3_000 would be refused by a mark that has
/// since re-confirmed at 5_000. Every other fixture in this file sets all three
/// to one value and cannot see the difference.
@Test func theBarIsTheEpochStartNotTheMarksOwnDate() {
    let mark = markWithRegrant(startedAt: 1_000, startPercent: 0, usedPercent: 7,
                               capturedAt: 5_000, provenAt: 5_000)
    let later = proven(20, at: 3_000, provenAt: 3_000)

    let picked = CaptureSelection.select([later], mark: mark)

    #expect(picked?.sevenDay.usedPercent == 20)
}

/// An epoch belongs to one window, and the rule exists to refuse replays of
/// *that* window's pre-re-grant reading. A capture describing a different window
/// cannot be one — so refusing it would discard live information and pin the app
/// to the stand-in, which is the dead window's mark. On an all-undated machine
/// nothing would ever clear the bar again.
///
/// ⚠️ The comparison carries `sameWindowTolerance` because two sources spell the
/// same boundary 0.58s apart. That is a fact about window identity, and the
/// reason the same slack would be wrong on `provenAt`.
@Test func aCandidateFromAnotherWindowIsNotJudgedByThisEpoch() {
    let mark = markWithRegrant(startedAt: 1_000, startPercent: 0, usedPercent: 7)
    let nextWindow = capture(4, at: 9_999, resetsAt: windowReset + 7 * 86_400)

    let picked = CaptureSelection.select([nextWindow], mark: mark)

    #expect(picked?.sevenDay.usedPercent == 4, "undated, but it cannot be a replay of this epoch")
}

/// The converse, so the tolerance is not a hole: the two sources' spellings of
/// one boundary are still the same window, and a replay inside it is still
/// refused.
@Test func aSubSecondDifferenceInTheResetInstantIsStillThisWindow() {
    let mark = markWithRegrant(startedAt: 2_000, startPercent: 0, usedPercent: 3)
    let replay = capture(51, at: 9_999, resetsAt: windowReset - 0.58)

    let picked = CaptureSelection.select([replay], mark: mark)

    #expect(picked?.sevenDay.usedPercent == 3, "the mark stood in; the replay was refused")
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
    // 🔴 The window boundary is the whole point of the stand-in: `resetsAt` is
    // what stops `SnapshotBuilder` reverting to the Thursday 09:00 schedule
    // placeholder. Zeroing it survived every other assertion here.
    #expect(picked?.sevenDay.resetsAt == windowReset)
}

@Test func selectingNothingWithNoMarkIsStillNothing() {
    #expect(CaptureSelection.select([], mark: .empty) == nil)
}

// MARK: - Before any epoch

/// Before any epoch exists, selection is unchanged — otherwise a machine that
/// has never seen a re-grant loses its statusline captures, which carry no
/// `provenAt` unless a transcript happened to date them.
@Test func selectionIsUnchangedWhileNoEpochIsOpen() {
    // ⚠️ The mark holds a percentage matching NEITHER candidate, and the age is
    // asserted too. An earlier version of this test defaulted the mark to 51 —
    // the same figure as the expected winner — so deleting the no-epoch guard
    // outright still passed: the stand-in returned the number being asserted.
    // A fixture that shares a value with the expectation cannot distinguish the
    // implementation from its failure mode.
    let mark = markWithoutRegrant(usedPercent: 33)
    let picked = CaptureSelection.select([capture(51, at: 9_999),
                                          proven(3, at: 1_500, provenAt: 1_500)], mark: mark)
    #expect(picked?.sevenDay.usedPercent == 51)
    #expect(picked?.capturedAt == 9_999, "the candidate itself, not the mark standing in")
}

/// The trade this unit accepts, pinned here rather than left in the plan: with
/// nothing on disk the mark stands in even though no epoch is open, where
/// `freshest` alone returned nil. `SnapshotBuilder` handles a dead-window mark
/// safely — `capturedDate < window.start` drops the source to calibrated or
/// pace-only — and the window it rolls forward beats the Thursday 09:00
/// placeholder that nil produces.
@Test func theMarkStandsInWithNoEpochWhenNothingIsOnDisk() {
    #expect(CaptureSelection.select([], mark: markWithoutRegrant(usedPercent: 33))?
        .sevenDay.usedPercent == 33)
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

// MARK: - Resolution: selection, then reconciliation, then reporting

// 🔴 `UsageStore` is an executable target with no test target of its own, so a
// composition written inline there is unverifiable — and the ORDER of these
// three steps is the entire point of the feature. `resolve` is that composition,
// lifted into `BurnlineCore` where the ordering can be pinned.

private func replay(_ percent: Double, at captured: TimeInterval,
                    provenAt: TimeInterval) -> RateLimitCapture {
    proven(percent, at: captured, provenAt: provenAt)
}

/// 🔴 Constraint A, pinned. Filtering must happen BEFORE `reconcile`, never
/// after: a proven-but-pre-re-grant replay arriving at `best()` takes the
/// *higher* branch, which carries no proof requirement at all, and is simply
/// accepted — restoring the frozen 51% with the epoch still open underneath it.
///
/// Reconcile the unfiltered freshest here and the mark comes back 51.
@Test func theEpochFilterRunsBeforeReconciliationNotAfter() {
    let mark = markWithRegrant(startedAt: 2_000, startPercent: 0, usedPercent: 7)
    let stale = replay(51, at: 9_999, provenAt: 1_000)

    let resolution = CaptureSelection.resolve([stale], against: mark)

    #expect(resolution.trusted?.sevenDay.usedPercent == 7)
    #expect(resolution.highWater.sevenDay?.usedPercent == 7,
            "the refused replay must never reach best()'s higher branch")
    #expect(resolution.highWater.sevenDay?.regrant != nil, "the epoch is still open")
}

/// 🔴 Constraint B, pinned. The refusal is exactly the moment the app disagrees
/// with the user's own terminal, so it is exactly the moment the row has to
/// fire. Computing the rejection from the SELECTED capture makes both sides the
/// same object and yields nil — the "looks like a broken app" failure the row
/// was built for, reintroduced by its own fix.
@Test func aReadingRefusedByTheEpochFilterIsStillReportedAsARejection() {
    let mark = markWithRegrant(startedAt: 1_000, startPercent: 0, usedPercent: 7)
    let stale = capture(51, at: 9_999)                  // undated: what the terminal shows
    let truth = proven(7, at: 1_500, provenAt: 1_500)

    let resolution = CaptureSelection.resolve([stale, truth], against: mark)

    #expect(resolution.trusted?.sevenDay.usedPercent == 7)
    #expect(resolution.rejected?.reportedPercent == 51)
    #expect(resolution.rejected?.usingPercent == 7)
}

/// The same, through the stand-in rather than a surviving candidate: nothing on
/// disk is eligible, so what the app shows was never in a file at all. `onDisk`
/// still has to name the file's figure.
@Test func theStandInStillReportsWhatTheFileSaid() {
    let mark = markWithRegrant(startedAt: 1_000, startPercent: 0, usedPercent: 7)

    let resolution = CaptureSelection.resolve([capture(51, at: 9_999)], against: mark)

    #expect(resolution.onDisk?.sevenDay.usedPercent == 51)
    #expect(resolution.trusted?.sevenDay.usedPercent == 7)
    #expect(resolution.rejected?.rowValue == "said 51%, kept 7%")
}

/// The pre-existing stale-session case, unchanged: no epoch, a lower reading on
/// disk, the mark holds the higher figure. This is the direction the row has
/// always reported and it must keep reporting it.
@Test func theOrdinaryStaleSessionRejectionSurvivesTheNewComposition() {
    let mark = markWithoutRegrant(usedPercent: 74)
    let resolution = CaptureSelection.resolve([capture(69, at: 2_000)], against: mark)

    #expect(resolution.trusted?.sevenDay.usedPercent == 74)
    #expect(resolution.rejected?.reportedPercent == 69)
    #expect(resolution.rejected?.usingPercent == 74)
}

/// Agreement is the overwhelmingly common case and must stay silent — the row
/// is exceptions-only, per the portfolio status-chip standard.
@Test func agreementBetweenDiskAndMarkReportsNothing() {
    let resolution = CaptureSelection.resolve([capture(51, at: 9_999)],
                                              against: markWithoutRegrant(usedPercent: 51))
    #expect(resolution.rejected == nil)
}

/// 🔴 Constraint C, pinned at the composition level: with nothing on disk the
/// mark still stands in, so the window boundary survives — but there is no file
/// to disagree with, so nothing is reported as rejected. Reporting one here
/// would accuse a file that does not exist.
@Test func aStandInWithNothingOnDiskKeepsTheWindowAndAccusesNobody() {
    let mark = markWithRegrant(startedAt: 1_000, startPercent: 0, usedPercent: 7)
    let resolution = CaptureSelection.resolve([], against: mark)

    #expect(resolution.onDisk == nil)
    #expect(resolution.rejected == nil)
    #expect(resolution.trusted?.sevenDay.usedPercent == 7)
    #expect(resolution.trusted?.sevenDay.resetsAt == windowReset,
            "the window boundary is what the stand-in exists to preserve")
}

/// No mark and no files: nothing to resolve, and the caller must not be handed
/// a mark to persist that it did not have before.
@Test func resolvingNothingAtAllChangesNothing() {
    let resolution = CaptureSelection.resolve([], against: .empty)

    #expect(resolution.trusted == nil)
    #expect(resolution.onDisk == nil)
    #expect(resolution.rejected == nil)
    #expect(resolution.highWater == .empty)
}

/// The mark to persist comes back on the result, so the caller writes what this
/// unit decided rather than recomputing it.
@Test func resolveReturnsTheMarkToPersist() {
    let resolution = CaptureSelection.resolve([capture(51, at: 9_999)], against: .empty)

    #expect(resolution.highWater.sevenDay?.usedPercent == 51)
    #expect(resolution.highWater.sevenDay?.capturedAt == 9_999)
}

/// 🔴 The stand-in must NOT be reconciled, and this is the case that proves it.
///
/// `standIn` has one `capturedAt`/`provenAt` to give — the SEVEN-DAY mark's —
/// and it stamps them on a capture carrying both readings. Reconciled, the
/// five-hour reading equals its own mark, takes the equal-value branch, and has
/// its dates advanced to the seven-day's by `max(capturedAt, mark.capturedAt)`.
/// The two marks diverge routinely (a seven-day climb accepted while a lower
/// unproven five-hour reading was refused), and `UsageStore` persists any mark
/// that differs — so this writes a confirmation the five-hour reading never
/// earned, which is the class `best()` explicitly refuses for itself.
@Test func reconcilingTheStandInWouldFabricateAFiveHourConfirmation() {
    let mark = RateLimitHighWater(
        sevenDay: .init(resetsAt: windowReset, usedPercent: 51,
                        capturedAt: 3_000, provenAt: 3_000),
        fiveHour: .init(resetsAt: 1_786_700_000, usedPercent: 42,
                        capturedAt: 1_000, provenAt: 1_000))

    let resolution = CaptureSelection.resolve([], against: mark)

    #expect(resolution.highWater.fiveHour?.capturedAt == 1_000,
            "the five-hour reading was never re-confirmed at the seven-day's instant")
    #expect(resolution.highWater.fiveHour?.provenAt == 1_000)
    #expect(resolution.highWater == mark, "the stand-in IS the mark; nothing to reconcile")
    // Still the stand-in the app displays, five-hour block and all.
    #expect(resolution.trusted?.sevenDay.usedPercent == 51)
    #expect(resolution.trusted?.fiveHour?.usedPercent == 42)
}

/// The convenience accessor both call sites use instead of reaching through two
/// levels. `UsageStore` has no test target, so the spelling is pinned here.
@Test func theResolutionSurfacesTheOpenEpoch() {
    let mark = markWithRegrant(startedAt: 1_000, startPercent: 0, usedPercent: 7)

    #expect(CaptureSelection.resolve([], against: mark).regrant?.startedAt == 1_000)
    #expect(CaptureSelection.resolve([], against: .empty).regrant == nil)
}

// MARK: - Reporting the resolution

// 🔴 `BurnlineProbe` has no test target, so anything it works out for itself is
// unverifiable — and it is the tool this whole feature will be verified with
// against real data. The facts a reader needs (what was loaded, what was
// refused, which one won) are therefore decided HERE, by the same call the app
// makes, and the probe only formats them.
//
// The correlation is by POSITION and this is not a style preference. The probe
// used to find the winning source with `first { $0.sessionId == winner.sessionId
// }`; `sessionId` is nil on the shared `rate-limits.json`, nil on the
// `cachedUsageUtilization` capture and nil on the stand-in, so that matched the
// first nil-id candidate loaded and named the wrong file.

@Test func candidatesAreReportedInTheOrderTheyWereSupplied() {
    let a = capture(10, at: 1_000)
    let b = capture(20, at: 2_000)
    let c = capture(30, at: 3_000)

    let resolution = CaptureSelection.resolve([a, b, c], against: .empty)

    #expect(resolution.candidates.map(\.capture) == [a, b, c],
            "index-parallel to the input: correlation back to the source file depends on it")
}

@Test func everyCandidateIsEligibleWhileNoEpochIsOpen() {
    let resolution = CaptureSelection.resolve([capture(51, at: 9_999),
                                               proven(3, at: 1_500, provenAt: 1_500)],
                                              against: markWithoutRegrant(usedPercent: 33))

    #expect(resolution.candidates.map(\.isEligible) == [true, true])
    #expect(resolution.candidates.map(\.isSelected) == [true, false])
    #expect(resolution.candidates.map(\.isFreshestOnDisk) == [true, false])
}

/// The whole re-grant story in two flags, and the reason both exist: the
/// candidate the terminal is showing is the freshest thing on disk AND the one
/// selection refused. A report that only named the winner could not show that a
/// refusal had happened at all.
@Test func theRefusedReplayIsStillNamedAsTheFreshestOnDisk() {
    let mark = markWithRegrant(startedAt: 1_000, startPercent: 0, usedPercent: 7)
    let stale = capture(51, at: 9_999)                  // undated: what the terminal shows
    let truth = proven(7, at: 1_500, provenAt: 1_500)

    let resolution = CaptureSelection.resolve([stale, truth], against: mark)

    #expect(resolution.candidates.map(\.isEligible) == [false, true])
    #expect(resolution.candidates.map(\.isFreshestOnDisk) == [true, false])
    #expect(resolution.candidates.map(\.isSelected) == [false, true],
            "freshest on disk and not selected — the case the feature exists for")
}

/// The stand-in is not a candidate and must never be reported as one. Marking
/// anything selected here would have the probe name a file for a reading that
/// was never in one.
@Test func nothingIsSelectedWhenTheMarkStandsIn() {
    let mark = markWithRegrant(startedAt: 1_000, startPercent: 0, usedPercent: 7)

    let resolution = CaptureSelection.resolve([capture(51, at: 9_999)], against: mark)

    #expect(resolution.trusted?.sevenDay.usedPercent == 7, "the mark stood in")
    #expect(resolution.candidates.count == 1)
    #expect(resolution.candidates.map(\.isSelected) == [false])
    #expect(resolution.candidates[0].isFreshestOnDisk, "it is still what the file says")
}

/// `isSelected` names the CANDIDATE that went into `reconcile`, not the figure
/// that came out. The ordinary stale-session case separates the two: the single
/// candidate is selected, and the mark still overrides its value.
@Test func selectionNamesTheCandidateNotTheFigureFinallyShown() {
    let resolution = CaptureSelection.resolve([capture(69, at: 2_000)],
                                              against: markWithoutRegrant(usedPercent: 74))

    #expect(resolution.candidates.map(\.isSelected) == [true])
    #expect(resolution.candidates[0].capture.sevenDay.usedPercent == 69)
    #expect(resolution.trusted?.sevenDay.usedPercent == 74)
}

@Test func resolvingNothingReportsNoCandidates() {
    #expect(CaptureSelection.resolve([], against: .empty).candidates.isEmpty)
}
