import Testing
import Foundation
@testable import BurnlineCore

private let chicago = TimeZone(identifier: "America/Chicago")!
private let utc = TimeZone(identifier: "UTC")!

// MARK: - The schedule as configured

/// The Settings fallback line. Four surfaces printed this reset four ways; this
/// is the one that had to change to match the rest, and the only one built from
/// the fields rather than from an observed instant.
@Test func theConfiguredScheduleNamesTheDayTheClockAndTheZone() {
    let schedule = ResetSchedule(weekday: 3, hour: 21, minute: 0, timeZone: chicago)

    #expect(schedule.description() == "Tuesday 9:00 PM (Central Time)")
}

/// 🔴 The zone is named in words, never as its database identifier.
/// `America/Chicago` is a row in tzdata, not a place a person says they are, and
/// it was rendering raw in the one sentence that had to explain a fallback to
/// somebody who had not asked for one.
@Test func theZoneIsNamedInWordsRatherThanAsATzdataIdentifier() {
    let schedule = ResetSchedule(weekday: 3, hour: 21, timeZone: chicago)

    #expect(!schedule.description().contains("America/Chicago"))
    #expect(schedule.description().contains("Central Time"))
}

@Test func middayAndMidnightAreNotBothTwelveAM() {
    let zone = TimeZone(identifier: "UTC")!
    #expect(ResetSchedule(weekday: 1, hour: 0, timeZone: zone).description()
                .hasPrefix("Sunday 12:00 AM"))
    #expect(ResetSchedule(weekday: 1, hour: 12, timeZone: zone).description()
                .hasPrefix("Sunday 12:00 PM"))
}

@Test func minutesAreZeroPaddedAndEveryWeekdayIsNamed() {
    #expect(ResetSchedule(weekday: 6, hour: 9, minute: 5, timeZone: utc).description()
                .hasPrefix("Friday 9:05 AM"))
    #expect(ResetSchedule(weekday: 7, hour: 23, minute: 59, timeZone: utc).description()
                .hasPrefix("Saturday 11:59 PM"))
}

/// The fields come from steppers with their own ranges, but `ResetSchedule` is
/// `Codable` and decodes from a settings file on disk — so out-of-range values
/// arrive from outside the steppers, and must not index off the end of the
/// weekday table.
@Test func fieldsFromOutsideTheStepperRangesDoNotTrap() {
    var schedule = ResetSchedule(weekday: 3, hour: 21, timeZone: utc)
    schedule.weekday = 99
    schedule.hour = -4
    schedule.minute = 800

    #expect(!schedule.description().isEmpty)
}
