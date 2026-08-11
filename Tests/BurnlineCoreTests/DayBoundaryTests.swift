import Testing
import Foundation
@testable import BurnlineCore

private let chicago = TimeZone(identifier: "America/Chicago")!

private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = chicago
    return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

/// Sean's real window: Fri 02:00 -> Fri 02:00, so window-days end at 02:00
/// while calendar days end at midnight — two hours apart.
private func window(now: Date) -> Window {
    Window(start: date(2026, 8, 7, 2), end: date(2026, 8, 14, 2), now: now)
}

// MARK: - Window-aligned days

@Test func windowDayTakesTheNextBoundaryStrictlyAfterNow() {
    // Tue 14:42 is day 4.53; the next window-day boundary is day 5.
    let w = window(now: date(2026, 8, 11, 14, 42))
    #expect(abs(w.endOfDayPercent(boundary: .windowDay, timeZone: chicago) - 500.0 / 7) < 1e-6)
}

@Test func windowDayAdvancesWhenSittingExactlyOnABoundary() {
    // At exactly day 5.0 (Wed 02:00) that day has just begun, so the
    // allowance runs to day 6 — the same reading as "end of today" at midnight.
    let w = window(now: date(2026, 8, 12, 2))
    #expect(abs(w.dayIndex - 5) < 1e-6)
    #expect(abs(w.endOfDayPercent(boundary: .windowDay, timeZone: chicago) - 600.0 / 7) < 1e-6)
}

@Test func windowDayAtTheVeryStartAllowsOneDay() {
    let w = window(now: date(2026, 8, 7, 2))
    #expect(abs(w.endOfDayPercent(boundary: .windowDay, timeZone: chicago) - 100.0 / 7) < 1e-6)
}

@Test func windowDayNeverExceedsOneHundred() {
    #expect(window(now: date(2026, 8, 13, 20)).endOfDayPercent(boundary: .windowDay, timeZone: chicago) == 100)
    #expect(window(now: date(2026, 8, 14, 1)).endOfDayPercent(boundary: .windowDay, timeZone: chicago) == 100)
}

// MARK: - Calendar days

@Test func calendarDayRunsToLocalMidnight() {
    // Tue 14:42 -> midnight starting Wed 00:00, which is 4 days 22h into a
    // window that began Fri 02:00.
    let now = date(2026, 8, 11, 14, 42)
    let w = window(now: now)
    let midnight = date(2026, 8, 12, 0)
    let expected = midnight.timeIntervalSince(w.start) / w.totalDuration * 100
    #expect(abs(w.endOfDayPercent(boundary: .calendarDay, timeZone: chicago) - expected) < 1e-6)
}

@Test func theTwoBoundariesDisagreeByTheResetOffset() {
    // Window-day ends 02:00, calendar day ends 00:00 — the calendar target is
    // the earlier, hence smaller, of the two here.
    let w = window(now: date(2026, 8, 11, 14, 42))
    let byWindow = w.endOfDayPercent(boundary: .windowDay, timeZone: chicago)
    let byCalendar = w.endOfDayPercent(boundary: .calendarDay, timeZone: chicago)
    #expect(byCalendar < byWindow)
    // Exactly two hours of a 168-hour week apart.
    #expect(abs((byWindow - byCalendar) - (2.0 / 168 * 100)) < 1e-6)
}

@Test func calendarDayAdvancesWhenSittingExactlyOnMidnight() {
    let w = window(now: date(2026, 8, 12, 0))
    let nextMidnight = date(2026, 8, 13, 0)
    let expected = nextMidnight.timeIntervalSince(w.start) / w.totalDuration * 100
    #expect(abs(w.endOfDayPercent(boundary: .calendarDay, timeZone: chicago) - expected) < 1e-6)
}

@Test func calendarDayClampsWhenTheNextMidnightIsPastTheReset() {
    // Fri 01:00 sits in the last hour of the window; the next midnight is
    // Saturday, well past the Friday 02:00 reset, so the allowance clamps.
    let w = window(now: date(2026, 8, 14, 1))
    #expect(w.endOfDayPercent(boundary: .calendarDay, timeZone: chicago) == 100)
}

@Test func calendarDayDoesNotClampWhileMidnightStillPrecedesTheReset() {
    // Thu 23:00 -> Fri 00:00, which is two hours BEFORE the 02:00 reset.
    let w = window(now: date(2026, 8, 13, 23))
    let value = w.endOfDayPercent(boundary: .calendarDay, timeZone: chicago)
    #expect(abs(value - 166.0 / 168 * 100) < 1e-6)
    #expect(value < 100)
}

@Test func calendarDayHonoursTheGivenTimeZone() {
    let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    let w = window(now: date(2026, 8, 11, 14, 42))
    let chi = w.endOfDayPercent(boundary: .calendarDay, timeZone: chicago)
    let tky = w.endOfDayPercent(boundary: .calendarDay, timeZone: tokyo)
    #expect(chi != tky)
}

@Test func bothBoundariesAreAtOrAheadOfTheRealTimeTarget() {
    for hour in stride(from: 0, through: 160, by: 7) {
        let w = window(now: date(2026, 8, 7, 2).addingTimeInterval(Double(hour) * 3600))
        #expect(w.endOfDayPercent(boundary: .windowDay, timeZone: chicago) >= w.targetPercent - 1e-9)
        #expect(w.endOfDayPercent(boundary: .calendarDay, timeZone: chicago) >= w.targetPercent - 1e-9)
    }
}

// MARK: - Settings

@Test func dayBoundaryDefaultsToWindowDay() {
    #expect(BurnlineSettings.default.dayBoundary == .windowDay)
}

@Test func settingsWithoutADayBoundaryDecodeToWindowDay() throws {
    let json = #"""
    {"resetSchedule":{"weekday":5,"hour":9,"minute":0,"timeZoneIdentifier":"America/Chicago"},
     "weights":{"input":1,"cacheWrite":1.25,"cacheRead":0.1,"output":5,
                "modelMultipliers":[],"defaultMultiplier":1},
     "calibrationAnchors":[],"launchAtLogin":false,"targetMode":"endOfDay"}
    """#
    let decoded = try JSONDecoder().decode(BurnlineSettings.self, from: Data(json.utf8))
    #expect(decoded.dayBoundary == .windowDay)
    #expect(decoded.targetMode == .endOfDay)
}
