import Foundation

/// Every number the History window draws, derived in one pure place.
///
/// **No view in this codebase does arithmetic** — that rule is why the pure
/// units carry the tests, and a scoreboard cell, a curve point and a breakdown
/// share are all arithmetic. Three views (week-over-week scoreboard, overlaid
/// burn curves, project/model breakdown) read this one enum.
public enum HistoryQuery {

    /// The label a folded tail carries. Exposed so a view can match on it
    /// rather than re-spelling the string.
    public static let otherLabel = "Other"

    // MARK: - Types

    public struct ScoreboardRow: Equatable, Sendable {
        public let window: WindowRow

        /// Weighted units for the whole window.
        ///
        /// ⚠️ Token-class weights only, with `weights.defaultMultiplier` — a
        /// `WindowRow` sums its four token counts across every model, so the
        /// model dimension is gone and no per-model multiplier can be
        /// recovered from it. `breakdown` still has the cells and so still
        /// applies real multipliers; the two therefore live on different
        /// scales whenever the multipliers are not all equal. Do not print a
        /// breakdown total next to this figure and call them the same
        /// quantity — use `breakdown`'s own rows, which reconcile among
        /// themselves.
        public let units: Double

        /// 🔴 **nil means NOT RECORDED — never render it as zero.**
        ///
        /// Anthropic's own figure or nothing. Every window in the real archive
        /// is nil today: the app only began recording percentages now, none
        /// exist anywhere on disk, and none can be reconstructed. That is the
        /// normal first-open state, not an edge case. `0%` would claim a week
        /// of no usage.
        public let usedPercent: Double?

        /// Coverage has a hole inside this window: usage there is **unknown**,
        /// not idle. The app was not running; tokens may well have been burned.
        public let hasGap: Bool

        public init(window: WindowRow, units: Double, usedPercent: Double?, hasGap: Bool) {
            self.window = window
            self.units = units
            self.usedPercent = usedPercent
            self.hasGap = hasGap
        }
    }

    public struct CurvePoint: Equatable, Sendable {
        /// 0...1 through the window — the shared axis that makes overlay valid.
        public let elapsedFraction: Double
        /// Cumulative weighted units consumed by this point in the window.
        public let units: Double

        public init(elapsedFraction: Double, units: Double) {
            self.elapsedFraction = elapsedFraction
            self.units = units
        }
    }

    public struct BreakdownRow: Equatable, Sendable {
        public let label: String
        public let units: Double
        /// Fraction of the total, 0...1. Zero when the total is zero.
        public let share: Double
        /// This row is the folded tail, not a single project or model.
        public let isOther: Bool

        public init(label: String, units: Double, share: Double, isOther: Bool) {
            self.label = label
            self.units = units
            self.share = share
            self.isOther = isOther
        }
    }

    public enum Dimension: Equatable, CaseIterable, Sendable { case project, model }

    // MARK: - Scoreboard

    /// One row per completed window, **newest first**.
    ///
    /// Archive order is oldest-first, because rows are appended as windows
    /// close; a list fed that order renders the history upside down.
    public static func scoreboard(windows: [WindowRow], coverage: Coverage,
                                  weights: Weights) -> [ScoreboardRow] {
        windows
            .sorted { $0.start > $1.start }
            .map { window in
                ScoreboardRow(
                    window: window,
                    units: ConsumptionModel.units(for: window.counts,
                                                  multiplier: weights.defaultMultiplier,
                                                  weights: weights),
                    // 🔴 Passed through unchanged. nil stays nil.
                    usedPercent: window.finalPercent,
                    hasGap: hasGap(in: window, coverage: coverage)
                )
            }
    }

    private static func hasGap(in window: WindowRow, coverage: Coverage) -> Bool {
        // The same bucket-ownership rule `WindowLedger` used to decide the
        // window was writable in the first place: a window owns the buckets
        // whose START falls in [start, end). Two different rules here and there
        // would flag every window as holed, or none.
        let first = WindowLedger.firstBucketStart(atOrAfter: window.start)
        let last = WindowLedger.lastBucketStart(before: window.end)
        guard first <= last else { return false }
        return !coverage.covers(from: first, through: last)
    }

    // MARK: - Burn curve

    /// Cumulative consumption through a window, on a 0...1 elapsed axis.
    ///
    /// Takes plain bounds, **not a `WindowRow`** — the current week is the
    /// curve the user most wants and has no row, because a row is only written
    /// once the window completes.
    ///
    /// **Cumulative**, because the question is "was I ahead or behind", and
    /// only a running total answers it against a straight pace line. And keyed
    /// to *fraction elapsed*, because windows do not all start on the same
    /// weekday — the reset moves whenever a new one is observed — so a wall
    /// clock axis compares Tuesday of one week to Friday of another. On this
    /// axis "day 3 of the window" is the same place in every curve.
    ///
    /// The series opens with `(0, 0)`: at the window's start, zero has been
    /// consumed *within the window* by definition, so every overlaid curve
    /// begins from the same origin. Empty in, empty out.
    public static func burnCurve(cells: [HistoryRow], start: Date, end: Date,
                                 weights: Weights) -> [CurvePoint] {
        let duration = end.timeIntervalSince(start)
        guard duration > 0 else { return [] }

        let first = WindowLedger.firstBucketStart(atOrAfter: start)
        let last = WindowLedger.lastBucketStart(before: end)
        guard first <= last else { return [] }

        let inWindow = cells.filter { $0.bucket >= first && $0.bucket <= last }
        guard !inWindow.isEmpty else { return [] }

        // ⚠️ Once, before the walk. See `breakdown`.
        let resolved = ConsumptionModel.ResolvedMultipliers(models: inWindow.lazy.map(\.model),
                                                            weights: weights)

        var byBucket: [Int: Double] = [:]
        for row in inWindow {
            byBucket[row.bucket, default: 0] += ConsumptionModel.units(
                for: row.counts, multiplier: resolved[row.model], weights: weights)
        }

        let origin = start.timeIntervalSince1970
        var running = 0.0
        var points: [CurvePoint] = [CurvePoint(elapsedFraction: 0, units: 0)]
        points.reserveCapacity(byBucket.count + 1)
        for bucket in byBucket.keys.sorted() {
            running += byBucket[bucket] ?? 0
            // The bucket's END: its tokens accrued *over* the bucket, so the
            // running total is only true once the bucket has finished.
            let instant = Double(bucket) + Bucket.seconds
            let fraction = min(max((instant - origin) / duration, 0), 1)
            points.append(CurvePoint(elapsedFraction: fraction, units: running))
        }
        return points
    }

    // MARK: - Breakdown

    /// Weighted units by project or model, descending, with the tail past
    /// `limit` folded into a single `isOther` row.
    ///
    /// The folded row carries the whole remainder, so the rows **including
    /// Other sum to the total** and the shares add to 1. A breakdown that does
    /// not reconcile with the total it sits under is worse than none: the
    /// reader cannot tell whether the tail was folded or dropped.
    public static func breakdown(cells: [HistoryRow], by dimension: Dimension,
                                 weights: Weights, limit: Int) -> [BreakdownRow] {
        guard !cells.isEmpty else { return [] }

        // ⚠️ ONCE per query, before the walk. `Weights.modelMultipliers` is an
        // ordered, substring-matched array, so resolving one model costs a walk
        // of the list plus a `lowercased()` allocation per candidate. Per cell
        // that is O(cells × candidates) over hundreds of thousands of rows —
        // the performance question measured and explicitly closed on
        // `ScanCache.units`. Pinned by `multipliersAreResolvedOncePerQueryNotPerCell`.
        let resolved = ConsumptionModel.ResolvedMultipliers(models: cells.lazy.map(\.model),
                                                            weights: weights)

        var totals: [String: Double] = [:]
        var total = 0.0
        for row in cells {
            let units = ConsumptionModel.units(for: row.counts, multiplier: resolved[row.model],
                                               weights: weights)
            let label = switch dimension {
            case .project: row.project
            case .model: row.model
            }
            totals[label, default: 0] += units
            total += units
        }

        // Ties break on the label so the table does not reshuffle between
        // refreshes; dictionary order is unspecified.
        let ranked = totals.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }

        func share(_ units: Double) -> Double { total > 0 ? units / total : 0 }
        func row(_ label: String, _ units: Double, isOther: Bool) -> BreakdownRow {
            BreakdownRow(label: label, units: units, share: share(units), isOther: isOther)
        }

        let keep = max(0, limit)
        guard ranked.count > keep else {
            return ranked.map { row($0.key, $0.value, isOther: false) }
        }
        var rows = ranked.prefix(keep).map { row($0.key, $0.value, isOther: false) }
        rows.append(row(otherLabel, ranked.dropFirst(keep).reduce(0) { $0 + $1.value },
                        isOther: true))
        return rows
    }
}
