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

# sha256_file FILE — portable across GNU (sha256sum) and BSD (shasum). Reads
# from stdin so filenames with newlines don't trigger GNU's \-escaped output.
sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum <"$1"
  else
    shasum -a 256 <"$1"
  fi | awk '{print $1}'
}
