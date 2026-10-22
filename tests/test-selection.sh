#!/usr/bin/env bash
# 実際の main.sh とダウンロード経路を使い、選択の表示と終了条件を確認する。
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=tests/helpers.sh
. tests/helpers.sh

tmp="$(mktemp -d)"
SERVER_PID=""
cleanup() {
  touch "$tmp/stop"
  if [ -n "$SERVER_PID" ]; then wait "$SERVER_PID" || true; fi
  rm -rf "$tmp"
}
trap cleanup EXIT
mkdir -p "$tmp/assets" "$tmp/bin" "$tmp/storybook-static"
printf '{}\n' >"$tmp/storybook-static/index.json"
cat >"$tmp/vrt" <<EOF_CLI
#!/usr/bin/env bash
if [ "\$1" = upload ] && [ "\$2" = --help ]; then
  exit 0
fi
printf '%s\\n' "\$*" >"$tmp/args"
printf '%s\\n' "\${LEAKY_SECRET:-absent}" "\${INPUT_GITHUB_TOKEN:-absent}" >"$tmp/inherited"
cat "$tmp/cli.log" >&2
cat "$tmp/cli.json"
exit "\$(cat "$tmp/cli.exit")"
EOF_CLI
chmod +x "$tmp/vrt"
# main.sh の実際の取得と checksum の照合を通すため、全 runner 用の配布物を作る。
for target in x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu x86_64-apple-darwin aarch64-apple-darwin; do
  asset="vrt-${target}.tar.gz"
  tar -czf "$tmp/assets/$asset" -C "$tmp" vrt
  printf '%s  %s\n' "$(sha256_file "$tmp/assets/$asset")" "$asset" >"$tmp/assets/$asset.sha256"
done
printf '[[{"tag_name":"cli-v0.1.2","prerelease":false,"draft":false}]]\n' >"$tmp/releases.json"
STOP_FILE="$tmp/stop" CLI_ASSET_DIR="$tmp/assets" RELEASES_FILE="$tmp/releases.json" python3 tests/fake_server.py \
  >"$tmp/port" 2>"$tmp/server.err" &
SERVER_PID=$!
n=0
while [ ! -s "$tmp/port" ] && [ "$n" -lt 300 ]; do
  sleep 0.1
  n=$((n + 1))
done
[ -s "$tmp/port" ] || fail "fake server did not start"
PORT="$(cat "$tmp/port")"
real_curl="$(command -v curl)"
# GitHub に取りに行く URL だけを local の配布物へ向ける。
cat >"$tmp/bin/curl" <<EOF_CURL
#!/usr/bin/env bash
args=()
for arg in "\$@"; do
  case "\$arg" in
    https://github.com/koyori-app/vrt/releases/download/*)
      arg="http://127.0.0.1:${PORT}/test-cli-assets/\${arg##*/}" ;;
  esac
  args+=("\$arg")
done
exec "$real_curl" "\${args[@]}"
EOF_CURL
chmod +x "$tmp/bin/curl"

# run_action の追加の環境は、公開 workflow の相当する設定に合わせる。
run_action() {
  : >"$tmp/output"
  : >"$tmp/summary"
  local rc=0
  env -i PATH="$tmp/bin:$PATH" \
    INPUT_TOKEN=vrt-secret-canary INPUT_GITHUB_TOKEN=github-secret-canary \
    LEAKY_SECRET=ambient-secret-canary \
    INPUT_URL=https://vrt.example.com/api INPUT_PROJECT=koyori/task \
    INPUT_MODE=storybook INPUT_DIR="$tmp/storybook-static" \
    INPUT_ONLY_CHANGED=true INPUT_STATS_JSON="$tmp/storybook-static/preview-stats.json" \
    INPUT_CLI_VERSION=cli-v0.1.2 INPUT_WAIT=true INPUT_EXIT_ZERO_ON_CHANGES=true \
    GITHUB_REF_NAME=main GITHUB_SHA=deadbeef \
    GITHUB_API_URL="http://127.0.0.1:${PORT}" \
    GITHUB_OUTPUT="$tmp/output" GITHUB_STEP_SUMMARY="$tmp/summary" \
    "$@" bash scripts/main.sh >"$tmp/action.log" 2>&1 || rc=$?
  printf '%s' "$rc"
}
value() {
  awk -F= -v key="$1" '$1 == key {sub(/^[^=]*=/, ""); value=$0} END {print value}' "$tmp/output"
}
result() {
  printf '{"build_id":"b-1","build_number":9,"tenant_slug":"koyori","project_slug":"task","status":"%s","exit_code":%s}\n' "$1" "$2" >"$tmp/cli.json"
  printf '%s\n' "$2" >"$tmp/cli.exit"
}

# 証跡なしで全撮影となる、task の公開 workflow 相当の入力。
result changes_detected 1
cat >"$tmp/cli.log" <<'EOF_LOG'
2026-10-21T00:00:00Z WARN vrt: no artifact provenance (vrt-provenance.json in storybook-static). build via `vrt stamp -- <build command>` to bind the artifact to its commit and enable per-story capture; capturing all stories
2026-10-21T00:00:00Z INFO vrt: finalizing with a full capture
[info] render started: 229 stories
[info] render complete: rendered 229 reused 0 failed 0
EOF_LOG
assert_eq 0 "$(run_action)" "task の差分検出は従来どおり成功へ読み替える"
assert_eq full "$(value optimization-status)" "全撮影の状態を output に残す"
assert_eq missing_provenance "$(value fallback-reason)" "証跡不足の理由を output に残す"
assert_eq 229 "$(value captured-stories)" "実撮影数を取得する"
assert_eq 229 "$(value total-stories)" "ストーリー総数を取得する"
assert_eq 0 "$(value reused-stories)" "ゼロの流用数も取得する"
assert_eq '' "$(value selected-stories)" "全撮影から計画の対象数を推定しない"
assert_eq changes_detected "$(value result)" "VRT の差分状態を保つ"
assert_contains "$(cat "$tmp/summary")" '全ストーリー撮影へ切り替え' "全撮影を要約に示す"
assert_contains "$(cat "$tmp/summary")" missing_provenance "理由を要約にも示す"
assert_contains "$(cat "$tmp/summary")" 229 "件数を要約にも示す"
assert_eq $'absent\nabsent' "$(cat "$tmp/inherited")" "CLI に余分な秘密を渡さない"
assert_contains "$(cat "$tmp/args")" --only-changed "従来の CLI の旗を保つ"

# 何を選んだかを明記したログだけから、選択済みとする。
result passed 0
cat >"$tmp/cli.log" <<'EOF_LOG'
2026-10-21T00:00:00Z INFO vrt: finalizing with only_changed story set count=8
[info] render started: 229 stories
[info] render complete: rendered 9 reused 220 failed 0
EOF_LOG
assert_eq 0 "$(run_action)" "正常な選択の終了値を保つ"
assert_eq optimized "$(value optimization-status)" "対象集合のログを認識する"
assert_eq 8 "$(value selected-stories)" "計画の対象数を取得する"
assert_eq 9 "$(value captured-stories)" "新規追加分を含む実撮影数を別に取得する"
assert_eq 220 "$(value reused-stories)" "流用数を取得する"
assert_eq '' "$(value fallback-reason)" "選択済みの場合は全撮影理由を出さない"
assert_contains "$(cat "$tmp/summary")" 'CLI が撮影対象を選択' "選択を要約にも示す"

# ゼロ件や色付きの tracing ログも、ゼロを未知と読み違えない。
printf '\033[32mINFO\033[0m vrt: finalizing with only_changed story set count=0\n' >"$tmp/cli.log"
assert_eq 0 "$(run_action)" "色付きログでも終了値を保つ"
assert_eq optimized "$(value optimization-status)" "色を落として既知のメッセージを読む"
assert_eq 0 "$(value selected-stories)" "ゼロ件の選択を保つ"
assert_eq '' "$(value captured-stories)" "計画ゼロから実撮影ゼロを推定しない"

# 古い CLI、ログの無効化、未知の文言は最適化に成功した根拠にしない。
for message in '' 'changed files since baseline count=11' 'finalizing with only_changed story set count=unknown' 'INFO vrt: finalizing with only_changed story set count=99999999999999999999' '[info] rendered 1/229 finalizing with only_changed story set count=5'; do
  printf '%s\n' "$message" >"$tmp/cli.log"
  assert_eq 0 "$(run_action)" "読めないログで既存の成功を壊さない"
  assert_eq unavailable "$(value optimization-status)" "根拠がなければ unavailable"
  assert_eq '' "$(value selected-stories)" "未知の対象数を推定しない"
done
assert_contains "$(cat "$tmp/summary")" unavailable "取得不能も要約に示す"

# 理由だけでは実行された計画と断言しない。
printf 'WARN vrt: no baseline commit for this branch yet; capturing all stories\n' >"$tmp/cli.log"
assert_eq 0 "$(run_action)" "finalize 前の警告でも終了値を保つ"
assert_eq unavailable "$(value optimization-status)" "計画確定のログなしでは unavailable"
printf 'INFO vrt: finalizing with a full capture\n' >"$tmp/cli.log"
assert_eq 0 "$(run_action)" "理由が取得できない全撮影でも継続する"
assert_eq full "$(value optimization-status)" "全撮影そのものは確認できる"
assert_eq unknown "$(value fallback-reason)" "全撮影の理由は unknown とする"

# 複数の矛盾した計画は、成功した計画として採用しない。
printf 'INFO vrt: finalizing with a full capture\nINFO vrt: finalizing with only_changed story set count=1\n' >"$tmp/cli.log"
assert_eq 0 "$(run_action)" "矛盾したログでも終了値を保つ"
assert_eq unavailable "$(value optimization-status)" "矛盾した計画は unavailable"

# 全撮影理由の自由文はコピーせず、既知のトークンを再掲ログにも残さない。
cat >"$tmp/cli.log" <<'EOF_LOG'
WARN vrt: no artifact provenance (vrt-secret-canary github-secret-canary). capturing all stories
INFO vrt: finalizing with a full capture
EOF_LOG
assert_eq 0 "$(run_action)" "トークンを含む理由でも終了値を保つ"
assert_eq missing_provenance "$(value fallback-reason)" "自由文を理由コードに限定する"
for secret in vrt-secret-canary github-secret-canary ambient-secret-canary; do
  if grep -F "$secret" "$tmp/output" "$tmp/summary" >/dev/null; then
    fail "secret reached output or summary"
  fi
  # add-mask 自体は従来から秘密を runner に登録する命令である。
  if grep -v '^::add-mask::' "$tmp/action.log" | grep -F "$secret" >/dev/null; then
    fail "secret reached an unmasked log"
  fi
  pass "秘密を output と要約と追加ログに残さない"
done

# wait と差分検出と失敗の組み合わせで、既存の終了契約を変えない。
result changes_detected 1
assert_eq 1 "$(run_action INPUT_EXIT_ZERO_ON_CHANGES=)" "差分検出は指定なしなら終了1"
assert_eq 1 "$(run_action INPUT_EXIT_ZERO_ON_CHANGES=main PR_NUMBER=12 PR_HEAD_SHA=deadbeef)" "PR ではブランチ指定の読み替えを行わない"
result failed 2
assert_eq 2 "$(run_action)" "失敗は exit-zero-on-changes でも終了2"
result processing 0
assert_eq 0 "$(run_action INPUT_WAIT=false)" "wait:false の受理済み build は終了0"
assert_eq '' "$(value captured-stories)" "待たない場合に実撮影数を推測しない"
printf '3\n' >"$tmp/cli.exit"
assert_eq 2 "$(run_action INPUT_WAIT=false)" "wait:false の CLI 失敗は終了2"

# JSON が出ない失敗や不完全な応答も、従来の終了値を保つ。
printf 'not json\n' >"$tmp/cli.json"
assert_eq 1 "$(run_action)" "JSON を出さない失敗は従来どおり終了1"
assert_eq failed "$(value result)" "JSON がなくても失敗を出力する"
assert_contains "$(cat "$tmp/summary")" 'VRT の撮影対象' "失敗時にも要約を出す"
printf '{"status":"passed","exit_code":0}\n' >"$tmp/cli.json"
assert_eq 2 "$(run_action)" "build ID が null の応答は従来どおり終了2"
result passed 0
printf '3\n' >"$tmp/cli.exit"
assert_eq 0 "$(run_action)" "wait:true は従来どおり JSON の結果コードを使う"

# arc の公開 workflow 相当では、追加 output も要約も書かない。
result changes_detected 1
assert_eq 0 "$(run_action INPUT_PROJECT=koyori/arc INPUT_ONLY_CHANGED=false INPUT_STATS_JSON=)" "arc 相当の差分検出は従来どおり成功"
assert_eq 4 "$(wc -l <"$tmp/output" | tr -d '[:space:]')" "only-changed が無効なら従来の4出力だけ"
assert_eq '' "$(cat "$tmp/summary")" "only-changed が無効なら要約を追加しない"
assert_eq 0 "$(run_action INPUT_ONLY_CHANGED= INPUT_STATS_JSON=)" "only-changed が未指定でも従来の成功を保つ"
assert_eq 4 "$(wc -l <"$tmp/output" | tr -d '[:space:]')" "未指定時も従来の4出力だけ"

# 要約の書き込み不能を、撮影の失敗に読み替えない。
result passed 0
assert_eq 0 "$(run_action GITHUB_STEP_SUMMARY="$tmp/missing/summary")" "要約を書けなくても終了条件を保つ"
