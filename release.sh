#!/usr/bin/env bash
set -euo pipefail

# Release pipeline: Developer ID signing, notarization, stapling, DMG.
#
# Unlike build.sh this REFUSES to fall back to an ad-hoc signature. An ad-hoc
# bundle works perfectly on the machine that built it — a cp -R'd app carries no
# com.apple.quarantine attribute, so Gatekeeper never evaluates the signature —
# and fails hard the moment anyone downloads it, with a dialog claiming the app
# is damaged.

APP_NAME="Burnline"
BUILD_DIR="build"
APP="${BUILD_DIR}/${APP_NAME}.app"
DMG="${BUILD_DIR}/${APP_NAME}.dmg"
ZIP="${BUILD_DIR}/${APP_NAME}.zip"
NOTARY_PROFILE="${BURNLINE_NOTARY_PROFILE:-burnline-notary}"

cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Resources/Info.plist)
echo "==> Releasing ${APP_NAME} ${VERSION} (build ${BUILD_NUMBER})"

# --- 0. preconditions ------------------------------------------------------
if [ "${BURNLINE_ALLOW_DIRTY:-}" != "1" ] && [ -n "$(git status --porcelain)" ]; then
  echo "!!! Working tree is dirty. Commit or stash first." >&2
  echo "    (BURNLINE_ALLOW_DIRTY=1 to override for a dry run.)" >&2
  exit 1
fi

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep "Developer ID Application" | head -1 | awk '{print $2}' || true)
if [ -z "${IDENTITY}" ]; then
  echo "!!! No Developer ID Application identity in the keychain." >&2
  echo "    Create one at https://developer.apple.com/account/resources/certificates" >&2
  echo "    (type: Developer ID Application), then double-click the .cer to install." >&2
  exit 1
fi

if ! xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" >/dev/null 2>&1; then
  echo "!!! No notary credentials for profile '${NOTARY_PROFILE}'." >&2
  echo "    xcrun notarytool store-credentials \"${NOTARY_PROFILE}\" \\" >&2
  echo "      --key <AuthKey.p8> --key-id <KEY_ID> --issuer <ISSUER_UUID>" >&2
  exit 1
fi

# --- 1. tests --------------------------------------------------------------
if [ "${BURNLINE_SKIP_TESTS:-}" != "1" ]; then
  echo "==> Running tests"
  swift test
fi

# --- 2. assemble (shared with build.sh, never duplicated) ------------------
BURNLINE_BUILD_LIB=1 source ./build.sh
# Releases are universal. Shipping arm64-only means an Intel user downloads a
# perfectly signed DMG and gets an app that will not open.
BURNLINE_UNIVERSAL=1 assemble_bundle

for binary in "${APP}/Contents/MacOS/Burnline" "${APP}/Contents/MacOS/burnline-statusline"; do
  archs=$(lipo -archs "${binary}")
  case "${archs}" in
    *x86_64*arm64*|*arm64*x86_64*) echo "    $(basename "${binary}"): ${archs}" ;;
    *) echo "!!! $(basename "${binary}") is ${archs}, not universal. Refusing to release." >&2; exit 1 ;;
  esac
done

# --- 3. sign, inside-out ---------------------------------------------------
echo "==> Signing with ${IDENTITY}"
# Nested code first, the .app last. Signing the container before its contents
# invalidates the container's seal — the single most common notarization
# rejection, and its error message does not say so.
codesign --force --options runtime --timestamp \
  --sign "${IDENTITY}" "${APP}/Contents/MacOS/burnline-statusline"
codesign --force --options runtime --timestamp \
  --sign "${IDENTITY}" "${APP}"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "${APP}"

# get-task-allow permits a debugger to attach and is an automatic notarization
# rejection. It should never be present here; check rather than assume.
if codesign -d --entitlements - --xml "${APP}" 2>/dev/null | grep -q "get-task-allow"; then
  echo "!!! get-task-allow entitlement present; notarization would reject this." >&2
  exit 1
fi

# --- 4. notarize the app ---------------------------------------------------
echo "==> Notarizing the app (this takes a few minutes)"
rm -f "${ZIP}"
ditto -c -k --keepParent "${APP}" "${ZIP}"
xcrun notarytool submit "${ZIP}" --keychain-profile "${NOTARY_PROFILE}" --wait
xcrun stapler staple "${APP}"
rm -f "${ZIP}"

# --- 5. DMG, built FROM THE STAPLED APP ------------------------------------
# Order matters: a DMG built from an unstapled app ships an unstapled app,
# however well the DMG itself is stapled afterwards.
echo "==> Building the DMG"
# A laid-out window rather than a bare file listing: background, positioned
# icons, no toolbar. This is the first thing anyone sees, and a default grey
# Finder window beside a hardcoded-dark app reads as two different products.
#
# It has to be built writable, decorated while mounted, then converted to a
# compressed read-only image. hdiutil cannot set any of this directly.
swift Tools/make-dmg-background.swift >/dev/null

STAGE="${BUILD_DIR}/dmg"
RW="${BUILD_DIR}/rw.dmg"
rm -rf "${STAGE}" "${DMG}" "${RW}"
mkdir -p "${STAGE}/.background"
cp -R "${APP}" "${STAGE}/"
ln -s /Applications "${STAGE}/Applications"
cp "${BUILD_DIR}/dmg-background.png" "${STAGE}/.background/background.png"

hdiutil create -volname "${APP_NAME}" -srcfolder "${STAGE}" \
  -ov -format UDRW "${RW}" >/dev/null
MOUNT=$(hdiutil attach "${RW}" -nobrowse -noverify | grep -o '/Volumes/.*' | head -1)

# Finder positions icons by CENTRE, from the window's top-left. These four
# numbers must match Tools/make-dmg-background.swift or the arrow points at
# nothing.
osascript <<EOF >/dev/null
tell application "Finder"
  tell disk "${APP_NAME}"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    -- Outer window bounds, title bar included: 600x428 outer is 600x400 of
    -- content plus a 28pt title bar. The background PNG is 600x445 — the extra
    -- 45pt deliberately overdraws Finder's status bar strip, which cannot be
    -- hidden reliably from AppleScript.
    set the bounds of container window to {200, 150, 800, 578}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set background picture of opts to file ".background:background.png"
    set position of item "${APP_NAME}.app" of container window to {150, 190}
    set position of item "Applications" of container window to {450, 190}
    close
    open
    -- Re-assert after reopening: close/open resets these, which left the status
    -- bar visible and eating ~25pt of the content area, clipping the bottom of
    -- the background.
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 150, 800, 578}
    update without registering applications
    delay 2
  end tell
end tell
EOF

hdiutil detach "${MOUNT}" >/dev/null
hdiutil convert "${RW}" -format UDZO -imagekey zlib-level=9 -o "${DMG}" >/dev/null
rm -f "${RW}"
rm -rf "${STAGE}"

# ⚠️ Sign the DMG itself. `hdiutil create` produces an UNSIGNED image, and
# notarizing plus stapling attaches a ticket without adding a signature. Caught
# 2026-08-12 by stamping com.apple.quarantine on the output by hand and asking
# Gatekeeper: the app inside assessed as `Notarized Developer ID` while the disk
# image around it came back `rejected — no usable signature`. spctl on the
# unquarantined build says nothing about this.
codesign --force --timestamp --sign "${IDENTITY}" "${DMG}"

# --- 6. notarize the DMG too -----------------------------------------------
# Notarizing the app does not notarize the disk image around it.
echo "==> Notarizing the DMG"
xcrun notarytool submit "${DMG}" --keychain-profile "${NOTARY_PROFILE}" --wait
xcrun stapler staple "${DMG}"

# --- 7. verification gates -------------------------------------------------
echo "==> Verifying"
xcrun stapler validate "${APP}"
xcrun stapler validate "${DMG}"
# The line that matters is `source=Notarized Developer ID`. "accepted" with any
# other source means notarization did not actually take.
spctl -a -vv "${APP}"

# Assess the DMG the way a downloaded copy is assessed. Without the quarantine
# attribute Gatekeeper does not evaluate anything, so a plain spctl on the build
# output is close to meaningless — it is the check that missed the unsigned DMG.
echo "==> Verifying as a quarantined download"
QTEST="${BUILD_DIR}/.quarantine-check.dmg"
cp "${DMG}" "${QTEST}"
xattr -w com.apple.quarantine "0083;$(printf %x "$(date +%s)");Safari;$(uuidgen)" "${QTEST}"
if spctl -a -vvv -t open --context context:primary-signature "${QTEST}" 2>&1 | tee /dev/stderr \
     | grep -q "source=Notarized Developer ID"; then
  rm -f "${QTEST}"
else
  rm -f "${QTEST}"
  echo "!!! The DMG fails Gatekeeper when quarantined. Do not publish it." >&2
  exit 1
fi

echo
echo "==> Done: ${DMG}"
shasum -a 256 "${DMG}"
echo
echo "    Next: gh release create v${VERSION} ${DMG}"
echo
echo "    Cask stanza for Stixum/homebrew-tap (Casks/burnline.rb) — the sha is"
echo "    printed here rather than kept in a second file, because a copy of it"
echo "    in this repo drifted from the artefact within hours of being written:"
echo
echo "      version \"${VERSION}\""
echo "      sha256 \"$(shasum -a 256 "${DMG}" | awk '{print $1}')\""
echo
echo "    ⚠️  None of the above proves it works for a stranger. Download the DMG"
echo "        through a BROWSER on another Mac (or a fresh user account) and"
echo "        launch it — only that carries com.apple.quarantine. See Plan 6"
echo "        Tasks 8 and 9."
