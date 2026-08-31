#!/bin/bash
# Build, sign, and launch NetlogsApp. Extra args are passed through, e.g.
#   Scripts/run-app.sh --autostart
#   Scripts/run-app.sh --diag
#   Scripts/run-app.sh --uicheck 15

set -euo pipefail
cd "$(dirname "$0")/.."

# Only the GUI path collides — two windows would mean two writers on
# netlogs.sqlite. The headless checks use their own temporary database and are
# fine alongside a running app.
HEADLESS=0
for arg in "$@"; do
  case "$arg" in
    --uicheck|--diag|--speed|--selftest) HEADLESS=1 ;;
  esac
done

# Path-matched, not name-matched: the Glaze prototype is also called "Netlogs",
# and a bare `pgrep -x Netlogs` sees it and refuses to launch.
if [ "$HEADLESS" -eq 0 ] && {
     pgrep -x NetlogsApp >/dev/null ||
     pgrep -f "$HOME/Applications/Netlogs.app/Contents/MacOS/Netlogs" >/dev/null
   }; then
  echo "Netlogs is already running — quit it first (⌘Q)." >&2
  exit 1
fi

swift build --product NetlogsApp
BIN="$(swift build --product NetlogsApp --show-bin-path)/NetlogsApp"

codesign --force --sign - \
  --entitlements Support/Netlogs.entitlements \
  --options runtime \
  "$BIN"

exec "$BIN" "$@"
