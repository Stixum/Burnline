import Foundation

/// All file I/O for `~/Library/Application Support/Burnline/history/`.
///
/// ```
/// manifest.json      version + lastObservedReset
/// coverage.jsonl     which bucket ranges are archived
/// tracking.json      capture observations
/// windows.jsonl      one row per completed weekly window
/// 2026-W33.jsonl     raw-token cells, one file per ISO week
/// ```
///
/// **Writes are at-least-once; reads deduplicate.** A crash between writing
/// rows and writing the coverage record leaves orphan rows behind, which a
/// later fill rewrites — coverage is the only duplicate guard at write time, so
/// `rows(in:)` resolves the collision on `(bucket, project, model)` with the
/// last occurrence winning. A bucket belongs to exactly one file
/// (`HistoryFileName` is a pure function of the bucket, in UTC), so file order
/// then line order makes "last" unambiguous. It also hardens the archive
/// against the hand-editing that a plain-text, spreadsheet-readable format
/// invites.
///
/// A `struct` rather than a class, matching `RateLimitStore`: under Swift 6 a
/// non-`Sendable` class handed to an actor and then used again by the caller is
/// a region-isolation error. That is also why the skipped-line count is
/// **returned** from `rows(in:)` rather than accumulated in a property —
/// mutable state is exactly what would block plain `Sendable` conformance, and
/// nothing needs it to persist.
public struct HistoryStore: Sendable {
    public let directory: URL

    /// Injected, never resolved from `ApplicationSupport` in here: every test
    /// must be able to point this somewhere disposable. Writing to the real
    /// archive from a test would corrupt an artifact that cannot be rebuilt,
    /// because Claude Code deletes transcripts after 30 days.
    public init(directory: URL) {
        self.directory = directory
    }

    // MARK: - JSON

    /// ⚠️ **Every encoder and decoder in this file comes from here.**
    ///
    /// A default `JSONEncoder` writes a `Date` as a reference-date `Double`, so
    /// `windows.jsonl` would carry `808617600` where the format calls for
    /// `"2026-08-15T12:00:00Z"` — unreadable to a human and useless in a
    /// spreadsheet, which is half the point of a plain-text archive. Pinning it
    /// in one shared place is what stops a later call site from quietly
    /// reintroducing the default.
    private enum JSON {
        static var encoder: JSONEncoder {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            return encoder
        }

        static var decoder: JSONDecoder {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return decoder
        }
    }

    // MARK: - Cell rows

    /// Appends one complete, newline-terminated buffer per file.
    ///
    /// One buffer per file rather than one write per row: a partial line at the
    /// end of a cell file is indistinguishable from a corrupt one on read, and
    /// a single write keeps the window in which that can happen as small as the
    /// filesystem allows.
    public func append(rows: [HistoryRow]) throws {
        guard !rows.isEmpty else { return }
        createDirectory()

        var byFile: [String: [HistoryRow]] = [:]
        for row in rows { byFile[HistoryFileName.forBucket(row.bucket), default: []].append(row) }

        let encoder = JSON.encoder
        for (name, group) in byFile {
            var buffer = Data()
            for row in group {
                buffer.append(try encoder.encode(row))
                buffer.append(newline)
            }
            try appendData(buffer, to: directory.appendingPathComponent(name))
        }
    }

    /// Archived rows whose bucket falls inside `range`, deduplicated.
    ///
    /// `skipped` counts lines that would not decode. A corrupt line is never
    /// fatal — one bad line must not cost the rest of the archive — but a
    /// *silent* skip is how an archive quietly loses half of itself, so the
    /// count comes back for the diagnostic probe to report.
    public func rows(in range: ClosedRange<Date>) throws -> (rows: [HistoryRow], skipped: Int) {
        var resolved: [HistoryRow.Key: HistoryRow] = [:]
        var skipped = 0

        for name in HistoryFileName.forRange(from: range.lowerBound, to: range.upperBound) {
            let read: (values: [HistoryRow], skipped: Int) =
                decodeLines(at: directory.appendingPathComponent(name))
            skipped += read.skipped
            for row in read.values
            where range.contains(Date(timeIntervalSince1970: Double(row.bucket))) {
                // Last occurrence wins: file order, then line order.
                resolved[row.key] = row
            }
        }

        let sorted = resolved.values
            .sorted { ($0.bucket, $0.project, $0.model) < ($1.bucket, $1.project, $1.model) }
        return (sorted, skipped)
    }

    // MARK: - Coverage

    public func appendCoverage(_ record: CoverageRecord) throws {
        createDirectory()
        var buffer = try JSON.encoder.encode(record)
        buffer.append(newline)
        try appendData(buffer, to: url("coverage.jsonl"))
    }

    /// Rebuilt from the log every time. An absent log is an empty archive, not
    /// an error — the first launch has nothing to read.
    public func loadCoverage() throws -> Coverage {
        let read: (values: [CoverageRecord], skipped: Int) = decodeLines(at: url("coverage.jsonl"))
        return Coverage(records: read.values)
    }

    // MARK: - Windows

    public func appendWindows(_ rows: [WindowRow]) throws {
        guard !rows.isEmpty else { return }
        createDirectory()
        let encoder = JSON.encoder
        var buffer = Data()
        for row in rows {
            buffer.append(try encoder.encode(row))
            buffer.append(newline)
        }
        try appendData(buffer, to: url("windows.jsonl"))
    }

    public func loadWindows() throws -> [WindowRow] {
        let read: (values: [WindowRow], skipped: Int) = decodeLines(at: url("windows.jsonl"))
        return read.values
    }

    // MARK: - Tracking

    /// Absent, unreadable **or from an incompatible version** all return a
    /// fresh default. Discarded, never migrated — the same doctrine as
    /// `ScanCache` and `RateLimitHighWater`.
    public func loadTracking() throws -> TrackingFile {
        guard let data = try? Data(contentsOf: url("tracking.json")),
              let file = try? JSON.decoder.decode(TrackingFile.self, from: data),
              file.isCompatible
        else { return TrackingFile() }
        return file
    }

    public func saveTracking(_ file: TrackingFile) throws {
        createDirectory()
        try JSON.encoder.encode(file).write(to: url("tracking.json"), options: .atomic)
    }

    // MARK: - Manifest

    public func loadManifest() throws -> HistoryManifest {
        guard let data = try? Data(contentsOf: url("manifest.json")),
              let manifest = try? JSON.decoder.decode(HistoryManifest.self, from: data),
              manifest.isCompatible
        else { return HistoryManifest() }
        return manifest
    }

    public func saveManifest(_ manifest: HistoryManifest) throws {
        createDirectory()
        try JSON.encoder.encode(manifest).write(to: url("manifest.json"), options: .atomic)
    }

    /// Advances only for a non-nil, strictly later instant. Nil never clears.
    ///
    /// Both halves matter. A launch fill commits before any capture has landed,
    /// so it passes nil — and if nil cleared the anchor, every past window's
    /// bounds would lose the only thing they can be rolled back from. And the
    /// anchor moving *backwards* would re-date windows that were already
    /// written against a later reset.
    public func advanceAnchor(_ instant: Date?) throws {
        guard let instant else { return }
        var manifest = try loadManifest()
        if let current = manifest.lastObservedReset, current >= instant { return }
        manifest.lastObservedReset = instant
        try saveManifest(manifest)
    }

    // MARK: - Files

    private var newline: UInt8 { 0x0A }

    private func url(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    /// Best-effort, exactly like `ApplicationSupport.directory()`. A directory
    /// that cannot be created must not crash the app: the write that follows
    /// throws a real error the caller can log, and every load tolerates a
    /// missing file.
    private func createDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func appendData(_ data: Data, to url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            try data.write(to: url, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    /// One JSON value per line. A missing file is an empty result, never an
    /// error; a line that will not decode is counted and skipped. Blank lines
    /// are neither — the trailing newline every write ends with produces one.
    private func decodeLines<T: Decodable>(at url: URL) -> (values: [T], skipped: Int) {
        guard let data = try? Data(contentsOf: url) else { return ([], 0) }
        let decoder = JSON.decoder
        var values: [T] = []
        var skipped = 0
        for line in data.split(separator: newline, omittingEmptySubsequences: false) {
            guard !line.isEmpty else { continue }
            if let value = try? decoder.decode(T.self, from: Data(line)) {
                values.append(value)
            } else {
                skipped += 1
            }
        }
        return (values, skipped)
    }
}
