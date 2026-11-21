import Testing
import Foundation
@testable import BurnlineCore

private let chicago = TimeZone(identifier: "America/Chicago")!
private let utc = TimeZone(identifier: "UTC")!

private func instant(_ y: Int, _ mo: Int, _ d: Int, _ h: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utc
    return calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h))!
}

/// A capture can outlive its own window, and `SnapshotBuilder` then rolls the
/// dead reset forward in 168-hour steps.
///
/// **Anthropic's reset is fixed in UTC.** Settled on 2026-11-06, the first
/// reset after the US clock change: `resets_at` stayed at 07:00Z, so on a
/// Chicago clock it moved from Fri 2:00 AM CDT to Fri 1:00 AM CST and the week
/// was 168 hours. The app used to step by calendar days and keep the
/// wall-clock time (169 hours here), which rolled a dead capture an hour late.
/// One account, one autumn transition.
@Test func aDeadResetRolledAcrossTheEndOfDSTKeepsItsUTCInstant() {
    let dead = instant(2026, 10, 30, 7)      // Fri 2:00 AM CDT, as observed
    let now = instant(2026, 11, 3, 12)

    let window = SnapshotBuilder.windowFromReset(dead, now: now)

    #expect(window.end == instant(2026, 11, 6, 7))   // Fri 1:00 AM CST, as observed
    #expect(window.start == dead)
    #expect(window.totalDuration == 168 * 3_600)
    #expect(hourInChicago(window.start) == 2)
    #expect(hourInChicago(window.end) == 1)          // the control: the clock did change
}

/// The spring transition, by the same rule: not yet observed.
@Test func aDeadResetRolledAcrossTheStartOfDSTKeepsItsUTCInstant() {
    let dead = instant(2027, 3, 12, 7)       // Fri 1:00 AM CST
    let now = instant(2027, 3, 16, 12)       // clocks went forward on the 14th

    let window = SnapshotBuilder.windowFromReset(dead, now: now)

    #expect(window.end == instant(2027, 3, 19, 7))   // Fri 2:00 AM CDT
    #expect(window.totalDuration == 168 * 3_600)
    #expect(hourInChicago(window.end) == 2)
}

/// 🔴 The live case, and the one that was wrong for a whole week: a capture
/// whose reset is still ahead. The window starts 168 hours before it, not
/// seven calendar days — which in the transition week was 06:00Z, an hour
/// before the previous reset, and counted that hour's tokens in this window.
@Test func theTransitionWeekStartsAtThePreviousResetNotAnHourBeforeIt() {
    let reset = instant(2026, 11, 6, 7)
    let now = instant(2026, 11, 3, 12)

    let window = SnapshotBuilder.windowFromReset(reset, now: now)

    #expect(window.end == reset)
    #expect(window.start == instant(2026, 10, 30, 7))
}

/// A reset landing exactly on `now` has passed: the new window is open.
@Test func aResetExactlyNowOpensTheNextWindow() {
    let reset = instant(2026, 11, 6, 7)

    let window = SnapshotBuilder.windowFromReset(reset, now: reset)

    #expect(window.start == reset)
    #expect(window.end == instant(2026, 11, 13, 7))
}

/// Several weeks dead rolls several weeks, and lands after `now`.
@Test func aResetSeveralWeeksDeadRollsUntilItIsAheadOfNow() {
    let dead = instant(2026, 10, 1, 7)
    let now = instant(2026, 10, 25, 12)

    let window = SnapshotBuilder.windowFromReset(dead, now: now)

    #expect(window.end == instant(2026, 10, 29, 7))
    #expect(window.start <= now && now < window.end)
}

private func hourInChicago(_ date: Date) -> Int {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = chicago
    return calendar.component(.hour, from: date)
}
