import Foundation

/// One reading of the real percentage from Claude Code's `/usage`, paired with
/// the weighted units accumulated in the window at that moment.
public struct CalibrationAnchor: Equatable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var timestamp: Date
    public var observedPercent: Double
    public var unitsInWindow: Double

    public init(id: UUID = UUID(), timestamp: Date, observedPercent: Double, unitsInWindow: Double) {
        self.id = id
        self.timestamp = timestamp
        self.observedPercent = observedPercent
        self.unitsInWindow = unitsInWindow
    }
}

/// Derives the denominator Anthropic does not publish.
///
/// Nothing on this machine says how many tokens equal 100% of a weekly limit,
/// so it is fitted from the user's own `/usage` readings. The fit is forced
/// through the origin — zero units must mean zero percent — which also makes
/// the single-anchor case fall out as a plain divide.
public enum Calibration {
    public static let minimumPercent: Double = 5
    public static let maximumAge: TimeInterval = 60 * 86_400
    public static let anchorLimit = 8
    /// How many anchors are kept on disk. Larger than `anchorLimit` so the
    /// Settings list still shows recent history the fit itself ignores.
    public static let storageLimit = 20
    /// Beyond this the UI styles the calibration as stale.
    public static let stalenessThreshold: TimeInterval = 14 * 86_400

    /// What to persist after adding one.
    ///
    /// Distinct from `validAnchors`, which decides what the *fit* may use.
    /// Pruning here is about unbounded growth only, so it drops by age and count
    /// but never by the 5% floor — a rejected-but-recent reading has to stay
    /// visible in Settings, or entering one looks like the app swallowed it.
    public static func retained(_ anchors: [CalibrationAnchor], now: Date) -> [CalibrationAnchor] {
        anchors
            .filter { now.timeIntervalSince($0.timestamp) <= maximumAge }
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(storageLimit)
            .map { $0 }
    }

    public static func validAnchors(_ anchors: [CalibrationAnchor], now: Date) -> [CalibrationAnchor] {
        anchors
            .filter { $0.observedPercent >= minimumPercent }
            .filter { $0.unitsInWindow > 0 }
            .filter { now.timeIntervalSince($0.timestamp) <= maximumAge }
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(anchorLimit)
            .map { $0 }
    }

    /// Least squares through the origin: Sum(units * pct) / Sum(pct^2).
    public static func unitsPerPercent(_ anchors: [CalibrationAnchor], now: Date) -> Double? {
        let valid = validAnchors(anchors, now: now)
        guard !valid.isEmpty else { return nil }

        let numerator = valid.reduce(0.0) { $0 + $1.unitsInWindow * $1.observedPercent }
        let denominator = valid.reduce(0.0) { $0 + $1.observedPercent * $1.observedPercent }
        guard denominator > 0 else { return nil }

        let fitted = numerator / denominator
        return fitted > 0 ? fitted : nil
    }

    /// Uncapped on purpose — a value above 100 is meaningful.
    public static func estimatedPercent(unitsInWindow: Double,
                                        anchors: [CalibrationAnchor],
                                        now: Date) -> Double? {
        guard let perPercent = unitsPerPercent(anchors, now: now), perPercent > 0 else { return nil }
        return unitsInWindow / perPercent
    }

    /// Age of the freshest valid anchor, for the popover's staleness display.
    public static func age(of anchors: [CalibrationAnchor], now: Date) -> TimeInterval? {
        guard let newest = validAnchors(anchors, now: now).first else { return nil }
        return now.timeIntervalSince(newest.timestamp)
    }
}
