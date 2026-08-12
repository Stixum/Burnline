import Testing
import Foundation
@testable import BurnlineCore

// MARK: - Saturating conversion

/// Swift **traps** on `Int(Double)` for NaN, infinity, or anything outside
/// Int's range. Several of these values originate in JSON any local process can
/// write — or in a weight typed into Settings. A menu bar app must degrade to a
/// silly number, not die.
@Test func hugeValuesSaturateInsteadOfTrapping() {
    #expect(DisplayValue.whole(1e308) == Int(DisplayValue.percentCeiling))
    #expect(DisplayValue.whole(.infinity) == Int(DisplayValue.percentCeiling))
    #expect(DisplayValue.whole(-.infinity) == -Int(DisplayValue.percentCeiling))
}

/// NaN has no sign to saturate toward, so it reports nothing rather than a
/// misleading maximum.
@Test func notANumberBecomesZero() {
    #expect(DisplayValue.whole(.nan) == 0)
}

@Test func ordinaryValuesRoundNormally() {
    #expect(DisplayValue.whole(64.4) == 64)
    #expect(DisplayValue.whole(64.5) == 65)
    #expect(DisplayValue.whole(-3.2) == -3)
}

@Test func durationsSaturateOnTheirOwnScale() {
    #expect(DisplayValue.seconds(.infinity) > 0)
    #expect(DisplayValue.seconds(.nan) == 0)
    #expect(DisplayValue.seconds(4_200) == 4_200)
}

/// `whole`'s own `ceiling` parameter must not be able to trap it: every current
/// caller passes a safe constant, but a type whose stated purpose is "never
/// trap" should not have a trapping parameter. `min`/`max` against a non-finite
/// ceiling would let the clamp through untouched into `Int(Double)`.
@Test func wholeFallsBackToThePercentCeilingWhenGivenANonFiniteCeiling() {
    #expect(DisplayValue.whole(1e308, ceiling: .infinity) == Int(DisplayValue.percentCeiling))
    #expect(DisplayValue.whole(-1e308, ceiling: .infinity) == -Int(DisplayValue.percentCeiling))
    #expect(DisplayValue.whole(1e308, ceiling: .nan) == Int(DisplayValue.percentCeiling))
}

// MARK: - Flooring conversion

/// `floor` exists for percentages, where 42.99% must read as "42%" — rounding
/// it to "43%" overstates how far through the window it actually is.
@Test func floorTruncatesAFraction() {
    #expect(DisplayValue.floor(42.99) == 42)
    #expect(DisplayValue.floor(42.0) == 42)
}

@Test func floorClampsAHugeValueBeforeConverting() {
    #expect(DisplayValue.floor(1e308) == Int(DisplayValue.percentCeiling))
    #expect(DisplayValue.floor(.infinity) == Int(DisplayValue.percentCeiling))
    #expect(DisplayValue.floor(-.infinity) == -Int(DisplayValue.percentCeiling))
}

@Test func floorOfNotANumberIsZero() {
    #expect(DisplayValue.floor(.nan) == 0)
}

@Test func floorHandlesNegativeValues() {
    #expect(DisplayValue.floor(-3.2) == -4)
}

/// Same guard as `whole`'s: `floor(1e308, ceiling: .infinity)` must saturate,
/// not trap, even though every current caller happens to pass a safe constant.
@Test func floorFallsBackToThePercentCeilingWhenGivenANonFiniteCeiling() {
    #expect(DisplayValue.floor(1e308, ceiling: .infinity) == Int(DisplayValue.percentCeiling))
    #expect(DisplayValue.floor(-1e308, ceiling: .infinity) == -Int(DisplayValue.percentCeiling))
    #expect(DisplayValue.floor(1e308, ceiling: .nan) == Int(DisplayValue.percentCeiling))
}

// MARK: - The call sites that were trapping

@Test func theProjectionRowSurvivesAnAbsurdEstimate() {
    _ = Projection.description(1e308)
    _ = Projection.description(.infinity)
    _ = Projection.description(.nan)
}

@Test func theFiveHourRowSurvivesAnAbsurdReading() {
    let silly = FiveHourStatus(usedPercent: 1e308,
                               resetsAt: Date(timeIntervalSince1970: 0),
                               timeRemaining: 1e308)
    _ = silly.rowValue
    _ = silly.remainingDescription
}

/// A capture with a nonsense `resetsAt` reaches `Bucket.key`, which divides and
/// converts to Int — the same trap, on the arithmetic path rather than display.
@Test func absurdDatesDoNotTrapTheBucketKey() {
    _ = Bucket.key(for: Date(timeIntervalSince1970: 1e308))
    _ = Bucket.key(for: Date(timeIntervalSince1970: -1e308))
    _ = Bucket.key(for: Date(timeIntervalSince1970: .infinity))
}

@Test func captureAgeSurvivesAnAbsurdAge() {
    _ = CaptureAge.description(1e308)
    _ = CaptureAge.description(.infinity)
}

// MARK: - Weights are bounded above as well as below

/// Weights multiply token counts. Unbounded above, a value typed into the
/// Settings text field overflows the product to infinity, which then propagates
/// into every downstream figure.
@Test func absurdWeightsAreClampedToAWorkableMaximum() {
    var weights = Weights.default
    weights.output = 1e308
    weights.cacheRead = .infinity

    let safe = weights.sanitized()

    #expect(safe.output == Weights.maximumWeight)
    #expect(safe.cacheRead == Weights.maximumWeight)
}

@Test func aWeightThatSurvivesClampingCannotOverflowRealisticTokenCounts() {
    var weights = Weights.default
    weights.output = 1e308
    let safe = weights.sanitized()

    // A preposterously heavy week: a trillion output tokens.
    let record = UsageRecord(timestamp: Date(), model: "claude-sonnet-5",
                             inputTokens: 0, outputTokens: 1_000_000_000_000,
                             cacheWriteTokens: 0, cacheReadTokens: 0)

    #expect(ConsumptionModel.units(for: record, weights: safe).isFinite)
}

@Test func sanitizingStillLeavesOrdinaryWeightsAlone() {
    #expect(Weights.default.sanitized() == Weights.default)
}
