# CLAUDE.md — Burnline

> Deep project notes live in Obsidian: `Project Notes/Burnline/` (`Burnline.md` overview + `ARCHITECTURE.md`). This file is the in-repo quick reference for agents. When this file and Obsidian disagree, Obsidian wins — update both.
>
> **Design spec is the source of truth for behaviour:** `docs/superpowers/specs/2026-08-11-burnline-design.md`.

## What this is

A macOS menu bar app (SwiftUI, `MenuBarExtra`, macOS 14+, Swift 6) showing estimated Claude usage against the pace target for the current weekly window. Menu bar reads `◐ 40/71` — actual over target.

Personal tool. Locally built and installed to `/Applications`, never App Store. **Unsandboxed on purpose** — that's what gives plain read access to `~/.claude` with no entitlement or TCC work. Don't add the sandbox entitlement; it breaks the only data source.

## The one thing to understand

**Two halves with different confidence levels, and the UI must keep them distinct.**

- **Pace is exact.** Calendar arithmetic over a user-set reset weekday/time. Cannot be wrong.
- **Usage is an estimate.** Token counts from `~/.claude/projects/**/*.jsonl` are exact, but Anthropic publishes no denominator — nothing local says how many tokens are 100% of the weekly limit. Burnline derives one from user-entered calibration anchors (`/usage` says X% → solve units-per-percent).

**Structural blind spot:** transcripts cover only Claude Code *on this Mac*. claude.ai web, the desktop app, and other machines are invisible and always will be. Calibration absorbs that share only while it stays roughly constant. Never present the estimate as authoritative. With zero anchors the app hides the estimate and runs pace-only, which is a fully valid mode.

## Structure

| Unit | Responsibility | Pure? |
|---|---|---|
| `WindowMath` | reset weekday/time + now → window bounds, elapsed fraction, day index | ✅ |
| `TranscriptScanner` | transcripts → `[UsageRecord]`, incremental by mtime + byte offset | filesystem |
| `ConsumptionModel` | records + weights → weighted units | ✅ |
| `Calibration` | anchors → units-per-percent | ✅ |
| `UsageStore` | orchestrates on a timer, publishes one `Snapshot` | — |
| Views | `MenuBarLabel`, `PopoverView`, `SettingsView` | — |

Views read a single immutable `Snapshot`. **No arithmetic in a view body** — it belongs in a pure unit with tests.

## Gotchas

- **Window end is `Calendar.date(byAdding: .day, value: 7)`, never `+604800`.** A DST week is 167 or 169 hours; the reset must stay at the same wall-clock time either way.
- **Ignore `usage.iterations`.** It restates the same token totals per turn — summing it double-counts.
- **Advance the scan offset only to the last complete line.** Transcripts are appended to live; the trailing line is often partial and must be re-read intact next pass.
- **`size < offset` means truncated/rewritten** → drop that file's cache entry and re-read whole, or it double-counts.
- **Calibration least-squares is through the origin.** Zero units must mean zero percent. Reject anchors below 5% (division noise) or older than 60 days.
- **Projection is suppressed when `elapsedFraction < 0.02`.** Dividing by a near-zero denominator early in a window produces nonsense.
- **Cache-read tokens dominate the weighted total** (8.9B vs 26M output in a sample week). Their weight is exposed in Settings for that reason — don't hardcode it.
- **Never put a hardcoded color on the menu bar label.** macOS renders it against a light or dark bar depending on the user's wallpaper and tints template content automatically. Hardcoded violet or green is unreadable on one of them. The popover is hardcoded dark; all color lives there. These two rules look contradictory and are both correct.
- **Buckets are 15 minutes and window totals sum whole buckets**, so a bucket straddling the reset counts all-in or all-out — bounded at 0.15% of a week. Don't "fix" this by summing partial buckets; the sub-bucket detail was never stored.

## Commands

```bash
swift test                 # run the Swift Testing suite
swift run BurnlineProbe    # print a Snapshot from the real transcripts
./build.sh --install       # release build, assemble bundle, sign, install to /Applications
```

**Built with SwiftPM, not Xcode.** Three targets: `BurnlineCore` (library, all logic, no SwiftUI), `Burnline` (executable, SwiftUI only), `BurnlineProbe` (CLI diagnostic). `build.sh` assembles the `.app` bundle around the SPM binary. There is no `.xcodeproj` and adding one would break CLI builds and tests.

## Design language

Dark family, hardcoded, **no light-mode toggle** — the popover stays dark in macOS light mode, per `~/Projects/DESIGN-STANDARDS.md`. Accent violet `#7C5CFF` (every other portfolio accent is claimed; a cool hue avoids colliding with the green/amber/red the delta needs). Surfaces `#0a0a0f`/`#12121a`, hairlines white @ 8%, SOFT radius camp (card 12 / control 10 / row 8). SF Pro only, `.monospacedDigit()` on every figure. **Status never by color alone** — the delta always carries word + arrow + color.
