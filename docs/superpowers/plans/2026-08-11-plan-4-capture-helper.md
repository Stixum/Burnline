# Burnline Plan 4 — Capture helper binary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the hand-installed `~/.claude/burnline-statusline.sh` with a `burnline-statusline` binary shipped inside `Burnline.app`, removing the `jq` dependency and putting the capture logic where app updates can reach it.

**Architecture:** All logic lands in `BurnlineCore` as two pure-ish units — `StatuslinePayload` (decode Claude Code's session JSON) and `StatusLineRenderer` (payload → the printed string) — plus a `save` on the existing `RateLimitStore`. The new `BurnlineStatusline` executable target is a ~20-line `main.swift` that reads stdin, calls those three, and exits 0 unconditionally.

**Tech Stack:** Swift 6, `Codable`, Swift Testing. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-08-11-burnline-distribution-design.md` §4. **Depends on:** Plans 1–3 complete (they are).

---

## Background for the implementer

**What a statusline script is.** Claude Code pipes a JSON blob describing the current session to a user-configured command on stdin after every assistant response, and renders whatever that command prints to stdout as the status line. Documented at <https://code.claude.com/docs/en/statusline>. This is **the only mechanism that exposes true subscription usage** — there is no API, no CLI flag, and no other local file. Hooks do not carry it. Do not go looking for an alternative; an earlier session did and wrongly concluded the data was unavailable.

**Why this is being rewritten in Swift.** The existing bash version works. Two things are wrong with it that only matter now that the app is being distributed:

1. It shells out to `jq`, which macOS did not ship until 15. `LSMinimumSystemVersion` is 14.0, so a Sonoma user gets no capture, no error, and a permanently pace-only app.
2. It lives outside the app bundle, so no app update can ever change it.

**The failure mode you are protecting against is silence.** This binary runs inside someone's terminal prompt. If it crashes, writes to stderr, or exits non-zero, Claude Code renders that inline and the user sees garbage on every single response. **A missed capture is a minor inconvenience; a noisy failure is a serious one.** Every error path prints something reasonable and exits 0.

**Reference implementation.** The current script is at `~/.claude/burnline-statusline.sh`. Read it before starting. The output format is in daily use and settled — this is a port, not a redesign.

**`rate_limits` being absent is normal, not an error.** It is missing on non-Pro/Max plans and before a session's first API response.

## File Structure

| File | Responsibility |
|---|---|
| `Sources/BurnlineCore/StatuslinePayload.swift` | **Create.** `Codable` model of Claude Code's session JSON + conversion to `RateLimitCapture` |
| `Sources/BurnlineCore/StatusLineRenderer.swift` | **Create.** Payload → the status line string. Pure |
| `Sources/BurnlineCore/RateLimitCapture.swift` | **Modify.** Add `RateLimitStore.save(_:)` |
| `Sources/BurnlineStatusline/main.swift` | **Create.** stdin → decode → save → print. No logic |
| `Package.swift` | **Modify.** Add the `BurnlineStatusline` executable target |
| `build.sh` | **Modify.** Build and copy the helper into `Contents/MacOS/` |
| `Tests/BurnlineCoreTests/StatuslinePayloadTests.swift` | **Create.** Decode fixtures |
| `Tests/BurnlineCoreTests/StatusLineRendererTests.swift` | **Create.** Rendering |

**Decode and render are separate files on purpose.** Decoding is about tolerating whatever Claude Code sends; rendering is about producing a string. They change for different reasons and one is far more likely to churn than the other.

---

### Task 1: `StatuslinePayload` — decode the session JSON

**Files:**
- Create: `Sources/BurnlineCore/StatuslinePayload.swift`
- Test: `Tests/BurnlineCoreTests/StatuslinePayloadTests.swift`

**Every field is optional.** Claude Code's payload shape is not a stable contract, and a missing field must degrade one element of the status line rather than failing the whole decode.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import BurnlineCore

private func decode(_ json: String) throws -> StatuslinePayload {
    try JSONDecoder().decode(StatuslinePayload.self, from: Data(json.utf8))
}

@Test func decodesAFullPayload() throws {
    let p = try decode("""
    {"model":{"display_name":"Opus 5"},
     "workspace":{"current_dir":"/Users/x/Projects/Burnline"},
     "context_window":{"used_percentage":42.7},
     "cost":{"total_cost_usd":1.2345},
     "rate_limits":{"seven_day":{"used_percentage":64,"resets_at":1786000000},
                    "five_hour":{"used_percentage":3,"resets_at":1785000000}}}
    """)
    #expect(p.model?.displayName == "Opus 5")
    #expect(p.workspace?.currentDir == "/Users/x/Projects/Burnline")
    #expect(p.contextWindow?.usedPercentage == 42.7)
    #expect(p.cost?.totalCostUsd == 1.2345)
    #expect(p.rateLimits?.sevenDay?.usedPercentage == 64)
    #expect(p.rateLimits?.fiveHour?.resetsAt == 1785000000)
}

@Test func decodesAnEmptyObject() throws {
    let p = try decode("{}")
    #expect(p.model == nil)
    #expect(p.rateLimits == nil)
}

@Test func decodesWithRateLimitsAbsent() throws {
    let p = try decode(#"{"model":{"display_name":"Sonnet 5"}}"#)
    #expect(p.model?.displayName == "Sonnet 5")
    #expect(p.rateLimits == nil)
}

@Test func decodesWithFiveHourAbsent() throws {
    let p = try decode(#"{"rate_limits":{"seven_day":{"used_percentage":64,"resets_at":1786000000}}}"#)
    #expect(p.rateLimits?.sevenDay?.usedPercentage == 64)
    #expect(p.rateLimits?.fiveHour == nil)
}

@Test func decodesWithExplicitNulls() throws {
    let p = try decode(#"{"model":null,"cost":{"total_cost_usd":null}}"#)
    #expect(p.model == nil)
    #expect(p.cost?.totalCostUsd == nil)
}

@Test func toleratesUnknownKeys() throws {
    let p = try decode(#"{"future_field":{"nested":true},"model":{"display_name":"Haiku","extra":1}}"#)
    #expect(p.model?.displayName == "Haiku")
}

// --- capture conversion ---

@Test func buildsACaptureFromAFullPayload() throws {
    let p = try decode(#"{"rate_limits":{"seven_day":{"used_percentage":64,"resets_at":1786000000},"five_hour":{"used_percentage":3,"resets_at":1785000000}}}"#)
    let capture = try #require(p.capture(capturedAt: 1_785_900_000))
    #expect(capture.version == RateLimitCapture.currentVersion)
    #expect(capture.capturedAt == 1_785_900_000)
    #expect(capture.sevenDay.usedPercent == 64)
    #expect(capture.sevenDay.resetsAt == 1_786_000_000)
    #expect(capture.fiveHour?.usedPercent == 3)
}

@Test func noCaptureWithoutRateLimits() throws {
    #expect(try decode("{}").capture(capturedAt: 1) == nil)
}

@Test func noCaptureWhenSevenDayResetsAtIsMissing() throws {
    // A percentage with no window boundary cannot be evaluated for validity
    // later, so it is worse than no capture at all.
    let p = try decode(#"{"rate_limits":{"seven_day":{"used_percentage":64}}}"#)
    #expect(p.capture(capturedAt: 1) == nil)
}

@Test func fiveHourWithoutResetsAtIsDroppedNotFatal() throws {
    let p = try decode(#"{"rate_limits":{"seven_day":{"used_percentage":64,"resets_at":1786000000},"five_hour":{"used_percentage":3}}}"#)
    let capture = try #require(p.capture(capturedAt: 1))
    #expect(capture.sevenDay.usedPercent == 64)
    #expect(capture.fiveHour == nil)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter StatuslinePayload`
Expected: FAIL — `cannot find 'StatuslinePayload' in scope`

- [ ] **Step 3: Implement**

```swift
import Foundation

/// The session JSON Claude Code pipes to a statusline command on stdin.
///
/// Every field is optional by design. This payload is not a stable contract —
/// a field that disappears in a future Claude Code release must cost us one
/// element of the status line, never the whole decode. See
/// <https://code.claude.com/docs/en/statusline>.
public struct StatuslinePayload: Sendable, Decodable {
    public struct Model: Sendable, Decodable {
        public var displayName: String?
        enum CodingKeys: String, CodingKey { case displayName = "display_name" }
    }

    public struct Workspace: Sendable, Decodable {
        public var currentDir: String?
        enum CodingKeys: String, CodingKey { case currentDir = "current_dir" }
    }

    public struct ContextWindow: Sendable, Decodable {
        public var usedPercentage: Double?
        enum CodingKeys: String, CodingKey { case usedPercentage = "used_percentage" }
    }

    public struct Cost: Sendable, Decodable {
        public var totalCostUsd: Double?
        enum CodingKeys: String, CodingKey { case totalCostUsd = "total_cost_usd" }
    }

    public struct Limit: Sendable, Decodable {
        public var usedPercentage: Double?
        public var resetsAt: TimeInterval?
        enum CodingKeys: String, CodingKey {
            case usedPercentage = "used_percentage"
            case resetsAt = "resets_at"
        }
    }

    public struct RateLimits: Sendable, Decodable {
        public var sevenDay: Limit?
        public var fiveHour: Limit?
        enum CodingKeys: String, CodingKey {
            case sevenDay = "seven_day"
            case fiveHour = "five_hour"
        }
    }

    public var model: Model?
    public var workspace: Workspace?
    public var contextWindow: ContextWindow?
    public var cost: Cost?
    public var rateLimits: RateLimits?

    enum CodingKeys: String, CodingKey {
        case model
        case workspace
        case contextWindow = "context_window"
        case cost
        case rateLimits = "rate_limits"
    }

    /// The capture to persist, or `nil` when this payload carries nothing worth
    /// recording.
    ///
    /// `rate_limits` is absent on non-Pro/Max plans and before a session's first
    /// API response — that is the normal case, not an error.
    ///
    /// A seven-day percentage without `resets_at` is rejected outright: the
    /// reading's validity is judged against its window boundary, and a
    /// percentage that can never be expired would be treated as current
    /// forever.
    public func capture(capturedAt: TimeInterval) -> RateLimitCapture? {
        guard let sevenDay = rateLimits?.sevenDay,
              let usedPercent = sevenDay.usedPercentage,
              let resetsAt = sevenDay.resetsAt
        else { return nil }

        var fiveHourReading: RateLimitCapture.Reading?
        if let fiveHour = rateLimits?.fiveHour,
           let percent = fiveHour.usedPercentage,
           let resets = fiveHour.resetsAt {
            fiveHourReading = .init(usedPercent: percent, resetsAt: resets)
        }

        return RateLimitCapture(
            version: RateLimitCapture.currentVersion,
            capturedAt: capturedAt,
            sevenDay: .init(usedPercent: usedPercent, resetsAt: resetsAt),
            fiveHour: fiveHourReading
        )
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter StatuslinePayload`
Expected: PASS, 10 tests

- [ ] **Step 5: Commit**

```bash
git add Sources/BurnlineCore/StatuslinePayload.swift Tests/BurnlineCoreTests/StatuslinePayloadTests.swift
git commit -m "feat: decode Claude Code's statusline payload in Swift"
```

---

### Task 2: `StatusLineRenderer` — the printed string

**Files:**
- Create: `Sources/BurnlineCore/StatusLineRenderer.swift`
- Test: `Tests/BurnlineCoreTests/StatusLineRendererTests.swift`

**This is a 1:1 port of the bash version's output.** It is in daily use; do not improve it. Fields joined by `"  ·  "` (two spaces, middle dot, two spaces), empty fields omitted entirely rather than rendered blank.

The one subtlety is money. The bash is `"$\(x * 100 | round / 100)"`, and jq prints numbers without trailing zeros — so `1.2` renders `$1.2`, not `$1.20`. Match that.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import BurnlineCore

private func render(_ json: String) throws -> String {
    StatusLineRenderer.render(try JSONDecoder().decode(StatuslinePayload.self, from: Data(json.utf8)))
}

@Test func rendersEveryField() throws {
    let line = try render("""
    {"model":{"display_name":"Opus 5"},
     "workspace":{"current_dir":"/Users/x/Projects/Burnline"},
     "context_window":{"used_percentage":42.7},
     "cost":{"total_cost_usd":1.2345},
     "rate_limits":{"seven_day":{"used_percentage":64.8,"resets_at":1786000000},
                    "five_hour":{"used_percentage":3.2,"resets_at":1785000000}}}
    """)
    #expect(line == "Opus 5  ·  Burnline  ·  ctx 42%  ·  week 64%  ·  5h 3%  ·  $1.23")
}

@Test func percentagesFloorRatherThanRound() throws {
    let line = try render(#"{"context_window":{"used_percentage":42.99}}"#)
    #expect(line == "ctx 42%")
}

@Test func directoryIsTheBasenameOnly() throws {
    let line = try render(#"{"workspace":{"current_dir":"/a/b/c/Burnline"}}"#)
    #expect(line == "Burnline")
}

@Test func omitsAbsentFieldsWithoutStraySeparators() throws {
    let line = try render(#"{"model":{"display_name":"Haiku"},"rate_limits":{"seven_day":{"used_percentage":10,"resets_at":1}}}"#)
    #expect(line == "Haiku  ·  week 10%")
}

@Test func omitsZeroCost() throws {
    // jq: `if .cost.total_cost_usd != null and > 0`. A $0 session is a session
    // that hasn't cost anything yet, and printing "$0" is noise.
    let line = try render(#"{"model":{"display_name":"Haiku"},"cost":{"total_cost_usd":0}}"#)
    #expect(line == "Haiku")
}

@Test func moneyDropsTrailingZeros() throws {
    #expect(try render(#"{"cost":{"total_cost_usd":1.2}}"#) == "$1.2")
    #expect(try render(#"{"cost":{"total_cost_usd":1.0}}"#) == "$1")
    #expect(try render(#"{"cost":{"total_cost_usd":0.005}}"#) == "$0.01")
}

@Test func rendersFallbackForAnEmptyPayload() throws {
    #expect(try render("{}") == "burnline")
}

@Test func fiveHourRendersWithoutSevenDay() throws {
    let line = try render(#"{"rate_limits":{"five_hour":{"used_percentage":3,"resets_at":1}}}"#)
    #expect(line == "5h 3%")
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter StatusLineRenderer`
Expected: FAIL — `cannot find 'StatusLineRenderer' in scope`

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Renders the line Claude Code prints in the user's terminal.
///
/// A 1:1 port of the jq filter in the original `burnline-statusline.sh`. The
/// format is settled and in daily use — this file exists to remove the `jq`
/// dependency, not to change what it prints.
public enum StatusLineRenderer {
    static let separator = "  ·  "
    /// Printed when the payload carries nothing renderable, so the status line
    /// is never blank.
    static let fallback = "burnline"

    public static func render(_ payload: StatuslinePayload) -> String {
        var fields: [String] = []

        if let name = payload.model?.displayName, !name.isEmpty {
            fields.append(name)
        }
        if let dir = payload.workspace?.currentDir,
           let last = dir.split(separator: "/").last, !last.isEmpty {
            fields.append(String(last))
        }
        if let ctx = payload.contextWindow?.usedPercentage {
            fields.append("ctx \(percent(ctx))")
        }
        if let week = payload.rateLimits?.sevenDay?.usedPercentage {
            fields.append("week \(percent(week))")
        }
        if let fiveHour = payload.rateLimits?.fiveHour?.usedPercentage {
            fields.append("5h \(percent(fiveHour))")
        }
        if let cost = payload.cost?.totalCostUsd, cost > 0 {
            fields.append(money(cost))
        }

        return fields.isEmpty ? fallback : fields.joined(separator: separator)
    }

    /// Floors. 42.99% is not 43% of the way through anything.
    private static func percent(_ value: Double) -> String {
        "\(Int(value.rounded(.down)))%"
    }

    /// Two decimal places with trailing zeros dropped, matching how jq prints
    /// the number: $1.2, not $1.20.
    private static func money(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        if rounded == rounded.rounded(.towardZero) {
            return "$\(Int(rounded))"
        }
        return "$" + String(format: "%.2f", rounded)
            .replacingOccurrences(of: #"0$"#, with: "", options: .regularExpression)
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter StatusLineRenderer`
Expected: PASS, 8 tests

- [ ] **Step 5: Commit**

```bash
git add Sources/BurnlineCore/StatusLineRenderer.swift Tests/BurnlineCoreTests/StatusLineRendererTests.swift
git commit -m "feat: render the status line in Swift, matching the jq filter"
```

---

### Task 3: `RateLimitStore.save` — the atomic write

**Files:**
- Modify: `Sources/BurnlineCore/RateLimitCapture.swift:53-69`
- Test: `Tests/BurnlineCoreTests/RateLimitTests.swift` (append)

**The atomicity is load-bearing, not hygiene.** `UsageStore` re-reads this file every 10 seconds from its own timer. A non-atomic write means it will eventually observe a half-written file. `Data.write(options: .atomic)` writes to a temporary and renames, which is exactly the `> tmp && mv -f` contract the bash version had.

- [ ] **Step 1: Write the failing test**

```swift
@Test func saveThenLoadRoundTripsACapture() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = RateLimitStore(directory: dir)
    let capture = RateLimitCapture(
        version: RateLimitCapture.currentVersion,
        capturedAt: 1_785_900_000,
        sevenDay: .init(usedPercent: 64, resetsAt: 1_786_000_000),
        fiveHour: .init(usedPercent: 3, resetsAt: 1_785_000_000)
    )

    try store.save(capture)
    #expect(store.load() == capture)
}

@Test func saveOverwritesAnExistingCapture() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = RateLimitStore(directory: dir)
    try store.save(.init(version: 1, capturedAt: 1, sevenDay: .init(usedPercent: 10, resetsAt: 2), fiveHour: nil))
    try store.save(.init(version: 1, capturedAt: 3, sevenDay: .init(usedPercent: 20, resetsAt: 4), fiveHour: nil))

    #expect(store.load()?.sevenDay.usedPercent == 20)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter RateLimit`
Expected: FAIL — `value of type 'RateLimitStore' has no member 'save'`

- [ ] **Step 3: Implement** — add to `RateLimitStore`:

```swift
    /// Written by the `burnline-statusline` helper after every assistant
    /// response.
    ///
    /// `.atomic` is required, not tidiness: `UsageStore` re-reads this file on a
    /// 10-second timer and must never observe a partial write. Foundation
    /// implements it as a write-to-temporary plus rename, matching the
    /// `> tmp && mv -f` contract of the shell script this replaced.
    public func save(_ capture: RateLimitCapture) throws {
        try JSONEncoder().encode(capture).write(to: url, options: .atomic)
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter RateLimit`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/BurnlineCore/RateLimitCapture.swift Tests/BurnlineCoreTests/RateLimitTests.swift
git commit -m "feat: RateLimitStore can write captures atomically"
```

---

### Task 4: The `BurnlineStatusline` executable

**Files:**
- Create: `Sources/BurnlineStatusline/main.swift`
- Modify: `Package.swift`

**No logic here.** Everything testable already lives in `BurnlineCore`. This file exists to move bytes and to guarantee the exit code.

- [ ] **Step 1: Add the target to `Package.swift`**

Insert after the `BurnlineProbe` target:

```swift
        .executableTarget(
            name: "BurnlineStatusline",
            dependencies: ["BurnlineCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
```

- [ ] **Step 2: Write `main.swift`**

```swift
import Foundation
import BurnlineCore

// Claude Code pipes session JSON on stdin after every assistant response and
// renders whatever we print as the status line. Two jobs: capture the rate
// limits for Burnline.app, and print a line worth having.
//
// This process runs inside someone's terminal prompt. It must never exit
// non-zero and never write to stderr — Claude Code renders failures inline, on
// every single response. A missed capture is a minor inconvenience; a noisy
// failure is a serious one. Hence: no `try!`, no fatalError, no early exit.

let input = FileHandle.standardInput.readDataToEndOfFile()

guard let payload = try? JSONDecoder().decode(StatuslinePayload.self, from: input) else {
    print(StatusLineRenderer.fallback)
    exit(0)
}

if let capture = payload.capture(capturedAt: Date().timeIntervalSince1970) {
    // Best-effort. A failed write must not cost the user their status line.
    try? RateLimitStore().save(capture)
}

print(StatusLineRenderer.render(payload))
exit(0)
```

- [ ] **Step 3: Verify it builds and behaves**

```bash
swift build --product BurnlineStatusline
```

Expected: builds clean.

```bash
echo '{"model":{"display_name":"Opus 5"},"rate_limits":{"seven_day":{"used_percentage":64,"resets_at":1786000000}}}' | swift run BurnlineStatusline
```

Expected output: `Opus 5  ·  week 64%`

⚠️ **That command writes to your real `~/Library/Application Support/Burnline/rate-limits.json`.** That file is live data — the only copy of the last real capture. Before running it, back it up:

```bash
cp ~/Library/Application\ Support/Burnline/rate-limits.json /tmp/rate-limits.backup.json
```

and restore it afterwards. Do not `rm` it at any point.

- [ ] **Step 4: Verify the silence guarantees**

```bash
echo 'not json at all' | swift run BurnlineStatusline; echo "exit=$?"
```

Expected: prints `burnline`, `exit=0`

```bash
printf '' | swift run BurnlineStatusline; echo "exit=$?"
```

Expected: prints `burnline`, `exit=0`

```bash
echo '{}' | swift run BurnlineStatusline 2>/tmp/stderr.txt; wc -c </tmp/stderr.txt
```

Expected: prints `burnline`, and stderr is **0 bytes**.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/BurnlineStatusline/main.swift
git commit -m "feat: burnline-statusline helper binary, replacing the bash script"
```

---

### Task 5: Ship it inside the bundle

**Files:**
- Modify: `build.sh:10-24`

The helper must sit at `Burnline.app/Contents/MacOS/burnline-statusline` so the onboarding in Plan 5 can point `settings.json` at a path that moves with the app and updates with it.

- [ ] **Step 1: Build both products**

Replace the build step:

```bash
echo "==> Building release binaries"
swift build -c release --product "${APP_NAME}"
swift build -c release --product BurnlineStatusline
```

- [ ] **Step 2: Copy the helper into the bundle**

After the existing `cp` of the main binary:

```bash
# The statusline helper ships inside the bundle so that (a) it is versioned
# with the app and reachable by updates, and (b) settings.json can point at a
# path that moves with the app. Its predecessor lived in ~/.claude and could
# never be updated.
cp ".build/release/BurnlineStatusline" "${APP}/Contents/MacOS/burnline-statusline"
```

- [ ] **Step 3: Sign the helper before the app**

Codesigning is inside-out — signing the `.app` first and the nested binary second invalidates the app's seal. In **both** branches of the signing block, sign the helper first:

```bash
codesign --force --options runtime --timestamp --sign "${IDENTITY}" "${APP}/Contents/MacOS/burnline-statusline"
codesign --force --options runtime --timestamp --sign "${IDENTITY}" "${APP}"
```

and for the ad-hoc branch (no `--timestamp`; ad-hoc signatures cannot be timestamped):

```bash
codesign --force --options runtime --sign - "${APP}/Contents/MacOS/burnline-statusline"
codesign --force --options runtime --sign - "${APP}"
```

- [ ] **Step 4: Verify**

```bash
./build.sh && codesign --verify --deep --strict --verbose=2 build/Burnline.app
```

Expected: `build/Burnline.app: valid on disk`, `satisfies its Designated Requirement`

```bash
echo '{}' | build/Burnline.app/Contents/MacOS/burnline-statusline
```

Expected: `burnline`

- [ ] **Step 5: Commit**

```bash
git add build.sh
git commit -m "build: ship and sign the statusline helper inside the bundle"
```

---

### Task 6: Cut over the author's own machine

Not strictly part of the deliverable, but it is how the port gets proven against real payloads before anyone else sees it.

- [ ] **Step 1: Install**

```bash
./build.sh --install
```

- [ ] **Step 2: Repoint `~/.claude/settings.json`**

Change the `statusLine.command` from `~/.claude/burnline-statusline.sh` to
`/Applications/Burnline.app/Contents/MacOS/burnline-statusline`. Leave `refreshInterval: 30` alone.

- [ ] **Step 3: Verify a real capture lands**

Send any message in a Claude Code session, then:

```bash
swift run BurnlineProbe
```

Expected: a `.live` source with a capture age under 30 seconds, and a status line in the terminal identical in format to the one before the cutover.

- [ ] **Step 4: Keep the old script for one week**

Do not delete `~/.claude/burnline-statusline.sh` yet. It is the rollback, and the only cost of keeping it is a file.

- [ ] **Step 5: Run the full suite and commit nothing**

```bash
swift test
```

Expected: all tests pass (193 existing + 20 new).

---

## Done when

- [ ] `swift test` green, ~213 tests
- [ ] `build/Burnline.app/Contents/MacOS/burnline-statusline` exists and is signed
- [ ] The author's own statusline runs the binary, not the script, and captures land
- [ ] `jq` appears nowhere in the shipped product
