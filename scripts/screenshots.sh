#!/usr/bin/env bash
# screenshots mode: upload PNGs to the VRT CI REST API directly.
# Sourced by main.sh; relies on resolved globals and lib.sh helpers.
#
# shellcheck disable=SC2034
# SC2034 (unused variable) is unreliable here: this file is sourced into main.sh,
# which reads the globals assigned below (CODE, RESULT, BUILD_*) after dispatch.
set -euo pipefail

run_screenshots() {
  # 1-4: validate and enumerate the PNG set before creating anything.
  collect_pngs "$DIR"
  log "Found ${#PNG_PATHS[@]} screenshot(s) under ${DIR}."

  # 5: create the build.
  local body
  body="$(build_create_body screenshots)"
  local tmp_body
  tmp_body="$(mktemp)"
  printf '%s' "$body" >"$tmp_body"
  request POST "$URL/v1/ci/projects/$TENANT/$PROJECT_SLUG/builds" \
    -H "Content-Type: application/json" --data-binary "@$tmp_body"
  rm -f "$tmp_body"
  require_2xx "Build creation"

  BUILD_ID="$(printf '%s' "$RESP_BODY" | jq -r '.id')"
  BUILD_NUMBER="$(printf '%s' "$RESP_BODY" | jq -r '.number')"
  [ -n "$BUILD_ID" ] && [ "$BUILD_ID" != "null" ] || die "build creation response missing 'id': ${RESP_BODY}"
  RESULT="$(printf '%s' "$RESP_BODY" | jq -r '.status')"
  CODE=2 # default pessimistic until we know better; records outputs on failure.
  compute_build_url
  write_outputs # flush build-id/build-url as early as possible.
  log "Created build ${BUILD_NUMBER} (${BUILD_ID})."

  # 6: upload each screenshot.
  local i=0 name path
  while [ "$i" -lt "${#PNG_PATHS[@]}" ]; do
    name="${PNG_NAMES[$i]}"
    path="${PNG_PATHS[$i]}"
    request POST "$URL/v1/ci/builds/$BUILD_ID/screenshots" \
      -F "name=$name" -F "file=@$path;type=image/png"
    require_2xx "Uploading screenshot '${name}'"
    log "Uploaded ${name}."
    i=$((i + 1))
  done

  # 7: finalize.
  request POST "$URL/v1/ci/builds/$BUILD_ID/finalize"
  require_2xx "Finalize"
  RESULT="$(printf '%s' "$RESP_BODY" | jq -r '.status // empty')"
  log "Finalized build ${BUILD_NUMBER}."

  # 8: wait for a terminal status if requested.
  if [ "$WAIT" = "true" ]; then
    poll_until_terminal "$BUILD_ID"
    CODE="$(status_to_exit_code "$RESULT")"
  else
    # Build created, uploaded and finalized successfully: the action succeeds.
    CODE=0
  fi
}

# poll_until_terminal BUILD_ID
# Updates RESULT with the latest status; on a terminal status it returns with
# CODE unset (caller maps it). On timeout it dies with exit code 2.
poll_until_terminal() {
  local id="$1"
  local deadline now st
  deadline=$(($(date +%s) + POLL_TIMEOUT_SECONDS))
  while :; do
    request GET "$URL/v1/ci/builds/$id"
    require_2xx "Fetching build status"
    st="$(printf '%s' "$RESP_BODY" | jq -r '.status')"
    RESULT="$st"
    if is_terminal_status "$st"; then
      log "Build ${BUILD_NUMBER} reached terminal status: ${st}."
      return 0
    fi
    now="$(date +%s)"
    if [ "$now" -ge "$deadline" ]; then
      CODE=2
      die "timed out after ${POLL_TIMEOUT_SECONDS}s waiting for build ${BUILD_NUMBER} to finish (last status: ${st})."
    fi
    log "Build ${BUILD_NUMBER} status: ${st}; waiting ${POLL_INTERVAL_SECONDS}s..."
    sleep "$POLL_INTERVAL_SECONDS"
  done
}
