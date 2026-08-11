# Burnline

A macOS menu bar app that shows where you *should* be in your Claude weekly usage window, next to where you actually are.

```
◐ 40/71
```

40% consumed, 71% of the week elapsed — 31 points under budget.

## Why

A weekly limit resets on a fixed weekday and time. Seven days is 100%, so each day is ~14.3%. On day 5 you're ~71% through the window. `/usage` tells you the actual number but nothing tells you the pace target to judge it against, and neither is visible without stopping what you're doing.

## How it works

**The pace half is exact** — calendar arithmetic over a reset weekday and time you configure.

**The usage half is an estimate.** Burnline reads token counts from Claude Code's local transcripts (`~/.claude/projects/**/*.jsonl`), which is exact, but Anthropic doesn't publish how many tokens equal 100% of a weekly limit. So you occasionally paste what `/usage` actually says, and Burnline solves for units-per-percent from that anchor.

Two things this means in practice:

- It only sees **Claude Code on this Mac**. claude.ai in a browser, the desktop app, and other machines are invisible. Calibration absorbs that share as long as it stays roughly constant.
- With no calibration at all, it hides the estimate and shows pure pace, which is useful on its own.

No API calls, no credentials, no network access.

## Build

```bash
./build.sh
```

Builds Release, signs, and installs to `/Applications`. Launch-at-login is a toggle in Settings.

## Docs

- Design spec: [`docs/superpowers/specs/2026-08-11-burnline-design.md`](docs/superpowers/specs/2026-08-11-burnline-design.md)
- Project notes: Obsidian `Project Notes/Burnline/`
