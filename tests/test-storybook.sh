#!/usr/bin/env bash
# storybook-mode tests with a fake vrt CLI: argument construction, env
# contract, JSON-line extraction from noisy stdout, and exit-code mapping.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=tests/helpers.sh
. tests/helpers.sh

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

sb="$tmp/storybook-static"
mkdir -p "$sb"
echo '{}' >"$sb/index.json"

# Fake CLI: records argv and env, emits stderr noise plus a non-JSON stdout
# line before the JSON result, mimicking a chatty real binary. Paths are baked
# in at write time because run_storybook launches the CLI under env -i — the
# fake must not depend on inherited variables. LEAKY_SECRET is a canary: it is
# set in the driver environment and must NOT survive into the CLI.
cat >"$tmp/vrt" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >"$tmp/args"
printf 'url=%s project=%s leak=%s\n' "\$VRT_URL" "\$VRT_PROJECT" "\${LEAKY_SECRET:-none}" >>"$tmp/args"
echo "some progress log" >&2
echo "stdout noise before the JSON line"
cat "$tmp/cli.json"
exit "\$(cat "$tmp/cli_exit" 2>/dev/null || echo 0)"
EOF
chmod +x "$tmp/vrt"

export FAKE_VRT_CLI="$tmp/vrt"
export FAKE_VRT_ARGS_FILE="$tmp/args"

# run_driver [extra K=V...] — echoes rc; driver stdout goes to $tmp/driver.out.
run_driver() {
  local rc=0
  env -i PATH="$PATH" \
    FAKE_VRT_CLI="$FAKE_VRT_CLI" \
    LEAKY_SECRET=should-not-leak \
    INPUT_TOKEN=t \
    INPUT_URL=https://vrt.example.com/api \
    INPUT_PROJECT=acme/web \
    INPUT_MODE=storybook \
    INPUT_DIR="$sb" \
    GITHUB_REF_NAME=main \
    GITHUB_SHA=abc \
    GITHUB_OUTPUT="$tmp/gh_output" \
    "$@" \
    bash tests/storybook-driver.sh >"$tmp/driver.out" 2>"$tmp/driver.err" || rc=$?
  echo "$rc"
}

# --- Case 1: wait:true, CLI reports passed / exit_code 0. --------------------
printf '%s\n' '{"build_id":"b-1","build_number":9,"tenant_slug":"acme","project_slug":"web","status":"passed","exit_code":0}' >"$tmp/cli.json"
rc="$(run_driver INPUT_WAIT=true)"
[ "$rc" -eq 0 ] || { cat "$tmp/driver.err" >&2; fail "driver failed: rc=$rc"; }
out="$(cat "$tmp/driver.out")"
# APP_URL strips the trailing /api from the API base URL.
assert_eq "CODE=0 RESULT=passed BUILD_URL=https://vrt.example.com/t/acme/p/web/builds/9" "$out" "passed maps to CODE=0"
args="$(cat "$FAKE_VRT_ARGS_FILE")"
assert_contains "$args" "--wait" "wait:true passes --wait"
assert_contains "$args" "--dir $sb" "CLI receives --dir"
assert_contains "$args" "url=https://vrt.example.com/api project=acme/web" "CLI env contract"
assert_contains "$args" "leak=none" "env -i keeps inherited secrets away from the CLI"

# --- Case 2: wait:true, CLI reports changes_detected / exit_code 1. ----------
printf '%s\n' '{"build_id":"b-1","build_number":9,"tenant_slug":"acme","project_slug":"web","status":"changes_detected","exit_code":1}' >"$tmp/cli.json"
rc="$(run_driver INPUT_WAIT=true)"
[ "$rc" -eq 0 ] || { cat "$tmp/driver.err" >&2; fail "driver failed: rc=$rc"; }
assert_eq "CODE=1 RESULT=changes_detected BUILD_URL=https://vrt.example.com/t/acme/p/web/builds/9" \
  "$(cat "$tmp/driver.out")" "changes_detected maps to CODE=1"

# --- Case 3: wait:false ignores the status for the exit code. ----------------
printf '%s\n' '{"build_id":"b-1","build_number":9,"tenant_slug":"acme","project_slug":"web","status":"processing"}' >"$tmp/cli.json"
rc="$(run_driver INPUT_WAIT=false)"
[ "$rc" -eq 0 ] || { cat "$tmp/driver.err" >&2; fail "driver failed: rc=$rc"; }
assert_eq "CODE=0 RESULT=processing BUILD_URL=https://vrt.example.com/t/acme/p/web/builds/9" \
  "$(cat "$tmp/driver.out")" "wait:false exits 0 after upload"
args="$(cat "$FAKE_VRT_ARGS_FILE")"
case "$args" in
  *"--wait"*) fail "wait:false must not pass --wait: $args" ;;
  *) pass "wait:false omits --wait" ;;
esac

# --- Case 4: CLI emits no JSON at all -> die with guidance. ------------------
printf '%s\n' 'not json' >"$tmp/cli.json"
rc="$(run_driver INPUT_WAIT=true)"
[ "$rc" -ne 0 ] || fail "expected failure when the CLI emits no JSON"
assert_contains "$(cat "$tmp/driver.err")" "did not emit a JSON result" "non-JSON stdout dies with guidance"

# --- Case 5: wait:false + CLI nonzero exit -> not a success (CODE=2). ---------
# The CLI printed a JSON line but exited 3 (e.g. the upload partially failed);
# wait:false must not report success on the exit code alone.
printf '%s\n' '{"build_id":"b-1","build_number":9,"tenant_slug":"acme","project_slug":"web","status":"processing"}' >"$tmp/cli.json"
echo 3 >"$tmp/cli_exit"
rc="$(run_driver INPUT_WAIT=false)"
[ "$rc" -eq 0 ] || { cat "$tmp/driver.err" >&2; fail "driver failed: rc=$rc"; }
assert_contains "$(cat "$tmp/driver.out")" "CODE=2 RESULT=processing" \
  "wait:false with a failing CLI maps to CODE=2"
rm -f "$tmp/cli_exit"
