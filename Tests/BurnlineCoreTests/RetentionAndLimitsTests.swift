import Testing
import Foundation
@testable import BurnlineCore

// MARK: - Buckets inside a surviving file

/// `evict` drops whole files by mtime, but a file that keeps being appended to
/// never ages out — so its old buckets lived forever. Retention is 14 days and a
/// window is 7, so a bucket past the cutoff can never fall inside a live window.
@Test func evictionAlsoDropsStaleBucketsInsideAFileThatSurvives() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let fresh = now.addingTimeInterval(-86_400)
    let ancient = now.addingTimeInterval(-40 * 86_400)

    var cache = ScanCache()
    cache.files["live.jsonl"] = FileState(
        modifiedAt: now, size: 1, offset: 1,
        buckets: [String(Bucket.key(for: fresh)): 10,
                  String(Bucket.key(for: ancient)): 999])

    cache.evict(before: now.addingTimeInterval(-ScanCache.retention))

    #expect(cache.files["live.jsonl"]?.buckets.count == 1)
    #expect(cache.units(from: .distantPast, to: .distantFuture) == 10)
}

@Test func evictionKeepsEveryBucketInsideRetention() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var cache = ScanCache()
    cache.files["live.jsonl"] = FileState(
        modifiedAt: now, size: 1, offset: 1,
        buckets: [String(Bucket.key(for: now.addingTimeInterval(-86_400))): 10,
                  String(Bucket.key(for: now.addingTimeInterval(-10 * 86_400))): 5])

    cache.evict(before: now.addingTimeInterval(-ScanCache.retention))

    #expect(cache.files["live.jsonl"]?.buckets.count == 2)
    #expect(cache.units(from: .distantPast, to: .distantFuture) == 15)
}

// MARK: - Anchors are pruned on write, not just filtered on read

private func anchor(_ percent: Double, daysAgo: Double, now: Date) -> CalibrationAnchor {
    CalibrationAnchor(timestamp: now.addingTimeInterval(-daysAgo * 86_400),
                      observedPercent: percent, unitsInWindow: 1_000)
}

@Test func anchorsBeyondTheStorageLimitAreDropped() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let many = (0..<40).map { anchor(50, daysAgo: Double($0) / 24, now: now) }

    let kept = Calibration.retained(many, now: now)

    #expect(kept.count == Calibration.storageLimit)
}

@Test func retentionKeepsTheNewestAnchors() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let old = anchor(10, daysAgo: 5, now: now)
    let new = anchor(90, daysAgo: 0, now: now)

    let kept = Calibration.retained([old, new], now: now)

    #expect(kept.first?.observedPercent == 90)
}

/// Age is a storage concern; the 5% floor is not. A too-low reading is rejected
/// by `validAnchors` at read time but must stay visible in Settings, or entering
/// one looks like the app silently swallowed it.
@Test func retentionDropsAgedAnchorsButKeepsLowOnes() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let aged = anchor(50, daysAgo: 90, now: now)
    let low = anchor(2, daysAgo: 1, now: now)

    let kept = Calibration.retained([aged, low], now: now)

    #expect(kept.count == 1)
    #expect(kept.first?.observedPercent == 2)
}

// MARK: - Weights can't go negative

/// Nothing stops a hand-typed weight going below zero, and a negative weight
/// makes units run backwards — an estimate that falls as you burn tokens.
@Test func negativeWeightsAreClampedToZero() {
    var weights = Weights.default
    weights.input = -5
    weights.cacheRead = -0.1

    let safe = weights.sanitized()

    #expect(safe.input == 0)
    #expect(safe.cacheRead == 0)
}

@Test func negativeModelMultipliersAreClampedToZero() {
    var weights = Weights.default
    weights.modelMultipliers = [ModelMultiplier(match: "opus", multiplier: -3)]
    weights.defaultMultiplier = -1

    let safe = weights.sanitized()

    #expect(safe.modelMultipliers.first?.multiplier == 0)
    #expect(safe.defaultMultiplier == 0)
}

/// Zero is legitimate — it means "ignore this token class" — so only negatives
/// move.
@Test func sanitizingLeavesValidWeightsAlone() {
    var weights = Weights.default
    weights.cacheRead = 0

    #expect(weights.sanitized() == weights)
}

// MARK: - The projection says when it lands over the limit

@Test func aProjectionUnderTheLimitReadsPlainly() {
    #expect(Projection.description(98.6) == "99% by reset")
}

/// The one number in the popover that should change behaviour. Word first, so
/// it never depends on colour alone.
@Test func aProjectionOverTheLimitSaysSo() {
    #expect(Projection.description(112.4) == "over limit · 112% by reset")
}

@Test func exactlyAtTheLimitIsNotOver() {
    #expect(Projection.description(100) == "100% by reset")
}

@Test func aSuppressedProjectionReadsAsADash() {
    #expect(Projection.description(nil) == "—")
}

@Test func projectionIsOverLimitOnlyAboveOneHundred() {
    #expect(Projection.isOverLimit(100) == false)
    #expect(Projection.isOverLimit(100.1))
    #expect(Projection.isOverLimit(nil) == false)
}
