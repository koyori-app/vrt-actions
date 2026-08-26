#!/usr/bin/env bash
# Input resolution and validation for the VRT action.
#
# shellcheck disable=SC2034
# SC2034 (unused variable) is unreliable here: the globals resolved below are
# consumed by the other scripts that main.sh sources alongside this one.
#
# When sourced, this file defines `resolve_inputs` and `validate_inputs`.
# When executed directly, it resolves and validates the current INPUT_* /
# GITHUB_* environment and prints "validation: OK" on success. This lets the
# validation logic be exercised without touching the VRT API.
set -euo pipefail

_VALIDATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$_VALIDATE_DIR/lib.sh"

# resolve_inputs derives the effective configuration from INPUT_* / GITHUB_*
# and exports it as plain globals used by the rest of the scripts.
resolve_inputs() {
  TOKEN="${INPUT_TOKEN:-}"
  PROJECT_INPUT="${INPUT_PROJECT:-}"
  URL="$(strip_trailing_slash "${INPUT_URL:-}")"
  MODE="${INPUT_MODE:-screenshots}"
  ONLY_CHANGED="${INPUT_ONLY_CHANGED:-false}"
  STATS_JSON="${INPUT_STATS_JSON:-}"
  WAIT="${INPUT_WAIT:-true}"
  # 空白付きの ' main' を「一致しないブランチ名」として黙って無効化しないよう詰める。
  EXIT_ZERO_ON_CHANGES="$(trim_whitespace "${INPUT_EXIT_ZERO_ON_CHANGES:-}")"
  CLI_VERSION="${INPUT_CLI_VERSION:-latest}"
  # Token used only to resolve the latest cli-v* release (storybook mode). May be
  # empty on forked PRs where the workflow token is restricted.
  GITHUB_TOKEN="${INPUT_GITHUB_TOKEN:-}"

  # dir default depends on the mode.
  DIR="${INPUT_DIR:-}"
  if [ -z "$DIR" ]; then
    case "$MODE" in
      storybook) DIR="./storybook-static" ;;
      *) DIR="./screenshots" ;;
    esac
  fi
  DIR="$(strip_trailing_slash "$DIR")"

  # branch default: input -> GITHUB_HEAD_REF -> GITHUB_REF_NAME.
  BRANCH="${INPUT_BRANCH:-}"
  if [ -z "$BRANCH" ]; then
    BRANCH="${GITHUB_HEAD_REF:-}"
  fi
  if [ -z "$BRANCH" ]; then
    BRANCH="${GITHUB_REF_NAME:-}"
  fi

  # commit default: input -> pull_request.head.sha -> GITHUB_SHA.
  # The PR head SHA is preferred over GITHUB_SHA because, on pull_request
  # events, GITHUB_SHA points at an ephemeral merge commit that does not exist
  # on the PR branch, so commit statuses cannot be attached to it.
  COMMIT="${INPUT_COMMIT:-}"
  if [ -z "$COMMIT" ]; then
    COMMIT="${PR_HEAD_SHA:-}"
  fi
  if [ -z "$COMMIT" ]; then
    COMMIT="${GITHUB_SHA:-}"
  fi

  # app-url: input, else the API url with a trailing "/api" removed so the web
  # UI base can be derived under reverse-proxy layouts (https://host/api ->
  # https://host).
  APP_URL="$(strip_trailing_slash "${INPUT_APP_URL:-}")"
  if [ -z "$APP_URL" ]; then
    APP_URL="${URL%/api}"
  fi

  # Effective stats-json path when only-changed is on and none was provided.
  if [ "$ONLY_CHANGED" = "true" ] && [ -z "$STATS_JSON" ]; then
    STATS_JSON="$DIR/preview-stats.json"
  fi

  # Split project into tenant / project slug (validated below).
  TENANT="${PROJECT_INPUT%%/*}"
  PROJECT_SLUG="${PROJECT_INPUT#*/}"
}

validate_inputs() {
  [ -n "$TOKEN" ] || die "input 'token' is required but empty. Provide a VRT Personal Access Token, e.g. token: \${{ secrets.VRT_TOKEN }}."
  [ -n "${INPUT_URL:-}" ] || die "input 'url' is required but empty. Provide the VRT base URL, e.g. url: https://vrt.example.com."

  case "$MODE" in
    screenshots | storybook) ;;
    *) die "input 'mode' must be 'screenshots' or 'storybook', got '${MODE}'." ;;
  esac

  # 真偽値の入力は mode と同様に弾く。誤記を黙って false に倒すと、
  # wait の場合は回帰があってもワークフローが緑で通ってしまう。
  for pair in "wait:$WAIT" "only-changed:$ONLY_CHANGED"; do
    case "${pair#*:}" in
      true | false) ;;
      *) die "input '${pair%%:*}' must be 'true' or 'false', got '${pair#*:}'." ;;
    esac
  done

  # project must be tenant/project with both parts non-empty and exactly one slash.
  if [ "$PROJECT_INPUT" = "$TENANT" ] || [ -z "$TENANT" ] || [ -z "$PROJECT_SLUG" ] || [ "$PROJECT_SLUG" != "${PROJECT_SLUG%/*}" ]; then
    die "input 'project' must be in 'tenant-slug/project-slug' form, got '${PROJECT_INPUT}'."
  fi

  if [ "$ONLY_CHANGED" = "true" ] && [ "$MODE" = "screenshots" ]; then
    die "input 'only-changed: true' is only valid for mode 'storybook'. Remove only-changed or switch to mode: storybook."
  fi

  # A user-supplied stats-json only makes sense with only-changed: true.
  if [ -n "${INPUT_STATS_JSON:-}" ] && [ "$ONLY_CHANGED" != "true" ]; then
    die "input 'stats-json' requires 'only-changed: true'. Set only-changed: true or remove stats-json."
  fi
}

# Direct execution: resolve + validate the current environment.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  resolve_inputs
  validate_inputs
  echo "validation: OK (mode=${MODE} tenant=${TENANT} project=${PROJECT_SLUG} dir=${DIR} branch=${BRANCH} commit=${COMMIT})" >&2
fi
