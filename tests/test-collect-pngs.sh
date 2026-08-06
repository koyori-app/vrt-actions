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

# --- Reject: CRC-valid but semantically invalid IHDR / chunk layout. ----------
# The png crate the server uses rejects all of these before reaching IDAT.
semantic_case() { # LABEL FRAGMENT ARGS-for-write_png_dims...
  local label="$1" frag="$2"
  shift 2
  local d="$tmp/sem-$((sem_case_n += 1))"
  mkdir -p "$d"
  write_png_dims "$d/x.png" "$@"
  expect_reject "$label" "$d" "$frag"
}
sem_case_n=0
semantic_case "rejects undefined color type" "color type" 10 10 8 5 0 0 0
semantic_case "rejects invalid bit depth for color type" "color type" 10 10 3 0 0 0 0
semantic_case "rejects nonzero compression method" "compression/filter" 10 10 8 6 1 0 0
semantic_case "rejects nonzero filter method" "compression/filter" 10 10 8 6 0 1 0
semantic_case "rejects invalid interlace method" "interlace" 10 10 8 6 0 0 2
semantic_case "rejects duplicate IHDR" "duplicate IHDR" 10 10 8 6 0 0 0 IHDR
semantic_case "rejects unknown critical chunk" "unknown critical" 10 10 8 6 0 0 0 ABCD
semantic_case "rejects duplicate PLTE" "duplicate PLTE" 10 10 8 6 0 0 0 "PLTE:000000,PLTE:000000"
# PLTE length must be in 3..=768; divisibility by 3 is NOT required (the png
# crate only range-checks the length in start_chunk).
semantic_case "rejects empty PLTE" "PLTE chunk length" 10 10 8 6 0 0 0 "PLTE:0000"
semantic_case "rejects oversized PLTE" "PLTE chunk length" 10 10 8 6 0 0 0 \
  "PLTE:$(printf '000000%.0s' $(seq 1 257))"
semantic_case "rejects PLTE with bad CRC" "CRC mismatch" 10 10 8 6 0 0 0 "PLTE:010203:badcrc"
# fcTL data layout: seq(4) w(4) h(4) x(4) y(4) delay_num(2) delay_den(2)
# dispose(1) blend(1) = 26 bytes. All CRCs are valid; only semantics differ.
semantic_case "rejects fcTL with bad length" "fcTL chunk length" 10 10 8 6 0 0 0 "fcTL:00000000"
# The length check runs before the CRC check, so a bad CRC does not save it.
semantic_case "rejects fcTL with bad length and bad CRC" "fcTL chunk length" 10 10 8 6 0 0 0 \
  "fcTL:00000000:badcrc"
semantic_case "rejects fcTL with nonzero sequence" "sequence number" 10 10 8 6 0 0 0 \
  "fcTL:000000010000000a0000000a0000000000000000000100640000"
semantic_case "rejects two fcTL repeating sequence 0" "sequence number" 10 10 8 6 0 0 0 \
  "fcTL:000000000000000a0000000a0000000000000000000100640000,fcTL:000000000000000a0000000a0000000000000000000100640000"
# The pre-IDAT fcTL describes the default image: the crate demands x/y = 0 and
# the exact IHDR dimensions (validate_default_image), not merely "fits inside".
semantic_case "rejects fcTL frame larger than image" "must cover the full" 10 10 8 6 0 0 0 \
  "fcTL:000000000000000b0000000a0000000000000000000100640000"
semantic_case "rejects fcTL frame smaller than image" "must cover the full" 10 10 8 6 0 0 0 \
  "fcTL:0000000000000005000000050000000000000000000100640000"
semantic_case "rejects fcTL with invalid blend op" "dispose/blend" 10 10 8 6 0 0 0 \
  "fcTL:000000000000000a0000000a0000000000000000000100640002"
# fdAT looks ancillary (lowercase first letter) but the crate routes it through
# the IDAT data-chunk path; before the first IDAT it is fatal even with a bad
# CRC (UnexpectedRestartOfDataChunkSequence, raised before the CRC check).
semantic_case "rejects fdAT before IDAT" "fdAT chunk before" 10 10 8 6 0 0 0 \
  "fdAT:00000000010203"
semantic_case "rejects fdAT before IDAT with bad CRC" "fdAT chunk before" 10 10 8 6 0 0 0 \
  "fdAT:00000000010203:badcrc"

# --- Accept: everything the server-side png crate treats as benign. ------------
# Ancillary chunks other than fcTL are never fatal to the crate's read_info:
# semantic garbage becomes BadAncillaryChunk and a bad CRC skips the chunk
# (skip_ancillary_crc_failures defaults to true). Rejecting these locally
# would fail builds the server would have accepted.
ok_edge="$tmp/ok-edge"
mkdir -p "$ok_edge"
write_png_dims "$ok_edge/adam7.png" 10 10 8 6 0 0 1
write_png_dims "$ok_edge/ancillary.png" 10 10 8 6 0 0 0 abCD
write_png_dims "$ok_edge/plte-fctl.png" 10 10 8 6 0 0 0 \
  "PLTE:000000,fcTL:000000000000000a0000000a0000000000000000000100640000"
write_png_dims "$ok_edge/plte-len4.png" 10 10 8 6 0 0 0 "PLTE:01020304"
write_png_dims "$ok_edge/trns-rgba.png" 10 10 8 6 0 0 0 "tRNS:000100020003"
write_png_dims "$ok_edge/trns-short-gray.png" 10 10 8 0 0 0 0 "tRNS:07"
write_png_dims "$ok_edge/sbit-bad.png" 10 10 8 6 0 0 0 "sBIT:0808"
write_png_dims "$ok_edge/actl-zero-frames.png" 10 10 8 6 0 0 0 "acTL:0000000000000000"
write_png_dims "$ok_edge/badcrc-ancillary.png" 10 10 8 6 0 0 0 "gAMA:0000b18f:badcrc"
write_png_dims "$ok_edge/badcrc-bad-fctl.png" 10 10 8 6 0 0 0 \
  "fcTL:0000000100000002000000020000000000000000000100640000:badcrc"
write_png_dims "$ok_edge/two-fctl-in-order.png" 10 10 8 6 0 0 0 \
  "fcTL:000000000000000a0000000a0000000000000000000100640000,fcTL:000000010000000a0000000a0000000000000000000100640000"
out="$(DIR="$ok_edge" bash scripts/collect-pngs.sh)"
assert_contains "$out" "adam7" "accepts Adam7 interlace"
assert_contains "$out" "ancillary" "accepts unknown ancillary chunk"
assert_contains "$out" "plte-fctl" "accepts single valid PLTE and fcTL"
assert_contains "$out" "plte-len4" "accepts PLTE length not divisible by 3"
assert_contains "$out" "trns-rgba" "accepts tRNS on an alpha color type"
assert_contains "$out" "trns-short-gray" "accepts short grayscale tRNS"
assert_contains "$out" "sbit-bad" "accepts sBIT with wrong length"
assert_contains "$out" "actl-zero-frames" "accepts acTL with zero frames"
assert_contains "$out" "badcrc-ancillary" "accepts ancillary chunk with bad CRC"
assert_contains "$out" "badcrc-bad-fctl" "accepts invalid fcTL hidden by a bad CRC"
assert_contains "$out" "two-fctl-in-order" "accepts fcTL chunks in sequence order"

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
