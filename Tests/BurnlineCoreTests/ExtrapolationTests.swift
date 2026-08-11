import Testing
import Foundation
@testable import BurnlineCore

/// `1_800_000_000` is exactly a 15-minute bucket boundary (it divides by 900),
/// so offsets from it place events at known positions inside a bucket.
private let bucketStart = Date(timeIntervalSince1970: 1_800_000_000)

private func settings() -> BurnlineSettings {
    var settings = BurnlineSettings.default
    settings.resetSchedule = ResetSchedule(weekday: 5, hour: 9,
                                           timeZone: TimeZone(identifier: "America/Chicago")!)
    return settings
}

private func cache(_ entries: [(Date, Double)]) -> ScanCache {
    var buckets: [String: Double] = [:]
    for (date, units) in entries {
        buckets[String(Bucket.key(for: date)), default: 0] += units
    }
    var cache = ScanCache()
    cache.files["a.jsonl"] = FileState(modifiedAt: .distantFuture, size: 1, offset: 1,
                                       buckets: buckets)
    return cache
}

private func capture(percent: Double, at captured: Date, now: Date) -> RateLimitCapture {
    RateLimitCapture(
        version: 1,
        capturedAt: captured.timeIntervalSince1970,
        sevenDay: .init(usedPercent: percent,
                        resetsAt: now.addingTimeInterval(2 * 86_400).timeIntervalSince1970),
        fiveHour: nil)
}

private func estimate(cache: ScanCache, capture: RateLimitCapture, now: Date) -> Double? {
    SnapshotBuilder.build(cache: cache, settings: settings(), rateLimit: capture,
                          now: now, isScanning: false).estimatedPercent
}

/// The capture's own 15-minute bucket straddles the capture instant, and the
/// sub-bucket detail was never stored. Counting the whole bucket as "burned
/// since the capture" double-counts usage the captured percentage already
/// includes — it is not extrapolation, it is invention.
@Test func usageInsideTheCapturesOwnBucketIsNotCountedAsDriftSinceTheCapture() {
    let now = bucketStart.addingTimeInterval(300)
    let captured = bucketStart.addingTimeInterval(290)   // same bucket as `now`
    let window = bucketStart.addingTimeInterval(-3 * 86_400)

    let scan = cache([(window, 9_000), (now, 1_000)])

    #expect(estimate(cache: scan, capture: capture(percent: 64, at: captured, now: now),
                     now: now) == 64)
}

/// The symptom as reported: the displayed percentage fell as time passed, with
/// the captured value unchanged the whole time. Usage inside a window is
/// cumulative and can never go backwards.
@Test func theEstimateDoesNotFallWhenTheClockCrossesABucketBoundary() {
    let window = bucketStart.addingTimeInterval(-3 * 86_400)

    // Late in the capture's own bucket, with that bucket carrying usage.
    let lateInBucket = bucketStart.addingTimeInterval(840)
    let scanBefore = cache([(window, 9_000), (lateInBucket, 1_000)])
    let before = estimate(cache: scanBefore,
                          capture: capture(percent: 64,
                                           at: bucketStart.addingTimeInterval(830),
                                           now: lateInBucket),
                          now: lateInBucket)

    // Just into the next bucket, a fresh capture reporting the same percentage
    // and no new usage yet.
    let earlyInNext = bucketStart.addingTimeInterval(960)
    let after = estimate(cache: scanBefore,
                         capture: capture(percent: 64,
                                          at: bucketStart.addingTimeInterval(950),
                                          now: earlyInNext),
                         now: earlyInNext)

    #expect(before != nil && after != nil)
    #expect(after! >= before!)
}

/// The counterweight: extrapolation still has to work. A bucket that closed
/// after the capture's own bucket is genuinely usage the capture never saw.
@Test func usageInLaterBucketsStillExtrapolatesForward() {
    let now = bucketStart.addingTimeInterval(1_000)       // bucket +1
    let captured = bucketStart.addingTimeInterval(100)    // bucket +0
    let window = bucketStart.addingTimeInterval(-3 * 86_400)

    let scan = cache([(window, 9_000), (now, 1_000)])
    let result = estimate(cache: scan, capture: capture(percent: 64, at: captured, now: now),
                          now: now)

    // 9,000 units bought 64% -> 140.625 units per point; 1,000 more -> +7.11.
    #expect(result != nil)
    #expect(abs(result! - 71.111) < 0.01)
}

/// A capture is a floor, never a ceiling: nothing may drag the figure below what
/// Claude Code actually reported.
@Test func theEstimateNeverDropsBelowTheCapturedPercentage() {
    let now = bucketStart.addingTimeInterval(300)
    let captured = bucketStart.addingTimeInterval(290)
    let window = bucketStart.addingTimeInterval(-3 * 86_400)

    let scan = cache([(window, 9_000), (now, 5_000)])
    let result = estimate(cache: scan, capture: capture(percent: 64, at: captured, now: now),
                          now: now)

    #expect(result != nil && result! >= 64)
}
