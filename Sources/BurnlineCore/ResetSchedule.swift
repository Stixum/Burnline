import Foundation

/// When the user's weekly limit resets.
public struct ResetSchedule: Equatable, Sendable, Codable {
    /// Calendar convention: 1 = Sunday ... 7 = Saturday.
    public var weekday: Int
    public var hour: Int
    public var minute: Int
    public var timeZoneIdentifier: String

    public var timeZone: TimeZone { TimeZone(identifier: timeZoneIdentifier) ?? .gmt }

    public init(weekday: Int, hour: Int, minute: Int = 0, timeZone: TimeZone = .current) {
        self.weekday = weekday
        self.hour = hour
        self.minute = minute
        self.timeZoneIdentifier = timeZone.identifier
    }
}
