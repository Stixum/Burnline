import Testing
import Foundation
@testable import BurnlineCore

// What "Live · N" counts from. It used to be the trusted capture's `capturedAt`,
// which an EQUAL re-confirmation moves forward whether or not it is proven
// (`RateLimitHighWater.best`), so an idle session republishing the held figure
// undated kept the label at "just now", and with it the refresh offer and the
// auth probe, which read the same age. The poll was moved off that age in
// 1.6.7 (`PollAnchorTests`); the label was left open.
//
// An undated republish cannot be told from an undated fresh reading: neither
// carries a mint time. What CAN be told is whether anything proves the figure
// on screen, and since when. So the age counts from the mark's proof when the
// mark has one, and only an unproven mark still counts from its last sighting.
//
// Every instant below is the fixture's own; nothing is read back from the code.

private let windowReset: TimeInterval = 1_786_690_800
private let fetchedAt = windowReset - 3 * 86_400           // the proven fetch
private let threeHoursLater = fetchedAt + 3 * 3_600        // the republish
private let now = Date(timeIntervalSince1970: threeHoursLater + 10)

private func reading(_ percent: Double, at captured: TimeInterval,
                     provenAt: TimeInterval? = nil) -> RateLimitCapture {
    var c = RateLimitCapture(version: RateLimitCapture.currentVersion, capturedAt: captured,
                             sevenDay: .init(usedPercent: percent, resetsAt: windowReset),
                             fiveHour: nil)
    c.provenAt = provenAt
    return c
}

private func mark(_ percent: Double, capturedAt: TimeInterval,
                  provenAt: TimeInterval?) -> RateLimitHighWater {
    RateLimitHighWater(sevenDay: .init(resetsAt: windowReset, usedPercent: percent,
                                       capturedAt: capturedAt, provenAt: provenAt),
                       fiveHour: nil)
}

/// The app's own composition: resolve, then build with the resolution's proof.
private func snapshot(_ candidates: [RateLimitCapture], against mark: RateLimitHighWater)
    -> Snapshot {
    let resolution = CaptureSelection.resolve(candidates, against: mark)
    return SnapshotBuilder.build(cache: ScanCache(), settings: .default,
                                 rateLimit: resolution.trusted, now: now, isScanning: false,
                                 regrant: resolution.regrant,
                                 trustedProvenAt: resolution.trustedProvenAt)
}

@Test func anUndatedRepublishOfAProvenFigureDoesNotMakeItLookFresh() {
    let s = snapshot([reading(22, at: threeHoursLater)],
                     against: mark(22, capturedAt: fetchedAt, provenAt: fetchedAt))
    #expect(s.source == .live(capturedAt: Date(timeIntervalSince1970: fetchedAt)))
    // The figure itself is untouched: same percentage, still live.
    #expect(s.capturedPercent == 22)
}

/// A higher reading is news, proven or not, and keeps its own date: the rule
/// `best` already has for the mark. The proof it replaced described a value
/// the mark no longer holds.
@Test func anUndatedHigherReadingStillCountsFromWhenItLanded() {
    let s = snapshot([reading(23, at: threeHoursLater)],
                     against: mark(22, capturedAt: fetchedAt, provenAt: fetchedAt))
    #expect(s.source == .live(capturedAt: Date(timeIntervalSince1970: threeHoursLater)))
}

/// A proven re-confirmation is a fresh reading and moves the age, as before.
@Test func aProvenReconfirmationStillMovesTheAge() {
    let s = snapshot([reading(22, at: threeHoursLater, provenAt: threeHoursLater)],
                     against: mark(22, capturedAt: fetchedAt, provenAt: fetchedAt))
    #expect(s.source == .live(capturedAt: Date(timeIntervalSince1970: threeHoursLater)))
}

/// ⚠️ The case this does not fix, pinned so nobody reads the fix as complete:
/// with nothing proving the figure anywhere, an undated republish and an
/// undated fresh reading look the same, and the age is still the last sighting.
@Test func withNoProofAnywhereAnUndatedRepublishStillLooksFresh() {
    let s = snapshot([reading(22, at: threeHoursLater)],
                     against: mark(22, capturedAt: fetchedAt, provenAt: nil))
    #expect(s.source == .live(capturedAt: Date(timeIntervalSince1970: threeHoursLater)))
}

/// The consequence the backlog named: the refresh offer reads this age, so an
/// idle terminal republishing a day-old proven figure no longer holds it off.
@Test func aDayOldProvenFigureIsOfferedARefreshWhileAnIdleSessionRepublishesIt() {
    let realNow = Date()
    let proven = realNow.timeIntervalSince1970 - 25 * 3_600
    let reset = realNow.timeIntervalSince1970 + 2 * 86_400
    var republished = RateLimitCapture(version: RateLimitCapture.currentVersion,
                                       capturedAt: realNow.timeIntervalSince1970 - 5,
                                       sevenDay: .init(usedPercent: 40, resetsAt: reset),
                                       fiveHour: nil)
    republished.provenAt = nil
    let held = RateLimitHighWater(sevenDay: .init(resetsAt: reset, usedPercent: 40,
                                                  capturedAt: proven, provenAt: proven),
                                  fiveHour: nil)
    let resolution = CaptureSelection.resolve([republished], against: held)
    let s = SnapshotBuilder.build(cache: ScanCache(), settings: .default,
                                  rateLimit: resolution.trusted, now: realNow, isScanning: false,
                                  trustedProvenAt: resolution.trustedProvenAt)

    let offer = RefreshOffer.resolve(choice: .neverChose, snapshot: s,
                                     helper: .reporting(age: 5), claudeFound: true)
    guard case .stale = offer else {
        Issue.record("expected a stale offer, got \(String(describing: offer))")
        return
    }
}

/// The proof is the mark's, so it belongs to the figure only while the mark
/// describes that figure. A mark for another window proves nothing about it.
@Test func aProofForAnotherWindowIsNotTheFiguresProof() {
    let other = RateLimitHighWater(sevenDay: .init(resetsAt: windowReset - 604_800, usedPercent: 22,
                                                   capturedAt: fetchedAt, provenAt: fetchedAt),
                                   fiveHour: nil)
    let r = CaptureSelection.resolve([reading(22, at: threeHoursLater)], against: other)
    // The new window replaces the mark wholesale; the undated reading proves nothing.
    #expect(r.trustedProvenAt == nil)
}
