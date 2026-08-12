# Per-Session Captures Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the live usage figure as fresh as the platform allows, and make its age true, by giving every Claude Code session its own capture file and dating each reading by when that session last called the API.

**Architecture:** The statusline helper stops writing one shared `rate-limits.json` and writes `captures/<session_id>.json` instead, so concurrent sessions never contend. The helper records only facts it can know for free — the payload, the session id, the transcript path, and its own wall clock. The **app** derives the true mint time by reading the tail of that session's transcript for the last assistant turn, then selects the capture with the newest mint time. `RateLimitHighWater` stays as a value backstop but stops being the primary defence.

**Tech Stack:** Swift 6, SwiftPM, Swift Testing. No new dependencies.

---

## Background — why this shape

Read these before starting; they are the constraints the design is pinned to.

- **`rate_limits` is a per-session cached snapshot.** It refreshes only when *that session* calls the API ([statusline docs](https://code.claude.com/docs/en/statusline): "appears only for Claude.ai subscribers (Pro/Max) **after the first API response in the session**"). An idle session republishes its original reading forever. **No plumbing beats this ceiling** — the freshest obtainable number is "the last API response in a session that renders a status line." What this plan fixes is that today you do not reliably get even that.
- **The statusline is the only carrier.** No API, no CLI, no hook, and — verified 2026-08-11 — **no OpenTelemetry metric or event** carries rate-limit data. Do not go looking again.
- **The shared file has many writers and no arbitration.** Last write wins, and "last" is not "freshest". `RateLimitHighWater` defends the *value* (usage is cumulative, so a lower reading is always staler) but cannot defend the *age*.
- **Verified facts this plan rests on** (checked against real data 2026-08-11, re-check if anything looks off):
  - Transcript assistant lines carry `timestamp` (ISO8601), `sessionId`, `type: "assistant"`, and `message.usage`. `TranscriptParser` already decodes exactly these.
  - The transcript **filename is the session id** (`<session_id>.jsonl`).
  - The statusline payload carries `session_id` and `transcript_path` (documented; **not yet observed at runtime** — see the degradation rule in Task 3).

### The rule that replaces guessing

An assistant message *is* an API response. So **the last assistant turn in a session's transcript at or before the moment we observed the capture is when that session's `rate_limits` was minted.** That is an exact instant, not an upper bound — strictly better than the shipped five-hour heuristic, and it works on plans that never report `five_hour`.

The five-hour rule stays as a fallback. It is cheap, already tested, and covers the case where the transcript is missing or unreadable.

---

## File structure

| File | Responsibility | Pure? |
|---|---|---|
| `Sources/BurnlineCore/SessionCapture.swift` | **Create.** One session's observation: payload readings + `sessionId` + `transcriptPath` + `observedAt`. Codable. | ✅ |
| `Sources/BurnlineCore/CaptureDirectory.swift` | **Create.** Read/write/prune `captures/<session_id>.json`. | file I/O |
| `Sources/BurnlineCore/TranscriptDating.swift` | **Create.** Transcript tail → last assistant timestamp ≤ a bound. | file I/O |
| `Sources/BurnlineCore/CaptureSelector.swift` | **Create.** `[SessionCapture]` + mint times + now → the one `RateLimitCapture` to trust. | ✅ |
| `Sources/BurnlineCore/StatuslinePayload.swift` | **Modify.** Decode `session_id` and `transcript_path`. | ✅ |
| `Sources/BurnlineStatusline/main.swift` | **Modify.** Write per-session; fall back to legacy when there is no session id. | — |
| `Sources/Burnline/UsageStore.swift` | **Modify.** Load the directory, date, select, then reconcile against high water. | — |
| `Sources/BurnlineProbe/main.swift` | **Modify.** Print every capture and why one won. | — |

**Do not** put transcript reading in the helper. The helper's contract is "never exits non-zero, never writes stderr, ~4ms" and it runs every 30s in every open session. It records facts; the app derives.

---

## Task 1: `SessionCapture` — the per-session record

**Files:**
- Create: `Sources/BurnlineCore/SessionCapture.swift`
- Test: `Tests/BurnlineCoreTests/SessionCaptureTests.swift`

> ⚠️ **Test names are module-scope in `Tests/`.** A name reused from another file is a hard compile error. `grep -rn "func <name>" Tests/` before naming.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import BurnlineCore

@Test func sessionCaptureRoundTripsThroughJSON() throws {
    let capture = SessionCapture(
        version: SessionCapture.currentVersion,
        sessionId: "abc-123",
        transcriptPath: "/tmp/abc-123.jsonl",
        observedAt: 1_000,
        sevenDay: .init(usedPercent: 69, resetsAt: 9_000),
        fiveHour: .init(usedPercent: 28, resetsAt: 4_000))

    let data = try JSONEncoder().encode(capture)
    #expect(try JSONDecoder().decode(SessionCapture.self, from: data) == capture)
}

/// `observedAt` is when we SAW the reading, never a claim about when it was
/// minted. The whole bug this replaces was conflating the two.
@Test func sessionCaptureWithoutATranscriptPathStillDecodes() throws {
    let json = #"{"version":1,"sessionId":"a","observedAt":5,"sevenDay":{"usedPercent":1,"resetsAt":2}}"#
    let capture = try JSONDecoder().decode(SessionCapture.self, from: Data(json.utf8))
    #expect(capture.transcriptPath == nil)
    #expect(capture.fiveHour == nil)
}

@Test func sessionCaptureRejectsAnIncompatibleVersion() {
    let capture = SessionCapture(version: 99, sessionId: "a", transcriptPath: nil,
                                 observedAt: 1, sevenDay: .init(usedPercent: 1, resetsAt: 2),
                                 fiveHour: nil)
    #expect(capture.isCompatible == false)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test 2>&1 | grep -E "error:|Test run with"`
Expected: `error: cannot find 'SessionCapture' in scope`

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// One session's observation of its own rate limits.
///
/// Each session writes its own file, so concurrent sessions never contend and
/// there is nothing to arbitrate. Reuses `RateLimitCapture.Reading` so the
/// readings stay one type across the codebase.
///
/// `observedAt` is when the helper SAW this payload — deliberately not called
/// `capturedAt`. It is not a claim about when the reading was minted; deriving
/// that is the app's job (see `TranscriptDating`). Conflating the two is the
/// bug this whole design replaces.
public struct SessionCapture: Equatable, Sendable, Codable {
    public static let currentVersion = 1

    public var version: Int
    public var sessionId: String
    /// Absent when the payload didn't carry one. Dating then falls back.
    public var transcriptPath: String?
    public var observedAt: TimeInterval
    public var sevenDay: RateLimitCapture.Reading
    public var fiveHour: RateLimitCapture.Reading?

    public init(version: Int, sessionId: String, transcriptPath: String?,
                observedAt: TimeInterval, sevenDay: RateLimitCapture.Reading,
                fiveHour: RateLimitCapture.Reading?) {
        self.version = version
        self.sessionId = sessionId
        self.transcriptPath = transcriptPath
        self.observedAt = observedAt
        self.sevenDay = sevenDay
        self.fiveHour = fiveHour
    }

    public var isCompatible: Bool { version == Self.currentVersion }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test 2>&1 | grep -E "✘|Test run with"`
Expected: `Test run with 256 tests ... passed` (253 + 3)

- [ ] **Step 5: Commit**

```bash
git add Sources/BurnlineCore/SessionCapture.swift Tests/BurnlineCoreTests/SessionCaptureTests.swift
git commit -m "feat: SessionCapture records one session's own reading"
```

---

## Task 2: `CaptureDirectory` — one file per session, with pruning

**Files:**
- Create: `Sources/BurnlineCore/CaptureDirectory.swift`
- Test: `Tests/BurnlineCoreTests/CaptureDirectoryTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import BurnlineCore

private func captureScratch() -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("burnline-captures-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func sample(_ session: String, observedAt: TimeInterval,
                    percent: Double = 50) -> SessionCapture {
    SessionCapture(version: SessionCapture.currentVersion, sessionId: session,
                   transcriptPath: nil, observedAt: observedAt,
                   sevenDay: .init(usedPercent: percent, resetsAt: 9_000), fiveHour: nil)
}

@Test func eachSessionGetsItsOwnFileSoWritersNeverContend() throws {
    let directory = CaptureDirectory(directory: captureScratch())
    try directory.save(sample("aaa", observedAt: 1))
    try directory.save(sample("bbb", observedAt: 2))

    #expect(Set(directory.load().map(\.sessionId)) == ["aaa", "bbb"])
}

@Test func rewritingASessionReplacesItRatherThanAccumulating() throws {
    let directory = CaptureDirectory(directory: captureScratch())
    try directory.save(sample("aaa", observedAt: 1, percent: 10))
    try directory.save(sample("aaa", observedAt: 2, percent: 20))

    let loaded = directory.load()
    #expect(loaded.count == 1)
    #expect(loaded.first?.sevenDay.usedPercent == 20)
}

/// A session id is used as a filename. Anything that could escape the
/// directory must be refused outright, not sanitised into something surprising.
@Test func aSessionIdThatCouldEscapeTheDirectoryIsRefused() {
    let scratch = captureScratch()
    let directory = CaptureDirectory(directory: scratch)
    #expect(throws: (any Error).self) {
        try directory.save(sample("../../escape", observedAt: 1))
    }
    #expect(directory.load().isEmpty)
}

@Test func corruptAndIncompatibleFilesAreSkippedNotFatal() throws {
    let scratch = captureScratch()
    let directory = CaptureDirectory(directory: scratch)
    try directory.save(sample("good", observedAt: 1))
    let dir = scratch.appendingPathComponent("captures", isDirectory: true)
    try Data("{ not json".utf8).write(to: dir.appendingPathComponent("bad.json"))
    try Data(#"{"version":99,"sessionId":"old","observedAt":1,"sevenDay":{"usedPercent":1,"resetsAt":2}}"#.utf8)
        .write(to: dir.appendingPathComponent("old.json"))

    #expect(directory.load().map(\.sessionId) == ["good"])
}

/// Sessions accumulate forever otherwise — they are created per session and
/// nothing ever deletes them.
@Test func capturesOlderThanTheCutoffArePruned() throws {
    let scratch = captureScratch()
    let directory = CaptureDirectory(directory: scratch)
    try directory.save(sample("stale", observedAt: 100))
    try directory.save(sample("current", observedAt: 5_000))

    directory.prune(before: 1_000)

    #expect(directory.load().map(\.sessionId) == ["current"])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test 2>&1 | grep -E "error:" | head -3`
Expected: `error: cannot find 'CaptureDirectory' in scope`

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

public enum CaptureDirectoryError: Error, Equatable {
    /// The session id would not survive being used as a filename.
    case unsafeSessionId(String)
}

/// `captures/<session_id>.json`, one file per Claude Code session.
///
/// **Why per-session rather than one shared file.** Every open session runs the
/// statusline on its own timer and writes blind; with a single file the last
/// writer wins and "last" has nothing to do with "freshest". Giving each session
/// its own file removes the contention entirely — there is no arbitration to get
/// wrong, only a selection to make at read time.
public struct CaptureDirectory: Sendable {
    private let root: URL

    public init(directory: URL = ApplicationSupport.directory()) {
        root = directory.appendingPathComponent("captures", isDirectory: true)
    }

    /// Session ids are UUIDs in practice. Anything else is refused rather than
    /// sanitised: a path separator here would write outside the directory, and a
    /// quietly-rewritten id would make the file impossible to correlate back.
    private static func isSafe(_ sessionId: String) -> Bool {
        !sessionId.isEmpty
            && sessionId.count <= 128
            && sessionId.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    public func save(_ capture: SessionCapture) throws {
        guard Self.isSafe(capture.sessionId) else {
            throw CaptureDirectoryError.unsafeSessionId(capture.sessionId)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("\(capture.sessionId).json")
        // Atomic for the same reason RateLimitStore is: the app re-reads on a
        // 10s timer and must never observe a partial write.
        try JSONEncoder().encode(capture).write(to: url, options: .atomic)
    }

    /// Every readable, compatible capture. A corrupt or version-mismatched file
    /// is skipped, never fatal — one bad file must not cost the others.
    public func load() -> [SessionCapture] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> SessionCapture? in
                guard let data = try? Data(contentsOf: url),
                      let capture = try? JSONDecoder().decode(SessionCapture.self, from: data),
                      capture.isCompatible
                else { return nil }
                return capture
            }
            .sorted { $0.sessionId < $1.sessionId }
    }

    /// Drops captures observed before `cutoff`. Callers pass the current
    /// window's start: a capture from a previous window describes a period that
    /// no longer exists and can never win selection again.
    public func prune(before cutoff: TimeInterval) {
        for capture in load() where capture.observedAt < cutoff {
            try? FileManager.default.removeItem(
                at: root.appendingPathComponent("\(capture.sessionId).json"))
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test 2>&1 | grep -E "✘|Test run with"`
Expected: 261 tests passed

- [ ] **Step 5: Commit**

```bash
git add Sources/BurnlineCore/CaptureDirectory.swift Tests/BurnlineCoreTests/CaptureDirectoryTests.swift
git commit -m "feat: per-session capture files remove the many-writers contention"
```

---

## Task 3: The helper writes per-session

**Files:**
- Modify: `Sources/BurnlineCore/StatuslinePayload.swift`
- Modify: `Sources/BurnlineStatusline/main.swift`
- Test: `Tests/BurnlineCoreTests/StatuslinePayloadTests.swift` (append)

> ⚠️ **`session_id` and `transcript_path` are documented but were never observed at runtime.** If they are absent the helper MUST fall back to the legacy `rate-limits.json` write, so a docs error costs freshness, never the capture itself.

> ⚠️ **Never run the helper without `BURNLINE_DATA_DIR`.** It writes live data. Confirm the export with `swift run BurnlineProbe`, whose first line says `(live data)` or `(BURNLINE_DATA_DIR override — not live data)`.

- [ ] **Step 1: Write the failing test**

```swift
@Test func decodesTheSessionIdAndTranscriptPath() throws {
    let p = try decode(#"{"session_id":"abc-123","transcript_path":"/tmp/abc-123.jsonl"}"#)
    #expect(p.sessionId == "abc-123")
    #expect(p.transcriptPath == "/tmp/abc-123.jsonl")
}

/// Decoded per-property like every other field: a wrong-typed session_id must
/// not cost us rate_limits.
@Test func aNumericSessionIdDoesNotCostTheRateLimits() throws {
    let p = try decode(#"{"session_id":123,"rate_limits":{"seven_day":{"used_percentage":64,"resets_at":1786000000}}}"#)
    #expect(p.sessionId == nil)
    #expect(p.rateLimits?.sevenDay?.usedPercentage == 64)
}

@Test func buildsASessionCaptureWhenTheSessionIdIsPresent() throws {
    let p = try decode(#"{"session_id":"abc","transcript_path":"/tmp/abc.jsonl","rate_limits":{"seven_day":{"used_percentage":64,"resets_at":1786000000}}}"#)
    let capture = try #require(p.sessionCapture(observedAt: 1_000))
    #expect(capture.sessionId == "abc")
    #expect(capture.observedAt == 1_000)
    #expect(capture.sevenDay.usedPercent == 64)
}

/// No session id means no per-session file is possible; the caller must fall
/// back to the legacy shared write rather than dropping the reading.
@Test func buildsNoSessionCaptureWithoutASessionId() throws {
    let p = try decode(#"{"rate_limits":{"seven_day":{"used_percentage":64,"resets_at":1786000000}}}"#)
    #expect(p.sessionCapture(observedAt: 1_000) == nil)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test 2>&1 | grep -E "error:" | head -3`
Expected: `error: value of type 'StatuslinePayload' has no member 'sessionId'`

- [ ] **Step 3: Write minimal implementation**

In `StatuslinePayload.swift`, add to the properties and `CodingKeys`:

```swift
    public var sessionId: String?
    public var transcriptPath: String?
```

```swift
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
```

In `init(from:)`, alongside the existing per-property decodes:

```swift
        sessionId = try? c.decodeIfPresent(String.self, forKey: .sessionId)
        transcriptPath = try? c.decodeIfPresent(String.self, forKey: .transcriptPath)
```

And a new builder beside `capture(capturedAt:)`:

```swift
    /// The per-session capture to persist, or `nil` when this payload cannot be
    /// attributed to a session.
    ///
    /// Reuses `capture(capturedAt:)` for the readings so the seven-day
    /// validation (a percentage without `resets_at` is rejected outright) lives
    /// in exactly one place.
    public func sessionCapture(observedAt: TimeInterval) -> SessionCapture? {
        guard let sessionId, !sessionId.isEmpty,
              let readings = capture(capturedAt: observedAt)
        else { return nil }

        return SessionCapture(
            version: SessionCapture.currentVersion,
            sessionId: sessionId,
            transcriptPath: transcriptPath,
            // Deliberately the raw observation. The five-hour correction inside
            // `capture(capturedAt:)` is a fallback for when the transcript can't
            // date this; the app applies it, and only if it has nothing better.
            observedAt: observedAt,
            sevenDay: readings.sevenDay,
            fiveHour: readings.fiveHour)
    }
```

Then in `Sources/BurnlineStatusline/main.swift`, replace the capture block:

```swift
let now = Date().timeIntervalSince1970
if let sessionCapture = payload.sessionCapture(observedAt: now) {
    // Best-effort. A failed write must not cost the user their status line.
    try? CaptureDirectory().save(sessionCapture)
} else if let capture = payload.capture(capturedAt: now) {
    // No session id — the payload can't be attributed, so fall back to the
    // shared file. Costs freshness, never the reading itself.
    try? RateLimitStore().save(capture)
}
```

- [ ] **Step 4: Run test to verify it passes, then exercise the real binary safely**

Run: `swift test 2>&1 | grep -E "✘|Test run with"`
Expected: 265 tests passed

```bash
SB=$(mktemp -d)
printf '%s' '{"session_id":"test-session","transcript_path":"/tmp/none.jsonl","rate_limits":{"seven_day":{"used_percentage":12.5,"resets_at":1786690800}}}' \
  | BURNLINE_DATA_DIR="$SB" swift run BurnlineStatusline
ls "$SB/captures/"          # expect: test-session.json
cat "$SB/captures/test-session.json"
grep -c "12.5" "$HOME/Library/Application Support/Burnline/rate-limits.json" || echo "live clean (expected)"
```

- [ ] **Step 5: Commit**

```bash
git add Sources/BurnlineCore/StatuslinePayload.swift Sources/BurnlineStatusline/main.swift Tests/BurnlineCoreTests/StatuslinePayloadTests.swift
git commit -m "feat: helper writes a per-session capture, falling back to the shared file"
```

---

## Task 4: `TranscriptDating` — when the reading was actually minted

**Files:**
- Create: `Sources/BurnlineCore/TranscriptDating.swift`
- Test: `Tests/BurnlineCoreTests/TranscriptDatingTests.swift`

An assistant message *is* an API response, so the last assistant turn at or before `observedAt` is when that session's `rate_limits` was minted.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import BurnlineCore

private func transcript(_ lines: [String]) -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("burnline-dating-\(UUID().uuidString).jsonl")
    try? Data(lines.joined(separator: "\n").appending("\n").utf8).write(to: url)
    return url
}

private func assistantLine(_ iso: String) -> String {
    #"{"type":"assistant","timestamp":"\#(iso)","message":{"model":"claude-opus-5","usage":{"input_tokens":1,"output_tokens":1}}}"#
}

@Test func datesACaptureByTheLastAssistantTurn() {
    let url = transcript([assistantLine("2026-08-11T18:00:00.000Z"),
                          assistantLine("2026-08-11T20:30:00.000Z")])
    let minted = TranscriptDating.mintedAt(transcriptPath: url.path,
                                           observedAt: 1_786_500_000)
    #expect(minted == ISO8601DateFormatter().date(from: "2026-08-11T20:30:00Z")?.timeIntervalSince1970)
}

/// A turn that happened AFTER we read the payload cannot have minted it.
@Test func ignoresAssistantTurnsAfterTheObservation() {
    let early = ISO8601DateFormatter().date(from: "2026-08-11T18:00:00Z")!
    let url = transcript([assistantLine("2026-08-11T18:00:00.000Z"),
                          assistantLine("2026-08-11T23:00:00.000Z")])
    let minted = TranscriptDating.mintedAt(transcriptPath: url.path,
                                           observedAt: early.timeIntervalSince1970 + 60)
    #expect(minted == early.timeIntervalSince1970)
}

@Test func aMissingTranscriptYieldsNoMintTime() {
    #expect(TranscriptDating.mintedAt(transcriptPath: "/nope/missing.jsonl",
                                      observedAt: 1_786_500_000) == nil)
}

@Test func aTranscriptWithNoAssistantTurnsYieldsNoMintTime() {
    let url = transcript([#"{"type":"user","timestamp":"2026-08-11T18:00:00.000Z"}"#])
    #expect(TranscriptDating.mintedAt(transcriptPath: url.path,
                                      observedAt: 1_786_500_000) == nil)
}

/// Transcripts run to megabytes. Only the tail is read, and a turn found in it
/// must still be correct.
@Test func readsOnlyTheTailAndStillFindsTheLastTurn() {
    var lines = (0..<5_000).map { _ in
        #"{"type":"user","timestamp":"2026-08-11T10:00:00.000Z","padding":"\#(String(repeating: "x", count: 200))"}"#
    }
    lines.append(assistantLine("2026-08-11T20:30:00.000Z"))
    let url = transcript(lines)

    #expect(TranscriptDating.mintedAt(transcriptPath: url.path, observedAt: 1_786_500_000)
            == ISO8601DateFormatter().date(from: "2026-08-11T20:30:00Z")?.timeIntervalSince1970)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test 2>&1 | grep -E "error:" | head -3`
Expected: `error: cannot find 'TranscriptDating' in scope`

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// When a session's `rate_limits` block was actually minted.
///
/// **The rule:** an assistant message *is* an API response, and `rate_limits`
/// refreshes only when that session calls the API. So the last assistant turn
/// at or before the moment the helper saw the payload is when the reading was
/// minted. That is an exact instant, not an upper bound — strictly better than
/// the five-hour heuristic, and it works on plans that never report `five_hour`.
public enum TranscriptDating {
    /// Transcripts run to megabytes and only the end is interesting. 256 KB
    /// covers thousands of lines; a session whose last assistant turn is further
    /// back than that has not called the API in a very long time, and returning
    /// `nil` there correctly falls back rather than guessing.
    static let tailBytes = 256 * 1024

    public static func mintedAt(transcriptPath: String,
                                observedAt: TimeInterval) -> TimeInterval? {
        guard let data = tail(of: URL(fileURLWithPath: transcriptPath)) else { return nil }

        // Reuse the shipped parser rather than a second JSON path: it already
        // filters to assistant lines with usage, handles both ISO8601 shapes,
        // and skips malformed lines silently.
        let records = TranscriptParser().parse(data)
        let candidates = records
            .map(\.timestamp.timeIntervalSince1970)
            .filter { $0 <= observedAt }
        return candidates.max()
    }

    /// The last `tailBytes`, trimmed forward to the first line boundary so the
    /// parser never sees a partial line.
    private static func tail(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }

        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty
        else { return nil }

        guard start > 0 else { return data }
        guard let firstNewline = data.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
        return Data(data[(firstNewline + 1)...])
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test 2>&1 | grep -E "✘|Test run with"`
Expected: 270 tests passed

- [ ] **Step 5: Commit**

```bash
git add Sources/BurnlineCore/TranscriptDating.swift Tests/BurnlineCoreTests/TranscriptDatingTests.swift
git commit -m "feat: date a capture by its session's last assistant turn"
```

---

## Task 5: `CaptureSelector` — pick the freshest, not the loudest

**Files:**
- Create: `Sources/BurnlineCore/CaptureSelector.swift`
- Test: `Tests/BurnlineCoreTests/CaptureSelectorTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import BurnlineCore

private let week: TimeInterval = 1_786_690_800

private func session(_ id: String, percent: Double, observedAt: TimeInterval,
                     fiveHourResetsAt: TimeInterval? = nil) -> SessionCapture {
    SessionCapture(version: SessionCapture.currentVersion, sessionId: id,
                   transcriptPath: nil, observedAt: observedAt,
                   sevenDay: .init(usedPercent: percent, resetsAt: week),
                   fiveHour: fiveHourResetsAt.map { .init(usedPercent: 5, resetsAt: $0) })
}

/// The whole point: an idle session writing at 21:13 loses to an active one
/// whose reading was minted more recently, regardless of who wrote last.
@Test func theFreshestMintedReadingWinsRegardlessOfWriteOrder() {
    // The idle session WROTE most recently (observedAt 9_999) but its reading
    // was minted long ago. Mint times must beat write order.
    let idle = session("idle", percent: 69, observedAt: 9_999)
    let active = session("active", percent: 74, observedAt: 9_000)

    let chosen = CaptureSelector.best(from: [idle, active],
                                      mintedAt: { $0.sessionId == "active" ? 8_000 : 1_000 })

    #expect(chosen?.sevenDay.usedPercent == 74)
    #expect(chosen?.capturedAt == 8_000)
}

/// Without a mint time the five-hour rule still applies, then the raw
/// observation. Never a claim of freshness we cannot support.
@Test func fallsBackToTheFiveHourRuleWhenNothingCanDateIt() {
    let replay = session("replay", percent: 69, observedAt: 9_000, fiveHourResetsAt: 4_000)
    let chosen = CaptureSelector.best(from: [replay], mintedAt: { _ in nil })
    #expect(chosen?.capturedAt == 4_000)
}

@Test func fallsBackToTheObservationWhenThereIsNoEvidenceAtAll() {
    let plain = session("plain", percent: 69, observedAt: 9_000)
    #expect(CaptureSelector.best(from: [plain], mintedAt: { _ in nil })?.capturedAt == 9_000)
}

/// A mint time can never be later than the moment we saw the payload.
@Test func aMintTimeAfterTheObservationIsClamped() {
    let one = session("one", percent: 69, observedAt: 5_000)
    #expect(CaptureSelector.best(from: [one], mintedAt: { _ in 9_999 })?.capturedAt == 5_000)
}

@Test func capturesFromAnotherWindowAreIgnored() {
    var old = session("old", percent: 90, observedAt: 9_000)
    old.sevenDay.resetsAt = week - 604_800
    let current = session("current", percent: 40, observedAt: 1_000)

    let chosen = CaptureSelector.best(from: [old, current], mintedAt: { _ in nil },
                                      currentWindowResetsAt: week)
    #expect(chosen?.sevenDay.usedPercent == 40)
}

@Test func noCapturesYieldsNothing() {
    #expect(CaptureSelector.best(from: [], mintedAt: { _ in nil }) == nil)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test 2>&1 | grep -E "error:" | head -3`
Expected: `error: cannot find 'CaptureSelector' in scope`

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Chooses which session's reading to trust.
///
/// Replaces "whoever wrote last" with "whoever's reading is genuinely newest".
/// `RateLimitHighWater` still runs afterwards as a value backstop — usage inside
/// a window is cumulative, so a lower reading is always staler — but it is no
/// longer the primary defence, and it can no longer be fooled by a replay that
/// merely arrived recently.
public enum CaptureSelector {

    /// - Parameters:
    ///   - captures: every session's latest observation.
    ///   - mintedAt: when that session last called the API, if it can be known.
    ///     Injected rather than read here so this stays pure and testable;
    ///     `TranscriptDating.mintedAt` is the production implementation.
    ///   - currentWindowResetsAt: when non-nil, captures describing a different
    ///     weekly window are discarded — their percentage is about a period that
    ///     no longer exists.
    public static func best(from captures: [SessionCapture],
                            mintedAt: (SessionCapture) -> TimeInterval?,
                            currentWindowResetsAt: TimeInterval? = nil) -> RateLimitCapture? {
        let eligible = captures.filter { capture in
            guard let currentWindowResetsAt else { return true }
            return capture.sevenDay.resetsAt == currentWindowResetsAt
        }

        let dated = eligible.map { capture -> RateLimitCapture in
            RateLimitCapture(
                version: RateLimitCapture.currentVersion,
                capturedAt: date(capture, mintedAt: mintedAt(capture)),
                sevenDay: capture.sevenDay,
                fiveHour: capture.fiveHour)
        }

        // Ties broken by the higher percentage: same instant, cumulative usage,
        // so the larger figure is the later one.
        return dated.max {
            ($0.capturedAt, $0.sevenDay.usedPercent) < ($1.capturedAt, $1.sevenDay.usedPercent)
        }
    }

    /// Best available evidence, in order: the session's own last API response,
    /// then the five-hour replay rule, then the raw observation.
    private static func date(_ capture: SessionCapture,
                             mintedAt: TimeInterval?) -> TimeInterval {
        if let mintedAt {
            // A reading cannot have been minted after we saw it.
            return min(mintedAt, capture.observedAt)
        }
        return RateLimitCapture(
            version: RateLimitCapture.currentVersion,
            capturedAt: capture.observedAt,
            sevenDay: capture.sevenDay,
            fiveHour: capture.fiveHour
        ).correctedForRepublishing().capturedAt
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test 2>&1 | grep -E "✘|Test run with"`
Expected: 276 tests passed

- [ ] **Step 5: Commit**

```bash
git add Sources/BurnlineCore/CaptureSelector.swift Tests/BurnlineCoreTests/CaptureSelectorTests.swift
git commit -m "feat: select the freshest-minted reading instead of the last written"
```

---

## Task 6: Wire it into the app, keeping the legacy file as a fallback

**Files:**
- Modify: `Sources/Burnline/UsageStore.swift:158-180` (the `rebuild()` method)
- Modify: `Sources/BurnlineProbe/main.swift`

> The legacy `rate-limits.json` must still be read. `~/.claude/burnline-statusline.sh` is the documented rollback and writes that format, and a payload with no `session_id` falls back to it (Task 3).

- [ ] **Step 1: Write the failing test**

Create `Tests/BurnlineCoreTests/CaptureResolutionTests.swift`:

```swift
import Testing
import Foundation
@testable import BurnlineCore

@Test func perSessionCapturesWinOverTheLegacySharedFile() {
    let legacy = RateLimitCapture(version: 1, capturedAt: 1_000,
                                  sevenDay: .init(usedPercent: 40, resetsAt: 9_000),
                                  fiveHour: nil)
    let session = SessionCapture(version: SessionCapture.currentVersion, sessionId: "a",
                                 transcriptPath: nil, observedAt: 5_000,
                                 sevenDay: .init(usedPercent: 70, resetsAt: 9_000),
                                 fiveHour: nil)

    let resolved = CaptureSelector.resolve(sessions: [session], legacy: legacy,
                                           mintedAt: { _ in nil })
    #expect(resolved?.sevenDay.usedPercent == 70)
}

/// A rolled-back install writes only the legacy file. It must still work.
@Test func theLegacyFileIsUsedWhenThereAreNoPerSessionCaptures() {
    let legacy = RateLimitCapture(version: 1, capturedAt: 1_000,
                                  sevenDay: .init(usedPercent: 40, resetsAt: 9_000),
                                  fiveHour: nil)
    let resolved = CaptureSelector.resolve(sessions: [], legacy: legacy, mintedAt: { _ in nil })
    #expect(resolved?.sevenDay.usedPercent == 40)
}

@Test func nothingAnywhereResolvesToNothing() {
    #expect(CaptureSelector.resolve(sessions: [], legacy: nil, mintedAt: { _ in nil }) == nil)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test 2>&1 | grep -E "error:" | head -3`
Expected: `error: type 'CaptureSelector' has no member 'resolve'`

- [ ] **Step 3: Write minimal implementation**

Add to `CaptureSelector`:

```swift
    /// The capture to trust across both storage formats.
    ///
    /// The legacy shared file competes on the same terms rather than being
    /// preferred or ignored — it is still written by the rollback script and by
    /// any payload that carries no `session_id`.
    public static func resolve(sessions: [SessionCapture],
                               legacy: RateLimitCapture?,
                               mintedAt: (SessionCapture) -> TimeInterval?,
                               currentWindowResetsAt: TimeInterval? = nil) -> RateLimitCapture? {
        let fromSessions = best(from: sessions, mintedAt: mintedAt,
                                currentWindowResetsAt: currentWindowResetsAt)
        guard let legacy = legacy?.correctedForRepublishing() else { return fromSessions }
        guard let fromSessions else { return legacy }
        return fromSessions.capturedAt >= legacy.capturedAt ? fromSessions : legacy
    }
```

Then in `UsageStore.rebuild()`, replace the `rateLimitStore.load()` line:

```swift
        let sessions = captureDirectory.load()
        var capture = CaptureSelector.resolve(
            sessions: sessions,
            legacy: rateLimitStore.load(),
            mintedAt: { session in
                session.transcriptPath.flatMap {
                    TranscriptDating.mintedAt(transcriptPath: $0, observedAt: session.observedAt)
                }
            })
```

Add the stored property beside the others:

```swift
    @ObservationIgnored private let captureDirectory = CaptureDirectory()
```

Prune from the **60s scan path**, not the 10s rebuild — it does directory I/O and a delete. Put it at the end of `refresh()`, after `rebuild()` has published a snapshot, so the window it prunes against is the current one:

```swift
        // `snapshot` is only correct here because rebuild() has already run.
        // Calling this from rebuild() itself would prune against the PREVIOUS
        // window for one tick after a reset — and delete the capture that
        // proves the new window started.
        captureDirectory.prune(before: snapshot.window.start.timeIntervalSince1970)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test 2>&1 | grep -E "✘|Test run with"`
Expected: 279 tests passed

- [ ] **Step 5: Add the probe reporting and verify against real data**

In `BurnlineProbe/main.swift`, after the `data dir` line, print every capture:

```swift
let sessions = CaptureDirectory().load()
let captureLines = sessions.isEmpty
    ? "  sessions         none — no per-session captures on disk"
    : sessions.map { s in
        let minted = s.transcriptPath.flatMap {
            TranscriptDating.mintedAt(transcriptPath: $0, observedAt: s.observedAt)
        }
        let age = minted.map { "minted \(DisplayValue.seconds(now.timeIntervalSince1970 - $0))s ago" }
            ?? "undatable"
        return "  session \(s.sessionId.prefix(8))  \(s.sevenDay.usedPercent)%  \(age)"
    }.joined(separator: "\n")
print(captureLines)
```

Run: `swift run BurnlineProbe` — read-only against live data, safe.
Expected: the `sessions` line lists any per-session captures, or says none.

- [ ] **Step 6: Commit**

```bash
git add Sources/BurnlineCore/CaptureSelector.swift Sources/Burnline/UsageStore.swift Sources/BurnlineProbe/main.swift Tests/BurnlineCoreTests/CaptureResolutionTests.swift
git commit -m "feat: app resolves the freshest capture across per-session and legacy files"
```

---

## Task 7: End-to-end verification against the real app

**No new code.** This is the gate — three defects in this project were invisible in code review and obvious when run.

- [ ] **Step 1: Exercise the full path in a sandbox**

```bash
SB=$(mktemp -d)
# Two sessions: an idle one that "wrote last" with a low reading, and an
# active one with a higher, more recently minted reading.
printf '%s' '{"session_id":"idle-session","rate_limits":{"seven_day":{"used_percentage":40,"resets_at":1786690800}}}' \
  | BURNLINE_DATA_DIR="$SB" swift run BurnlineStatusline
printf '%s' '{"session_id":"active-session","rate_limits":{"seven_day":{"used_percentage":74,"resets_at":1786690800}}}' \
  | BURNLINE_DATA_DIR="$SB" swift run BurnlineStatusline
ls "$SB/captures/"
BURNLINE_DATA_DIR="$SB" swift run BurnlineProbe | head -12
```

Expected: two files; the probe reports both sessions and resolves to **74%**.

- [ ] **Step 2: Confirm live data was never touched**

```bash
grep -c "74\|40" "$HOME/Library/Application Support/Burnline/rate-limits.json" || echo "live clean"
ls "$HOME/Library/Application Support/Burnline/captures/" 2>/dev/null || echo "no live captures dir written"
```

- [ ] **Step 3: Screenshot the popover with the new path**

```bash
BURNLINE_DATA_DIR="$SB" BURNLINE_OPEN_POPOVER=1 swift run Burnline &
sleep 4
# Window IDs: CGWindowListCopyWindowInfo filtered by kCGWindowOwnerName.
# `screencapture -x -o -l <id>` captures it even behind another app.
```

Confirm the source footer reads a sane age and the stale-session row behaves.

- [ ] **Step 4: Install and watch a real capture land**

```bash
./build.sh --install && open -a Burnline
```

Then **open a terminal `claude` session and do one turn.** Expect `captures/<session_id>.json` to appear in the live data dir within 30s, and the probe to date it to that turn.

> This is also the decisive test for the still-open question of **which session types run the statusline at all**. If the terminal session produces a capture while headless desktop sessions do not, that answers it. Record the result in `BACKLOG.md`.

- [ ] **Step 5: Commit any fixes, then sweep the notes**

Update in Obsidian `Project Notes/Burnline/`: `CHANGELOG.md`, `ARCHITECTURE.md` (the "many writers" section is substantially rewritten by this — it is no longer a hazard being defended against), and `BACKLOG.md`.

---

## Risks and how they are handled

| Risk | Handling |
|---|---|
| `session_id` / `transcript_path` absent at runtime (documented, never observed) | Helper falls back to the legacy shared write. Costs freshness, never the reading. Task 3 Step 4 observes it directly. |
| Capture files accumulate forever | `prune(before:)` on the window start, called once per scan, not per rebuild. |
| Session id used as a filename | Refused outright if not `[A-Za-z0-9-_]{1,128}`; never sanitised. Tested. |
| Transcript reads slow the 10s rebuild | Tail-read of 256 KB per session, only for sessions with a capture in the current window. If this ever shows up, cache by `(path, size)` — **measure before optimising.** |
| A rolled-back install writes only the legacy file | Legacy is still read and competes on equal terms. Tested. |
| Existing `rate-limit-highwater.json` holds a pre-fix timestamp | Known, separate backlog item (no schema version). Not addressed here. |

## Explicitly out of scope

- Plans 5, 6, 7 (onboarding, notarization/DMG/Homebrew, Sparkle) — paused at a clean boundary, do not start.
- Versioning `rate-limit-highwater.json` — filed separately.
- Threshold notifications.
