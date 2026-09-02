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

// MARK: - Pluralised points

/// The defect this exists to remove: the delta crosses ±1 constantly, so `1
/// points` is not an edge case, it is the value a user sees most often after 0.
@Test func oneIsSingularAndEverythingElseIsPlural() {
    #expect(DisplayValue.points(1) == "1 point")
    #expect(DisplayValue.points(0) == "0 points")
    #expect(DisplayValue.points(2) == "2 points")
    #expect(DisplayValue.points(12) == "12 points")
}

/// Rounding happens inside, so the noun agrees with the number on screen rather
/// than with the double behind it. `1.4` prints as `1`, and `1 points` would be
/// the same defect one decimal place further down.
@Test func thePluralFollowsTheRoundedFigureNotTheRawOne() {
    #expect(DisplayValue.points(1.4) == "1 point")
    #expect(DisplayValue.points(0.6) == "1 point")
    #expect(DisplayValue.points(1.5) == "2 points")
}

/// Magnitude, not sign. No current caller passes a negative — every one takes
/// an absolute value or a positive threshold first — but `-1 points` would be
/// the same grammatical error, and this type's job is to never produce one.
@Test func aSingleNegativePointIsStillSingular() {
    #expect(DisplayValue.points(-1) == "-1 point")
    #expect(DisplayValue.points(-2) == "-2 points")
}

/// Same saturation rule as `whole`, since this is `whole` with a noun on it: a
/// figure descending from JSON on disk must never trap.
@Test func pointsSaturateRatherThanTrapping() {
    #expect(DisplayValue.points(.nan) == "0 points")
    #expect(DisplayValue.points(.infinity) == "\(Int(DisplayValue.percentCeiling)) points")
}

/// The popover hero renders the number at 34pt and the noun at 12pt, so it
/// takes the noun alone — and must not be able to disagree with `points`.
@Test func theBareUnitAgreesWithTheFullString() {
    for value in [0.0, 0.6, 1, 1.4, 2, 12, -1, .nan, .infinity] {
        #expect(DisplayValue.points(value)
                == "\(DisplayValue.whole(value)) \(DisplayValue.pointsUnit(value))")
    }
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
