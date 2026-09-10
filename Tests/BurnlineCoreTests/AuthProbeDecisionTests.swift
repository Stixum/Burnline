import Testing
import Foundation
@testable import BurnlineCore

// When Burnline is allowed to spawn `claude auth status`.
//
// The cost is not the 0.17s — it is that `rebuild()` ticks every 10 seconds, so
// any rule that forgets a floor spawns six processes a minute forever.

private let now = Date(timeIntervalSince1970: 1_000_000)
private let longAgo = now.addingTimeInterval(-AuthProbeDecision.minimumInterval - 1)
private let justNow = now.addingTimeInterval(-5)

@Test func probesAtLaunch() {
    #expect(AuthProbeDecision.shouldProbe(anchorAge: 0, lastProbeAt: nil,
                                          isBlocked: false, now: now))
}

/// A floor still applies while blocked — the rebuild timer ticks every 10s and
/// must not spawn six processes a minute.
@Test func neverProbesTwiceInsideTheBlockedInterval() {
    let justProbed = now.addingTimeInterval(-(AuthProbeDecision.blockedInterval - 1))
    #expect(AuthProbeDecision.shouldProbe(anchorAge: nil, lastProbeAt: justProbed,
                                          isBlocked: true, now: now) == false)
}

/// 🔴 **The defect this constant was added for, asserted directly.** A user who
/// clicks `Sign in…`, signs in, and comes back must not be told they are signed
/// out because a cadence sized for an idle machine has not elapsed. Blocked and
/// healthy do NOT share a floor.
@Test func aBlockedMachineRechecksFarSoonerThanAHealthyOne() {
    let aMinuteAgo = now.addingTimeInterval(-AuthProbeDecision.blockedInterval)
    #expect(AuthProbeDecision.shouldProbe(anchorAge: nil, lastProbeAt: aMinuteAgo,
                                          isBlocked: true, now: now),
            "a standing block rechecks on the blocked cadence")
    #expect(AuthProbeDecision.shouldProbe(anchorAge: nil, lastProbeAt: aMinuteAgo,
                                          isBlocked: false, now: now) == false,
            "a healthy machine still waits out the long floor")
    #expect(AuthProbeDecision.blockedInterval < AuthProbeDecision.minimumInterval)
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
