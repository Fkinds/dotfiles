# dotfiles

Neovim (LazyVim) と Claude Code の個人設定リポジトリ。

`~/.config/nvim` と、`~/.claude` 配下の `settings.json` / `statusline.sh` /
`skills` / `agents` / `hooks` / `bin` は、このリポジトリへの symlink。新しい
マシンでは張り直す(手順は [README.md](README.md#セットアップ))。

```bash
ln -sfn ~/Work/dotfiles/.claude/bin ~/.claude/bin
```

## エージェント一覧 (`.claude/bin/agent-dashboard.sh`)

起動中の Claude Code セッションを一覧するダッシュボード。Neovim では `<leader>ad`。
表示仕様・状態ファイル・キャッシュは `agent-dashboard` スキルにある。

**状態の置き場を `~/.claude/agent-state/` から `~/.claude/agents/` に移さないこと。**
後者はサブエージェント定義のディレクトリで、別物。

## スキル (`.claude/skills/`)

- `SKILL.md` を新規作成・編集するときは `skill-authoring` に従う。
- 作成・編集のあとは `skill-review` で点検する。
- スキルを分けるか迷ったら `skill-scoping`。

`SKILL.md` に触れると `.claude/hooks/skill-guard.sh`(PreToolUse hook)が自動で
この注意を出す。`~/.claude/hooks` 経由で読まれるので**全プロジェクトで効く**。
無効にするなら `settings.json` の `hooks.PreToolUse` を消す。

### 外部スキル (`gh skill`)

公式配布のスキルは自作せず `gh skill` で入れる。**git では追跡しない**
(`.gitignore` 済み)。frontmatter の `metadata.github-repo` が目印。

```bash
gh skill install github/gh-stack gh-stack --agent claude-code --scope user
gh skill list      # 導入済み一覧
gh skill update    # 更新
```

第 2 引数は**リポジトリ内のディレクトリ名**。frontmatter の `name` とは違うことが
あり(`vercel-composition-patterns` に対しディレクトリは `composition-patterns`)、
`name` を渡すと not found になる。

導入済み:

- `gh-stack`(要 `gh extension install github/gh-stack`)
- `composition-patterns` / `react-best-practices` / `web-design-guidelines`
  (`vercel-labs/agent-skills`)。React の合成パターン、パフォーマンス、
  アクセシビリティ。FSD のレイヤー設計は自作の `fsd-*` が持つ。

**自作スキルは、外部スキルが持たない運用ルールだけを持つ。** コマンドの使い方を
書き写すと、本体の更新に追従できなくなる。

### 置き場所・検査・提出

`skill-authoring` / `agent-authoring` は、これらをリポジトリの CLAUDE.md に委ねている。
このリポジトリでは次のとおり。

- 置き場所: `.claude/skills/<skill-name>/SKILL.md`、サブエージェントは `.claude/agents/<name>.md`。
  どちらも symlink 経由で全プロジェクトに効く。
- 静的検査: pre-commit は無い。frontmatter が YAML として読めることと行数を手元で確かめる。
- 提出: `main` へ直接コミットする。

```bash
python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]).read().split("---")[1])' <SKILL.md>
```

**他リポジトリのプロジェクトスキルを、ここへ上書きコピーしない。** 社内のモジュール名や
規約がそのまま public に出るうえ、全プロジェクトのスキルがそのリポジトリ前提になる。
取り込むなら固有の部分を外してから。

## サブエージェント (`.claude/agents/`)

- 定義を新規作成・編集するときは `agent-authoring` に従う。
- 作成・編集のあとは `agent-review` で点検する。
- スキルにするかサブエージェントにするかで迷ったら `agent-authoring` の冒頭。

`~/.claude/agents` はここへの symlink なので、**置いた定義は全プロジェクトで効く**。
プロジェクト固有の前提を持つ定義をここに置かない。

上の「エージェント一覧」の `~/.claude/agent-state/` とは別物。あちらは
ダッシュボードが読む状態ファイルの置き場。

## MCP サーバー (`.claude/bin/setup-mcp.sh`)

MCP の設定は `~/.claude.json`(管理外)に入るので、登録は `setup-mcp.sh` に並べて
流す。サーバーを足すときもこのスクリプトに書き、`claude mcp add` を手で打たない。

**トークンを書かない。** 認証は `headersHelper` で実行時に取る(GitHub は
`gh auth token`)。AWS のプロファイル名も社内名なので、`AWS_MCP_PROFILE` で
実行時に渡す。

`aws-api` は全プロジェクトから呼べるので、**dev のプロファイル + `READ_OPERATIONS_ONLY`
に固定する。** 本番のプロファイルを渡さず、読み取り専用も外さない。

## `.claude/settings.json` と auto mode

`~/.claude/settings.json` はここへの symlink なので、auto mode が集めた環境情報
(`autoMode`)がこのリポジトリに書き込まれる。中身は内部システム名・CI シークレット
名・本番 env のパスで、**このリポジトリは public**。`.gitattributes` の filter が
コミット時にだけ `autoMode` を落とす(設定手順は [README.md](README.md#セットアップ))。

作業ツリーには残るので、`autoMode` だけが変わったときに `git status` が clean の
ままなのは正常。**手で消したり、filter を外して commit したりしない。**

filter が未設定の環境では git は黙って素通しする。`.claude/settings.json` を
コミットするときは、index に入っていないことを確かめる。

```bash
git show :.claude/settings.json | jq 'has("autoMode")'   # false なら安全
```

## コミット

Conventional Commits を日本語で書く。スコープはサブシステム名。

```text
feat(claude): DDD の層ごとのテスト戦略 skill を追加
docs(claude): 既存 DDD skill の相互リンクを新規 skill へ接続
feat(nvim): markdown を Ghostty 上で描画する md-render.nvim を導入
chore: lazy-lock.json を更新
```
