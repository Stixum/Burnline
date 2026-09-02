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

    /// Marks a figure that is no longer a reading but an extrapolation.
    ///
    /// **It cannot be colour.** macOS tints menu bar content against a light or
    /// dark bar depending on the user's wallpaper, so a hardcoded colour is
    /// unreadable on one of them — see the popover, which owns all colour. A
    /// tilde carries it in one character, and reads as "approximately"
    /// everywhere.
    ///
    /// Added 2026-08-12: the bar showed a confident `75` for 2h18m while the
    /// true figure had moved to 76. The popover said so; the bar is what gets
    /// looked at.
    private static let approximate = "~"

    /// Only a usage figure can be stale. The pace target is calendar arithmetic
    /// and exact, so marking it would claim an uncertainty that never exists.
    private static func mark(_ text: String, _ snapshot: Snapshot) -> String {
        guard snapshot.estimatedPercent != nil,
              CaptureAge.isStale(snapshot.liveAge) else { return text }
        return approximate + text
    }

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
            return mark("\(whole(estimated))/\(pace)", snapshot)

        case .delta:
            // `Snapshot.delta` is target - estimate, so positive means under.
            // Inverted here: on a usage meter a leading + reads as overspent.
            guard let delta = snapshot.delta(target) else { return empty }
            let over = whole(-delta)
            return mark(over > 0 ? "+\(over)" : "\(over)", snapshot)

        case .projection:
            guard let projected = snapshot.projectedPercent else { return empty }
            return mark("\(whole(projected))%", snapshot)

        case .fiveHour:
            guard let fiveHour = snapshot.fiveHour else { return empty }
            return "\(whole(fiveHour.usedPercent))%"

        case .used:
            guard let estimated = snapshot.estimatedPercent else { return empty }
            return mark("\(whole(estimated))%", snapshot)
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
            let delta = abs(snapshot.delta(target) ?? 0)
            let direction = (snapshot.isUnder(target) ?? true) ? "ahead of pace" : "behind pace"
            label = "Burnline: \(whole(estimated)) percent used, \(pace) percent \(frame), "
                + "\(DisplayValue.points(delta)) \(direction)"
        } else {
            label = "Burnline: \(pace) percent \(frame), no usage figure yet"
        }

        // A tilde is invisible to a screen reader, so the spoken label has to
        // carry the same fact in words.
        if snapshot.estimatedPercent != nil, CaptureAge.isStale(snapshot.liveAge) {
            label += ", carried forward from local token counts for "
                + CaptureAge.description(snapshot.liveAge)
        }

        if display == .fiveHour, let fiveHour = snapshot.fiveHour {
            label += ". 5-hour window \(whole(fiveHour.usedPercent)) percent used, "
                + "\(fiveHour.remainingDescription) left"
        }
        return label
    }

    private static func whole(_ value: Double) -> Int { DisplayValue.whole(value) }
}
