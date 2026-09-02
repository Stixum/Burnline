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

// MARK: - Saying when the reset is

extension ResetSchedule {

    /// How much of the reset to print.
    ///
    /// The app names the same instant at three widths — a settings sentence, a
    /// popover row 272pt wide, and the clock time alone inside a sentence about
    /// day boundaries — and it used to do it with three hand-rolled
    /// `DateFormatter`s in two view bodies. Same instant, three formats, one
    /// place tests can watch.
    public enum Format: Sendable, CaseIterable {
        /// `Tuesday 9:00 PM`
        case full
        /// `Tue 9:00 PM` — for the popover row, which has no width to spare.
        case abbreviated
        /// `9:00 PM`
        case clock
    }

    /// The schedule exactly as configured: `Tuesday 9:00 PM (Central Time)`.
    ///
    /// Built from the fields rather than from a synthesised instant, so it
    /// cannot be moved by a DST transition in whatever reference week the
    /// synthesis happened to pick.
    ///
    /// ⚠️ **Names the zone in words, unlike the instant form.** This describes
    /// the fallback the user typed in Settings, and `America/Chicago` is a
    /// database identifier, not a place anyone says they are. The instant form
    /// needs none of it: a reset the app actually observed is already being read
    /// on the user's own clock.
    public func description() -> String {
        let day = Self.weekdaySymbols[max(0, min(6, weekday - 1))]
        let zone = timeZone.localizedName(for: .generic, locale: Self.locale)
            ?? timeZoneIdentifier
        return "\(day) \(Self.clock(hour: hour, minute: minute)) (\(zone))"
    }

    /// A reset instant, rendered on this schedule's own clock.
    ///
    /// Used wherever the *observed* reset is what matters — Claude Code's
    /// `resets_at` pins the window exactly, and once it does, the fields above
    /// are unused.
    ///
    /// `en_US_POSIX`, for the reason `Snapshot.Regrant.rowValue` records: a
    /// custom `dateFormat` otherwise picks up the user's locale symbols and
    /// prints things like `14:14 PM`. The whole UI is hardcoded English.
    public func description(of instant: Date, _ format: Format = .full) -> String {
        let formatter = DateFormatter()
        formatter.locale = Self.locale
        formatter.timeZone = timeZone
        switch format {
        case .full:        formatter.dateFormat = "EEEE h:mm a"
        case .abbreviated: formatter.dateFormat = "EEE h:mm a"
        case .clock:       formatter.dateFormat = "h:mm a"
        }
        return formatter.string(from: instant)
    }

    private static let locale = Locale(identifier: "en_US_POSIX")

    private static let weekdaySymbols = ["Sunday", "Monday", "Tuesday", "Wednesday",
                                         "Thursday", "Friday", "Saturday"]

    /// 24-hour fields → a 12-hour clock string. Arithmetic rather than a
    /// `DateFormatter`, because there is no instant here to format — only the
    /// two numbers a stepper produced.
    private static func clock(hour: Int, minute: Int) -> String {
        let bounded = max(0, min(23, hour))
        let suffix = bounded < 12 ? "AM" : "PM"
        let twelve = bounded % 12 == 0 ? 12 : bounded % 12
        return String(format: "%d:%02d %@", twelve, max(0, min(59, minute)), suffix)
    }
}
