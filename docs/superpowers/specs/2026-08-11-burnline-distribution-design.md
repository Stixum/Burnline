# Burnline — Public Distribution Design Spec

> Status: **APPROVED 2026-08-11, NOT YET IMPLEMENTED.**
>
> Covers taking Burnline from a locally-built personal tool to a public GitHub
> Releases download. Companion to `2026-08-11-burnline-design.md` (the product
> design); this spec changes nothing about what the app computes or displays,
> only how it is signed, packaged, delivered, updated, and set up on a machine
> that has never seen it before.

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

### Displays

- Which source is currently in play (`.live` / `.calibrated` / `.paceOnly`)
- Whether a `statusLine` is configured in `~/.claude/settings.json`, and whether
  it points at this bundle
- A live indicator: *capture detected N seconds ago*, or *no capture yet*

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

Sparkle is a dynamically loaded framework that makes a network request. These must
be corrected **in the same commit that adds it**:

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
- **Privacy note**, in the README rather than a separate file nobody opens: the app
  is unsandboxed, it reads `~/.claude`, why that is required, and that nothing read
  is ever transmitted. Strangers will ask, and the answer is good.
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
