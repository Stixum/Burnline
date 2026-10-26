import Testing
import Foundation
@testable import BurnlineCore

private let hour: TimeInterval = 3_600
private let day: TimeInterval = 86_400

/// A week ending `left` from now, with a projection of `projected` and, when
/// given, a re-grant opened `regrantAgo` before now.
private func snapshot(projected: Double?, elapsed: TimeInterval = 3 * day,
                      regrantAgo: TimeInterval? = nil) -> Snapshot {
    let now = Date()
    let start = now.addingTimeInterval(-elapsed)
    let window = Window(start: start, end: start.addingTimeInterval(7 * day), now: now)
    let regrant = regrantAgo.map {
        Snapshot.Regrant(startedAt: now.addingTimeInterval(-$0), startPercent: 0)
    }
    return Snapshot(window: window, targetPercent: 50, estimatedPercent: 40,
                    projectedPercent: projected, unitsInWindow: 0, calibrationAge: nil,
                    isScanning: false, regrant: regrant)
}

private func timeLeft(_ remaining: TimeInterval) -> String {
    let now = Date()
    let end = now.addingTimeInterval(remaining)
    return Window(start: end.addingTimeInterval(-7 * day), end: end, now: now).timeLeftDescription
}

// MARK: - Projection early in an allowance

/// 🔴 The real case: a re-grant at 3:06 PM on a Friday, and 21 hours later the
/// row said "over limit · 116% by reset" in red. Twenty-one hours of burn has
/// not seen a night, so it overstates the week; the number stays, the alarm
/// waits until the rate has a whole day behind it.
@Test func aProjectionOverTheLimitOnLessThanADayOfRateIsEarlyNotAnAlarm() {
    let early = snapshot(projected: 116, regrantAgo: 21 * hour)

    #expect(!early.projectionIsWarning)
    #expect(early.projectionDescription == "early · 116% by reset")
}

@Test func aProjectionOverTheLimitOnADayOfRateIsTheAlarm() {
    let settled = snapshot(projected: 116, regrantAgo: 25 * hour)

    #expect(settled.projectionIsWarning)
    #expect(settled.projectionDescription == "over limit · 116% by reset")
}

/// The same rule at the start of an ordinary week: the rate is measured from
/// the window's start when no re-grant is open.
@Test func theFirstDayOfAnOrdinaryWeekIsEarlyToo() {
    #expect(!snapshot(projected: 130, elapsed: 20 * hour).projectionIsWarning)
    #expect(snapshot(projected: 130, elapsed: 26 * hour).projectionIsWarning)
}

/// The basis is the epoch's, not the window's: three days into the week, a
/// re-grant two hours old has two hours of rate behind it.
@Test func theBasisIsTheRegrantNotTheWindow() {
    let regranted = snapshot(projected: 140, elapsed: 3 * day, regrantAgo: 2 * hour)

    #expect(regranted.projectionBasis == 2 * hour)
    #expect(!regranted.projectionIsWarning)
}

/// Under the limit there is nothing to soften, so the row is unchanged.
@Test func anEarlyProjectionUnderTheLimitReadsAsItAlwaysDid() {
    #expect(snapshot(projected: 60, elapsed: 4 * hour).projectionDescription == "60% by reset")
    #expect(snapshot(projected: nil, elapsed: 4 * hour).projectionDescription == "—")
}

/// Never wider than the row's worst case, `over limit · 999% by reset`.
@Test func theEarlyRowIsNoWiderThanTheAlarmRow() {
    let early = snapshot(projected: 999, regrantAgo: 1 * hour).projectionDescription
    #expect(early.count <= "over limit · 999% by reset".count)
}

// MARK: - Time left

/// 🔴 Under an hour the row said "0h" — a reset still 40 minutes away read as
/// one already happening.
@Test func underAnHourTheRowCountsMinutes() {
    #expect(timeLeft(40 * 60 + 5) == "40m")
    #expect(timeLeft(59 * 60 + 59) == "59m")
}

/// Under a day, hours alone threw away up to 59 minutes of a short count.
@Test func underADayTheRowShowsHoursAndMinutes() {
    #expect(timeLeft(5 * hour + 20 * 60 + 5) == "5h 20m")
    #expect(timeLeft(1 * hour + 30) == "1h 0m")
}

@Test func overADayTheRowIsUnchanged() {
    #expect(timeLeft(3 * day + 6 * hour + 30 * 60) == "3d 6h")
}

/// The last minute is not "0m", which reads as passed.
@Test func theLastMinuteIsLessThanAMinuteNotZero() {
    #expect(timeLeft(30) == "<1m")
    #expect(timeLeft(0) == "<1m")
}
