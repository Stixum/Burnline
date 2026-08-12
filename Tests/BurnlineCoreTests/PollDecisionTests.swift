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
    #expect(PollDecision.shouldPoll(enabled: false, anchorAge: 9_999, lastPollAt: nil,
                                    interval: interval, now: now) == false)
}

/// The whole point: the anchor has stopped moving and nothing else will move it.
@Test func pollsWhenTheAnchorHasGoneStale() {
    #expect(PollDecision.shouldPoll(enabled: true, anchorAge: interval + 1, lastPollAt: nil,
                                    interval: interval, now: now))
}

/// A fresh anchor means something is already publishing. Polling would spawn a
/// process to learn what is already known.
@Test func neverPollsWhileTheAnchorIsStillFresh() {
    #expect(PollDecision.shouldPoll(enabled: true, anchorAge: 60, lastPollAt: nil,
                                    interval: interval, now: now) == false)
}

/// No anchor at all is the strongest case for polling, not the weakest.
@Test func pollsWhenThereIsNoAnchorAtAll() {
    #expect(PollDecision.shouldPoll(enabled: true, anchorAge: nil, lastPollAt: nil,
                                    interval: interval, now: now))
}

/// The interval doubles as the retry floor. A poll that fails to refresh
/// anything — Claude Code missing, not signed in, the command renamed — leaves
/// the anchor stale and the first condition true forever; without this it would
/// spawn a session on every 60s scan tick.
@Test func aPollThatChangedNothingIsNotRetriedUntilTheIntervalElapses() {
    let justPolled = now.addingTimeInterval(-60)
    #expect(PollDecision.shouldPoll(enabled: true, anchorAge: 9_999, lastPollAt: justPolled,
                                    interval: interval, now: now) == false)

    let longAgo = now.addingTimeInterval(-interval - 1)
    #expect(PollDecision.shouldPoll(enabled: true, anchorAge: 9_999, lastPollAt: longAgo,
                                    interval: interval, now: now))
}

/// Exactly at the interval is not yet eligible — a strict `>`, matching
/// `CaptureAge.isStale`.
@Test func theBoundaryBelongsToNotPollingYet() {
    #expect(PollDecision.shouldPoll(enabled: true, anchorAge: interval, lastPollAt: nil,
                                    interval: interval, now: now) == false)
    #expect(PollDecision.shouldPoll(enabled: true, anchorAge: interval + 1, lastPollAt: nil,
                                    interval: interval, now: now))
}

/// A tightened interval must actually take effect on the next tick rather than
/// waiting out the old one — that is the whole point of adapting.
@Test func aTighterIntervalMakesAnAlreadyAgedAnchorEligibleImmediately() {
    let polledElevenMinutesAgo = now.addingTimeInterval(-11 * 60)
    #expect(PollDecision.shouldPoll(enabled: true, anchorAge: 11 * 60,
                                    lastPollAt: polledElevenMinutesAgo,
                                    interval: PollDecision.critical, now: now))
}
