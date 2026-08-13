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
  echo "    See docs/superpowers/plans/2026-08-11-plan-6-release.md Task 1." >&2
  exit 1
fi

if ! xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" >/dev/null 2>&1; then
  echo "!!! No notary credentials for profile '${NOTARY_PROFILE}'." >&2
  echo "    See Plan 6 Task 2 (xcrun notarytool store-credentials)." >&2
  exit 1
fi

# --- 1. tests --------------------------------------------------------------
if [ "${BURNLINE_SKIP_TESTS:-}" != "1" ]; then
  echo "==> Running tests"
  swift test
fi

# --- 2. assemble (shared with build.sh, never duplicated) ------------------
BURNLINE_BUILD_LIB=1 source ./build.sh
assemble_bundle

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
STAGE="${BUILD_DIR}/dmg"
rm -rf "${STAGE}" "${DMG}"
mkdir -p "${STAGE}"
cp -R "${APP}" "${STAGE}/"
ln -s /Applications "${STAGE}/Applications"
hdiutil create -volname "${APP_NAME}" -srcfolder "${STAGE}" \
  -ov -format UDZO "${DMG}" >/dev/null
rm -rf "${STAGE}"

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

echo
echo "==> Done: ${DMG}"
shasum -a 256 "${DMG}"
echo
echo "    Next: gh release create v${VERSION} ${DMG}"
echo "    Then update the cask's version + sha256 in Stixum/homebrew-tap."
echo
echo "    ⚠️  None of the above proves it works for a stranger. Download the DMG"
echo "        through a BROWSER on another Mac (or a fresh user account) and"
echo "        launch it — only that carries com.apple.quarantine. See Plan 6"
echo "        Tasks 8 and 9."
