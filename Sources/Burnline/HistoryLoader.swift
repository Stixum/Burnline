import Foundation
import BurnlineCore

/// Which period the breakdown covers.
///
/// The scoreboard and the breakdown must be pointable at the same window, or
/// their totals reconcile with nothing — so this is one value shared by the
/// range control, the highlighted scoreboard row, and the cells the bars are
/// built from.
///
/// A window is identified by its `start` rather than by the whole `WindowRow`:
/// a `Picker` tag has to be `Hashable`, starts are unique across the archive
/// (windows are contiguous and non-overlapping), and a row carrying token
/// counts is a lot of value to compare on every selection change.
enum HistoryRange: Hashable, Sendable {
    case allCoverage
    case window(start: Date)
    /// **Unresolved**: "whichever complete window is the most recent". The view
    /// cannot name that before the archive is read, and the default has to be a
    /// real window rather than all-coverage — a breakdown covering five weeks
    /// answers a different question than the one the scoreboard row above it
    /// asks. `HistoryViewModel.range` is always resolved, never this.
    case newestWindow
}

/// One week of cumulative units, ready to draw.
///
/// Structs rather than the `(label:points:)` tuples this used to carry: Swift
/// does not synthesize `==` through a tuple, which is why `HistoryViewModel`
/// hand-wrote one, and both curves need a field the tuple shape had nowhere to
/// put.
struct HistoryUnitCurve: Equatable, Sendable {
    let label: String

    /// 🔴 **The week's position in the recency ramp, carried from its
    /// `HistoryOverlay.Slot` — NOT its position in this array.**
    ///
    /// Colouring by array position is a real defect, not a tidiness point: this
    /// series omits the live window whenever it has one point or fewer, which is
    /// the first quarter-hour after a reset and any time before the first scan
    /// lands. At that moment array position 0 is the week *before*, and the ramp
    /// paints it violet — the encoding saying "this is now" about a week that
    /// ended.
    let rampIndex: Int

    let points: [HistoryQuery.CurvePoint]
}

/// One week's percentage readings, ready to draw.
struct HistoryPercentCurve: Equatable, Sendable {
    /// Same text the units curve of this same week carries — both come from one
    /// `HistoryOverlay.Slot`, so the two modes cannot disagree about it.
    let label: String

    /// Same rule, same reason as `HistoryUnitCurve.rampIndex`, and the two
    /// series drop *different* weeks: one can hold transcript cells and no
    /// capture readings, or readings and no cells.
    let rampIndex: Int

    /// 🔴 `series.isEmpty` means NOT RECORDED, never a week at 0%. An empty
    /// series is dropped before it reaches a chart rather than drawn flat.
    let series: HistoryQuery.PercentSeries
}

/// Everything the History window draws, in one immutable value.
///
/// 🔴 **The view holds this or nil, and nil is the loading state.** Reading
/// 2,212 rows off disk and aggregating them is not main-actor work — it is the
/// same argument the launch fill makes, at a smaller scale — and a view that
/// pulled its own numbers would redo all of it on every redraw.
struct HistoryViewModel: Equatable, Sendable {
    let scoreboard: [HistoryQuery.ScoreboardRow]
    /// At most three, newest first. ⚠️ Colour comes from each entry's
    /// `rampIndex`, never from its position here — this array is filtered and
    /// recency is not.
    let curves: [HistoryUnitCurve]
    /// The same slots as `curves`, on the percent axis — but independently
    /// filtered, because the two series have different absences.
    let percentCurves: [HistoryPercentCurve]
    let breakdown: [HistoryQuery.BreakdownRow]
    let coverageBegins: Date?
    let hasGaps: Bool
    let skippedLines: Int
    /// What `breakdown` actually covers, always resolved. The view's picker
    /// reads its selection back from here, so "the most recent complete window"
    /// can be the default without the view knowing which window that is.
    let range: HistoryRange

    /// Forwards to the overlay rule, which is where the weeks and their ramp
    /// positions are decided. Kept as a name here because it reads better at
    /// the call sites that already had it.
    static let currentWeekLabel = HistoryOverlay.currentWeekLabel

    /// True when Anthropic's own figure is missing from EVERY row.
    ///
    /// This is the normal first-open state, not an edge case: percentages are
    /// recorded from now on, no closed week has one on disk, and none can be
    /// reconstructed. The window says so in one line while it holds — and stops
    /// saying it the moment a single week has a real figure, because at that
    /// point the empty cells are self-explanatory.
    var noPercentagesRecorded: Bool {
        !scoreboard.isEmpty && scoreboard.allSatisfy { $0.usedPercent == nil }
    }

    /// The breakdown's total, so the bars can be printed under a figure that
    /// they add up to. Arithmetic, and therefore not in a view body.
    var breakdownTotal: Double {
        breakdown.reduce(0) { $0 + $1.units }
    }

    /// Nothing to draw at all — as distinct from "still loading", which is nil.
    ///
    /// The percent series counts: a capture can land before the transcript scan
    /// has written a single cell, and on that launch there is genuinely
    /// something to show. Reporting "no completed weeks yet" over a chart that
    /// has data is the same class of wrong answer as reporting it over a
    /// running fill.
    var isEmpty: Bool { scoreboard.isEmpty && curves.isEmpty && percentCurves.isEmpty }
}

/// Reads the archive off the main actor and hands back one view model.
///
/// An actor rather than a detached task per call, for one reason: the picker
/// controls re-aggregate the same archive. Re-reading 2,212 JSONL rows to
/// switch project→model would be several hundred milliseconds of file I/O for a
/// dictionary walk that costs microseconds.
actor HistoryLoader {
    private let store: HistoryStore
    private var cached: Archive?

    /// ⚠️ Long enough that flipping the dimension picker never re-reads disk,
    /// short enough that a window left open does not quietly show an archive
    /// from an hour ago — the forward flush appends to it every 60 seconds.
    ///
    /// An age check rather than an explicit invalidate-on-appear because two
    /// `.task` modifiers on one view have no defined order between them, and the
    /// wrong order there is either a double read or a stale one.
    private static let cacheLifetime: TimeInterval = 15

    init(directory: URL) {
        store = HistoryStore(directory: directory)
    }

    private struct Archive {
        let cells: [HistoryRow]
        let windows: [WindowRow]
        let coverage: Coverage
        /// Every retained capture observation, unfiltered. `percentCurve` slices
        /// it per window by containment of the instant — deliberately not by
        /// the bucket-ownership rule the unit queries share, and never across
        /// the whole file, because the ordinary weekly reset is an 87 → 4 drop
        /// and a walk over the file would read almost every week as re-granted.
        let tracking: [TrackingEntry]
        let skipped: Int
        let loadedAt: Date
    }

    /// Drops the cached read, so the next call goes to disk.
    ///
    /// The age check above is for a window nobody is writing to. The launch fill
    /// is the opposite case: it commits ~20 seconds of work in one go, and the
    /// view is told the moment it lands — so waiting out the remainder of a
    /// 15-second lifetime there would redraw from the read taken back when the
    /// archive was still empty. That is not a slow refresh; it is the same wrong
    /// answer twice.
    func invalidate() {
        cached = nil
    }

    func viewModel(dimension: HistoryQuery.Dimension, range: HistoryRange,
                   currentWindow: Window, weights: Weights) -> HistoryViewModel {
        let archive = load(through: currentWindow.end, now: currentWindow.now)

        // Newest first, and the source of both the curve selection and the
        // range control's options.
        let scoreboard = HistoryQuery.scoreboard(windows: archive.windows, cells: archive.cells,
                                                 coverage: archive.coverage, weights: weights)

        // 🔴 ONE list of weeks, decided once, mapped over by both charts. The
        // toggle's premise is that the two modes show the same weeks under the
        // same labels in the same colours; while each built its own list from
        // its own inputs, nothing enforced any of the three.
        let slots = HistoryOverlay.slots(currentStart: currentWindow.start,
                                         currentEnd: currentWindow.end,
                                         windows: scoreboard.map(\.window))

        let resolved = resolve(range, windows: scoreboard.map(\.window))
        let breakdown = HistoryQuery.breakdown(
            cells: cells(for: resolved, in: archive), by: dimension,
            weights: weights,
            // Ten plus a folded tail. The real archive has 18 projects and the
            // last thirteen are unreadable slivers.
            limit: 10)

        return HistoryViewModel(
            scoreboard: scoreboard,
            curves: curves(in: archive, slots: slots, weights: weights),
            percentCurves: percentCurves(in: archive, slots: slots),
            breakdown: breakdown,
            coverageBegins: archive.coverage.ranges.first
                .map { Date(timeIntervalSince1970: Double($0.lowerBound)) },
            hasGaps: hasGaps(archive.coverage),
            skippedLines: archive.skipped,
            range: resolved
        )
    }

    // MARK: - Curves

    /// Cumulative units for each overlaid week.
    ///
    /// ⚠️ **Which weeks, and which colour, is `HistoryOverlay`'s decision — not
    /// this function's and not the chart's.** Both series map the same slots, so
    /// a week is the same colour and the same name on both faces of the toggle.
    ///
    /// A series with nothing in it is omitted rather than drawn flat: an empty
    /// week and a week of no usage are different claims, and a flat line at zero
    /// makes the second one. 🔴 The slot's `rampIndex` travels with the survivor
    /// precisely because this filter runs — recency is not array position.
    private func curves(in archive: Archive, slots: [HistoryOverlay.Slot],
                        weights: Weights) -> [HistoryUnitCurve] {
        slots.compactMap { slot in
            let points = HistoryQuery.burnCurve(cells: archive.cells, start: slot.start,
                                                end: slot.end, weights: weights)
            guard points.count > 1 else { return nil }
            let duration = slot.end.timeIntervalSince(slot.start)
            return HistoryUnitCurve(
                label: slot.label, rampIndex: slot.rampIndex,
                points: HistoryQuery.hourly(points, windowDuration: duration))
        }
    }

    /// The same slots, on the percent axis.
    ///
    /// 🔴 **Not thinned.** `HistoryQuery.hourly` is the unit curve's thinner and
    /// must not be reused: it keeps the last point in each hour, and a re-grant
    /// whose two readings fall in one hour would be swallowed whole — the single
    /// discontinuity this chart exists to show. There is also a third as much to
    /// draw (a week holds ~210 readings against ~670 buckets, because this
    /// series is observation-driven rather than bucket-driven), so nothing is
    /// asking to be thinned in the first place.
    ///
    /// A week with no readings is dropped rather than drawn flat, for a stronger
    /// reason than the units filter: `PercentSeries.isEmpty` means *not
    /// recorded*, and most archived weeks predate the retention fix — a line at
    /// 0% would claim an untouched allowance for every one of them.
    private func percentCurves(in archive: Archive,
                               slots: [HistoryOverlay.Slot]) -> [HistoryPercentCurve] {
        slots.compactMap { slot in
            let series = HistoryQuery.percentCurve(tracking: archive.tracking,
                                                   start: slot.start, end: slot.end)
            guard !series.isEmpty else { return nil }
            return HistoryPercentCurve(label: slot.label, rampIndex: slot.rampIndex,
                                       series: series)
        }
    }

    // MARK: - Range

    private func resolve(_ range: HistoryRange, windows: [WindowRow]) -> HistoryRange {
        switch range {
        case .allCoverage:
            return .allCoverage
        case .window(let start):
            // A selection that no longer names a real window — the archive was
            // rebuilt, or a row aged in — falls back rather than showing an
            // empty breakdown under a live-looking picker.
            return windows.contains { $0.start == start } ? .window(start: start)
                                                          : newest(of: windows)
        case .newestWindow:
            return newest(of: windows)
        }
    }

    private func newest(of windows: [WindowRow]) -> HistoryRange {
        windows.first.map { .window(start: $0.start) } ?? .allCoverage
    }

    private func cells(for range: HistoryRange, in archive: Archive) -> [HistoryRow] {
        guard case .window(let start) = range,
              let window = archive.windows.first(where: { $0.start == start })
        else { return archive.cells }
        // 🔴 Sliced by the query's own bucket-ownership rule, so these bars sum
        // to exactly the units that window's scoreboard row prints.
        return HistoryQuery.cells(archive.cells, in: window)
    }

    // MARK: - Coverage

    /// Holes BETWEEN covered ranges — usage that is unknown, not absent.
    /// Deliberately not "everything before the archive began", which is merely
    /// out of reach and is reported as the coverage start instead.
    private func hasGaps(_ coverage: Coverage) -> Bool {
        guard let first = coverage.ranges.first, let last = coverage.ranges.last else {
            return false
        }
        return !coverage.gaps(in: first.lowerBound...last.upperBound).isEmpty
    }

    // MARK: - Reading

    private func load(through: Date, now: Date) -> Archive {
        if let cached, now.timeIntervalSince(cached.loadedAt) < Self.cacheLifetime {
            return cached
        }

        let coverage = (try? store.loadCoverage()) ?? Coverage(records: [])
        let windows = (try? store.loadWindows()) ?? []
        // One small JSON file (~15KB per retained window), read on the same
        // pass and cached with everything else — the percent chart must not be
        // the one section that hits disk when a picker moves.
        let tracking = ((try? store.loadTracking()) ?? TrackingFile()).entries

        // The span to read: everything covered, everything any window claims,
        // and forward to the live window's end. A window row without its cells
        // would report zero units, which is the one number this feature must
        // never invent.
        var lower = coverage.ranges.first.map { Date(timeIntervalSince1970: Double($0.lowerBound)) }
        if let earliest = windows.map(\.start).min() {
            lower = min(lower ?? earliest, earliest)
        }
        guard let lower else {
            // ⚠️ Tracking still travels. A brand-new install can hold capture
            // observations before the scan has written a single cell, and
            // zeroing them here would blank the one chart that had data.
            let empty = Archive(cells: [], windows: windows, coverage: coverage,
                                tracking: tracking, skipped: 0, loadedAt: now)
            cached = empty
            return empty
        }
        let upper = max(through,
                        coverage.ranges.last.map { Date(timeIntervalSince1970: Double($0.upperBound)) }
                            ?? through)

        let read: (rows: [HistoryRow], skipped: Int) =
            (try? store.rows(in: lower...upper)) ?? (rows: [], skipped: 0)
        let archive = Archive(cells: read.rows, windows: windows, coverage: coverage,
                              tracking: tracking, skipped: read.skipped, loadedAt: now)
        cached = archive
        return archive
    }
}
