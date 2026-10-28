import Foundation

/// One reading of the real percentage from Claude Code's `/usage`, paired with
/// what the window had consumed at that moment.
public struct CalibrationAnchor: Equatable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var timestamp: Date
    public var observedPercent: Double
    /// Weighted under the weights in force when the anchor was taken. The fit
    /// reads `units(under:)`, never this, so a weight edit cannot rescale it.
    public var unitsInWindow: Double
    /// The window's raw tokens by model, the facts `unitsInWindow` was weighted
    /// from. Nil on anchors written by 1.6.3 and earlier, which keep their stored figure.
    public var tokensInWindow: [String: TokenCounts]?

    public init(id: UUID = UUID(), timestamp: Date, observedPercent: Double, unitsInWindow: Double) {
        self.id = id
        self.timestamp = timestamp
        self.observedPercent = observedPercent
        self.unitsInWindow = unitsInWindow
    }

    public init(timestamp: Date, observedPercent: Double,
                tokensInWindow: [String: TokenCounts], weights: Weights) {
        self.init(timestamp: timestamp, observedPercent: observedPercent,
                  unitsInWindow: Self.units(of: tokensInWindow, under: weights))
        self.tokensInWindow = tokensInWindow
    }

    /// The anchor's units under `weights`.
    public func units(under weights: Weights) -> Double {
        tokensInWindow.map { Self.units(of: $0, under: weights) } ?? unitsInWindow
    }

    private static func units(of tokens: [String: TokenCounts], under weights: Weights) -> Double {
        tokens.reduce(0) { $0 + ConsumptionModel.units(for: $1.value, model: $1.key, weights: weights) }
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

    /// The estimate with every anchor re-weighted under `weights`, the same
    /// weights `unitsInWindow` was computed under. Without this a weight edit
    /// divided units under the new weights by anchors under the old ones.
    public static func estimatedPercent(unitsInWindow: Double,
                                        anchors: [CalibrationAnchor],
                                        weights: Weights,
                                        now: Date) -> Double? {
        let reweighted = anchors.map { anchor in
            var anchor = anchor
            anchor.unitsInWindow = anchor.units(under: weights)
            return anchor
        }
        return estimatedPercent(unitsInWindow: unitsInWindow, anchors: reweighted, now: now)
    }

    /// Age of the freshest valid anchor, for the popover's staleness display.
    public static func age(of anchors: [CalibrationAnchor], now: Date) -> TimeInterval? {
        guard let newest = validAnchors(anchors, now: now).first else { return nil }
        return now.timeIntervalSince(newest.timestamp)
    }
}
