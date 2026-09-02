import Testing
import Foundation
@testable import BurnlineCore

private let chicago = TimeZone(identifier: "America/Chicago")!
private let utc = TimeZone(identifier: "UTC")!

/// Tue 2026-08-11 21:00 America/Chicago — a reset instant, fixed so the
/// assertions do not depend on when the suite runs.
private let resetInstant = Date(timeIntervalSince1970: 1_786_500_000)

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

// MARK: - An observed reset instant

/// The three view-body formatters this replaced: a full weekday for the Settings
/// sentence, an abbreviated one for the 272pt popover row, and the clock alone
/// inside the day-boundary explanation.
@Test func oneInstantRendersAtThreeWidths() {
    let schedule = ResetSchedule(weekday: 3, hour: 21, timeZone: chicago)

    #expect(schedule.description(of: resetInstant) == "Tuesday 9:00 PM")
    #expect(schedule.description(of: resetInstant, .abbreviated) == "Tue 9:00 PM")
    #expect(schedule.description(of: resetInstant, .clock) == "9:00 PM")
}

/// 🔴 The schedule's own zone, not the machine's. Once Claude Code reports a
/// real `resets_at` the fields above are unused — but the zone still decides
/// which clock the user is being shown, and the same instant is a different
/// weekday in two of them.
@Test func theInstantIsReadOnTheSchedulesOwnClock() {
    let central = ResetSchedule(weekday: 3, hour: 21, timeZone: chicago)
    let universal = ResetSchedule(weekday: 3, hour: 21, timeZone: utc)

    #expect(central.description(of: resetInstant) == "Tuesday 9:00 PM")
    #expect(universal.description(of: resetInstant) == "Wednesday 2:00 AM")
}

/// `en_US_POSIX`, for the reason `Snapshot.Regrant.rowValue` records: a custom
/// `dateFormat` otherwise picks up the user's locale symbols and prints things
/// like `14:14 PM`. Every format here is 12-hour and must carry its meridiem.
@Test func everyFormatCarriesAMeridiemRatherThanATwentyFourHourClock() {
    let schedule = ResetSchedule(weekday: 3, hour: 21, timeZone: chicago)

    for format in ResetSchedule.Format.allCases {
        let text = schedule.description(of: resetInstant, format)
        #expect(text.contains("PM"))
        #expect(!text.contains("21:"))
    }
}
