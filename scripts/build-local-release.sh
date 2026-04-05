#!/usr/bin/env bash
set -euo pipefail

# Build, sign, notarize, and install cmux locally.
# Usage: ./scripts/build-local-release.sh [--sync]
#   --sync   Fetch and rebase from upstream before building

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

SYNC=0
for arg in "$@"; do
  case "$arg" in
    --sync) SYNC=1 ;;
    -h|--help)
      echo "Usage: $0 [--sync]"
      echo "  --sync  Fetch upstream/main and rebase feature branch before building"
      exit 0
      ;;
  esac
done

# --- Signing configuration ---
SIGN_IDENTITY="Developer ID Application: Emily Carr University of Art and Design (7TF6CSP83S)"
SIGN_HASH="C0277EBA633F1AA2BC2855E45B3B38A1840053BA"
TEAM_ID="7TF6CSP83S"
APPLE_ID="applenotarization@ecuad.ca"
APPLE_PASSWORD="zdtm-jyob-rhbb-cbfq"
ENTITLEMENTS="cmux.entitlements"
INSTALL_PATH="/Applications/cmux.app"
BUILD_DIR="build"
APP_PATH="$BUILD_DIR/Build/Products/Release/cmux.app"

# --- Pre-flight ---
for tool in zig xcodebuild xcrun codesign; do
  command -v "$tool" >/dev/null || { echo "MISSING: $tool" >&2; exit 1; }
done
echo "==> Pre-flight passed"

# --- Sync upstream (optional) ---
if [[ "$SYNC" -eq 1 ]]; then
  echo "==> Syncing from upstream..."
  git fetch upstream
  git rebase upstream/main
  git submodule update --init --recursive
  # Re-download GhosttyKit if submodule changed
  GHOSTTY_SHA="$(git -C ghostty rev-parse HEAD)"
  if [ ! -d "GhosttyKit.xcframework" ] || ! grep -q "$GHOSTTY_SHA" GhosttyKit.xcframework/.ghostty_sha 2>/dev/null; then
    echo "==> Downloading updated GhosttyKit..."
    bash scripts/download-prebuilt-ghosttykit.sh
  fi
  echo "==> Sync complete"
fi

# --- Ensure GhosttyKit ---
if [ ! -d "GhosttyKit.xcframework" ]; then
  echo "==> Downloading GhosttyKit..."
  bash scripts/download-prebuilt-ghosttykit.sh
fi

# --- Remove problematic xcframework tags from ghostty submodule ---
for tag in $(git -C ghostty tag -l 'xcframework-*' 2>/dev/null); do
  git -C ghostty tag -d "$tag" >/dev/null 2>&1 || true
done

# --- Build Release ---
echo "==> Building Release..."
rm -rf "$BUILD_DIR/"
xcodebuild \
  -project GhosttyTabs.xcodeproj \
  -scheme cmux \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGNING_ALLOWED=NO \
  build 2>&1 | tail -5

if [ ! -d "$APP_PATH" ]; then
  echo "ERROR: Build failed, app not found at $APP_PATH" >&2
  exit 1
fi
echo "==> Build succeeded"

# --- Codesign ---
echo "==> Codesigning..."
HELPER_PATH="$APP_PATH/Contents/Resources/bin/ghostty"
CLI_PATH="$APP_PATH/Contents/Resources/bin/cmux"

if [ -f "$CLI_PATH" ]; then
  /usr/bin/codesign --force --options runtime --timestamp \
    --sign "$SIGN_HASH" --entitlements "$ENTITLEMENTS" "$CLI_PATH"
fi
if [ -f "$HELPER_PATH" ]; then
  /usr/bin/codesign --force --options runtime --timestamp \
    --sign "$SIGN_HASH" --entitlements "$ENTITLEMENTS" "$HELPER_PATH"
fi
/usr/bin/codesign --force --options runtime --timestamp \
  --sign "$SIGN_HASH" --entitlements "$ENTITLEMENTS" --deep "$APP_PATH"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"
echo "==> Codesign verified"

# --- Notarize ---
echo "==> Notarizing (this may take a few minutes)..."
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" cmux-notary.zip
xcrun notarytool submit cmux-notary.zip \
  --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APPLE_PASSWORD" --wait
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
rm -f cmux-notary.zip
echo "==> Notarization complete"

# --- Install ---
echo "==> Installing to $INSTALL_PATH..."
pkill -f "cmux" 2>/dev/null || true
sleep 1
if [ -d "$INSTALL_PATH" ]; then
  rm -rf "$INSTALL_PATH"
fi
cp -R "$APP_PATH" "$INSTALL_PATH"
echo "==> Installed. Launching..."
open "$INSTALL_PATH"

echo ""
echo "Done! cmux has been replaced with your custom build."
echo "To update from upstream in the future, run:"
echo "  ./scripts/build-local-release.sh --sync"
