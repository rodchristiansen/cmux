#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/codesign_app_bundle.sh <app-path> <signing-identity> <entitlements-path>

Signs a built cmux app bundle inside-out so Sparkle helpers keep their own entitlements.
Set CMUX_CODESIGN_DRY_RUN=1 to print the signing plan instead of executing codesign.
EOF
}

if [ "$#" -ne 3 ]; then
  usage >&2
  exit 1
fi

APP_PATH="$1"
SIGNING_IDENTITY="$2"
ENTITLEMENTS_PATH="$3"
CODESIGN_BIN="/usr/bin/codesign"

if [ ! -d "$APP_PATH" ]; then
  echo "App bundle not found: $APP_PATH" >&2
  exit 1
fi

emit_or_run() {
  if [ "${CMUX_CODESIGN_DRY_RUN:-0}" = "1" ]; then
    printf '%q' "$CODESIGN_BIN"
    for arg in "$@"; do
      printf ' %q' "$arg"
    done
    printf '\n'
    return 0
  fi

  "$CODESIGN_BIN" "$@"
}

sign_without_entitlements() {
  local path="$1"
  [ -e "$path" ] || return 0
  emit_or_run --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$path"
}

sign_with_entitlements() {
  local path="$1"
  [ -e "$path" ] || return 0
  emit_or_run --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" --entitlements "$ENTITLEMENTS_PATH" "$path"
}

resolve_sparkle_version_dir() {
  local sparkle_framework="$1"
  local current_dir="$sparkle_framework/Versions/Current"

  if [ -d "$current_dir" ]; then
    printf '%s\n' "$current_dir"
    return 0
  fi

  find "$sparkle_framework/Versions" -mindepth 1 -maxdepth 1 -type d ! -name Current -print | LC_ALL=C sort | head -n 1
}

FRAMEWORKS_DIR="$APP_PATH/Contents/Frameworks"
SPARKLE_FRAMEWORK="$FRAMEWORKS_DIR/Sparkle.framework"
SPARKLE_VERSION_DIR=""

if [ -d "$SPARKLE_FRAMEWORK/Versions" ]; then
  SPARKLE_VERSION_DIR="$(resolve_sparkle_version_dir "$SPARKLE_FRAMEWORK")"
fi

if [ -n "$SPARKLE_VERSION_DIR" ]; then
  sign_without_entitlements "$SPARKLE_VERSION_DIR/XPCServices/Installer.xpc"
  sign_without_entitlements "$SPARKLE_VERSION_DIR/XPCServices/Downloader.xpc"
  sign_without_entitlements "$SPARKLE_VERSION_DIR/Autoupdate"
  sign_without_entitlements "$SPARKLE_VERSION_DIR/Updater.app"
fi

sign_without_entitlements "$SPARKLE_FRAMEWORK"

if [ -d "$FRAMEWORKS_DIR" ]; then
  while IFS= read -r dependency; do
    [ "$dependency" = "$SPARKLE_FRAMEWORK" ] && continue
    sign_without_entitlements "$dependency"
  done < <(
    find "$FRAMEWORKS_DIR" -mindepth 1 -maxdepth 1 \
      \( -name '*.framework' -o -name '*.bundle' -o -name '*.dylib' \) \
      -print | LC_ALL=C sort
  )
fi

sign_with_entitlements "$APP_PATH/Contents/Resources/bin/cmux"
sign_with_entitlements "$APP_PATH/Contents/Resources/bin/ghostty"
sign_with_entitlements "$APP_PATH"

emit_or_run --verify --deep --strict --verbose=2 "$APP_PATH"
