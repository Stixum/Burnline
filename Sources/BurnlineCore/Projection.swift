import Foundation

/// Linear extrapolation of the current burn rate to the end of the window.
public enum Projection {
    /// Below this the denominator is too small for the result to mean anything
    /// — roughly the first 3.4 hours of a 7-day window, and 2% of whatever is
    /// left of one once a re-grant opens a shorter epoch inside it. That second
    /// reading is why the noise floor now recurs mid-week: see below.
    public static let minimumElapsedFraction: Double = 0.02

    /// The rate is measured over the **allowance epoch**, so `elapsedFraction`
    /// is the epoch's — its own start to the reset — and `epochStartPercent` is
    /// where it opened. The burn is what the epoch has spent, and the landing
    /// point is that carried to the reset and added back on top of the start.
    ///
    /// 🔴 A different denominator from `targetPercent`, deliberately, and the
    /// two coexist on one screen. Pace answers *where should I be*: the window
    /// did not change — a re-grant re-issues the allowance without touching
    /// `resets_at` — so the window is not restated. Projection answers *how fast
    /// am I going*, and a rate can only be measured over the period the
    /// allowance being burned has actually existed.
    ///
    /// Without a re-grant the epoch *is* the window and `epochStartPercent` is
    /// 0, which reduces to `estimate / elapsedFraction` exactly — `x - 0` and
    /// `0 + y` are both exact in binary floating point, so every ordinary
    /// window is untouched to the last bit.
    public static func projectedPercent(estimatedPercent: Double?,
                                        elapsedFraction: Double,
                                        epochStartPercent: Double = 0) -> Double? {
        guard let estimate = estimatedPercent,
              elapsedFraction >= minimumElapsedFraction else { return nil }
        return epochStartPercent + (estimate - epochStartPercent) / elapsedFraction
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
        let whole = "\(DisplayValue.whole(projected))% by reset"
        return isOverLimit(projected) ? "over limit · \(whole)" : whole
    }
}
