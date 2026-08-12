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

/// Exactly at the threshold is not yet eligible — a strict `>`, matching
/// `CaptureAge.isStale`.
@Test func theBoundaryBelongsToNotPollingYet() {
    #expect(PollDecision.shouldPoll(enabled: true, anchorAge: PollDecision.staleAfter,
                                    lastPollAt: nil, now: now) == false)
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

/// Poll BEFORE the UI would call the figure stale.
///
/// The two thresholds were equal at first, so the anchor had to actually go
/// stale before anything refreshed it: the footer flipped to amber and the menu
/// bar grew a tilde for the ~30s the poll took, every hour, in normal operation.
/// With headroom the figure simply stays live, and those signals become what
/// they should be — evidence that the refresh itself failed.
@Test func pollsBeforeTheFigureWouldBeCalledStale() {
    #expect(PollDecision.staleAfter < CaptureAge.stalenessThreshold)

    let age = PollDecision.staleAfter + 1
    #expect(PollDecision.shouldPoll(enabled: true, anchorAge: age, lastPollAt: nil, now: now))
    #expect(CaptureAge.isStale(age) == false)
}

/// A failed poll must get another attempt before the figure goes visibly stale,
/// or the headroom above buys nothing.
@Test func aFailedPollRetriesBeforeTheFigureGoesStale() {
    #expect(PollDecision.staleAfter + PollDecision.minimumInterval
            <= CaptureAge.stalenessThreshold)
}
