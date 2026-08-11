import Foundation

/// Linear extrapolation of the current burn rate to the end of the window.
public enum Projection {
    /// Below this the denominator is too small for the result to mean anything
    /// — roughly the first 3.4 hours of a 7-day window.
    public static let minimumElapsedFraction: Double = 0.02

    public static func projectedPercent(estimatedPercent: Double?, elapsedFraction: Double) -> Double? {
        guard let estimate = estimatedPercent,
              elapsedFraction >= minimumElapsedFraction else { return nil }
        return estimate / elapsedFraction
    }
}
