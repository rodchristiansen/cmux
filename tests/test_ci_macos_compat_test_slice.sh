#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW_FILE="$ROOT_DIR/.github/workflows/ci-macos-compat.yml"

if ! awk '
  /^      - name: Run compatibility unit test slice$/ { in_step=1; next }
  in_step && /^      - name:/ { in_step=0 }
  in_step && /scripts\/unit_test_shard_args\.py/ { saw_shard_args=1 }
  in_step && /-scheme cmux-unit/ { saw_unit_scheme=1 }
  in_step && /test 2>&1/ { saw_test=1 }
  END { exit !(saw_shard_args && saw_unit_scheme && saw_test) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: ci-macos-compat.yml must keep a real compatibility unit test slice"
  exit 1
fi

echo "PASS: macOS compat workflow keeps a compatibility unit test slice"
