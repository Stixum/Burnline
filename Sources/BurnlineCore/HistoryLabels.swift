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

    /// A 0…1 share as a percentage.
    ///
    /// The ×100 lives here rather than in a view: `BreakdownRow.share` is a
    /// fraction, every reader of it wants percent, and a stray ×100 in one call
    /// site out of three is the classic way a chart ends up disagreeing with the
    /// label under it.
    ///
    /// 🔴 **Both ends are guarded, and both were found on real data.** The model
    /// breakdown over one real week rounded to `claude-opus-5 100%` above three
    /// rows reading `0%` — four labels that between them claim 100% of the
    /// units and none of them, printed beside three bars that visibly exist.
    /// Whole-number rounding is right in the middle of the range and wrong at
    /// the extremes, where the thing it rounds away is the entire difference
    /// between "all of it" and "nearly all of it".
    public static func share(_ fraction: Double) -> String {
        let percent = fraction * 100
        guard percent.isFinite else { return "—" }
        // A row that exists consumed something, so it is never 0%.
        if percent > 0, percent < 1 { return "<1%" }
        // And it is only 100% if nothing else consumed anything at all.
        if percent > 99, percent < 100 { return ">99%" }
        // Through `DisplayValue`, which saturates. `Int(Double)` traps on NaN
        // and on anything outside Int's range.
        return "\(DisplayValue.whole(percent))%"
    }

    /// A figure that is ALREADY on the 0…100 scale, rendered as a percentage.
    ///
    /// ⚠️ **The sibling of `share(_:)`, and the ×100 is the whole difference.**
    /// `share` takes a 0…1 fraction because `BreakdownRow.share` is one;
    /// `PercentPoint.percent` is Anthropic's own figure and already reads 51 for
    /// fifty-one percent. Feeding one to the other is a hundred-fold error that
    /// renders as a plausible-looking chart, so they are two named functions
    /// rather than one with a flag.
    ///
    /// No `<1%` / `>99%` guards here, unlike `share`: those exist because a
    /// breakdown row that *exists* consumed something, so rounding it to `0%`
    /// contradicts the bar beside it. A percentage reading has no such
    /// invariant — 0% is a real and common state at the start of a window, and
    /// dressing it up as `<1%` would invent usage that was never reported.
    public static func percent(_ value: Double) -> String {
        // Same reason as `units`: an axis tick can arrive non-finite, and
        // `String(format:)` would print `inf` where a reader expects a figure.
        guard value.isFinite else { return "—" }
        // Through `DisplayValue`, which saturates. `Int(Double)` traps on NaN
        // and on anything outside Int's range.
        return "\(DisplayValue.whole(value))%"
    }

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
        // Through `percent(_:)`, not a third hand-rolled copy of it. That also
        // buys the non-finite guard: a reading that is not a number is not
        // `0%`, which is what `DisplayValue.whole` alone would have printed.
        // `Self.`, because the parameter shadows the function.
        let value = Self.percent(percent)
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
