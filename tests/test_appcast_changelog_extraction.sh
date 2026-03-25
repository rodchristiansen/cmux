#!/usr/bin/env bash
set -euo pipefail

tmp_changelog="$(mktemp)"
trap 'rm -f "$tmp_changelog"' EXIT

cat >"$tmp_changelog" <<'EOF'
# Changelog

## [1.2.3] - 2026-01-01

### Added
- New feature ([#1](https://example.com/pulls/1))
- `inline code` and **bold text**

### Fixed
- Bug fix with _italics_

## [1.2.2] - 2025-12-31

### Added
- Older feature
EOF

expected_output=$'Added\n• New feature (#1)\n• inline code and bold text\n\nFixed\n• Bug fix with italics'
actual_output="$(python3 scripts/appcast_changelog.py --tag v1.2.3 --changelog "$tmp_changelog")"

if [[ "$actual_output" != "$expected_output" ]]; then
  echo "Unexpected formatted changelog output" >&2
  printf 'Expected:\n%s\n' "$expected_output" >&2
  printf 'Actual:\n%s\n' "$actual_output" >&2
  exit 1
fi

missing_output="$(python3 scripts/appcast_changelog.py --tag v9.9.9 --changelog "$tmp_changelog")"
if [[ -n "$missing_output" ]]; then
  echo "Expected no changelog output for an unknown tag" >&2
  printf 'Actual:\n%s\n' "$missing_output" >&2
  exit 1
fi
