import Testing
import Foundation
@testable import BurnlineCore

// When an auth block is allowed to say anything, and what it silences when it
// does.
//
// Both rules exist because of pictures that contradict themselves: a red "signed
// out" banner beside a green `Live · 30s ago`, and a banner telling the user to
// open a terminal session directly above one telling them a terminal session is
// the remedy — while the CLI would land them on a login picker.

private func snapshot(source: UsageSource, block: AuthBlock.Kind?) -> Snapshot {
    let start = Date(timeIntervalSince1970: 0)
    let window = Window(start: start, end: start.addingTimeInterval(7 * 86_400),
                        now: start.addingTimeInterval(86_400))
    return Snapshot(window: window, targetPercent: 14, estimatedPercent: 10,
                    projectedPercent: nil, unitsInWindow: 0, calibrationAge: nil,
                    source: source, isScanning: false,
                    authBlock: block.map { AuthBlock(kind: $0, detectedAt: Date()) })
}

private var fresh: UsageSource { .live(capturedAt: Date().addingTimeInterval(-30)) }
private var stale: UsageSource { .live(capturedAt: Date().addingTimeInterval(-7_200)) }

// MARK: - When a block surfaces

/// No anchor at all is the strongest case for explaining why, not the weakest —
/// and it is the state a blocked machine settles into once the window rolls.
@Test func aBlockSurfacesWhenThereIsNoAnchor() {
    #expect(snapshot(source: .paceOnly, block: .signedOut).isAuthBlocked)
}

/// 🔴 The self-contradicting picture. The utilization cache is throttled to five
/// minutes, so a poll can legitimately refresh nothing and set a block seconds
/// after a capture landed. Saying "stopped updating" over a 30-second-old
/// reading is the failure this feature exists to remove.
@Test func aBlockStaysSilentWhileTheAnchorIsFresh() {
    let live = snapshot(source: fresh, block: .signedOut)
    #expect(live.visibleAuthBlock == nil)
    #expect(live.isAuthBlocked == false)
    #expect(live.authBlock != nil, "the block is still held — only its rendering is suppressed")
}

@Test func aBlockSurfacesOnceTheAnchorHasGoneStale() {
    #expect(snapshot(source: stale, block: .signedOut).isAuthBlocked)
}

@Test func noBlockMeansNothingToSurface() {
    #expect(snapshot(source: stale, block: nil).visibleAuthBlock == nil)
}

// MARK: - What a block silences

/// The ordinary staleness copy names two remedies — a terminal session, or
/// Refresh now. While a block stands both are dead: the session lands on the
/// login picker, and Refresh is gated by `ClaudeAuthStatus.blocksPolling`.
@Test func aBlockSilencesTheCarriedForwardExplanation() {
    #expect(snapshot(source: stale, block: .signedOut).scarcityExplanation == nil)
}

/// ⚠️ The other direction, or the rule would be satisfied by never showing the
/// explanation at all.
@Test func aStaleAnchorWithNoBlockStillExplainsItself() {
    let explanation = snapshot(source: stale, block: nil).scarcityExplanation
    #expect(explanation != nil)
    #expect(explanation?.contains("Refresh now") == true)
}

/// A suppressed block silences nothing — there is nothing to silence, because a
/// fresh anchor produces no explanation either.
@Test func aFreshAnchorHasNothingToSayEitherWay() {
    #expect(snapshot(source: fresh, block: .signedOut).scarcityExplanation == nil)
    #expect(snapshot(source: fresh, block: nil).scarcityExplanation == nil)
}
