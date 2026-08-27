import Foundation
import Testing
@testable import BurnlineCore

@Test func notificationSettingsDefaultIsOff() {
    let defaults = NotificationSettings.default
    #expect(defaults.enabled == false)
    #expect(defaults.behindPacePoints == 10)
    #expect(defaults.weeklyPercent == 90)
    #expect(defaults.fiveHourPercent == 80)
}

@Test func notificationSettingsSanitizeClampsEveryField() {
    // Zero is illegal everywhere: a threshold of 0 under >= fires permanently.
    var s = NotificationSettings(enabled: true, behindPacePoints: 0,
                                 weeklyPercent: 0, fiveHourPercent: 150)
    var clamped = s.sanitized()
    #expect(clamped.behindPacePoints == 1)
    #expect(clamped.weeklyPercent == 1)
    #expect(clamped.fiveHourPercent == 99)

    s = NotificationSettings(enabled: true, behindPacePoints: 500,
                             weeklyPercent: 100, fiveHourPercent: .nan)
    clamped = s.sanitized()
    #expect(clamped.behindPacePoints == 100)
    #expect(clamped.weeklyPercent == 99)   // 100 is unreachable; the window resets first
    #expect(clamped.fiveHourPercent == NotificationSettings.default.fiveHourPercent)

    // NaN on the other two fields: each must fall back to its OWN default,
    // never 0 (0 is a legal weight but an illegal threshold).
    s = NotificationSettings(enabled: true, behindPacePoints: .nan,
                             weeklyPercent: .nan, fiveHourPercent: 50)
    clamped = s.sanitized()
    #expect(clamped.behindPacePoints == NotificationSettings.default.behindPacePoints)
    #expect(clamped.weeklyPercent == NotificationSettings.default.weeklyPercent)
    #expect(clamped.fiveHourPercent == 50)

    // Negative clamps up to the floor; infinity clamps down to the ceiling.
    s = NotificationSettings(enabled: false, behindPacePoints: -5,
                             weeklyPercent: .infinity, fiveHourPercent: -.infinity)
    clamped = s.sanitized()
    #expect(clamped.behindPacePoints == 1)
    #expect(clamped.weeklyPercent == 99)
    #expect(clamped.fiveHourPercent == 1)

    // sanitized() clamps numbers only — the switch passes through untouched.
    #expect(clamped.enabled == false)
    #expect(NotificationSettings(enabled: true, behindPacePoints: 10,
                                 weeklyPercent: 90, fiveHourPercent: 80)
        .sanitized().enabled == true)
}

@Test func notificationSettingsRoundTripThroughJSON() throws {
    // Encode is compiler-synthesized while decode is hand-written; the pair
    // can drift. Round-trip non-default values through the parent settings.
    var settings = BurnlineSettings.default
    settings.notifications = NotificationSettings(
        enabled: true, behindPacePoints: 25, weeklyPercent: 75, fiveHourPercent: 60)
    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(BurnlineSettings.self, from: data)
    #expect(decoded.notifications == settings.notifications)
}

@Test func settingsFilePredatingNotificationsStillDecodes() throws {
    // The standing rule in BurnlineSettings: a missing key falls back, never throws.
    let old = """
    {"resetSchedule":{"weekday":5,"hour":9,"minute":0,"timeZoneIdentifier":"America/Chicago"},
     "weights":\(String(data: try JSONEncoder().encode(Weights.default), encoding: .utf8)!),
     "calibrationAnchors":[],"launchAtLogin":false}
    """
    let decoded = try JSONDecoder().decode(BurnlineSettings.self, from: Data(old.utf8))
    #expect(decoded.notifications == .default)
}
