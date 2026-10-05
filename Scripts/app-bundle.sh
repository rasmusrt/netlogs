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

# The native build system, not the default swiftbuild one. Since Swift 6.4,
# swiftbuild links the binary with its SDK version recorded as the deployment
# target (15.0), and macOS then runs the app in compatibility mode: the whole
# window drops the Tahoe look — grey bezels instead of glass in the toolbar.
# Check with `vtool -show-build <binary>`; `sdk` must be the real SDK version.
BUILD=(swift build -c "$CONFIG" --product NetlogsApp --build-system native)
"${BUILD[@]}" 2>&1 | grep -v "build-system native' has been deprecated" || true
BIN="$("${BUILD[@]}" --show-bin-path 2>/dev/null)/NetlogsApp"

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

# A stable identity, so the app keeps one identity across rebuilds and the
# Keychain remembers "Always Allow" for the gateway key: the Developer ID when
# this Mac has one, else "Netlogs Development" (Scripts/make-dev-identity.sh,
# the stopgap from before the Developer Program). Ad-hoc otherwise: that works,
# but asks again after every build. Release signing is Scripts/release.sh.
SIGN=-
# -v (valid only) for the Developer ID; not for the self-signed one, which
# macOS lists but never counts as valid.
DEVID="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: .*\)"$/\1/p' | head -1)"
if [ -n "$DEVID" ]; then
    SIGN="$DEVID"
elif security find-identity -p codesigning 2>/dev/null | grep -q '"Netlogs Development"'; then
    SIGN="Netlogs Development"
fi

[ "${1:-}" = "--build-only" ] && { codesign --force --sign "$SIGN" --timestamp=none --entitlements Support/Netlogs.entitlements "$STAGE"; exit 0; }

DEST="$HOME/Applications/Netlogs.app"
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$STAGE" "$DEST"
xattr -cr "$DEST"   # strip iCloud provenance / any quarantine
# Signed at the final location (no --deep / no hardened runtime — they only
# add Gatekeeper friction for a local dev build).
codesign --force --sign "$SIGN" --timestamp=none --entitlements Support/Netlogs.entitlements "$DEST"
[ "$SIGN" = - ] && SIGNED=ad-hoc || SIGNED="$SIGN"
echo "deployed $DEST (signed: $SIGNED)"

open "$DEST" --args "$@"
