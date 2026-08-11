import Testing
import Foundation
@testable import BurnlineCore

private let chicago = TimeZone(identifier: "America/Chicago")!

private func settings() -> BurnlineSettings {
    var settings = BurnlineSettings.default
    settings.resetSchedule = ResetSchedule(weekday: 5, hour: 9, timeZone: chicago)
    return settings
}

private func capture(now: Date,
                     capturedAgo: TimeInterval = 300,
                     fiveHourPercent: Double? = 3,
                     fiveHourResetsIn: TimeInterval = 4_200) -> RateLimitCapture {
    RateLimitCapture(
        version: 1,
        capturedAt: now.addingTimeInterval(-capturedAgo).timeIntervalSince1970,
        sevenDay: .init(usedPercent: 64,
                        resetsAt: now.addingTimeInterval(2 * 86_400).timeIntervalSince1970),
        fiveHour: fiveHourPercent.map {
            .init(usedPercent: $0,
                  resetsAt: now.addingTimeInterval(fiveHourResetsIn).timeIntervalSince1970)
        })
}

@Test func fiveHourReadingSurfacesFromALiveCapture() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let snapshot = SnapshotBuilder.build(cache: ScanCache(), settings: settings(),
                                         rateLimit: capture(now: now),
                                         now: now, isScanning: false)

    #expect(snapshot.fiveHour?.usedPercent == 3)
    #expect(abs((snapshot.fiveHour?.timeRemaining ?? 0) - 4_200) < 1e-6)
}

/// Same rule as the weekly percentage: past its own reset the number describes
/// a period that no longer exists.
@Test func fiveHourReadingIsDiscardedOnceItsWindowHasReset() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let snapshot = SnapshotBuilder.build(cache: ScanCache(), settings: settings(),
                                         rateLimit: capture(now: now, fiveHourResetsIn: -60),
                                         now: now, isScanning: false)

    #expect(snapshot.fiveHour == nil)
}

@Test func noFiveHourReadingWithoutACapture() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let snapshot = SnapshotBuilder.build(cache: ScanCache(), settings: settings(),
                                         now: now, isScanning: false)
    #expect(snapshot.fiveHour == nil)
}

/// `rate_limits.five_hour` is absent on some plans; the weekly figure must
/// still come through.
@Test func captureWithoutAFiveHourReadingStillYieldsTheWeekly() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let snapshot = SnapshotBuilder.build(cache: ScanCache(), settings: settings(),
                                         rateLimit: capture(now: now, fiveHourPercent: nil),
                                         now: now, isScanning: false)

    #expect(snapshot.fiveHour == nil)
    #expect(snapshot.estimatedPercent == 64)
}

@Test func fiveHourRemainingReadsAsHoursAndMinutes() {
    let status = FiveHourStatus(usedPercent: 3,
                                resetsAt: Date(timeIntervalSince1970: 1_800_004_200),
                                timeRemaining: 4_200)
    #expect(status.remainingDescription == "1h 10m")
}

@Test func fiveHourRemainingDropsTheHourUnderSixtyMinutes() {
    let status = FiveHourStatus(usedPercent: 3,
                                resetsAt: Date(timeIntervalSince1970: 1_800_000_720),
                                timeRemaining: 720)
    #expect(status.remainingDescription == "12m")
}

@Test func fiveHourRemainingNeverGoesNegative() {
    let status = FiveHourStatus(usedPercent: 3,
                                resetsAt: Date(timeIntervalSince1970: 1_800_000_000),
                                timeRemaining: -30)
    #expect(status.remainingDescription == "0m")
}

/// The whole row value, so the view body holds no arithmetic.
@Test func fiveHourRowValueReadsAsPercentAndTimeLeft() {
    let status = FiveHourStatus(usedPercent: 3.4,
                                resetsAt: Date(timeIntervalSince1970: 1_800_004_200),
                                timeRemaining: 4_200)
    #expect(status.rowValue == "3% · 1h 10m left")
}
