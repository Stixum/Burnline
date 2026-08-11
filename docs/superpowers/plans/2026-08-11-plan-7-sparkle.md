# Burnline Plan 7 — Sparkle auto-updates (1.1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In-app updates for users who did not install via Homebrew, without weakening the privacy posture and without breaking notarization.

**Architecture:** Sparkle 2 as an SPM binary dependency. Because there is no Xcode project, `build.sh` copies `Sparkle.framework` into `Contents/Frameworks/` by hand, the executable is linked with an `@executable_path/../Frameworks` rpath, and `release.sh` signs the framework before the app. Updates are advertised through an appcast on GitHub Pages, signed with an EdDSA key held in the login keychain.

**Tech Stack:** Sparkle 2.x, `generate_keys`, `sign_update`, GitHub Pages.

**Spec:** `docs/superpowers/specs/2026-08-11-burnline-distribution-design.md` §6. **Depends on:** Plan 6 shipped and 1.0 published — you cannot test an update without a previous version to update *from*.

---

## Background for the implementer

**Why this is sequenced last and alone.** It is the only item in the distribution work whose risk is unbounded. Everything else is a known quantity; this one is a first external dependency, a hand-assembled framework embed, and a signing arrangement that Xcode normally handles invisibly. It was deliberately deferred out of 1.0 so that a fight here cannot block a working release.

**A risk reducer worth confirming first.** Sparkle 2's XPC Services (`Installer.xpc`, `Downloader.xpc`) are required only for **sandboxed** apps. Burnline is deliberately unsandboxed — sandboxing would sever read access to `~/.claude`, which is the only data source. If that holds, the embed is a single framework rather than a framework plus two nested service bundles, and the signing order shortens accordingly. **Verify it against Sparkle's current documentation in Task 1 before planning around it** rather than trusting this paragraph.

**The part Xcode normally does for you.** With an Xcode project, a *Copy Files* build phase embeds the framework and a *Code Sign on Copy* checkbox signs it. There is no Xcode project here. `build.sh` must copy the framework and `release.sh` must sign it, in the right order, or the app will either fail to launch (framework not found at runtime) or fail notarization (unsigned nested code).

**Three things break the moment this ships,** and they are corrected in this plan, not left for later:

| Location | Current text |
|---|---|
| `README.md:29` | "No API calls, no credentials, no network access." |
| `ARCHITECTURE.md:5` (Obsidian) | "unsandboxed, no network access" |
| `Burnline.md:8` (Obsidian) | "unsandboxed, no network" |
| `CHANGELOG.md:345` (Obsidian) | "No networking, no subprocess, **no dynamic loading**" |

All four become false. Sparkle is a dynamically loaded framework that makes a network request.

## File Structure

| File | Responsibility |
|---|---|
| `Package.swift` | **Modify.** Sparkle dependency + rpath linker settings |
| `Sources/Burnline/Updater.swift` | **Create.** Wraps `SPUStandardUpdaterController` |
| `Sources/Burnline/SettingsView.swift` | **Modify.** "Check for Updates" + automatic-checks toggle |
| `Resources/Info.plist` | **Modify.** `SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks` |
| `build.sh` | **Modify.** Embed the framework |
| `release.sh` | **Modify.** Sign the framework, sign the update, emit the appcast entry |
| `docs/appcast.xml` | **Create.** The feed, served by GitHub Pages |
| `README.md` | **Modify.** Correct the network claim |

---

### Task 1: Confirm the framework layout before writing any code

Fifteen minutes here decides how much of the rest of this plan is real.

- [ ] **Step 1: Add the dependency**

In `Package.swift`:

```swift
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
```

and on the `Burnline` target:

```swift
        .executableTarget(
            name: "Burnline",
            dependencies: ["BurnlineCore", .product(name: "Sparkle", package: "Sparkle")],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [
                // Xcode would set this via an embed build phase. Without a
                // project file, the executable must be told at link time where
                // to find the framework inside the bundle at runtime.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
```

⚠️ **`.unsafeFlags` makes this package unusable as a dependency of another package.** Nothing depends on Burnline, so this is acceptable — but note it, because the failure message if that ever changes is opaque.

- [ ] **Step 2: Resolve and locate the artefact**

```bash
swift package resolve
find .build/artifacts -name "Sparkle.framework" -maxdepth 6
```

Record the exact path. `release.sh` needs it and it is version-dependent.

- [ ] **Step 3: Inspect what is inside it**

```bash
ls "$(find .build/artifacts -name 'Sparkle.framework' -maxdepth 6 | head -1)/Versions/Current/"
```

**Write down whether `XPCServices` is present and non-empty.** If it is absent — the expected outcome for a non-sandboxed app — the signing order in Task 4 is two commands rather than four. If it is present, sign each `.xpc` bundle before the framework.

Also check for `Autoupdate` and `Updater.app` in `Versions/Current/`; both are nested code that must be signed if present.

- [ ] **Step 4: Verify the app still builds and launches**

```bash
swift build --product Burnline
```

- [ ] **Step 5: Commit**

```bash
git add Package.swift Package.resolved
git commit -m "build: add Sparkle as an SPM dependency"
```

---

### Task 2: Generate the signing keys

- [ ] **Step 1: Find and run `generate_keys`**

```bash
find .build/artifacts -name "generate_keys" -maxdepth 6
```

Run it. It creates an EdDSA private key **in the login keychain** and prints the public key.

- [ ] **Step 2: Record the public key**

It goes in `Info.plist` as `SUPublicEDKey` in the next task.

- [ ] **Step 3: Back up the private key**

```bash
"$(find .build/artifacts -name 'generate_keys' -maxdepth 6 | head -1)" -x /tmp/sparkle-private-key.txt
```

Put the contents in your password manager, then delete the file:

```bash
rm -P /tmp/sparkle-private-key.txt
```

**Losing this key means no existing installation can ever be updated again** — they will reject every future appcast signature and the only path forward is telling users to re-download by hand. This is the single most consequential secret in the project.

⚠️ It must never be committed. `.gitignore` already excludes `*.p8`; add `*private-key*` too.

---

### Task 3: Info.plist and the updater

**Files:**
- Modify: `Resources/Info.plist`
- Create: `Sources/Burnline/Updater.swift`

- [ ] **Step 1: Add the Sparkle keys**

```xml
  <key>SUFeedURL</key><string>https://stixum.github.io/Burnline/appcast.xml</string>
  <key>SUPublicEDKey</key><string>PASTE_PUBLIC_KEY_HERE</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUSendProfileInfo</key><false/>
```

**`SUSendProfileInfo` must be `false`.** A tool whose entire purpose is watching your usage data must not transmit a system profile. This is not a default to leave to chance — set it explicitly so the intent is visible in the file.

- [ ] **Step 2: Write `Updater.swift`**

```swift
import SwiftUI
import Sparkle

/// Sparkle wrapper.
///
/// The update check is the only network request Burnline makes. No telemetry,
/// no profile (`SUSendProfileInfo` is explicitly false in Info.plist) — just a
/// GET of the appcast.
@MainActor
final class Updater {
    static let shared = Updater()

    private let controller = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
    )

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        // LSUIElement processes are never activated, so Sparkle's window opens
        // behind everything and the menu item reads as a dead button — the same
        // trap that made SettingsLink no-op in this app.
        NSApplication.shared.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}
```

- [ ] **Step 3: Add the Settings controls**

A "Check for Updates…" button and an "Automatically check for updates" toggle, following the existing `SettingsView` idiom. Show the current version beside them.

- [ ] **Step 4: Verify the button activates the window**

Build, install, click it. Expected: a Sparkle window appears **in front**. If it appears behind or not at all, the `activate` call is missing or in the wrong place.

- [ ] **Step 5: Commit**

---

### Task 4: Embed and sign the framework

**Files:**
- Modify: `build.sh`, `release.sh`

- [ ] **Step 1: Copy it in `build.sh`**

After the binaries are copied:

```bash
# Xcode would do this with an embed build phase. There is no Xcode project, so
# the framework is copied by hand and the executable carries an
# @executable_path/../Frameworks rpath (see Package.swift) to find it.
SPARKLE=$(find .build/artifacts -name "Sparkle.framework" -maxdepth 6 | head -1)
if [ -z "${SPARKLE}" ]; then
  echo "!!! Sparkle.framework not found; run 'swift package resolve'." >&2
  exit 1
fi
mkdir -p "${APP}/Contents/Frameworks"
rm -rf "${APP}/Contents/Frameworks/Sparkle.framework"
cp -R "${SPARKLE}" "${APP}/Contents/Frameworks/"
```

- [ ] **Step 2: Sign inside-out in `release.sh`**

Insert **before** the existing helper and app signing. Adjust to what Task 1 Step 3 actually found:

```bash
# Deepest first. If XPCServices is absent (expected for a non-sandboxed app)
# these two loops simply match nothing.
for xpc in "${APP}/Contents/Frameworks/Sparkle.framework/Versions/Current/XPCServices/"*.xpc; do
  [ -e "$xpc" ] || continue
  codesign --force --options runtime --timestamp --sign "${IDENTITY}" "$xpc"
done
for nested in "${APP}/Contents/Frameworks/Sparkle.framework/Versions/Current/Autoupdate" \
              "${APP}/Contents/Frameworks/Sparkle.framework/Versions/Current/Updater.app"; do
  [ -e "$nested" ] || continue
  codesign --force --options runtime --timestamp --sign "${IDENTITY}" "$nested"
done
codesign --force --options runtime --timestamp \
  --sign "${IDENTITY}" "${APP}/Contents/Frameworks/Sparkle.framework"
```

- [ ] **Step 3: Verify the signature is valid all the way down**

```bash
./release.sh
```

Expected: `codesign --verify --deep --strict` passes and notarization returns `Accepted`.

If it returns `Invalid`, read the actual reason — do not guess:

```bash
xcrun notarytool log <submission-id> --keychain-profile burnline-notary
```

The two likely entries are `The signature of the binary is invalid` (signing order wrong — a nested item was signed after its container) and `The binary is not signed with a valid Developer ID certificate` (a nested item was missed entirely).

- [ ] **Step 4: Verify it launches**

An app that builds, signs and notarizes can still fail at runtime if the rpath is wrong. Launch from `/Applications` and confirm no `dyld: Library not loaded` crash:

```bash
./build.sh --install && open -a Burnline && sleep 3 && pgrep -f "/Applications/Burnline.app"
```

Expected: a PID. No PID means it crashed on launch — check Console.app for the dyld error.

- [ ] **Step 5: Commit**

---

### Task 5: The appcast

- [ ] **Step 1: Enable GitHub Pages** on `Stixum/Burnline`, serving from `main` / `docs`.

- [ ] **Step 2: Sign the DMG**

```bash
"$(find .build/artifacts -name 'sign_update' -maxdepth 6 | head -1)" build/Burnline.dmg
```

Outputs the `sparkle:edSignature` and length for the appcast entry.

- [ ] **Step 3: Write `docs/appcast.xml`**

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Burnline</title>
    <item>
      <title>1.1</title>
      <sparkle:version>2</sparkle:version>
      <sparkle:shortVersionString>1.1</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure
        url="https://github.com/Stixum/Burnline/releases/download/v1.1/Burnline.dmg"
        sparkle:edSignature="PASTE_SIGNATURE"
        length="PASTE_LENGTH"
        type="application/octet-stream"/>
    </item>
  </channel>
</rss>
```

`sparkle:version` is `CFBundleVersion` and drives the comparison — **it must increase on every release**, independently of the human-facing `1.1`.

- [ ] **Step 4: Automate it in `release.sh`**

Append `sign_update` and the appcast entry generation to the pipeline so a release cannot ship with a stale or unsigned feed.

- [ ] **Step 5: Verify the feed is reachable**

```bash
curl -sSf https://stixum.github.io/Burnline/appcast.xml | head
```

Expected: the XML. A 404 means Pages is not serving `docs/` yet.

---

### Task 6: Correct the four false claims

Do this **in the same commit that ships Sparkle**, not afterwards.

- [ ] **Step 1: `README.md:29`** — replace with:

> No account credentials, no telemetry, and no usage data ever leaves your Mac. The only network request Burnline makes is an update check against GitHub.

- [ ] **Step 2: `build.sh:35`** — the hardened-runtime comment reasons from "no network". The conclusion still holds, but rewrite the premise so it is not stated in absolute terms that are no longer true.

- [ ] **Step 3: Obsidian** — `ARCHITECTURE.md:5`, `Burnline.md:8`, and the security-review paragraph at `CHANGELOG.md:345` ("No networking, no subprocess, no dynamic loading"). All three now need the update-check carve-out.

- [ ] **Step 4: Add a CHANGELOG entry** recording that the no-network property was traded for an update path, and why — it was a deliberate call, and a future reader will otherwise read it as an oversight.

- [ ] **Step 5: Commit**

---

### Task 7: Prove an actual update

The only test that matters. A Sparkle setup that looks perfect can still fail to update anything.

- [ ] **Step 1:** On a Mac that is not the build machine, install **1.0** from the GitHub release.
- [ ] **Step 2:** Publish 1.1 with the updated appcast.
- [ ] **Step 3:** On that Mac, launch 1.0 and click **Check for Updates**. Expected: 1.1 is offered, downloads, installs, and the app relaunches on 1.1.
- [ ] **Step 4:** Confirm the update did not break launch-at-login. `SMAppService` registration survived an ad-hoc → hardened-runtime signature change; whether it survives an in-place Sparkle replacement is **untested and unknown**. Check the Settings toggle still reads correctly and the app still launches after a reboot.
- [ ] **Step 5:** Confirm the statusline still works. The helper's path is unchanged by an in-place update, so `settings.json` should still be valid — verify rather than assume, because Plan 5's `.stalePath` repair exists precisely for when it is not.
- [ ] **Step 6:** Deliberately corrupt the appcast signature and confirm the update is **rejected**. An updater that accepts an unsigned payload is worse than no updater.

---

## Done when

- [ ] Notarization passes with the framework embedded
- [ ] The app launches from `/Applications` with no dyld error
- [ ] A real 1.0 → 1.1 update completes on another Mac
- [ ] A tampered signature is rejected
- [ ] Launch-at-login and the statusline both survive the update
- [ ] All four network claims corrected, in the same commit
- [ ] The private key is in the password manager and not on disk
