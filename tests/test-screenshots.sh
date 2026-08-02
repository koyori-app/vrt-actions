#!/usr/bin/env bash
# End-to-end test of screenshots mode: main.sh against tests/fake_server.py.
# Covers the curl -F hardening (names with @ < ; quotes and a newline arrive
# verbatim), byte-intact uploads, outputs, and the changes_detected exit path.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=tests/helpers.sh
. tests/helpers.sh

command -v python3 >/dev/null 2>&1 || fail "python3 is required for this test"
command -v jq >/dev/null 2>&1 || fail "jq is required for this test"

tmp="$(mktemp -d)"
SERVER_PID=""
# NB: guard the kill — an empty PID would become `kill 0` and take down the
# whole process group, including the test runner.
trap '[ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null; rm -rf "$tmp"' EXIT

# Names curl's -F would misinterpret without --form-string / the temp copy.
shots="$tmp/shots"
mkdir -p "$shots"
NAMES=('@env' '<lt' 'a;b' 'qu"ote' $'nl\nname' 'plain')
i=0
for n in "${NAMES[@]}"; do
  printf 'fake-png-payload-%s' "$i" >"$shots/$n.png"
  i=$((i + 1))
done

# start_server RECORD_FILE FINAL_STATUS — sets SERVER_PID and PORT.
start_server() {
  : >"$tmp/port"
  RECORD_FILE="$1" FINAL_STATUS="$2" python3 tests/fake_server.py >"$tmp/port" &
  SERVER_PID=$!
  local n=0
  while [ ! -s "$tmp/port" ] && [ "$n" -lt 100 ]; do
    sleep 0.1
    n=$((n + 1))
  done
  [ -s "$tmp/port" ] || fail "fake server did not start"
  PORT="$(cat "$tmp/port")"
}

stop_server() {
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=""
}

# run_action GITHUB_OUTPUT_FILE [extra K=V...] — runs main.sh; echoes its rc.
run_action() {
  local out_file="$1"
  shift
  local rc=0
  env -i PATH="$PATH" \
    INPUT_TOKEN=test-token \
    INPUT_URL="http://127.0.0.1:${PORT}" \
    INPUT_PROJECT=acme/web \
    INPUT_MODE=screenshots \
    INPUT_DIR="$shots" \
    GITHUB_REF_NAME=main \
    GITHUB_SHA=deadbeef \
    GITHUB_OUTPUT="$out_file" \
    "$@" \
    bash scripts/main.sh >"$tmp/action.log" 2>&1 || rc=$?
  echo "$rc"
}

# output_value FILE KEY — last write wins, matching GITHUB_OUTPUT semantics.
output_value() {
  grep "^$2=" "$1" | tail -n 1 | cut -d= -f2-
}

# --- Case 1: wait:true, server ends at "passed". -----------------------------
start_server "$tmp/received.jsonl" passed
: >"$tmp/gh_output"
rc="$(run_action "$tmp/gh_output" INPUT_WAIT=true)"
[ "$rc" -eq 0 ] || { cat "$tmp/action.log" >&2; fail "expected exit 0, got $rc"; }
pass "action exits 0 on passed"

assert_eq "passed" "$(output_value "$tmp/gh_output" result)" "result output"
assert_eq "0" "$(output_value "$tmp/gh_output" exit-code)" "exit-code output"
assert_eq "http://127.0.0.1:${PORT}/t/acme/p/web/builds/7" \
  "$(output_value "$tmp/gh_output" build-url)" "build-url output"

assert_eq "${#NAMES[@]}" "$(wc -l <"$tmp/received.jsonl" | tr -d '[:space:]')" \
  "one upload per screenshot"

expected_names="$(for n in "${NAMES[@]}"; do jq -rn --arg s "$n" '$s|@base64'; done | sort)"
got_names="$(jq -r '.name_b64' "$tmp/received.jsonl" | sort)"
assert_eq "$expected_names" "$got_names" "names arrive verbatim (base64 compare)"

expected_shas="$(for n in "${NAMES[@]}"; do sha256_file "$shots/$n.png"; done | sort)"
got_shas="$(jq -r '.sha256' "$tmp/received.jsonl" | sort)"
assert_eq "$expected_shas" "$got_shas" "file bytes arrive intact"
stop_server

# --- Case 2: wait:true, server ends at "changes_detected". -------------------
start_server "$tmp/received2.jsonl" changes_detected
: >"$tmp/gh_output2"
rc="$(run_action "$tmp/gh_output2" INPUT_WAIT=true)"
[ "$rc" -eq 1 ] || { cat "$tmp/action.log" >&2; fail "expected exit 1, got $rc"; }
pass "action exits 1 on changes_detected"
assert_eq "changes_detected" "$(output_value "$tmp/gh_output2" result)" "result output (changes)"
assert_eq "1" "$(output_value "$tmp/gh_output2" exit-code)" "exit-code output (changes)"
stop_server

# --- Case 3: wait:false succeeds right after finalize. -----------------------
start_server "$tmp/received3.jsonl" passed
: >"$tmp/gh_output3"
rc="$(run_action "$tmp/gh_output3" INPUT_WAIT=false)"
[ "$rc" -eq 0 ] || { cat "$tmp/action.log" >&2; fail "expected exit 0 for wait:false, got $rc"; }
pass "action exits 0 with wait:false"
assert_eq "0" "$(output_value "$tmp/gh_output3" exit-code)" "exit-code output (wait:false)"
stop_server
