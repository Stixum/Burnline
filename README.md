# Burnline

[![Download](https://img.shields.io/badge/download-DMG-7C5CFF)](https://github.com/Stixum/Burnline/releases/latest)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-informational)](https://github.com/Stixum/Burnline/releases/latest)
[![Universal](https://img.shields.io/badge/binary-universal-informational)](https://github.com/Stixum/Burnline/releases/latest)
[![MIT](https://img.shields.io/badge/license-MIT-informational)](LICENSE)

A macOS menu bar app that shows where you *should* be in your Claude weekly usage window, next to where you actually are.

```
64/65
```

64% consumed, 65% of the week elapsed, so you're one point under budget.

<img src="docs/images/popover.png" alt="Burnline popover: 0 points under budget, running cool, with a usage bar showing 84% used against an 85% end-of-day target" width="300">

Violet fill is what you've consumed. The solid marker is where you should be *right now*. The translucent band runs out to the end-of-day target, so if you spend into it the day finishes level.

## Why

A weekly limit resets on a fixed weekday and time. Seven days is 100%, so each day is about 14.3%. On day 5 you're roughly 71% through the window. `/usage` tells you the actual number, but nothing tells you the pace target to judge it against, and neither is visible without stopping what you're doing.

## Install

> ### ⬇️ [Download the latest release](https://github.com/Stixum/Burnline/releases/latest)
>
> Grab `Burnline.dmg`, open it, drag Burnline to Applications. It's signed and notarized, so it opens normally with no right-click-to-open dance.
>
> **Universal binary**, Apple silicon and Intel. Requires macOS 14 or later.

Or with Homebrew:

```bash
brew install --cask stixum/tap/burnline
```

## Setup, worth two minutes

Burnline reads your usage from files Claude Code already keeps on your Mac. It works immediately, but **one setting makes the number keep itself current**, and without it the figure goes stale and stays stale.

The setup window opens on first launch. Click **Set up automatically** and it adds a status line to `~/.claude/settings.json`:

```json
"statusLine": {
  "type": "command",
  "command": "/Applications/Burnline.app/Contents/MacOS/burnline-statusline",
  "refreshInterval": 30
}
```

Claude Code then reports your usage to Burnline after every response.

Dismissed it, or want it later? It's in **Settings, under Status line**, which also shows whether the status line is currently connected. When it isn't, the popover offers a **Set up** link too.

**Already have a status line?** Burnline won't touch it. It shows you the snippet and lets you merge it yourself, because replacing someone's existing status line isn't a decision an app should make on their behalf.

## Where the numbers come from

**The pace half is exact.** Calendar arithmetic. It cannot be wrong.

**The usage half comes from one of three sources, and the popover always says which is in play.**

1. **Live.** Anthropic's own percentage and the true reset instant, from either of two local sources, whichever is fresher:
   - the [status line](https://code.claude.com/docs/en/statusline), which Claude Code pipes to a command after every response
   - `~/.claude.json`, which holds a usage block with its own timestamp and, uniquely, the per-model weekly limit
2. **Calibrated.** No usable reading, but you've typed `/usage` numbers in by hand. A fallback.
3. **Pace only.** Neither. The clock target alone, which is useful on its own.

Between readings, Burnline extrapolates from token counts in `~/.claude/projects/**/*.jsonl`. Those see only **Claude Code on this Mac**: claude.ai in a browser, the desktop app, and your other machines are invisible to them. Every real reading is account-wide and corrects for all of it, so only the forward extrapolation is blind. Past an hour the popover says "Extrapolated" rather than "Live".

## What Burnline reads, and what it never does

Everything comes from files already on your Mac. Burnline holds no credentials, sends no telemetry, and never transmits anything it reads.

It touches four things:

- `~/.claude/projects/**/*.jsonl`, read, for transcript token counts between readings
- `~/Library/Application Support/Burnline/`, read and written, its own captures, cache and settings
- `~/.claude.json`, read, for **one field**, `cachedUsageUtilization`
- `~/.claude/settings.json`, read to see whether the status line is configured, and **written only when you click "Set up automatically"**, with a timestamped backup made first

`~/.claude.json` also contains a list of every project path on your machine. Burnline parses the file to reach `cachedUsageUtilization` and **keeps nothing else from it**: the rest is never stored, logged, or transmitted.

**Burnline is unsandboxed, deliberately.** `~/.claude` is a home dotfolder rather than a TCC-protected location like Documents or Desktop, so an unsandboxed app can read it with no permission prompt and no Full Disk Access. Sandboxing would sever the only data source. The trade is worth understanding, because it's why a clean install asks you for nothing.

**One optional setting makes network activity happen, and it's off by default.** "Refresh usage automatically" starts a short-lived Claude Code session that runs `/usage`, because otherwise a stale figure has nothing to correct it. It uses no message quota, since `/usage` produces no assistant turn, but it does start real Claude Code sessions and those talk to Anthropic. Burnline asks before enabling it. With it off, Burnline makes no network requests at all.

**If you enable it, macOS will ask for access to Documents, Downloads and any cloud drives.** That is Claude Code scanning your home directory when it starts, not Burnline reading your files. **Decline all of them and the feature still works** — verified. Burnline itself only ever reads the four paths listed above.

## Build from source

```bash
swift test
```

```bash
./build.sh --install
```

`--install` is what copies to `/Applications`. Plain `./build.sh` only assembles the bundle in `build/`.

Built with SwiftPM, not Xcode. Four targets: `BurnlineCore` (all logic, no SwiftUI), `Burnline` (the app), `BurnlineProbe` (a CLI that prints a snapshot from your real transcripts, the fastest way to see what the app sees), and `BurnlineStatusline` (the capture helper that ships inside the bundle).

```bash
swift run BurnlineProbe
```

### Where to start reading

Everything funnels through **`SnapshotBuilder`**, which assembles the one immutable `Snapshot` that every view reads. Both the app and the probe go through it, so if you want to know how a number on screen was produced, start there and work outwards:

- `WindowMath` turns a reset schedule and the current time into window bounds and elapsed fraction. Pure calendar arithmetic, and the half of the app that cannot be wrong.
- `TranscriptScanner` walks `~/.claude/projects` incrementally and produces token counts. `ConsumptionModel` weights them.
- `RateLimitHighWater` decides which reading to trust when several sources disagree, which they routinely do.
- `UsagePoller` is the only thing that starts a process, and the only thing that touches the network, indirectly.

Two conventions worth knowing before you change anything. **`BurnlineCore` imports no SwiftUI**, so all the logic is testable without a view; that is enforced by the target graph rather than by discipline. And **views do no arithmetic**: if a number needs computing it belongs in a pure unit with tests, not in a `body`.

The reasoning behind the non-obvious decisions lives in comments next to the code it explains rather than in a separate document, on the grounds that a document drifts and a comment two lines above the code usually doesn't.

## Known limitations

These are properties of the approach, not bugs:

- **Between readings, only Claude Code on this Mac is visible.** A real reading corrects for everything the moment it lands. The extrapolation between them is blind.
- **Readings need Claude Code to be running.** An idle day freezes the anchor. The popover states how old the reading is.
- **A reading dies with its window.** Past the reset it describes a period that no longer exists, so it's discarded.

## License

MIT. See [LICENSE](LICENSE).
