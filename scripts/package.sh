#!/usr/bin/env bash
# Build OpenFlock and assemble a double-clickable .app bundle.
# Ad-hoc signs it so Gatekeeper allows local launch (not notarized — see README).
#
# By default this produces a DEV build with its own bundle id and display name
# (ai.openflock.OpenFlock.dev / "OpenFlock (dev)") at dist/OpenFlock-dev.app, so a
# local build never collides with the installed/brew app in Launch Services or
# Spotlight. release.sh overrides the identity and output path via the
# OPENFLOCK_BUNDLE_ID / OPENFLOCK_DISPLAY_NAME / OPENFLOCK_BUNDLE_PATH env vars to
# build the production artifact.
#
# Usage: scripts/package.sh [build-number]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="OpenFlock"          # SwiftPM product / executable name inside the bundle
VERSION="$(cat VERSION)"
BUILD="${1:-1}"

# Bundle identity. Defaults to a dev profile so local builds stay distinct from
# the shipping app; release.sh exports these to the production identity.
BUNDLE_ID="${OPENFLOCK_BUNDLE_ID:-ai.openflock.OpenFlock.dev}"
DISPLAY_NAME="${OPENFLOCK_DISPLAY_NAME:-OpenFlock (dev)}"
BUNDLE="${OPENFLOCK_BUNDLE_PATH:-dist/OpenFlock-dev.app}"

echo "==> Building ${DISPLAY_NAME} ${VERSION} (build ${BUILD})"
echo "    bundle id: ${BUNDLE_ID}"
echo "    output:    ${BUNDLE}"

# Prefer a universal (arm64 + x86_64) binary so releases run on Intel and
# Apple Silicon. Multi-arch needs Xcode's xcbuild (Command Line Tools can't);
# fall back to a native single-arch build if full Xcode isn't available.
UNIVERSAL=1
if [[ "$(xcode-select -p 2>/dev/null)" != *Xcode.app* ]]; then
    if [[ -d /Applications/Xcode.app ]]; then
        export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    else
        echo "    note: full Xcode not found — building native arch only" >&2
        UNIVERSAL=0
    fi
fi

if [[ "$UNIVERSAL" == 1 ]]; then
    swift build -c release --arch arm64 --arch x86_64
    BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/${APP_NAME}"
else
    swift build -c release
    BIN="$(swift build -c release --show-bin-path)/${APP_NAME}"
fi
[[ -f "$BIN" ]] || { echo "error: built binary not found at $BIN" >&2; exit 1; }
echo "==> Binary archs: $(lipo -archs "$BIN" 2>/dev/null || echo native)"

echo "==> Assembling ${BUNDLE}"
rm -rf "$BUNDLE"
mkdir -p "${BUNDLE}/Contents/MacOS" "${BUNDLE}/Contents/Resources"

cp "$BIN" "${BUNDLE}/Contents/MacOS/${APP_NAME}"

sed -e "s|{{VERSION}}|${VERSION}|g" -e "s|{{BUILD}}|${BUILD}|g" \
    -e "s|{{BUNDLE_ID}}|${BUNDLE_ID}|g" -e "s|{{DISPLAY_NAME}}|${DISPLAY_NAME}|g" \
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
