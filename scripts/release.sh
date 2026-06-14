#!/usr/bin/env bash
# Build a universal OpenFlock.app, zip it for a GitHub Release, and render the
# Homebrew cask with the artifact's sha256. Does NOT publish anything — it only
# produces files in dist/ and prints the commands to publish them.
#
# Usage: scripts/release.sh [build-number]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="$(cat VERSION)"
APP="dist/OpenFlock.app"
ZIP="dist/OpenFlock-${VERSION}.zip"
CASK="dist/openflock.rb"

# Fresh, signed bundle.
"$ROOT/scripts/package.sh" "${1:-1}"

echo "==> Zipping ${APP} -> ${ZIP}"
rm -f "$ZIP"
# ditto preserves the code signature and bundle symlinks; a plain zip can break them.
ditto -c -k --keepParent "$APP" "$ZIP"

SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
SIZE="$(du -h "$ZIP" | awk '{print $1}')"

echo "==> Rendering cask -> ${CASK}"
sed -e "s/{{VERSION}}/${VERSION}/g" -e "s/{{SHA256}}/${SHA}/g" \
    packaging/openflock.cask.tmpl > "$CASK"

echo
echo "==> Release artifact ready"
echo "    zip:     ${ZIP}  (${SIZE})"
echo "    sha256:  ${SHA}"
echo "    cask:    ${CASK}"
echo
echo "Publish — these are OUTWARD-FACING / public:"
echo "  1. gh release create v${VERSION} \"${ZIP}\" \\"
echo "       --title \"OpenFlock v${VERSION}\" --notes \"Pre-alpha. Menu-bar agent watcher.\""
echo "  2. Copy ${CASK} into the bobby-oster/homebrew-openflock tap at Casks/openflock.rb"
echo "  3. brew install --cask bobby-oster/openflock/openflock   # (or add --no-quarantine)"
