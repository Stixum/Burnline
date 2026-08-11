#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Burnline"
BUILD_DIR="build"
APP="${BUILD_DIR}/${APP_NAME}.app"

cd "$(dirname "$0")"

echo "==> Building release binary"
swift build -c release --product "${APP_NAME}"

echo "==> Generating icon"
swift Tools/make-icon.swift
iconutil -c icns "${BUILD_DIR}/${APP_NAME}.iconset" -o "${BUILD_DIR}/${APP_NAME}.icns"

echo "==> Assembling bundle"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp ".build/release/${APP_NAME}" "${APP}/Contents/MacOS/${APP_NAME}"
cp "Resources/Info.plist" "${APP}/Contents/Info.plist"
cp "${BUILD_DIR}/${APP_NAME}.icns" "${APP}/Contents/Resources/${APP_NAME}.icns"

echo "==> Signing"
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep "Developer ID Application" | head -1 | awk '{print $2}' || true)
if [ -n "${IDENTITY}" ]; then
  echo "    Developer ID: ${IDENTITY}"
  codesign --force --options runtime --sign "${IDENTITY}" "${APP}"
else
  echo "    No Developer ID found; signing ad-hoc."
  echo "    Gatekeeper may need one right-click > Open on first launch."
  codesign --force --sign - "${APP}"
fi

if [ "${1:-}" = "--install" ]; then
  echo "==> Installing to /Applications"
  pkill -f "/Applications/${APP_NAME}.app" 2>/dev/null || true
  sleep 1
  rm -rf "/Applications/${APP_NAME}.app"
  cp -R "${APP}" /Applications/
  echo "    Installed. Launch with: open -a ${APP_NAME}"
else
  echo "==> Built at ${APP} (pass --install to copy to /Applications)"
fi
