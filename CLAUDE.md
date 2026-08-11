# CLAUDE.md — Burnline

> Deep project notes live in Obsidian: `Project Notes/Burnline/` (`Burnline.md` overview + `ARCHITECTURE.md`). This file is the in-repo quick reference for agents. When this file and Obsidian disagree, Obsidian wins — update both.
>
> **Design spec is the source of truth for behaviour:** `docs/superpowers/specs/2026-08-11-burnline-design.md`.

## What this is

A macOS menu bar app (SwiftUI, `MenuBarExtra`, macOS 14+, Swift 6) showing estimated Claude usage against the pace target for the current weekly window. Menu bar reads `64/65` — actual over target, no glyph and no colour (see the menu bar gotcha below).

Personal tool. Locally built and installed to `/Applications`, never App Store. **Unsandboxed on purpose** — that's what gives plain read access to `~/.claude` with no entitlement or TCC work. Don't add the sandbox entitlement; it breaks the only data source.

## The one thing to understand

**Three sources, ranked, and the UI must say which one is in play** (`Snapshot.source`):

1. **`.live`** — a statusline capture inside the current window. The percentage is Anthropic's own and the window boundary is exact. Extrapolated forward from local token counts between captures.
2. **`.calibrated`** — no usable capture, but the user has entered `/usage` readings by hand. Anchors → units-per-percent → estimate.
3. **`.paceOnly`** — neither. Show the clock target alone. Fully valid, and the app this started as.

**Pace is always exact** — calendar arithmetic, cannot be wrong. Usage is exact only under `.live`, and an estimate otherwise.

**Structural blind spot (applies to the estimate, and to `.live` between captures):** transcripts cover only Claude Code *on this Mac*. claude.ai web, the desktop app, and other machines are invisible. A live capture corrects for all of it at the moment it lands, then drifts again until the next one. Never present an extrapolated figure as authoritative.

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
- **Buckets store *weighted* units, so the cache is only valid for the weights that built it.** `ScanCache.weights` records them and a mismatch discards the whole cache. **Don't "optimise" that into a partial reuse** — the weighting can't be recovered from a bucket after the fact, and the incremental path would leave a permanent mix of two scales that only clears as files age out of retention. This shipped as a real 100× bug on 2026-08-11. The counterweight test is `unchangedWeightsStillScanIncrementally`: rescoring must fire *only* on an actual change, or every 60s refresh becomes a 6s cold scan.
- **Hardcoded dark surfaces are only half the job — you must declare dark appearance too.** `NSApplication.shared.appearance = NSAppearance(named: .darkAqua)` at launch, plus `.preferredColorScheme(.dark)` on each window. Skip it and every *system* control (picker, stepper, checkbox, disclosure triangle, title bar) renders for light mode and comes out near-black on near-black, while hand-styled text looks fine — so the bug hides from anyone reading the code. Use `.windowBackground()` (not `.background()`) on window roots: it paints the title bar and kills the translucent material that otherwise shows the desktop through the window.
- **`SettingsLink` / the `Settings` scene silently do nothing in this app.** An `LSUIElement` process is never activated, so the scene has nothing to attach to and the click looks like a dead button. Settings is an explicit `Window` scene opened via `openWindow(id:)` **plus `NSApplication.activate`** — both halves are required. Launch with `BURNLINE_OPEN_SETTINGS=1` to open it without a click, which is how it gets verified from a terminal.
- **True subscription usage DOES arrive — via the statusline hook, not an API.** Claude Code pipes session JSON to a statusline script on every response, carrying `rate_limits.seven_day.{used_percentage,resets_at}` ([docs](https://code.claude.com/docs/en/statusline)). `~/.claude/burnline-statusline.sh` captures it to `rate-limits.json`; `RateLimitStore` reads it. **Do not go looking for an API, a CLI flag, or another local file — there isn't one**, and searching for those is what made an earlier session wrongly conclude the data was unavailable at all.
  - A capture pins the window exactly (`resets_at` *is* the boundary), so the configured schedule is unused while one is live.
  - A capture also supplies **both halves of a calibration by itself**: the true percentage, plus the local token count at that instant giving units-per-percent to extrapolate forward. Manual anchors are a fallback, not the main path.
  - The percentage is only valid inside the window it was captured in. Once `resets_at` passes, roll the window forward but **discard the percentage** — it describes a period that no longer exists.
  - **`five_hour` is a separate window, not a sub-window of the weekly one.** It rides in the same capture and obeys the same die-with-your-window rule, but against **its own** `resetsAt` — a 5-hour window resets several times inside one weekly window, so the weekly validity check tells you nothing about it. Evaluate them independently, and never extrapolate the 5-hour figure from local tokens. It's absent on some plans; the row just doesn't render.
  - **Hooks are not an alternative.** Checked 2026-08-11: no hook event receives `rate_limits` — they get `session_id`, `transcript_path`, `cwd`, `permission_mode` and little else. statusLine is the only carrier, so don't try to "improve" this by moving it to a hook.
  - ⚠️ **`rate-limits.json` is LIVE DATA, not scratch.** It is the only copy of the last real capture; deleting it drops the app to pace-only until Claude Code writes another. Never `rm` it while diagnosing — write test payloads to a temp path and point a test `RateLimitStore(directory:)` at that instead.
  - **`refreshInterval` in the statusLine config re-runs the script on a timer**, not just on assistant responses. Set to 30s, because between captures Burnline extrapolates from local tokens alone and undershoots any usage that happened off this Mac.
  - **The desktop app runs the script — and that's the problem, not the reassurance.** Verified 2026-08-11: every writer was a GUI session (`Claude.app` → `Helpers/disclaimer` → `claude`), with no CLI session running at all. **Every open session writes this one file on its own timer, with no arbitration — last write wins, and "last" is not "freshest."** A session's `rate_limits` is a cached snapshot that only refreshes when *that session* calls the API, so an idle window republishes its original reading forever. Seven sessions were open, one for 26 hours. They accumulate; they don't exit when you're done. `RateLimitHighWater` is what defends against this — **don't bypass it and read the file directly.**
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
