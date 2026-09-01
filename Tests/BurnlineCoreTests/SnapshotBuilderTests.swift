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

/// Cells hold raw tokens now. An input token on a sonnet model is the identity
/// mapping under `Weights.default` — `input: 1.0` × sonnet `1.0` — so `units`
/// here is still both the fixture and the weighted total it renders to.
private func cache(units: Int, at date: Date) -> ScanCache {
    var cache = ScanCache()
    cache.files["a.jsonl"] = FileState(
        modifiedAt: date, size: 1, offset: 1,
        cells: [String(Bucket.key(for: date)): ["claude-sonnet-5": TokenCounts(input: units)]])
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

// MARK: - capturedPercent

/// `1_800_000_000` divides by 900, so it is exactly a 15-minute bucket boundary
/// and offsets from it place usage in known buckets.
private let capturedBucketStart = Date(timeIntervalSince1970: 1_800_000_000)

/// Two-entry cache: the baseline the capture already saw, plus whatever landed
/// after it. `cache(units:at:)` above only holds one entry, and a single entry
/// cannot make the extrapolation differ from the capture.
private func cache(_ entries: [(Date, Int)]) -> ScanCache {
    var cells: [String: [String: TokenCounts]] = [:]
    for (date, tokens) in entries {
        cells[String(Bucket.key(for: date)), default: [:]]["claude-sonnet-5", default: .zero]
            += TokenCounts(input: tokens)
    }
    var cache = ScanCache()
    cache.files["a.jsonl"] = FileState(modifiedAt: .distantFuture, size: 1, offset: 1,
                                       cells: cells)
    return cache
}

private func capture(percent: Double, at captured: Date, resetsAt: Date) -> RateLimitCapture {
    RateLimitCapture(version: 1,
                     capturedAt: captured.timeIntervalSince1970,
                     sevenDay: .init(usedPercent: percent,
                                     resetsAt: resetsAt.timeIntervalSince1970),
                     fiveHour: nil)
}

@Test func capturedPercentIsTheCapturedFigureNotTheExtrapolation() {
    // estimatedPercent under .live is the captured figure carried FORWARD by
    // local token counts. Archiving that as a week's final percentage would
    // write an estimate into the one artifact that can never be recomputed.
    // Build a snapshot where local usage has accrued since the capture, so the
    // two figures genuinely differ — equal values would prove nothing.
    let now = capturedBucketStart.addingTimeInterval(1_000)     // bucket +1
    let captured = capturedBucketStart.addingTimeInterval(100)  // bucket +0
    let earlier = capturedBucketStart.addingTimeInterval(-3 * 86_400)

    let snapshot = SnapshotBuilder.build(
        cache: cache([(earlier, 9_000), (now, 1_000)]),
        settings: settings(),
        rateLimit: capture(percent: 64, at: captured,
                           resetsAt: now.addingTimeInterval(2 * 86_400)),
        now: now, isScanning: false)

    // 9,000 units bought 64% -> 140.625 units per point; 1,000 more -> +7.11.
    #expect(snapshot.capturedPercent == 64)
    #expect(abs(snapshot.estimatedPercent! - 71.111) < 0.01)
    #expect(snapshot.estimatedPercent != snapshot.capturedPercent)
}

@Test func aDeadCaptureYieldsNoCapturedPercent() {
    // windowFromReset rolls a window forward from a capture whose resets_at has
    // passed, so `rateLimit` is non-nil precisely when the capture is dead.
    // Ungated, that dead window's percentage would be archived as the NEW
    // window's final figure.
    let captured = capturedBucketStart
    let resetsAt = capturedBucketStart.addingTimeInterval(60)
    let now = capturedBucketStart.addingTimeInterval(3 * 86_400)

    let snapshot = SnapshotBuilder.build(
        cache: cache([(captured, 9_000)]),
        settings: settings(),
        rateLimit: capture(percent: 64, at: captured, resetsAt: resetsAt),
        now: now, isScanning: false)

    // The capture is outside the rolled-forward window, so it is not live.
    #expect(snapshot.source == .paceOnly)
    #expect(snapshot.capturedPercent == nil)
}

// MARK: - The allowance epoch

// Anthropic re-issues the weekly allowance INSIDE a window without moving
// `resets_at` (observed 2026-09-01: 51% → 0%). `RateLimitHighWater` records that
// as a `Regrant` on the mark; the snapshot is the single immutable value every
// reader gets, so it has to carry the epoch or each reader recomputes it.

/// 🔴 The epoch-seconds → `Date` boundary is here, and every fixture value is
/// deliberately distinct. `Regrant.startedAt`, the capture's `capturedAt` and
/// `window.start` are three same-typed instants; wiring any of the other two
/// compiles silently. `startPercent` is likewise neither 0 (the value a
/// hardcode would produce, and the value the real 2026-09-01 event re-granted
/// to) nor the capture's own percentage.
@Test func theSnapshotCarriesTheOpenAllowanceEpoch() {
    let captured = capturedBucketStart
    let now = capturedBucketStart.addingTimeInterval(1_000)
    let resetsAt = capturedBucketStart.addingTimeInterval(2 * 86_400)
    let startedAt = capturedBucketStart.addingTimeInterval(-3_600)

    let snapshot = SnapshotBuilder.build(
        cache: cache([(captured, 9_000)]),
        settings: settings(),
        rateLimit: capture(percent: 3, at: captured, resetsAt: resetsAt),
        now: now, isScanning: false,
        regrant: .init(startedAt: startedAt.timeIntervalSince1970, startPercent: 4))

    #expect(snapshot.regrant?.startedAt == startedAt)
    #expect(snapshot.regrant?.startPercent == 4)
    #expect(snapshot.regrant?.startedAt != snapshot.window.start)
    #expect(snapshot.regrant?.startedAt != captured)
}

/// The ordinary case: no epoch has ever opened, so nothing is claimed.
@Test func aSnapshotWithNoEpochCarriesNoRegrant() {
    let captured = capturedBucketStart
    let now = capturedBucketStart.addingTimeInterval(1_000)

    let snapshot = SnapshotBuilder.build(
        cache: cache([(captured, 9_000)]),
        settings: settings(),
        rateLimit: capture(percent: 3, at: captured,
                           resetsAt: capturedBucketStart.addingTimeInterval(2 * 86_400)),
        now: now, isScanning: false)

    #expect(snapshot.regrant == nil)
}

/// 🔴 A mark outlives its own window. `reconcile` only clears it when a capture
/// for a DIFFERENT window arrives, and in the gap `CaptureSelection` hands back
/// that dead mark as a stand-in — so an epoch from the previous window is a
/// reachable state, not a hypothetical. Carrying it forward would date the new
/// window's extrapolation (Task 8) from an instant that is not in it.
///
/// Same guard shape as `capturedPercent` above, and for the same reason.
@Test func anEpochFromAWindowThatHasSinceResetIsNotCarried() {
    let captured = capturedBucketStart
    let resetsAt = capturedBucketStart.addingTimeInterval(60)
    let now = capturedBucketStart.addingTimeInterval(3 * 86_400)

    let snapshot = SnapshotBuilder.build(
        cache: cache([(captured, 9_000)]),
        settings: settings(),
        rateLimit: capture(percent: 3, at: captured, resetsAt: resetsAt),
        now: now, isScanning: false,
        regrant: .init(startedAt: captured.addingTimeInterval(-86_400).timeIntervalSince1970,
                       startPercent: 4))

    // `windowFromReset` rolled the window forward past the epoch's start.
    #expect(snapshot.source == .paceOnly)
    #expect(snapshot.regrant == nil)
}
