#!/usr/bin/env bash
# Common helpers shared by the VRT action scripts.
# This file is meant to be sourced, not executed directly.
#
# shellcheck disable=SC2034
# SC2034 (unused variable) is unreliable here: the constants below are consumed
# by the other scripts that main.sh sources alongside this one.
set -euo pipefail

# Guard against double-sourcing (readonly constants would otherwise re-error).
if [ -n "${_VRT_LIB_SOURCED:-}" ]; then
  return 0
fi
_VRT_LIB_SOURCED=1

# --- Constants -------------------------------------------------------------

# Per-screenshot upload limit (25 MiB), matching the VRT screenshots API.
readonly MAX_PNG_BYTES=$((25 * 1024 * 1024))

# Image / name constraints enforced by the VRT screenshots API. Validated
# locally before the build is created, so an invalid set cannot leave an
# unfinalized build behind.
readonly MAX_PNG_DIMENSION=10000
readonly MAX_NAME_BYTES=255

# Polling configuration for `wait: true`.
readonly POLL_INTERVAL_SECONDS=5
readonly POLL_TIMEOUT_SECONDS=1800 # 30 minutes.

# curl timeouts. Without --max-time a hung request blocks forever and the
# 30-minute poll deadline is never re-evaluated, so the action never exits.
readonly CURL_CONNECT_TIMEOUT_SECONDS=15
readonly CURL_MAX_TIME_SECONDS=300 # generous: uploads may carry 25 MiB PNGs.

# --- Output handling -------------------------------------------------------
# Outputs must be written regardless of the final exit code so that callers
# using `continue-on-error: true` can still read `build-url` etc. We append to
# $GITHUB_OUTPUT (last write wins for a given key), so build-id/build-url can be
# recorded as soon as the build exists and result/exit-code updated at the end.

_OUTPUTS_WRITTEN=0

write_outputs() {
  # Idempotent-ish: appending the same key again lets the last value win.
  _OUTPUTS_WRITTEN=1
  {
    echo "build-id=${BUILD_ID:-}"
    echo "build-url=${BUILD_URL:-}"
    echo "result=${RESULT:-}"
    echo "exit-code=${CODE:-}"
  } >>"${GITHUB_OUTPUT:-/dev/null}"
}

# --- Logging / errors ------------------------------------------------------

log() {
  echo "$*" >&2
}

# die prints a GitHub Actions error annotation, records a failed result, and
# exits. Outputs are always flushed so callers can read result/exit-code (and
# build-url once a build exists) regardless of where the failure happened.
#
# The exit code is assigned unconditionally, never with `:=`. main.sh initialises
# CODE=0 before dispatching, so a conditional assignment would leave CODE at 0
# and make a fatal error exit successfully — the workflow would go green while
# the outputs said result=failed.
#
# write_outputs is defensive (every field uses ${VAR:-} and it appends to
# ${GITHUB_OUTPUT:-/dev/null}), so calling die from an early stage such as
# validate_inputs — before GITHUB_OUTPUT or the BUILD_* globals exist — cannot
# raise a secondary error under `set -u`.
die() {
  echo "::error::$*" >&2
  local code=1
  if [ -n "${BUILD_ID:-}" ]; then
    # ビルドが存在する = 実行時の失敗。作成前の失敗（使い方の誤り）と終了コードで区別する。
    code=2
  fi
  RESULT="failed"
  CODE="$code"
  write_outputs
  exit "$code"
}

# --- URL helpers -----------------------------------------------------------

# Strip a single trailing slash.
strip_trailing_slash() {
  local v="$1"
  printf '%s' "${v%/}"
}

# --- String helpers ----------------------------------------------------------

# trim_whitespace VALUE — strip leading/trailing whitespace (incl. newlines),
# mirroring the trim the VRT API applies to screenshot names.
trim_whitespace() {
  local v="$1"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "$v"
}

# --- PNG helpers -------------------------------------------------------------

# CRC-32 (zlib polynomial, as used by PNG chunks) over a lowercase-hex byte
# string, in pure bash. Only ever applied to the pre-IDAT region of a PNG,
# which is small (IHDR + a few ancillary chunks; typically well under 1 KiB).
_CRC_TABLE_READY=""
_crc32_init() {
  local c n k
  for ((n = 0; n < 256; n++)); do
    c=$n
    for ((k = 0; k < 8; k++)); do
      if ((c & 1)); then
        c=$(((c >> 1) ^ 0xEDB88320))
      else
        c=$((c >> 1))
      fi
    done
    _CRC_TABLE[n]=$c
  done
  _CRC_TABLE_READY=1
}

crc32_hex() {
  [ -n "$_CRC_TABLE_READY" ] || _crc32_init
  local hex="$1" crc=4294967295 i b
  local n=${#hex}
  for ((i = 0; i < n; i += 2)); do
    b=$((16#${hex:i:2}))
    crc=$(((crc >> 8) ^ _CRC_TABLE[(crc ^ b) & 255]))
  done
  printf '%08x' $((crc ^ 4294967295))
}

# png_dimensions FILE — echoes "WIDTH HEIGHT" and returns 0 when the PNG's
# header region is valid; otherwise echoes a reason and returns 1.
#
# サーバー側 (validate_png -> image::into_dimensions) は署名から最初の IDAT の
# 直前までを実際にパースし、その区間の各チャンクの完全性と CRC を検証する
# (IDAT 以降のバイト列は読まない)。ここで同じ区間を同じ厳しさで検査することで、
# 「事前検証は通るのにアップロードで拒否され、作成済みビルドが未完了のまま残る」
# 事故を防ぐ。24 バイトで途切れたファイルや IDAT 前で切れたファイルはここで落ちる。
png_dimensions() {
  local LC_ALL=C
  local file="$1"
  local file_size hex buf_bytes pos end len type body stored
  local bit_depth color_type compression filter interlace first_byte
  local width="" height="" chunks=0
  file_size="$(wc -c <"$file" | tr -d '[:space:]')"

  # Pre-IDAT chunks are tiny in real screenshots; 256 KiB of headroom covers
  # even large ICC profiles. Past that we refuse rather than walk unvalidated.
  hex="$(od -An -v -tx1 -N262144 "$file" | tr -d ' \t\n')"
  buf_bytes=$((${#hex} / 2))

  if [ "$file_size" -lt 8 ] || [ "${hex:0:16}" != "89504e470d0a1a0a" ]; then
    echo "missing PNG signature"
    return 1
  fi

  pos=8
  while :; do
    chunks=$((chunks + 1))
    if [ "$chunks" -gt 100 ]; then
      echo "more than 100 chunks before the image data"
      return 1
    fi
    if [ $((pos + 8)) -gt "$file_size" ]; then
      echo "truncated: chunk header at byte ${pos} runs past end of file"
      return 1
    fi
    if [ $((pos + 8)) -gt "$buf_bytes" ]; then
      echo "more than 256 KiB of chunks before the image data"
      return 1
    fi
    len=$((16#${hex:pos*2:8}))
    type="${hex:pos*2+8:8}"

    if [ "$type" = "49444154" ]; then # IDAT
      if [ -z "$width" ]; then
        echo "IDAT chunk appears before IHDR"
        return 1
      fi
      # The server stops parsing here; so do we. IDAT bodies and anything
      # after them (including trailing bytes past IEND) are never inspected.
      echo "$width $height"
      return 0
    fi

    end=$((pos + 8 + len + 4))
    if [ "$end" -gt "$file_size" ]; then
      echo "truncated: chunk at byte ${pos} (length ${len}) runs past end of file"
      return 1
    fi
    if [ "$end" -gt "$buf_bytes" ]; then
      echo "more than 256 KiB of chunks before the image data"
      return 1
    fi
    body="${hex:pos*2+8:(len+4)*2}" # chunk type + data
    stored="${hex:(pos+8+len)*2:8}"
    if [ "$(crc32_hex "$body")" != "$stored" ]; then
      echo "CRC mismatch in chunk at byte ${pos}"
      return 1
    fi

    if [ -z "$width" ]; then
      if [ "$type" != "49484452" ] || [ "$len" -ne 13 ]; then # "IHDR"
        echo "first chunk is not a 13-byte IHDR"
        return 1
      fi
      width=$((16#${hex:32:8}))
      height=$((16#${hex:40:8}))
      # png crate は IHDR の残りのフィールドもここで検証して弾く。同じ組み合わせ
      # 表で拒否しないと、CRC だけ正しい不正 IHDR がアップロード時まで生き残る。
      bit_depth=$((16#${hex:48:2}))
      color_type=$((16#${hex:50:2}))
      compression=$((16#${hex:52:2}))
      filter=$((16#${hex:54:2}))
      interlace=$((16#${hex:56:2}))
      case "${color_type}/${bit_depth}" in
        0/1 | 0/2 | 0/4 | 0/8 | 0/16 | 2/8 | 2/16 | 3/1 | 3/2 | 3/4 | 3/8 | 4/8 | 4/16 | 6/8 | 6/16) ;;
        *)
          echo "invalid bit depth / color type combination (depth ${bit_depth}, color type ${color_type})"
          return 1
          ;;
      esac
      if [ "$compression" -ne 0 ] || [ "$filter" -ne 0 ]; then
        echo "invalid compression/filter method (${compression}/${filter})"
        return 1
      fi
      if [ "$interlace" -ne 0 ] && [ "$interlace" -ne 1 ]; then
        echo "invalid interlace method (${interlace})"
        return 1
      fi
    elif [ "$type" = "49484452" ]; then # second IHDR
      echo "duplicate IHDR chunk"
      return 1
    elif [ "$type" = "49454e44" ]; then # IEND
      echo "no IDAT chunk before IEND"
      return 1
    elif [ "$type" = "504c5445" ]; then # PLTE
      if [ "$len" -eq 0 ] || [ $((len % 3)) -ne 0 ] || [ "$len" -gt 768 ]; then
        echo "invalid PLTE chunk length ${len}"
        return 1
      fi
    else
      # Critical chunks (bit 5 of the first type byte clear = uppercase) other
      # than IHDR/PLTE/IDAT/IEND are unknown; the png crate refuses them too.
      # Unknown *ancillary* chunks are skipped, matching the crate.
      first_byte=$((16#${type:0:2}))
      if [ $((first_byte & 32)) -eq 0 ]; then
        echo "unknown critical chunk (type 0x${type})"
        return 1
      fi
    fi
    pos=$end
  done
}

# --- Status mapping --------------------------------------------------------
# Terminal states: passed / changes_detected / failed / approved / rejected.

is_terminal_status() {
  case "$1" in
    passed | changes_detected | failed | approved | rejected) return 0 ;;
    *) return 1 ;;
  esac
}

# Map a VRT build status to the documented exit code:
#   passed/approved -> 0, changes_detected -> 1, everything else -> 2.
status_to_exit_code() {
  case "$1" in
    passed | approved) echo 0 ;;
    changes_detected) echo 1 ;;
    *) echo 2 ;;
  esac
}

# --- Authenticated HTTP ----------------------------------------------------
# The bearer token is passed via a curl --config file (mode 600) so it never
# appears in the process argument list visible to `ps`.

# init_auth_config writes the auth header file and registers cleanup.
init_auth_config() {
  AUTH_CONFIG="$(mktemp)"
  chmod 600 "$AUTH_CONFIG"
  printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" >"$AUTH_CONFIG"
  # shellcheck disable=SC2064
  trap "rm -f '$AUTH_CONFIG'" EXIT
}

# try_request METHOD URL [extra curl args...]
# Sets globals RESP_BODY and RESP_CODE. Returns non-zero on a transport error
# (DNS, connect, timeout) instead of dying, so pollers can retry until their
# own deadline.
try_request() {
  local method="$1"
  local url="$2"
  shift 2
  local tmp
  tmp="$(mktemp)"
  local code
  if ! code="$(curl -sS --config "$AUTH_CONFIG" \
    --connect-timeout "$CURL_CONNECT_TIMEOUT_SECONDS" \
    --max-time "$CURL_MAX_TIME_SECONDS" \
    -X "$method" "$@" -o "$tmp" -w '%{http_code}' "$url")"; then
    rm -f "$tmp"
    return 1
  fi
  RESP_BODY="$(cat "$tmp")"
  RESP_CODE="$code"
  rm -f "$tmp"
}

# request METHOD URL [extra curl args...]
# As try_request, but a transport error is fatal. Used for create / upload /
# finalize, where a blind retry could duplicate side effects on the server.
request() {
  try_request "$@" ||
    die "HTTP request failed: $1 $2 (network error or timeout after ${CURL_MAX_TIME_SECONDS}s)"
}

# require_2xx CONTEXT
require_2xx() {
  local context="$1"
  case "$RESP_CODE" in
    2*) return 0 ;;
    *) die "$context failed with HTTP $RESP_CODE: ${RESP_BODY:-<empty body>}" ;;
  esac
}

# --- Build helpers ---------------------------------------------------------

# build_create_body MODE
# Emits the JSON body for POST .../builds. Optional fields (commit_message,
# pull_request_number) are included only when derivable from the environment.
build_create_body() {
  local mode="$1"
  jq -cn \
    --arg branch "$BRANCH" \
    --arg sha "$COMMIT" \
    --arg mode "$mode" \
    --arg msg "${COMMIT_MESSAGE:-}" \
    --arg pr "${PR_NUMBER:-}" \
    '{branch: $branch, commit_sha: $sha, mode: $mode}
     + (if $msg != "" then {commit_message: $msg} else {} end)
     + (if ($pr | test("^[0-9]+$")) then {pull_request_number: ($pr | tonumber)} else {} end)'
}

# compute_build_url derives BUILD_URL from the resolved web UI base and build.
compute_build_url() {
  BUILD_URL="${APP_URL}/t/${TENANT}/p/${PROJECT_SLUG}/builds/${BUILD_NUMBER}"
}
