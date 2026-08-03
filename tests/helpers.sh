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

# png_be32 N — emit a 4-byte big-endian integer as printf octal escapes.
png_be32() {
  printf '\\%03o\\%03o\\%03o\\%03o' \
    $(($1 >> 24 & 255)) $(($1 >> 16 & 255)) $(($1 >> 8 & 255)) $(($1 & 255))
}

# write_png_header FILE WIDTH HEIGHT — write only the PNG signature and an
# IHDR prefix with the given dimensions. Enough to exercise the dimension
# validation; not a decodable image.
write_png_header() {
  printf '\211PNG\015\012\032\012\000\000\000\015IHDR' >"$1"
  # shellcheck disable=SC2059
  printf "$(png_be32 "$2")$(png_be32 "$3")" >>"$1"
  printf '\010\006\000\000\000' >>"$1"
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
