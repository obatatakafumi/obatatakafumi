# claude-lane v3 — 2つのサブスクを1台のMacで並走させる（アカウント割当て込み）

新Mac移行手順書の **Phase 7〜10**（`claude_lane.sh` v3 の配置 → レーンB作成 → VS Code 第2インスタンス → 受入テスト）をそのまま実行できる形にしたキットです。

手順書の v3 に、次の1点を加えています。

- **各レーンがどのアカウントでログインすべきかを固定する**。取り違えは `setup` と `verify` が exit 1 で止めます。

## アカウント割当て

| レーン | 開き方 | ログインするアカウント | Keychain |
|---|---|---|---|
| **A** | 通常の VS Code（Dock・Spotlight から起動）／ 素の `claude` | `--lane-a` で指定 | `Claude Code-credentials` |
| **B** | ターミナルから `code-b`（= `code-team`）／ `ccb` | `--lane-b` で指定 | `Claude Code-credentials-<hash>` |

割当ては `~/.claude/scripts/claude_lane.conf`（パーミッション 600）に保存され、このリポジトリには入りません。このリポジトリは public なので、メールアドレスはコミットしていません。

> ターミナルから**素の `code .`** を叩くと開くのは**レーンA**（通常の VS Code）です。レーンBになるのは `code-b` / `code-team` だけです。見分け方は、ウィンドウが青くタイトルに `[MAX-B]` が付くかどうかです。

## 手順（新Macで実行）

**前提**: 手順書の Phase 0〜6 が済んでいること。具体的には `~/.claude` が配置済み、`jq`・`claude` CLI・VS Code の `code` コマンドが使える、**レーンAがアカウントA（既存 VS Code 用）でログイン済み**、の3点です。

```bash
jq -r .oauthAccount.emailAddress ~/.claude.json    # アカウントA のメールが出ること
```

### 1. キットを取得して、Mac 上でテストを回す（何も書き換えません）

```bash
git clone --depth 1 -b claude/lane-setup-sync-ph5qry https://github.com/obatatakafumi/obatatakafumi /tmp/claude-lane-kit
/bin/bash /tmp/claude-lane-kit/claude-lane/tests/run.sh      # 最終行が passed=N failed=0 であること
```

テストは使い捨ての偽 HOME・偽 Keychain・偽 `code`/`claude` を使うため、本物の設定には触れません。**macOS 同梱の bash 3.2 での実行はまだ誰もしていない**ので、ここで失敗したら先に進まずに出力を見せてください。

### 2. インストールとアカウント割当て

```bash
bash /tmp/claude-lane-kit/claude-lane/install.sh --lane-a <アカウントAのメール> --lane-b <アカウントBのメール>
```

このコマンドは次を行います。

- `~/.claude/scripts/` に `claude_lane.sh` と `claude_lane.zsh` を置く
- 割当てを書く
- `~/.zshrc` に source 行を1回だけ足す
- 構文検査をする

置き換える既存ファイルは `~/.claude-lane-backups/<日時>/` に退避されます。`~/.claude` が無い場合は、作らずに止まります（`~/.claude` を先に作ってしまうと、後の `git clone` が失敗するため）。

### 3. レーンBを作ってアカウントBでログイン（手順書 Phase 8）

```bash
bash ~/.claude/scripts/claude_lane.sh setup     # レーンAがアカウントAでなければ、ここで止まる
bash ~/.claude/scripts/claude_lane.sh sync
env -u CLAUDECODE CLAUDE_CONFIG_DIR="$HOME/.claude-b" claude     # ここでアカウントBでサインイン
```

> :no_entry: ブラウザが claude.ai にアカウントAでログインしたままだと、OAuth がアカウントAのまま通ってしまいます。**CLI が表示するURLをプライベートウィンドウに貼って**アカウントBでサインインしてください。取り違えは手順5の `verify` が `FAIL: lane B must be signed into ...` として検出します。

### 4. VS Code 第2インスタンス（手順書 Phase 9）

```bash
bash ~/.claude/scripts/claude_lane.sh vscode    # 新しいターミナルからなら code-b でも同じ
```

青いタイトルバーに `[MAX-B]` が付いたウィンドウが開きます。このウィンドウの Claude 拡張と統合ターミナルはレーンB（アカウントB）で動きます。通常の VS Code は今までどおりレーンA（アカウントA）です。

### 5. 受入テスト（手順書 Phase 10）

```bash
bash ~/.claude/scripts/claude_lane.sh verify; echo "EXIT=$?"
```

`EXIT=0` なら合格です。判定は exit code だけで行ってください。出力の `lane A :` 行にアカウントA、`lane B :` 行にアカウントBが出ます。

## 手順書の v3 からの変更点

| 変更 | 理由 |
|---|---|
| アカウント割当て（`claude_lane.conf`）。`setup` はレーンAの取り違えを**レーンB作成前に**止める。`verify` は各レーンの割当てと入れ替わり（SWAPPED）を検査する | 「両レーンが別アカウント」という検査は、正しい2アカウントが**逆のレーン**に入った状態でも全部通ってしまうため |
| `verify`: シェルに `CLAUDE_CODE_OAUTH_TOKEN` があれば FAIL、`ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN` があれば NOTE | 環境変数のトークンは全レーンの Keychain より優先されるため、両レーンが1アカウントになる。しかも `.claude.json` には現れない |
| `verify`: フック検査を `settings.json` と `settings.local.json` の**合算**に変更し、各フックが呼ぶスクリプトの実在も確認する | 手順書は「フックは `settings.local.json` にしかない」前提だったが、旧Macの実際の配線は `settings.json` 側（`~/claude-code-config/hooks/` を呼ぶ）だった。新Macで誤って FAIL が出たため修正。スクリプトが無いフックは失敗しても処理を止めないので、安全装置が黙って止まる |
| `setup`: `primaryApiKey` もレーンBへコピーしない | レーンAの支払い手段をレーンBに引き継がせないため |
| リンク除外に `.credentials.json` と `.git` を追加 | 前者は資格情報。後者を共有すると `~/.claude-b` がレーンAのリポジトリに見えてしまう |
| `setup`: レーンB用の古い Keychain 資格情報が残っていれば、消すコマンドを添えて警告する | 手順書にある「作り直したのにログイン画面が出ない」罠を実行時に知らせるため |
| `vscode`: 環境変数の抽出を `grep -E` に変更。引数は `${1+"$@"}` で渡す | BRE の `\|` は GNU 拡張なので、BSD grep では剥がしが空振りする恐れがある。引数なしの `"$@"` は `set -u` 下で古い bash が落ちる恐れがある |
| スクリプト冒頭（変数・`identity_file`・`field`・`keychain_*` など）を再構成 | 貼り付けられた手順書では、`claude_lane.sh` の前半と Phase 0〜7 が欠けていたため |
| `install.sh` を追加 | 長いヒアドキュメントを貼る方式は途中で切れやすいため |

## 検証状況

| 検査 | 結果 |
|---|---|
| `tests/run.sh`（Linux, bash 5.2.21 / zsh 5.9, 偽 Keychain・偽 VS Code・偽 claude） | **118/118 通過** |
| Keychain 名の導出を元Macの実測値（`~/.claude-team` → `ac37998e`）と突き合わせ | 一致 |
| shellcheck（`claude_lane.sh` / `install.sh`, warning 以上） | 指摘なし |
| macOS 実機・`/bin/bash` 3.2・本物の Keychain / VS Code / ログイン | **未実施**（作業環境が Linux で、bash 3.2 の入手もネットワーク制限で不可だった） |

## レーン間で共有されるもの・されないもの

| 項目 | レーンA と B で | 補足 |
|---|---|---|
| Claude のアカウント・組織 | 別 | それぞれの Keychain 項目に入っているログイン情報で決まる |
| Claude のログイン情報（Keychain 項目 `Claude Code-credentials*`） | 別 | 共有すると両レーンが同じアカウントになるため、共有できない |
| MCP サーバーへのログイン（freee・limitless・miro など） | 別（レーンBで未認証の表示を確認） | レーンBでは未認証から始まる。レーンBで使うなら、`ccb` で `/mcp` から一度認証する |
| Keychain に入れたその他の秘密情報（API キーなど） | 共通 | 同じ macOS ユーザーのログインキーチェーンを両レーンが使う |
| 設定・CLAUDE.md・rules・skills・agents・hooks・plugins・会話履歴 | 共通 | `~/.claude-b` 内の symlink が `~/.claude` を指す |
| MCP サーバーの定義 | 共通（`sync` で A→B に複製） | レーンAで登録し、`claude_lane.sh sync` で降ろす |

## 触っていないもの

- 手順書の Phase 0〜6（貼り付けに含まれていなかった）
- `llm_client.py` の `_alt_lane_dir()`（`~/.claude-team` をハードコードしている件。手順書の付録B-5）
- `~/.claude` が git 管理下の場合の、`scripts/claude_lane.sh` のコミット（`install.sh` が差分の有無を知らせます）
