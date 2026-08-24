#!/bin/bash
# Builds DisplayVolume.app from the SwiftPM package and signs it.
#
# Works with just the Command Line Tools (no full Xcode needed).
#
# Usage:
#   Scripts/build-app.sh                    # release build, ad-hoc signed
#   CONFIGURATION=debug Scripts/build-app.sh
#   CODESIGN_IDENTITY="Apple Development: You (TEAMID)" Scripts/build-app.sh
#
# IMPORTANT: macOS ties privacy permissions (System Audio Recording,
# Accessibility) to the code signature + bundle ID. Ad-hoc signatures change
# on every build, which makes macOS treat each build as a new app and re-ask
# for permissions. For day-to-day use, sign with a real Apple Development
# identity (set CODESIGN_IDENTITY) so permissions stick across rebuilds.

set -euo pipefail
cd "$(dirname "$0")/.."

CONFIGURATION="${CONFIGURATION:-release}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

# Fail early and loudly if a named identity doesn't exist, instead of
# letting codesign fail cryptically halfway through.
if [[ "$CODESIGN_IDENTITY" != "-" ]]; then
    if ! security find-identity -v -p codesigning | grep -qF "$CODESIGN_IDENTITY"; then
        echo "error: no code-signing identity named \"$CODESIGN_IDENTITY\" in your keychain." >&2
        echo "       Create one in Keychain Access (Certificate Assistant → Create a" >&2
        echo "       Certificate… → Identity Type: Self-Signed Root, Certificate Type:" >&2
        echo "       Code Signing), or list identities with:" >&2
        echo "           security find-identity -v -p codesigning" >&2
        exit 1
    fi
fi
BUILD_DIR=".build"
APP_NAME="DisplayVolume"
OUT_DIR="${OUT_DIR:-build}"
APP_BUNDLE="$OUT_DIR/$APP_NAME.app"

echo "==> swift build -c $CONFIGURATION"
swift build -c "$CONFIGURATION"

BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path)/DisplayVolumeApp"
if [[ ! -f "$BIN_PATH" ]]; then
    echo "error: built binary not found at $BIN_PATH" >&2
    exit 1
fi

echo "==> Assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp SupportFiles/Info.plist "$APP_BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

echo "==> Signing (identity: $CODESIGN_IDENTITY)"
codesign --force --sign "$CODESIGN_IDENTITY" \
    --entitlements SupportFiles/DisplayVolume.entitlements \
    --options runtime \
    "$APP_BUNDLE" 2>/dev/null || \
codesign --force --sign "$CODESIGN_IDENTITY" \
    --entitlements SupportFiles/DisplayVolume.entitlements \
    "$APP_BUNDLE"

codesign --verify --verbose=2 "$APP_BUNDLE"

echo
echo "Built: $APP_BUNDLE"
echo "Run:   open \"$APP_BUNDLE\""
echo
echo "Tip: move the app to /Applications (or another stable path) before"
echo "granting permissions, so Start-at-Login and TCC grants stay valid."
