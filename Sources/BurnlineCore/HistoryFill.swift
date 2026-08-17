import Foundation

/// Reads transcripts over an arbitrary date range and produces archive rows.
///
/// 🔴 **Why this is not `TranscriptScanner`.** The scanner skips any file whose
/// mtime predates the 14-day `ScanCache` retention *before opening it*, then
/// calls `evict(before:)` at the end. Routed through it, a ranged fill would
/// read nothing outside 14 days and evict what it did read. But transcripts
/// survive 30 days (Claude Code's `cleanupPeriodDays` default), and the 15-to-30
/// day band is exactly what a gap fill has to reach. So this reads directly,
/// reusing the pure `TranscriptParser`, and never touches `ScanCache`.
public struct HistoryFill: Sendable {
    public let rootURL: URL

    /// No default root on purpose: a fill that silently walked the real
    /// transcripts is not something a test should be able to do by omission.
    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    public struct Result: Equatable, Sendable {
        public let rows: [HistoryRow]
        /// True when no record was found at or before `from` — the transcripts
        /// that would have covered the start of the range are already deleted.
        /// This is what makes the resulting gap KNOWABLE rather than merely absent.
        public let truncated: Bool
        /// Files actually opened — pins the mtime lower bound in a test.
        public let filesOpened: Int

        public init(rows: [HistoryRow], truncated: Bool, filesOpened: Int) {
            self.rows = rows
            self.truncated = truncated
            self.filesOpened = filesOpened
        }
    }

    /// Records in `[from, to]`, folded into rows. Both bounds inclusive.
    public func cells(from: Date, to: Date) throws -> Result {
        let parser = TranscriptParser()
        let step = Int(Bucket.seconds)
        var totals: [Cell: TokenCounts] = [:]
        var directories = Set<String>()
        var filesOpened = 0
        var oldest: Date?

        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )

        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "jsonl" else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }

            // The one mtime bound that belongs here. mtime is the last append,
            // so every record in the file precedes it: a file untouched since
            // before the range began cannot hold one inside it. This keeps a
            // gap fill off most of ~2,470 files instead of opening all of them.
            //
            // ⚠️ Deliberately NOT the scanner's retention cutoff, which bounds
            // the other end — escaping that is the point of this type.
            guard (values.contentModificationDate ?? .distantPast) >= from else { continue }

            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
            filesOpened += 1

            // Every file examined, not just the ones that emit rows: the display
            // name a directory resolves to depends on which other directories
            // are in the set, so the set has to be the corpus, not the survivors.
            let directory = HistoryArchive.projectDirectory(of: url.path)
            directories.insert(directory)

            for record in parser.parse(data) {
                // Dating considers every record, in range or not: one that
                // PREDATES `from` proves the transcripts covering the start of
                // the range still exist, which is precisely what `truncated`
                // asks about.
                if record.timestamp < (oldest ?? .distantFuture) { oldest = record.timestamp }

                guard record.timestamp >= from, record.timestamp <= to else { continue }
                let cell = Cell(bucket: Bucket.key(for: record.timestamp) * step,
                                directory: directory,
                                model: record.model)
                totals[cell, default: .zero] += TokenCounts(input: record.inputTokens,
                                                            output: record.outputTokens,
                                                            cacheWrite: record.cacheWriteTokens,
                                                            cacheRead: record.cacheReadTokens)
            }
        }

        let projects = ProjectName.resolve(directories)
        let rows = totals
            .map { HistoryRow(bucket: $0.key.bucket,
                              project: projects[$0.key.directory] ?? "unknown",
                              model: $0.key.model,
                              counts: $0.value) }
            .sorted { ($0.bucket, $0.project, $0.model) < ($1.bucket, $1.project, $1.model) }

        // No record at all is truncated, not clean: nothing was found that
        // reaches the start, and claiming coverage never verified is the one
        // answer this archive cannot recover from.
        return Result(rows: rows,
                      truncated: (oldest ?? .distantFuture) > from,
                      filesOpened: filesOpened)
    }

    /// 🔴 The aggregation identity, and it carries no file. Several transcripts
    /// in one project hitting the same 15-minute bucket is the common case
    /// (multiple terminals, plus subagent transcripts), so counts are summed
    /// ACROSS files before any row is emitted — identical to the flush path.
    /// Emit per file instead and dedupe-on-read keeps one file's share and
    /// silently discards the rest: a permanent undercount in an artifact that
    /// cannot be recomputed, because the transcripts behind it are deleted.
    ///
    /// Keyed by the *encoded* directory rather than the display name: names are
    /// resolved once, at the end, over the whole set.
    private struct Cell: Hashable {
        let bucket: Int
        let directory: String
        let model: String
    }
}
