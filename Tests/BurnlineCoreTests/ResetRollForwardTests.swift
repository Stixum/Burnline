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
/// dead reset forward in calendar weeks on the user's clock. No test had rolled
/// one across a DST change.
///
/// ⚠️ **This pins the app's rule, not Anthropic's.** Whether Anthropic's weekly
/// reset holds its local wall-clock time across DST (169 hours, as here) or
/// its UTC instant (168) had never been observed when this was written
/// (2026-10-25): the app was born in August. The first reset after
/// 2026-11-01 settles it. If `resets_at` moves from 07:00Z to 08:00Z the rule
/// is right; if it stays at 07:00Z, a dead capture rolls an hour off until the
/// next live one lands.
@Test func aDeadResetRolledAcrossTheEndOfDSTKeepsItsWallClockTime() {
    let dead = instant(2026, 10, 29, 7)      // Thu 2:00 AM CDT
    let now = instant(2026, 11, 3, 12)

    let window = SnapshotBuilder.windowFromReset(dead, now: now, timeZone: chicago)

    #expect(window.end == instant(2026, 11, 5, 8))   // Thu 2:00 AM CST
    #expect(window.start == dead)
    #expect(window.totalDuration == 169 * 3_600)
}

/// The same roll on a clock with no DST is exactly a week.
@Test func aDeadResetRolledOnAClockWithoutDSTIsExactlyAWeek() {
    let dead = instant(2026, 10, 29, 7)
    let now = instant(2026, 11, 3, 12)

    let window = SnapshotBuilder.windowFromReset(dead, now: now, timeZone: utc)

    #expect(window.end == instant(2026, 11, 5, 7))
    #expect(window.totalDuration == 168 * 3_600)
}

/// Several weeks dead rolls several weeks, and lands after `now`.
@Test func aResetSeveralWeeksDeadRollsUntilItIsAheadOfNow() {
    let dead = instant(2026, 10, 1, 7)
    let now = instant(2026, 10, 25, 12)

    let window = SnapshotBuilder.windowFromReset(dead, now: now, timeZone: chicago)

    #expect(window.end == instant(2026, 10, 29, 7))
    #expect(window.start <= now && now < window.end)
}
