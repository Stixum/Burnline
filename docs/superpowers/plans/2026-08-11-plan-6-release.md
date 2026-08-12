# Burnline Plan 6 — Notarized release + Homebrew tap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn `build/Burnline.app` into a notarized DMG that a stranger can download and launch, published on public GitHub Releases with a Homebrew cask as the convenience path.

**Architecture:** A new `release.sh` sits above the existing `build.sh`. `build.sh` keeps doing exactly what it does now (assemble + sign, ad-hoc fallback intact for day-to-day work); `release.sh` refuses the ad-hoc fallback, signs with Developer ID, notarizes, staples, builds the DMG, notarizes and staples that too, verifies everything, and publishes.

**Tech Stack:** `codesign`, `notarytool`, `stapler`, `hdiutil`, `spctl`, `gh`.

**Spec:** `docs/superpowers/specs/2026-08-11-burnline-distribution-design.md` §3, §7, §9. **Depends on:** Plans 4 and 5 complete — do not publish a release without the onboarding, or the first user experience is a pace-only app with no explanation.

> ## Revision note — 2026-08-12
>
> - **Task 5 Step 4's privacy bullet is now a section**, not a sentence. The app
>   reads `~/.claude.json` and can spawn Claude Code sessions; both need saying
>   out loud. A first draft already landed in commit `1363ce4` — refine it for an
>   outside reader rather than starting over.
> - **Task 5 Step 5 is obsolete.** It said the README's "no network access" line
>   was true for 1.0 and should not be pre-emptively weakened. It was already
>   false when written; `UsagePoller` had made it so. Corrected.
> - **New Task 9** verifies the poller still works from a *notarized, hardened
>   runtime* bundle. Nothing in signing should block `posix_spawn`, but the
>   poller fails silently by design, so an untested assumption here would ship as
>   a feature that quietly never runs.
> - `BURNLINE_DATA_DIR` and `BURNLINE_CLAUDE_CONFIG` now exist, so any warning
>   below about testing being unable to avoid live data is obsolete.

---

## Background for the implementer

**The reason none of this was needed before.** A locally built bundle copied with `cp -R` never receives the `com.apple.quarantine` extended attribute, so Gatekeeper's first-launch gate never fires and the ad-hoc signature is never evaluated. That is why an ad-hoc signed Burnline has worked perfectly for its whole life. **A downloaded bundle is quarantined**, and at that point an ad-hoc signature produces a hard refusal — on recent macOS the dialog says the app is *damaged*, which sends users to delete it rather than to a workaround.

**Signing is necessary but not sufficient.** A Developer ID signature alone still gets a scary first-launch dialog. Notarization (Apple scans the binary and issues a ticket) plus stapling (the ticket is attached to the artefact so it validates offline) is what produces a clean launch.

**Codesigning is inside-out.** Signing a container before its contents invalidates the container's seal. Sign nested binaries first, the `.app` last. Getting this backwards is the most common notarization rejection and the error message is not obvious.

**Notarizing a DMG does not notarize the app inside it.** Both need their own submission and their own staple, in the right order — the app must be stapled *before* the DMG is built from it, or you ship a stapled disk image containing an unstapled app.

**`sudo` will not be needed anywhere in this plan.** If a step seems to want it, something is wrong.

## File Structure

| File | Responsibility |
|---|---|
| `release.sh` | **Create.** The whole release pipeline, with abort-on-failure gates |
| `build.sh` | **Modify.** Extract the bundle assembly so `release.sh` reuses it |
| `LICENSE` | **Create.** MIT |
| `README.md` | **Rewrite.** For an outside reader |
| `docs/superpowers/specs/2026-08-11-burnline-design.md` | **Modify.** Scrub the hardcoded home path |
| `Resources/Info.plist` | **Modify.** Version bump |
| *(separate repo)* `Stixum/homebrew-tap/Casks/burnline.rb` | **Create.** The cask |

---

### Task 1: Obtain the Developer ID Application certificate

The Mac currently holds only `Apple Development: Sean McCauley (ZQU4QNRVLL)`, which cannot notarize.

- [ ] **Step 1: Confirm the starting state**

```bash
security find-identity -v -p codesigning
```

Expected today: one identity, `Apple Development`. You are done with this task when a second line reading `Developer ID Application: Sean McCauley (<TEAMID>)` appears.

- [ ] **Step 2: Create the certificate**

At <https://developer.apple.com/account/resources/certificates/list>, create a **Developer ID Application** certificate. It is included in the existing paid membership at no extra cost — the same account already used for Train Times and TixTrk.

This requires a Certificate Signing Request from Keychain Access (*Keychain Access → Certificate Assistant → Request a Certificate From a Certificate Authority*, saved to disk).

- [ ] **Step 3: Install and verify**

Download the `.cer`, double-click to add it to the login keychain, then:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

Expected: exactly one match. **Record the Team ID** in the parentheses — `release.sh` and `notarytool` both need it.

- [ ] **Step 4: Confirm the private key came across**

```bash
security find-certificate -c "Developer ID Application" -p | openssl x509 -noout -subject
```

Expected: a subject line naming you. If the certificate shows in Keychain Access without a disclosure triangle, the private key is missing and the certificate is unusable — revoke and reissue from the same Mac that generated the CSR.

---

### Task 2: Store notary credentials

- [ ] **Step 1: Create an App Store Connect API key**

At <https://appstoreconnect.apple.com/access/integrations/api>, create a key with the **Developer** role. Download the `.p8` — **it can only be downloaded once**. Note the Key ID and the Issuer ID.

An App Store Connect key is preferred over an app-specific password: it survives Apple ID password rotation, and it can be revoked independently without touching the account.

- [ ] **Step 2: Store it in the keychain**

```bash
xcrun notarytool store-credentials "burnline-notary" \
  --key ~/path/to/AuthKey_XXXXXXXX.p8 \
  --key-id XXXXXXXX \
  --issuer XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX
```

- [ ] **Step 3: Verify**

```bash
xcrun notarytool history --keychain-profile "burnline-notary"
```

Expected: an empty history table rather than `Error: Must provide credentials`.

- [ ] **Step 4: Move the `.p8` out of the way**

Store it in your password manager and delete the copy on disk. It is not needed again — the credentials now live in the keychain. **It must never enter the repo**; add `*.p8` to `.gitignore` as a belt-and-braces measure.

```bash
echo '*.p8' >> .gitignore
git add .gitignore && git commit -m "chore: never commit an App Store Connect key"
```

---

### Task 3: Extract bundle assembly from `build.sh`

`release.sh` needs the same assembly steps without the ad-hoc signing fallback. Duplicating them would guarantee drift.

- [ ] **Step 1: Split `build.sh`**

Move the build + icon + assemble steps into a `assemble_bundle()` function, leaving the signing and `--install` handling in place. Keep `build.sh`'s behaviour byte-identical for the no-arguments and `--install` cases — it is the daily driver.

- [ ] **Step 2: Verify nothing changed**

```bash
./build.sh && codesign -dv --verbose=4 build/Burnline.app 2>&1 | grep -E "Signature|flags"
```

Expected: `Signature=adhoc`, `flags=0x10002(adhoc,runtime)` — unchanged from before the split.

- [ ] **Step 3: Commit**

```bash
git add build.sh
git commit -m "build: extract bundle assembly for reuse by the release script"
```

---

### Task 4: `release.sh` — sign, notarize, staple, package

**Files:**
- Create: `release.sh`

- [ ] **Step 1: Write it**

```bash
#!/usr/bin/env bash
set -euo pipefail

# Release pipeline. Unlike build.sh, this REFUSES to fall back to an ad-hoc
# signature: an ad-hoc bundle works fine locally (a cp -R'd app carries no
# quarantine attribute, so Gatekeeper never evaluates it) and fails hard the
# moment it is downloaded.

APP_NAME="Burnline"
BUILD_DIR="build"
APP="${BUILD_DIR}/${APP_NAME}.app"
DMG="${BUILD_DIR}/${APP_NAME}.dmg"
ZIP="${BUILD_DIR}/${APP_NAME}.zip"
NOTARY_PROFILE="burnline-notary"

cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
echo "==> Releasing ${APP_NAME} ${VERSION}"

# --- 0. refuse to release from a dirty tree ---------------------------------
if [ -n "$(git status --porcelain)" ]; then
  echo "!!! Working tree is dirty. Commit or stash first." >&2
  exit 1
fi

# --- 1. tests must pass -----------------------------------------------------
echo "==> Running tests"
swift test

# --- 2. assemble ------------------------------------------------------------
source ./build.sh --assemble-only

# --- 3. sign with Developer ID, inside-out ----------------------------------
IDENTITY=$(security find-identity -v -p codesigning \
  | grep "Developer ID Application" | head -1 | awk '{print $2}' || true)
if [ -z "${IDENTITY}" ]; then
  echo "!!! No Developer ID Application identity. See plan 6 task 1." >&2
  exit 1
fi
echo "==> Signing with ${IDENTITY}"

# Inside-out: nested code first, the .app last. Signing the container before
# its contents invalidates the container's seal, and that is the single most
# common cause of a notarization rejection.
codesign --force --options runtime --timestamp \
  --sign "${IDENTITY}" "${APP}/Contents/MacOS/burnline-statusline"
codesign --force --options runtime --timestamp \
  --sign "${IDENTITY}" "${APP}"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "${APP}"

# get-task-allow permits a debugger to attach and is an automatic notarization
# rejection. It should never be present, but check rather than assume.
if codesign -d --entitlements - --xml "${APP}" 2>/dev/null | grep -q "get-task-allow"; then
  echo "!!! get-task-allow entitlement present; would be rejected." >&2
  exit 1
fi

# --- 4. notarize the app ----------------------------------------------------
echo "==> Notarizing the app"
rm -f "${ZIP}"
ditto -c -k --keepParent "${APP}" "${ZIP}"
xcrun notarytool submit "${ZIP}" --keychain-profile "${NOTARY_PROFILE}" --wait
xcrun stapler staple "${APP}"
rm -f "${ZIP}"

# --- 5. build the DMG from the STAPLED app ----------------------------------
# Order matters: a DMG built from an unstapled app ships an unstapled app,
# however well the DMG itself is stapled afterwards.
echo "==> Building the DMG"
STAGE="${BUILD_DIR}/dmg"
rm -rf "${STAGE}" "${DMG}"
mkdir -p "${STAGE}"
cp -R "${APP}" "${STAGE}/"
ln -s /Applications "${STAGE}/Applications"
hdiutil create -volname "${APP_NAME}" -srcfolder "${STAGE}" \
  -ov -format UDZO "${DMG}"
rm -rf "${STAGE}"

# --- 6. notarize the DMG too ------------------------------------------------
echo "==> Notarizing the DMG"
xcrun notarytool submit "${DMG}" --keychain-profile "${NOTARY_PROFILE}" --wait
xcrun stapler staple "${DMG}"

# --- 7. verification gates --------------------------------------------------
echo "==> Verifying"
xcrun stapler validate "${APP}"
xcrun stapler validate "${DMG}"
spctl -a -vv "${APP}"

echo "==> Done: ${DMG}"
shasum -a 256 "${DMG}"
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x release.sh
```

- [ ] **Step 3: Run it**

```bash
./release.sh
```

Expected, in order: tests pass; `Signature=Developer ID Application`; notarization `status: Accepted` (typically under two minutes — if it says `Invalid`, run `xcrun notarytool log <submission-id> --keychain-profile burnline-notary` for the specific reason); `The staple and validate action worked!` twice; and `spctl` reporting:

```
build/Burnline.app: accepted
source=Notarized Developer ID
```

**`source=Notarized Developer ID` is the line that matters.** `accepted` alone with a different source means notarization did not actually take.

- [ ] **Step 4: Commit**

```bash
git add release.sh
git commit -m "build: release.sh — Developer ID signing, notarization, stapled DMG"
```

---

### Task 5: Prepare the repo to be public

- [ ] **Step 1: Scrub the hardcoded home path**

```bash
grep -rn "seanmccauley" --exclude-dir=.git --exclude-dir=.build --exclude-dir=build .
```

Expected: one file, `docs/superpowers/specs/2026-08-11-burnline-design.md`. Replace the absolute paths with repo-relative ones. Re-run until the grep is empty.

- [ ] **Step 2: Audit the full history, not just the working tree**

Public exposes every commit, not just `HEAD`.

```bash
git log --all --full-history --oneline -- '*rate-limits.json' '*settings.json' '*.jsonl' '*.p8'
```

Expected: no output.

```bash
git rev-list --all | while read -r c; do
  git grep -l "seanmccauley" "$c" 2>/dev/null
done | sort -u
```

Expected: only the design-spec path, and only in commits before the scrub. If anything else appears — a transcript, a capture payload, a client reference — **stop and rewrite history before publishing**; it cannot be fixed after the fact.

- [ ] **Step 3: Add a LICENSE**

MIT, copyright Sean McCauley, 2026.

- [ ] **Step 4: Rewrite the README for an outside reader**

Structure:
1. One-line description and the `64/65` example
2. **Screenshot of the popover** — take it now; there is no release page without one
3. **Install** — `brew install --cask stixum/tap/burnline` first, DMG link second
4. **Setup** — the statusline requirement, stated plainly and **above the fold**. This is the difference between the app working and the app looking broken, and a user who misses it concludes the latter
5. **Where the numbers come from** — the three ranked sources, kept from the current README; it is good and accurate
6. **Privacy** — unsandboxed, reads `~/.claude`, why that is required, and that nothing read is ever transmitted. Strangers will ask and the answer is good
7. Build-from-source instructions, moved below install

- [ ] **Step 5: Verify the README's claims are still true — against the code, not against this plan**

> ⚠️ **This step previously asserted that "No API calls, no credentials, no
> network access" was true for 1.0 and should not be weakened. That was wrong** —
> `UsagePoller` had already made it false. Corrected 2026-08-12 in `1363ce4`.
> The instruction stands, but as a *check*, not a reassurance.

Re-derive each claim from the current source before publishing:

```bash
grep -rn "URLSession\|Process()\|openpty\|NWConnection\|CFSocket" Sources/
```

Every hit must be accounted for in the README's privacy section. **A claim that
was true when written is not evidence it is true now**, and this file is about to
become the front page of a public repository.

- [ ] **Step 6: Commit and make public**

```bash
git add LICENSE README.md docs/
git commit -m "docs: prepare for public release — license, outward README, path scrub"
git push
```

Then flip the repo to public in GitHub settings.

---

### Task 6: Publish the release

- [ ] **Step 1: Set the version**

```bash
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 1.0" Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion 1" Resources/Info.plist
```

`CFBundleVersion` must increase monotonically on every subsequent release — Sparkle compares it in Plan 7, and a version that goes backwards silently disables updates.

- [ ] **Step 2: Tag and release**

```bash
git tag -a v1.0 -m "Burnline 1.0"
git push origin v1.0
gh release create v1.0 build/Burnline.dmg \
  --title "Burnline 1.0" \
  --notes "First public release."
```

- [ ] **Step 3: Record the checksum**

```bash
shasum -a 256 build/Burnline.dmg
```

The cask needs it in the next task.

---

### Task 7: The Homebrew tap

- [ ] **Step 1: Create the tap repo**

```bash
gh repo create Stixum/homebrew-tap --public \
  --description "Homebrew tap for Stixum projects"
```

The `homebrew-` prefix is required; `brew` maps `stixum/tap` to `Stixum/homebrew-tap`.

- [ ] **Step 2: Write `Casks/burnline.rb`**

```ruby
cask "burnline" do
  version "1.0"
  sha256 "PASTE_THE_SHASUM_HERE"

  url "https://github.com/Stixum/Burnline/releases/download/v#{version}/Burnline.dmg"
  name "Burnline"
  desc "Menu bar app showing Claude usage against the weekly pace target"
  homepage "https://github.com/Stixum/Burnline"

  depends_on macos: ">= :sonoma"

  app "Burnline.app"

  zap trash: [
    "~/Library/Application Support/Burnline",
  ]
end
```

**The `zap` stanza deliberately does not touch `~/.claude/settings.json`.** A cask cannot safely edit a user's config file, and a leftover `statusLine` pointing at a deleted binary merely prints a "command not found" status line — annoying, but it does not break Claude Code. Removing the key wrongly would.

- [ ] **Step 3: Verify the cask**

```bash
brew tap Stixum/tap
brew audit --cask --online stixum/tap/burnline
```

Expected: no offences.

- [ ] **Step 4: Install through it**

```bash
brew install --cask stixum/tap/burnline
```

Expected: downloads, verifies the checksum, installs to `/Applications` with **no Gatekeeper prompt**. A prompt here means notarization or stapling did not take.

- [ ] **Step 5: Add the one-liner to the README and commit**

---

### Task 8: Prove it on a machine that is not this one

**Nothing in Task 4's verification substitutes for this.** `spctl` and `stapler validate` run on the machine that holds the signing identity, against an artefact that has never carried a quarantine attribute. They catch the common errors; only a real download proves the result.

- [ ] **Step 1:** On a different Mac — or at minimum a fresh user account on this one — download the DMG **through a browser**, not `curl`. Only a browser sets `com.apple.quarantine`.

- [ ] **Step 2:** Confirm the attribute is present:

```bash
xattr -p com.apple.quarantine ~/Downloads/Burnline.dmg
```

Expected: a value. **If this errors, the test is invalid** — you did not download it the way a user will.

- [ ] **Step 3:** Open the DMG, drag to Applications, launch.

Expected: **it opens.** No "damaged" dialog, no "unidentified developer" dialog, no right-click → Open workaround.

- [ ] **Step 4:** Confirm onboarding appears and the whole Plan 5 flow works from a cold start.

- [ ] **Step 5:** Test offline. Disconnect from the network and launch again — a stapled ticket validates without a round trip, and this is what proves the staple rather than a lucky online check.

---

### Task 9: Verify the poller survives notarization

**Files:** none — this is a verification gate.

The poller spawns `claude` via `Process` + `openpty` from inside a hardened
runtime, Developer ID signed, notarized bundle. Nothing in that should block
process creation — hardened runtime restricts code *injection*, not spawning —
but **the poller is silent by design when it fails**, so an assumption here would
ship as a feature that quietly never runs on anyone's machine but yours.

- [ ] **Step 1:** On the test machine from Task 8, enable "Refresh usage
      automatically" and confirm through the new first-enable dialog.
- [ ] **Step 2:** Launch with the diagnostic log:
      `BURNLINE_POLL_LOG=/tmp/poll.log open -a Burnline`
- [ ] **Step 3:** Wait for a poll and read the log. Expected: `launched pid …`,
      not `FAILED: claude not found` or an `openpty` failure.
- [ ] **Step 4:** Confirm `~/.claude.json`'s `fetchedAtMs` actually moved. A
      launched process that never delivered `/usage` looks identical to success
      in the log alone.
- [ ] **Step 5:** Confirm the poll's own captures went to its throwaway directory
      and **not** to the real Application Support directory — the isolation that
      stops it laundering a stale reading as fresh.

---

## Done when

- [ ] `spctl -a -vv` reports `source=Notarized Developer ID`
- [ ] The DMG downloads through a browser and launches with no dialog, on a Mac that never held the signing identity
- [ ] It launches with the network off
- [ ] `brew install --cask stixum/tap/burnline` works end to end
- [ ] `grep -rn seanmccauley` across the working tree and full history is clean
- [ ] The poller spawns successfully from the notarized bundle, and `fetchedAtMs` moves
- [ ] The README's first screen tells a stranger about the statusline requirement
