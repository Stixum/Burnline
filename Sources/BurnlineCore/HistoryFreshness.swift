import Foundation

/// When the History window last read the archive, and under which revision.
///
/// `revision` is `HistoryWriter.revision` as it stood when the read began, so a
/// write that lands mid-read counts as unread and triggers the next one.
public struct HistoryReadState: Equatable, Sendable {
    public let readAt: Date
    public let revision: Int

    public init(readAt: Date, revision: Int) {
        self.readAt = readAt
        self.revision = revision
    }
}

/// The History header's line about how current the window's read is.
///
/// 🔴 **Why it exists.** The window draws its read beside a live "now" line, so
/// an old read looks current: on 2026-11-26 the curve ended at 41% a day after
/// the archive held 74%, and nothing on screen said so. The reload now follows
/// `HistoryWriter.revision`, and this line is the check on the reload: if the
/// archive has moved and the window has not caught up within `grace`, it says
/// so in words, with a symbol, rather than drawing an old curve as if it were
/// new.
///
/// Every archive read degrades rather than throws (a missing or unreadable file
/// loads as empty), so "the read failed" is not a state the window can see.
/// What it can see is a reload that never landed, and that is what this flags.
public enum HistoryFreshness {
    /// How long a write may go unread before the line flags it. A reload starts
    /// the moment the revision moves and reads the archive in well under a
    /// second; a minute is long enough never to flash on an ordinary write and
    /// short enough that a stuck window is caught before anyone reads a day-old
    /// curve as today's.
    public static let grace: TimeInterval = 60

    public struct Line: Equatable, Sendable {
        public let text: String
        /// True when the archive holds writes this read does not. Drawn amber
        /// with a symbol, never by colour alone.
        public let isBehind: Bool
    }

    /// - Parameters:
    ///   - archiveRevision: `HistoryWriter.revision` as the app last saw it.
    ///   - archiveChangedAt: when the app saw that revision arrive; nil when it
    ///     has not moved since launch.
    public static func line(read: HistoryReadState, archiveRevision: Int,
                            archiveChangedAt: Date?, now: Date) -> Line {
        line(read: read, archiveRevision: archiveRevision, archiveChangedAt: archiveChangedAt,
             now: now, timeZone: .current)
    }

    public static func line(read: HistoryReadState, archiveRevision: Int,
                            archiveChangedAt: Date?, now: Date,
                            timeZone: TimeZone) -> Line {
        let isBehind = archiveRevision > read.revision
            && archiveChangedAt.map { now.timeIntervalSince($0) > grace } == true
        let when = readTime(read.readAt, now: now, timeZone: timeZone)
        return isBehind
            ? Line(text: "Last read at \(when). Newer readings are not shown yet.", isBehind: true)
            : Line(text: "Read at \(when)", isBehind: false)
    }

    /// On the machine's clock, to the nearest minute, through the same
    /// formatter as the reset. The weekday is added when the read is from
    /// another day, because a stuck window is exactly the case where "11:07 AM"
    /// would be read as today's.
    static func readTime(_ instant: Date, now: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let sameDay = calendar.isDate(ResetSchedule.toTheMinute(instant), inSameDayAs: now)
        return ResetSchedule.description(of: instant, sameDay ? .clock : .abbreviated,
                                         on: timeZone)
    }
}
