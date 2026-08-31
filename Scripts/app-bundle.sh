#!/bin/bash
# Assemble Netlogs.app, deploy it to ~/Applications (outside iCloud), and open it.
#
# Needed for anything that requires a LaunchServices-registered app in a
# TCC-trusted location: the Location (SSID) permission prompt, proper Dock/menu
# behaviour. The project lives in iCloud Drive, where TCC won't attribute
# permissions — hence the copy to ~/Applications.
#
#   Scripts/app-bundle.sh [--autostart | ...]   # args forwarded to the app
#   Scripts/app-bundle.sh --build-only          # build into build/, don't deploy/open

set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=release
[ "${NETLOGS_DEBUG:-}" = "1" ] && CONFIG=debug

swift build -c "$CONFIG" --product NetlogsApp
BIN="$(swift build -c "$CONFIG" --product NetlogsApp --show-bin-path)/NetlogsApp"

# Quit any running instance of *this* app first — it enforces single-instance
# and would otherwise just hand off to the old one (looking like "didn't
# launch").
#
# Matched by executable path, never by process name. The Glaze prototype this
# app replaces is also called "Netlogs" (/Applications/Glaze/Netlogs.app), so
# `pkill -x Netlogs` quits that too — which it did, repeatedly, before anyone
# noticed.
pkill -f "$HOME/Applications/Netlogs.app/Contents/MacOS/Netlogs" 2>/dev/null || true
pkill -f "$PWD/build/Netlogs.app/Contents/MacOS/Netlogs" 2>/dev/null || true
pkill -x NetlogsApp 2>/dev/null || true

[ -f build/AppIcon.icns ] || Scripts/make-icon.sh

STAGE="build/Netlogs.app"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN" "$STAGE/Contents/MacOS/Netlogs"
cp Support/Info.plist "$STAGE/Contents/Info.plist"
cp build/AppIcon.icns "$STAGE/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$STAGE/Contents/PkgInfo"
echo "built $STAGE"

[ "${1:-}" = "--build-only" ] && { codesign --force --sign - --entitlements Support/Netlogs.entitlements "$STAGE"; exit 0; }

DEST="$HOME/Applications/Netlogs.app"
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$STAGE" "$DEST"
xattr -cr "$DEST"   # strip iCloud provenance / any quarantine
# Plain ad-hoc sign at the final location (no --deep / no hardened runtime —
# they only add Gatekeeper friction for a local dev build).
codesign --force --sign - --entitlements Support/Netlogs.entitlements "$DEST"
echo "deployed $DEST"

open "$DEST" --args "$@"
