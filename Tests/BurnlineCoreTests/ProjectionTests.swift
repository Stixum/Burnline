import Testing
@testable import BurnlineCore

@Test func extrapolatesCurrentBurnToEndOfWindow() {
    // 40% consumed at 71.4% elapsed lands at ~56%.
    let projected = Projection.projectedPercent(estimatedPercent: 40, elapsedFraction: 5.0 / 7.0)
    #expect(abs(projected! - 56) < 0.01)
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
