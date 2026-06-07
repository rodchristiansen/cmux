#!/usr/bin/env bash
# Format/uniformity check for CURRENT_PROJECT_VERSION.
#
# This fork uses date-based versioning (YYYYMMDDHHMM as the build number, set
# by scripts/bump-version.sh). Strict monotonicity is guaranteed by the clock,
# so we no longer compare against any published appcast; we only enforce that
# the value parses as a 12-digit integer and is uniform across build configs.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_FILE="$ROOT_DIR/GhosttyTabs.xcodeproj/project.pbxproj"

if [[ ! -f "$PROJECT_FILE" ]]; then
  echo "FAIL: $PROJECT_FILE not found" >&2
  exit 1
fi

LOCAL_BUILD=$(grep -m1 'CURRENT_PROJECT_VERSION = ' "$PROJECT_FILE" | sed 's/.*= //;s/;.*//')
if ! [[ "$LOCAL_BUILD" =~ ^[0-9]{12}$ ]]; then
  echo "FAIL: CURRENT_PROJECT_VERSION must be a 12-digit YYYYMMDDHHMM integer (got '$LOCAL_BUILD'). Run scripts/bump-version.sh." >&2
  exit 1
fi

UNIQ=$(grep 'CURRENT_PROJECT_VERSION = ' "$PROJECT_FILE" | sort -u | wc -l | tr -d ' ')
if [[ "$UNIQ" != "1" ]]; then
  echo "FAIL: CURRENT_PROJECT_VERSION values are inconsistent across build configurations:" >&2
  grep 'CURRENT_PROJECT_VERSION = ' "$PROJECT_FILE" | sort -u >&2
  exit 1
fi

echo "PASS: CURRENT_PROJECT_VERSION=$LOCAL_BUILD (uniform across build configs)"
