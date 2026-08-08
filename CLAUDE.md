# dotfiles

Neovim (LazyVim) と Claude Code の個人設定リポジトリ。

- Neovim: `init.lua` / `lua/` / `lazy-lock.json` / `lazyvim.json`
- Claude Code: `.claude/settings.json` / `.claude/skills/` / `.claude/agents/` /
  `.claude/hooks/` / `.claude/bin/`

`~/.claude` 配下の `settings.json` / `statusline.sh` / `hooks` / `bin` は、この
リポジトリへの symlink。新しいマシンでは張り直す。

```bash
ln -sfn ~/Work/dotfiles/.claude/bin ~/.claude/bin
```

## エージェント一覧 (`.claude/bin/agent-dashboard.sh`)

起動中の Claude Code セッションを一覧するダッシュボード。Ghostty のタブを 1 枚使って
常駐させる。承認待ちで止まっているセッションが上に来る。Neovim では `<leader>ad`。

1 セッションを 2 段で出す。

- 上段: 状態 / リポジトリ / ブランチ / 経過 / セッション ID
- 下段: 使っているサブエージェントとスキル(サブエージェント稼働中は行ごと色が変わる)

```bash
~/.claude/bin/agent-dashboard.sh          # 常駐(1秒ごとに再描画)
~/.claude/bin/agent-dashboard.sh --once   # 1回だけ描画
```

上段の状態は `.claude/hooks/agent-state.sh` が hook から
`~/.claude/agent-state/<session_id>.json` に書く。`settings.json` の `SessionStart` /
`UserPromptSubmit` / `PermissionRequest` / `Notification` / `Stop` / `SessionEnd` に
割り当て済み。

下段はセッションの transcript(`~/.claude/projects/**/<session_id>.jsonl`)から `Agent` /
`Task` / `Skill` の tool_use を拾う。transcript は数 MB になるので、読んだ結果を
`~/.claude/cache/agent-dashboard.json` に持ち、次回は増えたバイトだけ読む。**このキャッシュ
は消しても支障ない**(次の描画で全部読み直す)。

**状態の置き場を `~/.claude/agents/` にしないこと。** そこはサブエージェント定義の
ディレクトリで、別物。

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

導入済み: `gh-stack`(要 `gh extension install github/gh-stack`)。

**自作スキルは、外部スキルが持たない運用ルールだけを持つ。** コマンドの使い方を
書き写すと、本体の更新に追従できなくなる。

### `skill-authoring` の前提のうち、このリポジトリに当てはまらないもの

`skill-authoring` は社内スキル集リポジトリ向けに書かれている。次の 3 点は読み替える。

| skill-authoring の記述 | このリポジトリでは |
| --- | --- |
| ステップ1: リポジトリ直下に `<skill-name>/SKILL.md` を置く | `.claude/skills/<skill-name>/SKILL.md` に置く |
| ステップ5: pre-commit (`markdownlint-cli2` + `validate_skills.py`) を通す | どちらも存在しない。手元で YAML と行数を確認する |
| ステップ6: feature ブランチ + PR、`main` への直接 push は禁止 | `main` へ直接コミットする |

## コミット

Conventional Commits を日本語で書く。スコープはサブシステム名。

```text
feat(claude): DDD の層ごとのテスト戦略 skill を追加
docs(claude): 既存 DDD skill の相互リンクを新規 skill へ接続
feat(nvim): markdown を Ghostty 上で描画する md-render.nvim を導入
chore: lazy-lock.json を更新
```
