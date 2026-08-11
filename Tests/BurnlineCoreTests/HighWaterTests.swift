import Testing
import Foundation
@testable import BurnlineCore

private let reset: TimeInterval = 1_786_690_800

private func capture(_ percent: Double, at captured: TimeInterval,
                     resetsAt: TimeInterval = reset,
                     fiveHour: RateLimitCapture.Reading? = nil) -> RateLimitCapture {
    RateLimitCapture(version: 1, capturedAt: captured,
                     sevenDay: .init(usedPercent: percent, resetsAt: resetsAt),
                     fiveHour: fiveHour)
}

/// Several Claude Code sessions run the statusline script concurrently, each on
/// its own timer, each carrying the rate_limits block from its own last API
/// response — and they all overwrite the same file blind. An idle session
/// therefore replaces a fresh reading with a stale one twice a minute.
@Test func aLowerReadingInsideTheSameWindowIsRejectedAsStale() {
    let fresh = capture(65, at: 1_000)
    let (_, mark) = RateLimitHighWater.reconcile(fresh, against: .empty)

    let stale = capture(64, at: 2_000)
    let (result, _) = RateLimitHighWater.reconcile(stale, against: mark)

    #expect(result.sevenDay.usedPercent == 65)
}

/// Rejecting the value must also reject its timestamp, or the popover reports a
/// three-minute-old figure as having just landed.
@Test func aRejectedReadingDoesNotRefreshTheCaptureAge() {
    let fresh = capture(65, at: 1_000)
    let (_, mark) = RateLimitHighWater.reconcile(fresh, against: .empty)

    let (result, _) = RateLimitHighWater.reconcile(capture(64, at: 9_999), against: mark)

    #expect(result.capturedAt == 1_000)
}

@Test func aHigherReadingIsAdoptedAndBecomesTheNewMark() {
    let (_, mark) = RateLimitHighWater.reconcile(capture(64, at: 1_000), against: .empty)
    let (result, updated) = RateLimitHighWater.reconcile(capture(70, at: 2_000), against: mark)

    #expect(result.sevenDay.usedPercent == 70)
    #expect(result.capturedAt == 2_000)
    #expect(updated.sevenDay?.usedPercent == 70)
}

/// Re-reporting the same percentage is a fresh confirmation of it, so the age
/// must move even though the value doesn't.
@Test func anEqualReadingRefreshesTheAge() {
    let (_, mark) = RateLimitHighWater.reconcile(capture(64, at: 1_000), against: .empty)
    let (result, _) = RateLimitHighWater.reconcile(capture(64, at: 5_000), against: mark)

    #expect(result.capturedAt == 5_000)
}

/// The mark is only meaningful inside the window it was taken in. A new window
/// starts from nothing, or the previous week's high would pin the new one.
@Test func aNewWindowDiscardsTheEarlierMark() {
    let (_, mark) = RateLimitHighWater.reconcile(capture(90, at: 1_000), against: .empty)

    let nextWindow = capture(4, at: 2_000, resetsAt: reset + 7 * 86_400)
    let (result, updated) = RateLimitHighWater.reconcile(nextWindow, against: mark)

    #expect(result.sevenDay.usedPercent == 4)
    #expect(updated.sevenDay?.resetsAt == reset + 7 * 86_400)
}

// MARK: - The 5-hour reading has the same problem and its own window

@Test func theFiveHourReadingIsReconciledIndependently() {
    let fiveReset: TimeInterval = 1_786_491_600
    let high = capture(64, at: 1_000,
                       fiveHour: .init(usedPercent: 30, resetsAt: fiveReset))
    let (_, mark) = RateLimitHighWater.reconcile(high, against: .empty)

    let low = capture(64, at: 2_000,
                      fiveHour: .init(usedPercent: 3, resetsAt: fiveReset))
    let (result, _) = RateLimitHighWater.reconcile(low, against: mark)

    #expect(result.fiveHour?.usedPercent == 30)
}

@Test func aFiveHourWindowThatHasRolledStartsOver() {
    let old: TimeInterval = 1_786_491_600
    let high = capture(64, at: 1_000, fiveHour: .init(usedPercent: 90, resetsAt: old))
    let (_, mark) = RateLimitHighWater.reconcile(high, against: .empty)

    let rolled = capture(64, at: 2_000,
                         fiveHour: .init(usedPercent: 2, resetsAt: old + 5 * 3_600))
    let (result, _) = RateLimitHighWater.reconcile(rolled, against: mark)

    #expect(result.fiveHour?.usedPercent == 2)
}

/// A capture with no five-hour block must not resurrect an earlier one.
@Test func anAbsentFiveHourReadingStaysAbsent() {
    let high = capture(64, at: 1_000,
                       fiveHour: .init(usedPercent: 30, resetsAt: 1_786_491_600))
    let (_, mark) = RateLimitHighWater.reconcile(high, against: .empty)

    let (result, _) = RateLimitHighWater.reconcile(capture(64, at: 2_000), against: mark)

    #expect(result.fiveHour == nil)
}
