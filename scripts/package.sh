#!/usr/bin/env bash
# Build OpenFlock and assemble a double-clickable OpenFlock.app in dist/.
# Ad-hoc signs it so Gatekeeper allows local launch (not notarized — see README).
#
# Usage: scripts/package.sh [build-number]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="OpenFlock"
VERSION="$(cat VERSION)"
BUILD="${1:-1}"
BUNDLE="dist/${APP_NAME}.app"

echo "==> Building ${APP_NAME} ${VERSION} (build ${BUILD})"
swift build -c release

BIN=".build/release/${APP_NAME}"
[ -f "$BIN" ] || { echo "error: built binary not found at $BIN" >&2; exit 1; }

echo "==> Assembling ${BUNDLE}"
rm -rf "$BUNDLE"
mkdir -p "${BUNDLE}/Contents/MacOS" "${BUNDLE}/Contents/Resources"

cp "$BIN" "${BUNDLE}/Contents/MacOS/${APP_NAME}"

sed -e "s/{{VERSION}}/${VERSION}/g" -e "s/{{BUILD}}/${BUILD}/g" \
    packaging/Info.plist > "${BUNDLE}/Contents/Info.plist"

if [ -f packaging/AppIcon.icns ]; then
    cp packaging/AppIcon.icns "${BUNDLE}/Contents/Resources/AppIcon.icns"
else
    echo "warning: packaging/AppIcon.icns missing — run scripts/make-icon.sh" >&2
fi

echo "==> Ad-hoc signing"
codesign --force --sign - "${BUNDLE}" || echo "warning: codesign failed (app may still run)"

echo "==> Done: ${BUNDLE}"
echo "    Launch with: open ${BUNDLE}"
