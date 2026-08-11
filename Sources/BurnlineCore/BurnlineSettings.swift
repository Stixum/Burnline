import Foundation

public struct BurnlineSettings: Equatable, Sendable, Codable {
    public var resetSchedule: ResetSchedule
    public var weights: Weights
    public var calibrationAnchors: [CalibrationAnchor]
    public var launchAtLogin: Bool

    public init(resetSchedule: ResetSchedule, weights: Weights,
                calibrationAnchors: [CalibrationAnchor], launchAtLogin: Bool) {
        self.resetSchedule = resetSchedule
        self.weights = weights
        self.calibrationAnchors = calibrationAnchors
        self.launchAtLogin = launchAtLogin
    }

    /// Thursday 09:00 local is a placeholder — the user sets this on first run.
    public static let `default` = BurnlineSettings(
        resetSchedule: ResetSchedule(weekday: 5, hour: 9),
        weights: .default,
        calibrationAnchors: [],
        launchAtLogin: false
    )
}
