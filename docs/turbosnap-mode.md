# TurboSnap 相当の撮影対象を選ぶ mode の設計

本書は実装前の設計案である。
`mode: turbosnap` を新設し、Storybook の build、生成元の検証、撮影対象の選択、結果の表示を一つの action で扱う。
既存の `screenshots` と `storybook` は既定値も入力の意味も保つ。
新しい mode を選ばない workflow は書き換えずに使える。

調査日は 2026年10月21日である。
action の調査基準は `ca529f2000f543930dda075f0a7501eeb56d1a1e`、VRT 本体の調査基準は `cf39c6d556c0482c76574a404410cf32b418c1bf` とする。
本体の main にある機能が公開済み CLI に含まれるとは限らないため、提供時には対応する CLI とサーバーの組み合わせを検証して公開する。

## 解く問題

撮影を減らすには、変更がどのストーリーへ届くかを判定する材料が要る。
本書では、Storybook を生成したコミットと stats と index の内容を結び付ける `vrt-provenance.json` を**生成証跡**と呼ぶ。
生成証跡は `vrt stamp -- <build command>` が build を実行して作る。
既存の action は build 済みの `dir` を受け取るため、利用者が普通に Storybook を build しただけでは生成証跡ができない。

[arc の issue #44][arc44] は task での実測について、次のように記録している。

> `only-changed: true` を渡しても毎回 229 件すべてを撮っており

同じ issue のログには、次の警告がある。

> no artifact provenance

この記録では baseline と git 差分は取得できており、証跡不足で全撮影へ戻っている。
警告をログに出すだけでは、利用者が絞り込みに成功したと思い込める。
そこで、全撮影へ戻した理由を機械向け output と人向け実行要約に常に残し、必要な利用者は全撮影を失敗として扱えるようにする。

## 現状でできることと不足

同じ repo 内の道は調査基準の内容を指す。
CLI とサーバーの根拠は末尾の公開ソースに示す。

| 層 | 確認した場所 | 既にできること | 不足するもの |
| --- | --- | --- | --- |
| 入口 | [action.yml](../action.yml) | `mode` は `screenshots` と `storybook`、`only-changed` と `stats-json` を受け取る | build の入口、全撮影へ戻ったことの output、厳格な失敗指定 |
| 入力解決 | [scripts/validate.sh](../scripts/validate.sh) | mode 別の `dir`、コミット、stats の既定値を決め、無効な組み合わせを弾く | build の作業ディレクトリと相対パスの契約、新しい mode の検証 |
| script | [scripts/storybook.sh](../scripts/storybook.sh) の `run_storybook` | build 済み `dir/index.json` を検査し、CLI に `upload --only-changed --stats-json` を渡す | CLI を build 前に用意して stamp を実行する処理、選択結果の取得 |
| 出力 | [scripts/lib.sh](../scripts/lib.sh) と [scripts/main.sh](../scripts/main.sh) | build の ID、URL、結果、終了コードを書く | 絞り込みの状態と理由、計画件数と実撮影件数、実行要約 |
| 説明 | [README.md](../README.md) の storybook モード | stats と git 履歴の用意、全撮影への切り替え、baseline の流用を説明する | 例の build に stamp がなく、生成証跡が必要なことを説明していない |
| CLI | [main.rs][cli-main] の `run_stamp` と `resolve_only_story_ids` | stamp が build 前後の HEAD と clean 状態を調べ、成果物を検証して影響ストーリーを選ぶ | action が安定して読める選択状態と理由、全撮影を止める契約 |
| 選択の芯 | [turbosnap.rs][cli-turbosnap] と [plan.rs][cli-plan] | git 差分と stats の逆依存グラフと index から対象を選び、不明な変更は全撮影にする | action 向けの安定した理由コード、未対応 builder を明示する機能 |
| 撮影の芯 | [render_build.rs][render] | 選択外を固定した baseline から流用し、baseline にないストーリーは撮影する | action が得られる実撮影件数と流用件数の構造化された結果 |

不足は action の旗だけでは埋まらない。
現状の CLI は選択理由を警告へ出すが、action が読む upload の JSON にはその契約がない。
新しい mode の公開には CLI とサーバー側の対応も必要になる。

## build を action の中で実行する

生成証跡を得る方法として、次の二案を比較した。

| 案 | 利点 | 利用者の負担と欠点 | 判断 |
| --- | --- | --- | --- |
| action が CLI を用意し、`vrt stamp` で build する | build と upload に同じ CLI、作業場所、成果物のパスを使える | 利用者は build step を action の入力へ移す必要がある | 新しい mode の標準として採る |
| 利用者が事前に CLI を用意して stamp し、action は既存の `storybook` で送る | 複雑な独自 build を利用者が制御できる | CLI の取得と版の整合、パス合わせを利用者が二重に担う | 既存の上級者向け経路として残す |

action 内で build すれば、issue #44 の「CLI を取得する時点が build より後」という順序を解消できる。
既存の build 済みディレクトリを受け取る契約は `storybook` に残すため、利用者が移行を急ぐ必要もない。
新しい mode では build を省略して既存成果物へ後付けで stamp する経路を設けない。
CLI の `run_stamp` が build 前に旧証跡と stats と index を無効化するため、生成済み成果物のキャッシュだけを復元して成功したことにもできない。

### 実行の順序

1. 入力を検証し、checkout 済み HEAD と記録対象の `commit` が一致することを確認する。
2. 新しい契約に対応した CLI とサーバーかを能力照会で確認する。
3. `working-directory` を解決し、その中で同じ CLI の `vrt stamp` を実行する。
4. 成功後に生成証跡、stats、index を検証し、同じ作業場所から upload する。
5. サーバーが決めた baseline を固定し、それを起点に撮影対象を計画する。
6. 全撮影へ戻る場合は理由を確定し、失敗指定があれば撮影を開始せず終了する。
7. 受理した計画で finalize し、`wait` の指定に応じて待つ。
8. 成功、全撮影、失敗のいずれでも output と実行要約を書き出す。

`build-command` は利用者が workflow に記す一つの shell コマンド文字列とする。
action はこれを入力用の環境変数から読み、`vrt stamp --dir <解決済みのdir> --stats-json <解決済みのstats> -- bash --noprofile --norc -e -o pipefail -c <build-command>` の引数として渡す。
ここに示すのは実行契約であり、現在利用できる action の実装例ではない。
workflow の式を action 自身の shell ソースへ直接埋め込む形は取らない。
PR の題名など外部入力を `build-command` に差し込まないよう説明する。

build の作業場所は `GITHUB_WORKSPACE` を基準に解決する。
`working-directory` は実在するディレクトリを指定し、実パスが workspace の外へ出る指定を入力エラーとする。
新しい mode の `dir` と `stats-json` はその作業場所からの相対パスとし、同じ解決結果を stamp と upload へ渡す。
既存の `storybook` のパス解決は変えない。
CLI のモジュール名は build の作業場所を基準に解決されるため、stamp だけをサブディレクトリで実行して upload を repo 直下で実行する形を避ける。

build が非ゼロ終了した場合、生成証跡を作れない場合、HEAD が途中で動いた場合、追跡ファイルが汚れた場合は upload を実行しない。
要約には失敗した段階と子プロセスの終了コードを示し、`result=failed`、`exit-code=2` とする。
build の終了コードと action の終了コードは別に記録する。
依存の導入や WASM の準備などは利用者の事前 step に残し、それらが追跡ファイルを書き換える環境では clean な build 手順へ直す必要を説明する。

CLI の取得と build と upload は資格情報を分ける。
GitHub の取得用トークンは CLI の取得だけに使い、build には action の VRT トークンと取得用トークンを渡さない。
build には Node や pnpm の PATH と利用者が明示した build 用環境を残す。
upload は既存と同じく必要な `VRT_*` と PATH へ絞り、build コマンドやエラーを表示するときにもトークンを含めない。
秘密を持たない fork PR へ秘密を渡すための workflow 変更は行わず、既存の実行条件を保つ。

## 入力と後方互換

以下は提案する入力契約である。
新しい入力と mode は未実装であり、例の提供版は対応機能を公開した版へ置き換える。

| 入力 | 今までの既定値 | 設計後の既定値と意味 | 区分 |
| --- | --- | --- | --- |
| `token` | 必須 | 同じ PAT を upload に使う | 今までどおり |
| `project` | 必須 | 同じ `tenant/project` | 今までどおり |
| `url` | 必須 | 同じ API URL | 今までどおり |
| `mode` | `screenshots` | 既定を保ち、選択肢 `turbosnap` を追加 | 選択肢だけ新設 |
| `dir` | `screenshots` は `./screenshots`、`storybook` は `./storybook-static` | 既存二種は同じ、新しい mode は作業場所から `./storybook-static` | 新しい mode の解決規則を追加 |
| `only-changed` | `false` | `storybook` の `true` は同じ、新しい mode は値にかかわらず選択を有効にする | 既存の意味を維持 |
| `stats-json` | 入力は空、`only-changed: true` なら `<dir>/preview-stats.json` | 既存は同じ、新しい mode も `<dir>/preview-stats.json` | 新しい mode でも受理 |
| `wait` | `true` | 同じ、新しい mode の計画結果は待たなくても返す | 今までどおり |
| `exit-zero-on-changes` | 空 | 差分検出の終了コード 1 だけを読み替える | 今までどおり |
| `branch` | `GITHUB_HEAD_REF`、なければ `GITHUB_REF_NAME` | 同じ | 今までどおり |
| `commit` | PR head SHA、なければ `GITHUB_SHA` | 同じ、新しい mode は checkout HEAD との一致を必須にする | 新しい mode だけ検証を追加 |
| `cli-version` | `latest` | 既存は同じ、新しい mode は対応能力を検査する | 新しい mode だけ検証を追加 |
| `app-url` | `url` から末尾の `/api` を除く | 同じ | 今までどおり |
| `github-token` | `${{ github.token }}` | 同じ、CLI の取得に限って使う | 今までどおり |
| `build-command` | なし | 空、新しい mode では必須 | 新設 |
| `working-directory` | なし | `.`、新しい mode の build と upload の作業場所 | 新設 |
| `fail-on-fallback` | なし | `false`、新しい mode の全撮影を撮影前に失敗へ変える | 新設 |

`only-changed` は新しい mode に吸収して廃止することをしない。
既存利用者が `mode: storybook` と `only-changed: true` を書いた場合は、証跡不足なら全撮影する従来の動作と成功条件を保つ。
新しい mode は撮影対象の選択を必ず試みるため、選択を切りたい利用者は `storybook` へ戻す。
`only-changed: false` の既定値が新しい mode を無効にすることはない。

`build-command` と `working-directory` と `fail-on-fallback` は新しい mode 専用とする。
既存二種に build コマンドや `fail-on-fallback: true` を指定した場合は、未対応の組み合わせとして明示的に拒否する。
`working-directory: .` など入力から省略と区別できない既定値は拒否せず、既存 mode のパス解決へ影響させない。
新しい mode で stats の独自パスを指定した場合は、実際の build が同じ場所へ書くよう利用者がコマンドを設定する。
action が `--stats-json` を無条件にコマンド末尾へ足すと、各 build ツールの引数契約を壊すため、自動付加しない。

### 現在の利用者を変えない場合

公開 workflow [arc][arc-workflow] は `storybook`、`only-changed: false`、`cli-v0.1.2` を指定している。
公開 workflow [task][task-workflow] は `storybook`、`only-changed: true`、stats の明示パス、`cli-v0.1.2` を指定している。
どちらも action を `ca529f2000f543930dda075f0a7501eeb56d1a1e` に固定しているため、新しい設計の公開だけでは動作が変わらない。
action の参照だけを更新しても、既存 mode では build の代行、CLI の強制更新、生成証跡の必須化、全撮影時の失敗を導入しない。
旧 CLI から選択状態を得られない場合は `unavailable` と表示し、推定で「最適化済み」とは書かない。

### 新しい mode へ移る workflow の形

次は task のように `apps/frontend` で build する場合の将来の記述例である。
`<対応ActionのSHA>` と `<対応CLIのタグ>` は公開時に検証済みの値へ置き換える。
この例は現在そのまま実行できる workflow ではない。

```yaml
steps:
  - uses: actions/checkout@v4
    with:
      ref: ${{ github.event.pull_request.head.sha || github.sha }}
      fetch-depth: 0
      persist-credentials: false
  # Node と pnpm の準備、依存の導入は従来の step を残す。
  # 従来の Build Storybook step は削り、下の build-command へ移す。
  - name: Build and upload Storybook
    id: vrt
    uses: koyori-app/vrt-actions@<対応ActionのSHA>
    with:
      token: ${{ secrets.VRT_TOKEN }}
      project: acme/web
      url: https://vrt.example.com/api
      mode: turbosnap
      working-directory: apps/frontend
      build-command: pnpm build-storybook --stats-json
      dir: ./storybook-static
      stats-json: ./storybook-static/preview-stats.json
      cli-version: <対応CLIのタグ>
      wait: true
      exit-zero-on-changes: true
      fail-on-fallback: false
```

移行時には action の参照と CLI の固定版を更新し、build step を `build-command` に移す。
`only-changed` は省略でき、`dir` と `stats-json` は作業場所からの相対パスへ直す。
arc では `working-directory: packages/arc-vue` とし、既存の Rust と WASM と Node と pnpm の準備は残す。
arc の checkout には `fetch-depth: 0` を追加する。
task には既にこの履歴指定がある。
イベントや fork PR の実行条件、既存の権限は変更しない。
PR では checkout の ref と記録するコミットを head SHA にそろえ、マージ後の状態を別途確認したい場合は別の明示的な検証として実行する。

## 全撮影になったことを表示する

output と実行要約を標準で採り、`fail-on-fallback` を追加の選択肢にする。
既定は `false` とする。
初回や依存更新での全撮影は通常の安全な動作でもあり、既定で失敗にすると有効化直後から利用者の job を止めるためである。
一方で、出力だけでは人が見落とし、要約だけでは自動集計できないため、両方を使う。

CLI の upload 結果に版付きの `selection` を追加する設計とする。
`selection` には要求した最適化、実際の計画種別、理由コード、補足理由、baseline の識別子とコミット、対象コミット、計画対象数、全ストーリー数を持たせる。
サーバーが finalize 時に受理した計画と固定した baseline を、この情報の根拠にする。
ログの文言を検索して理由を推測する実装は採らない。
新設する CLI の入口は `vrt capabilities --json` と `vrt upload --fail-on-fallback` とする。
能力照会は CLI の機能版を返し、新しい mode は `selection-v1`、`stamp-v2`、`fail-on-fallback-v1` を必須とする。
upload は撮影の前にサーバーの対応能力も確認し、非対応なら finalize しない。
`--fail-on-fallback` は入力が `true` のときだけ渡す。
既存の `vrt upload --json` に `selection.schema_version=1` を追加し、旧 CLI の JSON がこのフィールドを持つとは仮定しない。
`selection` の `plan` は `only` または `all`、`reason_codes` は配列とし、計画対象数と実撮影数は別の値にする。
厳格指定で止まるときも JSON を出し、全撮影の理由を action が取得できるようにする。
以下の output はその構造化結果を変換したものである。

| 新しい output | 値と意味 |
| --- | --- |
| `optimization-status` | `optimized` は検証済みの対象選択を受理、`full` は全撮影へ切り替え、`disabled` は要求なし、`unavailable` は旧版で取得不能、`error` は計画不能 |
| `fallback-reason` | `full` では必須の安定した理由コード、それ以外は空 |
| `selection-reasons` | 全理由コードの JSON 配列、説明文と分ける |
| `selected-stories` | 計画に含めた対象数、未確定なら空 |
| `total-stories` | index の有効ストーリー総数、未確定なら空 |
| `captured-stories` | サーバーが実際に撮影した数、結果未確定なら空 |
| `reused-stories` | サーバーが baseline から流用した数、結果未確定なら空 |

`build-id` と `build-url` と `result` と `exit-code` は維持する。
全ストーリーが依存上の影響を受けて `selected-stories=total-stories` となっても、検証済みの選択結果なら `optimized` とする。
理由不明で全撮影へ戻った場合と区別するため、要約には件数も並べる。
選択対象がゼロでも baseline のないストーリーは撮影するため、計画対象数を実撮影数として表示しない。

実行要約には要求 mode、選択状態、全撮影の理由、計画対象数と総数、実撮影数と流用数、baseline のコミット、レビュー URL、次に直す設定を表で出す。
`full` の場合は要約の先頭に「全ストーリー撮影へ切り替え」と書き、Actions の warning annotation も出す。
例として、証跡不足なら `optimization-status=full`、`fallback-reason=missing_provenance` とし、stamp を通す build 手順を案内する。
新しい mode の正常な build ではこの不足を予防できるが、旧形式の成果物や将来の取得経路でも理由を表示できる契約にする。

`wait: false` でも計画を受理した時点の状態と理由を output と要約へ出す。
実撮影数と流用数は空とし、「未確定」と表示する。
`result` が処理中であることと、対象選択が成功したことは別に扱う。

`fail-on-fallback: true` は、初回を含むすべての `full` を失敗にする。
CLI が baseline を得て選択結果を確定した後、finalize より前に停止し、撮影 job を投入しない。
作成済み build は理由付きの失敗状態へ終端させる API 契約を本体に追加し、pending のまま残さない。
この場合も選択状態は `full`、理由は実際の理由のまま、`result=failed`、`exit-code=2` とする。
`exit-zero-on-changes` はコード 1 だけに効くため、この失敗を成功に変えない。
最初の baseline を作るときは `fail-on-fallback: false` を使い、その後に厳格指定へ切り替えられる。

新しい mode は必要な能力を持たない CLI やサーバーを実行前の照会で拒否する。
構造化結果の欠落、不正な版、未知の状態も成功扱いにせず、取得できなかった段階を `error` として示す。
既存 mode は能力照会を必須にせず、選択を要求したのに追加情報が取れなければ `unavailable` として従来の終了条件を保つ。
`screenshots` と `only-changed: false` の `storybook` は要求していないことが分かるため `disabled` とする。
通常のエラー、build 失敗、厳格指定の停止でも要約と outputs を後処理で書く。
runner の強制終了や通信断で後処理自体が動けない場合まで表示を保証することはできないため、開始時にも「計画未確定」の要約を作り、完了時に更新する。

## 全撮影とエラーの境界

次の表は新しい mode の判断である。
理由コードは提案であり、既存 CLI が同じ文字列を返すことを意味しない。
複数理由がある場合は全理由を保存し、表の順で最初の理由を `fallback-reason` にする。
破損やコミット不一致は全撮影で隠さず、先にエラーとして扱う。

| 条件 | 判断と理由コード | 見逃しを防ぐ根拠 |
| --- | --- | --- |
| 生成証跡のコミット不一致、内容ハッシュ不一致、不正 JSON、未知の証跡版 | エラー | 別の成果物を信じて一部撮影すると偽の成功になり得る |
| HEAD と対象コミットの不一致、追跡ファイルの変更 | エラー | 選択の入力と記録先が違う |
| stats や index の破損、必要な `importPath` の欠落、空または不正な index | エラー | 一部のストーリーだけを黙って落とせない |
| build 失敗、stats や index を再生成できない | エラー | 新しい mode の stamp が成立していない |
| 選択後に baseline が変わった | エラー | finalize の照合で止め、計画を勝手に別 baseline へ転用しない |
| プロジェクトに baseline がない | 全撮影、`missing_baseline` | 流用元がない |
| 枝の初回 build | baseline が解決できなければ上と同じ、解決できれば検証して選択 | 枝の初回という事実だけから流用元を推測しない |
| shallow checkout、baseline のコミットが取れない、git 差分を確定できない | 全撮影、`insufficient_history` | 変更の起点を失っている |
| 生成証跡なし、build 所有を証明しない旧 v1 証跡 | 全撮影、`missing_provenance` または `legacy_provenance` | 既存 CLI の安全な移行動作を理由付きで示す |
| stats がない | 旧経路では全撮影、`missing_stats` | 新しい mode ではその前の stamp 失敗となる |
| `package.json`、`pnpm-lock.yaml`、`yarn.lock`、`package-lock.json` の変更 | 全撮影、`dependency_changed` | 現行の芯に合わせ、依存更新の波及を限定しない |
| `.storybook/` 配下の変更 | 全撮影、`storybook_config_changed` | 共通の設定が全ストーリーへ影響し得る |
| preview が参照する共通依存の変更 | 到達する全ストーリーを選ぶ、解釈不能なら全撮影 | グラフで全件へ到達した場合は正当な選択として件数を示す |
| staticDirs、画像、フォント、外部 Sass 生成元などのグラフ外の変更 | 全撮影、`outside_graph` | 現行の芯の保守的な判定を保つ |
| 未対応 builder、解釈できない stats 形式、完全性を検証できない graph | 全撮影、`unsupported_graph`、破損データならエラー | 空の graph を正常なゼロ件選択と誤認しない |
| monorepo 内の別パッケージや未知の変更 | グラフ外で既知の無関係ファイルにも当たらなければ全撮影 | repo 外の影響を無根拠に無視しない |
| repo 直下の既知の説明文書だけが変更された | 現行の芯の限定した除外を適用 | 任意の Markdown や静的アセットを一律に除外しない |
| 影響のあるストーリーがゼロ | 検証済み選択としてゼロ件を送る | 全撮影を意味する null と空配列を区別する |
| 選択外のストーリーに baseline の画像がない | そのストーリーを追加撮影 | 新規ストーリーを流用扱いで消さない |

現行の webpack 形式の解析を、Chromatic の Vite 対応と同等だとは宣言しない。
新しい mode の初期提供は検証済み builder に限定し、対応外は上の理由で表示する。
グラフが表現しない動的依存を常に検出できるわけではないため、builder ごとの fixture と全撮影との突き合わせで対応範囲を決める。
見逃しを増やし得る任意の除外設定は初期提供に含めない。

## baseline の流用と比較の境界

対象外のストーリーは finalize が固定した baseline の同名エントリから流用する。
サーバーの `decide_story_action` は、対象外でも同名 baseline がなければ撮影へ戻す。
空の選択集合でもこの判定を省かない。
削除されたストーリーは現在の index に存在しないため、baseline の全項目を無条件に複製する実装にしない。
実撮影数と流用数はこの処理後に確定する。

選択計画は baseline のコミットと結び付けて finalize する。
既存 CLI の `expected_baseline` の照合を維持し、流用元が変われば計画を拒否する。
通信失敗や計画拒否を全撮影成功へ読み替えず、同じコミットから再実行するための情報を残す。

TurboSnap 相当 mode は「どのストーリーを撮るか」を変える。
[PR #60][dom-design] と [PR #61][dom-implementation] の DOM と CSSOM の一致によって画素差分の閾値を緩める仕組みは「撮った後の比べ方」を変えるため、本設計とは別に扱う。
この mode で画素の閾値や承認条件を変えない。

## Chromatic に倣う範囲

Chromatic の [概要][chromatic-overview] は、選択の材料を次のように説明している。

> Git history and builder’s dependency graph

また、対象外について次のように説明している。

> copies over the snapshots from baselines that didn’t change

[setup][chromatic-setup] は事前 build に stats を付ける方法と、外部アセットに追加設定が要ることを説明している。
その設計から、build と選択の責任、全撮影にする条件、選択外の扱いを分けて比較する。

| 論点 | Chromatic の公開仕様 | 本設計で倣う範囲 | 倣わない範囲と理由 |
| --- | --- | --- | --- |
| 変更の根拠 | git 履歴と builder の依存グラフを使う | 同じ材料でストーリーへの逆依存をたどる | 複数 ancestor の union は初期提供に持ち込まない、VRT が固定した baseline との二点差分を使う |
| graph の取得 | Webpack と Vite の build stats、事前 build には `--stats-json` | 新しい mode が stamp を通す build を実行し、stats と index を束縛する | Vite や全 builder の同等対応を前提にしない、対応 fixture を増やして別途公開する |
| 設定の変更 | Storybook 設定と preview の依存の変更は全撮影になり得る | `.storybook/` と未知の共通影響を保守的に扱う | `untraced` による任意除外は見逃しの検証を増やすため後回し |
| 依存の変更 | lockfile の情報から変更依存をたどり、判定不能なら全撮影 | 判定不能なら全撮影する | 初期提供では package と lockfile の変更を常に全撮影する、依存版の精密比較は実装しない |
| 外部アセット | `externals` と static assets の設定を持つ | graph の外の変更では全撮影へ戻す | globs の入力は設けない、まず見逃しを避ける |
| 初回と baseline 不在 | ancestor が見つからなければ全撮影となる | VRT の baseline がなければ全撮影する | 枝の初回でも解決した baseline があれば使う、Chromatic の ancestor 選択は複製しない |
| 対象外の結果 | baseline の snapshot を複製し、条件次第では build を bypass する | baseline を流用し、不足する画像は撮影する | build 全体の bypass、課金上の扱い、UI 指標の同等化は対象外 |
| 成否の表示 | CLI と build ページに適用状態や bail 理由を表示する | output、実行要約、warning、選べる失敗指定を備える | 警告の文言から状態を逆算しない |
| 利用開始 | setup は CI で10 build 完了などの前提を示す | 移行初期に全撮影との照合を行う | 10 build の機械的制限は設けない、VRT の運用で判断する |
| PR と git | setup は `pull_request` の一時的マージコミットによる食い違いを説明する | checkout HEAD と記録コミットと証跡を一致させる | イベントを `push` に限定しない、既存利用者の PR 検証を保つ |

資料間には stats 欠落時の説明の差がある。
setup は次のように記している。

> Chromatic doesn’t fail the build.

一方で [troubleshooting][chromatic-troubleshooting] の `missingStatsFile` は、次のように記している。

> Newer versions fail the build with an error message instead of bailing

このため、Chromatic の現行版が必ず警告だけで進むとは断定しない。
本設計は独自の契約として、既存 mode の動作を維持し、新しい mode の stamp 不成立はエラー、通常の全撮影は表示して継続、厳格指定時は撮影前に失敗と決める。

## 公開資料と短い引用

以下はすべて 2026年10月21日に取得した。
引用は設計判断に必要な短い部分だけを掲載し、他の文書の全文は同梱しない。
CLI の公開ソースへのリンクは調査時のコミットに固定している。

| 資料 | URL | 根拠となる短い引用または識別子 |
| --- | --- | --- |
| arc の実測 | [issue #44][arc44] | 「毎回 229 件すべてを撮っており」 |
| TurboSnap の導入 | [setup][chromatic-setup] | `--only-changed`、`--stats-json` |
| 選択と流用 | [概要][chromatic-overview] | “Git history and builder’s dependency graph” |
| 全撮影の理由 | [troubleshooting][chromatic-troubleshooting] | `changedPackageFiles`、`changedStorybookFiles`、`invalidChangedFiles`、`noAncestorBuild` |
| CLI の build と upload | [main.rs][cli-main] | `run_stamp`、`resolve_only_story_ids`、`expected_baseline` |
| 生成証跡の検証 | [provenance.rs][cli-provenance] | `PROVENANCE_VERSION: u32 = 2`、`Verification::Missing`、`Verification::Unowned` |
| 依存の選択 | [turbosnap.rs][cli-turbosnap] | `compute_affected_stories`、`is_full_capture_trigger` |
| 計画の共通処理 | [plan.rs][cli-plan] | `Selection::CaptureAll`、`CorruptInput::Error` |
| 対象外の流用 | [render_build.rs][render] | `decide_story_action` |
| 既存の利用者 | [arc の workflow][arc-workflow]、[task の workflow][task-workflow] | `mode: storybook`、`cli-version: cli-v0.1.2` |
| DOM の設計 | [PR #60][dom-design] | 「DOM と CSSOM の一致で画素の閾値を緩める」 |
| DOM の実装 | [PR #61][dom-implementation] | 「DOM と CSSOM の正規化と hash」 |

## 実装の段取りと戻し方

以下は将来の実装案であり、本変更は文書だけを追加する。
新しい mode は各段の前提がそろうまで公開しない。

| 段 | 実装することと確認 | 既存環境への影響 | 使う側の workflow の変更 | 戻し方 |
| --- | --- | --- | --- | --- |
| 1 | CLI の版付き選択結果、理由、能力照会を追加し、サーバーの計画受理と件数と厳格停止の終端契約を整える | 既存応答への追加を基本にし、旧 CLI の upload を保つ | なし | 旧版 CLI と既存応答へ戻せる、保存する追加情報は削除を前提にしない |
| 2 | action に選択 output と実行要約を追加し、旧 CLI で `unavailable` となることを確認する | 既存の終了条件を保ち、出力だけ追加 | なし、導入する場合は action 参照の更新 | action の SHA を旧版へ戻せる |
| 3 | `turbosnap` と build 入力とパス検証と stamp 実行を追加する | 選んだ利用者だけ build の担当が変わる | action と CLI の参照、build step、作業場所、パスを更新する | 元の build step と `storybook` と CLI の固定版へ戻す |
| 4 | 全撮影理由、厳格指定、結果待ちの有無、失敗時 outputs を結合試験する | 既定は全撮影を許す、厳格指定だけ追加で失敗する | 厳格指定を使う利用者だけ `fail-on-fallback` を追加する | `false` へ戻せる、baseline を作り直す必要はない |
| 5 | 対象を限定して全撮影と並行比較し、arc と task への移行を別変更で提案する | 見逃しと全撮影率を確認してから広げる | 移行を選ぶ repo だけ変更する | repo ごとに旧 workflow と旧参照へ戻せる、承認済み baseline は保つ |

試験では、未変更の arc と task の公開 workflow 相当の入力を旧 CLI で再現し、既存の終了条件を変えていないことを確認する。
新しい mode では、初回 baseline 不在、正常な部分選択、選択ゼロ、全件が影響対象、依存更新、設定変更、グラフ外のアセット、履歴不足、証跡の欠落と改変、build 失敗、baseline の競合、旧 CLI と旧サーバー、`wait: false` を分けて確認する。
全撮影した対照結果と選択後の結果を比較し、新規ストーリーの追加撮影と既存 baseline の流用を含めて一致を確認する。
厳格指定時には撮影 job が投入されず build が終端すること、`exit-zero-on-changes: true` でも失敗を隠さないことを確認する。
これは実装時に必要な検証の定義であり、本書の追加だけで試験済みとは扱わない。

[arc44]: https://github.com/koyori-app/arc/issues/44
[chromatic-setup]: https://www.chromatic.com/docs/turbosnap/setup/
[chromatic-overview]: https://www.chromatic.com/docs/turbosnap/
[chromatic-troubleshooting]: https://www.chromatic.com/docs/turbosnap/troubleshooting/
[cli-main]: https://github.com/koyori-app/vrt/blob/cf39c6d556c0482c76574a404410cf32b418c1bf/apps/backend/crates/cli/src/main.rs
[cli-provenance]: https://github.com/koyori-app/vrt/blob/cf39c6d556c0482c76574a404410cf32b418c1bf/apps/backend/crates/cli/src/provenance.rs
[cli-turbosnap]: https://github.com/koyori-app/vrt/blob/cf39c6d556c0482c76574a404410cf32b418c1bf/apps/backend/crates/cli/src/turbosnap.rs
[cli-plan]: https://github.com/koyori-app/vrt/blob/cf39c6d556c0482c76574a404410cf32b418c1bf/apps/backend/crates/cli/src/plan.rs
[render]: https://github.com/koyori-app/vrt/blob/cf39c6d556c0482c76574a404410cf32b418c1bf/apps/backend/crates/job/src/render_build.rs
[arc-workflow]: https://github.com/koyori-app/arc/blob/master/.github/workflows/vrt.yml
[task-workflow]: https://github.com/koyori-app/task/blob/main/.github/workflows/vrt.yml
[dom-design]: https://github.com/koyori-app/vrt/pull/60
[dom-implementation]: https://github.com/koyori-app/vrt/pull/61
