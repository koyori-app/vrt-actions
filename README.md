# VRT Actions

VRT Actions は、CI から [VRT](https://github.com/koyori-app/vrt) へ画像または Storybook を送るための GitHub Action です。
プロジェクト側の撮影方法を変えずに `uses:` 一行で VRT のビルドを作成し、アップロード、finalize、結果待ちまでを実行します。

この action は composite action として実装されており、ランナー上の `curl` / `jq` / `git` / `tar` だけで動作します。
`screenshots` モードは VRT の CI REST API を直接呼び出し、`storybook` モードは `koyori-app/vrt` の Release から取得した `vrt` CLI に委譲します。

## モード

`mode` で、誰がスクリーンショットを撮るかを選びます。

| `mode` | 誰が撮るか | action が送るもの | 上限 |
| --- | --- | --- | --- |
| `screenshots` | 利用者の CI | `dir` 以下の PNG を一枚ずつ | 一枚 25 MB |
| `storybook` | VRT サーバーの Chromium | ビルド済み Storybook の zip を一本 | zip 200 MB |

どちらのモードも、アップロード後は同じ比較、レビュー、baseline 昇格の経路を通ります。

`screenshots` は、Playwright などが CI 内で撮った PNG をそのまま送るモードです。
action 自身はブラウザーを起動せず、PNG の生成も行いません。

`storybook` は、`storybook-static` を zip にまとめて送り、VRT サーバーに撮影を任せるモードです。
Storybook の直下には `index.json` が必要です。

## 最小構成

最小構成は次のとおりです（`v1` タグの公開後に `@v1` で参照できます）。

```yaml
- uses: koyori-app/vrt-actions@v1
  with:
    token: ${{ secrets.VRT_TOKEN }}
    project: acme/design-system
    url: https://vrt.example.com
    mode: storybook
```

## Inputs

| input | 必須 | 既定値 | 説明 |
| --- | --- | --- | --- |
| `token` | はい | なし | VRT の Personal Access Token。ログには出しません。 |
| `project` | はい | なし | `tenant-slug/project-slug` 形式の対象プロジェクトです。 |
| `url` | はい | なし | VRT のベース URL です。末尾の `/` はあってもなくても構いません。 |
| `mode` | いいえ | `screenshots` | `screenshots` または `storybook` を指定します。 |
| `dir` | いいえ | モード別 | `screenshots` では `./screenshots`、`storybook` では `./storybook-static` を使います。 |
| `only-changed` | いいえ | `false` | `storybook` 専用です。`true` のとき、変更の影響を受けるストーリーだけをサーバーで撮影します。 |
| `stats-json` | いいえ | `<dir>/preview-stats.json` | `only-changed: true` で使う webpack stats JSON のパスです。 |
| `wait` | いいえ | `true` | 結果が出るまで待ち、VRT の結果を action の終了コードへ反映します。 |
| `branch` | いいえ | `GITHUB_HEAD_REF` または `GITHUB_REF_NAME` | baseline を解決するブランチ名です。 |
| `commit` | いいえ | PR の head SHA、なければ `GITHUB_SHA` | 対象コミットの SHA です。 |
| `cli-version` | いいえ | `latest` | `storybook` モードで使う `vrt` CLI のリリースタグ（例 `cli-v0.1.0`）です。`latest` のときは最新の `cli-v*` タグを解決します。 |
| `app-url` | いいえ | `url` から末尾の `/api` を除いた値 | `build-url` の組み立てに使う Web UI のベース URL です。 |
| `github-token` | いいえ | `${{ github.token }}` | `cli-version: latest` の解決で `koyori-app/vrt` の Release 一覧を取得する際に使う GitHub トークンです。未認証だと GitHub API のレート制限（60 回/時/IP）に当たりやすいため既定でワークフロートークンを使います。フォークからの PR などで空になっても未認証で解決を試みます。 |

`commit` の既定値は、`pull_request` イベントでは `github.event.pull_request.head.sha`、それ以外では `GITHUB_SHA` です。
`pull_request` イベントの `GITHUB_SHA` は GitHub 上に永続しないマージコミットを指すため、コミットステータスを貼れる PR ブランチ上の head SHA を優先します。

`mode` とモード別の `dir` 既定値は action の入力契約です。
`vrt upload` CLI は Storybook 専用であり、`--mode` フラグはありません。
action は `screenshots` を CI REST API、`storybook` を `vrt upload` に振り分けます。

`only-changed` は `storybook` でのみ有効です。
`screenshots` と組み合わせた場合や、未知の `mode` を指定した場合は、黙って無視せず入力エラーにします。

## Outputs

| output | 説明 |
| --- | --- |
| `build-id` | 作成された VRT ビルドの UUID です。 |
| `build-url` | VRT のレビュー画面を開く URL です。 |
| `result` | `wait: true` では最終結果、`wait: false` では finalize 直後の状態です。 |
| `exit-code` | VRT CLI と同じ結果コードです。`passed` / `approved` は `0`、`changes_detected` は `1`、`failed` / `rejected` / 想定外の状態は `2` です。 |

`wait: false` の action 自体は、ビルド作成、アップロード、finalize が受理されれば成功として終了します。
この場合の `result` は `pending`、`rendering`、`processing` などの途中状態になり得るため、比較結果として扱わないでください。

`build-url` は `{app-url}/t/{tenant}/p/{project}/builds/{number}` の形で組み立てます。
`app-url` を省略した場合は `url` から末尾の `/api` を除いた値を使います。
リバースプロキシ構成で API のベースが `https://example.com/api`、Web UI のベースが `https://example.com` になる場合に対応するためです。

`build-url` を含む outputs は、終了コードにかかわらず（差分検出や失敗時も）書き出します。
`continue-on-error: true` と組み合わせて、後続 step から `build-url` を参照できます。

## PAT の権限

PAT は VRT の **Settings → Personal access tokens** で発行します。

- `write:build` は必須です。
  ビルド作成、PNG または Storybook のアップロード、finalize に使います。
- `read:build` は `wait: true` のときに必須です。
  ビルド状態と進捗ログの取得に使います。

トークンは GitHub Actions の Secret に保存し、workflow やリポジトリへ直接書かないでください。

```yaml
token: ${{ secrets.VRT_TOKEN }}
```

## screenshots モード

次の例は、Playwright が `screenshots/` に生成した PNG を一枚ずつ送ります。
撮影コマンドと出力先は、利用するプロジェクトの設定に合わせてください。

```yaml
name: Visual regression testing

on:
  pull_request:

jobs:
  vrt:
    runs-on: ubuntu-latest
    permissions:
      contents: read

    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v4
        with:
          node-version: 22
          cache: npm

      - run: npm ci
      - name: Capture screenshots
        run: npm run test:visual

      - name: Upload screenshots to VRT
        id: vrt
        uses: koyori-app/vrt-actions@v1
        with:
          token: ${{ secrets.VRT_TOKEN }}
          project: acme/web
          url: https://vrt.example.com
          mode: screenshots
          dir: ./screenshots
          wait: true
```

action は `dir` 以下の `.png` ファイルだけを対象にします。
各 PNG の相対パスをスクリーンショット名として使う設計にし、同名による意図しない上書きを避けます。
PNG 以外のファイル、25 MB を超える PNG、空のディレクトリはアップロード前にエラーにします。

## storybook モード

`only-changed: true` を使う場合は、Storybook ビルド時に stats JSON を生成し、checkout の履歴を baseline まで取得してください。

```yaml
name: Storybook visual regression testing

on:
  pull_request:

jobs:
  vrt:
    runs-on: ubuntu-latest
    permissions:
      contents: read

    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - uses: actions/setup-node@v4
        with:
          node-version: 22
          cache: npm

      - run: npm ci
      - name: Build Storybook with webpack stats
        run: npm run build-storybook -- --stats-json

      - name: Upload Storybook to VRT
        id: vrt
        uses: koyori-app/vrt-actions@v1
        with:
          token: ${{ secrets.VRT_TOKEN }}
          project: acme/design-system
          url: https://vrt.example.com
          mode: storybook
          dir: ./storybook-static
          only-changed: true
          stats-json: ./storybook-static/preview-stats.json
          wait: true
```

`storybook` モードは `vrt` CLI に委譲するため、`--json` 出力に対応した `cli-v0.1.0` 以降の CLI が必要です。
CLI は `koyori-app/vrt` の Release からランナーの OS / アーキテクチャに合わせてダウンロードし、`.sha256` で必ずチェックサムを検証します。
使用するタグは `cli-version` で固定できます（既定は最新の `cli-v*`）。

`only-changed` は、変更ファイル、webpack stats、Storybook の `index.json` から影響を受けるストーリーを求めます。
stats JSON がない、baseline がない、git 履歴が baseline に届かない、または変更が依存グラフ外にある場合は、撮影漏れを避けるため全ストーリー撮影へフォールバックします。
CI では `fetch-depth: 0` を指定してください。

## 高速化の境界

VRT の高速化には、異なる三つの段階があります。

1. **撮らない**
   `storybook` と `only-changed` を使い、サーバー側で影響ストーリーだけを撮影します。
2. **送らない**
   現在の `screenshots` API は PNG を一枚ずつ受け取り、Storybook API は zip を一本受け取ります。
   差分アップロードやキャッシュ再利用を action の既存機能としては扱いません。
3. **比較しない**
   `only-changed` で撮影対象外になったストーリーは baseline を流用するため、不要な比較も減ります。

将来、manifest、キャッシュ、並列アップロードなどを追加するときは、これらを別の入力として設計します。
既存 input の意味を変えて最適化を隠すことはしません。

## 終了コード

`wait: true` では、レビューが必要な差分を通常のエラーと区別します。

| VRT の状態 | 終了コード | 意味 |
| --- | ---: | --- |
| `passed`, `approved` | `0` | 差分なし、または承認済み |
| `changes_detected` | `1` | 差分があり、人間のレビューが必要 |
| `failed`, `rejected`, 想定外 | `2` | 比較失敗、却下、または処理不能 |

`changes_detected` で workflow を失敗させたくない場合は、呼び出し側の step に `continue-on-error: true` を指定し、`result` と `build-url` を後続 step で参照してください。

