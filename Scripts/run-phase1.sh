#!/bin/bash
# Phase 1 ICMP check.
#
# Unprivileged SOCK_DGRAM ICMP on macOS needs the binary code-signed with
# com.apple.security.network.client — without it sendto() succeeds but every
# reply is silently dropped. SwiftPM does not sign executables with
# entitlements, so we build, ad-hoc sign the product, then run it.
#
# Usage: Scripts/run-phase1.sh [routerHost] [internetHost] [seconds]

set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=debug
swift build -c "$CONFIG" --product netlogs-ping

BIN="$(swift build -c "$CONFIG" --product netlogs-ping --show-bin-path)/netlogs-ping"
ENT="$(mktemp -t netlogs-ent).plist"
cat > "$ENT" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.network.client</key><true/>
</dict></plist>
PLIST

codesign --force --sign - --entitlements "$ENT" "$BIN"
rm -f "$ENT"

exec "$BIN" "$@"
