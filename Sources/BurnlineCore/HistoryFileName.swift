import Foundation

/// Maps a bucket to the cell file that holds it. ⚠️ Always UTC — see the test.
///
/// `bucket → file` must be a pure function of the bucket key. The archive's
/// dedupe rule is "one bucket belongs to one file, so line order settles
/// last-occurrence-wins". Resolve the ISO week in *local* time and a timezone
/// change moves a bucket's target file — after which a rewritten row lands
/// somewhere else and the dedupe argument silently fails. There is
/// deliberately no `timeZone:` parameter for this reason.
public enum HistoryFileName {
    static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    public static func forBucket(_ bucket: Int) -> String {
        forDate(Date(timeIntervalSince1970: Double(bucket)))
    }

    public static func forDate(_ date: Date) -> String {
        let parts = utcCalendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        let year = parts.yearForWeekOfYear ?? 1970
        let week = parts.weekOfYear ?? 1
        return String(format: "%04d-W%02d.jsonl", year, week)
    }

    /// Every file touched by `[from, to]`, in order, deduplicated.
    public static func forRange(from: Date, to: Date) -> [String] {
        guard from <= to else { return [] }
        var names: [String] = []
        var seen = Set<String>()
        var cursor = from
        while cursor <= to {
            let name = forDate(cursor)
            if seen.insert(name).inserted { names.append(name) }
            guard let next = utcCalendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        let last = forDate(to)
        if seen.insert(last).inserted { names.append(last) }
        return names
    }
}
