import Foundation

/// Which threshold notifications have already fired, so a signal fires once
/// per allowance and re-arms when a new one begins.
///
/// A mark records the window it fired in, *the allowance epoch inside that
/// window*, and *the threshold it fired at*. It suppresses only while the
/// current threshold equals the recorded one — so editing a threshold re-arms
/// the signal with no clear-on-edit hook, and this file needs no coordination
/// with settings.json. Accepted consequence, per the spec: oscillating a
/// threshold can fire more than once per window; each edit expresses fresh
/// intent.
///
/// 🔴 Marks are never cleared imperatively when an epoch opens. A clear is a
/// write that can fail or race; a mark that no longer matches the current
/// epoch simply stops suppressing. That is the whole mechanism.
public struct NotificationMarks: Equatable, Sendable, Codable {
    /// Bump when a stored mark's meaning changes. Same treatment as
    /// `RateLimitHighWater`: discard, never migrate — this is derived state and
    /// the worst case after a discard is one repeated notification.
    ///
    /// v2 (2026-09-01): `Mark` gained `epochStartedAt`. A v1 file has no such
    /// key, so it neither decodes nor passes the version check — that *is* the
    /// migration; there is no migration code and there must not be.
    public static let currentVersion = 2

    public struct Mark: Equatable, Sendable, Codable {
        public var resetsAt: TimeInterval
        public var threshold: Double
        /// The allowance epoch this mark fired in: for the weekly signals the
        /// open re-grant's start, or the window's own start when no allowance
        /// has been re-issued; for the five-hour signal, that window's start.
        ///
        /// 🔴 NON-OPTIONAL on purpose, unlike `RateLimitHighWater.Mark.regrant`
        /// where the optional *is* the discriminator for "an epoch is open".
        /// Different type, different rule: a notification mark always fired
        /// inside some allowance, so there is always an instant to record. Do
        /// not harmonise the two.
        public var epochStartedAt: TimeInterval

        public init(resetsAt: TimeInterval, threshold: Double,
                    epochStartedAt: TimeInterval) {
            self.resetsAt = resetsAt
            self.threshold = threshold
            self.epochStartedAt = epochStartedAt
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
    /// sources describe the same window to different precision. Epoch instants
    /// compare the same way and for the same reason: a window start is derived
    /// from a ledger anchor whose fractional second comes and goes, and exact
    /// equality would hand every rebuild its own epoch. Thresholds compare
    /// exactly: they come from steppers, not arithmetic.
    ///
    /// `epochStartedAt` is required, never defaulted — a caller that forgot it
    /// would fall back to suppressing across a re-grant, which is the bug this
    /// dimension exists to fix.
    ///
    /// 🔴 For the FIVE-HOUR mark this comparison is redundant by construction
    /// and must not be special-cased away. That window's start is its reset
    /// less a fixed span, and a constant translation cancels under
    /// `abs(a - b) <= tol` — so the epoch clause can never decide a five-hour
    /// call the reset clause did not already decide. Its value is not
    /// discriminating power: it is that a real, required field forces the
    /// five-hour call site to *feed* something, which is the only reason a test
    /// can catch an edit that threads `weeklyEpoch` through there instead.
    /// Delete it as dead weight and that check has nothing left to hold onto.
    public static func suppresses(_ mark: Mark?, resetsAt: TimeInterval,
                                  threshold: Double,
                                  epochStartedAt: TimeInterval) -> Bool {
        guard let mark else { return false }
        return abs(mark.resetsAt - resetsAt) <= WindowLedger.sameResetTolerance
            && abs(mark.epochStartedAt - epochStartedAt) <= WindowLedger.sameResetTolerance
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
