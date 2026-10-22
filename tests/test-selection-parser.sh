#!/usr/bin/env bash
# 理由と件数を、既知のログから両方の OS で同じように読む。
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=tests/helpers.sh
. tests/helpers.sh
# shellcheck source=scripts/selection.sh
. scripts/selection.sh

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

check_reason() {
  printf '2026-10-21T00:00:00Z WARN vrt: %s\n' "$2" >"$tmp/log"
  printf '2026-10-21T00:00:00Z INFO vrt: finalizing with a full capture\n' >>"$tmp/log"
  read_selection_log "$tmp/log"
  assert_eq full "$OPTIMIZATION_STATUS" "$1 の全撮影状態"
  assert_eq "$1" "$FALLBACK_REASON" "$1 の理由コード"
  assert_eq '' "$SELECTED_STORIES" "$1 から対象数を推定しない"
}
check_reason missing_baseline 'no baseline commit for this branch yet; capturing all stories'
check_reason insufficient_history 'could not diff against baseline (missing commit); capturing all stories'
check_reason missing_provenance 'no artifact provenance (vrt-provenance.json in storybook-static); capturing all stories'
check_reason legacy_provenance 'the artifact provenance in storybook-static predates build ownership (version 1); capturing all stories'
# shellcheck disable=SC2016  # ログ内のバッククォートは展開しない。
check_reason dependency_or_storybook_config_changed 'changed file `pnpm-lock.yaml` forces a full capture (dependency/Storybook config change); capturing all stories'
# shellcheck disable=SC2016  # ログ内のバッククォートは展開しない。
check_reason dependency_or_storybook_config_changed 'changed file `.storybook/preview.ts` forces a full capture (dependency/Storybook config change); capturing all stories'
# shellcheck disable=SC2016  # ログ内のバッククォートは展開しない。
check_reason outside_graph 'changed file `public/image.png` is not in the dependency graph; capturing all stories'
check_reason unknown 'a future fallback reason; capturing all stories'

# 計画と実撮影と流用をそれぞれ確認する。
cat >"$tmp/log" <<'EOF_LOG'
2026-10-21T00:00:00Z INFO vrt::upload: finalizing with only_changed story set count=8
[info] render started: 229 stories
[info] render complete: rendered 9 reused 220 failed 0
EOF_LOG
read_selection_log "$tmp/log"
assert_eq optimized "$OPTIMIZATION_STATUS" "名札に階層があるログの選択状態"
assert_eq 8 "$SELECTED_STORIES" "選択ログの対象数"
assert_eq 229 "$TOTAL_STORIES" "開始ログの総数"
assert_eq 9 "$CAPTURED_STORIES" "完了ログの実撮影数"
assert_eq 220 "$REUSED_STORIES" "完了ログの流用数"
assert_eq '' "$FALLBACK_REASON" "選択時は前の全撮影理由を残さない"

# 件数がメッセージより前にある形と、ゼロの扱いを確認する。
cat >"$tmp/log" <<'EOF_LOG'
INFO vrt: count=0 finalizing with only_changed story set
[info] render started: 1 stories
[info] render complete: rendered 1 reused 0 failed 0
EOF_LOG
read_selection_log "$tmp/log"
assert_eq optimized "$OPTIMIZATION_STATUS" "前置した件数でも選択を認識する"
assert_eq 0 "$SELECTED_STORIES" "ゼロの計画対象数を読む"
assert_eq 1 "$TOTAL_STORIES" "新規ストーリーがある総数を読む"
assert_eq 1 "$CAPTURED_STORIES" "計画ゼロでも追加撮影を別に読む"
assert_eq 0 "$REUSED_STORIES" "ゼロの流用数を読む"

# ANSI の除去が、日時と水準と名札の除去を妨げないことを確認する。
printf '\033[2m2026-10-21T00:00:00Z\033[0m \033[32mINFO\033[0m vrt: finalizing with only_changed story set \033[3mcount\033[0m=8\n' >"$tmp/log"
read_selection_log "$tmp/log"
assert_eq optimized "$OPTIMIZATION_STATUS" "色付きの日時と水準とフィールドを読む"
assert_eq 8 "$SELECTED_STORIES" "色付きのフィールドでも対象数を読む"
assert_eq '' "$CAPTURED_STORIES" "計画だけで撮影数を推定しない"
assert_eq '' "$TOTAL_STORIES" "開始ログなしで総数を推定しない"
assert_eq '' "$REUSED_STORIES" "完了ログなしで流用数を推定しない"

# 途中の進捗や壊れた完了ログから、実績を作らない。
cat >"$tmp/log" <<'EOF_LOG'
INFO vrt: finalizing with only_changed story set count=8
[info] rendered 1/229 button--primary
[info] render complete: rendered unknown reused 220 failed 0
EOF_LOG
read_selection_log "$tmp/log"
assert_eq optimized "$OPTIMIZATION_STATUS" "実績がなくても選択の根拠は保つ"
assert_eq '' "$CAPTURED_STORIES" "途中の進捗から実撮影数を推定しない"
assert_eq '' "$REUSED_STORIES" "壊れた完了ログから流用数を採用しない"
assert_eq '' "$TOTAL_STORIES" "進捗の分母を総数として採用しない"
