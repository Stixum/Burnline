import Testing
import Foundation
@testable import BurnlineCore

private let chicago = TimeZone(identifier: "America/Chicago")!

private func settings(anchors: [CalibrationAnchor] = []) -> BurnlineSettings {
    var settings = BurnlineSettings.default
    settings.resetSchedule = ResetSchedule(weekday: 5, hour: 9, timeZone: chicago)
    settings.calibrationAnchors = anchors
    return settings
}

private func cache(units: Double, at date: Date) -> ScanCache {
    var cache = ScanCache()
    cache.files["a.jsonl"] = FileState(modifiedAt: date, size: 1, offset: 1,
                                       buckets: [String(Bucket.key(for: date)): units])
    return cache
}

@Test func uncalibratedSnapshotHasTargetButNoEstimate() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let window = WindowMath.window(for: settings().resetSchedule, now: now)
    let snapshot = SnapshotBuilder.build(
        cache: cache(units: 5_000, at: window.start.addingTimeInterval(60)),
        settings: settings(), now: now, isScanning: false)

    #expect(snapshot.estimatedPercent == nil)
    #expect(snapshot.projectedPercent == nil)
    #expect(snapshot.deltaPercent == nil)
    #expect(snapshot.targetPercent > 0)
    #expect(snapshot.isPaceOnly)
}

@Test func calibratedSnapshotProducesEstimateAndDelta() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let window = WindowMath.window(for: settings().resetSchedule, now: now)
    let anchors = [CalibrationAnchor(timestamp: now.addingTimeInterval(-86_400),
                                     observedPercent: 50, unitsInWindow: 5_000)]
    let snapshot = SnapshotBuilder.build(
        cache: cache(units: 4_000, at: window.start.addingTimeInterval(60)),
        settings: settings(anchors: anchors), now: now, isScanning: false)

    #expect(abs(snapshot.estimatedPercent! - 40) < 1e-6)
    #expect(snapshot.isPaceOnly == false)
    // delta is target - estimate: positive means under budget
    #expect(abs(snapshot.deltaPercent! - (snapshot.targetPercent - 40)) < 1e-6)
}

@Test func unitsOutsideTheWindowDoNotCount() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let window = WindowMath.window(for: settings().resetSchedule, now: now)
    let snapshot = SnapshotBuilder.build(
        cache: cache(units: 9_999, at: window.start.addingTimeInterval(-86_400)),
        settings: settings(), now: now, isScanning: false)
    #expect(snapshot.unitsInWindow == 0)
}

@Test func isUnderBudgetWhenEstimateTrailsTarget() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let window = WindowMath.window(for: settings().resetSchedule, now: now)
    let anchors = [CalibrationAnchor(timestamp: now, observedPercent: 50, unitsInWindow: 5_000)]
    let low = SnapshotBuilder.build(cache: cache(units: 10, at: window.start.addingTimeInterval(60)),
                                    settings: settings(anchors: anchors), now: now, isScanning: false)
    #expect(low.isUnderBudget == true)
}

@Test func scanningFlagIsCarriedThrough() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let snapshot = SnapshotBuilder.build(cache: ScanCache(), settings: settings(),
                                         now: now, isScanning: true)
    #expect(snapshot.isScanning)
}
