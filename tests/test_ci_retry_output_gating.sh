#!/usr/bin/env bash
# Regression test for retry and wrapper logic on continue-on-error CI jobs.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CI_WORKFLOW_FILE="$ROOT_DIR/.github/workflows/ci.yml"
BUILD_WORKFLOW_FILE="$ROOT_DIR/.github/workflows/build-ghosttykit.yml"

extract_job_block() {
  local workflow_file="$1"
  local job_name="$2"

  awk -v job_header="  ${job_name}:" '
    $0 == job_header { in_job=1; print; next }
    in_job && /^  [^[:space:]]/ { exit }
    in_job { print }
  ' "$workflow_file"
}

assert_job_if_uses_outputs_only() {
  local workflow_file="$1"
  local job_name="$2"
  local required_output="$3"
  local block
  local if_line

  block="$(extract_job_block "$workflow_file" "$job_name")"
  if [ -z "$block" ]; then
    echo "FAIL: missing job block for $job_name"
    exit 1
  fi

  if_line="$(printf '%s\n' "$block" | grep -m1 '^[[:space:]]*if:')"
  if [ -z "$if_line" ]; then
    echo "FAIL: missing if: line for $job_name"
    exit 1
  fi

  if [[ "$if_line" != *"$required_output"* ]]; then
    echo "FAIL: $job_name retry guard must key off $required_output"
    exit 1
  fi

  if [[ "$if_line" == *".result"* ]]; then
    echo "FAIL: $job_name retry guard must not depend on needs.<job>.result"
    exit 1
  fi
}

assert_job_block_contains() {
  local workflow_file="$1"
  local job_name="$2"
  local pattern="$3"
  local message="$4"
  local block

  block="$(extract_job_block "$workflow_file" "$job_name")"
  if [ -z "$block" ]; then
    echo "FAIL: missing job block for $job_name"
    exit 1
  fi

  if ! printf '%s\n' "$block" | grep -Fq -- "$pattern"; then
    echo "FAIL: $message"
    exit 1
  fi
}

for shard in 1 2 3 4 5 6; do
  assert_job_if_uses_outputs_only \
    "$CI_WORKFLOW_FILE" \
    "tests-shard-${shard}-attempt-2" \
    "outputs.test_started != 'true'"
  assert_job_block_contains \
    "$CI_WORKFLOW_FILE" \
    "tests-shard-${shard}" \
    'if [ "$ATTEMPT_1_PASSED" = "true" ] || [ "$ATTEMPT_2_PASSED" = "true" ]; then' \
    "tests-shard-${shard} wrapper must key success off passed outputs"
done

assert_job_if_uses_outputs_only \
  "$CI_WORKFLOW_FILE" \
  "tests-build-and-lag-attempt-2" \
  "outputs.test_started != 'true'"
assert_job_block_contains \
  "$CI_WORKFLOW_FILE" \
  "tests-build-and-lag" \
  'if [ "$ATTEMPT_1_PASSED" = "true" ] || [ "$ATTEMPT_2_PASSED" = "true" ]; then' \
  "tests-build-and-lag wrapper must key success off passed outputs"

assert_job_if_uses_outputs_only \
  "$CI_WORKFLOW_FILE" \
  "ui-display-resolution-regression-attempt-2" \
  "outputs.test_started != 'true'"
assert_job_block_contains \
  "$CI_WORKFLOW_FILE" \
  "ui-display-resolution-regression" \
  'if [ "$ATTEMPT_1_PASSED" = "true" ] || [ "$ATTEMPT_2_PASSED" = "true" ]; then' \
  "ui-display-resolution-regression wrapper must key success off passed outputs"

assert_job_if_uses_outputs_only \
  "$BUILD_WORKFLOW_FILE" \
  "build-ghosttykit-attempt-2" \
  "outputs.build_started != 'true'"
assert_job_block_contains \
  "$BUILD_WORKFLOW_FILE" \
  "build-ghosttykit-attempt-1" \
  'passed: ${{ steps.mark-build-pass.outputs.value }}' \
  "build-ghosttykit-attempt-1 must expose a passed output"
assert_job_block_contains \
  "$BUILD_WORKFLOW_FILE" \
  "build-ghosttykit-attempt-2" \
  'passed: ${{ steps.mark-build-pass.outputs.value }}' \
  "build-ghosttykit-attempt-2 must expose a passed output"
assert_job_block_contains \
  "$BUILD_WORKFLOW_FILE" \
  "build-ghosttykit" \
  'if [ "$ATTEMPT_1_PASSED" = "true" ] || [ "$ATTEMPT_2_PASSED" = "true" ]; then' \
  "build-ghosttykit wrapper must key success off passed outputs"

echo "PASS: retry and wrapper guards use explicit outputs, not needs.<job>.result"
