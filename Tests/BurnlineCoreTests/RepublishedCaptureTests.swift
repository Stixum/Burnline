import Testing
import Foundation
@testable import BurnlineCore

// Every open Claude Code session runs the statusline on its own timer and
// republishes the `rate_limits` block cached from *its own* last API response.
// An idle session therefore rewrites the file forever with a reading that never
// changes — and both the script and the binary stamped it with `Date()`, so a
// three-hour-old number presented as thirty seconds old.
//
// The five-hour block dates it. A payload generated while the current five-hour
// window ended at T cannot have been generated after T, so a payload whose own
// `five_hour.resets_at` has already passed at stamping time is provably a
// replay, and T is the latest instant it could have been produced.
//
// Sufficient, not necessary: `five_hour` is absent on some plans, so this
// catches the common case only.

private let weekReset: TimeInterval = 1_786_690_800

private func republishable(capturedAt: TimeInterval,
                           fiveHourResetsAt: TimeInterval?,
                           percent: Double = 69) -> RateLimitCapture {
    RateLimitCapture(
        version: 1,
        capturedAt: capturedAt,
        sevenDay: .init(usedPercent: percent, resetsAt: weekReset),
        fiveHour: fiveHourResetsAt.map { .init(usedPercent: 28, resetsAt: $0) })
}

@Test func aFreshPayloadIsNotARepublishedCache() {
    let fresh = republishable(capturedAt: 1_000, fiveHourResetsAt: 9_000)
    #expect(fresh.isRepublishedCache == false)
    #expect(fresh.correctedForRepublishing() == fresh)
}

@Test func anExpiredFiveHourWindowProvesThePayloadIsARepublishedCache() {
    #expect(republishable(capturedAt: 10_000, fiveHourResetsAt: 4_000).isRepublishedCache)
}

@Test func aRepublishedCaptureIsDatedToTheLatestInstantItCouldHaveBeenProduced() {
    let corrected = republishable(capturedAt: 10_000, fiveHourResetsAt: 4_000)
        .correctedForRepublishing()

    #expect(corrected.capturedAt == 4_000)
    // Only the timestamp is a lie. The percentage is a real reading and the
    // best available; discarding it would drop the app to pace-only on a Mac
    // where every session is idle — which is the exact case this detects.
    #expect(corrected.sevenDay.usedPercent == 69)
}

@Test func correctingARepublishedCaptureTwiceChangesNothingTheSecondTime() {
    let once = republishable(capturedAt: 10_000, fiveHourResetsAt: 4_000)
        .correctedForRepublishing()
    #expect(once.correctedForRepublishing() == once)
}

/// The documented caveat, pinned: no five-hour block means no dating evidence,
/// so the capture is left exactly as it is rather than guessed at.
@Test func aCaptureWithNoFiveHourBlockCannotBeDatedAndIsLeftAlone() {
    let undatable = republishable(capturedAt: 10_000, fiveHourResetsAt: nil)
    #expect(undatable.isRepublishedCache == false)
    #expect(undatable.correctedForRepublishing() == undatable)
}

/// The write side: the helper must not stamp a replay with `Date()`.
@Test func theHelperDatesARepublishedPayloadHonestlyInsteadOfStampingItNow() throws {
    let json = """
    {"rate_limits":{"seven_day":{"used_percentage":69,"resets_at":1786690800},
                    "five_hour":{"used_percentage":28,"resets_at":1786491600}}}
    """
    let payload = try JSONDecoder().decode(StatuslinePayload.self, from: Data(json.utf8))

    let capture = try #require(payload.capture(capturedAt: 1_786_500_648))
    #expect(capture.capturedAt == 1_786_491_600)
}

/// The read side, which also covers files written by anything that isn't this
/// binary — the rollback script, or an older build still in someone's bundle.
@Test func loadingARepublishedCaptureFromDiskDatesItHonestly() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("burnline-republish-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = RateLimitStore(directory: directory)
    try store.save(republishable(capturedAt: 10_000, fiveHourResetsAt: 4_000))

    #expect(store.load()?.capturedAt == 4_000)
}

/// A replay of the same percentage is not a new confirmation of it, so it must
/// not pull the age backwards past a genuine reading. Counterpart to
/// `anEqualReadingRefreshesTheAge`, which pins the forward case.
@Test func aRepublishedCaptureDoesNotDragTheHighWaterAgeBackwards() {
    let genuine = republishable(capturedAt: 5_000, fiveHourResetsAt: 9_000)
    let (_, mark) = RateLimitHighWater.reconcile(genuine, against: .empty)

    let replay = republishable(capturedAt: 10_000, fiveHourResetsAt: 4_000)
        .correctedForRepublishing()
    let (result, _) = RateLimitHighWater.reconcile(replay, against: mark)

    #expect(result.capturedAt == 5_000)
}

/// A strictly higher reading is new information, so it keeps its own date even
/// when that date is older than the mark's. Taking the max here instead would
/// present a figure as fresher than the moment it was actually learned.
@Test func aHigherReadingKeepsItsOwnDateEvenWhenOlderThanTheMark() {
    let (_, mark) = RateLimitHighWater.reconcile(
        republishable(capturedAt: 5_000, fiveHourResetsAt: 9_000), against: .empty)

    let higherButOlder = republishable(capturedAt: 3_000, fiveHourResetsAt: 9_000, percent: 75)
    let (result, _) = RateLimitHighWater.reconcile(higherButOlder, against: mark)

    #expect(result.sevenDay.usedPercent == 75)
    #expect(result.capturedAt == 3_000)
}

/// The user-visible consequence: the popover already styles anything over an
/// hour old as extrapolated, so an honest timestamp is the whole fix.
@Test func aRepublishedCaptureReadsAsExtrapolatedRatherThanJustNow() {
    let now: TimeInterval = 10_000
    let corrected = republishable(capturedAt: now, fiveHourResetsAt: 4_000)
        .correctedForRepublishing()

    #expect(CaptureAge.isStale(now - corrected.capturedAt))
}
