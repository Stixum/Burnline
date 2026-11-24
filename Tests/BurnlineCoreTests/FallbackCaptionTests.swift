import Testing
import Foundation
@testable import BurnlineCore

// The caption under the typed reset fields in Settings. The typed schedule is
// wall-clock (`WindowMath`) and Anthropic's reset is fixed in UTC, so after a
// clock change the typed time is an hour off the real reset until the user
// moves it. It is the only window anyone without a reading has, so the caption
// says so, and only where the clocks can change at all.

private let now = Date(timeIntervalSince1970: 1_795_000_000)   // 2026-11-19
private let dstWarning = "Doesn't follow daylight saving: after a clock change, "
    + "set the hour here to match /usage."

private func schedule(_ zone: String) -> ResetSchedule {
    ResetSchedule(weekday: 6, hour: 2, timeZone: TimeZone(identifier: zone)!)
}

@Test func theTypedCaptionWarnsAboutClockChangesWhereTheClocksChange() {
    #expect(schedule("America/Chicago").fallbackCaption(now: now)
            == "Resets Friday 2:00 AM (Central Time). Used only until Claude Code "
             + "reports the real reset. " + dstWarning)
}

/// Southern hemisphere: the clocks change the other way round, still a change.
@Test func theWarningAppearsInTheSouthernHemisphereToo() {
    #expect(schedule("Australia/Sydney").fallbackCaption(now: now).hasSuffix(dstWarning))
}

/// A zone with no clock changes can never drift, so the warning would be noise.
@Test(arguments: ["Asia/Tokyo", "America/Phoenix", "UTC"])
func aZoneWithoutClockChangesGetsNoWarning(zone: String) {
    let caption = schedule(zone).fallbackCaption(now: now)
    #expect(!caption.contains("daylight saving"))
    #expect(caption.hasSuffix("Used only until Claude Code reports the real reset."))
}
