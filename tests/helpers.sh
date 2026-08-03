# shellcheck shell=bash
# Tiny assertion helpers shared by the test scripts. Meant to be sourced.

pass() {
  echo "ok: $*"
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# assert_eq EXPECTED ACTUAL LABEL
assert_eq() {
  if [ "$1" = "$2" ]; then
    pass "$3"
  else
    fail "$3: expected '$1', got '$2'"
  fi
}

# assert_contains HAYSTACK NEEDLE LABEL
assert_contains() {
  case "$1" in
    *"$2"*) pass "$3" ;;
    *) fail "$3: expected to contain '$2', got: $1" ;;
  esac
}

# write_min_png FILE — write a real, decodable 1x1 RGBA PNG (68 bytes).
# shellcheck disable=SC2016  # the byte string must stay literal, `$` and all
write_min_png() {
  printf '\211PNG\015\012\032\012\000\000\000\015IHDR\000\000\000\001\000\000\000\001\010\006\000\000\000\037\025\304\211\000\000\000\013IDATx\332cd`\000\000\000\006\000\0020\201\320/\000\000\000\000IEND\256B`\202' >"$1"
}

# write_png_dims FILE WIDTH HEIGHT — the smallest byte string that satisfies
# the server-equivalent header validation: signature, CRC-valid IHDR with the
# given dimensions, and an IDAT chunk header. Not a decodable image; use it to
# exercise the dimension bounds, not the happy path.
write_png_dims() {
  python3 - "$1" "$2" "$3" <<'EOF'
import struct, sys, zlib
path, w, h = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
ihdr = struct.pack(">II5B", w, h, 8, 6, 0, 0, 0)
chunk = (
    struct.pack(">I", len(ihdr))
    + b"IHDR" + ihdr
    + struct.pack(">I", zlib.crc32(b"IHDR" + ihdr))
)
with open(path, "wb") as f:
    f.write(b"\x89PNG\r\n\x1a\n" + chunk + struct.pack(">I", 0) + b"IDAT")
EOF
}

# sha256_file FILE — portable across GNU (sha256sum) and BSD (shasum). Reads
# from stdin so filenames with newlines don't trigger GNU's \-escaped output.
sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum <"$1"
  else
    shasum -a 256 <"$1"
  fi | awk '{print $1}'
}
