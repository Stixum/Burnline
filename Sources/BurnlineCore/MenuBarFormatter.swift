import Foundation

/// The menu bar string. Deliberately free of color — macOS renders this
/// against a light or dark bar depending on the user's wallpaper, so the
/// label must survive both. All color lives in the popover.
public enum MenuBarFormatter {
    private static let displayCeiling: Double = 999

    public static func text(for snapshot: Snapshot, mode: TargetMode = .realTime) -> String {
        if snapshot.isScanning && snapshot.estimatedPercent == nil { return "…" }
        let target = whole(snapshot.activeTarget(mode))
        guard let estimated = snapshot.estimatedPercent else { return "\(target)" }
        return "\(whole(estimated))/\(target)"
    }

    public static func accessibilityLabel(for snapshot: Snapshot,
                                          mode: TargetMode = .realTime) -> String {
        let target = whole(snapshot.activeTarget(mode))
        let frame = mode == .endOfDay ? "allowed by the end of today" : "through the weekly window"
        guard let estimated = snapshot.estimatedPercent else {
            return "Burnline: \(target) percent \(frame), usage not yet calibrated"
        }
        let delta = abs(whole(snapshot.delta(mode) ?? 0))
        let direction = (snapshot.isUnder(mode) ?? true) ? "under budget" : "over budget"
        return "Burnline: \(whole(estimated)) percent used, \(target) percent \(frame), \(delta) points \(direction)"
    }

    private static func whole(_ value: Double) -> Int {
        Int(min(max(value, -displayCeiling), displayCeiling).rounded())
    }
}
