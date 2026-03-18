#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW_FILE="$ROOT_DIR/.github/workflows/ci-macos-compat.yml"

require_pattern() {
  local pattern="$1"
  local message="$2"
  if ! grep -q -- "$pattern" "$WORKFLOW_FILE"; then
    echo "FAIL: $message"
    exit 1
  fi
}

reject_pattern() {
  local pattern="$1"
  local message="$2"
  if grep -q -- "$pattern" "$WORKFLOW_FILE"; then
    echo "FAIL: $message"
    exit 1
  fi
}

require_pattern "compat_test_filters:" "ci-macos-compat.yml must define explicit compatibility test filters"
require_pattern "cmuxTests/AppDelegateLaunchServicesRegistrationTests" "macOS 15 compat filters are missing"
require_pattern "cmuxTests/ZshShellIntegrationHandoffTests" "macOS 26 compat filters are missing"
require_pattern "while IFS= read -r filter; do" "compat step must still load test filters into an array"
require_pattern "-scheme cmux-unit" "compat step must run the cmux-unit scheme"
require_pattern "test 2>&1" "compat step must execute unit tests"
reject_pattern "scripts/unit_test_shard_args.py" "compat workflow must not rely on shard-based test selection"

echo "PASS: macOS compat workflow keeps an explicit compatibility unit test slice"
