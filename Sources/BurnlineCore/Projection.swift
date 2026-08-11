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

    /// Landing above 100% is the one thing in the popover that should change
    /// what you do next.
    public static func isOverLimit(_ projected: Double?) -> Bool {
        guard let projected else { return false }
        return projected > 100
    }

    /// The popover row value. Leads with the word, so the warning never rests on
    /// colour alone.
    public static func description(_ projected: Double?) -> String {
        guard let projected else { return "—" }
        let whole = "\(Int(projected.rounded()))% by reset"
        return isOverLimit(projected) ? "over limit · \(whole)" : whole
    }
}
