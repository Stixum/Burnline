import Foundation

/// The menu bar string. Deliberately free of color — macOS renders this
/// against a light or dark bar depending on the user's wallpaper, so the
/// label must survive both. All color lives in the popover.
public enum MenuBarFormatter {
    private static let displayCeiling: Double = 999
    /// Shown when the selected format has nothing to say. Never substitute
    /// another number for it — at four characters wide, an unlabelled figure in
    /// the wrong format reads as the right one.
    private static let empty = "—"

    public static func text(for snapshot: Snapshot,
                            target: TargetMode = .realTime,
                            display: MenuBarMode = .usedOverTarget) -> String {
        if snapshot.isScanning && snapshot.estimatedPercent == nil { return "…" }

        switch display {
        case .usedOverTarget:
            let pace = whole(snapshot.activeTarget(target))
            // Pace-only is a valid state for this format specifically: the clock
            // target alone is the app this started as.
            guard let estimated = snapshot.estimatedPercent else { return "\(pace)" }
            return "\(whole(estimated))/\(pace)"

        case .delta:
            // `Snapshot.delta` is target - estimate, so positive means under.
            // Inverted here: on a usage meter a leading + reads as overspent.
            guard let delta = snapshot.delta(target) else { return empty }
            let over = whole(-delta)
            return over > 0 ? "+\(over)" : "\(over)"

        case .projection:
            guard let projected = snapshot.projectedPercent else { return empty }
            return "\(whole(projected))%"

        case .fiveHour:
            guard let fiveHour = snapshot.fiveHour else { return empty }
            return "\(whole(fiveHour.usedPercent))%"

        case .used:
            guard let estimated = snapshot.estimatedPercent else { return empty }
            return "\(whole(estimated))%"
        }
    }

    /// Stays comprehensive whichever format is on screen. The visual is four
    /// characters wide; the spoken version has no such limit, so abbreviating it
    /// would lose information for no reason.
    public static func accessibilityLabel(for snapshot: Snapshot,
                                          target: TargetMode = .realTime,
                                          display: MenuBarMode = .usedOverTarget) -> String {
        let pace = whole(snapshot.activeTarget(target))
        let frame = target == .endOfDay ? "allowed by the end of today" : "through the weekly window"

        var label: String
        if let estimated = snapshot.estimatedPercent {
            let delta = abs(whole(snapshot.delta(target) ?? 0))
            let direction = (snapshot.isUnder(target) ?? true) ? "under budget" : "over budget"
            label = "Burnline: \(whole(estimated)) percent used, \(pace) percent \(frame), "
                + "\(delta) points \(direction)"
        } else {
            label = "Burnline: \(pace) percent \(frame), usage not yet calibrated"
        }

        if display == .fiveHour, let fiveHour = snapshot.fiveHour {
            label += ". 5-hour window \(whole(fiveHour.usedPercent)) percent used, "
                + "\(fiveHour.remainingDescription) left"
        }
        return label
    }

    private static func whole(_ value: Double) -> Int {
        Int(min(max(value, -displayCeiling), displayCeiling).rounded())
    }
}
