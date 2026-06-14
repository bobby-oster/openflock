#!/usr/bin/env bash
# Build packaging/AppIcon.icns from a 1024+ square source PNG.
# Renders the Big Sur tile via make-icon.swift, then sips + iconutil.
#
# Usage: scripts/make-icon.sh [source.png] [out.icns]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SRC="${1:-packaging/AppIcon-source.png}"
OUT="${2:-packaging/AppIcon.icns}"
[ -f "$SRC" ] || { echo "error: source image not found: $SRC" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
MASTER="$TMP/master.png"
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"

echo "==> Rendering rounded 1024 master"
swift scripts/make-icon.swift "$SRC" "$MASTER"

echo "==> Generating iconset"
gen() { sips -z "$1" "$1" "$MASTER" --out "$ICONSET/$2" >/dev/null; }
gen 16   icon_16x16.png
gen 32   icon_16x16@2x.png
gen 32   icon_32x32.png
gen 64   icon_32x32@2x.png
gen 128  icon_128x128.png
gen 256  icon_128x128@2x.png
gen 256  icon_256x256.png
gen 512  icon_256x256@2x.png
gen 512  icon_512x512.png
gen 1024 icon_512x512@2x.png

echo "==> Compiling $OUT"
iconutil -c icns "$ICONSET" -o "$OUT"
echo "==> Done: $OUT"

# Also emit a rounded PNG for the README hero, kept in sync with the icon.
README_PNG="assets/openflock-icon.png"
mkdir -p assets
sips -z 512 512 "$MASTER" --out "$README_PNG" >/dev/null
echo "==> Wrote $README_PNG"
