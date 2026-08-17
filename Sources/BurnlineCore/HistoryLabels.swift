import Foundation

/// Every string the History window prints for a figure, in one tested place.
///
/// **No view in this codebase does arithmetic, and none of them formats a rule
/// either.** Two of the strings below carry a decision rather than a format:
/// a missing percentage must read as *not recorded* and never as `0%`, and a
/// percentage that was captured mid-week must carry when it was seen. Neither
/// branch renders on today's archive — every window in it is "not recorded" —
/// so a test is the only thing that can hold them upright until they do.
public enum HistoryLabels {

    // MARK: - Units

    /// Weighted units, compacted. A real week is ~8.6 × 10⁹ of them.
    ///
    /// The absolute scale is meaningless by construction (`Weights` documents
    /// that calibration divides it out), so the digits past the first two are
    /// noise dressed as precision. `8.6B` compares week to week, which is the
    /// only comparison this figure supports.
    public static func units(_ value: Double) -> String {
        units(value, isLowerBound: false)
    }

    /// `isLowerBound` marks a total drawn from a window with a hole in its
    /// coverage. The archived tokens are real; the ones burned while the app was
    /// not running are unknown and missing from the sum, so the figure is a
    /// floor and has to say so.
    ///
    /// An overload rather than a defaulted parameter, matching
    /// `ApplicationSupport.directory()`: a default argument generator is emitted
    /// into each caller's object file, so adding one later renames the symbol
    /// every existing caller references.
    public static func units(_ value: Double, isLowerBound: Bool) -> String {
        // A weight typed into the Settings field can overflow the product to
        // infinity, and `String(format:)` would print `inf`. Same class of
        // defect `DisplayValue` exists for.
        guard value.isFinite else { return "—" }
        let prefix = isLowerBound ? "≥" : ""
        let magnitude = abs(value)
        for (threshold, suffix) in scales where magnitude >= threshold {
            let mantissa = value / threshold
            // One decimal only while it carries information. `412.0M` prints a
            // digit that is always zero at that magnitude and pushes the column
            // wider for nothing.
            let places = abs(mantissa) < 100 ? 1 : 0
            return prefix + String(format: "%.\(places)f%@", mantissa, suffix)
        }
        return prefix + String(format: "%.0f", value)
    }

    private static let scales: [(Double, String)] = [
        (1e12, "T"), (1e9, "B"), (1e6, "M"), (1e3, "K"),
    ]

    // MARK: - Window range

    /// `Jul 30 – Aug 6`.
    ///
    /// The end instant is the reset, which is the *start* of the next window —
    /// bounds are half-open everywhere in this codebase — so printing it as the
    /// closing date is correct and needs no −1 day.
    public static func windowRange(start: Date, end: Date) -> String {
        windowRange(start: start, end: end, timeZone: .current, locale: .autoupdatingCurrent)
    }

    public static func windowRange(start: Date, end: Date,
                                   timeZone: TimeZone, locale: Locale) -> String {
        let formatter = template("dMMM", timeZone: timeZone, locale: locale)
        return "\(formatter.string(from: start)) – \(formatter.string(from: end))"
    }

    // MARK: - Final reading

    /// What a window's percentage column says, and whether it says anything.
    public struct FinalReading: Equatable, Sendable {
        /// The figure, or `—`. 🔴 **Never `0%`.**
        public let value: String
        /// Always present, because the figure alone is never the whole truth:
        /// either there is no figure, or there is one and *when it was taken*
        /// decides whether it is a final reading or a mid-week snapshot.
        public let note: String
        public let isRecorded: Bool
    }

    /// 🔴 **nil is NOT zero.**
    ///
    /// Every window in the real archive is nil today: percentages are recorded
    /// from now on, none exist on disk for a closed week, and none can be
    /// reconstructed. `0%` would claim a week of no usage.
    ///
    /// When a figure *is* present, it is only a final reading if it was taken at
    /// the reset. A week where the laptop closed on Thursday holds Thursday's
    /// number, and a bare `61%` claims a total the app never saw — so the
    /// reading always carries its own age.
    public static func finalReading(percent: Double?, at: Date?, windowEnd: Date) -> FinalReading {
        finalReading(percent: percent, at: at, windowEnd: windowEnd,
                     timeZone: .current, locale: .autoupdatingCurrent)
    }

    public static func finalReading(percent: Double?, at: Date?, windowEnd: Date,
                                    timeZone: TimeZone, locale: Locale) -> FinalReading {
        guard let percent else {
            return FinalReading(value: "—", note: "not recorded", isRecorded: false)
        }
        let value = "\(DisplayValue.whole(percent))%"
        guard let at else {
            // The two are written together by `WindowLedger`, so this pairing
            // means a hand-edited or partially-decoded row. Say so rather than
            // implying the figure is final.
            return FinalReading(value: value, note: "time unknown", isRecorded: true)
        }
        // One bucket is the archive's own resolution, so a reading inside the
        // last bucket of the window is as final as anything here can be.
        if abs(windowEnd.timeIntervalSince(at)) <= Bucket.seconds {
            return FinalReading(value: value, note: "at the reset", isRecorded: true)
        }
        let formatter = template("EEEdMMM", timeZone: timeZone, locale: locale)
        return FinalReading(value: value, note: "last seen \(formatter.string(from: at))",
                            isRecorded: true)
    }

    // MARK: - Coverage

    /// `Jul 16` — where the archive starts, for the one line that says how far
    /// back any of this can see.
    public static func day(_ date: Date) -> String {
        day(date, timeZone: .current, locale: .autoupdatingCurrent)
    }

    public static func day(_ date: Date, timeZone: TimeZone, locale: Locale) -> String {
        template("dMMM", timeZone: timeZone, locale: locale).string(from: date)
    }

    private static func template(_ template: String, timeZone: TimeZone,
                                 locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        // Localized template, not a fixed pattern: `MMM d` is wrong in most of
        // the world, and this app has no business hardcoding US order.
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }
}
