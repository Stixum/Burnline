import Foundation

/// How often, at most, to refresh the usage anchor.
///
/// A **ceiling**, not a fixed cadence: pressure on any limit tightens it below
/// this, but nothing ever loosens it past. Chosen so no option exceeds an hour —
/// beyond that the figure is mostly the app's own arithmetic and the anchor
/// stops being an anchor.
public enum RefreshInterval: Int, Codable, CaseIterable, Sendable {
    case fifteen = 15
    case thirty = 30
    case fortyFive = 45
    case sixty = 60

    public var seconds: TimeInterval { TimeInterval(rawValue * 60) }
    public var title: String { "\(rawValue) min" }
}
