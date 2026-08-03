#!/usr/bin/env bash
# resolve_cli_tag tests against the fake releases API: paging past a first
# page that has no cli-v* tag, prerelease exclusion, the not-found path, and
# the pinned-version short-circuit.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=tests/helpers.sh
. tests/helpers.sh

command -v python3 >/dev/null 2>&1 || fail "python3 is required for this test"
command -v jq >/dev/null 2>&1 || fail "jq is required for this test"

tmp="$(mktemp -d)"
SERVER_PID=""
trap '[ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null; rm -rf "$tmp"' EXIT

# start_server RELEASES_FILE — sets SERVER_PID and PORT.
start_server() {
  : >"$tmp/port"
  RELEASES_FILE="$1" python3 tests/fake_server.py \
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

# run_resolve CLI_VERSION — echoes rc; stdout/stderr land in $tmp/resolve.*.
run_resolve() {
  local rc=0
  # shellcheck disable=SC2016  # the inner script expands in the child shell
  env -i PATH="$PATH" \
    GITHUB_API_URL="http://127.0.0.1:${PORT}" \
    CLI_VERSION_INPUT="$1" \
    bash -c '
      set -euo pipefail
      . scripts/lib.sh
      . scripts/storybook.sh
      CLI_VERSION="$CLI_VERSION_INPUT"
      GITHUB_TOKEN=""
      resolve_cli_tag
    ' >"$tmp/resolve.out" 2>"$tmp/resolve.err" || rc=$?
  echo "$rc"
}

# --- Case 1: page 1 has only backend tags + a cli prerelease; the stable ------
# --- cli-v* lives on page 2. ---------------------------------------------------
cat >"$tmp/pages.json" <<'EOF'
[
  [
    {"tag_name": "v1.2.0", "prerelease": false, "draft": false},
    {"tag_name": "cli-v0.3.0-rc1", "prerelease": true, "draft": false}
  ],
  [
    {"tag_name": "v1.1.0", "prerelease": false, "draft": false},
    {"tag_name": "cli-v0.2.0", "prerelease": false, "draft": false},
    {"tag_name": "cli-v0.1.0", "prerelease": false, "draft": false}
  ]
]
EOF
start_server "$tmp/pages.json"
rc="$(run_resolve latest)"
[ "$rc" -eq 0 ] || { cat "$tmp/resolve.err" >&2; fail "resolve failed: rc=$rc"; }
assert_eq "cli-v0.2.0" "$(cat "$tmp/resolve.out")" "pages past page 1, skips prerelease"

# --- Case 2: pinned version never touches the API. ---------------------------
rc="$(run_resolve cli-v9.9.9)"
[ "$rc" -eq 0 ] || fail "pinned resolve failed: rc=$rc"
assert_eq "cli-v9.9.9" "$(cat "$tmp/resolve.out")" "pinned cli-version short-circuits"
stop_server

# --- Case 3: no stable cli-v* anywhere -> die with guidance. ------------------
cat >"$tmp/no-cli.json" <<'EOF'
[
  [
    {"tag_name": "v1.2.0", "prerelease": false, "draft": false},
    {"tag_name": "v1.1.0", "prerelease": false, "draft": false}
  ]
]
EOF
start_server "$tmp/no-cli.json"
rc="$(run_resolve latest)"
[ "$rc" -ne 0 ] || fail "expected failure when no stable cli-v* release exists"
assert_contains "$(cat "$tmp/resolve.err")" "no stable 'cli-v*' release" "not-found dies with guidance"
stop_server
