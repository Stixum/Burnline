import Foundation

/// `Double` → `Int` for display, saturating rather than trapping.
///
/// **Swift traps on `Int(Double)`** when the value is NaN, infinite, or outside
/// `Int`'s range — a hard crash, not an exception. Every figure this app shows
/// descends from one of:
///
/// - `rate-limits.json`, written by a shell script that any local process could
///   also write,
/// - `scan-cache.json` and `settings.json`, both plain JSON on disk,
/// - a **weight typed into the Settings text field**, which multiplies token
///   counts and can overflow the product to infinity.
///
/// That last one needs no attacker at all. A menu bar app should render a silly
/// number, never die, so every Double→Int display conversion goes through here.
public enum DisplayValue {
    /// Percentages are clamped hard: past this the figure has stopped meaning
    /// anything, and the label is only a few characters wide.
    public static let percentCeiling: Double = 999

    public static func whole(_ value: Double, ceiling: Double = percentCeiling) -> Int {
        // NaN has no sign to saturate toward, and `min`/`max` propagate it —
        // report nothing rather than a misleading maximum.
        guard !value.isNaN else { return 0 }
        return Int(min(max(value, -ceiling), ceiling).rounded())
    }

    /// Durations need a far larger ceiling than percentages, but still a finite
    /// one. A century is beyond any window this app models.
    public static func seconds(_ value: Double) -> Int {
        whole(value, ceiling: 100 * 365 * 86_400)
    }

    /// Like `whole`, but floors. 42.99% is not 43% of the way through anything.
    ///
    /// Clamps before converting for the same reason `whole` does: `Int(Double)`
    /// traps outside `Int`'s range, and a 20-digit integer in JSON decodes to a
    /// perfectly finite `1e20`.
    public static func floor(_ value: Double, ceiling: Double = percentCeiling) -> Int {
        guard !value.isNaN else { return 0 }
        return Int(min(max(value, -ceiling), ceiling).rounded(.down))
    }
}
