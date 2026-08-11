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
    /// Where `estimatedPercent` came from — exact, calibrated, or absent.
    public let source: UsageSource
    /// True when the window came from Claude Code's `resets_at` rather than the
    /// user's configured schedule.
    public let isScheduleAutomatic: Bool
    public let isScanning: Bool
    public let dayBoundary: DayBoundary
    /// Timezone the calendar-day boundary is evaluated in.
    public let dayTimeZoneIdentifier: String

    public init(window: Window, targetPercent: Double, estimatedPercent: Double?,
                projectedPercent: Double?, unitsInWindow: Double,
                calibrationAge: TimeInterval?, source: UsageSource = .paceOnly,
                isScheduleAutomatic: Bool = false, isScanning: Bool,
                dayBoundary: DayBoundary = .windowDay,
                dayTimeZoneIdentifier: String = TimeZone.current.identifier) {
        self.window = window
        self.targetPercent = targetPercent
        self.estimatedPercent = estimatedPercent
        self.projectedPercent = projectedPercent
        self.unitsInWindow = unitsInWindow
        self.calibrationAge = calibrationAge
        self.source = source
        self.isScheduleAutomatic = isScheduleAutomatic
        self.isScanning = isScanning
        self.dayBoundary = dayBoundary
        self.dayTimeZoneIdentifier = dayTimeZoneIdentifier
    }

    /// Age of the live capture, when there is one.
    public var liveAge: TimeInterval? {
        guard case let .live(capturedAt) = source else { return nil }
        return Date().timeIntervalSince(capturedAt)
    }

    /// Where you may be by the end of the current day.
    public var endOfDayPercent: Double {
        window.endOfDayPercent(boundary: dayBoundary,
                               timeZone: TimeZone(identifier: dayTimeZoneIdentifier) ?? .current)
    }

    /// The target the headline numbers compare against, per the user's mode.
    public func activeTarget(_ mode: TargetMode) -> Double {
        switch mode {
        case .realTime: return targetPercent
        case .endOfDay: return endOfDayPercent
        }
    }

    /// Positive means under budget. `nil` without a usage figure.
    public func delta(_ mode: TargetMode) -> Double? {
        guard let estimate = estimatedPercent else { return nil }
        return activeTarget(mode) - estimate
    }

    public func isUnder(_ mode: TargetMode) -> Bool? {
        guard let delta = delta(mode) else { return nil }
        return delta >= 0
    }

    /// Positive means under budget, against the real-time target.
    public var deltaPercent: Double? { delta(.realTime) }

    public var isUnderBudget: Bool? { isUnder(.realTime) }

    /// No calibration yet — show the pace target alone.
    public var isPaceOnly: Bool { estimatedPercent == nil }

    public var isCalibrationStale: Bool {
        guard let age = calibrationAge else { return false }
        return age > Calibration.stalenessThreshold
    }
}
