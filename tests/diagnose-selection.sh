#!/usr/bin/env bash
# 秘密を含まない固定入力だけで変換を一段ずつ観測する。
line='2026-10-21T00:00:00Z INFO vrt: finalizing with a full capture'
probe_step() {
  local result rc=0
  result="$(printf '%s\n' "$line" | LC_ALL=C awk "$2 { print line }")" || rc=$?
  printf 'PROBE %s rc=%s value=[%s]\n' "$1" "$rc" "$result"
  if [ "$rc" -eq 0 ]; then line="$result"; fi
}
awk -version </dev/null 2>&1 || true
probe_step ansi '{ line=$0; gsub(/\033\[[0-9;]*[[:alpha:]]/, "", line) }'
probe_step space '{ line=$0; sub(/^[[:space:]]+/, "", line) }'
probe_step datetime '{ line=$0; sub(/^[0-9T:.Z+-]+[[:space:]]+/, "", line) }'
probe_step level '{ line=$0; sub(/^(INFO|WARN|ERROR|DEBUG|TRACE)[[:space:]]+/, "", line) }'
probe_step target '{ line=$0; sub(/^[[:alnum:]_:]+:[[:space:]]+/, "", line) }'
