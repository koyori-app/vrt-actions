#!/usr/bin/env bash
# 撮影対象の判定を表示する。
# ログを読む部分と表示を分け、版付きの結果が利用可能になったら読取側を置き換える。
# shellcheck disable=SC2034
set -euo pipefail

# CLI の出力を再掲するときも、既知のトークンを残さない。
redact_selection_log() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -n "${TOKEN:-}" ]; then
      line="${line//"$TOKEN"/\*\*\*}"
    fi
    if [ -n "${GITHUB_TOKEN:-}" ]; then
      line="${line//"$GITHUB_TOKEN"/\*\*\*}"
    fi
    printf '%s\n' "$line"
  done
}

# 現行 CLI の既知のメッセージだけを読む。
# パスや自由記述は output と要約へコピーせず、理由を固定のコードへ変換する。
read_selection_log() {
  OPTIMIZATION_STATUS=unavailable
  FALLBACK_REASON=""
  SELECTED_STORIES=""
  CAPTURED_STORIES=""
  REUSED_STORIES=""
  TOTAL_STORIES=""
  local record status reason selected captured reused total
  if ! record="$(LC_ALL=C awk '
    function count_value(value) {
      return value ~ /^[0-9]+$/ && length(value) <= 10 ? value : "-"
    }
    {
      line = $0
      gsub(/\033\[[0-9;]*[[:alpha:]]/, "", line)
      sub(/^[[:space:]]+/, "", line)
      sub(/^[0-9T:.Z+-]+[[:space:]]+/, "", line)
      sub(/^(INFO|WARN|ERROR|DEBUG|TRACE)[[:space:]]+/, "", line)
      sub(/^[[:alnum:]_:]+:[[:space:]]+/, "", line)
      if (line == "finalizing with a full capture") full = 1
      if (line ~ /^finalizing with only_changed story set[[:space:]]+count=[0-9]+$/ ||
          line ~ /^count=[0-9]+[[:space:]]+finalizing with only_changed story set$/) {
        value = line
        sub(/^.*count=/, "", value)
        sub(/[[:space:]].*$/, "", value)
        value = count_value(value)
        if (value != "-") {
          if (only && selected != value) conflict = 1
          only = 1
          selected = value
        }
      }
      if (line ~ /capturing all stories/) {
        code = ""
        if (line ~ /^no baseline commit for this branch yet;/) code = "missing_baseline"
        else if (line ~ /^could not diff against baseline \(/) code = "insufficient_history"
        else if (line ~ /^no artifact provenance \(/) code = "missing_provenance"
        else if (line ~ /^the artifact provenance in .* predates build ownership/) code = "legacy_provenance"
        else if (line ~ /^changed file .* forces a full capture \(dependency\/Storybook config change\)/) code = "dependency_or_storybook_config_changed"
        else if (line ~ /^changed file .* is not in the dependency graph;/) code = "outside_graph"
        if (code != "" && reason == "") reason = code
      }
      if (line ~ /^\[info\] render started: [0-9]+ stories$/) {
        split(line, fields, " ")
        total = count_value(fields[4])
      }
      if (line ~ /^\[info\] render complete: rendered [0-9]+ reused [0-9]+ failed [0-9]+$/) {
        split(line, fields, " ")
        captured = count_value(fields[5])
        reused = count_value(fields[7])
      }
    }
    END {
      status = "unavailable"
      if (full && !only) {
        status = "full"
        if (reason == "") reason = "unknown"
      } else if (only && !full && !conflict) status = "optimized"
      if (status != "full") reason = ""
      if (status != "optimized") selected = ""
      printf "%s %s %s %s %s %s\n", status,
        reason == "" ? "-" : reason, selected == "" ? "-" : selected,
        captured == "" ? "-" : captured, reused == "" ? "-" : reused,
        total == "" ? "-" : total
    }
  ' "$1")"; then
    return 0
  fi
  read -r status reason selected captured reused total <<<"$record"
  OPTIMIZATION_STATUS="$status"
  [ "$reason" = "-" ] || FALLBACK_REASON="$reason"
  [ "$selected" = "-" ] || SELECTED_STORIES="$selected"
  [ "$captured" = "-" ] || CAPTURED_STORIES="$captured"
  [ "$reused" = "-" ] || REUSED_STORIES="$reused"
  [ "$total" = "-" ] || TOTAL_STORIES="$total"
  return 0
}

# 終了条件に影響させず、only-changed を要求した利用者だけに追加情報を出す。
write_selection_observability() {
  [ "${MODE:-}" = "storybook" ] && [ "${ONLY_CHANGED:-}" = "true" ] || return 0
  local status="${OPTIMIZATION_STATUS:-unavailable}" label reason
  reason="${FALLBACK_REASON:-}"
  case "$status" in
    full) label="全ストーリー撮影へ切り替え" ;;
    optimized) label="CLI が撮影対象を選択" ;;
    *) label="撮影対象の決定方法を取得できませんでした" ;;
  esac
  {
    printf 'optimization-status=%s\n' "$status"
    printf 'fallback-reason=%s\n' "$reason"
    printf 'selected-stories=%s\n' "${SELECTED_STORIES:-}"
    printf 'captured-stories=%s\n' "${CAPTURED_STORIES:-}"
    printf 'reused-stories=%s\n' "${REUSED_STORIES:-}"
    printf 'total-stories=%s\n' "${TOTAL_STORIES:-}"
  } >>"${GITHUB_OUTPUT:-/dev/null}" || log "撮影対象の追加 output を書き込めませんでした。"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      printf '### VRT の撮影対象\n\n%s\n\n' "$label"
      printf '| 項目 | 値 |\n| --- | --- |\n'
      printf '| 選択状態 | %s |\n' "$status"
      printf '| 全撮影の理由 | %s |\n' "${reason:-該当なし}"
      printf '| 計画の対象数 | %s |\n' "${SELECTED_STORIES:-未取得}"
      printf '| 実際の撮影数 | %s |\n' "${CAPTURED_STORIES:-未取得}"
      printf '| 流用数 | %s |\n' "${REUSED_STORIES:-未取得}"
      printf '| ストーリー総数 | %s |\n\n' "${TOTAL_STORIES:-未取得}"
      printf '現行 CLI の既知のログから取得した情報です。\n'
      printf '計画の対象数と実際の撮影数は異なることがあります。\n'
    } >>"$GITHUB_STEP_SUMMARY" || log "撮影対象の実行要約を書き込めませんでした。"
  fi
}
