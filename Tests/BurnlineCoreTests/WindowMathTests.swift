import Testing
import Foundation
@testable import BurnlineCore

private let chicago = TimeZone(identifier: "America/Chicago")!

private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0,
                  zone: TimeZone = chicago) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

private func hour(of instant: Date, zone: TimeZone = chicago) -> Int {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar.component(.hour, from: instant)
}

private func weekday(of instant: Date, zone: TimeZone = chicago) -> Int {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar.component(.weekday, from: instant)
}

/// Thursday 09:00 America/Chicago. Calendar weekday 5 == Thursday.
private let thursday9am = ResetSchedule(weekday: 5, hour: 9, minute: 0, timeZone: chicago)

@Test func windowStartsOnConfiguredWeekdayAndHour() {
    // 2026-08-11 is a Tuesday; any mid-week instant will do.
    let window = WindowMath.window(for: thursday9am, now: date(2026, 8, 11, 14, 30))
    #expect(weekday(of: window.start) == 5)
    #expect(hour(of: window.start) == 9)
    #expect(window.start <= window.now)
    #expect(window.end > window.now)
}

@Test func dayFiveIsSeventyOnePercent() {
    let window = WindowMath.window(for: thursday9am, now: date(2026, 8, 11, 14, 30))
    // Re-anchor: exactly five days after that window's own start.
    let fiveDaysIn = window.start.addingTimeInterval(5 * 86_400)
    let atDayFive = WindowMath.window(for: thursday9am, now: fiveDaysIn)
    #expect(atDayFive.start == window.start)
    #expect(abs(atDayFive.targetPercent - 71.428571) < 1e-4)
    #expect(abs(atDayFive.dayIndex - 5.0) < 1e-6)
}

@Test func exactResetInstantStartsTheNewWindow() {
    let reset = date(2026, 8, 13, 9, 0)          // a Thursday at 09:00
    let window = WindowMath.window(for: thursday9am, now: reset)
    #expect(window.start == reset)
    #expect(window.elapsedFraction == 0)
}

@Test func oneSecondBeforeResetIsEndOfTheOldWindow() {
    let reset = date(2026, 8, 13, 9, 0)
    let window = WindowMath.window(for: thursday9am, now: reset.addingTimeInterval(-1))
    #expect(window.end == reset)
    #expect(window.elapsedFraction > 0.999)
    #expect(window.elapsedFraction < 1.0)
}

@Test func springForwardWeekIs167HoursAndKeepsWallClockTime() {
    // US DST begins 2026-03-08. Sit inside the window that contains it.
    let window = WindowMath.window(for: thursday9am, now: date(2026, 3, 8, 12, 0))
    #expect(hour(of: window.start) == 9)
    #expect(hour(of: window.end) == 9)
    #expect(window.totalDuration == 167 * 3600)
}

@Test func fallBackWeekIs169HoursAndKeepsWallClockTime() {
    // US DST ends 2026-11-01.
    let window = WindowMath.window(for: thursday9am, now: date(2026, 11, 1, 12, 0))
    #expect(hour(of: window.start) == 9)
    #expect(hour(of: window.end) == 9)
    #expect(window.totalDuration == 169 * 3600)
}

@Test func scheduleTimeZoneIsIndependentOfSystemTimeZone() {
    let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    let schedule = ResetSchedule(weekday: 2, hour: 6, minute: 30, timeZone: tokyo)
    let window = WindowMath.window(for: schedule, now: date(2026, 8, 11, 14, 30))
    #expect(weekday(of: window.start, zone: tokyo) == 2)
    #expect(hour(of: window.start, zone: tokyo) == 6)
}

@Test func windowIsAlwaysSevenCalendarDays() {
    let window = WindowMath.window(for: thursday9am, now: date(2026, 6, 15, 3, 0))
    #expect(window.totalDuration == 168 * 3600)   // ordinary week
}
