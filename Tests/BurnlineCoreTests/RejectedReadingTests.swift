import Testing
import Foundation
@testable import BurnlineCore

// `BurnlineProbe` has always reported "on disk 69% -> REJECTED as stale, using
// 74%" while the popover said nothing at all. That silence is the difference
// between "my app is broken" and "my app is protecting me from a stale
// session" — and it is exactly the confusion the 2026-08-11 investigation was.

private let week: TimeInterval = 1_786_690_800

private func reading(_ percent: Double, at capturedAt: TimeInterval) -> RateLimitCapture {
    RateLimitCapture(version: 1, capturedAt: capturedAt,
                     sevenDay: .init(usedPercent: percent, resetsAt: week),
                     fiveHour: nil)
}

@Test func noRejectionWhenTheFileAgreesWithWhatIsShown() {
    let same = reading(69, at: 1_000)
    #expect(RateLimitHighWater.rejection(onDisk: same, resolved: same) == nil)
}

/// ⚠️ Renamed 2026-09-01. It used to be
/// `noRejectionWhenTheFileCarriesTheHigherReading`, and its fixture was 74/74 —
/// EQUAL, not higher — so it passed whatever the guard did, while its name
/// described the case that now FIRES
/// (`aRegrantMakesTheHigherFileReadingTheRejectedOne`). What it really checks is
/// worth keeping under an honest name: equality is silent at a value other than
/// the one the test above uses, so a comparison hardcoded to 69 cannot pass
/// both. The two dates differ for the same reason — this keys on the
/// percentages, not on the two captures being the same object.
@Test func equalityIsSilentAtAnyValueNotJustTheOneAbove() {
    #expect(RateLimitHighWater.rejection(onDisk: reading(74, at: 2_000),
                                         resolved: reading(74, at: 1_000)) == nil)
}

@Test func aRejectionIsReportedWhenTheHighWaterMarkOverrodeTheFile() {
    let rejected = RateLimitHighWater.rejection(onDisk: reading(69, at: 2_000),
                                                resolved: reading(74, at: 1_000))
    #expect(rejected?.reportedPercent == 69)
    #expect(rejected?.usingPercent == 74)
}

/// Assembled on the model, like `FiveHourStatus.rowValue`, so the view body
/// stays declarative and the wording is test-covered.
@Test func theRejectionRowNamesBothFiguresSoNeitherIsAmbiguous() {
    let rejected = try? #require(RateLimitHighWater.rejection(onDisk: reading(69, at: 2_000),
                                                              resolved: reading(74, at: 1_000)))
    #expect(rejected?.rowValue == "said 69%, kept 74%")
}

/// End to end through the real reconcile, which is how the app produces the two
/// values — not two hand-built captures that happen to differ.
@Test func reconcilingAStaleSessionProducesAReportableRejection() {
    let (_, mark) = RateLimitHighWater.reconcile(reading(74, at: 1_000), against: .empty)
    let onDisk = reading(69, at: 2_000)
    let (resolved, _) = RateLimitHighWater.reconcile(onDisk, against: mark)

    let rejected = RateLimitHighWater.rejection(onDisk: onDisk, resolved: resolved)
    #expect(rejected?.reportedPercent == 69)
    #expect(rejected?.usingPercent == 74)
}

@Test func theSnapshotCarriesTheRejectionThroughToTheView() {
    let snapshot = SnapshotBuilder.build(
        cache: ScanCache(),
        settings: .default,
        rateLimit: reading(74, at: Date().timeIntervalSince1970),
        now: Date(),
        isScanning: false,
        rejected: .init(reportedPercent: 69, usingPercent: 74))

    #expect(snapshot.rejectedReading?.reportedPercent == 69)
}

/// The ordinary case renders nothing. This row is exceptions-only, per the
/// portfolio status-chip standard.
@Test func aSnapshotWithNoDisagreementCarriesNoRejection() {
    let snapshot = SnapshotBuilder.build(cache: ScanCache(), settings: .default,
                                         rateLimit: nil, now: Date(), isScanning: false)
    #expect(snapshot.rejectedReading == nil)
}

// MARK: - The other direction

// ⚠️ The rule used to be one-way: only a HIGHER shown figure counted as a
// rejection, because "usage inside a window cannot go down" made the lower
// reading always the older one. Anthropic re-issued the weekly allowance inside
// an unchanged window on 2026-09-01 and the true figure went 51% → 0%, so the
// stale replay is now the HIGHER one and the row that explains the disagreement
// has to fire in both directions or it goes silent exactly when it is needed.

/// The re-grant direction. Left one-way, the app shows 7% while the user's
/// terminal shows 51% and nothing on screen says why.
@Test func aRegrantMakesTheHigherFileReadingTheRejectedOne() {
    let rejected = RateLimitHighWater.rejection(onDisk: reading(51, at: 9_999),
                                                resolved: reading(7, at: 1_000))
    #expect(rejected?.reportedPercent == 51)
    #expect(rejected?.usingPercent == 7)
    #expect(rejected?.rowValue == "said 51%, kept 7%")
}

/// 🔴 The explanation is branch-aware and lives on the model, like `rowValue`,
/// so no view body branches. The old copy asserted "usage inside a window cannot
/// go down, so the lower reading is always the older one" — the exact axiom the
/// re-grant falsified. Printing that over a re-grant refusal would explain the
/// disagreement with a statement the disagreement disproves.
///
/// ⚠️ **The second assertion is an INVERSION of the one it replaces**, kept in
/// place the way `freshestBreaksATieOnTheHigherPercentage` →
/// `freshestBreaksATieOnProvenanceNotMagnitude` was, because the reasoning it
/// overturns still explains the design.
///
/// It used to read `#expect(idleSession.explanation.contains("cannot go down"))`
/// — the axiom survived on that branch with "by consumption" attached, which
/// made the sentence true. It is still not the REASON. `best()` refuses a lower
/// reading purely because its date could not be shown to be later than the
/// evidence behind the mark, and a genuine 2026-09-01-style re-grant that
/// arrived undated lands on exactly this branch — where it was told, in the
/// app's own words, that what it had just reported cannot happen. Changed
/// 2026-09-01 along with the copy; neither branch rests on the axiom now.
@Test func neitherExplanationRestsOnTheAxiomARegrantFalsified() {
    let regrant = RateLimitHighWater.RejectedReading(reportedPercent: 51, usingPercent: 7)
    #expect(regrant.explanation.contains("re-issued"))
    #expect(!regrant.explanation.contains("cannot go down"))

    let idleSession = RateLimitHighWater.RejectedReading(reportedPercent: 69, usingPercent: 74)
    #expect(!idleSession.explanation.contains("cannot go down"))
    #expect(!idleSession.explanation.contains("re-issued"))
}

/// ⚠️ Anchored to the PHRASE around each figure, never merely to its presence.
/// "Names both figures" cannot see a transposition — swap `said` and `kept`
/// inside a branch and both numbers are still there, while the tooltip now reads
/// "reported 7% … the 51% shown", which is the disagreement backwards. That is a
/// very plausible slip during a re-word and it is user-facing.
@Test func theExplanationNeverTransposesTheTwoFigures() {
    let regrant = RateLimitHighWater.RejectedReading(reportedPercent: 51, usingPercent: 7)
    #expect(regrant.explanation.contains("reported 51%"))
    #expect(regrant.explanation.contains("The 7% shown"))

    let idleSession = RateLimitHighWater.RejectedReading(reportedPercent: 69, usingPercent: 74)
    #expect(idleSession.explanation.contains("reported 69%"))
    #expect(idleSession.explanation.contains("lower than the 74% already seen"))
}

/// 🔴 The re-grant branch may not say the reading PREDATES the re-issue.
/// `CaptureSelection.eligible` refuses two kinds of candidate — one proven to
/// predate the epoch, and one with no proven date at all (the shared file with
/// no `session_id`, the rollback script, an older build). The second may be
/// perfectly live, and telling its owner their terminal shows a pre-re-grant
/// number is false at the exact moment they are comparing the two. Only
/// "could not be shown to postdate" is a claim the filter actually makes.
@Test func theRegrantExplanationClaimsOnlyWhatTheFilterChecked() {
    let regrant = RateLimitHighWater.RejectedReading(reportedPercent: 51, usingPercent: 7)
    #expect(regrant.explanation.contains("could not be shown to postdate"))
    #expect(!regrant.explanation.contains("predates"))
}

/// ⚠️ **Rewritten 2026-09-01, and it is the second half of the same wording
/// change as `neitherExplanationRestsOnTheAxiomARegrantFalsified`** — one branch
/// of `explanation`, pinned by two tests.
///
/// It used to be `theIdleSessionExplanationPresumesRatherThanDeduces` and
/// asserted `contains("cannot go down by consumption")`, `contains("presumed
/// older")` and `!contains("always the older one")`. Its comment read: "it fires
/// for a reading that is merely not provably newer, so 'presumed older' is the
/// claim, and the axiom survives 2026-09-01 only with 'by consumption'
/// attached". The first half of that is right and is what this test now pins;
/// the axiom is the half that had to go. It is a true sentence that is not the
/// reason — `best()` refuses on provenance alone — and stating it as the reason
/// tells an undated but genuine re-grant that its own observation is impossible.
///
/// So the claim is the missing proof, and the idle session stays as the likely
/// cause it is rather than the deduction it was.
@Test func theOverriddenExplanationNamesTheMissingProofNotAnAxiom() {
    let idleSession = RateLimitHighWater.RejectedReading(reportedPercent: 69, usingPercent: 74)
    #expect(idleSession.explanation.contains("could not be shown to have been taken later"))
    // Hedged, not deduced: this branch cannot tell an idle replay from a
    // re-grant that arrived without a provable date.
    #expect(idleSession.explanation.contains("Usually"))
    #expect(!idleSession.explanation.contains("cannot go down"))
    #expect(!idleSession.explanation.contains("always the older one"))
}

// MARK: - A reading from a window that has already reset

// 🔴 Reachable, and reachable silently. With an epoch open and the window then
// rolling, `CaptureSelection.eligible` refuses an undated replay of the old
// window (same window as the mark, no proof) while admitting a proven capture of
// the new one — so the freshest reading ON DISK and the trusted one describe
// different windows. The row fires, correctly, and before this branch existed it
// explained a previous window's reading with "the weekly allowance was re-issued
// inside this window", which is a claim about a window that reading is not in.

@Test func aReadingFromAnEarlierWindowIsMarkedAsSuch() {
    let previous = reading(51, at: 9_999)
    let current = RateLimitCapture(
        version: 1, capturedAt: 1_000,
        sevenDay: .init(usedPercent: 3, resetsAt: week + 7 * 86_400), fiveHour: nil)

    let rejected = RateLimitHighWater.rejection(onDisk: previous, resolved: current)

    #expect(rejected?.isFromAnEarlierWindow == true)
}

/// 🔴 The two sources spell one boundary 0.58s apart — the statusline reports
/// whole epoch seconds, `cachedUsageUtilization` reports microseconds. Without
/// the tolerance every ordinary re-grant refusal would claim the rejected
/// reading is from a previous window, which is the loudest possible way to be
/// wrong about the case this whole feature exists for.
@Test func aSubSecondDifferenceInTheResetInstantIsNotAnEarlierWindow() {
    let statusline = reading(51, at: 9_999)
    let utilization = RateLimitCapture(
        version: 1, capturedAt: 1_000,
        sevenDay: .init(usedPercent: 7, resetsAt: week + 0.58), fiveHour: nil)

    let rejected = RateLimitHighWater.rejection(onDisk: statusline, resolved: utilization)

    #expect(rejected?.isFromAnEarlierWindow == false)
    #expect(rejected?.explanation.contains("re-issued") == true)
}

/// 🔴 The tolerance EDGE, both sides of it. `aSubSecondDifference…` above pins
/// 0.58s, which is comfortably inside — so nothing there can tell `<` from `<=`
/// on the 60.000s boundary, and a mutation of exactly that passed the whole
/// suite when this branch spelled the tolerance out itself.
///
/// The answer is `isSameWindow`'s, deliberately: exactly 60s apart is one
/// window, because `CaptureSelection.eligible` says so about the same 60
/// seconds. These two fixtures are what stops the two sites drifting apart.
@Test func exactlyTheToleranceApartIsStillTheSameWindow() {
    let onDisk = reading(51, at: 9_999)
    let resolved = RateLimitCapture(
        version: 1, capturedAt: 1_000,
        sevenDay: .init(usedPercent: 7, resetsAt: week + RateLimitHighWater.sameWindowTolerance),
        fiveHour: nil)

    let rejected = RateLimitHighWater.rejection(onDisk: onDisk, resolved: resolved)

    #expect(rejected?.isFromAnEarlierWindow == false)
    #expect(rejected?.explanation.contains("re-issued") == true)
}

/// The positive control for it: one second past the tolerance and the branch
/// fires. Without this, `isFromAnEarlierWindow = false` satisfies the test above.
@Test func oneSecondPastTheToleranceIsAnEarlierWindow() {
    let onDisk = reading(51, at: 9_999)
    let resolved = RateLimitCapture(
        version: 1, capturedAt: 1_000,
        sevenDay: .init(usedPercent: 7,
                        resetsAt: week + RateLimitHighWater.sameWindowTolerance + 1),
        fiveHour: nil)

    let rejected = RateLimitHighWater.rejection(onDisk: onDisk, resolved: resolved)

    #expect(rejected?.isFromAnEarlierWindow == true)
    #expect(rejected?.explanation.contains("previous weekly window") == true)
}

/// Windows are seven days apart, so the tolerance cannot merge two of them.
@Test func theEarlierWindowBranchNamesThePreviousWindowNotTheRegrant() {
    let rejected = RateLimitHighWater.RejectedReading(reportedPercent: 51, usingPercent: 3,
                                                      isFromAnEarlierWindow: true)

    #expect(rejected.explanation.contains("previous weekly window"))
    #expect(!rejected.explanation.contains("re-issued"))
    #expect(!rejected.explanation.contains("could not be shown"))
}

/// The same anti-transposition discipline the other two branches carry: both
/// numbers are present in either order, so only the phrase around each one can
/// see the swap.
@Test func theEarlierWindowExplanationNeverTransposesTheTwoFigures() {
    let rejected = RateLimitHighWater.RejectedReading(reportedPercent: 51, usingPercent: 3,
                                                      isFromAnEarlierWindow: true)

    #expect(rejected.explanation.contains("reported 51%"))
    #expect(rejected.explanation.contains("The 3% shown"))
}

/// 🔴 The branch takes precedence over DIRECTION, and this is the fixture that
/// says so. A rolled window can leave the refused reading either above or below
/// the shown one — an old window near its limit against a fresh one at 3%, or an
/// old window at 2% against a current 5% — and the reason is the same both
/// times. Deciding it by direction puts one of the two on the idle-session
/// branch, which explains a dead window's reading as a live rival.
@Test func theEarlierWindowBranchWinsInEitherDirection() {
    let below = RateLimitHighWater.RejectedReading(reportedPercent: 2, usingPercent: 5,
                                                   isFromAnEarlierWindow: true)
    #expect(below.explanation.contains("previous weekly window"))
    #expect(!below.explanation.contains("already seen this window"))
}

/// End to end through the real selection, which is the only thing that proves
/// the state is reachable rather than merely representable.
@Test func aRolledWindowUnderAnOpenEpochReportsThePreviousWindow() {
    let regrant = RateLimitHighWater.Regrant(startedAt: 1_000, startPercent: 0)
    let mark = RateLimitHighWater(
        sevenDay: .init(resetsAt: week, usedPercent: 7, capturedAt: 1_000,
                        provenAt: 1_000, regrant: regrant))

    // Undated, and the freshest thing in a file: an old build or the shared
    // `rate-limits.json` replaying the window that just ended.
    let replay = reading(51, at: 9_999)
    var nextWindow = RateLimitCapture(
        version: 1, capturedAt: 5_000,
        sevenDay: .init(usedPercent: 3, resetsAt: week + 7 * 86_400), fiveHour: nil)
    nextWindow.provenAt = 5_000

    let resolution = CaptureSelection.resolve([replay, nextWindow], against: mark)

    #expect(resolution.onDisk?.sevenDay.usedPercent == 51)
    #expect(resolution.trusted?.sevenDay.usedPercent == 3)
    #expect(resolution.rejected?.isFromAnEarlierWindow == true)
    #expect(resolution.rejected?.explanation.contains("previous weekly window") == true)
}

/// The positive control for the test above: the ordinary re-grant refusal, same
/// window on both sides, must NOT be relabelled. Without this,
/// `isFromAnEarlierWindow = true` hardcoded would pass every assertion above.
@Test func anOrdinaryRegrantRefusalIsNotCalledAPreviousWindow() {
    let regrant = RateLimitHighWater.Regrant(startedAt: 1_000, startPercent: 0)
    let mark = RateLimitHighWater(
        sevenDay: .init(resetsAt: week, usedPercent: 7, capturedAt: 1_000,
                        provenAt: 1_000, regrant: regrant))

    let resolution = CaptureSelection.resolve([reading(51, at: 9_999)], against: mark)

    #expect(resolution.rejected?.isFromAnEarlierWindow == false)
    #expect(resolution.rejected?.explanation.contains("re-issued") == true)
}
