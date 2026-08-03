#!/usr/bin/env bash
# collect_pngs tests via collect-pngs.sh's direct-exec mode: name derivation,
# deterministic ordering (portable sort), and the reject paths.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=tests/helpers.sh
. tests/helpers.sh

command -v python3 >/dev/null 2>&1 || fail "python3 is required for this test"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- Happy path: names curl would misparse, nested dirs, .PNG extension. ----
shots="$tmp/shots"
mkdir -p "$shots/sub"
write_min_png "$shots/@env.png"
write_min_png "$shots/a;b.png"
write_min_png "$shots/qu\"ote.png"
write_min_png "$shots/sub/home.png"
write_min_png "$shots/zz.PNG"

out="$(DIR="$shots" bash scripts/collect-pngs.sh)"
expected="$(printf '%s\t%s\n' \
  '@env' "$shots/@env.png" \
  'a;b' "$shots/a;b.png" \
  'qu"ote' "$shots/qu\"ote.png" \
  'sub/home' "$shots/sub/home.png" \
  'zz' "$shots/zz.PNG")"
assert_eq "$expected" "$out" "names derived and byte-wise sorted"

# expect_reject LABEL DIR ERROR_FRAGMENT
expect_reject() {
  local rc=0 out
  out="$(DIR="$2" bash scripts/collect-pngs.sh 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || fail "$1: was accepted"
  assert_contains "$out" "$3" "$1"
}

# --- Reject: non-PNG extension. ----------------------------------------------
mixed="$tmp/mixed"
mkdir -p "$mixed"
write_min_png "$mixed/a.png"
printf 'txt' >"$mixed/notes.txt"
expect_reject "rejects non-PNG files" "$mixed" "non-PNG"

# --- Reject: .png extension but not PNG content. ------------------------------
fakepng="$tmp/fakepng"
mkdir -p "$fakepng"
printf 'this is text, not a png' >"$fakepng/sample.png"
expect_reject "rejects renamed text file" "$fakepng" "not a valid PNG"

# --- Reject: dimensions over the API limit / zero dimensions. -----------------
wide="$tmp/wide"
mkdir -p "$wide"
write_png_dims "$wide/wide.png" 10001 100
expect_reject "rejects >10000px width" "$wide" "must be between 1 and 10000"

zero="$tmp/zero"
mkdir -p "$zero"
write_png_dims "$zero/zero.png" 0 100
expect_reject "rejects zero width" "$zero" "must be between 1 and 10000"

# --- Reject: valid signature + dimensions, but truncated. ---------------------
# The old 24-byte header check accepted both of these; the server's PNG parser
# (which walks every chunk up to the first IDAT, CRCs included) does not.
cut_ihdr="$tmp/cut-ihdr"
mkdir -p "$cut_ihdr"
write_min_png "$tmp/min.png"
head -c 24 "$tmp/min.png" >"$cut_ihdr/cut.png"
expect_reject "rejects PNG cut mid-IHDR" "$cut_ihdr" "not a valid PNG"

cut_idat="$tmp/cut-idat"
mkdir -p "$cut_idat"
head -c 33 "$tmp/min.png" >"$cut_idat/cut.png" # signature + full IHDR, no IDAT
expect_reject "rejects PNG cut before IDAT" "$cut_idat" "not a valid PNG"

# --- Reject: IHDR data corrupted without updating its CRC. --------------------
badcrc="$tmp/badcrc"
mkdir -p "$badcrc"
cp "$tmp/min.png" "$badcrc/bad.png"
printf '\002' | dd of="$badcrc/bad.png" bs=1 seek=19 count=1 conv=notrunc 2>/dev/null
expect_reject "rejects CRC mismatch" "$badcrc" "not a valid PNG"

# --- Reject: empty derived name ('.png'). -------------------------------------
noname="$tmp/noname"
mkdir -p "$noname"
write_min_png "$noname/.png"
expect_reject "rejects empty derived name" "$noname" "empty name"

# --- Reject: duplicate names after trimming ('foo' vs 'foo '). ----------------
dup="$tmp/dup"
mkdir -p "$dup"
write_min_png "$dup/foo.png"
write_min_png "$dup/foo .png"
expect_reject "rejects duplicate names after trimming" "$dup" "duplicate screenshot name"

# --- Reject: foo.png vs foo.PNG — only where the filesystem itself keeps them
# --- apart (macOS APFS is case-insensitive: both paths land on one file). -----
dup2="$tmp/dup2"
mkdir -p "$dup2"
write_min_png "$dup2/bar.png"
write_min_png "$dup2/bar.PNG"
if [ "$(find "$dup2" -type f | wc -l | tr -d '[:space:]')" -eq 2 ]; then
  expect_reject "rejects case-colliding names" "$dup2" "duplicate screenshot name"
else
  pass "case-colliding names skipped (case-insensitive filesystem)"
fi

# --- Reject: derived name over 255 bytes. --------------------------------------
longdir="$(printf 'a%.0s' $(seq 1 200))"
longname="$(printf 'b%.0s' $(seq 1 60))"
deep="$tmp/deep"
mkdir -p "$deep/$longdir"
write_min_png "$deep/$longdir/$longname.png"
expect_reject "rejects >255-byte name" "$deep" "exceeding the 255-byte limit"

# --- Reject: empty directory. -----------------------------------------------
empty="$tmp/empty"
mkdir -p "$empty"
expect_reject "rejects empty directory" "$empty" "contains no .png"

# --- Reject: PNG over the 25 MiB limit. ---------------------------------------
big="$tmp/big"
mkdir -p "$big"
dd if=/dev/zero of="$big/huge.png" bs=1048576 count=26 2>/dev/null
expect_reject "rejects oversized PNG" "$big" "25 MiB"
