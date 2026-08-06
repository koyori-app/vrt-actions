#!/usr/bin/env bash
# Input resolution / validation tests, run via validate.sh's direct-exec mode.
# env -i keeps the ambient GITHUB_* / INPUT_* environment out of the cases.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=tests/helpers.sh
. tests/helpers.sh

# expect_ok LABEL [K=V...]
expect_ok() {
  local label="$1"
  shift
  local out
  if ! out="$(env -i PATH="$PATH" "$@" bash scripts/validate.sh 2>&1)"; then
    fail "$label: expected success, got: $out"
  fi
  assert_contains "$out" "validation: OK" "$label"
}

# expect_die ERROR_FRAGMENT [K=V...]
expect_die() {
  local frag="$1"
  shift
  local out rc=0
  out="$(env -i PATH="$PATH" "$@" bash scripts/validate.sh 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || fail "expected failure containing '$frag', but validation passed: $out"
  assert_contains "$out" "$frag" "rejects: $frag"
}

BASE=(INPUT_TOKEN=t INPUT_URL=https://vrt.example.com INPUT_PROJECT=acme/web GITHUB_REF_NAME=main GITHUB_SHA=abc)

expect_ok "screenshots defaults" "${BASE[@]}"
expect_ok "storybook with only-changed and stats-json" "${BASE[@]}" \
  INPUT_MODE=storybook INPUT_ONLY_CHANGED=true INPUT_STATS_JSON=stats.json INPUT_WAIT=false

expect_die "input 'token'" INPUT_URL=https://vrt.example.com INPUT_PROJECT=acme/web
expect_die "input 'url'" INPUT_TOKEN=t INPUT_PROJECT=acme/web
expect_die "input 'mode'" "${BASE[@]}" INPUT_MODE=video
expect_die "input 'wait'" "${BASE[@]}" INPUT_WAIT=yes
expect_die "input 'only-changed'" "${BASE[@]}" INPUT_MODE=storybook INPUT_ONLY_CHANGED=1
expect_die "tenant-slug/project-slug" INPUT_TOKEN=t INPUT_URL=https://vrt.example.com INPUT_PROJECT=acme
expect_die "tenant-slug/project-slug" INPUT_TOKEN=t INPUT_URL=https://vrt.example.com INPUT_PROJECT=a/b/c
expect_die "only valid for mode 'storybook'" "${BASE[@]}" INPUT_ONLY_CHANGED=true
expect_die "requires 'only-changed: true'" "${BASE[@]}" INPUT_MODE=storybook INPUT_STATS_JSON=stats.json
