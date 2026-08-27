import Foundation

/// The threshold-notification settings: one master switch, one number per
/// signal. Off by default — notification permission is only ever requested on
/// the first enable, so a user who never touches this pays nothing.
public struct NotificationSettings: Equatable, Sendable, Codable {
    public var enabled: Bool
    /// Fires when the delta reaches this many points *behind* the target.
    public var behindPacePoints: Double
    /// Fires when the displayed weekly estimate reaches this percentage.
    public var weeklyPercent: Double
    /// Fires when the capture's own 5-hour figure reaches this percentage.
    public var fiveHourPercent: Double

    public init(enabled: Bool, behindPacePoints: Double,
                weeklyPercent: Double, fiveHourPercent: Double) {
        self.enabled = enabled
        self.behindPacePoints = behindPacePoints
        self.weeklyPercent = weeklyPercent
        self.fiveHourPercent = fiveHourPercent
    }

    public static let `default` = NotificationSettings(
        enabled: false, behindPacePoints: 10, weeklyPercent: 90, fiveHourPercent: 80)

    /// Zero is illegal everywhere — a threshold of 0 under `>=` fires
    /// permanently. 100 is illegal for the percent signals: unreachable in
    /// practice, the window resets first. NaN falls back to the default —
    /// deliberately *unlike* `Weights.sanitized()`, which clamps NaN to 0:
    /// zero is a legal weight and an illegal threshold.
    public func sanitized() -> NotificationSettings {
        func clamp(_ value: Double, to range: ClosedRange<Double>,
                   fallback: Double) -> Double {
            value.isNaN ? fallback : min(max(value, range.lowerBound), range.upperBound)
        }
        return NotificationSettings(
            enabled: enabled,
            behindPacePoints: clamp(behindPacePoints, to: 1...100,
                                    fallback: Self.default.behindPacePoints),
            weeklyPercent: clamp(weeklyPercent, to: 1...99,
                                 fallback: Self.default.weeklyPercent),
            fiveHourPercent: clamp(fiveHourPercent, to: 1...99,
                                   fallback: Self.default.fiveHourPercent))
    }
}
