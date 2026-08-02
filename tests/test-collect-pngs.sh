#!/usr/bin/env bash
# collect_pngs tests via collect-pngs.sh's direct-exec mode: name derivation,
# deterministic ordering (portable sort), and the reject paths.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=tests/helpers.sh
. tests/helpers.sh

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- Happy path: names curl would misparse, nested dirs, .PNG extension. ----
shots="$tmp/shots"
mkdir -p "$shots/sub"
printf 'png1' >"$shots/@env.png"
printf 'png2' >"$shots/a;b.png"
printf 'png3' >"$shots/qu\"ote.png"
printf 'png4' >"$shots/sub/home.png"
printf 'png5' >"$shots/zz.PNG"

out="$(DIR="$shots" bash scripts/collect-pngs.sh)"
expected="$(printf '%s\t%s\n' \
  '@env' "$shots/@env.png" \
  'a;b' "$shots/a;b.png" \
  'qu"ote' "$shots/qu\"ote.png" \
  'sub/home' "$shots/sub/home.png" \
  'zz' "$shots/zz.PNG")"
assert_eq "$expected" "$out" "names derived and byte-wise sorted"

# --- Reject: non-PNG file. --------------------------------------------------
mixed="$tmp/mixed"
mkdir -p "$mixed"
printf 'png' >"$mixed/a.png"
printf 'txt' >"$mixed/notes.txt"
rc=0
out="$(DIR="$mixed" bash scripts/collect-pngs.sh 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "non-PNG file was accepted"
assert_contains "$out" "non-PNG" "rejects non-PNG files"

# --- Reject: empty directory. -----------------------------------------------
empty="$tmp/empty"
mkdir -p "$empty"
rc=0
out="$(DIR="$empty" bash scripts/collect-pngs.sh 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "empty directory was accepted"
assert_contains "$out" "contains no .png" "rejects empty directory"

# --- Reject: PNG over the 25 MiB limit. ---------------------------------------
big="$tmp/big"
mkdir -p "$big"
dd if=/dev/zero of="$big/huge.png" bs=1048576 count=26 2>/dev/null
rc=0
out="$(DIR="$big" bash scripts/collect-pngs.sh 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "oversized PNG was accepted"
assert_contains "$out" "exceeding" "rejects oversized PNG"
