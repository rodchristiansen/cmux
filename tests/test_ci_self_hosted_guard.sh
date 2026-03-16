#!/usr/bin/env bash
# Regression test for https://github.com/manaflow-ai/cmux/issues/385.
# Ensures pull_request CI stays on GitHub-hosted runners and privileged
# workflows stay off the PR path.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PR_WORKFLOW="$ROOT_DIR/.github/workflows/ci.yml"
DEPOT_WORKFLOW="$ROOT_DIR/.github/workflows/test-depot.yml"
BUILD_GHOSTTYKIT_WORKFLOW="$ROOT_DIR/.github/workflows/build-ghosttykit.yml"

if ! grep -Eq '^  pull_request:$' "$PR_WORKFLOW"; then
  echo "FAIL: $PR_WORKFLOW must remain the pull_request workflow"
  exit 1
fi

if grep -Fq 'runs-on: depot-macos-latest' "$PR_WORKFLOW"; then
  echo "FAIL: $PR_WORKFLOW must not run Depot jobs on the pull_request path"
  exit 1
fi

if grep -Fq 'secrets.GHOSTTY_RELEASE_TOKEN' "$PR_WORKFLOW"; then
  echo "FAIL: $PR_WORKFLOW must not use release-token secrets on the pull_request path"
  exit 1
fi

for trusted_workflow in "$DEPOT_WORKFLOW" "$BUILD_GHOSTTYKIT_WORKFLOW"; do
  if grep -Eq '^  pull_request:$' "$trusted_workflow"; then
    echo "FAIL: $trusted_workflow must not trigger on pull_request"
    exit 1
  fi
done

if ! awk '
  /^  tests:/ { in_tests=1; next }
  in_tests && /^  [^[:space:]]/ { in_tests=0 }
  in_tests && /runs-on: depot-macos-latest/ { saw_depot=1 }
  END { exit !saw_depot }
' "$DEPOT_WORKFLOW"; then
  echo "FAIL: $DEPOT_WORKFLOW must keep its Depot-hosted tests job"
  exit 1
fi

echo "PASS: pull_request CI is GitHub-hosted only and privileged workflows stay trusted-only"
