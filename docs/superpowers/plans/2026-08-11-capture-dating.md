# Capture Dating and the Scarcity Nudge — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a live capture's age exact rather than an upper bound, and make it obvious in the popover when nothing is reporting — the two things that would have made "stuck at 69%" self-explanatory.

**Architecture:** The helper records `session_id` and `transcript_path` alongside the reading. The app reads the tail of that session's transcript to find the last assistant turn, which *is* the moment the API last responded and therefore the moment `rate_limits` was minted. That exact instant replaces the five-hour heuristic, which stays as a fallback. The popover then explains a stale figure instead of leaving the user to infer it.

**Tech Stack:** Swift 6, SwiftPM, Swift Testing. No new dependencies, no new file format.

---

## Why this is three tasks and not seven

The first draft of this plan built per-session capture files (`captures/<session_id>.json`) to remove writer contention. **That premise was wrong** and was retired on 2026-08-11 when the mechanism question was finally answered:

- **Only sessions that render a status line publish captures.** The desktop app's headless sessions (`--output-format stream-json`) never invoke the command at all — proven by the helper's atime sitting still for 40 minutes with desktop sessions running, then moving within seconds of one terminal turn (69% → **74%**, the exact figure `/usage` had been showing).
- So there is no crowd of contending writers. The real gap is **scarcity of captures, not arbitration among them**, and per-session files do nothing for scarcity.
- With one shared file plus a session id, the multi-terminal case is already handled: `RateLimitHighWater` keeps the correct value (usage is cumulative, so a fresher reading is always ≥ a staler one), and transcript dating reports an honest, slightly pessimistic age. Per-session files would only buy back that pessimism.

**Dropped:** `SessionCapture`, `CaptureDirectory` + pruning, `CaptureSelector` + merge logic, the migration and the directory I/O on a timer. Revisit only if contention is ever actually observed.

## Constraints this is pinned to

- **`rate_limits` is a per-session cached snapshot**, refreshed only when *that session* calls the API ([docs](https://code.claude.com/docs/en/statusline): "after the first API response in the session"). The freshest obtainable number is "the last API response in a session that renders a status line." No code beats that ceiling.
- **The statusline is the only carrier.** No API, no CLI, no hook, and — verified — no OpenTelemetry metric or event. Do not look again.
- **The helper must never exit non-zero or write to stderr**, and runs every 30s in every open session. It records facts; the app derives. **No transcript reading in the helper.**
- **Verified against real data** (re-check if anything looks off): transcript assistant lines carry `timestamp` (ISO8601), `sessionId`, `type: "assistant"` and `message.usage` — exactly what `TranscriptParser` already decodes. The payload carries `session_id` and `transcript_path` (documented; **not yet observed at runtime** — see the degradation rule in Task 1).

## File structure

| File | Responsibility | Pure? |
|---|---|---|
| `Sources/BurnlineCore/RateLimitCapture.swift` | **Modify.** Two optional fields + `dated(mintedAt:)`. | ✅ |
| `Sources/BurnlineCore/StatuslinePayload.swift` | **Modify.** Decode `session_id`, `transcript_path`. | ✅ |
| `Sources/BurnlineCore/TranscriptDating.swift` | **Create.** Transcript tail → last assistant turn ≤ a bound. | file I/O |
| `Sources/BurnlineCore/CaptureAge.swift` | **Modify.** The staleness explanation copy. | ✅ |
| `Sources/Burnline/UsageStore.swift` | **Modify.** Apply dating on rebuild. | — |
| `Sources/Burnline/PopoverView.swift` | **Modify.** Render the explanation. | — |
| `Sources/BurnlineProbe/main.swift` | **Modify.** Report the mint time and its source. | — |

---

## Task 1: The capture carries its session

**Files:**
- Modify: `Sources/BurnlineCore/RateLimitCapture.swift`
- Modify: `Sources/BurnlineCore/StatuslinePayload.swift`
- Test: `Tests/BurnlineCoreTests/StatuslinePayloadTests.swift` (append), `Tests/BurnlineCoreTests/RateLimitTests.swift` (append)

> ⚠️ **Test names are module-scope in `Tests/`.** A reused name is a hard compile error. `grep -rn "func <name>" Tests/` before naming.

> ⚠️ **No version bump.** Both fields are optional, so a `version: 1` file written before this change decodes with `nil` and keeps working. Bumping would discard the live capture on disk for no reason.

- [ ] **Step 1: Write the failing tests**

```swift
// StatuslinePayloadTests.swift
@Test func decodesTheSessionIdAndTranscriptPath() throws {
    let p = try decode(#"{"session_id":"abc-123","transcript_path":"/tmp/abc-123.jsonl"}"#)
    #expect(p.sessionId == "abc-123")
    #expect(p.transcriptPath == "/tmp/abc-123.jsonl")
}

/// Per-property decoding, like every other field: a wrong-typed session_id must
/// not cost us rate_limits.
@Test func aNumericSessionIdDoesNotCostTheRateLimits() throws {
    let p = try decode(#"{"session_id":123,"rate_limits":{"seven_day":{"used_percentage":64,"resets_at":1786000000}}}"#)
    #expect(p.sessionId == nil)
    #expect(p.rateLimits?.sevenDay?.usedPercentage == 64)
}

@Test func theCaptureCarriesTheSessionThatProducedIt() throws {
    let p = try decode(#"{"session_id":"abc","transcript_path":"/tmp/abc.jsonl","rate_limits":{"seven_day":{"used_percentage":64,"resets_at":1786000000}}}"#)
    let capture = try #require(p.capture(capturedAt: 1_785_900_000))
    #expect(capture.sessionId == "abc")
    #expect(capture.transcriptPath == "/tmp/abc.jsonl")
}

/// The documented fields have never been observed at runtime. Their absence
/// must cost the mint time and nothing else.
@Test func aPayloadWithoutSessionFieldsStillProducesACapture() throws {
    let p = try decode(#"{"rate_limits":{"seven_day":{"used_percentage":64,"resets_at":1786000000}}}"#)
    let capture = try #require(p.capture(capturedAt: 1_785_900_000))
    #expect(capture.sessionId == nil)
    #expect(capture.transcriptPath == nil)
}
```

```swift
// RateLimitTests.swift
/// A capture written before this change has neither field and must still load.
@Test func aCaptureFileWithoutSessionFieldsStillDecodes() throws {
    let json = #"{"version":1,"capturedAt":5,"sevenDay":{"usedPercent":1,"resetsAt":9}}"#
    let capture = try JSONDecoder().decode(RateLimitCapture.self, from: Data(json.utf8))
    #expect(capture.isCompatible)
    #expect(capture.sessionId == nil)
}

@Test func anExactMintTimeReplacesTheObservationTime() {
    let capture = RateLimitCapture(version: 1, capturedAt: 9_000,
                                   sevenDay: .init(usedPercent: 69, resetsAt: 90_000),
                                   fiveHour: nil)
    #expect(capture.dated(mintedAt: 6_000).capturedAt == 6_000)
}

/// A reading cannot have been minted after we saw it.
@Test func aMintTimeAfterTheObservationIsIgnored() {
    let capture = RateLimitCapture(version: 1, capturedAt: 9_000,
                                   sevenDay: .init(usedPercent: 69, resetsAt: 90_000),
                                   fiveHour: nil)
    #expect(capture.dated(mintedAt: 99_999).capturedAt == 9_000)
}

/// No transcript evidence — the five-hour rule still applies.
@Test func datingWithoutAMintTimeFallsBackToTheFiveHourRule() {
    let capture = RateLimitCapture(version: 1, capturedAt: 9_000,
                                   sevenDay: .init(usedPercent: 69, resetsAt: 90_000),
                                   fiveHour: .init(usedPercent: 5, resetsAt: 4_000))
    #expect(capture.dated(mintedAt: nil).capturedAt == 4_000)
}

/// Both kinds of evidence present and disagreeing: take the earlier. They
/// cannot both be true, and overstating freshness is the failure that matters.
@Test func theEarlierOfTheTwoDatingRulesWins() {
    let capture = RateLimitCapture(version: 1, capturedAt: 9_000,
                                   sevenDay: .init(usedPercent: 69, resetsAt: 90_000),
                                   fiveHour: .init(usedPercent: 5, resetsAt: 4_000))
    #expect(capture.dated(mintedAt: 7_000).capturedAt == 4_000)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test 2>&1 | grep -E "error:" | head -3`
Expected: `error: value of type 'StatuslinePayload' has no member 'sessionId'`

- [ ] **Step 3: Write minimal implementation**

In `RateLimitCapture`, add two stored properties (both optional, defaulted in `init` so existing call sites compile):

```swift
    /// Which Claude Code session produced this reading, when the payload said.
    /// `rate_limits` is that session's cached snapshot, so the session is what
    /// makes an exact mint time derivable at all.
    public var sessionId: String?
    /// That session's transcript. The app reads its tail to find the last
    /// assistant turn; the helper never touches it.
    public var transcriptPath: String?
```

```swift
    public init(version: Int, capturedAt: TimeInterval, sevenDay: Reading,
                fiveHour: Reading?, sessionId: String? = nil,
                transcriptPath: String? = nil) {
        ...
        self.sessionId = sessionId
        self.transcriptPath = transcriptPath
    }
```

And the dating function:

```swift
    /// `capturedAt` narrowed by every piece of evidence available.
    ///
    /// `mintedAt` is the exact instant this session last called the API, which
    /// is when `rate_limits` was refreshed — precise, where
    /// `correctedForRepublishing` only ever supplies an upper bound. Both are
    /// applied and the **earlier** wins: they cannot both be true, and
    /// overstating freshness is the failure that matters.
    public func dated(mintedAt: TimeInterval?) -> RateLimitCapture {
        var result = correctedForRepublishing()
        if let mintedAt {
            result.capturedAt = min(result.capturedAt, mintedAt)
        }
        return result
    }
```

In `StatuslinePayload`, add the properties, the `CodingKeys` cases, the two per-property decodes, and thread them into `capture(capturedAt:)`:

```swift
    public var sessionId: String?
    public var transcriptPath: String?
```
```swift
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
```
```swift
        sessionId = try? c.decodeIfPresent(String.self, forKey: .sessionId)
        transcriptPath = try? c.decodeIfPresent(String.self, forKey: .transcriptPath)
```
```swift
        return RateLimitCapture(
            version: RateLimitCapture.currentVersion,
            capturedAt: capturedAt,
            sevenDay: .init(usedPercent: usedPercent, resetsAt: resetsAt),
            fiveHour: fiveHourReading,
            sessionId: sessionId,
            transcriptPath: transcriptPath
        ).correctedForRepublishing()
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test 2>&1 | grep -E "✘|Test run with"`
Expected: 261 tests passed (253 + 8)

- [ ] **Step 5: Observe the real payload fields, safely**

⚠️ **Never run the helper without `BURNLINE_DATA_DIR`** — it writes live data.

```bash
SB=$(mktemp -d)
printf '%s' '{"session_id":"probe-test","transcript_path":"/tmp/none.jsonl","rate_limits":{"seven_day":{"used_percentage":12.5,"resets_at":1786690800}}}' \
  | BURNLINE_DATA_DIR="$SB" swift run BurnlineStatusline
cat "$SB/rate-limits.json"   # expect sessionId and transcriptPath present
```

- [ ] **Step 6: Commit**

```bash
git add Sources/BurnlineCore/RateLimitCapture.swift Sources/BurnlineCore/StatuslinePayload.swift Tests/BurnlineCoreTests/
git commit -m "feat: a capture records the session that produced it"
```

---

## Task 2: `TranscriptDating` — the exact mint time

**Files:**
- Create: `Sources/BurnlineCore/TranscriptDating.swift`
- Test: `Tests/BurnlineCoreTests/TranscriptDatingTests.swift`
- Modify: `Sources/Burnline/UsageStore.swift` (the `rebuild()` method)
- Modify: `Sources/BurnlineProbe/main.swift`

An assistant message *is* an API response, so the last assistant turn at or before the observation is when that session's `rate_limits` was minted.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import BurnlineCore

private func datingTranscript(_ lines: [String]) -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("burnline-dating-\(UUID().uuidString).jsonl")
    try? Data(lines.joined(separator: "\n").appending("\n").utf8).write(to: url)
    return url
}

private func assistantTurn(_ iso: String) -> String {
    #"{"type":"assistant","timestamp":"\#(iso)","message":{"model":"claude-opus-5","usage":{"input_tokens":1,"output_tokens":1}}}"#
}

private func epoch(_ iso: String) -> TimeInterval {
    ISO8601DateFormatter().date(from: iso)!.timeIntervalSince1970
}

@Test func datesACaptureByTheLastAssistantTurn() {
    let url = datingTranscript([assistantTurn("2026-08-11T18:00:00.000Z"),
                                assistantTurn("2026-08-11T20:30:00.000Z")])
    #expect(TranscriptDating.mintedAt(transcriptPath: url.path,
                                      observedAt: epoch("2026-08-11T21:00:00Z"))
            == epoch("2026-08-11T20:30:00Z"))
}

/// A turn that happened after we read the payload cannot have minted it.
@Test func ignoresAssistantTurnsAfterTheObservation() {
    let url = datingTranscript([assistantTurn("2026-08-11T18:00:00.000Z"),
                                assistantTurn("2026-08-11T23:00:00.000Z")])
    #expect(TranscriptDating.mintedAt(transcriptPath: url.path,
                                      observedAt: epoch("2026-08-11T19:00:00Z"))
            == epoch("2026-08-11T18:00:00Z"))
}

@Test func aMissingTranscriptYieldsNoMintTime() {
    #expect(TranscriptDating.mintedAt(transcriptPath: "/nope/missing.jsonl",
                                      observedAt: 1_786_500_000) == nil)
}

@Test func aTranscriptWithNoAssistantTurnsYieldsNoMintTime() {
    let url = datingTranscript([#"{"type":"user","timestamp":"2026-08-11T18:00:00.000Z"}"#])
    #expect(TranscriptDating.mintedAt(transcriptPath: url.path,
                                      observedAt: 1_786_500_000) == nil)
}

/// Transcripts run to megabytes; only the tail is read, and the answer must
/// still be right. Also pins that a partial first line never reaches the parser.
@Test func readsOnlyTheTailAndStillFindsTheLastTurn() {
    var lines = (0..<5_000).map { _ in
        #"{"type":"user","timestamp":"2026-08-11T10:00:00.000Z","pad":"\#(String(repeating: "x", count: 200))"}"#
    }
    lines.append(assistantTurn("2026-08-11T20:30:00.000Z"))
    let url = datingTranscript(lines)

    #expect(TranscriptDating.mintedAt(transcriptPath: url.path,
                                      observedAt: epoch("2026-08-11T21:00:00Z"))
            == epoch("2026-08-11T20:30:00Z"))
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
/// refreshes only when that session calls the API. So the last assistant turn at
/// or before the moment the helper saw the payload is when the reading was
/// minted — an exact instant, where the five-hour rule only ever gives an upper
/// bound. It also works on plans that never report `five_hour`, and on a replay
/// younger than five hours, which the five-hour rule cannot see at all.
public enum TranscriptDating {
    /// Transcripts run to megabytes and only the end is interesting. 256 KB is
    /// thousands of lines; a session whose last assistant turn is further back
    /// than that has not called the API in a very long time, and returning `nil`
    /// there correctly falls back rather than guessing.
    static let tailBytes = 256 * 1024

    public static func mintedAt(transcriptPath: String,
                                observedAt: TimeInterval) -> TimeInterval? {
        guard let data = tail(of: URL(fileURLWithPath: transcriptPath)) else { return nil }

        // Reuse the shipped parser rather than adding a second JSON path: it
        // already filters to assistant lines with usage, handles both ISO8601
        // shapes, and skips malformed lines silently.
        return TranscriptParser().parse(data)
            .map(\.timestamp.timeIntervalSince1970)
            .filter { $0 <= observedAt }
            .max()
    }

    /// The last `tailBytes`, advanced to the first line boundary so the parser
    /// never sees a partial line.
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
Expected: 266 tests passed

- [ ] **Step 5: Wire it into the app**

In `UsageStore.rebuild()`, replace `var capture = rateLimitStore.load()` with:

```swift
        // Dating is the app's job, not the helper's: it is file I/O, and the
        // helper runs every 30s in every open session under a contract that it
        // never fails and never slows the user's prompt.
        var capture = rateLimitStore.load().map { loaded in
            loaded.dated(mintedAt: loaded.transcriptPath.flatMap {
                TranscriptDating.mintedAt(transcriptPath: $0, observedAt: loaded.capturedAt)
            })
        }
```

In `BurnlineProbe/main.swift`, extend `captureNote` to say where the date came from:

```swift
    let dating = capture.sessionId.map { session in
        capture.transcriptPath.flatMap {
            TranscriptDating.mintedAt(transcriptPath: $0, observedAt: capture.capturedAt)
        } != nil ? "dated by transcript (session \(session.prefix(8)))"
                 : "undatable by transcript (session \(session.prefix(8)))"
    } ?? "no session id in payload"
```

…and append `dating` to the printed capture line.

- [ ] **Step 6: Verify against live data (read-only) and commit**

Run: `swift run BurnlineProbe | head -6`
Expected: the capture line names the session and says it was dated by transcript.

```bash
git add Sources/BurnlineCore/TranscriptDating.swift Sources/Burnline/UsageStore.swift Sources/BurnlineProbe/main.swift Tests/BurnlineCoreTests/TranscriptDatingTests.swift
git commit -m "feat: date a capture by its session's last API response"
```

---

## Task 3: The scarcity nudge

**Files:**
- Modify: `Sources/BurnlineCore/CaptureAge.swift`
- Modify: `Sources/Burnline/PopoverView.swift`
- Test: `Tests/BurnlineCoreTests/CaptureAgeTests.swift` (append)

The figure freezes whenever no session with a status line has taken a turn. That is the whole of "stuck at 69%", and today the popover leaves the user to infer it from an age string.

- [ ] **Step 1: Write the failing test**

```swift
/// Exceptions-only: nothing to explain while captures are landing.
@Test func aFreshCaptureNeedsNoExplanation() {
    #expect(CaptureAge.scarcityExplanation(60) == nil)
    #expect(CaptureAge.scarcityExplanation(nil) == nil)
}

/// The copy has to name the cause, not just the symptom — "3h ago" alone is
/// what made this look like a broken app rather than an idle one.
@Test func aStaleCaptureExplainsWhyAndWhatToDo() throws {
    let text = try #require(CaptureAge.scarcityExplanation(3 * 3_600))
    #expect(text.contains("3h"))
    #expect(text.lowercased().contains("terminal"))
}

@Test func theScarcityThresholdMatchesTheStalenessThreshold() {
    #expect(CaptureAge.scarcityExplanation(CaptureAge.stalenessThreshold) == nil)
    #expect(CaptureAge.scarcityExplanation(CaptureAge.stalenessThreshold + 1) != nil)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test 2>&1 | grep -E "error:" | head -3`
Expected: `error: type 'CaptureAge' has no member 'scarcityExplanation'`

- [ ] **Step 3: Write minimal implementation**

```swift
    /// Why the figure has stopped moving, when it has.
    ///
    /// Only sessions that render a status line publish usage — verified
    /// 2026-08-11: with desktop sessions running, the statusline command was not
    /// invoked for 40 minutes, and one terminal turn produced a capture within
    /// seconds. Quota burned in the desktop app is real but invisible until a
    /// reporting session takes a turn, so a frozen figure is the expected state
    /// rather than a fault — and saying so is the difference between "my app is
    /// broken" and "nothing is reporting right now".
    public static func scarcityExplanation(_ age: TimeInterval?) -> String? {
        guard isStale(age), let age else { return nil }
        return "Carried forward for \(description(age).replacingOccurrences(of: " ago", with: "")). "
            + "Desktop sessions don't report usage — a turn in a terminal session refreshes it."
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test 2>&1 | grep -E "✘|Test run with"`
Expected: 269 tests passed

- [ ] **Step 5: Render it, below the hero where the pace-only explanation sits**

In `PopoverView`, after the `hero` block:

```swift
            if let explanation = CaptureAge.scarcityExplanation(snapshot.liveAge) {
                Text(explanation)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
```

- [ ] **Step 6: SCREENSHOT it, both ways**

Three defects in this project were invisible in code review and obvious in a picture. Build two sandboxes with `BURNLINE_DATA_DIR` — one capture 3h old, one 60s old — and render each with `BURNLINE_OPEN_POPOVER=1`.

Capture the window even when it sits behind another app:

```bash
# window id from CGWindowListCopyWindowInfo filtered by kCGWindowOwnerName
screencapture -x -o -l <windowID> out.png
```

Check: the text wraps without clipping at 300pt, amber reads clearly on `#0a0a0f`, and it is **absent entirely** on the fresh capture.

- [ ] **Step 7: Commit**

```bash
git add Sources/BurnlineCore/CaptureAge.swift Sources/Burnline/PopoverView.swift Tests/BurnlineCoreTests/CaptureAgeTests.swift
git commit -m "feat: the popover says why the figure stopped moving"
```

---

## Task 4: Install and confirm on real data

- [ ] **Step 1:** `./build.sh --install && open -a Burnline`
- [ ] **Step 2:** Take one turn in a terminal `claude` session. Confirm `rate-limits.json` gains `sessionId`/`transcriptPath` and the probe reports "dated by transcript".
- [ ] **Step 3:** Confirm the popover shows no scarcity nudge while fresh.
- [ ] **Step 4:** Sweep Obsidian `CHANGELOG.md`, `ARCHITECTURE.md`, `BACKLOG.md`.

## Risks

| Risk | Handling |
|---|---|
| `session_id`/`transcript_path` absent at runtime (documented, never observed) | Both optional throughout; absence costs the mint time only. Task 1 Step 5 observes it directly. |
| Transcript tail read on every 10s rebuild | One 256 KB read, only when a capture carries a path. If it ever shows up, cache by `(path, size)` — **measure first.** |
| Capture files predating this change | Optional fields, no version bump; they decode and simply aren't datable. Tested. |
| Copy claims something untrue about desktop sessions | Grounded in the 2026-08-11 measurement, recorded in `ARCHITECTURE.md`. Re-check if Claude Code changes. |

## Out of scope

- Per-session capture files (dropped — see rationale above).
- Plans 5–7 (onboarding, notarization/DMG/Homebrew, Sparkle) — paused, do not start.
- Versioning `rate-limit-highwater.json` — separate backlog item.
