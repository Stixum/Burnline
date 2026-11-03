import Testing
import Foundation
@testable import BurnlineCore

// What the poll measures its anchor's age from. Not `Snapshot.liveAge`: that is
// the trusted capture's `capturedAt`, which an EQUAL re-confirmation moves
// forward whether or not it is proven. An idle session republishing the figure
// the mark already holds, undated (no five-hour block to expose the replay, a
// transcript with no assistant turn to date it), therefore kept the anchor at
// "just now" every 30s, and the poll never fired while usage elsewhere climbed.
// Seen on Ultra after 2026-10-30, which removed the five-hour block.

private let windowReset: TimeInterval = 1_786_690_800
private let t0 = windowReset - 3 * 86_400

private func reading(_ percent: Double, at captured: TimeInterval,
                     provenAt: TimeInterval? = nil,
                     resetsAt: TimeInterval = windowReset) -> RateLimitCapture {
    var c = RateLimitCapture(version: RateLimitCapture.currentVersion, capturedAt: captured,
                             sevenDay: .init(usedPercent: percent, resetsAt: resetsAt),
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

@Test func anUndatedRepublishOfTheSameFigureDoesNotRefreshThePollAnchor() {
    let now = t0 + 50 * 60
    let republished = reading(48, at: now)
    let polled = reading(48, at: t0, provenAt: t0)
    let resolution = CaptureSelection.resolve([republished, polled],
                                              against: mark(48, capturedAt: t0, provenAt: t0))

    #expect(resolution.lastProvenAt(now: now) == t0)
    let anchorAge = resolution.lastProvenAt(now: now).map { now - $0 }
    #expect(PollDecision.shouldPoll(enabled: true, anchorAge: anchorAge,
                                    lastPollAt: Date(timeIntervalSince1970: t0),
                                    consecutiveFailures: 0, interval: 45 * 60,
                                    now: Date(timeIntervalSince1970: now)))
}

/// A poll whose reading the mark refused still proved a fresh fetch. Polling
/// again would spawn a session to learn what the last one already did.
@Test func aProvenReadingTheMarkRefusedStillCountsAsTheAnchor() {
    let now = t0 + 50 * 60
    let polled = reading(46, at: now - 60, provenAt: now - 60)
    let resolution = CaptureSelection.resolve([polled],
                                              against: mark(50, capturedAt: now - 30,
                                                            provenAt: nil))

    #expect(resolution.lastProvenAt(now: now) == now - 60)
}

/// After a weekly reset the last proof describes a week that is over. Counting
/// it would hold the first poll of the new week back by up to an interval.
@Test func aProofFromAWindowThatHasResetIsNotAnAnchor() {
    let now = windowReset + 5 * 60
    let polled = reading(97, at: windowReset - 10 * 60, provenAt: windowReset - 10 * 60)
    let resolution = CaptureSelection.resolve([polled],
                                              against: mark(97, capturedAt: windowReset - 600,
                                                            provenAt: windowReset - 600))

    #expect(resolution.lastProvenAt(now: now) == nil)
}

/// Nothing proven anywhere is no anchor, which polls, rather than the newest
/// undated stamp, which never would.
@Test func withNoProofAnywhereThereIsNoPollAnchor() {
    let now = t0 + 50 * 60
    let resolution = CaptureSelection.resolve([reading(48, at: now)],
                                              against: mark(48, capturedAt: now - 30,
                                                            provenAt: nil))

    #expect(resolution.lastProvenAt(now: now) == nil)
}
