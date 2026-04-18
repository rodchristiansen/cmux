#!/usr/bin/env bash
set -euo pipefail

# Build, sign, notarize, and install cmux to /Applications.
#
# Unlike scripts/build-sign-upload.sh this does NOT:
#   - inject a Sparkle key (you won't auto-update a local dev install)
#   - create a DMG, upload to GitHub, or update homebrew-cmux
#   - bump the version, tag, or push anything
#
# Environment variables:
#   CMUX_LOCAL_SIGN_IDENTITY  Developer ID Application SHA-1 to sign with.
#                             If unset, auto-detected from the keychain; errors
#                             if zero or more than one identity is present.
#   CMUX_NOTARY_PROFILE       notarytool keychain profile (default: notarization_credentials).
#   CMUX_SKIP_ZIG_BUILD       Passed through to the Xcode build phase for the ghostty
#                             CLI helper. Set to 1 on macOS 26+ hosts where the
#                             helper's zig build is broken.
#
# Flags:
#   --launch                  Launch /Applications/cmux.app after installing.
#   --skip-notarize           Build, sign, and install without notarizing. The
#                             installed app will fail Gatekeeper on other machines
#                             but runs fine locally (ad-hoc launch). Useful for
#                             quick iteration.

usage() {
  cat <<'EOF'
Usage: ./scripts/install-local.sh [--launch] [--skip-notarize]

Builds a Release cmux, signs with your Developer ID Application identity, notarizes
via your notarytool keychain profile, staples, and installs to /Applications.
EOF
}

LAUNCH="false"
SKIP_NOTARIZE="false"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --launch) LAUNCH="true"; shift ;;
    --skip-notarize) SKIP_NOTARIZE="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

NOTARY_PROFILE="${CMUX_NOTARY_PROFILE:-notarization_credentials}"
ENTITLEMENTS="$REPO_ROOT/cmux.entitlements"
DERIVED_DATA="$REPO_ROOT/build-local"
APP_PATH="$DERIVED_DATA/Build/Products/Release/cmux.app"
DEST_PATH="/Applications/cmux.app"

# --- Pre-flight ---
for tool in xcodebuild codesign xcrun ditto; do
  command -v "$tool" >/dev/null || { echo "MISSING tool: $tool" >&2; exit 1; }
done
if [[ ! -f "$ENTITLEMENTS" ]]; then
  echo "Missing entitlements file: $ENTITLEMENTS" >&2
  exit 1
fi

# --- Resolve signing identity ---
if [[ -n "${CMUX_LOCAL_SIGN_IDENTITY:-}" ]]; then
  SIGN_HASH="$CMUX_LOCAL_SIGN_IDENTITY"
else
  MATCHES="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2}' | sort -u)"
  COUNT="$(printf '%s\n' "$MATCHES" | grep -c . || true)"
  if [[ "$COUNT" -eq 0 ]]; then
    echo "No 'Developer ID Application' identity found in the keychain." >&2
    echo "Install one or set CMUX_LOCAL_SIGN_IDENTITY to an identity SHA-1." >&2
    exit 1
  elif [[ "$COUNT" -gt 1 ]]; then
    echo "Multiple 'Developer ID Application' identities found:" >&2
    printf '  %s\n' $MATCHES >&2
    echo "Set CMUX_LOCAL_SIGN_IDENTITY to the SHA-1 you want to use." >&2
    exit 1
  fi
  SIGN_HASH="$(security find-identity -v -p codesigning | awk '/Developer ID Application/ {print $2; exit}')"
fi
echo "==> Signing identity: $SIGN_HASH"

# --- Verify notary profile unless skipping ---
if [[ "$SKIP_NOTARIZE" != "true" ]]; then
  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "notarytool keychain profile '$NOTARY_PROFILE' is not usable." >&2
    echo "Store one via: xcrun notarytool store-credentials $NOTARY_PROFILE" >&2
    echo "Or pass --skip-notarize for an ad-hoc local install." >&2
    exit 1
  fi
  echo "==> Notary profile: $NOTARY_PROFILE"
fi

# --- Ensure GhosttyKit.xcframework is present ---
if [[ ! -d "$REPO_ROOT/GhosttyKit.xcframework" ]]; then
  echo "==> GhosttyKit.xcframework missing; running ensure-ghosttykit.sh"
  "$SCRIPT_DIR/ensure-ghosttykit.sh"
fi

# --- Build Release (unsigned) ---
echo "==> Building Release (unsigned)..."
rm -rf "$DERIVED_DATA"
BUILD_ENV=(env)
if [[ -n "${CMUX_SKIP_ZIG_BUILD:-}" ]]; then
  BUILD_ENV+=(CMUX_SKIP_ZIG_BUILD="$CMUX_SKIP_ZIG_BUILD")
fi
"${BUILD_ENV[@]}" xcodebuild \
  -project GhosttyTabs.xcodeproj \
  -scheme cmux \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build 2>&1 | tail -10

if [[ ! -d "$APP_PATH" ]]; then
  echo "Build did not produce $APP_PATH" >&2
  exit 1
fi
echo "==> Built: $APP_PATH"

# --- Codesign ---
CLI_PATH="$APP_PATH/Contents/Resources/bin/cmux"
HELPER_PATH="$APP_PATH/Contents/Resources/bin/ghostty"

sign_if_exists() {
  local path="$1"
  [[ -e "$path" ]] || return 0
  /usr/bin/codesign --force --options runtime --timestamp \
    --sign "$SIGN_HASH" --entitlements "$ENTITLEMENTS" "$path"
}

echo "==> Signing helpers..."
sign_if_exists "$CLI_PATH"
sign_if_exists "$HELPER_PATH"

echo "==> Signing app..."
/usr/bin/codesign --force --options runtime --timestamp \
  --sign "$SIGN_HASH" --entitlements "$ENTITLEMENTS" --deep "$APP_PATH"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"
echo "==> Codesign verified"

# --- Notarize ---
if [[ "$SKIP_NOTARIZE" != "true" ]]; then
  NOTARY_ZIP="$DERIVED_DATA/cmux-notary.zip"
  echo "==> Zipping for notarization..."
  rm -f "$NOTARY_ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$NOTARY_ZIP"
  echo "==> Submitting to notarization (this usually takes 1-5 minutes)..."
  xcrun notarytool submit "$NOTARY_ZIP" \
    --keychain-profile "$NOTARY_PROFILE" --wait
  rm -f "$NOTARY_ZIP"
  echo "==> Stapling..."
  xcrun stapler staple "$APP_PATH"
  xcrun stapler validate "$APP_PATH"
  echo "==> Notarized and stapled"
fi

# --- Install to /Applications ---
echo "==> Installing to $DEST_PATH..."
if pgrep -xf "$DEST_PATH/Contents/MacOS/cmux" >/dev/null 2>&1 \
   || pgrep -xf "/Applications/cmux.app/Contents/MacOS/cmux" >/dev/null 2>&1; then
  echo "==> Quitting running cmux.app"
  osascript -e 'tell application "cmux" to quit' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -xf "/Applications/cmux.app/Contents/MacOS/cmux" >/dev/null 2>&1 || break
    sleep 0.5
  done
  pkill -f "/Applications/cmux.app/Contents/MacOS/cmux" 2>/dev/null || true
fi

SUDO=""
if [[ ! -w /Applications ]]; then
  SUDO="sudo"
fi
$SUDO rm -rf "$DEST_PATH"
$SUDO ditto "$APP_PATH" "$DEST_PATH"
echo "==> Installed $DEST_PATH"

# --- Verify ---
echo "==> Verifying install..."
/usr/bin/codesign --verify --deep --strict --verbose=2 "$DEST_PATH"
if [[ "$SKIP_NOTARIZE" != "true" ]]; then
  xcrun stapler validate "$DEST_PATH" || true
fi
spctl -a -vv "$DEST_PATH" || true

VERSION="$(defaults read "$DEST_PATH/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo unknown)"
BUILD="$(defaults read "$DEST_PATH/Contents/Info" CFBundleVersion 2>/dev/null || echo unknown)"
echo "==> cmux $VERSION (build $BUILD) installed"

if [[ "$LAUNCH" == "true" ]]; then
  echo "==> Launching..."
  open -a "$DEST_PATH"
fi
