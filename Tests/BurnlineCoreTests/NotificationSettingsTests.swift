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
