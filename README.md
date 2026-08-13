# Burnline

A macOS menu bar app that shows where you *should* be in your Claude weekly usage window, next to where you actually are.

```
64/65
```

64% consumed, 65% of the week elapsed — one point under budget.

<img src="docs/images/popover.png" alt="Burnline popover: 0 points under budget, running cool, with a usage bar showing 84% used against an 85% end-of-day target" width="300">

Violet fill is what you've consumed. The solid marker is where you should be *right now*. The translucent band runs out to the end-of-day target — spend into it and the day finishes level.

## Why

A weekly limit resets on a fixed weekday and time. Seven days is 100%, so each day is about 14.3%. On day 5 you're roughly 71% through the window. `/usage` tells you the actual number, but nothing tells you the pace target to judge it against — and neither is visible without stopping what you're doing.

## Install

```bash
brew install --cask stixum/tap/burnline
```

Or download the DMG from [Releases](https://github.com/Stixum/Burnline/releases) and drag it to Applications. It's signed and notarized, so it opens normally — no right-click-to-open dance.

Requires macOS 14 or later.

## Setup — worth two minutes

Burnline reads your usage from files Claude Code already keeps on your Mac. It works immediately, but **one setting makes the number keep itself current**, and without it the figure goes stale and stays stale.

Open Burnline's setup window (it appears on first launch) and click **Set up automatically**. That adds a status line to `~/.claude/settings.json`:

```json
"statusLine": {
  "type": "command",
  "command": "/Applications/Burnline.app/Contents/MacOS/burnline-statusline",
  "refreshInterval": 30
}
```

Claude Code then reports your usage to Burnline after every response.

**Already have a status line?** Burnline won't touch it. It shows you the snippet and lets you merge it yourself — replacing someone's existing status line is not a decision an app should make on their behalf.

## Where the numbers come from

**The pace half is exact.** Calendar arithmetic. It cannot be wrong.

**The usage half comes from one of three sources, and the popover always says which is in play.**

1. **Live** — Anthropic's own percentage and the true reset instant, from either of two local sources, whichever is fresher:
   - the [status line](https://code.claude.com/docs/en/statusline), which Claude Code pipes to a command after every response
   - `~/.claude.json`, which holds a usage block with its own timestamp — and, uniquely, the per-model weekly limit
2. **Calibrated** — no usable reading, but you've typed `/usage` numbers in by hand. A fallback.
3. **Pace only** — neither. The clock target alone, which is useful on its own.

Between readings, Burnline extrapolates from token counts in `~/.claude/projects/**/*.jsonl`. Those see only **Claude Code on this Mac** — claude.ai in a browser, the desktop app, and your other machines are invisible to them. Every real reading is account-wide and corrects for all of it; only the forward extrapolation is blind. Past an hour the popover says "Extrapolated" rather than "Live".

## What Burnline reads, and what it never does

Everything comes from files already on your Mac. Burnline holds no credentials, sends no telemetry, and never transmits anything it reads.

It reads three things:

- `~/.claude/projects/**/*.jsonl` — transcript token counts, for the estimate between readings
- `~/Library/Application Support/Burnline/` — its own captures, cache and settings
- `~/.claude.json` — **one field**, `cachedUsageUtilization`

That last file also contains a list of every project path on your machine. **Burnline reads one field out of it and nothing else** — it doesn't read, store, or transmit the rest.

**Burnline is unsandboxed, deliberately.** `~/.claude` is a home dotfolder rather than a TCC-protected location like Documents or Desktop, so an unsandboxed app can read it with no permission prompt and no Full Disk Access. Sandboxing would sever the only data source. The trade is visible and worth understanding: it's why a clean install asks you for nothing.

**One optional setting makes network activity happen, and it's off by default.** "Refresh usage automatically" starts a short-lived Claude Code session that runs `/usage`, because otherwise a stale figure has nothing to correct it. It uses no message quota — `/usage` produces no assistant turn — but it does start real Claude Code sessions, and those talk to Anthropic. Burnline asks before enabling it. With it off, Burnline makes no network requests at all.

## Build from source

```bash
swift test
```

```bash
./build.sh --install
```

`--install` is what copies to `/Applications` — plain `./build.sh` only assembles the bundle in `build/`.

Built with SwiftPM, not Xcode. Four targets: `BurnlineCore` (all logic, no SwiftUI), `Burnline` (the app), `BurnlineProbe` (a CLI that prints a snapshot from your real transcripts — the fastest way to see what the app sees), and `BurnlineStatusline` (the capture helper that ships inside the bundle).

```bash
swift run BurnlineProbe
```

## Known limitations

These are properties of the approach, not bugs:

- **Between readings, only Claude Code on this Mac is visible.** A real reading corrects for everything the moment it lands; the extrapolation between them is blind.
- **Readings need Claude Code to be running.** An idle day freezes the anchor. The popover states how old the reading is.
- **A reading dies with its window.** Past the reset it describes a period that no longer exists, so it's discarded.

## License

MIT — see [LICENSE](LICENSE).
