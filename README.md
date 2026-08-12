# Burnline

A macOS menu bar app that shows where you *should* be in your Claude weekly usage window, next to where you actually are.

```
64/65
```

64% consumed, 65% of the week elapsed — 1 point under budget.

## Why

A weekly limit resets on a fixed weekday and time. Seven days is 100%, so each day is ~14.3%. On day 5 you're ~71% through the window. `/usage` tells you the actual number but nothing tells you the pace target to judge it against, and neither is visible without stopping what you're doing.

## Where the numbers come from

**The pace half is exact.** Calendar arithmetic. It cannot be wrong.

**The usage half comes from one of three sources, and the popover always says which is in play.**

1. **Live** — Anthropic's own percentage and the true reset instant, from either of two local sources, whichever is fresher:
   - Claude Code pipes session JSON to a [statusline command](https://code.claude.com/docs/en/statusline) on every response, carrying `rate_limits.seven_day.{used_percentage,resets_at}`. The `burnline-statusline` binary, shipped inside `Burnline.app`, captures it.
   - `~/.claude.json` holds a `cachedUsageUtilization` block with its own timestamp, and — uniquely — the per-model weekly limit that the statusline payload omits.

   This is the normal state.
2. **Calibrated** — no usable capture, but you've typed `/usage` readings in by hand. Fallback.
3. **Pace only** — neither. The clock target alone, which is useful on its own.

A capture does the whole job by itself: the true percentage, plus — paired with the local token count at that instant — the units-per-percent needed to carry it forward. Nothing to configure, and the reset schedule sets itself from `resets_at`.

Between captures the app extrapolates from token counts in `~/.claude/projects/**/*.jsonl`, which see only **Claude Code on this Mac**. claude.ai in a browser, the desktop app, and other machines are invisible to them. Every capture that lands is account-wide and corrects for all of it; only the forward extrapolation is blind. Past an hour the popover says "Extrapolated" rather than "Live".

## What Burnline reads, and what it never does

Everything above comes from files already on your Mac. Burnline holds no credentials, sends no telemetry, and never transmits anything it reads.

It reads three things, all locally:

- `~/.claude/projects/**/*.jsonl` — transcript token counts, for the estimate between captures
- `~/Library/Application Support/Burnline/` — its own captures, cache and settings
- `~/.claude.json` — **one field**, `cachedUsageUtilization`. That file also contains a list of your project paths; Burnline does not read, store, or transmit it

**One optional setting makes network activity happen indirectly, and it is off by default.** "Refresh usage automatically" spawns a short-lived Claude Code session that runs `/usage`, because a stale figure otherwise has nothing to correct it — measured sitting 2h18m behind reality. It costs no model tokens (`/usage` produces no assistant turn), but it does start real Claude Code sessions, and those talk to Anthropic. With the setting off, Burnline makes no network requests of any kind.

## Build

```bash
swift test
```

```bash
./build.sh --install
```

`--install` is what copies to `/Applications` — plain `./build.sh` only assembles the bundle in `build/`. Launch-at-login is a toggle in Settings.

Built with SwiftPM, not Xcode. Four targets: `BurnlineCore` (all logic, no SwiftUI), `Burnline` (the app), `BurnlineProbe` (a CLI that prints a Snapshot off the real transcripts — the fastest way to see what the app is seeing), `BurnlineStatusline` (the capture helper, shipped inside the app bundle).

```bash
swift run BurnlineProbe
```

## Docs

- In-repo agent notes: [`CLAUDE.md`](CLAUDE.md)
- Architecture, changelog, backlog: Obsidian `Project Notes/Burnline/` — `ARCHITECTURE.md` is the source of truth
- Design spec: [`docs/superpowers/specs/2026-08-11-burnline-design.md`](docs/superpowers/specs/2026-08-11-burnline-design.md) — **partly superseded**; its founding premise was that usage data wasn't available at all
