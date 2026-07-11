#!/usr/bin/env bash
# Render the app icon and build Resources/AppIcon.icns from it.
#   scripts/make-icns.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PNG="$WORK/icon-1024.png"
swift scripts/make-icon.swift "$PNG"

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size"           "$PNG" --out "$ICONSET/icon_${size}x${size}.png"   >/dev/null
  sips -z $((size*2)) $((size*2))   "$PNG" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"
sips -z 192 192 "$PNG" --out "$ROOT/Resources/PWAIcon-192.png" >/dev/null
sips -z 512 512 "$PNG" --out "$ROOT/Resources/PWAIcon-512.png" >/dev/null
echo "wrote macOS and PWA app icons"
