import Foundation

/// The menu bar string. Deliberately free of color — macOS renders this
/// against a light or dark bar depending on the user's wallpaper, so the
/// label must survive both. All color lives in the popover.
public enum MenuBarFormatter {
    private static let displayCeiling: Double = 999

    public static func text(for snapshot: Snapshot) -> String {
        if snapshot.isScanning && snapshot.estimatedPercent == nil { return "…" }
        let target = whole(snapshot.targetPercent)
        guard let estimated = snapshot.estimatedPercent else { return "\(target)" }
        return "\(whole(estimated))/\(target)"
    }

    public static func accessibilityLabel(for snapshot: Snapshot) -> String {
        let target = whole(snapshot.targetPercent)
        guard let estimated = snapshot.estimatedPercent else {
            return "Burnline: \(target) percent through the weekly window, usage not yet calibrated"
        }
        let delta = abs(whole(snapshot.deltaPercent ?? 0))
        let direction = (snapshot.isUnderBudget ?? true) ? "under budget" : "over budget"
        return "Burnline: \(whole(estimated)) percent used, \(target) percent through the window, \(delta) points \(direction)"
    }

    private static func whole(_ value: Double) -> Int {
        Int(min(max(value, -displayCeiling), displayCeiling).rounded())
    }
}
