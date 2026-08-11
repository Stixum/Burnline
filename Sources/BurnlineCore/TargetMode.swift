import Foundation

/// Which pace target the headline numbers compare against.
///
/// Both are always computed and both are always drawn on the bar; this only
/// decides which one the menu bar string and the delta use, because a menu bar
/// slot has room for exactly one.
public enum TargetMode: String, Equatable, Sendable, Codable, CaseIterable {
    /// Where you should be this instant — `elapsed / total`. Strictest reading.
    case realTime
    /// Where you may be once the current window-day ends. Gives today a budget
    /// instead of a continuously creeping line.
    case endOfDay

    public var title: String {
        switch self {
        case .realTime: return "Right now"
        case .endOfDay: return "End of day"
        }
    }

    public var explanation: String {
        switch self {
        case .realTime: return "Are you on pace this second?"
        case .endOfDay: return "What can you still spend today?"
        }
    }
}
