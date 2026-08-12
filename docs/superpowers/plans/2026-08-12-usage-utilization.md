# Usage Utilization Source Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Read subscription usage from `~/.claude.json` → `cachedUsageUtilization` as a second source alongside the statusline, gaining an explicit fetch timestamp, Anthropic's own severity grading, and the per-model weekly limit that was previously believed unobtainable.

**Architecture:** The utilization block converts into the existing `RateLimitCapture` shape, so it flows through `CaptureSelector.freshest` and `RateLimitHighWater` untouched — the two sources compete on age and the fresher wins. Nothing about the statusline path changes. The per-model limit is additive to `Snapshot`. An optional `/usage` poll to refresh the cache is the last task and can be dropped.

**Tech Stack:** Swift 6, SwiftPM, Swift Testing. No new dependencies, no network, no credentials.

---

## What was found, and why it is a peer rather than a replacement

`~/.claude.json` carries a `cachedUsageUtilization` block (discovered 2026-08-12):

```
fetchedAtMs   1786542556418          <- EXPLICIT fetch timestamp
accountUuid   7d48fca5-…
utilization:
  five_hour   { utilization: 3,  resets_at: "2026-08-12T16:10:00.818605+00:00" }
  seven_day   { utilization: 75, resets_at: "2026-08-14T07:00:00.818653+00:00" }
  limits[]    session 3% normal · weekly_all 75% warning ·
              weekly_scoped 2% normal scope={model:{display_name:"Fable"}}
  seven_day_opus / seven_day_sonnet / tangelo / nimbus_quill / … mostly null
  extra_usage / spend
```

**Why it is valuable**

- **`fetchedAtMs` is an explicit age.** Every dating heuristic shipped on 2026-08-12 — the five-hour replay rule, `TranscriptDating` — exists *only* because the statusline payload has no timestamp. This source needs none of it.
- **`weekly_scoped` is the per-model weekly limit**, which the backlog had marked 🔴 "blocked at the source". It was blocked in the *statusline payload*, not absent from the machine.
- **`severity`** (`normal` / `warning`) is Anthropic's own grading, better than any threshold this app invents.
- Plain local file read — **no credentials, no network, no ToS question.** Same risk class as reading transcripts.

**Why it must NOT become the sole source**

- It is an **undocumented internal field** and can change shape or disappear in any Claude Code release. The statusline payload is at least documented.
- **It does not self-refresh.** Measured frozen for 5+ minutes during continuous desktop-session use. `/usage` refreshes it — confirmed twice by watching `fetchedAtMs` move to the second the command was sent — and a session start does *not*.
- The statusline path is free, automatic while you work in a terminal, and now well covered by tests.

**So: two sources, compete on age, fresher wins.** `CaptureSelector.freshest` already models exactly that.

## Constraints and traps

- ⚠️ **`resets_at` has SIX fractional digits** (`…:00.818653+00:00`). Verified in Swift: `.withFractionalSeconds` parses it and the plain formatter returns `nil`; a bare `…Z` form is the reverse. **Both formatters with fallback are required** — the same pattern `TranscriptParser` already uses. A single formatter silently yields `nil` and the whole source goes dark.
- ⚠️ **Entries can be present with `resets_at: null`** (`nimbus_quill` is, today). A reading with no window boundary must be dropped, exactly as `StatuslinePayload` already drops a seven-day percentage with no `resets_at`.
- ⚠️ **Most sibling keys are `null`** (`seven_day_opus`, `seven_day_sonnet`, `tangelo`, `cinder_cove`, …). They are presumably non-null on other plans. Decode per-property and never let one unknown shape cost the others.
- ⚠️ **Claude Code rewrites this file concurrently.** A read can catch a partial write; the decode then fails and must simply yield `nil`, never throw into the UI.
- ⚠️ **The file contains 252 project paths** — for consultancy work, client names. Burnline must read only the utilization block and **must never copy the file, log it, or include it in diagnostics.** `BurnlineProbe` prints figures, never raw JSON.
- Measured cost: **160 KB, 0.5 ms to parse.** Cheap enough that mtime-gating is a nicety, not a necessity — but do it anyway, since the rebuild runs every 10s.

---

## File structure

| File | Responsibility | Pure? |
|---|---|---|
| `Sources/BurnlineCore/UsageUtilization.swift` | **Create.** Decode the block; convert to `RateLimitCapture`; expose scoped limits. | ✅ |
| `Sources/BurnlineCore/UtilizationStore.swift` | **Create.** Read `~/.claude.json`, mtime-gated. | file I/O |
| `Sources/BurnlineCore/Snapshot.swift` | **Modify.** Carry the per-model limit and its severity. | ✅ |
| `Sources/Burnline/UsageStore.swift` | **Modify.** Add utilization as a candidate. | — |
| `Sources/Burnline/PopoverView.swift` | **Modify.** Per-model row. | — |
| `Sources/BurnlineProbe/main.swift` | **Modify.** Report both sources and which won. | — |

---

## Task 1: Decode the utilization block

**Files:**
- Create: `Sources/BurnlineCore/UsageUtilization.swift`
- Test: `Tests/BurnlineCoreTests/UsageUtilizationTests.swift`

> ⚠️ Test names are module-scope. `grep -rn "func <name>" Tests/` before naming.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import BurnlineCore

/// Shaped from the real block observed 2026-08-12, including the null siblings
/// and the six-digit fractional seconds.
private let realish = """
{"fetchedAtMs":1786542556418,"accountUuid":"7d48fca5-1303-41f3-b219-eb0ad1170511",
 "utilization":{
   "five_hour":{"utilization":3,"resets_at":"2026-08-12T16:10:00.818605+00:00"},
   "seven_day":{"utilization":75,"resets_at":"2026-08-14T07:00:00.818653+00:00"},
   "seven_day_opus":null,"tangelo":null,
   "nimbus_quill":{"utilization":0,"resets_at":null},
   "limits":[
     {"kind":"session","group":"session","percent":3,"severity":"normal",
      "resets_at":"2026-08-12T16:10:00.818605+00:00","scope":null,"is_active":false},
     {"kind":"weekly_all","group":"weekly","percent":75,"severity":"warning",
      "resets_at":"2026-08-14T07:00:00.818653+00:00","scope":null,"is_active":true},
     {"kind":"weekly_scoped","group":"weekly","percent":2,"severity":"normal",
      "resets_at":"2026-08-14T06:59:59.818908+00:00",
      "scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":false}]}}
"""

private func decodeUtilization(_ json: String) throws -> UsageUtilization {
    try JSONDecoder().decode(UsageUtilization.self, from: Data(json.utf8))
}

@Test func decodesTheRealUtilizationBlock() throws {
    let u = try decodeUtilization(realish)
    #expect(u.sevenDay?.percent == 75)
    #expect(u.fiveHour?.percent == 3)
    #expect(u.fetchedAt == 1_786_542_556.418)
}

/// The trap: six fractional digits. A single formatter silently yields nil and
/// the entire source goes dark with no error anywhere.
@Test func parsesSixDigitFractionalSecondsAndBarePlainForm() throws {
    let u = try decodeUtilization(realish)
    #expect(u.sevenDay?.resetsAt != nil)

    let plain = try decodeUtilization("""
    {"fetchedAtMs":1,"utilization":{"seven_day":{"utilization":5,"resets_at":"2026-08-14T07:00:00Z"}}}
    """)
    #expect(plain.sevenDay?.resetsAt != nil)
}

/// `nimbus_quill` really is shaped like this today. A reading with no window
/// boundary can never be judged valid, so it is dropped.
@Test func aReadingWithNoResetInstantIsDropped() throws {
    let u = try decodeUtilization("""
    {"fetchedAtMs":1,"utilization":{"seven_day":{"utilization":5,"resets_at":null}}}
    """)
    #expect(u.sevenDay == nil)
}

@Test func nullSiblingsAndUnknownKeysDoNotCostTheRealReadings() throws {
    let u = try decodeUtilization("""
    {"fetchedAtMs":1,"utilization":{"seven_day_opus":null,"future_bucket":{"nope":1},
     "seven_day":{"utilization":50,"resets_at":"2026-08-14T07:00:00Z"}}}
    """)
    #expect(u.sevenDay?.percent == 50)
}

@Test func anAbsentUtilizationBlockDecodesToNothingRatherThanThrowing() throws {
    let u = try decodeUtilization(#"{"fetchedAtMs":1}"#)
    #expect(u.sevenDay == nil)
    #expect(u.scopedWeekly == nil)
}

/// The per-model weekly figure the backlog had recorded as unobtainable.
@Test func exposesTheScopedWeeklyLimitWithItsModelName() throws {
    let scoped = try #require(try decodeUtilization(realish).scopedWeekly)
    #expect(scoped.percent == 2)
    #expect(scoped.modelName == "Fable")
    #expect(scoped.severity == "normal")
}

/// Converting into the existing capture shape is what lets this source flow
/// through selection and high-water untouched.
@Test func convertsToACaptureDatedByItsOwnFetchTimestamp() throws {
    let capture = try #require(try decodeUtilization(realish).asCapture())
    #expect(capture.sevenDay.usedPercent == 75)
    #expect(capture.capturedAt == 1_786_542_556.418)
    #expect(capture.fiveHour?.usedPercent == 3)
    // No session owns this reading; it must never be dated by a transcript.
    #expect(capture.sessionId == nil)
    #expect(capture.transcriptPath == nil)
}

@Test func aBlockWithNoSevenDayYieldsNoCapture() throws {
    #expect(try decodeUtilization(#"{"fetchedAtMs":1}"#).asCapture() == nil)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test 2>&1 | grep -E "error:" | head -3`
Expected: `error: cannot find 'UsageUtilization' in scope`

- [ ] **Step 3: Implement**

Key points for the implementer:

- One `Reading` type: `percent: Double`, `resetsAt: Date`. Construct only when `resets_at` parses — mirror `StatuslinePayload`, which rejects a percentage with no boundary.
- Two `ISO8601DateFormatter`s, fractional first then plain, exactly like `TranscriptParser.date(from:)`. **Formatters are not `Sendable`; build them per decode, never share a global.**
- Decode every property with `try?` per key so one unknown shape costs only itself.
- `asCapture()` returns `RateLimitCapture(version: .currentVersion, capturedAt: fetchedAt, sevenDay:, fiveHour:, sessionId: nil, transcriptPath: nil)`. **`sessionId` must stay nil** — `TranscriptDating` would otherwise try to date a reading that no session produced.
- `scopedWeekly` picks `limits` where `kind == "weekly_scoped"`, carrying `percent`, `severity`, `modelName` from `scope.model.display_name`.

- [ ] **Step 4: Verify green**

Run: `swift test 2>&1 | grep -E "✘|Test run with"`
Expected: 292 tests passed (283 + 9)

- [ ] **Step 5: Commit**

```bash
git add Sources/BurnlineCore/UsageUtilization.swift Tests/BurnlineCoreTests/UsageUtilizationTests.swift
git commit -m "feat: decode cachedUsageUtilization, a second usage source with its own timestamp"
```

---

## Task 2: Read it from `~/.claude.json`

**Files:**
- Create: `Sources/BurnlineCore/UtilizationStore.swift`
- Test: `Tests/BurnlineCoreTests/UtilizationStoreTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
@Test func readsTheUtilizationBlockOutOfAClaudeConfig() throws { /* write a temp .claude.json, expect 75 */ }

/// Claude Code rewrites this file underneath us; a partial read must degrade to
/// nothing, never throw into the UI.
@Test func aTruncatedConfigYieldsNoUtilization() throws { /* write "{\"cachedUsage" */ }

@Test func aConfigWithoutTheBlockYieldsNoUtilization() throws { /* "{}" */ }

@Test func aMissingConfigYieldsNoUtilization() { /* nonexistent path */ }

/// Re-reading an unchanged file must not re-parse it — the rebuild runs every
/// 10 seconds.
@Test func anUnchangedFileIsNotReparsed() throws {
    let store = UtilizationStore(path: …)
    _ = store.load()
    #expect(store.load(parseCount: …) …)   // expose a test-only counter or compare identity
}
```

- [ ] **Step 2–4:** RED, implement, GREEN.

Implementation notes:

- `init(path: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude.json"))` — injectable, so tests never touch the real config. **No test may read or write the real `~/.claude.json`.**
- Cache on `(mtime, size)`; re-parse only on change.
- ⚠️ **Read only the utilization block.** The file holds 252 project paths, which for consultancy work are client names. Never copy the file, never log it, never include raw JSON in diagnostics.

- [ ] **Step 5: Commit**

---

## Task 3: Make it compete with the statusline

**Files:**
- Modify: `Sources/Burnline/UsageStore.swift`, `Sources/BurnlineProbe/main.swift`
- Test: `Tests/BurnlineCoreTests/CaptureDirectoryTests.swift` (append)

- [ ] **Step 1: Write the failing test**

```swift
/// The two sources compete on age alone. Utilization carries an explicit
/// fetchedAtMs; a statusline capture carries a derived mint time. Whichever is
/// genuinely newer wins.
@Test func utilizationWinsWhenItIsFresherThanTheStatuslineCapture() { … }

@Test func theStatuslineCaptureWinsWhenTheUtilizationCacheIsStale() { … }
```

- [ ] **Step 2–4:** RED, implement, GREEN.

In `UsageStore.rebuild()`, add the utilization capture to the candidate list already being built:

```swift
let candidates = captureDirectory.load()
    + [rateLimitStore.load()].compactMap { $0 }
    + [utilizationStore.load()?.asCapture()].compactMap { $0 }
```

Everything downstream — dating, `freshest(of:)`, `RateLimitHighWater` — is unchanged. The utilization capture has no `transcriptPath`, so dating leaves its `fetchedAtMs` alone, which is exactly right.

The probe gains a line naming both sources and their ages, so a disagreement is diagnosable.

- [ ] **Step 5: Commit**

---

## Task 4: The per-model weekly row

**Files:** `Sources/BurnlineCore/Snapshot.swift`, `Sources/Burnline/PopoverView.swift`, tests.

This is the item the backlog recorded as 🔴 impossible. Now obtainable.

- [ ] **Step 1:** Test that `Snapshot` carries `scopedWeekly` and that it is absent when the source has none.
- [ ] **Step 2–4:** RED, implement, GREEN. Row reads `Fable   2%`, alongside the existing `5-hour` row, rendered only when present.
- [ ] **Step 5: SCREENSHOT both states.** Three defects in this project were invisible in code review. Use `BURNLINE_OPEN_POPOVER=1` with `BURNLINE_DATA_DIR`, and **select the window by owner PID** — `/Applications/Burnline.app` owns windows with the same name and will otherwise be captured instead.
- [ ] **Step 6:** Close the 🔴 backlog item with the reasoning, since it is recorded as answered-no.

---

## Task 5 (OPTIONAL — decide after living with Tasks 1–4): the `/usage` poll

**Do not build this reflexively.** Tasks 1–4 are a pure read of a file that already exists. This task makes Burnline *spawn processes*, which is a different kind of app.

Measured facts it rests on:

- `/usage` refreshes `cachedUsageUtilization` — confirmed twice, `fetchedAtMs` moving to the second the command was sent.
- A `/usage`-only pty session produced **no transcript and no assistant turns**, so it costs no model tokens.
- A plain pipe will not do; Claude Code must believe it has a terminal (`openpty`).

If built:

- **Opt-in setting, default off**, with the cost stated in the UI.
- Interval no shorter than 15 minutes — the figure moves ~0.1%/minute.
- Must not run when a statusline capture is already fresher than the interval; polling would be pure waste.
- Kill the child on a timeout; never leave orphan sessions. Sessions accumulated to eight during the 2026-08-11 investigation and nobody noticed.
- ⚠️ It creates real Claude Code sessions. Confirm the footprint is acceptable before shipping to strangers.

---

## Risks

| Risk | Handling |
|---|---|
| Field changes shape or disappears | Peer, not primary. Absent → `nil` → statusline path unaffected. Every key decoded with `try?`. |
| Six-digit fractional seconds | Dual formatters, pinned by test. Verified in Swift before writing this plan. |
| Partial read during Claude Code's write | Decode failure → `nil`. Tested. |
| Client names in `~/.claude.json` | Read only the utilization block; never copy, log, or diagnose with raw JSON. |
| Stale cache presented as fresh | `fetchedAtMs` is explicit; freshest-wins handles it; high water still backstops the value. |
| Tests touching the real config | `UtilizationStore(path:)` is injectable and every test uses a temp file. |

## Out of scope

- Replacing the statusline path.
- Plans 5–7 (onboarding, notarization, Sparkle) — still paused.
- `extra_usage` / `spend` blocks — present in the data, no current use.
