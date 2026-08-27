import Foundation

/// Which threshold notifications have already fired, so a signal fires once
/// per window and re-arms on that window's reset.
///
/// A mark records the window it fired in *and the threshold it fired at*. It
/// suppresses only while the current threshold equals the recorded one — so
/// editing a threshold re-arms the signal with no clear-on-edit hook, and this
/// file needs no coordination with settings.json. Accepted consequence, per the
/// spec: oscillating a threshold can fire more than once per window; each edit
/// expresses fresh intent.
public struct NotificationMarks: Equatable, Sendable, Codable {
    /// Bump when a stored mark's meaning changes. Same treatment as
    /// `RateLimitHighWater`: discard, never migrate — this is derived state and
    /// the worst case after a discard is one repeated notification.
    public static let currentVersion = 1

    public struct Mark: Equatable, Sendable, Codable {
        public var resetsAt: TimeInterval
        public var threshold: Double

        public init(resetsAt: TimeInterval, threshold: Double) {
            self.resetsAt = resetsAt
            self.threshold = threshold
        }
    }

    public var version: Int
    public var behindPace: Mark?
    public var weekly: Mark?
    /// Keyed to the 5-hour window's *own* reset instant — it rolls several
    /// times inside one weekly window, and neither says anything about the
    /// other.
    public var fiveHour: Mark?

    public init(version: Int = NotificationMarks.currentVersion,
                behindPace: Mark? = nil, weekly: Mark? = nil, fiveHour: Mark? = nil) {
        self.version = version
        self.behindPace = behindPace
        self.weekly = weekly
        self.fiveHour = fiveHour
    }

    public var isCompatible: Bool { version == Self.currentVersion }

    /// Reset instants compare with the shared 60s tolerance — the two capture
    /// sources describe the same window to different precision. Thresholds
    /// compare exactly: they come from steppers, not arithmetic.
    public static func suppresses(_ mark: Mark?, resetsAt: TimeInterval,
                                  threshold: Double) -> Bool {
        guard let mark else { return false }
        return abs(mark.resetsAt - resetsAt) <= WindowLedger.sameResetTolerance
            && mark.threshold == threshold
    }
}

public struct NotificationMarksStore: Sendable {
    private let url: URL

    public init(directory: URL = ApplicationSupport.directory()) {
        url = directory.appendingPathComponent("notification-marks.json")
    }

    /// A file with no version, or one this build doesn't know, is discarded.
    public func load() -> NotificationMarks {
        guard let data = try? Data(contentsOf: url),
              let marks = try? JSONDecoder().decode(NotificationMarks.self, from: data),
              marks.isCompatible
        else { return NotificationMarks() }
        return marks
    }

    public func save(_ marks: NotificationMarks) throws {
        try JSONEncoder().encode(marks).write(to: url, options: .atomic)
    }
}
