# Burnline — Design Spec

> Status: **APPROVED** 2026-08-11. Not yet implemented.

A macOS menu bar app that answers one question at a glance: **am I ahead of or behind the pace I should be at, this far into my Claude weekly usage window?**

- **Repo:** `/Users/seanmccauley/Projects/Burnline/`
- **Obsidian:** `Project Notes/Burnline/`
- **Platform:** macOS 14+, SwiftUI, Swift 6, Xcode 26.6

---

## 1. Problem

A Claude subscription's weekly limit resets on a fixed weekday and time. Seven days is 100%, so each elapsed day is ~14.3% of the window. On day 5 you are ~71% of the way through the window — if you've consumed materially less than 71% of your limit you have headroom, and if you've consumed more you will run out early.

Claude Code's `/usage` tells you the actual percentage, but nothing tells you the **pace target** to compare it against, and nothing surfaces either number without stopping what you're doing.

## 2. What Burnline does

A menu bar item shows `◐ 40/71` — actual estimated usage over the pace target. Clicking opens a popover with a single bar: a violet fill for what has actually been consumed, and a white marker where the clock says you should be. Fill behind the marker means you are under budget.

The popover also shows day-of-window, reset time, time remaining, and an "at this rate" projection of where you will land by reset.

### Non-goals

- No Anthropic API calls, no scraping of claude.ai, no credentials of any kind.
- No history, charts, or trends. Current window only.
- No notifications or alerts in v1 (see Backlog).
- Not App Store distributed. Locally installed personal tool.

## 3. Two halves, two different confidence levels

This distinction runs through the whole design and must be visible in the UI.

**The pace half is exact.** It is pure calendar arithmetic over a user-configured reset weekday and time. It cannot be wrong.

**The usage half is an estimate.** Burnline reads token counts from Claude Code's local transcripts, which is exact, but Anthropic does not publish how many tokens equal 100% of a weekly limit. There is no denominator available locally. Burnline therefore *derives* one from user-supplied calibration anchors (§6).

### Structural blind spot

`~/.claude/projects/**/*.jsonl` records **only Claude Code sessions on this Mac**. Usage from claude.ai in a browser, the Claude desktop app, or any other machine is invisible and always will be.

Calibration partially compensates: when the user enters a real percentage, the fitted units-per-percent inflates to absorb the invisible share. This holds only while that share stays roughly constant. If it swings, the estimate drifts until recalibration. This is a permanent property of the approach, not a defect to fix later, and the UI must never present the estimate as authoritative.

**Degradation:** with zero calibration anchors, Burnline hides the usage estimate entirely and displays only the pace target. That mode is fully useful on its own.

## 4. Architecture

Native SwiftUI `MenuBarExtra`, `LSUIElement = true` (no dock icon), **unsandboxed**.

**Built as a Swift package, not an Xcode project** (revised 2026-08-11 after a spike). A hand-generated `project.pbxproj` is fragile and can't be driven from a terminal; an SPM package gives `swift build` and `swift test` directly, and `build.sh` assembles the `.app` bundle around the produced binary. Verified in a spike: SwiftUI `MenuBarExtra` compiles under Swift 6 language mode as an SPM executable, and the hand-assembled bundle ad-hoc signs and launches clean as an `LSUIElement` accessory process.

The package splits into two targets, which is what makes the core testable from the CLI with no UI in the loop:

- **`BurnlineCore`** (library) — all six logic units. No SwiftUI, no app lifecycle.
- **`Burnline`** (executable) — SwiftUI views and the app entry point only.
- **`BurnlineProbe`** (executable) — a small diagnostic that prints a `Snapshot` against the real transcripts, so the engine is verifiable before any UI exists.

Unsandboxed is a deliberate choice: it grants plain read access to `~/.claude` with no entitlement work and no TCC prompt (a home-directory dotfolder is not a TCC-protected location). The app is locally built and installed, never App Store distributed, so the sandbox buys nothing.

Six units. The first four are pure and independently testable; the UI reads a single immutable `Snapshot` so no arithmetic happens in a view body.

| Unit | Responsibility | Depends on |
|---|---|---|
| `WindowMath` | reset weekday + time + now → window start/end, elapsed fraction, day index, time remaining | Foundation |
| `TranscriptScanner` | walk transcripts → `[UsageRecord]`; incremental via mtime + byte offset | filesystem |
| `ConsumptionModel` | records + weights → weighted units | — |
| `Calibration` | anchors → units-per-percent | — |
| `UsageStore` | orchestrates on a timer, publishes `Snapshot` | all of the above |
| Views | `MenuBarLabel`, `PopoverView`, `SettingsView` | `UsageStore` |

### Data flow

```
~/.claude/projects/**/*.jsonl
  → TranscriptScanner (incremental)  → [UsageRecord]
  → ConsumptionModel (weights)       → hourly unit buckets → scan-cache.json
  → sum over window                  → units-in-window
  → Calibration (anchors)            → estimated %
  ↘ WindowMath (settings + now)      → target %, day index, time left
  → Snapshot → MenuBarLabel + PopoverView
```

### Types

```swift
struct UsageRecord {
    let timestamp: Date
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheWriteTokens: Int
    let cacheReadTokens: Int
}

struct Window {
    let start: Date
    let end: Date
    var elapsedFraction: Double   // 0...1, clamped
    var dayIndex: Double          // elapsedFraction * 7
    var timeRemaining: TimeInterval
}

struct Snapshot {
    let window: Window
    let targetPercent: Double         // exact
    let estimatedPercent: Double?     // nil when uncalibrated
    let projectedPercent: Double?     // nil when too early in window
    let unitsInWindow: Double
    let calibrationAge: TimeInterval?
    let isScanning: Bool
}
```

## 5. Window math

The user configures a reset **weekday**, **time of day**, and **timezone** (defaults to the system timezone).

- `windowStart` = the most recent occurrence of (weekday, time) at or before `now`, found with `Calendar.nextDate(after:matching:matchingPolicy:direction:.backward)`.
- `windowEnd` = `calendar.date(byAdding: .day, value: 7, to: windowStart)`. Calendar arithmetic, **not** `+604800` seconds, so the wall-clock reset time survives DST transitions — a DST week is 167 or 169 hours long, and the reset must stay at (say) 9:00 AM either way.
- `elapsedFraction = (now - windowStart) / (windowEnd - windowStart)`, clamped to `0...1`.
- `targetPercent = elapsedFraction * 100`.
- `dayIndex = elapsedFraction * 7`.

Worked example from the original request: at exactly day 5.0 of 7, `elapsedFraction = 5/7 = 0.714`, `targetPercent = 71.4`.

## 6. Consumption and calibration

### Weighted units

```
units = (in × 1.0 + cacheWrite × 1.25 + cacheRead × 0.1 + out × 5.0) × modelMultiplier
```

Model multipliers: Opus 5.0, Sonnet 1.0, Haiku 0.27. Unknown models default to 1.0 and are logged.

These defaults are price-proportional (Sonnet as the 1.0 baseline). The **absolute scale is irrelevant** — calibration divides it out. Only the *relative* weighting matters, because it determines how the estimate responds to a change in usage mix. All weights are editable under an Advanced disclosure in Settings.

Measured reality check (this Mac, 7 days to 2026-08-11): 26.0M output and 8.9B cache-read tokens on Opus 5, across 41,520 assistant messages. Cache reads dominate the weighted total even at 0.1, which is why their weight is exposed rather than hardcoded.

### Calibration

An anchor is `(timestamp, observedPercent, unitsInWindowAtThatMoment)`, created when the user reads `/usage` and types the real number into the popover.

- **One anchor:** `unitsPerPercent = units / observedPercent`.
- **Multiple anchors:** least-squares fit through the origin over the most recent 8 anchors — `unitsPerPercent = Σ(units × percent) / Σ(percent²)`. Through-origin is correct because zero units must mean zero percent.
- **Rejected anchors:** `observedPercent < 5` (division noise dominates), or older than 60 days.
- **Zero valid anchors:** `estimatedPercent = nil`; UI enters pace-only mode.

`estimatedPercent = unitsInWindow / unitsPerPercent`, uncapped (values over 100 are meaningful — they mean the estimate has drifted or the limit is genuinely exhausted).

The popover displays calibration age. Beyond 14 days it is styled as stale, with a prompt to recalibrate.

### Projection

`projectedPercent = estimatedPercent / elapsedFraction` — a linear extrapolation of the current burn rate to the end of the window.

Suppressed (`nil`, rendered as an em-dash) when `elapsedFraction < 0.02` (roughly the first 3.4 hours of a window), where the denominator is too small for the result to mean anything.

## 7. Scanning

A full scan of 2,929 transcript files takes ~1.5s — acceptable once, far too slow to repeat on a 60-second timer.

### Incremental cache

`~/Library/Application Support/Burnline/scan-cache.json` holds, per file: `mtime`, `size`, byte `offset`, and **15-minute buckets** of weighted units.

Bucket granularity is a deliberate trade. Buckets must be per-file so a truncated file's contribution can be dropped wholesale, and a window total is a sum of whole buckets — so a bucket straddling the window boundary is counted all-in or all-out. At 15 minutes that error is ≤0.15% of a 7-day window, and it vanishes entirely when the reset time lands on a quarter hour. Hourly buckets would put it at 0.6%; per-record storage would remove it but costs ~2MB of JSON per week.

Each refresh re-reads only files whose `mtime` has advanced, resuming from the stored byte offset, so steady-state cost is a few KB. Window totals are a sum over buckets in range.

### Correctness rules

- **Truncation/rewrite:** if `size < offset`, drop that file's cache entry entirely and re-read from zero. Without this, a rewritten file double-counts.
- **Eviction:** files untouched for 14 days are removed from the cache. If such a file is later touched, it re-reads from zero; the buckets it recomputes are outside any live window and are therefore harmless.
- **Partial lines:** the final line of a file being actively written may be incomplete. Advance the stored offset only to the end of the last **complete** line (last newline), so the partial record is re-read intact next pass.
- **Malformed lines:** skip silently and continue. Transcripts contain non-JSON and non-assistant rows routinely.

### Parsing

For each line: require `type == "assistant"` and a `message.usage` object. Read `timestamp` (ISO 8601), `message.model`, and `usage.{input_tokens, output_tokens, cache_creation_input_tokens, cache_read_input_tokens}`. Ignore `usage.iterations`, which restates the same totals per turn and would double-count.

A cheap `line.contains("\"usage\"")` prefilter before JSON decoding avoids parsing the majority of lines.

### Cadence

Every 60s on a background queue, plus immediately on popover open (debounced to at most once per 5s). First launch pays the full scan behind a spinner, with `isScanning` surfaced in the popover.

## 8. Interface

### Menu bar

`◐ 40/71` — estimated actual over pace target, both integers, monospaced digits. Uncalibrated: `◐ 71` (target alone). Scanning on first launch: `◐ …`.

### Popover (300pt wide)

- Eyebrow: `WEEKLY WINDOW`
- Hero: delta magnitude + `points under budget` / `points over budget`, with a direction arrow and a short verdict line
- The bar: violet fill = estimated actual, white marker = pace target, labelled `40% used` / `should be 71%`
- Rows: `Day 5.0 of 7` · `Resets Thu 9:00 AM` · `Time left 2d 3h` · `At this rate 56% by reset`
- Footer: calibration age with an `Update` action, Settings (⌘,), Quit (⌘Q)

### Settings

Reset weekday, reset time, timezone, launch at login (`SMAppService.mainApp`), and an Advanced disclosure holding the six weights plus a calibration anchor list with delete.

### Visual identity

Per `~/Projects/DESIGN-STANDARDS.md`, dark family, **hardcoded dark with no toggle** — the popover stays dark in macOS light mode, which is the deliberate portfolio standard.

- Accent **violet `#7C5CFF`**. Every other portfolio accent is claimed (TicketTrek cyan, Metra amber, TrainTimes azure, OmniLoad `#2E5BFF`, TodoNotes `#0055FF`, Workshop `#003ec7`). A cool hue also keeps the accent from colliding with the green/amber/red the delta needs.
- Surfaces `#0a0a0f` background, `#12121a` raised, hairline borders white @ 8%.
- Radius: SOFT camp — card 12 / control 10 / row 8 / badge 4.
- Type: SF Pro only, no bundled fonts. `.monospacedDigit()` on every figure. Uppercase eyebrows at ~10pt, tracking 1.2–1.5.
- Wordmark and app icon: rounded-square violet tile with a diagonal burn-line glyph, hand-rolled SVG.

### Accessibility

- **Status never by color alone.** The delta always carries word + arrow + color.
- Honour `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` for any bar animation.
- The menu bar item carries an accessibility label spelling out both numbers.
- Muted text stays at ≥4.5:1 against `#0a0a0f` (the standards call out low-alpha muted text on near-black as a recurring contrast failure).

## 9. Testing

Swift Testing (`import Testing`). The pure units carry the logic and therefore the tests.

**`WindowMath`**
- day 5.0 of 7 → 71.4% (the originating example)
- `now` exactly at the reset instant → new window, elapsed 0
- one second before reset → elapsed ≈ 1.0, not 0
- spring-forward week (167h) and fall-back week (169h) both keep the reset at the configured wall-clock time
- reset weekday/time in a non-system timezone
- clamping when the system clock jumps backwards

**`TranscriptScanner`**
- malformed JSON line skipped, scan continues
- non-assistant rows and rows without `usage` ignored
- `usage.iterations` does not double-count
- offset resume reads only appended content
- truncated file (`size < offset`) re-reads whole
- trailing partial line re-read intact on the next pass

**`ConsumptionModel`**
- weighting arithmetic per token class
- unknown model defaults to 1.0

**`Calibration`**
- zero anchors → nil
- single anchor → exact divide
- multiple anchors → through-origin least squares
- anchors below 5% and older than 60 days rejected
- all anchors rejected → nil

**Projection**
- `elapsedFraction < 0.02` → nil
- normal case extrapolates linearly

## 10. Build and install

`build.sh` at the repo root:

1. `swift build -c release`
2. Assemble `Burnline.app` — `Contents/MacOS/Burnline`, `Contents/Info.plist` (with `LSUIElement`), `Contents/Resources/`
3. Sign with Developer ID Application if a cert is present; ad-hoc (`-s -`) otherwise
4. Copy to `/Applications`

Ad-hoc signed builds need one right-click → Open to clear Gatekeeper. Launch-at-login is a Settings toggle, not part of install.

## 11. Repo and notes structure

```
~/Projects/Burnline/
├── Package.swift
├── Sources/
│   ├── BurnlineCore/         # library: the six logic units, no SwiftUI
│   ├── Burnline/             # executable: SwiftUI views + entry point
│   └── BurnlineProbe/        # executable: prints a Snapshot for verification
├── Tests/BurnlineCoreTests/
├── Resources/Info.plist
├── build.sh
├── CLAUDE.md
├── README.md
└── docs/superpowers/
    ├── specs/2026-08-11-burnline-design.md
    └── plans/
```

Obsidian `Project Notes/Burnline/` — `Burnline.md` (index), `ARCHITECTURE.md`, `BACKLOG.md`, `CHANGELOG.md`, plus an `INDEX.md` entry. Burnline uses the **Obsidian prose-backlog**, not GitHub issues; it is not one of the three Workshop-pipeline projects.

## 12. Open items

Deferred out of v1, recorded in `BACKLOG.md`:

- Threshold notifications ("you crossed 15 points over budget")
- The separate weekly Opus limit as a second bar
- The rolling 5-hour session window
- Sparkline of the current window's burn curve
- Multi-machine merge via a synced cache file
