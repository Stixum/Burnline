import Foundation

/// What the menu bar label shows.
///
/// A menu bar slot is about four characters wide, so it carries exactly one
/// fact. Which fact is worth that slot is a matter of taste — hence a setting
/// rather than a judgement baked into the code.
///
/// Orthogonal to `TargetMode`: that decides *which target* the comparison is
/// made against, this decides *what gets displayed*.
public enum MenuBarMode: String, Equatable, Sendable, Codable, CaseIterable {
    /// `64/65` — consumption over the pace target.
    case usedOverTarget
    /// `+3` / `-1` — points over or under the pace target.
    case delta
    /// `98%` — where the week lands at the current burn rate.
    case projection
    /// `3%` — the 5-hour window rather than the weekly one.
    case fiveHour
    /// `64%` — consumption alone.
    case used

    public var title: String {
        switch self {
        case .usedOverTarget: return "Used / target"
        case .delta:          return "Delta"
        case .projection:     return "Projection"
        case .fiveHour:       return "5-hour"
        case .used:           return "Used"
        }
    }

    public var explanation: String {
        switch self {
        case .usedOverTarget:
            return "Consumption over the pace target — 64/65."
        case .delta:
            return "Points over or under pace. A leading + means over budget — 64/65 shows as -1."
        case .projection:
            return "Where the week lands if you carry on at this rate — 98%."
        case .fiveHour:
            return "The 5-hour limit instead of the weekly one — 3%. Blank on plans that don't report it."
        case .used:
            return "Consumption on its own, no target — 64%."
        }
    }
}
