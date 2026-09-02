import Foundation

/// Which weeks the History window overlays, in which order, in which colour.
///
/// 🔴 **The chart area is a toggle, and its whole premise is that the two modes
/// show the SAME weeks under the SAME labels in the SAME colours.** Nothing
/// enforced that while each chart picked its own weeks: the units curve and the
/// percent trend computed "the live window plus its two most recent priors"
/// independently, from different inputs, a hundred lines apart.
///
/// 🔴 **And each of them assigned colour by position in its own drawn array,
/// which is a different quantity from recency.** Both series drop a week with
/// nothing in them — and they drop *different* weeks, because a week can hold
/// transcript cells and no capture readings, or readings and no cells. The
/// units curve omits the live window for the first quarter-hour after a reset,
/// or until the first scan lands; at that moment array position 0 is the week
/// before, and the ramp paints it violet. Violet means **now**. The chart says
/// "this is the current week" about a week that ended.
///
/// A slot is assigned its ramp position **before anything is filtered**, which
/// is the entire fix: `rampIndex` is a week's recency, and a caller that drops
/// an empty series cannot renumber the ones that remain.
///
/// Pure, and in `BurnlineCore` rather than beside the loader, because
/// `Sources/Burnline` has no test target — a rule that lives there is a rule
/// nothing can hold upright.
public enum HistoryOverlay {

    /// The label the live window's series carries.
    ///
    /// Not a date range: the current window has no `WindowRow` — one is written
    /// only when a window closes — and "this week" is what a reader is looking
    /// for anyway.
    public static let currentWeekLabel = "This week"

    /// How many series one overlay may hold: the live window and two priors.
    ///
    /// 🔴 **Three, because `Theme.curveRamp` has three entries and the next step
    /// down measures 2.94:1 against the window background** — under the 3:1
    /// floor a graphical mark has to clear, i.e. a line some readers cannot see
    /// at all. A fourth series means finding a different encoding, not a fourth
    /// grey, so the cap is a contrast decision and belongs beside the rule that
    /// hands out ramp positions rather than at a call site counting windows.
    public static let capacity = 3

    /// One week's place in the overlay.
    public struct Slot: Equatable, Sendable {
        /// What the legend, the direct end label and both charts call this week.
        public let label: String
        public let start: Date
        public let end: Date

        /// 🔴 **Position in the RECENCY ramp — never a position in a drawn
        /// array.** 0 is the live window whether or not it has anything to
        /// draw. Colour encodes recency, and a caller that filters empty series
        /// must carry this through rather than re-deriving it.
        public let rampIndex: Int

        /// This is the live window. Carried so a caller never has to recover it
        /// by matching the label string, which is presentation and localized.
        public let isCurrent: Bool

        public init(label: String, start: Date, end: Date, rampIndex: Int, isCurrent: Bool) {
            self.label = label
            self.start = start
            self.end = end
            self.rampIndex = rampIndex
            self.isCurrent = isCurrent
        }
    }

    /// The live window, then the most recent completed windows before it.
    ///
    /// Takes plain bounds for the live window rather than a `WindowRow`, for the
    /// reason `burnCurve` and `percentCurve` both do: the window a reader most
    /// wants is the current one, and it has no row until it closes.
    public static func slots(currentStart: Date, currentEnd: Date,
                             windows: [WindowRow]) -> [Slot] {
        slots(currentStart: currentStart, currentEnd: currentEnd, windows: windows,
              timeZone: .current, locale: .autoupdatingCurrent)
    }

    /// An overload rather than defaulted parameters, matching `HistoryLabels`
    /// and `ApplicationSupport.directory()`: a default argument generator is
    /// emitted into each caller's object file, so adding one later renames the
    /// symbol every existing caller references.
    public static func slots(currentStart: Date, currentEnd: Date,
                             windows: [WindowRow],
                             timeZone: TimeZone, locale: Locale) -> [Slot] {
        // 🔴 Slot 0 is the live window UNCONDITIONALLY. Whether either chart
        // has anything to draw for it is the chart's business; reserving the
        // newest ramp position is this function's, and it is exactly what stops
        // a prior week inheriting "now".
        var slots = [Slot(label: currentWeekLabel, start: currentStart, end: currentEnd,
                          rampIndex: 0, isCurrent: true)]

        // Strictly before the live window's start, so a row written for the
        // window now in progress — the flush can land one either side of a
        // reset — is never drawn a second time beside itself.
        //
        // ⚠️ **`windows.jsonl` GUARANTEES NEITHER ORDER NOR UNIQUENESS, and the
        // next two lines are the only place this feature assumes otherwise.**
        // The property is worth knowing on its own, because it is a property of
        // the archive rather than of this function:
        //
        // - The file is **append-only**, and `HistoryStore.loadWindows` keeps
        //   every line that decodes — unlike the cell rows, which deduplicate
        //   on read. So archive order is write order, and nothing sorts it.
        // - Writes are **at-least-once**. `WindowLedger.isAlreadyWritten` is the
        //   guard against appending a row twice, and it runs at the one
        //   construction site — which by this archive's own doctrine
        //   (`WindowRow.regrant`) means it is an invariant the FILE does not
        //   have. A crash between the append and the next read, or any second
        //   writer, leaves two rows claiming one start.
        //
        // Sorting matters because recency is the entire meaning of the colour:
        // an out-of-order row hands "second newest" to whichever week happened
        // to be written first. Deduplicating matters twice over — drawn as-is a
        // duplicate is one week in two colours, AND it evicts a genuine prior
        // from an overlay that only holds three.
        //
        // 🔴 The fix here is LOCAL to the overlay. `loadWindows` still returns
        // duplicates to every other caller, so the scoreboard and the range
        // picker can still show one week twice.
        var seen = Set<Date>()
        let priors = windows
            .filter { $0.start < currentStart }
            .sorted { $0.start > $1.start }
            .filter { seen.insert($0.start).inserted }
            .prefix(capacity - 1)

        for window in priors {
            slots.append(Slot(
                label: HistoryLabels.windowRange(start: window.start, end: window.end,
                                                 timeZone: timeZone, locale: locale),
                start: window.start, end: window.end,
                rampIndex: slots.count, isCurrent: false))
        }
        return slots
    }
}
