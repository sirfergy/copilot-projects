#!/usr/bin/env bash
# Render the app icons and build Resources/AppIcon.icns and
# Resources/PullRequestsIcon.icns from them.
#   scripts/make-icns.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

render() {
  local name="$1"; shift
  local png="$WORK/$name-1024.png"
  swift scripts/make-icon.swift "$png" "$@"
  local iconset="$WORK/$name.iconset"
  mkdir -p "$iconset"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size"           "$png" --out "$iconset/icon_${size}x${size}.png"   >/dev/null
    sips -z $((size*2)) $((size*2))   "$png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$iconset" -o "$ROOT/Resources/$name.icns"
}

render AppIcon
render PullRequestsIcon --pull-requests
echo "wrote macOS app icons"
