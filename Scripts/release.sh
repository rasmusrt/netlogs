#!/bin/bash
# Build a release zip for direct distribution, and print the Homebrew cask
# stanza that describes it.
#
#   Scripts/release.sh            # version from Support/Info.plist
#   Scripts/release.sh 0.2.0      # override
#
# The zip is what a user downloads and what the cask hashes, so it is built the
# way Gatekeeper will see it: release configuration, entitlements applied, no
# extended attributes, signature verified before packing.
#
# It stays ad-hoc signed. Notarization needs the paid Developer Program (see
# PUBLISHING.md); until then the cask documents --no-quarantine.

set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)}"
ZIP="build/Netlogs-$VERSION.zip"

Scripts/app-bundle.sh --build-only

# Assemble the shipping copy *outside* the repo, because the repo is in iCloud
# Drive: the file provider stamps com.apple.FinderInfo and a fileprovider key
# on the bundle, and `codesign --verify --strict` rejects those as "resource
# fork, Finder information, or similar detritus". `xattr -cr` is not enough —
# com.apple.provenance cannot be removed at all — so the fix is to copy without
# attributes rather than to strip them afterwards.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ditto --norsrc --noextattr build/Netlogs.app "$WORK/Netlogs.app"

# Sign last: this is the signature the user's Gatekeeper checks.
codesign --force --sign - --entitlements Support/Netlogs.entitlements "$WORK/Netlogs.app"
codesign --verify --strict --verbose=2 "$WORK/Netlogs.app"

# ditto, not zip: it preserves the bundle's symlinks and _CodeSignature, which
# a plain `zip -r` mangles into an app that will not launch.
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$WORK/Netlogs.app" "$WORK/out.zip"
cp "$WORK/out.zip" "$ZIP"

SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
SIZE="$(du -h "$ZIP" | cut -f1)"

cat <<EOF

built $ZIP ($SIZE)
sha256 $SHA

Cask stanza — update Casks/netlogs.rb in the tap:

  version "$VERSION"
  sha256 "$SHA"

Publish it:

  git tag -a v$VERSION -m "Netlogs $VERSION" && git push origin v$VERSION
  gh release create v$VERSION "$ZIP" --title "Netlogs $VERSION" --notes "…"
EOF
