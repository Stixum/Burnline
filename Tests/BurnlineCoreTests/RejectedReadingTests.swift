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

@Test func noRejectionWhenTheFileCarriesTheHigherReading() {
    #expect(RateLimitHighWater.rejection(onDisk: reading(74, at: 2_000),
                                         resolved: reading(74, at: 2_000)) == nil)
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

/// 🔴 The explanation is direction-aware and lives on the model, like
/// `rowValue`, so no view body branches. The old copy asserted "usage inside a
/// window cannot go down, so the lower reading is always the older one" — the
/// exact axiom the re-grant falsified. Printing that over a re-grant refusal
/// would explain the disagreement with a statement the disagreement disproves.
@Test func theExplanationDoesNotClaimUsageCannotGoDownAfterARegrant() {
    let regrant = RateLimitHighWater.RejectedReading(reportedPercent: 51, usingPercent: 7)
    #expect(regrant.explanation.contains("re-issued"))
    #expect(!regrant.explanation.contains("cannot go down"))

    let idleSession = RateLimitHighWater.RejectedReading(reportedPercent: 69, usingPercent: 74)
    #expect(idleSession.explanation.contains("cannot go down"))
    #expect(!idleSession.explanation.contains("re-issued"))
}

/// Both figures appear in both directions, so the tooltip can never name one
/// number and leave the other to be guessed at.
@Test func theExplanationAlwaysNamesBothFigures() {
    for reading in [RateLimitHighWater.RejectedReading(reportedPercent: 51, usingPercent: 7),
                    RateLimitHighWater.RejectedReading(reportedPercent: 69, usingPercent: 74)] {
        #expect(reading.explanation.contains("\(DisplayValue.whole(reading.reportedPercent))%"))
        #expect(reading.explanation.contains("\(DisplayValue.whole(reading.usingPercent))%"))
    }
}
