#!/usr/bin/env bash
# Test driver for storybook mode: sources the action scripts, stubs
# download_cli (the only network seam) with $FAKE_VRT_CLI, and runs
# run_storybook against the resolved INPUT_* environment. Prints the resulting
# CODE / RESULT / BUILD_URL for the test to assert on.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

: "${FAKE_VRT_CLI:?set FAKE_VRT_CLI to the fake vrt binary}"

# shellcheck source=scripts/lib.sh
. scripts/lib.sh
# shellcheck source=scripts/validate.sh
. scripts/validate.sh
# shellcheck source=scripts/storybook.sh
. scripts/storybook.sh

download_cli() {
  printf '%s' "$FAKE_VRT_CLI"
}

resolve_inputs
validate_inputs

BUILD_ID=""
BUILD_NUMBER=""
BUILD_URL=""
RESULT=""
CODE=0

run_storybook
printf 'CODE=%s RESULT=%s BUILD_URL=%s\n' "$CODE" "$RESULT" "$BUILD_URL"
