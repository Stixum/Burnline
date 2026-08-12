import Testing
import Foundation
@testable import BurnlineCore

private let chicago = TimeZone(identifier: "America/Chicago")!
private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func settings() -> BurnlineSettings {
    var settings = BurnlineSettings.default
    settings.resetSchedule = ResetSchedule(weekday: 5, hour: 9, timeZone: chicago)
    return settings
}

private func capture(usedPercent: Double, resetsIn days: Double, capturedAgo: TimeInterval = 0)
-> RateLimitCapture {
    RateLimitCapture(
        version: 1,
        capturedAt: now.addingTimeInterval(-capturedAgo).timeIntervalSince1970,
        sevenDay: .init(usedPercent: usedPercent,
                        resetsAt: now.addingTimeInterval(days * 86_400).timeIntervalSince1970),
        fiveHour: nil)
}

private func cache(_ entries: [(Date, Double)]) -> ScanCache {
    var cache = ScanCache()
    for (index, entry) in entries.enumerated() {
        cache.files["f\(index).jsonl"] = FileState(
            modifiedAt: entry.0, size: 1, offset: 1,
            buckets: [String(Bucket.key(for: entry.0)): entry.1])
    }
    return cache
}

// MARK: - Window derived from resets_at

@Test func windowComesFromResetsAtWhenACaptureExists() {
    let live = capture(usedPercent: 50, resetsIn: 2)
    let snapshot = SnapshotBuilder.build(cache: ScanCache(), settings: settings(),
                                         rateLimit: live, now: now, isScanning: false)
    #expect(snapshot.window.end.timeIntervalSince1970 == live.sevenDay.resetsAt)
    #expect(snapshot.isScheduleAutomatic)
    // Seven calendar days back from the reset.
    #expect(abs(snapshot.window.totalDuration - 7 * 86_400) < 3600)
}

@Test func manualScheduleIsUsedWhenThereIsNoCapture() {
    let snapshot = SnapshotBuilder.build(cache: ScanCache(), settings: settings(),
                                         rateLimit: nil, now: now, isScanning: false)
    let manual = WindowMath.window(for: settings().resetSchedule, now: now)
    #expect(snapshot.window.start == manual.start)
    #expect(snapshot.isScheduleAutomatic == false)
}

@Test func aResetsAtInThePastRollsForwardToTheCurrentWindow() {
    // Capture is two windows old; its reset instant has already passed.
    let stale = capture(usedPercent: 90, resetsIn: -9, capturedAgo: 10 * 86_400)
    let snapshot = SnapshotBuilder.build(cache: ScanCache(), settings: settings(),
                                         rateLimit: stale, now: now, isScanning: false)
    #expect(snapshot.window.end > now)
    #expect(snapshot.window.start <= now)
    // The percentage belonged to a window that has since reset — do not reuse it.
    #expect(snapshot.source != .live(capturedAt: stale.capturedDate))
}

// MARK: - Exact percentage, and extrapolation past it

@Test func usesTheExactPercentageWhenNothingBurnedSinceCapture() {
    let live = capture(usedPercent: 63.4, resetsIn: 2)
    let start = Date(timeIntervalSince1970: live.sevenDay.resetsAt).addingTimeInterval(-7 * 86_400)
    let snapshot = SnapshotBuilder.build(
        cache: cache([(start.addingTimeInterval(3600), 1_000)]),
        settings: settings(), rateLimit: live, now: now, isScanning: false)
    #expect(abs(snapshot.estimatedPercent! - 63.4) < 0.001)
    #expect(snapshot.source == .live(capturedAt: live.capturedDate))
}

@Test func extrapolatesForwardFromTheCaptureUsingUnitsBurnedSince() {
    // 1000 units at capture == 50%, so 20 units per percent.
    // Another 500 units after the capture == +25 points.
    let live = capture(usedPercent: 50, resetsIn: 2, capturedAgo: 3600)
    let start = Date(timeIntervalSince1970: live.sevenDay.resetsAt).addingTimeInterval(-7 * 86_400)
    let snapshot = SnapshotBuilder.build(
        cache: cache([(start.addingTimeInterval(60), 1_000),
                      (now.addingTimeInterval(-60), 500)]),
        settings: settings(), rateLimit: live, now: now, isScanning: false)
    #expect(abs(snapshot.estimatedPercent! - 75) < 0.01)
}

@Test func doesNotExtrapolateFromATinyPercentage() {
    // Below 1% the derived units-per-percent is noise; report the exact figure.
    let live = capture(usedPercent: 0.4, resetsIn: 6, capturedAgo: 3600)
    let start = Date(timeIntervalSince1970: live.sevenDay.resetsAt).addingTimeInterval(-7 * 86_400)
    let snapshot = SnapshotBuilder.build(
        cache: cache([(start.addingTimeInterval(60), 10),
                      (now.addingTimeInterval(-60), 9_999)]),
        settings: settings(), rateLimit: live, now: now, isScanning: false)
    #expect(abs(snapshot.estimatedPercent! - 0.4) < 0.001)
}

@Test func doesNotExtrapolateWhenNoUnitsWereRecordedAtCaptureTime() {
    // Claude Code used elsewhere: real percentage, nothing local to scale by.
    let live = capture(usedPercent: 40, resetsIn: 3, capturedAgo: 60)
    let snapshot = SnapshotBuilder.build(cache: ScanCache(), settings: settings(),
                                         rateLimit: live, now: now, isScanning: false)
    #expect(abs(snapshot.estimatedPercent! - 40) < 0.001)
}

@Test func liveCaptureBeatsManualCalibrationAnchors() {
    var withAnchors = settings()
    withAnchors.calibrationAnchors = [CalibrationAnchor(timestamp: now, observedPercent: 10,
                                                        unitsInWindow: 1_000_000)]
    let live = capture(usedPercent: 63.4, resetsIn: 2)
    let snapshot = SnapshotBuilder.build(cache: ScanCache(), settings: withAnchors,
                                         rateLimit: live, now: now, isScanning: false)
    #expect(abs(snapshot.estimatedPercent! - 63.4) < 0.001)
    #expect(snapshot.source == .live(capturedAt: live.capturedDate))
}

@Test func fallsBackToManualCalibrationWhenTheCaptureIsFromAnOldWindow() {
    var withAnchors = settings()
    withAnchors.calibrationAnchors = [CalibrationAnchor(timestamp: now, observedPercent: 50,
                                                        unitsInWindow: 5_000)]
    let stale = capture(usedPercent: 90, resetsIn: -9, capturedAgo: 10 * 86_400)
    let snapshot = SnapshotBuilder.build(cache: ScanCache(), settings: withAnchors,
                                         rateLimit: stale, now: now, isScanning: false)
    #expect(snapshot.source == .calibrated)
}

@Test func noCaptureAndNoAnchorsIsPaceOnly() {
    let snapshot = SnapshotBuilder.build(cache: ScanCache(), settings: settings(),
                                         rateLimit: nil, now: now, isScanning: false)
    #expect(snapshot.source == .paceOnly)
    #expect(snapshot.isPaceOnly)
}

// MARK: - Decoding what the statusline script writes

@Test func decodesTheStatuslineScriptOutput() throws {
    let json = #"""
    {"version":1,"capturedAt":1786476127,
     "sevenDay":{"usedPercent":63.4,"resetsAt":1786400000},
     "fiveHour":{"usedPercent":12.5,"resetsAt":1786000000}}
    """#
    let decoded = try JSONDecoder().decode(RateLimitCapture.self, from: Data(json.utf8))
    #expect(decoded.sevenDay.usedPercent == 63.4)
    #expect(decoded.sevenDay.resetsAt == 1_786_400_000)
    #expect(decoded.fiveHour?.usedPercent == 12.5)
    #expect(decoded.capturedDate.timeIntervalSince1970 == 1_786_476_127)
}

@Test func decodesWithFiveHourAbsent() throws {
    let json = #"{"version":1,"capturedAt":1,"sevenDay":{"usedPercent":5,"resetsAt":2},"fiveHour":null}"#
    let decoded = try JSONDecoder().decode(RateLimitCapture.self, from: Data(json.utf8))
    #expect(decoded.fiveHour == nil)
}

@Test func rejectsAnIncompatibleVersion() {
    let capture = RateLimitCapture(version: 99, capturedAt: 1,
                                   sevenDay: .init(usedPercent: 5, resetsAt: 2), fiveHour: nil)
    #expect(capture.isCompatible == false)
}

// MARK: - Atomic writes

@Test func saveThenLoadRoundTripsACapture() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = RateLimitStore(directory: dir)
    // The five-hour reset is ahead of `capturedAt`, as in any genuinely fresh
    // payload. Behind it, `load()` would date the capture as a replay and the
    // round trip would legitimately not be an identity.
    let capture = RateLimitCapture(
        version: RateLimitCapture.currentVersion,
        capturedAt: 1_785_900_000,
        sevenDay: .init(usedPercent: 64, resetsAt: 1_786_000_000),
        fiveHour: .init(usedPercent: 3, resetsAt: 1_785_910_000)
    )

    try store.save(capture)
    #expect(store.load() == capture)
}

@Test func saveOverwritesAnExistingCapture() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = RateLimitStore(directory: dir)
    try store.save(.init(version: 1, capturedAt: 1, sevenDay: .init(usedPercent: 10, resetsAt: 2), fiveHour: nil))
    try store.save(.init(version: 1, capturedAt: 3, sevenDay: .init(usedPercent: 20, resetsAt: 4), fiveHour: nil))

    #expect(store.load()?.sevenDay.usedPercent == 20)
}

@Test func saveRoundTripsACaptureWithNoFiveHour() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = RateLimitStore(directory: dir)
    let capture = RateLimitCapture(version: RateLimitCapture.currentVersion,
                                   capturedAt: 1, sevenDay: .init(usedPercent: 5, resetsAt: 2), fiveHour: nil)
    try store.save(capture)
    #expect(store.load() == capture)
    #expect(store.load()?.fiveHour == nil)
}
