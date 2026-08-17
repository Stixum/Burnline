import Testing
import Foundation
@testable import BurnlineCore

/// Whole seconds, so every timestamp round-trips through ISO-8601 exactly and a
/// boundary assertion means what it says.
private let clock = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))

private let day: TimeInterval = 86_400

private func iso(_ date: Date) -> String {
    // Built per call: `ISO8601DateFormatter` is not `Sendable`, so it cannot be
    // a file-scope global under the v6 language mode.
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}

private func assistantLine(output: Int, at date: Date,
                           model: String = "claude-sonnet-5") -> String {
    """
    {"type":"assistant","timestamp":"\(iso(date))","message":{"model":"\(model)","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":\(output)}}}\n
    """
}

/// A throwaway transcript tree. Deliberately not the scanner tests' `TempDir`:
/// this one sets an explicit mtime, which is the whole subject here.
private struct FillTree: ~Copyable {
    let root: URL

    init() {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("burnline-fill-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    @discardableResult
    func session(_ contents: String, at name: String, modified: Date) -> URL {
        let target = root.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? contents.write(to: target, atomically: true, encoding: .utf8)
        // After the write: an atomic write replaces the file, and with it the mtime.
        try? FileManager.default.setAttributes([.modificationDate: modified],
                                               ofItemAtPath: target.path)
        return target
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}

/// 🔴 The reason this type exists. Claude Code keeps transcripts for 30 days but
/// `ScanCache` retains 14, and the scanner skips anything older than its cutoff
/// *before opening it*. A fill must reach the 15-to-30 day band the scanner
/// refuses to look at — asserted here against the scanner itself.
@Test func fillReadsOutsideTheScannersRetentionWindow() throws {
    let tree = FillTree()
    let stamp = clock.addingTimeInterval(-20 * day)
    tree.session(assistantLine(output: 100, at: stamp),
                 at: "projects/-Users-me-Projects-Burnline/a.jsonl", modified: stamp)

    let filled = try HistoryFill(rootURL: tree.root)
        .cells(from: clock.addingTimeInterval(-25 * day), to: clock)

    #expect(filled.filesOpened == 1)
    #expect(filled.rows.count == 1)
    #expect(filled.rows.first?.output == 100)
    #expect(filled.rows.first?.project == "Burnline")

    // The contrast that makes the point: the scanner sees nothing at all here.
    let cache = try TranscriptScanner(rootURL: tree.root).scan(cache: ScanCache(), now: clock)
    #expect(cache.files.isEmpty)
}

/// mtime is the last append, so every record in a file precedes it. A file
/// untouched since before the range began cannot hold one inside it, and
/// opening it is pure cost — ~2,470 files' worth on this machine.
@Test func fillSkipsFilesModifiedBeforeTheRangeStarts() throws {
    let tree = FillTree()
    let stamp = clock.addingTimeInterval(-40 * day)
    tree.session(assistantLine(output: 100, at: stamp),
                 at: "projects/-Users-me-Projects-Burnline/old.jsonl", modified: stamp)

    let filled = try HistoryFill(rootURL: tree.root)
        .cells(from: clock.addingTimeInterval(-5 * day), to: clock)

    #expect(filled.filesOpened == 0)
    #expect(filled.rows.isEmpty)
}

@Test func aFillThatCannotReachItsRangeStartIsTruncated() throws {
    let tree = FillTree()
    let stamp = clock.addingTimeInterval(-5 * day)
    tree.session(assistantLine(output: 100, at: stamp),
                 at: "projects/-Users-me-Projects-Burnline/a.jsonl", modified: stamp)

    // 60 days back: the transcripts that covered the start are long deleted.
    let filled = try HistoryFill(rootURL: tree.root)
        .cells(from: clock.addingTimeInterval(-60 * day), to: clock)

    #expect(filled.rows.count == 1)
    #expect(filled.truncated)
}

/// The negative control. Without it `truncated` proves nothing — a field wired
/// to `true` would pass the test above.
@Test func fillIsNotTruncatedWhenItReachesTheRangeStart() throws {
    let tree = FillTree()
    let from = clock.addingTimeInterval(-10 * day)
    tree.session(assistantLine(output: 40, at: from)                     // exactly at `from`
                 + assistantLine(output: 60, at: from.addingTimeInterval(3600)),
                 at: "projects/-Users-me-Projects-Burnline/a.jsonl", modified: clock)

    let filled = try HistoryFill(rootURL: tree.root).cells(from: from, to: clock)

    #expect(!filled.truncated)
    // The lower bound is inclusive, so the record sitting on it is kept.
    #expect(filled.rows.map(\.output) == [40, 60])
}

/// 🔴 THE test. Two session files, same project, same model, same bucket — the
/// common case (multiple terminals, plus subagent transcripts). Rows have no
/// file field, so emitting one per file makes duplicate keys inside a single
/// commit and dedupe-on-read then keeps one file's share and discards the rest:
/// a silent, permanent undercount in an artifact that cannot be recomputed.
///
/// ⚠️ `rows.count == 1` alone passes against a merge that keeps one share.
/// The sum is the assertion that discriminates.
@Test func fillSumsAcrossFilesLikeTheFlushPath() throws {
    let tree = FillTree()
    let stamp = clock.addingTimeInterval(-3 * day)
    tree.session(assistantLine(output: 10, at: stamp),
                 at: "projects/-Users-me-Projects-Burnline/session-a.jsonl", modified: stamp)
    tree.session(assistantLine(output: 32, at: stamp),
                 at: "projects/-Users-me-Projects-Burnline/session-b.jsonl", modified: stamp)

    let filled = try HistoryFill(rootURL: tree.root)
        .cells(from: clock.addingTimeInterval(-7 * day), to: clock)

    #expect(filled.filesOpened == 2)
    #expect(filled.rows.count == 1)
    #expect(filled.rows.first?.output == 42)
}

/// The two paths write into one archive. If they disagree about a project's
/// name, the same project appears under two names and neither total is right.
@Test func fillAgreesWithTheFlushPathOnProjectNames() throws {
    let tree = FillTree()
    let stamp = clock.addingTimeInterval(-2 * day)
    // Nested below the encoded project dir, exactly as subagent transcripts are:
    // the parent directory is `subagents`, and the project is not.
    let file = tree.session(assistantLine(output: 12, at: stamp),
                            at: "projects/-Users-me-Projects-Burnline/sess/subagents/a.jsonl",
                            modified: stamp)

    let filled = try HistoryFill(rootURL: tree.root)
        .cells(from: clock.addingTimeInterval(-7 * day), to: clock)

    // The same file through the forward flush.
    var cache = ScanCache()
    cache.files[file.path] = FileState(
        modifiedAt: stamp, size: 1, offset: 1,
        cells: [String(Bucket.key(for: stamp)): ["claude-sonnet-5": TokenCounts(output: 12)]])
    let flushed = HistoryArchive.rows(from: cache, coverage: Coverage(records: []), through: Int(clock.timeIntervalSince1970))

    #expect(filled.rows.first?.project == "Burnline")
    #expect(filled.rows.first?.project == flushed.first?.project)
    // Same units, too: bucket START in epoch seconds, not the quarter-hour index.
    #expect(filled.rows.first?.bucket == flushed.first?.bucket)
}

@Test func recordsOutsideTheRangeAreExcluded() throws {
    let tree = FillTree()
    let from = clock.addingTimeInterval(-10 * day)
    let to = clock.addingTimeInterval(-5 * day)
    tree.session(assistantLine(output: 7, at: from.addingTimeInterval(-3600))
                 + assistantLine(output: 500, at: from.addingTimeInterval(3600))
                 + assistantLine(output: 9, at: to.addingTimeInterval(3600)),
                 at: "projects/-Users-me-Projects-Burnline/a.jsonl", modified: clock)

    let filled = try HistoryFill(rootURL: tree.root).cells(from: from, to: to)

    #expect(filled.rows.count == 1)
    #expect(filled.rows.first?.output == 500)
}

@Test func fillIgnoresFilesThatAreNotTranscripts() throws {
    let tree = FillTree()
    let stamp = clock.addingTimeInterval(-2 * day)
    tree.session(assistantLine(output: 100, at: stamp),
                 at: "projects/-Users-me-Projects-Burnline/a.jsonl", modified: stamp)
    tree.session(assistantLine(output: 100, at: stamp),
                 at: "projects/-Users-me-Projects-Burnline/notes.txt", modified: stamp)

    let filled = try HistoryFill(rootURL: tree.root)
        .cells(from: clock.addingTimeInterval(-7 * day), to: clock)

    #expect(filled.filesOpened == 1)
    #expect(filled.rows.count == 1)
}

/// Nothing found is reported as truncated, not as a clean empty range: an
/// unreadable root cannot distinguish an idle period from deleted transcripts,
/// and claiming coverage it never verified is the one unrecoverable answer.
@Test func aFillOverAMissingRootIsEmptyAndTruncated() throws {
    let missing = URL(fileURLWithPath: "/tmp/burnline-no-such-tree-\(UUID().uuidString)")
    let filled = try HistoryFill(rootURL: missing)
        .cells(from: clock.addingTimeInterval(-7 * day), to: clock)

    #expect(filled.rows.isEmpty)
    #expect(filled.filesOpened == 0)
    #expect(filled.truncated)
}
