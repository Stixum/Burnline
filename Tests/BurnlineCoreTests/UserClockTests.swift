import Testing
import Foundation
@testable import BurnlineCore

private let chicago = TimeZone(identifier: "America/Chicago")!
private let utc = TimeZone(identifier: "UTC")!

/// Tue 2026-08-11 21:00 America/Chicago, Wed 02:00 UTC.
private let ninePMChicago = Date(timeIntervalSince1970: 1_786_500_000)

/// What Anthropic actually reports: `resets_at` half a second short of the
/// hour (06:59:59.522 UTC was the real one).
private let halfASecondEarly: TimeInterval = -0.478

private func snapshot(windowEnd: Date, clock: TimeZone) -> Snapshot {
    let window = Window(start: windowEnd.addingTimeInterval(-7 * 86_400), end: windowEnd,
                        now: windowEnd.addingTimeInterval(-86_400))
    return Snapshot(window: window, targetPercent: 50, estimatedPercent: nil,
                    projectedPercent: nil, unitsInWindow: 0, calibrationAge: nil,
                    isScanning: false, clockTimeZoneIdentifier: clock.identifier)
}

/// Any zone the suite is not running in, so a test about "the machine's zone,
/// not the saved one" cannot pass by the two happening to agree.
private let elsewhere: TimeZone = {
    let candidates = ["Pacific/Kiritimati", "Pacific/Pago_Pago"]
    let pick = candidates.first { $0 != TimeZone.current.identifier }!
    return TimeZone(identifier: pick)!
}()

// MARK: - The zone is the machine's, now

/// 🔴 The saved schedule's zone was stamped once, at first launch. Read on it,
/// "midnight" and the Resets row stayed on the first launch's clock wherever
/// the user went next. The schedule keeps its zone for what it is — the
/// fallback the user typed — and everything the user reads is on their clock.
@Test func theSnapshotIsOnTheMachinesClockNotTheZoneSavedAtFirstLaunch() {
    var settings = BurnlineSettings.default
    settings.resetSchedule = ResetSchedule(weekday: 5, hour: 9, timeZone: elsewhere)

    let built = SnapshotBuilder.build(cache: ScanCache(), settings: settings,
                                      now: Date(), isScanning: false)

    #expect(built.clockTimeZoneIdentifier == TimeZone.current.identifier)
    #expect(built.clockTimeZoneIdentifier != elsewhere.identifier)
}

/// The same instant is a different weekday on two clocks, so the zone the
/// snapshot carries is the one the row is read on.
@Test func theResetIsReadOnTheSnapshotsClock() {
    #expect(snapshot(windowEnd: ninePMChicago, clock: chicago).resetDescription(.full)
            == "Tuesday 9:00 PM")
    #expect(snapshot(windowEnd: ninePMChicago, clock: utc).resetDescription(.full)
            == "Wednesday 2:00 AM")
}

// MARK: - To the minute

/// 🔴 `h:mm` truncates, so a reset half a second short of the hour printed as
/// `1:59 AM` everywhere while the archive said 02:00.
@Test func aResetHalfASecondShortOfTheHourIsShownOnTheHour() {
    let early = snapshot(windowEnd: ninePMChicago.addingTimeInterval(halfASecondEarly),
                         clock: chicago)

    #expect(early.resetDescription(.full) == "Tuesday 9:00 PM")
    #expect(early.resetDescription(.abbreviated) == "Tue 9:00 PM")
    #expect(early.resetDescription(.clock) == "9:00 PM")
}

/// Nearest, not up: a reset genuinely past the half-minute is the next minute,
/// and one just after the hour stays on it.
@Test func theResetRoundsToTheNearestMinute() {
    let justAfter = snapshot(windowEnd: ninePMChicago.addingTimeInterval(29), clock: chicago)
    let pastHalf = snapshot(windowEnd: ninePMChicago.addingTimeInterval(31), clock: chicago)

    #expect(justAfter.resetDescription(.clock) == "9:00 PM")
    #expect(pastHalf.resetDescription(.clock) == "9:01 PM")
}

/// Rounding across midnight moves the weekday too, which only happens if the
/// whole instant is rounded rather than the minute field patched.
@Test func roundingAcrossMidnightMovesTheWeekday() {
    let midnightUTC = ninePMChicago.addingTimeInterval(-2 * 3_600)   // Wed 00:00 UTC
    let early = snapshot(windowEnd: midnightUTC.addingTimeInterval(halfASecondEarly), clock: utc)

    #expect(early.resetDescription(.full) == "Wednesday 12:00 AM")
}

// MARK: - Midnight

/// The day-boundary sentence drops its contrast when the reset is at midnight,
/// because the two options are then identical. It compared the formatted clock
/// to `"12:00 AM"`, so a real midnight reset reported half a second early read
/// as `11:59 PM` and invented a difference.
@Test func aMidnightResetIsRecognisedWhenReportedHalfASecondEarly() {
    let midnightUTC = ninePMChicago.addingTimeInterval(-2 * 3_600)

    #expect(snapshot(windowEnd: midnightUTC.addingTimeInterval(halfASecondEarly), clock: utc)
                .resetFallsAtMidnight)
    #expect(snapshot(windowEnd: midnightUTC, clock: utc).resetFallsAtMidnight)
}

/// Midnight on whose clock: the user's. The same instant is 7 PM in Chicago.
@Test func midnightIsJudgedOnTheSnapshotsClock() {
    let midnightUTC = ninePMChicago.addingTimeInterval(-2 * 3_600)

    #expect(!snapshot(windowEnd: midnightUTC, clock: chicago).resetFallsAtMidnight)
    #expect(!snapshot(windowEnd: ninePMChicago, clock: chicago).resetFallsAtMidnight)
}

/// `en_US_POSIX`, for the reason `Snapshot.Regrant.rowValue` records: a custom
/// `dateFormat` otherwise picks up the user's locale symbols and prints things
/// like `14:14 PM`. Every format is 12-hour and carries its meridiem.
@Test func everyResetFormatCarriesAMeridiemRatherThanATwentyFourHourClock() {
    let row = snapshot(windowEnd: ninePMChicago, clock: chicago)

    for format in ResetSchedule.Format.allCases {
        let text = row.resetDescription(format)
        #expect(text.contains("PM"))
        #expect(!text.contains("21:"))
    }
}
