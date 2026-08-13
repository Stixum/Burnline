#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Burnline"
BUILD_DIR="build"
APP="${BUILD_DIR}/${APP_NAME}.app"

cd "$(dirname "$0")"

# Build + assemble, with no signing. Factored out so `release.sh` can produce a
# byte-identical bundle and then apply its own stricter signing, rather than
# duplicating these steps and drifting from them.
assemble_bundle() {
  # Universal only when releasing. Two architectures roughly doubles build time,
  # which is not worth paying on every local iteration — but shipping arm64-only
  # would hand Intel Mac users a signed, notarized DMG whose app cannot launch,
  # with nothing on screen explaining why. macOS 14 still supports 2018-2020
  # Intel machines, so "requires macOS 14" and "Apple silicon only" are not the
  # same statement.
  if [ "${BURNLINE_UNIVERSAL:-}" = "1" ]; then
    echo "==> Building universal release binaries (arm64 + x86_64)"
    swift build -c release --arch arm64 --arch x86_64 --product "${APP_NAME}"
    swift build -c release --arch arm64 --arch x86_64 --product BurnlineStatusline
    # SwiftPM puts multi-arch output here, NOT in .build/release. Copying from
    # the usual path silently ships a single-arch binary from an earlier build.
    PRODUCTS=".build/apple/Products/Release"
  else
    echo "==> Building release binaries (native arch)"
    swift build -c release --product "${APP_NAME}"
    swift build -c release --product BurnlineStatusline
    PRODUCTS=".build/release"
  fi

  echo "==> Generating icon"
  swift Tools/make-icon.swift
  iconutil -c icns "${BUILD_DIR}/${APP_NAME}.iconset" -o "${BUILD_DIR}/${APP_NAME}.icns"

  echo "==> Assembling bundle"
  rm -rf "${APP}"
  mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
  cp "${PRODUCTS}/${APP_NAME}" "${APP}/Contents/MacOS/${APP_NAME}"
  # The statusline helper ships inside the bundle for two reasons: it is then
  # versioned with the app and reachable by an update, and settings.json can point
  # at a path that moves with the app. Its bash predecessor lived in ~/.claude and
  # could never be updated by anything the app did.
  cp "${PRODUCTS}/BurnlineStatusline" "${APP}/Contents/MacOS/burnline-statusline"
  cp "Resources/Info.plist" "${APP}/Contents/Info.plist"
  cp "${BUILD_DIR}/${APP_NAME}.icns" "${APP}/Contents/Resources/${APP_NAME}.icns"
}

# `release.sh` sources this file to reuse assemble_bundle. Everything below is
# the interactive path and must not run on source.
if [ "${1:-}" = "--assemble-only" ]; then
  assemble_bundle
  exit 0
fi
if [ "${BURNLINE_BUILD_LIB:-}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

assemble_bundle

echo "==> Signing"
# Inside-out, always: nested code first, the .app last. Signing the container
# before its contents invalidates the container's seal, and that is the single
# most common cause of a notarization rejection.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep "Developer ID Application" | head -1 | awk '{print $2}' || true)
if [ -n "${IDENTITY}" ]; then
  echo "    Developer ID: ${IDENTITY}"
  codesign --force --options runtime --timestamp \
    --sign "${IDENTITY}" "${APP}/Contents/MacOS/burnline-statusline"
  codesign --force --options runtime --timestamp --sign "${IDENTITY}" "${APP}"
else
  echo "    No Developer ID found; signing ad-hoc (hardened runtime on)."
  # Hardened runtime works fine alongside an ad-hoc signature — verified
  # 2026-08-11, flags 0x10002(adhoc,runtime). It blocks DYLD injection and
  # debugger attach. Cheap hygiene rather than a meaningful hole closed: this
  # app holds no secrets, so anything able to inject already runs as the user
  # and could read ~/.claude directly.
  #
  # No --timestamp here: an ad-hoc signature cannot carry a trusted timestamp.
  codesign --force --options runtime --sign - "${APP}/Contents/MacOS/burnline-statusline"
  codesign --force --options runtime --sign - "${APP}"
fi

if [ "${1:-}" = "--install" ]; then
  echo "==> Installing to /Applications"
  pkill -f "/Applications/${APP_NAME}.app" 2>/dev/null || true
  sleep 1
  rm -rf "/Applications/${APP_NAME}.app"
  cp -R "${APP}" /Applications/
  # Drop the staging copy: two registered bundles make a bare `open -a Burnline`
  # ambiguous, and it can resolve to this build directory instead.
  rm -rf "${APP}"
  echo "    Installed. Launch with: open -a ${APP_NAME}"
else
  echo "==> Built at ${APP} (pass --install to copy to /Applications)"
fi
