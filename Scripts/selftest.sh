#!/bin/bash
# Build NetlogsApp, sign it with the (non-sandboxed) entitlements, run --selftest.
#
#   Scripts/selftest.sh [router] [internet] [seconds]
#
# Confirms ICMP still works from the real app binary's identity. Exit 0 = pass.

set -euo pipefail
cd "$(dirname "$0")/.."

swift build --product NetlogsApp
BIN="$(swift build --product NetlogsApp --show-bin-path)/NetlogsApp"

codesign --force --sign - \
  --entitlements Support/Netlogs.entitlements \
  --options runtime \
  "$BIN"

exec "$BIN" --selftest "$@"
