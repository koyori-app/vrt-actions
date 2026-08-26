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
  write_min_png "$shots/$n.png"
  # Distinct trailing bytes after IEND keep the per-file sha256 comparison
  # meaningful; the header validation and PNG decoders ignore them.
  printf 'trailer-%s' "$i" >>"$shots/$n.png"
  i=$((i + 1))
done

# start_server RECORD_FILE FINAL_STATUS — sets SERVER_PID and PORT.
start_server() {
  : >"$tmp/port"
  RECORD_FILE="$1" FINAL_STATUS="$2" FLAKY_POLL_CODE="${FLAKY_POLL_CODE:-0}" \
    python3 tests/fake_server.py \
    >"$tmp/port" 2>"$tmp/server.err" &
  SERVER_PID=$!
  local n=0
  while [ ! -s "$tmp/port" ] && [ "$n" -lt 300 ]; do
    sleep 0.1
    n=$((n + 1))
  done
  if [ ! -s "$tmp/port" ]; then
    cat "$tmp/server.err" >&2
    fail "fake server did not start within 30s"
  fi
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

# --- Case 4: a transient 502 on the first status poll is retried, not fatal. --
FLAKY_POLL_CODE=502 start_server "$tmp/received4.jsonl" passed
: >"$tmp/gh_output4"
rc="$(run_action "$tmp/gh_output4" INPUT_WAIT=true VRT_TEST_POLL_INTERVAL_SECONDS=0.2)"
[ "$rc" -eq 0 ] || { cat "$tmp/action.log" >&2; fail "expected exit 0 despite a 502 poll, got $rc"; }
pass "action retries a transient 502 while polling"
assert_eq "passed" "$(output_value "$tmp/gh_output4" result)" "result output (after 502)"
assert_contains "$(cat "$tmp/action.log")" "HTTP 502" "the 502 retry is logged"
stop_server

# --- Case 5: poll deadline expires -> exit 2 with outputs written. ------------
start_server "$tmp/received5.jsonl" processing # never reaches a terminal status
: >"$tmp/gh_output5"
rc="$(run_action "$tmp/gh_output5" INPUT_WAIT=true \
  VRT_TEST_POLL_INTERVAL_SECONDS=0.2 VRT_TEST_POLL_TIMEOUT_SECONDS=1)"
[ "$rc" -eq 2 ] || { cat "$tmp/action.log" >&2; fail "expected exit 2 on poll timeout, got $rc"; }
pass "action exits 2 when the poll deadline expires"
assert_eq "2" "$(output_value "$tmp/gh_output5" exit-code)" "exit-code output (timeout)"
assert_contains "$(cat "$tmp/action.log")" "timed out after" "the timeout is reported"
stop_server

# --- Case 6: exit-zero-on-changes greens a changes_detected build. -----------
# 差分は承認待ちであって失敗ではないので、赤を本物の失敗だけに絞れること。
# result は書き換えず、差分が出た事実は outputs に残ること。
start_server "$tmp/received6.jsonl" changes_detected
: >"$tmp/gh_output6"
rc="$(run_action "$tmp/gh_output6" INPUT_WAIT=true INPUT_EXIT_ZERO_ON_CHANGES=true)"
[ "$rc" -eq 0 ] || { cat "$tmp/action.log" >&2; fail "expected exit 0 with exit-zero-on-changes, got $rc"; }
pass "exit-zero-on-changes:true exits 0 on changes_detected"
assert_eq "changes_detected" "$(output_value "$tmp/gh_output6" result)" "result stays changes_detected"
assert_eq "0" "$(output_value "$tmp/gh_output6" exit-code)" "exit-code output is remapped too"
stop_server

# --- Case 7: a branch value only greens that branch. -------------------------
start_server "$tmp/received7.jsonl" changes_detected
: >"$tmp/gh_output7"
rc="$(run_action "$tmp/gh_output7" INPUT_WAIT=true INPUT_EXIT_ZERO_ON_CHANGES=main)"
[ "$rc" -eq 0 ] || { cat "$tmp/action.log" >&2; fail "expected exit 0 on the named branch, got $rc"; }
pass "exit-zero-on-changes:main exits 0 on main"
stop_server

start_server "$tmp/received8.jsonl" changes_detected
: >"$tmp/gh_output8"
rc="$(run_action "$tmp/gh_output8" INPUT_WAIT=true INPUT_EXIT_ZERO_ON_CHANGES=main \
  GITHUB_REF_NAME=feat/x)"
[ "$rc" -eq 1 ] || { cat "$tmp/action.log" >&2; fail "expected exit 1 off the named branch, got $rc"; }
pass "exit-zero-on-changes:main keeps other branches red"
stop_server

# 部分一致で広がると、意図しない PR まで緑になって入力の意味が消える。
start_server "$tmp/received9.jsonl" changes_detected
: >"$tmp/gh_output9"
rc="$(run_action "$tmp/gh_output9" INPUT_WAIT=true INPUT_EXIT_ZERO_ON_CHANGES=main \
  GITHUB_REF_NAME=main-2)"
[ "$rc" -eq 1 ] || { cat "$tmp/action.log" >&2; fail "expected exit 1 on a prefix-sharing branch, got $rc"; }
pass "exit-zero-on-changes matches the branch exactly"
stop_server

# PR ビルドではブランチ指定モードを効かせない。PR で照合される branch は
# GITHUB_HEAD_REF——PR を出した側が名乗ったブランチ名なので、ここで照合すると
# 'main' と名付けた PR ブランチまで緑になり、設定の意味が裏返る。
start_server "$tmp/received9b.jsonl" changes_detected
: >"$tmp/gh_output9b"
rc="$(run_action "$tmp/gh_output9b" INPUT_WAIT=true INPUT_EXIT_ZERO_ON_CHANGES=main \
  GITHUB_HEAD_REF=main GITHUB_EVENT_NAME=pull_request PR_NUMBER=42)"
[ "$rc" -eq 1 ] || { cat "$tmp/action.log" >&2; fail "expected exit 1 for a PR branch named main, got $rc"; }
pass "exit-zero-on-changes:main keeps a PR named main red"
grep -q "does not apply to pull request builds" "$tmp/action.log" ||
  { cat "$tmp/action.log" >&2; fail "the skipped branch mode must explain itself"; }
pass "the PR-context skip explains itself in the log"
stop_server

# PR 番号だけが渡る経路（イベント名が無い composite 実行）でも同じ扱いにする。
start_server "$tmp/received9c.jsonl" changes_detected
: >"$tmp/gh_output9c"
rc="$(run_action "$tmp/gh_output9c" INPUT_WAIT=true INPUT_EXIT_ZERO_ON_CHANGES=main \
  GITHUB_HEAD_REF=main PR_NUMBER=42)"
[ "$rc" -eq 1 ] || { cat "$tmp/action.log" >&2; fail "expected exit 1 when only PR_NUMBER marks the PR, got $rc"; }
pass "a bare PR number is enough to disable branch-restricted mode"
stop_server

# 'true' は明示的な意思表示なので PR でも効かせる。ここまで塞ぐと、
# PR も含めて常に緑にする手段が無くなる。
start_server "$tmp/received9d.jsonl" changes_detected
: >"$tmp/gh_output9d"
rc="$(run_action "$tmp/gh_output9d" INPUT_WAIT=true INPUT_EXIT_ZERO_ON_CHANGES=true \
  GITHUB_HEAD_REF=feat/x GITHUB_EVENT_NAME=pull_request PR_NUMBER=42)"
[ "$rc" -eq 0 ] || { cat "$tmp/action.log" >&2; fail "expected exit 0 for exit-zero-on-changes:true on a PR, got $rc"; }
pass "exit-zero-on-changes:true still greens a PR"
stop_server

# --- Case 8: the input never hides a broken build. ---------------------------
start_server "$tmp/received10.jsonl" failed
: >"$tmp/gh_output10"
rc="$(run_action "$tmp/gh_output10" INPUT_WAIT=true INPUT_EXIT_ZERO_ON_CHANGES=true)"
[ "$rc" -eq 2 ] || { cat "$tmp/action.log" >&2; fail "expected exit 2 for a failed build, got $rc"; }
pass "exit-zero-on-changes leaves a failed build red"
assert_eq "2" "$(output_value "$tmp/gh_output10" exit-code)" "exit-code output (failed)"
stop_server

# --- Case 9: 'false' and whitespace-only values behave like the default. -----
for value in false "  "; do
  start_server "$tmp/received11.jsonl" changes_detected
  : >"$tmp/gh_output11"
  rc="$(run_action "$tmp/gh_output11" INPUT_WAIT=true INPUT_EXIT_ZERO_ON_CHANGES="$value")"
  [ "$rc" -eq 1 ] || { cat "$tmp/action.log" >&2; fail "expected exit 1 for exit-zero-on-changes='$value', got $rc"; }
  pass "exit-zero-on-changes='$value' keeps changes red"
  stop_server
done
