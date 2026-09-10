import Testing
import Foundation
@testable import BurnlineCore

// When Burnline is allowed to spawn `claude auth status`.
//
// The cost is not the 0.17s — it is that `rebuild()` ticks every 10 seconds, so
// any rule that forgets a floor spawns six processes a minute forever.

private let now = Date(timeIntervalSince1970: 1_000_000)
private let justNow = now.addingTimeInterval(-60)
private let longAgo = now.addingTimeInterval(-AuthProbeDecision.minimumInterval - 1)

@Test func probesAtLaunch() {
    #expect(AuthProbeDecision.shouldProbe(anchorAge: 0, lastProbeAt: nil,
                                          isBlocked: false, now: now))
}

/// The floor, and it outranks every other trigger — including a standing block.
@Test func neverProbesTwiceInsideTheMinimumInterval() {
    #expect(AuthProbeDecision.shouldProbe(anchorAge: nil, lastProbeAt: justNow,
                                          isBlocked: true, now: now) == false)
}

/// A fresh anchor means something is publishing, which is its own answer.
@Test func doesNotProbeWhileTheAnchorIsFresh() {
    #expect(AuthProbeDecision.shouldProbe(anchorAge: 60, lastProbeAt: longAgo,
                                          isBlocked: false, now: now) == false)
}

@Test func probesOnceTheAnchorHasGoneStale() {
    #expect(AuthProbeDecision.shouldProbe(anchorAge: CaptureAge.stalenessThreshold + 1,
                                          lastProbeAt: longAgo, isBlocked: false, now: now))
}

/// No anchor at all is the strongest symptom, not the weakest.
@Test func probesWhenThereIsNoAnchorAtAll() {
    #expect(AuthProbeDecision.shouldProbe(anchorAge: nil, lastProbeAt: longAgo,
                                          isBlocked: false, now: now))
}

/// 🔴 The recovery path, and the reason this rule cannot be folded into
/// staleness. Every block gates polling, so a poll can never be the proof — and
/// a user whose sessions publish no captures has nothing else that could reopen
/// it. A block must keep asking even when the anchor looks fine.
@Test func keepsProbingWhileBlockedEvenWithAFreshAnchor() {
    #expect(AuthProbeDecision.shouldProbe(anchorAge: 60, lastProbeAt: longAgo,
                                          isBlocked: true, now: now))
}
