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

/// Everything the History window draws, in one immutable value.
///
/// 🔴 **The view holds this or nil, and nil is the loading state.** Reading
/// 2,212 rows off disk and aggregating them is not main-actor work — it is the
/// same argument the launch fill makes, at a smaller scale — and a view that
/// pulled its own numbers would redo all of it on every redraw.
struct HistoryViewModel: Equatable, Sendable {
    let scoreboard: [HistoryQuery.ScoreboardRow]
    /// At most three, newest first. Colour encodes recency, so ORDER IS
    /// MEANING here: index 0 is the most recent series shown.
    let curves: [(label: String, points: [HistoryQuery.CurvePoint])]
    let breakdown: [HistoryQuery.BreakdownRow]
    let coverageBegins: Date?
    let hasGaps: Bool
    let skippedLines: Int
    /// What `breakdown` actually covers, always resolved. The view's picker
    /// reads its selection back from here, so "the most recent complete window"
    /// can be the default without the view knowing which window that is.
    let range: HistoryRange

    /// The label the live window's curve carries. Not a date range: the current
    /// window has no `WindowRow` — one is only written when a window closes —
    /// and "this week" is what a reader is looking for anyway.
    static let currentWeekLabel = "This week"

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
    var isEmpty: Bool { scoreboard.isEmpty && curves.isEmpty }

    /// Written out because Swift does not synthesize `==` through a tuple.
    static func == (lhs: HistoryViewModel, rhs: HistoryViewModel) -> Bool {
        lhs.scoreboard == rhs.scoreboard
            && lhs.breakdown == rhs.breakdown
            && lhs.coverageBegins == rhs.coverageBegins
            && lhs.hasGaps == rhs.hasGaps
            && lhs.skippedLines == rhs.skippedLines
            && lhs.range == rhs.range
            && lhs.curves.count == rhs.curves.count
            && zip(lhs.curves, rhs.curves).allSatisfy {
                $0.label == $1.label && $0.points == $1.points
            }
    }
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

        let resolved = resolve(range, windows: scoreboard.map(\.window))
        let breakdown = HistoryQuery.breakdown(
            cells: cells(for: resolved, in: archive), by: dimension,
            weights: weights,
            // Ten plus a folded tail. The real archive has 18 projects and the
            // last thirteen are unreadable slivers.
            limit: 10)

        return HistoryViewModel(
            scoreboard: scoreboard,
            curves: curves(in: archive, scoreboard: scoreboard,
                           currentWindow: currentWindow, weights: weights),
            breakdown: breakdown,
            coverageBegins: archive.coverage.ranges.first
                .map { Date(timeIntervalSince1970: Double($0.lowerBound)) },
            hasGaps: hasGaps(archive.coverage),
            skippedLines: archive.skipped,
            range: resolved
        )
    }

    // MARK: - Curves

    /// The live window, then up to two completed windows before it.
    ///
    /// ⚠️ **Two priors, not three.** Colour encodes recency and the ramp's next
    /// step measures 2.94:1 against the window background — under the 3:1 floor
    /// for a mark, i.e. a line some readers cannot see at all.
    ///
    /// A series with nothing in it is omitted rather than drawn flat: an empty
    /// week and a week of no usage are different claims, and a flat line at zero
    /// makes the second one.
    private func curves(in archive: Archive, scoreboard: [HistoryQuery.ScoreboardRow],
                        currentWindow: Window,
                        weights: Weights) -> [(label: String, points: [HistoryQuery.CurvePoint])] {
        var curves: [(label: String, points: [HistoryQuery.CurvePoint])] = []

        let live = HistoryQuery.burnCurve(cells: archive.cells, start: currentWindow.start,
                                          end: currentWindow.end, weights: weights)
        if live.count > 1 {
            curves.append((HistoryViewModel.currentWeekLabel,
                           HistoryQuery.hourly(live, windowDuration: currentWindow.totalDuration)))
        }

        let priors = scoreboard.map(\.window).filter { $0.start < currentWindow.start }.prefix(2)
        for window in priors {
            let points = HistoryQuery.burnCurve(cells: archive.cells, start: window.start,
                                                end: window.end, weights: weights)
            guard points.count > 1 else { continue }
            let duration = window.end.timeIntervalSince(window.start)
            curves.append((HistoryLabels.windowRange(start: window.start, end: window.end),
                           HistoryQuery.hourly(points, windowDuration: duration)))
        }
        return curves
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

        // The span to read: everything covered, everything any window claims,
        // and forward to the live window's end. A window row without its cells
        // would report zero units, which is the one number this feature must
        // never invent.
        var lower = coverage.ranges.first.map { Date(timeIntervalSince1970: Double($0.lowerBound)) }
        if let earliest = windows.map(\.start).min() {
            lower = min(lower ?? earliest, earliest)
        }
        guard let lower else {
            let empty = Archive(cells: [], windows: windows, coverage: coverage,
                                skipped: 0, loadedAt: now)
            cached = empty
            return empty
        }
        let upper = max(through,
                        coverage.ranges.last.map { Date(timeIntervalSince1970: Double($0.upperBound)) }
                            ?? through)

        let read: (rows: [HistoryRow], skipped: Int) =
            (try? store.rows(in: lower...upper)) ?? (rows: [], skipped: 0)
        let archive = Archive(cells: read.rows, windows: windows, coverage: coverage,
                              skipped: read.skipped, loadedAt: now)
        cached = archive
        return archive
    }
}
