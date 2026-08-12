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
- **True subscription usage DOES arrive — via the statusline hook, not an API.** Claude Code pipes session JSON to a statusline script on every response, carrying `rate_limits.seven_day.{used_percentage,resets_at}` ([docs](https://code.claude.com/docs/en/statusline)). The `burnline-statusline` binary inside the app bundle captures it to `rate-limits.json`; `RateLimitStore` reads it. ⚠️ **This line used to say "don't go looking for an API, a CLI flag, or another local file — there isn't one". That was wrong, twice over.** There IS another local file: `~/.claude.json` → `cachedUsageUtilization` (see below), found 2026-08-12 and now a shipped peer source. What genuinely does not exist is an **API** carrying subscription usage — the documented `anthropic-ratelimit-*` headers are per-minute API-organization limits for a different product, and OpenTelemetry carries none of it (both checked 2026-08-12). **Three times now a confident negative on this project has been a negative about one interface mistaken for the system.**
  - **The capture helper is a Swift binary in the bundle, not a shell script.** `Sources/BurnlineStatusline/main.swift` is a thin shell over `StatuslinePayload` (decode) and `StatusLineRenderer` (the printed line), both in `BurnlineCore` and both tested. It replaced `~/.claude/burnline-statusline.sh` because the script shelled out to **`jq`, which macOS did not ship until 15** while this app supports 14+ — so a Sonoma user got no capture and no error — and because a file in `~/.claude` can never be updated by an app update.
  - **The helper must never exit non-zero or write to stderr.** Claude Code renders statusline failures inline in the user's terminal, on every response. Malformed JSON, empty stdin and a decode overflow all print `burnline` and exit 0. Every `Double`→`Int` conversion goes through `DisplayValue`, which saturates — `Int(Double)` *traps* on a value outside `Int`'s range, and a plain 20-digit number in JSON decodes to a perfectly finite `1e20`.
  - A capture pins the window exactly (`resets_at` *is* the boundary), so the configured schedule is unused while one is live.
  - A capture also supplies **both halves of a calibration by itself**: the true percentage, plus the local token count at that instant giving units-per-percent to extrapolate forward. Manual anchors are a fallback, not the main path.
  - The percentage is only valid inside the window it was captured in. Once `resets_at` passes, roll the window forward but **discard the percentage** — it describes a period that no longer exists.
  - **`five_hour` is a separate window, not a sub-window of the weekly one.** It rides in the same capture and obeys the same die-with-your-window rule, but against **its own** `resetsAt` — a 5-hour window resets several times inside one weekly window, so the weekly validity check tells you nothing about it. Evaluate them independently, and never extrapolate the 5-hour figure from local tokens. It's absent on some plans; the row just doesn't render.
  - **Hooks are not an alternative.** Checked 2026-08-11: no hook event receives `rate_limits` — they get `session_id`, `transcript_path`, `cwd`, `permission_mode` and little else. statusLine is the only carrier, so don't try to "improve" this by moving it to a hook.
  - ⚠️ **`rate-limits.json` is LIVE DATA, not scratch.** It is the only copy of the last real capture; deleting it drops the app to pace-only until Claude Code writes another. Never `rm` it while diagnosing — write test payloads to a temp path and point a test `RateLimitStore(directory:)` at that instead.
  - ⚠️⚠️ **Running the `burnline-statusline` binary WRITES to that live file. Set `BURNLINE_DATA_DIR` before you run it** — that env var redirects every Burnline data file, and it is the only thing that works. `env -i HOME=/tmp/...` does **not** sandbox it: `ApplicationSupport.directory()` resolves via `FileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)`, which uses the real home directory and **ignores `$HOME`**. Copying the binary elsewhere does not help either — the path is resolved at runtime, not from the binary's location. This wrote live data three times in one session on 2026-08-11, once producing a **fabricated reading that the app latched into `rate-limit-highwater.json`** and displayed as real.

    ```bash
    BURNLINE_DATA_DIR=/tmp/burnline-test .build/debug/BurnlineStatusline < payload.json
    ```

    **Confirm the export landed before running anything that writes** — `swift run BurnlineProbe` prints the resolved directory as its first line and says `(live data)` or `(BURNLINE_DATA_DIR override — not live data)`. A typo'd variable name is silent otherwise. Verify a capture by *content*, not by exit code: put a value in the payload no real session would produce (`12.5`) and grep the live file for it.

    **Any non-empty value is honoured, including a relative path; only unset or empty means the real directory.** There is deliberately no path validation — rejecting a malformed value and falling back to the live directory would fail *open*, which is the entire class of accident this removes. The stores tolerate a directory that can't be created; they don't fall back.

    **`rate-limit-highwater.json` is derived state and IS safe to delete** — the app rebuilds it from the next capture; that is the remedy if a bad value gets latched.
  - **`refreshInterval` in the statusLine config re-runs the script on a timer**, not just on assistant responses. Set to 30s, because between captures Burnline extrapolates from local tokens alone and undershoots any usage that happened off this Mac.
  - ⚠️ **Only sessions that render a status line publish captures. The desktop app's headless sessions do NOT.** Corrected 2026-08-12 — an earlier note here claimed the opposite ("the desktop app runs the script… abundance, not scarcity, is the failure mode") and it was wrong. **Measured:** with only desktop sessions running, the helper was not invoked for 40 minutes (its atime sat still); one turn in a terminal `claude` session produced a capture within seconds and moved the figure **69% → 74%**, the exact number `/usage` was showing while the app looked stuck. Fits the docs — the status line renders *"in its own row above the built-in footer badges"*, and a headless session has no footer.
    - **The failure mode is scarcity.** Quota burned in the desktop app is real but invisible; the file freezes at whatever the last terminal session left. **Burnline is only as fresh as your last turn in a session that renders a status line.** The popover says so past the staleness threshold.
    - **Still true:** several *terminal* sessions each write this one file on their own timer with no arbitration, and a session's `rate_limits` is a cached snapshot that only refreshes when *that session* calls the API — so an idle one republishes forever. `RateLimitHighWater` defends the value; **don't bypass it and read the file directly.**
  - **One capture file per session: `captures/<session_id>.json`.** The shared `rate-limits.json` is still written and still competes (the rollback script writes only it, as does a payload with no `session_id`), but per-session files are what stop an idle session's clobber. High water was already keeping the correct *value*; what it could not fix is the **age** — dating pinned to the idle session's last turn fires a false "nothing is reporting" nudge. Selection is `CaptureDirectory.freshest(of:)` over dated candidates. **Change resolution, change the probe too** — wiring only `UsageStore` left the probe disagreeing with the app in exactly the case the feature exists for.
  - **`rate-limit-highwater.json` is versioned; a mark from an older build is discarded, never migrated.** Pre-versioning files have no `version` key so the decode fails, which *is* the migration. Testing this needs a **positive control** — "discarded" and "loaded but equal" look identical otherwise.
  - ⚠️ **A SECOND SOURCE EXISTS: `~/.claude.json` → `cachedUsageUtilization`.** Plain local file, no credentials, no network. Carries `seven_day`, `five_hour`, an **explicit `fetchedAtMs`** (so it needs none of the dating heuristics below), Anthropic's own `severity`, and **`limits[kind=weekly_scoped]` — the per-model weekly limit the statusline payload omits entirely.** Read via `UtilizationStore`, converted by `asCapture()` into the normal pipeline; it is a **peer**, competing on age, never the primary — the field is undocumented and **does not self-refresh** (measured frozen 5+ min; `/usage` refreshes it).
    - ⚠️ **The two sources report the same window to different precision** — statusline `1786690800`, utilization `…06:59:59.424563Z`, 0.58s apart. `RateLimitHighWater` compares reset instants with a **60s tolerance** for exactly this reason; exact equality silently gave each source its own mark and lost stale-session protection. Found only by running against real data.
    - ⚠️ **`resets_at` has SIX fractional digits.** Needs `.withFractionalSeconds`; a bare `Z` form needs the formatter *without* it. Both required or the source goes dark silently.
    - ⚠️ **`NSHomeDirectory()` ignores `$HOME`** just like `FileManager.urls(for:in:)`. Use **`BURNLINE_CLAUDE_CONFIG`** to point at a test config — otherwise you are reading the user's real one, which holds hundreds of project paths (client names). Never copy, log, or diagnose with that file.
  - **A capture is dated by its session's last API response** (`TranscriptDating`). An assistant message *is* an API response, so the last assistant turn at or before the observation is when `rate_limits` was minted — exact, unlike the five-hour rule, and it works when `five_hour` is absent or the replay is under five hours old. Both rules apply and the **earlier wins**. `sessionId`/`transcriptPath` are optional with no version bump. **Dating belongs in the app, never the helper** — it is file I/O in a path that runs every 30s in every session.
- **Never put a hardcoded color on the menu bar label.** macOS renders it against a light or dark bar depending on the user's wallpaper and tints template content automatically. Hardcoded violet or green is unreadable on one of them. The popover is hardcoded dark; all color lives there. These two rules look contradictory and are both correct.
- **Buckets are 15 minutes and window totals sum whole buckets**, so a bucket straddling the reset counts all-in or all-out — bounded at 0.15% of a week. Don't "fix" this by summing partial buckets; the sub-bucket detail was never stored.

## Commands

```bash
swift test                 # run the Swift Testing suite
swift run BurnlineProbe    # print a Snapshot from the real transcripts
./build.sh --install       # release build, assemble bundle, sign, install to /Applications
```

**Built with SwiftPM, not Xcode.** Four targets: `BurnlineCore` (library, all logic, no SwiftUI), `Burnline` (executable, SwiftUI only), `BurnlineProbe` (CLI diagnostic), `BurnlineStatusline` (the capture helper, shipped as `Contents/MacOS/burnline-statusline`). `build.sh` assembles the `.app` bundle around the SPM binaries. There is no `.xcodeproj` and adding one would break CLI builds and tests.

**Signing is inside-out.** `build.sh` signs `burnline-statusline` *before* the `.app`. Signing a container before its nested code invalidates the container's seal, and that is the most common cause of a notarization rejection. `codesign --verify --deep --strict` prints a `--validated:` line for the helper when this is right.

## Design language

Dark family, hardcoded, **no light-mode toggle** — the popover stays dark in macOS light mode, per `~/Projects/DESIGN-STANDARDS.md`. Accent violet `#7C5CFF` (every other portfolio accent is claimed; a cool hue avoids colliding with the green/amber/red the delta needs). Surfaces `#0a0a0f`/`#12121a`, hairlines white @ 8%, SOFT radius camp (card 12 / control 10 / row 8). SF Pro only, `.monospacedDigit()` on every figure. **Status never by color alone** — the delta always carries word + arrow + color.
