import Testing
import Foundation
@testable import BurnlineCore

private func line(output: Int, at iso: String = "2026-08-10T18:51:57.446Z",
                  model: String = "claude-sonnet-5") -> String {
    """
    {"type":"assistant","timestamp":"\(iso)","message":{"model":"\(model)","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":\(output)}}}\n
    """
}

private struct TempDir: ~Copyable {
    let url: URL
    init() {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("burnline-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    func write(_ contents: String, to name: String) -> URL {
        let target = url.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? contents.write(to: target, atomically: true, encoding: .utf8)
        return target
    }
    func append(_ contents: String, to name: String) {
        let target = url.appendingPathComponent(name)
        guard let handle = try? FileHandle(forWritingTo: target) else { return }
        defer { try? handle.close() }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(contents.utf8))
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

private let never = Date(timeIntervalSince1970: 0)

/// Real "now": the temp files carry real mtimes, and the scanner evicts
/// anything older than `now - 14 days`. Passing `.distantFuture` here would
/// put the retention cutoff in the future and evict every file just scanned.
private let scanTime = Date()

@Test func scansASingleFile() throws {
    let dir = TempDir()
    _ = dir.write(line(output: 100), to: "proj/a.jsonl")
    let scanner = TranscriptScanner(rootURL: dir.url, weights: .default)
    let cache = try scanner.scan(cache: ScanCache(), now: scanTime)
    // 100 output x 5.0 x sonnet 1.0
    #expect(abs(cache.units(from: never, to: .distantFuture) - 500) < 1e-9)
}

@Test func ignoresNonJSONLFiles() throws {
    let dir = TempDir()
    _ = dir.write(line(output: 100), to: "proj/a.jsonl")
    _ = dir.write(line(output: 100), to: "proj/notes.txt")
    let scanner = TranscriptScanner(rootURL: dir.url, weights: .default)
    let cache = try scanner.scan(cache: ScanCache(), now: scanTime)
    #expect(abs(cache.units(from: never, to: .distantFuture) - 500) < 1e-9)
}

@Test func secondScanReadsOnlyAppendedBytes() throws {
    let dir = TempDir()
    _ = dir.write(line(output: 100), to: "proj/a.jsonl")
    let scanner = TranscriptScanner(rootURL: dir.url, weights: .default)
    var cache = try scanner.scan(cache: ScanCache(), now: scanTime)
    let firstOffset = cache.files.values.first!.offset

    dir.append(line(output: 100), to: "proj/a.jsonl")
    cache = try scanner.scan(cache: cache, now: scanTime)

    #expect(cache.files.values.first!.offset > firstOffset)
    #expect(abs(cache.units(from: never, to: .distantFuture) - 1000) < 1e-9)
}

@Test func rescanningAnUnchangedFileDoesNotDoubleCount() throws {
    let dir = TempDir()
    _ = dir.write(line(output: 100), to: "proj/a.jsonl")
    let scanner = TranscriptScanner(rootURL: dir.url, weights: .default)
    var cache = try scanner.scan(cache: ScanCache(), now: scanTime)
    cache = try scanner.scan(cache: cache, now: scanTime)
    cache = try scanner.scan(cache: cache, now: scanTime)
    #expect(abs(cache.units(from: never, to: .distantFuture) - 500) < 1e-9)
}

@Test func aTrailingPartialLineIsRereadIntact() throws {
    let dir = TempDir()
    let complete = line(output: 100)
    let full = line(output: 200)
    let partial = String(full.dropLast(30))   // no trailing newline
    _ = dir.write(complete + partial, to: "proj/a.jsonl")

    let scanner = TranscriptScanner(rootURL: dir.url, weights: .default)
    var cache = try scanner.scan(cache: ScanCache(), now: scanTime)
    #expect(abs(cache.units(from: never, to: .distantFuture) - 500) < 1e-9)

    // Complete the partial line; its full value must now be counted exactly once.
    dir.append(String(full.suffix(30)), to: "proj/a.jsonl")
    cache = try scanner.scan(cache: cache, now: scanTime)
    #expect(abs(cache.units(from: never, to: .distantFuture) - 1500) < 1e-9)
}

@Test func aTruncatedFileIsRereadWholeRatherThanDoubleCounted() throws {
    let dir = TempDir()
    _ = dir.write(line(output: 100) + line(output: 100), to: "proj/a.jsonl")
    let scanner = TranscriptScanner(rootURL: dir.url, weights: .default)
    var cache = try scanner.scan(cache: ScanCache(), now: scanTime)
    #expect(abs(cache.units(from: never, to: .distantFuture) - 1000) < 1e-9)

    // Rewrite shorter — offset now exceeds size.
    _ = dir.write(line(output: 100), to: "proj/a.jsonl")
    cache = try scanner.scan(cache: cache, now: scanTime)
    #expect(abs(cache.units(from: never, to: .distantFuture) - 500) < 1e-9)
}

@Test func modelWeightingIsAppliedDuringTheScan() throws {
    let dir = TempDir()
    _ = dir.write(line(output: 100, model: "claude-opus-5"), to: "proj/a.jsonl")
    let scanner = TranscriptScanner(rootURL: dir.url, weights: .default)
    let cache = try scanner.scan(cache: ScanCache(), now: scanTime)
    // 100 x 5.0 output x 5.0 opus
    #expect(abs(cache.units(from: never, to: .distantFuture) - 2500) < 1e-9)
}

@Test func missingRootDirectoryYieldsAnEmptyCache() throws {
    let missing = URL(fileURLWithPath: "/tmp/burnline-does-not-exist-\(UUID().uuidString)")
    let scanner = TranscriptScanner(rootURL: missing, weights: .default)
    let cache = try scanner.scan(cache: ScanCache(), now: scanTime)
    #expect(cache.files.isEmpty)
}

@Test func entriesForDeletedFilesAreDropped() throws {
    let dir = TempDir()
    let file = dir.write(line(output: 100), to: "proj/a.jsonl")
    let scanner = TranscriptScanner(rootURL: dir.url, weights: .default)
    var cache = try scanner.scan(cache: ScanCache(), now: scanTime)
    #expect(cache.files.count == 1)

    try FileManager.default.removeItem(at: file)
    cache = try scanner.scan(cache: cache, now: scanTime)
    #expect(cache.files.isEmpty)
}

@Test func filesOlderThanRetentionAreSkippedWithoutReading() throws {
    let dir = TempDir()
    let old = dir.write(line(output: 100), to: "proj/old.jsonl")
    _ = dir.write(line(output: 100), to: "proj/new.jsonl")

    // Backdate past the 14-day retention cutoff.
    try FileManager.default.setAttributes(
        [.modificationDate: scanTime.addingTimeInterval(-20 * 86_400)], ofItemAtPath: old.path)

    let scanner = TranscriptScanner(rootURL: dir.url, weights: .default)
    let cache = try scanner.scan(cache: ScanCache(), now: scanTime)

    #expect(cache.files.count == 1)
    #expect(cache.files.keys.first?.hasSuffix("new.jsonl") == true)
    // Only the fresh file's usage counted.
    #expect(abs(cache.units(from: never, to: .distantFuture) - 500) < 1e-9)
}

/// Not a behaviour this file introduces — a precondition `UsageStore` now leans
/// on. It skips persisting when the scan returns a cache equal to the one it
/// went in with, so if a no-op rescan ever produced an unequal cache the app
/// would silently go back to rewriting hundreds of KB every 60s forever.
@Test func aNoOpRescanProducesAnIdenticalCache() throws {
    let dir = TempDir()
    _ = dir.write(line(output: 100), to: "proj/a.jsonl")
    _ = dir.write(line(output: 250), to: "proj/nested/b.jsonl")
    let scanner = TranscriptScanner(rootURL: dir.url, weights: .default)

    let first = try scanner.scan(cache: ScanCache(), now: scanTime)
    let second = try scanner.scan(cache: first, now: scanTime)

    #expect(second == first)
}

// MARK: - Weights are baked into the cache

private func weights(output: Double) -> Weights {
    var weights = Weights.default
    weights.output = output
    return weights
}

/// Buckets store *weighted* units, so a cache built under one weight set says
/// nothing about another. Editing a weight in Settings must rescore everything,
/// not just bytes appended afterwards.
@Test func changingWeightsRescoresEveryBucket() throws {
    let dir = TempDir()
    _ = dir.write(line(output: 100), to: "proj/a.jsonl")

    let light = try TranscriptScanner(rootURL: dir.url, weights: weights(output: 5))
        .scan(cache: ScanCache(), now: scanTime)
    #expect(abs(light.units(from: never, to: .distantFuture) - 500) < 1e-9)

    // Same untouched file, tenfold output weight.
    let heavy = try TranscriptScanner(rootURL: dir.url, weights: weights(output: 50))
        .scan(cache: light, now: scanTime)

    #expect(abs(heavy.units(from: never, to: .distantFuture) - 5_000) < 1e-9)
}

/// The counterweight to the test above: rescoring must happen only when the
/// weights actually differ. Discarding the cache on every scan would turn the
/// 30ms warm path back into a multi-second cold one on every refresh.
@Test func unchangedWeightsStillScanIncrementally() throws {
    let dir = TempDir()
    _ = dir.write(line(output: 100), to: "proj/a.jsonl")
    let scanner = TranscriptScanner(rootURL: dir.url, weights: .default)

    let first = try scanner.scan(cache: ScanCache(), now: scanTime)
    let offsetAfterFirst = first.files.values.first?.offset

    let second = try scanner.scan(cache: first, now: scanTime)

    // A re-read from zero would reset and re-advance the offset to the same
    // place, so assert on the totals too: a full rescan would double-count.
    #expect(second.files.values.first?.offset == offsetAfterFirst)
    #expect(abs(second.units(from: never, to: .distantFuture) - 500) < 1e-9)
}

/// A cache written before weights were tracked can't be trusted either — there
/// is no way to know what it was scored with.
@Test func aCacheWithNoRecordedWeightsIsRescored() throws {
    let dir = TempDir()
    _ = dir.write(line(output: 100), to: "proj/a.jsonl")

    var untracked = try TranscriptScanner(rootURL: dir.url, weights: weights(output: 5))
        .scan(cache: ScanCache(), now: scanTime)
    untracked.weights = nil

    let rescored = try TranscriptScanner(rootURL: dir.url, weights: weights(output: 50))
        .scan(cache: untracked, now: scanTime)

    #expect(abs(rescored.units(from: never, to: .distantFuture) - 5_000) < 1e-9)
}
