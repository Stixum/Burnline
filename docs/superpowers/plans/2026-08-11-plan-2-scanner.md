# Burnline Plan 2 — Scanner and snapshot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Read real token usage out of Claude Code's transcripts incrementally, accumulate it into a persistent bucket cache, and assemble a complete `Snapshot` — ending with a CLI probe that prints real numbers from the real transcripts, before any UI exists.

**Architecture:** `TranscriptScanner` walks `~/.claude/projects/**/*.jsonl` and folds new bytes into a per-file `ScanCache` of 15-minute unit buckets, resuming from stored byte offsets. `SnapshotBuilder` is a pure function combining cache totals, `WindowMath`, `Calibration` and `Projection` into one immutable `Snapshot`. A `BurnlineProbe` executable prints it.

**Tech Stack:** Swift 6.3, SwiftPM, Swift Testing, Foundation (`FileHandle`, `JSONDecoder`, `ISO8601DateFormatter`).

**Spec:** `docs/superpowers/specs/2026-08-11-burnline-design.md` §7. **Depends on:** Plan 1 complete.

---

## Background for the implementer

**The transcript format.** Each `.jsonl` file is one Claude Code session, one JSON object per line, appended to live while a session runs. Only lines with `"type": "assistant"` carry token counts. A real line looks like:

```json
{"type":"assistant","timestamp":"2026-08-10T18:51:57.446Z","message":{"model":"claude-sonnet-5","usage":{"input_tokens":2,"cache_creation_input_tokens":26527,"cache_read_input_tokens":30640,"output_tokens":135,"iterations":[...]}}}
```

Three traps in that shape:

1. **`usage.iterations` restates the same totals per turn.** Summing it double-counts. The decoder below simply doesn't declare the key, so it's ignored — do not "helpfully" add it.
2. **Other line types put a *string* in `message`**, so a strict decode of every line throws. That's expected; skip and continue.
3. **The last line of an active session is often a partial write.** Advancing the byte offset past it would lose the record forever, so the offset only ever advances to the last complete newline.

**Scale, measured on this machine:** 2,929 files, ~1.5s for a cold full scan, 368 files touched in a 7-day span, 41,520 assistant messages per week. Cold scan happens once; steady state re-reads only appended bytes.

## File Structure

| File | Responsibility |
|---|---|
| `Sources/BurnlineCore/Bucket.swift` | 15-minute bucket keying |
| `Sources/BurnlineCore/ScanCache.swift` | Persistent per-file state + window summation |
| `Sources/BurnlineCore/TranscriptParser.swift` | Bytes → `[UsageRecord]` |
| `Sources/BurnlineCore/TranscriptScanner.swift` | Filesystem walk + incremental fold into the cache |
| `Sources/BurnlineCore/BurnlineSettings.swift` | Codable settings: schedule, weights, anchors |
| `Sources/BurnlineCore/Snapshot.swift` | The immutable value the UI renders |
| `Sources/BurnlineCore/SnapshotBuilder.swift` | Pure: cache + settings + now → Snapshot |
| `Sources/BurnlineProbe/main.swift` | CLI that prints a Snapshot from real data |

---

## Task 1: Bucket keying

**Files:**
- Create: `Sources/BurnlineCore/Bucket.swift`
- Test: `Tests/BurnlineCoreTests/BucketTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/BurnlineCoreTests/BucketTests.swift
import Testing
import Foundation
@testable import BurnlineCore

@Test func bucketKeyIsStableWithinAQuarterHour() {
    let base = Date(timeIntervalSince1970: 1_800_000_000)  // exactly on a 900s boundary
    #expect(Bucket.key(for: base) == Bucket.key(for: base.addingTimeInterval(899)))
    #expect(Bucket.key(for: base) != Bucket.key(for: base.addingTimeInterval(900)))
}

@Test func bucketKeysAdvanceByOne() {
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(Bucket.key(for: base.addingTimeInterval(900)) == Bucket.key(for: base) + 1)
}

@Test func bucketStartRoundTripsTheKey() {
    let base = Date(timeIntervalSince1970: 1_800_000_450)
    let start = Bucket.start(ofKey: Bucket.key(for: base))
    #expect(start <= base)
    #expect(base.timeIntervalSince(start) < 900)
}

@Test func bucketKeyFloorsRatherThanRounds() {
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(Bucket.key(for: base.addingTimeInterval(890)) == Bucket.key(for: base))
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter BucketTests`
Expected: FAIL — `cannot find 'Bucket' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/BurnlineCore/Bucket.swift
import Foundation

/// Usage is accumulated into fixed 15-minute buckets.
///
/// Buckets must be per-file so a truncated file's contribution can be dropped
/// wholesale, and a window total sums whole buckets — so a bucket straddling
/// the window boundary is counted all-in or all-out. At 15 minutes that error
/// is at most 0.15% of a 7-day window, and it disappears entirely when the
/// reset lands on a quarter hour.
public enum Bucket {
    public static let seconds: TimeInterval = 900

    public static func key(for date: Date) -> Int {
        Int((date.timeIntervalSince1970 / seconds).rounded(.down))
    }

    public static func start(ofKey key: Int) -> Date {
        Date(timeIntervalSince1970: Double(key) * seconds)
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter BucketTests`
Expected: PASS, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/BurnlineCore/Bucket.swift Tests/BurnlineCoreTests/BucketTests.swift
git commit -m "feat: 15-minute usage buckets"
```

---

## Task 2: ScanCache

**Files:**
- Create: `Sources/BurnlineCore/ScanCache.swift`
- Test: `Tests/BurnlineCoreTests/ScanCacheTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/BurnlineCoreTests/ScanCacheTests.swift
import Testing
import Foundation
@testable import BurnlineCore

private let anchorDate = Date(timeIntervalSince1970: 1_800_000_000)

private func state(at date: Date, units: Double) -> FileState {
    FileState(modifiedAt: date, size: 100, offset: 100,
              buckets: [String(Bucket.key(for: date)): units])
}

@Test func sumsBucketsInsideTheWindow() {
    var cache = ScanCache()
    cache.files["a.jsonl"] = state(at: anchorDate.addingTimeInterval(3600), units: 10)
    cache.files["b.jsonl"] = state(at: anchorDate.addingTimeInterval(7200), units: 25)
    let total = cache.units(from: anchorDate, to: anchorDate.addingTimeInterval(86_400))
    #expect(abs(total - 35) < 1e-9)
}

@Test func excludesBucketsOutsideTheWindow() {
    var cache = ScanCache()
    cache.files["old.jsonl"] = state(at: anchorDate.addingTimeInterval(-86_400), units: 999)
    cache.files["new.jsonl"] = state(at: anchorDate.addingTimeInterval(3600), units: 10)
    let total = cache.units(from: anchorDate, to: anchorDate.addingTimeInterval(86_400))
    #expect(abs(total - 10) < 1e-9)
}

@Test func windowEndIsExclusive() {
    var cache = ScanCache()
    let end = anchorDate.addingTimeInterval(86_400)
    cache.files["edge.jsonl"] = state(at: end, units: 50)
    #expect(cache.units(from: anchorDate, to: end) == 0)
}

@Test func evictsFilesUntouchedBeyondTheRetentionWindow() {
    var cache = ScanCache()
    cache.files["stale.jsonl"] = state(at: anchorDate.addingTimeInterval(-15 * 86_400), units: 1)
    cache.files["fresh.jsonl"] = state(at: anchorDate.addingTimeInterval(-1 * 86_400), units: 1)
    cache.evict(before: anchorDate.addingTimeInterval(-14 * 86_400))
    #expect(cache.files["stale.jsonl"] == nil)
    #expect(cache.files["fresh.jsonl"] != nil)
}

@Test func roundTripsThroughJSON() throws {
    var cache = ScanCache()
    cache.files["a.jsonl"] = state(at: anchorDate, units: 12.5)
    let data = try JSONEncoder().encode(cache)
    let decoded = try JSONDecoder().decode(ScanCache.self, from: data)
    #expect(decoded == cache)
}

@Test func rejectsACacheFromAnIncompatibleVersion() throws {
    let json = #"{"version":0,"files":{}}"#.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(ScanCache.self, from: json)
    #expect(decoded.isCompatible == false)
}

@Test func emptyCacheSumsToZero() {
    #expect(ScanCache().units(from: anchorDate, to: anchorDate.addingTimeInterval(86_400)) == 0)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter ScanCacheTests`
Expected: FAIL — `cannot find 'ScanCache' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/BurnlineCore/ScanCache.swift
import Foundation

/// What we know about one transcript file.
public struct FileState: Equatable, Sendable, Codable {
    public var modifiedAt: Date
    public var size: Int
    /// Byte offset of the end of the last *complete* line consumed.
    public var offset: Int
    /// Bucket key (as a string, so it survives JSON) → weighted units.
    public var buckets: [String: Double]

    public init(modifiedAt: Date = .distantPast, size: Int = 0, offset: Int = 0,
                buckets: [String: Double] = [:]) {
        self.modifiedAt = modifiedAt
        self.size = size
        self.offset = offset
        self.buckets = buckets
    }
}

/// Persistent incremental scan state. Lives at
/// `~/Library/Application Support/Burnline/scan-cache.json`.
public struct ScanCache: Equatable, Sendable, Codable {
    public static let currentVersion = 1
    /// Files untouched for longer than this are dropped.
    public static let retention: TimeInterval = 14 * 86_400

    public var version: Int
    public var files: [String: FileState]

    public init(version: Int = ScanCache.currentVersion, files: [String: FileState] = [:]) {
        self.version = version
        self.files = files
    }

    public var isCompatible: Bool { version == Self.currentVersion }

    /// Total weighted units in `[start, end)`.
    public func units(from start: Date, to end: Date) -> Double {
        let lower = Bucket.key(for: start)
        let upper = Bucket.key(for: end)
        var total = 0.0
        for state in files.values {
            for (rawKey, units) in state.buckets {
                guard let key = Int(rawKey), key >= lower, key < upper else { continue }
                total += units
            }
        }
        return total
    }

    /// Drops files not modified since `cutoff`. If such a file is touched again
    /// it re-reads from zero; the buckets it recomputes fall outside any live
    /// window, so the double-read is harmless.
    public mutating func evict(before cutoff: Date) {
        files = files.filter { $0.value.modifiedAt >= cutoff }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter ScanCacheTests`
Expected: PASS, 7 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/BurnlineCore/ScanCache.swift Tests/BurnlineCoreTests/ScanCacheTests.swift
git commit -m "feat: ScanCache with window summation and retention eviction"
```

---

## Task 3: TranscriptParser

**Files:**
- Create: `Sources/BurnlineCore/TranscriptParser.swift`
- Test: `Tests/BurnlineCoreTests/TranscriptParserTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/BurnlineCoreTests/TranscriptParserTests.swift
import Testing
import Foundation
@testable import BurnlineCore

private let assistantLine = """
{"type":"assistant","timestamp":"2026-08-10T18:51:57.446Z","message":{"model":"claude-sonnet-5","usage":{"input_tokens":2,"cache_creation_input_tokens":26527,"cache_read_input_tokens":30640,"output_tokens":135}}}
"""

private func parse(_ text: String) -> [UsageRecord] {
    TranscriptParser().parse(Data(text.utf8))
}

@Test func parsesAnAssistantLine() {
    let records = parse(assistantLine + "\n")
    #expect(records.count == 1)
    #expect(records[0].model == "claude-sonnet-5")
    #expect(records[0].inputTokens == 2)
    #expect(records[0].outputTokens == 135)
    #expect(records[0].cacheWriteTokens == 26527)
    #expect(records[0].cacheReadTokens == 30640)
}

@Test func parsesFractionalSecondTimestamps() {
    let records = parse(assistantLine + "\n")
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    #expect(calendar.component(.hour, from: records[0].timestamp) == 18)
    #expect(calendar.component(.minute, from: records[0].timestamp) == 51)
}

@Test func parsesTimestampsWithoutFractionalSeconds() {
    let line = assistantLine.replacingOccurrences(of: "57.446Z", with: "57Z")
    #expect(parse(line + "\n").count == 1)
}

@Test func skipsMalformedLinesAndKeepsGoing() {
    let text = "not json at all\n" + assistantLine + "\n{\"broken\":\n"
    #expect(parse(text).count == 1)
}

@Test func ignoresNonAssistantLines() {
    let user = #"{"type":"user","timestamp":"2026-08-10T18:00:00.000Z","message":"a plain string"}"#
    let text = user + "\n" + assistantLine + "\n"
    #expect(parse(text).count == 1)
}

@Test func ignoresAssistantLinesWithoutUsage() {
    let noUsage = #"{"type":"assistant","timestamp":"2026-08-10T18:00:00.000Z","message":{"model":"claude-opus-5"}}"#
    #expect(parse(noUsage + "\n").isEmpty)
}

@Test func doesNotDoubleCountIterations() {
    // `iterations` restates the same totals. Only the outer numbers may count.
    let withIterations = """
    {"type":"assistant","timestamp":"2026-08-10T18:51:57.446Z","message":{"model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"iterations":[{"input_tokens":10,"output_tokens":20}]}}}
    """
    let records = parse(withIterations + "\n")
    #expect(records.count == 1)
    #expect(records[0].inputTokens == 10)
    #expect(records[0].outputTokens == 20)
}

@Test func treatsMissingTokenFieldsAsZero() {
    let sparse = #"{"type":"assistant","timestamp":"2026-08-10T18:00:00.000Z","message":{"model":"claude-opus-5","usage":{"output_tokens":7}}}"#
    let records = parse(sparse + "\n")
    #expect(records[0].inputTokens == 0)
    #expect(records[0].cacheReadTokens == 0)
    #expect(records[0].outputTokens == 7)
}

@Test func skipsLinesWithNoTimestamp() {
    let noTime = #"{"type":"assistant","message":{"model":"claude-opus-5","usage":{"output_tokens":7}}}"#
    #expect(parse(noTime + "\n").isEmpty)
}

@Test func handlesAnEmptyModelName() {
    let noModel = #"{"type":"assistant","timestamp":"2026-08-10T18:00:00.000Z","message":{"usage":{"output_tokens":7}}}"#
    let records = parse(noModel + "\n")
    #expect(records.count == 1)
    #expect(records[0].model == "")
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter TranscriptParserTests`
Expected: FAIL — `cannot find 'TranscriptParser' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/BurnlineCore/TranscriptParser.swift
import Foundation

/// Turns raw transcript bytes into usage records.
///
/// Holds its own date formatters, so create one per scan rather than sharing a
/// global — Foundation formatters are not `Sendable`.
public struct TranscriptParser {
    private let fractional: ISO8601DateFormatter
    private let plain: ISO8601DateFormatter
    private static let usageNeedle = Data(#""usage""#.utf8)
    private static let newline = UInt8(ascii: "\n")

    public init() {
        fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
    }

    /// Parses whole lines only. `data` must end at a line boundary.
    public func parse(_ data: Data) -> [UsageRecord] {
        var records: [UsageRecord] = []
        let decoder = JSONDecoder()

        for line in data.split(separator: Self.newline, omittingEmptySubsequences: true) {
            // Cheap prefilter: most lines are tool results and never mention usage.
            guard Data(line).range(of: Self.usageNeedle) != nil else { continue }
            guard let raw = try? decoder.decode(TranscriptLine.self, from: Data(line)) else { continue }
            guard raw.type == "assistant",
                  let usage = raw.message?.usage,
                  let stamp = raw.timestamp,
                  let timestamp = date(from: stamp) else { continue }

            records.append(UsageRecord(
                timestamp: timestamp,
                model: raw.message?.model ?? "",
                inputTokens: usage.inputTokens ?? 0,
                outputTokens: usage.outputTokens ?? 0,
                cacheWriteTokens: usage.cacheCreationInputTokens ?? 0,
                cacheReadTokens: usage.cacheReadInputTokens ?? 0
            ))
        }
        return records
    }

    private func date(from string: String) -> Date? {
        fractional.date(from: string) ?? plain.date(from: string)
    }
}

/// Only the keys we need. `usage.iterations` is deliberately absent — it
/// restates the same totals per turn and would double-count.
private struct TranscriptLine: Decodable {
    let type: String?
    let timestamp: String?
    let message: Message?

    struct Message: Decodable {
        let model: String?
        let usage: Usage?
    }

    struct Usage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheCreationInputTokens: Int?
        let cacheReadInputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
        }
    }
}
```

> Note: `message` is declared optional and typed as an object. Lines where `message` is a plain string fail to decode and are skipped — which is the desired behaviour, since only assistant lines matter.

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter TranscriptParserTests`
Expected: PASS, 10 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/BurnlineCore/TranscriptParser.swift Tests/BurnlineCoreTests/TranscriptParserTests.swift
git commit -m "feat: TranscriptParser reading assistant usage from JSONL"
```

---

## Task 4: TranscriptScanner

**Files:**
- Create: `Sources/BurnlineCore/TranscriptScanner.swift`
- Test: `Tests/BurnlineCoreTests/TranscriptScannerTests.swift`

- [ ] **Step 1: Write the failing test**

These tests write real files into a temp directory. Use a helper that creates and cleans up per test.

```swift
// Tests/BurnlineCoreTests/TranscriptScannerTests.swift
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

@Test func scansASingleFile() throws {
    let dir = TempDir()
    _ = dir.write(line(output: 100), to: "proj/a.jsonl")
    let scanner = TranscriptScanner(rootURL: dir.url, weights: .default)
    let cache = try scanner.scan(cache: ScanCache(), now: .distantFuture)
    // 100 output × 5.0 × sonnet 1.0
    #expect(abs(cache.units(from: never, to: .distantFuture) - 500) < 1e-9)
}

@Test func ignoresNonJSONLFiles() throws {
    let dir = TempDir()
    _ = dir.write(line(output: 100), to: "proj/a.jsonl")
    _ = dir.write(line(output: 100), to: "proj/notes.txt")
    let scanner = TranscriptScanner(rootURL: dir.url, weights: .default)
    let cache = try scanner.scan(cache: ScanCache(), now: .distantFuture)
    #expect(abs(cache.units(from: never, to: .distantFuture) - 500) < 1e-9)
}

@Test func secondScanReadsOnlyAppendedBytes() throws {
    let dir = TempDir()
    _ = dir.write(line(output: 100), to: "proj/a.jsonl")
    let scanner = TranscriptScanner(rootURL: dir.url, weights: .default)
    var cache = try scanner.scan(cache: ScanCache(), now: .distantFuture)
    let firstOffset = cache.files.values.first!.offset

    dir.append(line(output: 100), to: "proj/a.jsonl")
    cache = try scanner.scan(cache: cache, now: .distantFuture)

    #expect(cache.files.values.first!.offset > firstOffset)
    #expect(abs(cache.units(from: never, to: .distantFuture) - 1000) < 1e-9)
}

@Test func rescanningAnUnchangedFileDoesNotDoubleCount() throws {
    let dir = TempDir()
    _ = dir.write(line(output: 100), to: "proj/a.jsonl")
    let scanner = TranscriptScanner(rootURL: dir.url, weights: .default)
    var cache = try scanner.scan(cache: ScanCache(), now: .distantFuture)
    cache = try scanner.scan(cache: cache, now: .distantFuture)
    cache = try scanner.scan(cache: cache, now: .distantFuture)
    #expect(abs(cache.units(from: never, to: .distantFuture) - 500) < 1e-9)
}

@Test func aTrailingPartialLineIsRereadIntact() throws {
    let dir = TempDir()
    let complete = line(output: 100)
    let partial = String(line(output: 200).dropLast(30))   // no trailing newline
    _ = dir.write(complete + partial, to: "proj/a.jsonl")

    let scanner = TranscriptScanner(rootURL: dir.url, weights: .default)
    var cache = try scanner.scan(cache: ScanCache(), now: .distantFuture)
    #expect(abs(cache.units(from: never, to: .distantFuture) - 500) < 1e-9)

    // Complete the partial line; its full value must now be counted exactly once.
    dir.append(String(line(output: 200).suffix(30)), to: "proj/a.jsonl")
    cache = try scanner.scan(cache: cache, now: .distantFuture)
    #expect(abs(cache.units(from: never, to: .distantFuture) - 1500) < 1e-9)
}

@Test func aTruncatedFileIsRereadWholeRatherThanDoubleCounted() throws {
    let dir = TempDir()
    _ = dir.write(line(output: 100) + line(output: 100), to: "proj/a.jsonl")
    let scanner = TranscriptScanner(rootURL: dir.url, weights: .default)
    var cache = try scanner.scan(cache: ScanCache(), now: .distantFuture)
    #expect(abs(cache.units(from: never, to: .distantFuture) - 1000) < 1e-9)

    // Rewrite shorter — offset now exceeds size.
    _ = dir.write(line(output: 100), to: "proj/a.jsonl")
    cache = try scanner.scan(cache: cache, now: .distantFuture)
    #expect(abs(cache.units(from: never, to: .distantFuture) - 500) < 1e-9)
}

@Test func modelWeightingIsAppliedDuringTheScan() throws {
    let dir = TempDir()
    _ = dir.write(line(output: 100, model: "claude-opus-5"), to: "proj/a.jsonl")
    let scanner = TranscriptScanner(rootURL: dir.url, weights: .default)
    let cache = try scanner.scan(cache: ScanCache(), now: .distantFuture)
    // 100 × 5.0 output × 5.0 opus
    #expect(abs(cache.units(from: never, to: .distantFuture) - 2500) < 1e-9)
}

@Test func missingRootDirectoryYieldsAnEmptyCache() throws {
    let missing = URL(fileURLWithPath: "/tmp/burnline-does-not-exist-\(UUID().uuidString)")
    let scanner = TranscriptScanner(rootURL: missing, weights: .default)
    let cache = try scanner.scan(cache: ScanCache(), now: .distantFuture)
    #expect(cache.files.isEmpty)
}

@Test func entriesForDeletedFilesAreDropped() throws {
    let dir = TempDir()
    let file = dir.write(line(output: 100), to: "proj/a.jsonl")
    let scanner = TranscriptScanner(rootURL: dir.url, weights: .default)
    var cache = try scanner.scan(cache: ScanCache(), now: .distantFuture)
    #expect(cache.files.count == 1)

    try FileManager.default.removeItem(at: file)
    cache = try scanner.scan(cache: cache, now: .distantFuture)
    #expect(cache.files.isEmpty)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter TranscriptScannerTests`
Expected: FAIL — `cannot find 'TranscriptScanner' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/BurnlineCore/TranscriptScanner.swift
import Foundation

/// Walks Claude Code's transcripts and folds new bytes into a `ScanCache`.
///
/// A cold scan of ~2,900 files takes about 1.5 seconds; steady state re-reads
/// only appended bytes, which is why every refresh can afford to run.
public struct TranscriptScanner: Sendable {
    public let rootURL: URL
    public let weights: Weights

    public init(rootURL: URL = TranscriptScanner.defaultRoot, weights: Weights = .default) {
        self.rootURL = rootURL
        self.weights = weights
    }

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }

    public func scan(cache incoming: ScanCache, now: Date) throws -> ScanCache {
        var cache = incoming.isCompatible ? incoming : ScanCache()
        let parser = TranscriptParser()
        var seen = Set<String>()

        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )

        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "jsonl" else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }

            let path = url.path
            seen.insert(path)
            let modifiedAt = values.contentModificationDate ?? .distantPast
            let size = values.fileSize ?? 0

            var state = cache.files[path] ?? FileState()

            // A shrunken file was rewritten or truncated; its old buckets are
            // no longer trustworthy, so start it over.
            if size < state.offset {
                state = FileState()
            }

            // Untouched since last time — nothing to do.
            if state.modifiedAt == modifiedAt, state.size == size, state.offset > 0 {
                cache.files[path] = state
                continue
            }

            let (records, newOffset) = readAppended(at: url, from: state.offset, parser: parser)
            for record in records {
                let key = String(Bucket.key(for: record.timestamp))
                state.buckets[key, default: 0] += ConsumptionModel.units(for: record, weights: weights)
            }
            state.offset = newOffset
            state.size = size
            state.modifiedAt = modifiedAt
            cache.files[path] = state
        }

        // Forget files that no longer exist, then apply retention.
        cache.files = cache.files.filter { seen.contains($0.key) }
        cache.evict(before: now.addingTimeInterval(-ScanCache.retention))
        return cache
    }

    /// Reads from `offset` to the last complete line. Never advances past a
    /// partial trailing write — sessions are appended to live.
    private func readAppended(at url: URL, from offset: Int,
                              parser: TranscriptParser) -> ([UsageRecord], Int) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ([], offset) }
        defer { try? handle.close() }

        if offset > 0 {
            guard (try? handle.seek(toOffset: UInt64(offset))) != nil else { return ([], offset) }
        }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return ([], offset) }
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return ([], offset) }

        let complete = data[data.startIndex...lastNewline]
        return (parser.parse(Data(complete)), offset + complete.count)
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter TranscriptScannerTests`
Expected: PASS, 9 tests.

The two tests that matter most are `aTrailingPartialLineIsRereadIntact` and `aTruncatedFileIsRereadWholeRatherThanDoubleCounted` — they encode the only two ways this design silently corrupts its own totals.

- [ ] **Step 5: Commit**

```bash
git add Sources/BurnlineCore/TranscriptScanner.swift Tests/BurnlineCoreTests/TranscriptScannerTests.swift
git commit -m "feat: incremental TranscriptScanner with truncation and partial-line handling"
```

---

## Task 5: Settings and Snapshot

**Files:**
- Create: `Sources/BurnlineCore/BurnlineSettings.swift`
- Create: `Sources/BurnlineCore/Snapshot.swift`
- Create: `Sources/BurnlineCore/SnapshotBuilder.swift`
- Test: `Tests/BurnlineCoreTests/SnapshotBuilderTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/BurnlineCoreTests/SnapshotBuilderTests.swift
import Testing
import Foundation
@testable import BurnlineCore

private let chicago = TimeZone(identifier: "America/Chicago")!

private func settings(anchors: [CalibrationAnchor] = []) -> BurnlineSettings {
    var settings = BurnlineSettings.default
    settings.resetSchedule = ResetSchedule(weekday: 5, hour: 9, timeZone: chicago)
    settings.calibrationAnchors = anchors
    return settings
}

private func cache(units: Double, at date: Date) -> ScanCache {
    var cache = ScanCache()
    cache.files["a.jsonl"] = FileState(modifiedAt: date, size: 1, offset: 1,
                                       buckets: [String(Bucket.key(for: date)): units])
    return cache
}

@Test func uncalibratedSnapshotHasTargetButNoEstimate() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let window = WindowMath.window(for: settings().resetSchedule, now: now)
    let snapshot = SnapshotBuilder.build(
        cache: cache(units: 5_000, at: window.start.addingTimeInterval(60)),
        settings: settings(), now: now, isScanning: false)

    #expect(snapshot.estimatedPercent == nil)
    #expect(snapshot.projectedPercent == nil)
    #expect(snapshot.deltaPercent == nil)
    #expect(snapshot.targetPercent > 0)
    #expect(snapshot.isPaceOnly)
}

@Test func calibratedSnapshotProducesEstimateAndDelta() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let window = WindowMath.window(for: settings().resetSchedule, now: now)
    let anchors = [CalibrationAnchor(timestamp: now.addingTimeInterval(-86_400),
                                     observedPercent: 50, unitsInWindow: 5_000)]
    let snapshot = SnapshotBuilder.build(
        cache: cache(units: 4_000, at: window.start.addingTimeInterval(60)),
        settings: settings(anchors: anchors), now: now, isScanning: false)

    #expect(abs(snapshot.estimatedPercent! - 40) < 1e-6)
    #expect(snapshot.isPaceOnly == false)
    // delta is target − estimate: positive means under budget
    #expect(abs(snapshot.deltaPercent! - (snapshot.targetPercent - 40)) < 1e-6)
}

@Test func unitsOutsideTheWindowDoNotCount() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let window = WindowMath.window(for: settings().resetSchedule, now: now)
    let snapshot = SnapshotBuilder.build(
        cache: cache(units: 9_999, at: window.start.addingTimeInterval(-86_400)),
        settings: settings(), now: now, isScanning: false)
    #expect(snapshot.unitsInWindow == 0)
}

@Test func isUnderBudgetWhenEstimateTrailsTarget() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let window = WindowMath.window(for: settings().resetSchedule, now: now)
    let anchors = [CalibrationAnchor(timestamp: now, observedPercent: 50, unitsInWindow: 5_000)]
    let low = SnapshotBuilder.build(cache: cache(units: 10, at: window.start.addingTimeInterval(60)),
                                    settings: settings(anchors: anchors), now: now, isScanning: false)
    #expect(low.isUnderBudget == true)
}

@Test func scanningFlagIsCarriedThrough() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let snapshot = SnapshotBuilder.build(cache: ScanCache(), settings: settings(),
                                         now: now, isScanning: true)
    #expect(snapshot.isScanning)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter SnapshotBuilderTests`
Expected: FAIL — types not found.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/BurnlineCore/BurnlineSettings.swift
import Foundation

public struct BurnlineSettings: Equatable, Sendable, Codable {
    public var resetSchedule: ResetSchedule
    public var weights: Weights
    public var calibrationAnchors: [CalibrationAnchor]
    public var launchAtLogin: Bool

    public init(resetSchedule: ResetSchedule, weights: Weights,
                calibrationAnchors: [CalibrationAnchor], launchAtLogin: Bool) {
        self.resetSchedule = resetSchedule
        self.weights = weights
        self.calibrationAnchors = calibrationAnchors
        self.launchAtLogin = launchAtLogin
    }

    /// Thursday 09:00 local is a placeholder — the user sets this on first run.
    public static let `default` = BurnlineSettings(
        resetSchedule: ResetSchedule(weekday: 5, hour: 9),
        weights: .default,
        calibrationAnchors: [],
        launchAtLogin: false
    )
}
```

```swift
// Sources/BurnlineCore/Snapshot.swift
import Foundation

/// Everything the UI renders, computed in one pass. Views read this and do no
/// arithmetic of their own.
public struct Snapshot: Equatable, Sendable {
    public let window: Window
    /// Exact. Where the clock says you should be.
    public let targetPercent: Double
    /// `nil` until the user has supplied at least one calibration anchor.
    public let estimatedPercent: Double?
    public let projectedPercent: Double?
    public let unitsInWindow: Double
    public let calibrationAge: TimeInterval?
    public let isScanning: Bool

    /// Positive means under budget.
    public var deltaPercent: Double? {
        guard let estimate = estimatedPercent else { return nil }
        return targetPercent - estimate
    }

    public var isUnderBudget: Bool? {
        guard let delta = deltaPercent else { return nil }
        return delta >= 0
    }

    /// No calibration yet — show the pace target alone.
    public var isPaceOnly: Bool { estimatedPercent == nil }

    public var isCalibrationStale: Bool {
        guard let age = calibrationAge else { return false }
        return age > Calibration.stalenessThreshold
    }
}
```

```swift
// Sources/BurnlineCore/SnapshotBuilder.swift
import Foundation

/// Pure: cache + settings + now → one immutable `Snapshot`.
public enum SnapshotBuilder {
    public static func build(cache: ScanCache, settings: BurnlineSettings,
                             now: Date, isScanning: Bool) -> Snapshot {
        let window = WindowMath.window(for: settings.resetSchedule, now: now)
        let units = cache.units(from: window.start, to: window.end)

        let estimated = Calibration.estimatedPercent(
            unitsInWindow: units, anchors: settings.calibrationAnchors, now: now)
        let projected = Projection.projectedPercent(
            estimatedPercent: estimated, elapsedFraction: window.elapsedFraction)

        return Snapshot(
            window: window,
            targetPercent: window.targetPercent,
            estimatedPercent: estimated,
            projectedPercent: projected,
            unitsInWindow: units,
            calibrationAge: Calibration.age(of: settings.calibrationAnchors, now: now),
            isScanning: isScanning
        )
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter SnapshotBuilderTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/BurnlineCore/BurnlineSettings.swift Sources/BurnlineCore/Snapshot.swift Sources/BurnlineCore/SnapshotBuilder.swift Tests/BurnlineCoreTests/SnapshotBuilderTests.swift
git commit -m "feat: Snapshot and pure SnapshotBuilder"
```

---

## Task 6: The probe — prove the engine on real data

This is the verification gate for the whole plan. It runs the engine against the actual transcripts and prints what it finds, before a single line of UI exists.

**Files:**
- Modify: `Package.swift`
- Create: `Sources/BurnlineProbe/main.swift`

- [ ] **Step 1: Add the executable target**

Add to `Package.swift` `targets:`

```swift
        .executableTarget(
            name: "BurnlineProbe",
            dependencies: ["BurnlineCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
```

- [ ] **Step 2: Write the probe**

```swift
// Sources/BurnlineProbe/main.swift
import Foundation
import BurnlineCore

// Diagnostic only. Scans the real transcripts and prints a Snapshot.
let now = Date()
var settings = BurnlineSettings.default
if let weekday = ProcessInfo.processInfo.environment["BURNLINE_WEEKDAY"].flatMap(Int.init) {
    settings.resetSchedule.weekday = weekday
}
if let hour = ProcessInfo.processInfo.environment["BURNLINE_HOUR"].flatMap(Int.init) {
    settings.resetSchedule.hour = hour
}

let scanner = TranscriptScanner(weights: settings.weights)
let started = Date()
let cache = try scanner.scan(cache: ScanCache(), now: now)
let elapsed = Date().timeIntervalSince(started)

let snapshot = SnapshotBuilder.build(cache: cache, settings: settings,
                                     now: now, isScanning: false)

func percent(_ value: Double?) -> String {
    value.map { String(format: "%.1f%%", $0) } ?? "—"
}

print("""
Burnline probe
  scanned          \(cache.files.count) files in \(String(format: "%.2f", elapsed))s
  window           \(snapshot.window.start) → \(snapshot.window.end)
  duration         \(String(format: "%.0f", snapshot.window.totalDuration / 3600))h
  day              \(String(format: "%.2f", snapshot.window.dayIndex)) of 7
  target           \(percent(snapshot.targetPercent))
  units in window  \(String(format: "%.0f", snapshot.unitsInWindow))
  estimated        \(percent(snapshot.estimatedPercent))
  projected        \(percent(snapshot.projectedPercent))
  pace-only        \(snapshot.isPaceOnly)
""")
```

- [ ] **Step 3: Run it against real data**

Run: `swift run BurnlineProbe`

Expected: a report naming roughly 2,900 scanned files in a couple of seconds, a 168-hour window (or 167/169 near a DST change), a day index between 0 and 7, a target percent matching that day index, a large non-zero unit count, and `estimated —` with `pace-only true` because no anchors exist yet.

**Verify three things by hand before proceeding:**
1. `target` ≈ `day / 7 × 100`.
2. `units in window` is non-zero — if it is zero, the window or bucket keying is wrong.
3. A second immediate run is much faster than the first only if you persist the cache; without persistence both runs are cold. That is expected here — cache persistence lands in Plan 3.

- [ ] **Step 4: Run the whole suite**

Run: `swift test`
Expected: PASS, ~70 tests, zero warnings.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/BurnlineProbe
git commit -m "feat: BurnlineProbe CLI for verifying the engine against real transcripts"
```

---

## Done when

- `swift test` passes ~70 tests with no warnings.
- `swift run BurnlineProbe` prints a plausible report from the real `~/.claude/projects`.
- Appending to a transcript and re-scanning adds exactly the new usage, never re-counts old usage.
- Nothing in `BurnlineCore` imports SwiftUI.

Next: **Plan 3 — the app**, which puts a menu bar and a popover on top of this.
