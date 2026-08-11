import Foundation

public struct BurnlineSettings: Equatable, Sendable, Codable {
    public var resetSchedule: ResetSchedule
    public var weights: Weights
    public var calibrationAnchors: [CalibrationAnchor]
    public var launchAtLogin: Bool
    public var targetMode: TargetMode
    public var dayBoundary: DayBoundary

    public init(resetSchedule: ResetSchedule, weights: Weights,
                calibrationAnchors: [CalibrationAnchor], launchAtLogin: Bool,
                targetMode: TargetMode = .realTime,
                dayBoundary: DayBoundary = .windowDay) {
        self.resetSchedule = resetSchedule
        self.weights = weights
        self.calibrationAnchors = calibrationAnchors
        self.launchAtLogin = launchAtLogin
        self.targetMode = targetMode
        self.dayBoundary = dayBoundary
    }

    /// Thursday 09:00 local is a placeholder — replaced by the real reset as
    /// soon as a live capture lands, and settable by hand until then.
    public static let `default` = BurnlineSettings(
        resetSchedule: ResetSchedule(weekday: 5, hour: 9),
        weights: .default,
        calibrationAnchors: [],
        launchAtLogin: false,
        targetMode: .realTime,
        dayBoundary: .windowDay
    )

    // Hand-written so that settings files predating a field still decode.
    // A missing key must fall back rather than throw and reset everything.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        resetSchedule = try container.decode(ResetSchedule.self, forKey: .resetSchedule)
        weights = try container.decode(Weights.self, forKey: .weights)
        calibrationAnchors = try container.decode([CalibrationAnchor].self, forKey: .calibrationAnchors)
        launchAtLogin = try container.decode(Bool.self, forKey: .launchAtLogin)
        targetMode = try container.decodeIfPresent(TargetMode.self, forKey: .targetMode) ?? .realTime
        dayBoundary = try container.decodeIfPresent(DayBoundary.self, forKey: .dayBoundary) ?? .windowDay
    }
}
