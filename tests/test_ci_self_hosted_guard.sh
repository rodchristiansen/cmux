#!/usr/bin/env bash
# Regression test for https://github.com/manaflow-ai/cmux/issues/385.
# Ensures paid/gated CI jobs are never run for fork pull requests.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW_FILE="$ROOT_DIR/.github/workflows/ci.yml"

EXPECTED_IF="if: github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository"

if ! grep -Fq "$EXPECTED_IF" "$WORKFLOW_FILE"; then
  echo "FAIL: Missing fork pull_request guard in $WORKFLOW_FILE"
  echo "Expected line:"
  echo "  $EXPECTED_IF"
  exit 1
fi

# tests-shard-1: must use WarpBuild runner with fork guard (paid runner)
if ! awk '
  /^  tests-shard-1:/ { in_tests=1; next }
  in_tests && /^  [^[:space:]]/ { in_tests=0 }
  in_tests && /runs-on: warp-macos-15-arm64-6x/ { saw_warp=1 }
  in_tests && /github.event.pull_request.head.repo.full_name == github.repository/ { saw_guard=1 }
  END { exit !(saw_warp && saw_guard) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: tests-shard-1 block must keep both warp-macos-15-arm64-6x runner and fork guard"
  exit 1
fi

# tests-shard-2: must use WarpBuild runner with fork guard (paid runner)
if ! awk '
  /^  tests-shard-2:/ { in_tests=1; next }
  in_tests && /^  [^[:space:]]/ { in_tests=0 }
  in_tests && /runs-on: warp-macos-15-arm64-6x/ { saw_warp=1 }
  in_tests && /github.event.pull_request.head.repo.full_name == github.repository/ { saw_guard=1 }
  END { exit !(saw_warp && saw_guard) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: tests-shard-2 block must keep both warp-macos-15-arm64-6x runner and fork guard"
  exit 1
fi

# tests-shard-3: must use WarpBuild runner with fork guard (paid runner)
if ! awk '
  /^  tests-shard-3:/ { in_tests=1; next }
  in_tests && /^  [^[:space:]]/ { in_tests=0 }
  in_tests && /runs-on: warp-macos-15-arm64-6x/ { saw_warp=1 }
  in_tests && /github.event.pull_request.head.repo.full_name == github.repository/ { saw_guard=1 }
  END { exit !(saw_warp && saw_guard) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: tests-shard-3 block must keep both warp-macos-15-arm64-6x runner and fork guard"
  exit 1
fi

# tests-shard-4: must use WarpBuild runner with fork guard (paid runner)
if ! awk '
  /^  tests-shard-4:/ { in_tests=1; next }
  in_tests && /^  [^[:space:]]/ { in_tests=0 }
  in_tests && /runs-on: warp-macos-15-arm64-6x/ { saw_warp=1 }
  in_tests && /github.event.pull_request.head.repo.full_name == github.repository/ { saw_guard=1 }
  END { exit !(saw_warp && saw_guard) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: tests-shard-4 block must keep both warp-macos-15-arm64-6x runner and fork guard"
  exit 1
fi

# tests-shard-5: must use WarpBuild runner with fork guard (paid runner)
if ! awk '
  /^  tests-shard-5:/ { in_tests=1; next }
  in_tests && /^  [^[:space:]]/ { in_tests=0 }
  in_tests && /runs-on: warp-macos-15-arm64-6x/ { saw_warp=1 }
  in_tests && /github.event.pull_request.head.repo.full_name == github.repository/ { saw_guard=1 }
  END { exit !(saw_warp && saw_guard) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: tests-shard-5 block must keep both warp-macos-15-arm64-6x runner and fork guard"
  exit 1
fi

# tests-shard-6: must use WarpBuild runner with fork guard (paid runner)
if ! awk '
  /^  tests-shard-6:/ { in_tests=1; next }
  in_tests && /^  [^[:space:]]/ { in_tests=0 }
  in_tests && /runs-on: warp-macos-15-arm64-6x/ { saw_warp=1 }
  in_tests && /github.event.pull_request.head.repo.full_name == github.repository/ { saw_guard=1 }
  END { exit !(saw_warp && saw_guard) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: tests-shard-6 block must keep both warp-macos-15-arm64-6x runner and fork guard"
  exit 1
fi

# tests wrapper: should stay on hosted Linux because it only aggregates shard outputs.
if ! awk '
  /^  tests:/ { in_tests=1; next }
  in_tests && /^  [^[:space:]]/ { in_tests=0 }
  in_tests && /runs-on: ubuntu-latest/ { saw_hosted=1 }
  in_tests && /github.event.pull_request.head.repo.full_name == github.repository/ { saw_guard=1 }
  END { exit !(saw_hosted && saw_guard) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: tests wrapper must keep both ubuntu-latest runner and fork guard"
  exit 1
fi

# tests-build-and-lag-attempt-1: must use WarpBuild runner with fork guard (paid runner)
if ! awk '
  /^  tests-build-and-lag-attempt-1:/ { in_tests=1; next }
  in_tests && /^  [^[:space:]]/ { in_tests=0 }
  in_tests && /runs-on: warp-macos-15-arm64-6x/ { saw_warp=1 }
  in_tests && /github.event.pull_request.head.repo.full_name == github.repository/ { saw_guard=1 }
  END { exit !(saw_warp && saw_guard) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: tests-build-and-lag-attempt-1 block must keep both warp-macos-15-arm64-6x runner and fork guard"
  exit 1
fi

# tests-build-and-lag-attempt-2: must use WarpBuild runner with fork guard (paid runner)
if ! awk '
  /^  tests-build-and-lag-attempt-2:/ { in_tests=1; next }
  in_tests && /^  [^[:space:]]/ { in_tests=0 }
  in_tests && /runs-on: warp-macos-15-arm64-6x/ { saw_warp=1 }
  in_tests && /github.event.pull_request.head.repo.full_name == github.repository/ { saw_guard=1 }
  END { exit !(saw_warp && saw_guard) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: tests-build-and-lag-attempt-2 block must keep both warp-macos-15-arm64-6x runner and fork guard"
  exit 1
fi

# tests-build-and-lag wrapper: should stay on hosted Linux because it only aggregates attempt outputs.
if ! awk '
  /^  tests-build-and-lag:/ { in_tests=1; next }
  in_tests && /^  [^[:space:]]/ { in_tests=0 }
  in_tests && /runs-on: ubuntu-latest/ { saw_hosted=1 }
  in_tests && /github.event.pull_request.head.repo.full_name == github.repository/ { saw_guard=1 }
  END { exit !(saw_hosted && saw_guard) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: tests-build-and-lag wrapper must keep both ubuntu-latest runner and fork guard"
  exit 1
fi

# ui-display-resolution-regression-attempt-1: must use WarpBuild runner with fork guard (paid runner)
if ! awk '
  /^  ui-display-resolution-regression-attempt-1:/ { in_tests=1; next }
  in_tests && /^  [^[:space:]]/ { in_tests=0 }
  in_tests && /runs-on: warp-macos-15-arm64-6x/ { saw_warp=1 }
  in_tests && /github.event.pull_request.head.repo.full_name == github.repository/ { saw_guard=1 }
  END { exit !(saw_warp && saw_guard) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: ui-display-resolution-regression-attempt-1 block must keep both warp-macos-15-arm64-6x runner and fork guard"
  exit 1
fi

# ui-display-resolution-regression-attempt-2: must use WarpBuild runner with fork guard (paid runner)
if ! awk '
  /^  ui-display-resolution-regression-attempt-2:/ { in_tests=1; next }
  in_tests && /^  [^[:space:]]/ { in_tests=0 }
  in_tests && /runs-on: warp-macos-15-arm64-6x/ { saw_warp=1 }
  in_tests && /github.event.pull_request.head.repo.full_name == github.repository/ { saw_guard=1 }
  END { exit !(saw_warp && saw_guard) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: ui-display-resolution-regression-attempt-2 block must keep both warp-macos-15-arm64-6x runner and fork guard"
  exit 1
fi

# ui-display-resolution-regression wrapper: should stay on hosted Linux because it only aggregates attempt outputs.
if ! awk '
  /^  ui-display-resolution-regression:/ { in_tests=1; next }
  in_tests && /^  [^[:space:]]/ { in_tests=0 }
  in_tests && /runs-on: ubuntu-latest/ { saw_hosted=1 }
  in_tests && /github.event.pull_request.head.repo.full_name == github.repository/ { saw_guard=1 }
  END { exit !(saw_hosted && saw_guard) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: ui-display-resolution-regression wrapper must keep both ubuntu-latest runner and fork guard"
  exit 1
fi

echo "PASS: tests-shard-1 WarpBuild runner fork guard is present"
echo "PASS: tests-shard-2 WarpBuild runner fork guard is present"
echo "PASS: tests-shard-3 WarpBuild runner fork guard is present"
echo "PASS: tests-shard-4 WarpBuild runner fork guard is present"
echo "PASS: tests-shard-5 WarpBuild runner fork guard is present"
echo "PASS: tests-shard-6 WarpBuild runner fork guard is present"
echo "PASS: tests wrapper hosted runner guard is present"
echo "PASS: tests-build-and-lag attempt-1 WarpBuild runner fork guard is present"
echo "PASS: tests-build-and-lag attempt-2 WarpBuild runner fork guard is present"
echo "PASS: tests-build-and-lag wrapper hosted runner guard is present"
echo "PASS: ui-display-resolution-regression attempt-1 WarpBuild runner fork guard is present"
echo "PASS: ui-display-resolution-regression attempt-2 WarpBuild runner fork guard is present"
echo "PASS: ui-display-resolution-regression wrapper hosted runner guard is present"
