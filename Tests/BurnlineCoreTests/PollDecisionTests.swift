import Testing
import Foundation
@testable import BurnlineCore

// Whether to spawn a Claude Code session is a decision worth testing on its own,
// separately from the pty machinery that carries it out. Getting this wrong
// means either a figure that silently freezes, or sessions accumulating on
// someone's machine — eight of them piled up unnoticed on 2026-08-11.

private let now = Date(timeIntervalSince1970: 100_000)

@Test func neverPollsWhenDisabled() {
    #expect(PollDecision.shouldPoll(enabled: false, anchorAge: 9_999, lastPollAt: nil, now: now)
            == false)
}

/// The whole point: the anchor has stopped moving and nothing else will move it.
@Test func pollsWhenTheAnchorHasGoneStale() {
    #expect(PollDecision.shouldPoll(enabled: true, anchorAge: 2 * 3_600, lastPollAt: nil, now: now))
}

/// Exactly at the threshold is NOT yet stale — `CaptureAge.isStale` is a strict
/// `>`. The two must agree, or the app polls while still labelling the figure
/// live, or labels it stale while refusing to refresh it.
@Test func theBoundaryBelongsToNotStaleInBothPlaces() {
    #expect(CaptureAge.isStale(PollDecision.staleAfter) == false)
    #expect(PollDecision.shouldPoll(enabled: true, anchorAge: PollDecision.staleAfter,
                                    lastPollAt: nil, now: now) == false)
    #expect(CaptureAge.isStale(PollDecision.staleAfter + 1))
    #expect(PollDecision.shouldPoll(enabled: true, anchorAge: PollDecision.staleAfter + 1,
                                    lastPollAt: nil, now: now))
}

/// A fresh anchor means a session is already publishing. Polling would spawn a
/// process to learn something already known.
@Test func neverPollsWhileTheAnchorIsStillFresh() {
    #expect(PollDecision.shouldPoll(enabled: true, anchorAge: 60, lastPollAt: nil, now: now)
            == false)
}

/// No anchor at all is the strongest case for polling, not the weakest.
@Test func pollsWhenThereIsNoAnchorAtAll() {
    #expect(PollDecision.shouldPoll(enabled: true, anchorAge: nil, lastPollAt: nil, now: now))
}

/// Backstop against a poll that fails to refresh anything: without this, a
/// permanently stale anchor would spawn a session every single scan tick.
@Test func respectsTheMinimumIntervalBetweenPolls() {
    let justPolled = now.addingTimeInterval(-60)
    #expect(PollDecision.shouldPoll(enabled: true, anchorAge: 9_999,
                                    lastPollAt: justPolled, now: now) == false)

    let longAgo = now.addingTimeInterval(-PollDecision.minimumInterval - 1)
    #expect(PollDecision.shouldPoll(enabled: true, anchorAge: 9_999,
                                    lastPollAt: longAgo, now: now))
}

/// The threshold has to sit above the staleness threshold the UI uses, or the
/// app would poll while still calling the figure live.
@Test func theStalenessThresholdsAgree() {
    #expect(PollDecision.staleAfter >= CaptureAge.stalenessThreshold)
}
