import Testing
import Foundation
@testable import BurnlineCore

// Whether to spawn a Claude Code session is worth testing apart from the pty
// machinery that carries it out. Getting it wrong costs either a figure that
// silently freezes, or sessions accumulating on someone's machine — eight piled
// up unnoticed during the 2026-08-11 investigation.
//
// The cadence itself lives in PollIntervalTests; this is only the gate.

private let now = Date(timeIntervalSince1970: 100_000)
private let interval: TimeInterval = 45 * 60

@Test func neverPollsWhenDisabled() {
    #expect(PollDecision.shouldPoll(enabled: false, anchorAge: 9_999, lastPollAt: nil, consecutiveFailures: 0,
                                    interval: interval, now: now) == false)
}

/// The whole point: the anchor has stopped moving and nothing else will move it.
@Test func pollsWhenTheAnchorHasGoneStale() {
    #expect(PollDecision.shouldPoll(enabled: true, anchorAge: interval + 1, lastPollAt: nil, consecutiveFailures: 0,
                                    interval: interval, now: now))
}

/// A fresh anchor means something is already publishing. Polling would spawn a
/// process to learn what is already known.
@Test func neverPollsWhileTheAnchorIsStillFresh() {
    #expect(PollDecision.shouldPoll(enabled: true, anchorAge: 60, lastPollAt: nil, consecutiveFailures: 0,
                                    interval: interval, now: now) == false)
}

/// No anchor at all is the strongest case for polling, not the weakest.
@Test func pollsWhenThereIsNoAnchorAtAll() {
    #expect(PollDecision.shouldPoll(enabled: true, anchorAge: nil, lastPollAt: nil, consecutiveFailures: 0,
                                    interval: interval, now: now))
}

/// A poll that fails to refresh anything — a network blip, a 429, Claude Code
/// showing an update screen, not signed in — leaves the anchor stale and the
/// first condition true forever. The floor stops it spawning a session on every
/// 60s scan tick.
@Test func aFailedPollIsNotRetriedOnTheNextScanTick() {
    let justPolled = now.addingTimeInterval(-60)
    #expect(PollDecision.shouldPoll(enabled: true, anchorAge: 9_999, lastPollAt: justPolled,
                                    consecutiveFailures: 1,
                                    interval: interval, now: now) == false)
}

/// The floor after a failure is a short retry, not the whole interval. With the
/// interval as the floor, one miss at minute 46 pushed the next attempt to
/// minute 91, and the figure sat past the hour the UI calls stale.
@Test func aFailedPollIsRetriedAfterFiveMinutesRatherThanAWholeInterval() {
    let fourMinutesAgo = now.addingTimeInterval(-4 * 60)
    #expect(PollDecision.shouldPoll(enabled: true, anchorAge: 9_999, lastPollAt: fourMinutesAgo,
                                    consecutiveFailures: 1,
                                    interval: interval, now: now) == false)

    let fiveMinutesAgo = now.addingTimeInterval(-5 * 60 - 1)
    #expect(PollDecision.shouldPoll(enabled: true, anchorAge: 9_999, lastPollAt: fiveMinutesAgo,
                                    consecutiveFailures: 1,
                                    interval: interval, now: now))
}

/// A failure that persists — Claude Code missing, the command renamed — must
/// not spawn a ~27s session every five minutes forever. The retry doubles and
/// settles at the interval, which is where the old rule always sat.
@Test func repeatedFailuresBackOffUntilTheyReachTheInterval() {
    let floors = (1...6).map { PollDecision.retryFloor(afterFailures: $0, interval: interval) }
    let minute: TimeInterval = 60
    let expected: [TimeInterval] = [5 * minute, 10 * minute, 20 * minute, 40 * minute,
                                    interval, interval]
    #expect(floors == expected)
    #expect(PollDecision.retryFloor(afterFailures: 10_000, interval: interval) == interval)
}

/// The backoff never loosens a tight interval: under pressure the interval is
/// already the shorter wait.
@Test func theRetryFloorNeverExceedsTheInterval() {
    for failures in 1...8 {
        #expect(PollDecision.retryFloor(afterFailures: failures,
                                        interval: PollDecision.critical) <= PollDecision.critical)
    }
}

/// After a refresh the floor is the full interval, as before. Only a failure
/// earns the short retry.
@Test func withoutAFailureTheFloorIsTheWholeInterval() {
    #expect(PollDecision.retryFloor(afterFailures: 0, interval: interval) == interval)
    let sixMinutesAgo = now.addingTimeInterval(-6 * 60)
    #expect(PollDecision.shouldPoll(enabled: true, anchorAge: 9_999, lastPollAt: sixMinutesAgo,
                                    consecutiveFailures: 0,
                                    interval: interval, now: now) == false)

    let longAgo = now.addingTimeInterval(-interval - 1)
    #expect(PollDecision.shouldPoll(enabled: true, anchorAge: 9_999, lastPollAt: longAgo,
                                    consecutiveFailures: 0,
                                    interval: interval, now: now))
}

/// Exactly at the interval is not yet eligible — a strict `>`, matching
/// `CaptureAge.isStale`.
@Test func theBoundaryBelongsToNotPollingYet() {
    #expect(PollDecision.shouldPoll(enabled: true, anchorAge: interval, lastPollAt: nil, consecutiveFailures: 0,
                                    interval: interval, now: now) == false)
    #expect(PollDecision.shouldPoll(enabled: true, anchorAge: interval + 1, lastPollAt: nil, consecutiveFailures: 0,
                                    interval: interval, now: now))
}

/// A tightened interval must actually take effect on the next tick rather than
/// waiting out the old one — that is the whole point of adapting.
@Test func aTighterIntervalMakesAnAlreadyAgedAnchorEligibleImmediately() {
    let polledElevenMinutesAgo = now.addingTimeInterval(-11 * 60)
    #expect(PollDecision.shouldPoll(enabled: true, anchorAge: 11 * 60,
                                    lastPollAt: polledElevenMinutesAgo, consecutiveFailures: 0,
                                    interval: PollDecision.critical, now: now))
}
