import Testing
@testable import BurnlineCore

@Test func extrapolatesCurrentBurnToEndOfWindow() throws {
    // 40% consumed at 71.4% elapsed lands at ~56%.
    // `#require`, not `!`: a relational mutation of the guard one file over
    // (`>=` to `<`) nils this, and a force unwrap turns that into a process
    // trap that takes every later test's result down with it.
    let projected = try #require(
        Projection.projectedPercent(estimatedPercent: 40, elapsedFraction: 5.0 / 7.0))
    #expect(abs(projected - 56) < 0.01)
}

@Test func suppressedTooEarlyInTheWindow() {
    #expect(Projection.projectedPercent(estimatedPercent: 40, elapsedFraction: 0.019) == nil)
    #expect(Projection.projectedPercent(estimatedPercent: 40, elapsedFraction: 0) == nil)
}

@Test func availableExactlyAtTheThreshold() {
    #expect(Projection.projectedPercent(estimatedPercent: 1, elapsedFraction: 0.02) != nil)
}

@Test func noEstimateMeansNoProjection() {
    #expect(Projection.projectedPercent(estimatedPercent: nil, elapsedFraction: 0.5) == nil)
}

// MARK: - The rate is measured over the allowance epoch

// Anthropic re-issues the weekly allowance *inside* a window without moving
// `resets_at`. Pace answers "where should I be" and is unchanged — the window
// did not change, so the window is not restated. Projection answers "how fast
// am I going", and a rate has to be measured over the period the allowance it
// is burning has actually been running.

/// Swapping only the fraction projects 30/0.02 = 1500% on a partial top-up.
@Test func projectionOffsetsByTheEpochStartPercent() {
    let p = Projection.projectedPercent(estimatedPercent: 35, elapsedFraction: 0.1,
                                        epochStartPercent: 30)
    #expect(p == 80)   // 30 + (35-30)/0.1
}

/// POSITIVE CONTROL: with no re-grant the formula must be byte-identical to
/// today's, or every existing window silently changes behaviour.
@Test func projectionIsUnchangedWithoutARegrant() {
    #expect(Projection.projectedPercent(estimatedPercent: 50, elapsedFraction: 0.5,
                                        epochStartPercent: 0) == 100)
}

/// The noise floor is not skipped just because an epoch is open. A minutes-old
/// epoch is exactly the near-zero denominator the guard exists to refuse, and
/// it is the *only* thing standing between it and a projection.
@Test func aThinEpochIsStillSuppressed() {
    #expect(Projection.projectedPercent(estimatedPercent: 9, elapsedFraction: 0.019,
                                        epochStartPercent: 2) == nil)
}
