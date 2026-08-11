import Testing
import Foundation
@testable import BurnlineCore

private let week: TimeInterval = 7 * 86_400
private let start = Date(timeIntervalSince1970: 1_800_000_000)

private func window(dayIndex: Double) -> Window {
    Window(start: start, end: start.addingTimeInterval(week),
           now: start.addingTimeInterval(dayIndex * 86_400))
}

// MARK: - End-of-day target

@Test func endOfDayRoundsUpToTheNextWholeWindowDay() {
    // Day 4.53 -> you may reach day 5 by the time today ends -> 5/7.
    #expect(abs(window(dayIndex: 4.53).endOfDayPercent - 500.0 / 7) < 1e-6)
}

@Test func endOfDayIsAlwaysAtOrAheadOfRealTime() {
    for day in stride(from: 0.0, through: 7.0, by: 0.37) {
        let w = window(dayIndex: day)
        #expect(w.endOfDayPercent >= w.targetPercent - 1e-9)
    }
}

@Test func exactlyOnADayBoundaryDoesNotJumpAWholeDayAhead() {
    // At exactly day 5.0 the day just ended; the allowance is 5/7, not 6/7.
    let w = window(dayIndex: 5.0)
    #expect(abs(w.endOfDayPercent - 500.0 / 7) < 1e-6)
    #expect(abs(w.targetPercent - 500.0 / 7) < 1e-6)
}

@Test func endOfDayNeverExceedsOneHundred() {
    #expect(window(dayIndex: 6.9).endOfDayPercent == 100)
    #expect(window(dayIndex: 7.0).endOfDayPercent == 100)
}

@Test func firstDayOfTheWindowAllowsOneSeventh() {
    #expect(abs(window(dayIndex: 0.2).endOfDayPercent - 100.0 / 7) < 1e-6)
}

@Test func atTheVeryStartTheAllowanceIsStillOneDay() {
    // Zero elapsed: nothing spent yet, but today's budget exists.
    #expect(abs(window(dayIndex: 0).endOfDayPercent - 100.0 / 7) < 1e-6)
}

// MARK: - Which target the menu bar uses

@Test func snapshotExposesBothTargets() {
    let w = window(dayIndex: 4.53)
    let snapshot = Snapshot(window: w, targetPercent: w.targetPercent, estimatedPercent: 64,
                            projectedPercent: nil, unitsInWindow: 0, calibrationAge: nil,
                            isScanning: false)
    #expect(abs(snapshot.targetPercent - w.targetPercent) < 1e-9)
    #expect(abs(snapshot.endOfDayPercent - w.endOfDayPercent) < 1e-9)
}

@Test func realTimeModeSelectsTheContinuousTarget() {
    let w = window(dayIndex: 4.53)
    let snapshot = Snapshot(window: w, targetPercent: w.targetPercent, estimatedPercent: 64,
                            projectedPercent: nil, unitsInWindow: 0, calibrationAge: nil,
                            isScanning: false)
    #expect(abs(snapshot.activeTarget(.realTime) - w.targetPercent) < 1e-9)
}

@Test func endOfDayModeSelectsTheRoundedUpTarget() {
    let w = window(dayIndex: 4.53)
    let snapshot = Snapshot(window: w, targetPercent: w.targetPercent, estimatedPercent: 64,
                            projectedPercent: nil, unitsInWindow: 0, calibrationAge: nil,
                            isScanning: false)
    #expect(abs(snapshot.activeTarget(.endOfDay) - 500.0 / 7) < 1e-9)
}

@Test func deltaFollowsTheSelectedMode() {
    let w = window(dayIndex: 4.53)                       // realtime 64.71, eod 71.43
    let snapshot = Snapshot(window: w, targetPercent: w.targetPercent, estimatedPercent: 64,
                            projectedPercent: nil, unitsInWindow: 0, calibrationAge: nil,
                            isScanning: false)
    #expect(abs(snapshot.delta(.realTime)! - (w.targetPercent - 64)) < 1e-9)
    #expect(abs(snapshot.delta(.endOfDay)! - (500.0 / 7 - 64)) < 1e-9)
    // Under budget against end-of-day, only just under against real time.
    #expect(snapshot.isUnder(.endOfDay) == true)
}

@Test func deltaIsNilWithoutAnEstimateInEitherMode() {
    let w = window(dayIndex: 4.53)
    let snapshot = Snapshot(window: w, targetPercent: w.targetPercent, estimatedPercent: nil,
                            projectedPercent: nil, unitsInWindow: 0, calibrationAge: nil,
                            isScanning: false)
    #expect(snapshot.delta(.realTime) == nil)
    #expect(snapshot.delta(.endOfDay) == nil)
    #expect(snapshot.isUnder(.realTime) == nil)
}

// MARK: - Menu bar rendering

@Test func menuBarUsesTheSelectedTarget() {
    let w = window(dayIndex: 4.53)
    let snapshot = Snapshot(window: w, targetPercent: w.targetPercent, estimatedPercent: 64.1,
                            projectedPercent: nil, unitsInWindow: 0, calibrationAge: nil,
                            isScanning: false)
    #expect(MenuBarFormatter.text(for: snapshot, mode: .realTime) == "64/65")
    #expect(MenuBarFormatter.text(for: snapshot, mode: .endOfDay) == "64/71")
}

@Test func uncalibratedMenuBarStillHonoursTheMode() {
    let w = window(dayIndex: 4.53)
    let snapshot = Snapshot(window: w, targetPercent: w.targetPercent, estimatedPercent: nil,
                            projectedPercent: nil, unitsInWindow: 0, calibrationAge: nil,
                            isScanning: false)
    #expect(MenuBarFormatter.text(for: snapshot, mode: .realTime) == "65")
    #expect(MenuBarFormatter.text(for: snapshot, mode: .endOfDay) == "71")
}

@Test func targetModeDefaultsToRealTimeInSettings() {
    #expect(BurnlineSettings.default.targetMode == .realTime)
}

@Test func targetModeSurvivesAJSONRoundTrip() throws {
    var settings = BurnlineSettings.default
    settings.targetMode = .endOfDay
    let data = try JSONEncoder().encode(settings)
    #expect(try JSONDecoder().decode(BurnlineSettings.self, from: data).targetMode == .endOfDay)
}

@Test func settingsFromBeforeThisFeatureDecodeToRealTime() throws {
    // Files written by the previous build have no targetMode key.
    let json = #"""
    {"resetSchedule":{"weekday":5,"hour":9,"minute":0,"timeZoneIdentifier":"America/Chicago"},
     "weights":{"input":1,"cacheWrite":1.25,"cacheRead":0.1,"output":5,
                "modelMultipliers":[],"defaultMultiplier":1},
     "calibrationAnchors":[],"launchAtLogin":false}
    """#
    let decoded = try JSONDecoder().decode(BurnlineSettings.self, from: Data(json.utf8))
    #expect(decoded.targetMode == .realTime)
}
