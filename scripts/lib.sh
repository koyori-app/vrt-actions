#!/usr/bin/env bash
# Common helpers shared by the VRT action scripts.
# This file is meant to be sourced, not executed directly.
#
# shellcheck disable=SC2034
# SC2034 (unused variable) is unreliable here: the constants below are consumed
# by the other scripts that main.sh sources alongside this one.
set -euo pipefail

# Guard against double-sourcing (readonly constants would otherwise re-error).
if [ -n "${_VRT_LIB_SOURCED:-}" ]; then
  return 0
fi
_VRT_LIB_SOURCED=1

# --- Constants -------------------------------------------------------------

# Per-screenshot upload limit (25 MiB), matching the VRT screenshots API.
readonly MAX_PNG_BYTES=$((25 * 1024 * 1024))

# Polling configuration for `wait: true`.
readonly POLL_INTERVAL_SECONDS=5
readonly POLL_TIMEOUT_SECONDS=1800 # 30 minutes.

# curl timeouts. Without --max-time a hung request blocks forever and the
# 30-minute poll deadline is never re-evaluated, so the action never exits.
readonly CURL_CONNECT_TIMEOUT_SECONDS=15
readonly CURL_MAX_TIME_SECONDS=300 # generous: uploads may carry 25 MiB PNGs.

# --- Output handling -------------------------------------------------------
# Outputs must be written regardless of the final exit code so that callers
# using `continue-on-error: true` can still read `build-url` etc. We append to
# $GITHUB_OUTPUT (last write wins for a given key), so build-id/build-url can be
# recorded as soon as the build exists and result/exit-code updated at the end.

_OUTPUTS_WRITTEN=0

write_outputs() {
  # Idempotent-ish: appending the same key again lets the last value win.
  _OUTPUTS_WRITTEN=1
  {
    echo "build-id=${BUILD_ID:-}"
    echo "build-url=${BUILD_URL:-}"
    echo "result=${RESULT:-}"
    echo "exit-code=${CODE:-}"
  } >>"${GITHUB_OUTPUT:-/dev/null}"
}

# --- Logging / errors ------------------------------------------------------

log() {
  echo "$*" >&2
}

# die prints a GitHub Actions error annotation, records a failed result, and
# exits. Outputs are always flushed so callers can read result/exit-code (and
# build-url once a build exists) regardless of where the failure happened.
#
# The exit code is assigned unconditionally, never with `:=`. main.sh initialises
# CODE=0 before dispatching, so a conditional assignment would leave CODE at 0
# and make a fatal error exit successfully — the workflow would go green while
# the outputs said result=failed.
#
# write_outputs is defensive (every field uses ${VAR:-} and it appends to
# ${GITHUB_OUTPUT:-/dev/null}), so calling die from an early stage such as
# validate_inputs — before GITHUB_OUTPUT or the BUILD_* globals exist — cannot
# raise a secondary error under `set -u`.
die() {
  echo "::error::$*" >&2
  local code=1
  if [ -n "${BUILD_ID:-}" ]; then
    # ビルドが存在する = 実行時の失敗。作成前の失敗（使い方の誤り）と終了コードで区別する。
    code=2
  fi
  RESULT="failed"
  CODE="$code"
  write_outputs
  exit "$code"
}

# --- URL helpers -----------------------------------------------------------

# Strip a single trailing slash.
strip_trailing_slash() {
  local v="$1"
  printf '%s' "${v%/}"
}

# --- Status mapping --------------------------------------------------------
# Terminal states: passed / changes_detected / failed / approved / rejected.

is_terminal_status() {
  case "$1" in
    passed | changes_detected | failed | approved | rejected) return 0 ;;
    *) return 1 ;;
  esac
}

# Map a VRT build status to the documented exit code:
#   passed/approved -> 0, changes_detected -> 1, everything else -> 2.
status_to_exit_code() {
  case "$1" in
    passed | approved) echo 0 ;;
    changes_detected) echo 1 ;;
    *) echo 2 ;;
  esac
}

# --- Authenticated HTTP ----------------------------------------------------
# The bearer token is passed via a curl --config file (mode 600) so it never
# appears in the process argument list visible to `ps`.

# init_auth_config writes the auth header file and registers cleanup.
init_auth_config() {
  AUTH_CONFIG="$(mktemp)"
  chmod 600 "$AUTH_CONFIG"
  printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" >"$AUTH_CONFIG"
  # shellcheck disable=SC2064
  trap "rm -f '$AUTH_CONFIG'" EXIT
}

# try_request METHOD URL [extra curl args...]
# Sets globals RESP_BODY and RESP_CODE. Returns non-zero on a transport error
# (DNS, connect, timeout) instead of dying, so pollers can retry until their
# own deadline.
try_request() {
  local method="$1"
  local url="$2"
  shift 2
  local tmp
  tmp="$(mktemp)"
  local code
  if ! code="$(curl -sS --config "$AUTH_CONFIG" \
    --connect-timeout "$CURL_CONNECT_TIMEOUT_SECONDS" \
    --max-time "$CURL_MAX_TIME_SECONDS" \
    -X "$method" "$@" -o "$tmp" -w '%{http_code}' "$url")"; then
    rm -f "$tmp"
    return 1
  fi
  RESP_BODY="$(cat "$tmp")"
  RESP_CODE="$code"
  rm -f "$tmp"
}

# request METHOD URL [extra curl args...]
# As try_request, but a transport error is fatal. Used for create / upload /
# finalize, where a blind retry could duplicate side effects on the server.
request() {
  try_request "$@" ||
    die "HTTP request failed: $1 $2 (network error or timeout after ${CURL_MAX_TIME_SECONDS}s)"
}

# require_2xx CONTEXT
require_2xx() {
  local context="$1"
  case "$RESP_CODE" in
    2*) return 0 ;;
    *) die "$context failed with HTTP $RESP_CODE: ${RESP_BODY:-<empty body>}" ;;
  esac
}

# --- Build helpers ---------------------------------------------------------

# build_create_body MODE
# Emits the JSON body for POST .../builds. Optional fields (commit_message,
# pull_request_number) are included only when derivable from the environment.
build_create_body() {
  local mode="$1"
  jq -cn \
    --arg branch "$BRANCH" \
    --arg sha "$COMMIT" \
    --arg mode "$mode" \
    --arg msg "${COMMIT_MESSAGE:-}" \
    --arg pr "${PR_NUMBER:-}" \
    '{branch: $branch, commit_sha: $sha, mode: $mode}
     + (if $msg != "" then {commit_message: $msg} else {} end)
     + (if ($pr | test("^[0-9]+$")) then {pull_request_number: ($pr | tonumber)} else {} end)'
}

# compute_build_url derives BUILD_URL from the resolved web UI base and build.
compute_build_url() {
  BUILD_URL="${APP_URL}/t/${TENANT}/p/${PROJECT_SLUG}/builds/${BUILD_NUMBER}"
}
