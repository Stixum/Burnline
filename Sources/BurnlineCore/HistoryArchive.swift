import Foundation

/// Turns cache cells into archive rows.
public enum HistoryArchive {

    /// Rows to append, plus **the range they establish**.
    public struct Payload: Equatable, Sendable {
        public let rows: [HistoryRow]
        /// nil when nothing was uncovered — there is no new coverage to claim.
        public let span: ClosedRange<Int>?
        /// A fill could not reach `span.lowerBound`; the record still claims
        /// the full requested range so the shortfall is a *known* gap.
        public let truncated: Bool

        /// Explicit and public — the memberwise init is internal, and callers
        /// in other modules must construct this for the fill path.
        public init(rows: [HistoryRow], span: ClosedRange<Int>?, truncated: Bool = false) {
            self.rows = rows
            self.span = span
            self.truncated = truncated
        }
    }

    public static func payload(from cache: ScanCache, coverage: Coverage,
                               through closedBefore: Int) -> Payload {
        let step = Int(Bucket.seconds)
        let lastClosed = closedBefore - (closedBefore % step) - step
        let earliest = cache.files.values
            .flatMap { $0.cells.keys.compactMap(Int.init) }
            .min()
            .map { $0 * step }
        guard let first = earliest, first <= lastClosed else {
            return Payload(rows: [], span: nil)
        }
        let uncovered = coverage.uncovered(from: first, through: lastClosed)
        guard let lo = uncovered.first?.lowerBound, let hi = uncovered.last?.upperBound else {
            return Payload(rows: [], span: nil)
        }
        return Payload(rows: rows(from: cache, coverage: coverage, through: closedBefore),
                       span: lo...hi)
    }

    /// Rows for every CLOSED bucket that coverage does not already hold.
    ///
    /// 🔴 Cells are summed ACROSS transcript files first. `ScanCache.files` is
    /// keyed by path; rows have no file field. Emitting one row per file
    /// produces duplicate keys inside a single commit, and dedupe-on-read then
    /// keeps one file's share and discards the rest — a silent, permanent
    /// undercount in an artifact that cannot be recomputed.
    public static func rows(from cache: ScanCache, coverage: Coverage,
                            through closedBefore: Int) -> [HistoryRow] {
        let step = Int(Bucket.seconds)
        var totals: [HistoryRow.Key: TokenCounts] = [:]
        let projects = ProjectName.resolve(Set(cache.files.keys.map(projectDirectory(of:))))

        for (path, state) in cache.files {
            let project = projects[projectDirectory(of: path)] ?? "unknown"
            for (rawKey, byModel) in state.cells {
                guard let index = Int(rawKey) else { continue }
                let start = index * step
                // Closed only when the whole bucket lies behind the mark.
                guard start + step <= closedBefore else { continue }
                guard !coverage.contains(start) else { continue }
                for (model, counts) in byModel {
                    let key = HistoryRow.Key(bucket: start, project: project, model: model)
                    totals[key, default: .zero] += counts
                }
            }
        }

        return totals
            .map { HistoryRow(bucket: $0.key.bucket, project: $0.key.project,
                              model: $0.key.model, counts: $0.value) }
            .sorted { ($0.bucket, $0.project, $0.model) < ($1.bucket, $1.project, $1.model) }
    }

    /// The encoded project directory a transcript path sits under. Session and
    /// subagent transcripts nest below it, so this is not simply the parent.
    static func projectDirectory(of path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        guard let index = parts.firstIndex(of: "projects"), index + 1 < parts.count else {
            return parts.dropLast().last ?? "unknown"
        }
        return parts[index + 1]
    }
}
