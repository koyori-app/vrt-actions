#!/usr/bin/env bash
# Orchestrator for the VRT action. Runs as a single composite step so ordering
# is fully controlled: resolve -> validate -> dispatch -> write outputs -> exit.
# Outputs are written before the final `exit` so callers with
# `continue-on-error: true` can read build-url even when the build has changes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"
# shellcheck source=scripts/validate.sh
. "$SCRIPT_DIR/validate.sh"
# shellcheck source=scripts/collect-pngs.sh
. "$SCRIPT_DIR/collect-pngs.sh"
# shellcheck source=scripts/screenshots.sh
. "$SCRIPT_DIR/screenshots.sh"
# shellcheck source=scripts/storybook.sh
. "$SCRIPT_DIR/storybook.sh"

# Mask the token in logs before it is used anywhere.
if [ -n "${INPUT_TOKEN:-}" ]; then
  echo "::add-mask::${INPUT_TOKEN}"
fi

resolve_inputs
validate_inputs
init_auth_config

# Best-effort optional build metadata. Never fatal.
PR_NUMBER="${PR_NUMBER:-}"
COMMIT_MESSAGE=""
if command -v git >/dev/null 2>&1 && [ -n "$COMMIT" ]; then
  COMMIT_MESSAGE="$(git log -1 --pretty=%B "$COMMIT" 2>/dev/null || true)"
fi

# Outputs start empty; dispatch fills them in.
BUILD_ID=""
BUILD_NUMBER=""
BUILD_URL=""
RESULT=""
CODE=0

case "$MODE" in
  screenshots) run_screenshots ;;
  storybook) run_storybook ;;
esac

# Persist outputs, then exit with the resolved code (wait:true reflects the VRT
# result; wait:false is 0 once the build was created, uploaded and finalized).
write_outputs
log "Done: result=${RESULT} exit-code=${CODE} build-url=${BUILD_URL}"
exit "${CODE:-0}"
