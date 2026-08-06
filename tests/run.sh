#!/usr/bin/env bash
# Runs every tests/test-*.sh and reports an aggregate result.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

rc=0
for t in test-*.sh; do
  echo "=== ${t}"
  if bash "$t"; then
    echo "=== ${t}: PASS"
  else
    echo "=== ${t}: FAIL"
    rc=1
  fi
done
exit "$rc"
