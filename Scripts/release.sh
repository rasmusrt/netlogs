#!/bin/bash
# Build a release zip for direct distribution, and print the Homebrew cask
# stanza that describes it.
#
#   Scripts/release.sh            # version from Support/Info.plist
#   Scripts/release.sh 0.2.0      # override
#   Scripts/release.sh --adhoc    # skip Developer ID + notarization (testing only)
#
# The zip is what a user downloads and what the cask hashes, so it is built the
# way Gatekeeper will see it: release configuration, entitlements applied, no
# extended attributes, signature verified before packing.
#
# Signed with the "Developer ID Application" identity in the login Keychain,
# with the hardened runtime and a secure timestamp, then notarized and stapled.
# Two one-time setup steps on the signing Mac (PUBLISHING.md):
#
#   - the Developer ID Application certificate, from Xcode → Settings →
#     Accounts → Manage Certificates;
#   - a notary credential stored in the Keychain under the profile name below:
#     xcrun notarytool store-credentials netlogs-notary \
#         --apple-id <apple-id> --team-id <team-id> --password <app-specific-password>
#
# Overrides: NETLOGS_SIGN_IDENTITY (if the Keychain holds more than one
# Developer ID), NETLOGS_NOTARY_PROFILE (default netlogs-notary).

set -euo pipefail
cd "$(dirname "$0")/.."

ADHOC=0
VERSION=""
for arg in "$@"; do
    case "$arg" in
        --adhoc) ADHOC=1 ;;
        *) VERSION="$arg" ;;
    esac
done
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)}"
ZIP="build/Netlogs-$VERSION.zip"
PROFILE="${NETLOGS_NOTARY_PROFILE:-netlogs-notary}"

# Fail before building rather than after: a release that silently falls back to
# ad-hoc is exactly the build macOS kills at launch on a user's machine.
if [ "$ADHOC" = 1 ]; then
    IDENTITY=-
else
    IDENTITY="${NETLOGS_SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
        | sed -n 's/.*"\(Developer ID Application: .*\)"$/\1/p' | head -1)}"
    if [ -z "$IDENTITY" ]; then
        echo "No valid \"Developer ID Application\" identity in the Keychain." >&2
        echo "Create it in Xcode → Settings → Accounts → Manage Certificates," >&2
        echo "or pass --adhoc for a build that is not for distribution." >&2
        exit 1
    fi
    if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
        echo "No working notary credential under the Keychain profile \"$PROFILE\"." >&2
        echo "Store it once with:" >&2
        echo "  xcrun notarytool store-credentials $PROFILE --apple-id <apple-id> --team-id <team-id> --password <app-specific-password>" >&2
        exit 1
    fi
    echo "signing as: $IDENTITY"
fi

Scripts/app-bundle.sh --build-only

# Assemble the shipping copy *outside* the repo, because the repo is in iCloud
# Drive: the file provider stamps com.apple.FinderInfo and a fileprovider key
# on the bundle, and `codesign --verify --strict` rejects those as "resource
# fork, Finder information, or similar detritus". `xattr -cr` is not enough —
# com.apple.provenance cannot be removed at all — so the fix is to copy without
# attributes rather than to strip them afterwards.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/Netlogs.app"
ditto --norsrc --noextattr build/Netlogs.app "$APP"

# ditto, not zip: it preserves the bundle's symlinks and _CodeSignature, which
# a plain `zip -r` mangles into an app that will not launch.
pack() { rm -f "$WORK/out.zip"; ditto -c -k --sequesterRsrc --keepParent "$APP" "$WORK/out.zip"; }

# Sign last: this is the signature the user's Gatekeeper checks.
if [ "$ADHOC" = 1 ]; then
    codesign --force --sign - --entitlements Support/Netlogs.entitlements "$APP"
    codesign --verify --strict --verbose=2 "$APP"
    pack
else
    # Notarization requires the hardened runtime and a secure timestamp.
    codesign --force --sign "$IDENTITY" --options runtime --timestamp \
        --entitlements Support/Netlogs.entitlements "$APP"
    codesign --verify --strict --verbose=2 "$APP"

    # The notary service takes a zip; the ticket is then stapled to the app
    # itself (a zip cannot carry one), and the zip rebuilt around the stapled
    # app so it launches offline too.
    pack
    echo "notarizing — usually a few minutes…"
    NOTARY="$(xcrun notarytool submit "$WORK/out.zip" --keychain-profile "$PROFILE" --wait 2>&1)" || true
    echo "$NOTARY"
    if ! grep -q "status: Accepted" <<<"$NOTARY"; then
        ID="$(sed -n 's/^ *id: //p' <<<"$NOTARY" | head -1)"
        echo "Notarization was not accepted. See why with:" >&2
        echo "  xcrun notarytool log ${ID:-<submission-id>} --keychain-profile $PROFILE" >&2
        exit 1
    fi
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    # What Gatekeeper on a user's Mac will say: expect "source=Notarized Developer ID".
    spctl --assess --type execute --verbose=2 "$APP"
    pack
fi

mkdir -p build
cp "$WORK/out.zip" "$ZIP"

SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
SIZE="$(du -h "$ZIP" | cut -f1)"

cat <<EOS

built $ZIP ($SIZE)
sha256 $SHA

Cask stanza — update Casks/netlogs.rb in the tap:

  version "$VERSION"
  sha256 "$SHA"

Publish it:

  git tag -a v$VERSION -m "Netlogs $VERSION" && git push origin v$VERSION
  gh release create v$VERSION "$ZIP" --title "Netlogs $VERSION" --notes "…"
EOS
