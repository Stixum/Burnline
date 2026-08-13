# Burnline — Public Distribution Design Spec

> Status: **APPROVED 2026-08-11. Plan 4 shipped; Plans 5–7 outstanding.**
>
> Covers taking Burnline from a locally-built personal tool to a public GitHub
> Releases download. Companion to `2026-08-11-burnline-design.md` (the product
> design); this spec changes nothing about what the app computes or displays,
> only how it is signed, packaged, delivered, updated, and set up on a machine
> that has never seen it before.
>
> ## Revision note — 2026-08-12
>
> The app changed underneath this spec between Plan 4 and Plan 5. Three
> subsystems landed that did not exist when it was written, and each one moves
> something here:
>
> - **A second usage source.** `UtilizationStore` reads `~/.claude.json` →
>   `cachedUsageUtilization`, a peer to the statusline capture competing on age,
>   and the only source carrying the per-model weekly limit. **§5's premise
>   softens:** a user with no statusline configured is no longer necessarily
>   stuck in `.paceOnly`.
> - **`UsagePoller` spawns subprocesses.** Opt-in and off by default, it runs
>   `claude` in a pty and types `/usage` to refresh the anchor. **This is the
>   single largest change to the distribution posture in this document** — the
>   app went from "reads some files" to "can start Claude Code sessions", and
>   §7's privacy note grows from a paragraph to a section because of it.
> - **`BURNLINE_DATA_DIR` and `BURNLINE_CLAUDE_CONFIG` exist.** Every warning in
>   Plans 4–6 about testing being unable to avoid live data is now obsolete;
>   the capture path is safely exercisable.
>
> **§6's "four false claims" task is overtaken and already done.** Those claims
> did not survive to Sparkle — the poller made them false first, while they were
> still published on the README. Corrected 2026-08-12 (commit `1363ce4` and the
> Obsidian notes). Sparkle still adds *dynamic loading*, which remains a separate
> correction when it lands.
>
> **Decisions taken at the same time:** the poller **ships in 1.0**, gated behind
> an explicit first-enable confirmation (§5); spec and plans are revised in place
> rather than superseded.

- **Platform:** macOS 14+, SwiftUI, Swift 6, SwiftPM (no Xcode project)
- **Distribution:** public GitHub Releases + a self-owned Homebrew tap
- **Current state:** ad-hoc signed with hardened runtime, installed only via
  `./build.sh --install` on the author's own Mac

---

## 1. Problem

Burnline works today because of three properties that are all artefacts of never
having left the machine it was built on:

1. **No quarantine.** A locally built bundle copied with `cp -R` never receives
   `com.apple.quarantine`, so Gatekeeper's first-launch gate never fires and the
   ad-hoc signature is never evaluated. A downloaded bundle *is* quarantined.
2. **The statusline capture was installed by hand.** `~/.claude/burnline-statusline.sh`
   was written into place and `~/.claude/settings.json` edited manually. Neither
   step exists for anyone else, and without them the app silently runs in
   `.paceOnly` forever.
3. **`jq` happened to be present.** The capture script is bash and shells out to
   `jq`. macOS only began shipping `jq` in 15; `LSMinimumSystemVersion` is 14.0.

Each of the three fails silently. A stranger on macOS 14 downloads the app, is
blocked by Gatekeeper, works around it, sees a pace-only reading, and has no
signal anywhere explaining why the usage half is missing.

**A fourth silent failure was added after this spec was written** (2026-08-12).
`UsagePoller` resolves the `claude` executable from `PATH` plus four known
locations — a deliberate fix for the fact that a Finder-launched app inherits
roughly `/usr/bin:/bin:/usr/sbin:/sbin` and never sees Homebrew. That covers the
common installs. It does not cover nvm, asdf, or a custom prefix, and when it
misses, the poll does nothing forever and the only diagnostic is the
`BURNLINE_POLL_LOG` environment variable. **A user who enables the setting and
gets silence cannot tell that from a working poller with nothing to do** —
exactly the failure class Plan 4 existed to remove, reintroduced in a new place.
Plan 5 surfaces it.

### Non-goals

- **Not** an App Store release. Sandboxing would sever read access to `~/.claude`,
  which is the only data source. Developer ID distribution is the correct channel
  and does not require the sandbox.
- **Not** a `.pkg` installer. It needs a second certificate type (Developer ID
  *Installer*), reads as heavyweight for a menu bar app, and its `postinstall`
  runs as root — precisely wrong for writing into a user's `~/.claude`. Onboarding
  belongs in the app, where it runs as the user and can refuse unsafe edits.
- **Not** submission to `homebrew-cask` proper. Its acceptance criteria (notability,
  release history) are not met by a day-old project. A self-owned tap has no such
  gate and is trivially upgradeable to the main repo later.
- **No telemetry, ever.** Not analytics, not crash reporting, not a system profile
  with the update check.

---

## 2. Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Audience | Public GitHub Releases, repo goes public | Stated goal |
| Signing | Developer ID Application + notarization + stapling | Only way a downloaded bundle launches cleanly |
| Primary artefact | Notarized DMG | One download, obvious install gesture, launches offline |
| Convenience path | Homebrew cask on `Stixum/homebrew-tap` | `brew upgrade`, clean uninstall, no acceptance gate |
| Capture mechanism | Helper binary inside the `.app` | Removes `jq`; versioned with the app |
| Onboarding | In-app first-run window that writes the config | Only path where a stranger succeeds unaided |
| Auto-update | Sparkle, **deferred to 1.1** | Highest-risk item; must not block the first release |
| Release automation | Local `release.sh` | Keeps the Developer ID cert out of GitHub secrets |
| `UsagePoller` in 1.0 | **Ships, off by default, first-enable confirmation** | Solves a measured 2h18m staleness; spawning processes warrants an explicit yes (§5) |

### Release sequencing

- **1.0** — notarized DMG, Homebrew tap, capture helper, first-run onboarding,
  public repo. Fully shippable and updatable via `brew upgrade`.
- **1.1** — Sparkle.

Sparkle is sequenced second because it is the only item whose risk is unbounded:
`Sparkle.framework` carries XPC services that an Xcode build phase would normally
place and sign, and this project has no Xcode project. If that fight goes badly it
must not hold a working release hostage.

---

## 3. Signing and notarization

The current `build.sh` greps for a `Developer ID Application` identity and falls
back to ad-hoc. The fallback stays (it keeps `swift build` usable on a machine
without the cert) but the release path must refuse it.

### Prerequisites

- **Developer ID Application certificate**, issued from the Apple Developer
  portal. Included in the existing paid membership at no extra cost. The Mac
  currently holds only `Apple Development: Sean McCauley (ZQU4QNRVLL)`, which
  cannot notarize.
- **Notary credentials** stored once via `xcrun notarytool store-credentials`,
  using an **App Store Connect API key** (`.p8`) rather than an app-specific
  password. Keys survive Apple ID password rotation; app-specific passwords do not.

### Signing order

Codesigning is inside-out. Signing a container before its contents invalidates the
container's seal, and this is the single most common cause of notarization
rejection:

1. Any bundled XPC services (1.1, with Sparkle)
2. `Contents/Frameworks/Sparkle.framework` (1.1)
3. `Contents/MacOS/burnline-statusline`
4. `Contents/MacOS/Burnline`
5. The `.app` itself

All with `--options runtime --timestamp`. Hardened runtime is already enabled and
is a notarization requirement. No `com.apple.security.get-task-allow` entitlement
may survive into a release build.

### Notarization order

Notarizing a DMG does not notarize the app inside it, and a DMG built from an
unstapled app ships an unstapled app. Both need their own ticket:

1. `ditto -c -k --keepParent` the signed `.app` to a zip
2. `notarytool submit --wait` the zip
3. `stapler staple` the `.app`
4. Build the DMG **from the stapled app**
5. `notarytool submit --wait` the DMG
6. `stapler staple` the DMG

### Verification gate

`release.sh` aborts unless all three pass:

- `codesign --verify --deep --strict --verbose=2` on the `.app`
- `spctl -a -vvv -t install` reports `source=Notarized Developer ID`
- `xcrun stapler validate` on both the `.app` and the DMG

**These are necessary and not sufficient.** See §8.

---

## 4. Capture helper — `BurnlineStatusline`

A fourth SwiftPM executable target, built into
`Burnline.app/Contents/MacOS/burnline-statusline`, replacing
`~/.claude/burnline-statusline.sh`.

### Responsibility

Read Claude Code session JSON on stdin. Two jobs, unchanged from the bash script:

1. If `rate_limits.seven_day.used_percentage` is present, write the capture to
   `~/Library/Application Support/Burnline/rate-limits.json`.
2. Print a status line to stdout.

### Why a binary rather than the script

- **Removes `jq`.** The script's `jq` invocations are the only external
  dependency in the entire product, and their failure mode is silence: `jq` missing
  means no capture, no error, and a permanently pace-only app. `LSMinimumSystemVersion`
  can honestly stay at 14.0.
- **Lives inside the bundle.** The script sits outside the app, so no app update
  can ever change it. A user who installed 1.0 would run 1.0's capture logic
  forever. In `Contents/MacOS/` it is versioned with the app and updated by
  `brew upgrade` or Sparkle.
- **Typed decode.** `Codable` against a fixture corpus, testable in the existing
  suite, rather than untested `jq` filters.

### Correctness rules

- **Write atomically** — tmp file plus `mv -f`, preserving the existing contract.
  The app reads this file on a 10s timer and must never observe a partial write.
- **Never exit non-zero and never write to stderr on the normal path.** Claude Code
  renders statusline failure inline in the user's terminal; a crash here is far
  more visible and more annoying than a missed capture.
- **`rate_limits` absent → skip the capture, still print a line.** It is absent on
  non-Pro/Max plans and before a session's first API response. This is normal, not
  an error.
- **`five_hour` absent → emit `null`.** Already handled; some plans lack it.
- **Output format is a 1:1 port** of the bash version's status line. It is in daily
  use and the formatting is settled.

### Path stability

The command written into `settings.json` is an absolute path into
`/Applications/Burnline.app`. If the user moves the bundle, the statusline breaks.
The onboarding window (§5) detects a stale path on launch and offers to repair it;
this is why it must resolve the path from `Bundle.main` rather than hardcoding it.

---

## 5. First-run onboarding

A new `Window` scene, opened via `openWindow(id:)` **plus `NSApplication.activate`**
— `SettingsLink` and the `Settings` scene silently no-op in an `LSUIElement`
process, a trap this project already hit and documented.

Shown automatically on first launch, and reachable from the popover thereafter.

### Revised premise — 2026-08-12

This section was written when the statusline capture was the only way to a real
number, so onboarding was pass/fail: wire it or sit in `.paceOnly` forever.
`UtilizationStore` changed that. A user who configures nothing may still get a
live figure from `~/.claude.json`, because Claude Code writes
`cachedUsageUtilization` whether or not Burnline is involved.

**The statusline is still the path to recommend, and onboarding should still
push it** — it is event-driven, free, updates on every response, and needs no
subprocess. The utilization file does not self-refresh; it goes stale until
something runs `/usage`. So the framing changes from *"do this or the app cannot
work"* to *"do this and the app works properly"*, which is both true and a
better thing to say to a stranger.

Onboarding must therefore show **which sources are actually feeding the figure**,
not merely whether the statusline is wired.

### Displays

- Which source is currently in play (`.live` / `.calibrated` / `.paceOnly`)
- Whether a `statusLine` is configured in `~/.claude/settings.json`, and whether
  it points at this bundle
- A live indicator: *capture detected N seconds ago*, or *no capture yet*
- Whether `~/.claude.json` is supplying a utilization reading, and its age
- **Whether the `claude` executable was found**, if the poller is enabled — see
  §1's fourth silent failure. A poller that can never run must say so here rather
  than in an environment variable.

### The poller's first-enable confirmation

**Decided 2026-08-12: the poller ships in 1.0, behind an explicit confirmation
the first time it is switched on.**

Off by default is the right posture and stays. But "off by default" protects a
user who never touches the setting; it says nothing to one who flips it because
the label sounded useful. Spawning Claude Code sessions on someone's machine is a
different category of act from reading files, and the person doing it should know
that before it happens, not discover it in a process list.

The confirmation states: it starts short-lived Claude Code sessions; those
sessions talk to Anthropic; it costs no model tokens because `/usage` produces no
assistant turn; it runs at most once per the configured interval; and it can be
turned off again at any time. Confirm/cancel, and cancelling leaves the setting
off.

Shown once per enable, not once ever — a user re-enabling it a year later on a
new machine deserves the same sentence.

### "Set up automatically"

Writes `~/.claude/settings.json`:

```json
"statusLine": {
  "type": "command",
  "command": "<Bundle.main path>/Contents/MacOS/burnline-statusline",
  "refreshInterval": 30
}
```

`refreshInterval: 30` is deliberate and load-bearing: between captures the app
extrapolates from local tokens alone and undershoots any usage that happened off
this Mac.

Behaviour by state:

| Existing `settings.json` state | Action |
|---|---|
| No file | Create it with only the `statusLine` key |
| File, no `statusLine` key | Add the key, preserve everything else verbatim |
| `statusLine` is ours, path current | No-op, report already configured |
| `statusLine` is ours, path stale | Update the path |
| **`statusLine` is someone else's** | **Refuse.** Show their command, offer the snippet to merge by hand |
| Malformed JSON | Refuse, surface the parse error, offer the manual snippet |

**A backup is written to `settings.json.burnline-backup-<epoch>` before any write.**

The refusal case is the important one. Silently replacing a user's existing
statusline is the single most damaging thing this app could do to a stranger's
setup, and it is unrecoverable without the backup. Burnline never wins that
conflict on its own.

### Manual path

The exact JSON snippet, with a copy button, is visible at all times regardless of
whether the automatic route succeeded. Users who decline to let an app edit their
config are being reasonable and must not be second-class.

---

## 5a. Permissions at install time

Audited 2026-08-12. **Burnline requests no macOS permissions, and on a clean
machine the core function produces no prompts at all.** That is worth stating in
the README rather than leaving a reader to wonder.

Why it holds:

- **No TCC-gated API is used anywhere.** No camera, location, contacts,
  calendar, notifications, Accessibility, Screen Recording or AppleScript.
  `Info.plist` declares no `NS*UsageDescription` key, and none is needed.
- **Everything read is a home dotfile.** `~/.claude/projects/**`,
  `~/.claude.json`, and the app's own Application Support directory.
  `~/Documents`, `~/Desktop` and `~/Downloads` are TCC-protected; a dotfolder is
  not. **This is the concrete payoff of being unsandboxed** — the app reads its
  only data source with no entitlement, no prompt, and no Full Disk Access.
- **Writing `~/.claude/settings.json` needs no permission either.** It is a trust
  question, not an OS one, and §5's refuse-to-clobber rule is the answer.

### The one sharp edge: the poller's child process

`UsagePoller` spawns `claude` with `currentDirectoryURL` set to the home
directory. Spawning needs no permission — but **macOS attributes a child's TCC
requests to the responsible process, which is Burnline.** If Claude Code touches
a protected location while running under the poller, the prompt a user sees will
say *Burnline* wants access to their Documents, and a denial will be recorded
against Burnline rather than against Claude Code.

⚠️ **CORRECTED 2026-08-12, hours after the paragraph above was written, which
claimed this "has not been observed". It has. It is happening on the author's own
machine.** Burnline prompts for **Documents, Desktop and Downloads**. The poller
is enabled here, so the child has been running on a timer all along; the audit
that concluded "zero prompts" checked for TCC-gated APIs *in our own code*, which
is not the same question as *what does the user see*. **A permission audit that
does not include the processes you spawn is not a permission audit.**

**Mechanism:** `currentDirectoryURL` is `$HOME`, and Claude Code enumerates its
working directory at startup. From `$HOME` that means the protected folders. The
existing comment shows the trade being made knowingly in one direction only:
*"an unfamiliar directory makes Claude Code open a trust prompt … Home is already
a known project."* Home avoids a hidden trust dialog and buys TCC prompts
instead.

**This is a release blocker.** A menu bar usage meter that asks a stranger for
their Documents on first run does not get a second chance.

### The fix, measured 2026-08-12

`claude --print` **skips the workspace trust dialog** — stated in `--help` —
which removes the only reason `$HOME` was chosen. Measured, running
`claude -p "/usage" --model haiku` from an untrusted scratch directory:

- exit 0, **no trust dialog**, no pty, seconds rather than the 18s + 8s the TUI
  path waits out
- **no project entry added** to `~/.claude.json` (252 before, 252 after) — print
  mode does not register the directory, so it does not pollute the user's config
- it printed the authoritative figures, including the per-model line:
  `Current week (all models): 82% used · resets Aug 14 at 1:59am`

**One caveat that decides the design:** it did **not** move
`cachedUsageUtilization.fetchedAtMs`. So print mode does not refresh the JSON
field the current poller exists to refresh — but it prints the same numbers
directly, and more of them.

Two candidate designs, both of which fix the TCC problem:

1. **Keep the pty, move the cwd** to a scratch directory and accept a trust
   dialog risk. Smaller change, keeps the JSON-cache mechanism, but the trust
   dialog is exactly the invisible hang the original comment warned about.
2. **Replace the pty with `claude -p "/usage"` and parse stdout.** Removes the
   pty, the 26s of delays, the `$HOME` cwd and the TCC prompts in one move, and
   gains the per-model figure. Cost: parsing human-readable output, which is
   fragile — though no more so than depending on an undocumented JSON field.

**Recommended: (2), behind tests over captured `/usage` output**, with the
existing utilization source kept as the peer it already is so a format change
degrades rather than blinds the app.

### Launch at login

`SMAppService.mainApp.register()` shows no approval dialog. It creates an entry
under System Settings → General → Login Items, and macOS posts a notification
saying Burnline added one. ⚠️ **A user can disable it there, and `register()`
does not obviously report that afterwards** — the Settings toggle can therefore
disagree with reality. Not a blocker for 1.0; worth a look before anyone asks
why launch-at-login "stopped working".

### What this means for the install experience

A notarized DMG, dragged to Applications and launched, should produce **zero
permission dialogs** — no Gatekeeper warning (notarized and stapled), no TCC
prompt, no login-item approval. The only dialog Burnline shows on a fresh
install is its own onboarding window. Any prompt beyond that is a finding, and
Plan 6 Task 8 should treat it as one.

## 6. Sparkle (1.1)

### Mechanics

- First external dependency the project has ever taken. `Package.swift` currently
  declares none.
- `Sparkle.framework` must be copied into `Contents/Frameworks/` **by `build.sh`
  explicitly** — the Xcode build phase that normally does this does not exist here.
  Its embedded XPC services must be signed before the framework, which must be
  signed before the app (§3).
- `generate_keys` produces an EdDSA keypair; the private key lives in the login
  keychain, `SUPublicEDKey` goes in `Info.plist`, and `sign_update` signs each
  release for the appcast.
- Appcast at `docs/appcast.xml` served by GitHub Pages — a stabler URL than a
  release asset.
- `SUSendProfileInfo` **false**. A tool whose entire purpose is watching your usage
  data must not transmit a system profile.
- The update sheet needs `NSApplication.activate` before presentation, the same
  `LSUIElement` trap as Settings.
- `CFBundleVersion` drives Sparkle's comparison and must increase monotonically.
  It is `1` today.

### Consequence: four documented claims become false

> **✅ OVERTAKEN 2026-08-12 — this task is already done, and not by Sparkle.**
> `UsagePoller` made all four statements false before Sparkle was written, while
> they were still published on the README. Corrected in commit `1363ce4` plus the
> Obsidian notes; `CHANGELOG.md:345` was annotated as a historical record rather
> than rewritten.
>
> **What Sparkle still costs:** *dynamic loading*. `CHANGELOG.md:345`'s
> "no dynamic loading" and the reasoning in `build.sh`'s hardened-runtime comment
> both need a further pass when the framework is embedded. The network half is
> already spent.
>
> **The lesson, which is the reason this note is kept rather than deleted:** a
> documented property that a *planned* feature will cost is worth re-checking
> against the code every time you touch it. Something else may spend it first,
> and the schedule for correcting it silently becomes a schedule for leaving a
> false statement in public.

The original analysis, retained for the record — Sparkle is a dynamically loaded
framework that makes a network request:

| Location | Current text |
|---|---|
| `README.md:29` | "No API calls, no credentials, no network access." |
| `ARCHITECTURE.md:5` (Obsidian) | "unsandboxed, no network access" |
| `Burnline.md:8` (Obsidian) | "unsandboxed, no network" |
| `CHANGELOG.md:345` (Obsidian) | "No networking, no subprocess, **no dynamic loading**" |

Replacement, which is both accurate and still a strong claim:

> No account credentials, no telemetry, and no usage data ever leaves your Mac.
> The only network request Burnline makes is an update check against GitHub.

`build.sh:35`'s comment ("no network, so anything able to inject already runs as
the user") should be revisited at the same time — the reasoning still holds, but
its premise is stated in absolute terms that will no longer be true.

---

## 7. Public repo preparation

- **Scrub `/Users/seanmccauley`** from `docs/superpowers/specs/2026-08-11-burnline-design.md`
  — the only hardcoded personal path in the repo, already flagged in the backlog.
  This spec deliberately uses no absolute personal paths.
- **LICENSE.** MIT unless there is a reason otherwise.
- **Privacy section** — upgraded from a paragraph on 2026-08-12, because what the
  app touches grew. In the README, not a separate file nobody opens. It must
  cover, plainly:
  - Unsandboxed, and *why* — `~/.claude` is a home dotfolder, not TCC-protected,
    so this is what makes the data source reachable at all. Sandboxing would
    break it.
  - The three things read: transcript token counts under
    `~/.claude/projects/**/*.jsonl`; the app's own Application Support directory;
    and **exactly one field of `~/.claude.json`**.
  - ⚠️ **`~/.claude.json` deserves its own sentence.** It also contains a list of
    every project path on the machine — which for many users means client names.
    Burnline reads `cachedUsageUtilization` and nothing else, stores nothing
    else, and transmits nothing at all. Say so explicitly; a reader who knows
    what is in that file will otherwise assume the worst, and would be right to.
  - **The poller, stated honestly.** Off by default. When on, it starts real
    Claude Code sessions that talk to Anthropic. It costs no model tokens
    (`/usage` produces no assistant turn, measured) but it is the one setting
    that makes network activity happen, and the README must not bury that.
  - The standing guarantee: no credentials, no telemetry, nothing read ever
    leaves the machine.

  A first draft of this landed early, in commit `1363ce4`, because the old
  unqualified "no network access" line was already false and could not be left
  standing on a soon-to-be-public page. Plan 6 refines it for an outside reader
  rather than writing it from scratch.
- **README rewritten outward.** Screenshot, `brew install` one-liner, DMG link, and
  **the statusline requirement above the fold** — it is the difference between the
  app working and the app appearing broken.
- **Re-run the secrets audit.** It passed before the private push, but public is a
  different bar and applies to full history: no transcript data, no `rate-limits.json`,
  no capture payloads, no client references.

---

## 8. Testing

The existing 193 tests are unaffected and must stay green.

### New unit tests

**Capture helper decode** — fixtures for: a full payload; `rate_limits` absent;
`five_hour` absent; `used_percentage` present but `resets_at` missing; malformed
JSON; empty stdin. Every case must produce a printed status line and a zero exit.

**`settings.json` merge** — the six rows of the §5 table, plus: unknown top-level
keys preserved byte-for-identical on the round trip; the backup file actually
written before mutation; nested `hooks` config untouched.

### Manual gate — nothing substitutes for this

**Download the released DMG on a different Mac, or at minimum a fresh user account,
and launch it.**

`spctl` and `stapler validate` on the build machine can both pass while a
downloaded copy still fails, because the build machine has the signing identity in
its keychain and the downloaded artefact carries a quarantine attribute the local
one never had. The local checks catch the common errors; only the download proves
the result.

Also verify on that machine: onboarding writes a valid `statusLine`, a capture
lands within 30s of a Claude Code response, and the app transitions from
`.paceOnly` to `.live` without a restart.

---

## 9. Release mechanics

`release.sh`, run locally. Not GitHub Actions — that would require the Developer ID
certificate and its private key as repository secrets, which is a materially worse
security posture than a personal machine for a project with one maintainer.

Steps: version bump → `swift test` → release build → assemble bundle → sign
inside-out → notarize app → staple → build DMG → notarize DMG → staple → verify
(§3) → `sign_update` (1.1+) → `gh release create` with the DMG → update the cask's
version and SHA → update `docs/appcast.xml` (1.1+).

The script aborts on any verification failure rather than publishing an artefact
that will fail on a stranger's Mac.

### Homebrew tap

`Stixum/homebrew-tap`, public, one cask file. Install becomes:

```
brew install --cask stixum/tap/burnline
```

The cask needs a `zap` stanza covering `~/Library/Application Support/Burnline` so
uninstall is clean. It should **not** attempt to remove the `statusLine` key from
`~/.claude/settings.json` — casks cannot safely edit a user's config file, and a
stale key merely prints a "command not found" status line rather than breaking
Claude Code.

---

## 10. Open items

- **Screenshot for the release page** does not exist yet. Worth noting that three
  UI defects in this project were invisible in code review and obvious in a
  picture — the release screenshot is cheap insurance as well as marketing.
- **Sparkle's interaction with `SMAppService` launch-at-login** across an update is
  untested. Registration survived an ad-hoc → hardened-runtime signature change;
  whether it survives a Sparkle in-place replacement is unknown.
- **Support burden is now real.** The `rate-limits.json` multi-writer problem
  (every open Claude Code GUI session republishes its cached `rate_limits` on its
  own timer, so an idle session can publish a stale reading indefinitely) is
  mitigated by `RateLimitHighWater` but will still generate confused reports from
  users comparing Burnline against their own status line. The popover does not
  currently say when it is holding a high-water value against a staler file; that
  backlog item's priority rises with a public release.
