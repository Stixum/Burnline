import Foundation

/// Everything the UI renders, computed in one pass. Views read this and do no
/// arithmetic of their own.
public struct Snapshot: Equatable, Sendable {
    public let window: Window
    /// Exact. Where the clock says you should be.
    public let targetPercent: Double
    /// `nil` until the user has supplied at least one calibration anchor.
    public let estimatedPercent: Double?
    public let projectedPercent: Double?
    public let unitsInWindow: Double
    public let calibrationAge: TimeInterval?
    public let isScanning: Bool

    public init(window: Window, targetPercent: Double, estimatedPercent: Double?,
                projectedPercent: Double?, unitsInWindow: Double,
                calibrationAge: TimeInterval?, isScanning: Bool) {
        self.window = window
        self.targetPercent = targetPercent
        self.estimatedPercent = estimatedPercent
        self.projectedPercent = projectedPercent
        self.unitsInWindow = unitsInWindow
        self.calibrationAge = calibrationAge
        self.isScanning = isScanning
    }

    /// Positive means under budget.
    public var deltaPercent: Double? {
        guard let estimate = estimatedPercent else { return nil }
        return targetPercent - estimate
    }

    public var isUnderBudget: Bool? {
        guard let delta = deltaPercent else { return nil }
        return delta >= 0
    }

    /// No calibration yet — show the pace target alone.
    public var isPaceOnly: Bool { estimatedPercent == nil }

    public var isCalibrationStale: Bool {
        guard let age = calibrationAge else { return false }
        return age > Calibration.stalenessThreshold
    }
}
