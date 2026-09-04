# dotfiles

Neovim ([LazyVim](https://github.com/LazyVim/LazyVim)) と Claude Code の個人設定。
`~/.config/nvim` と `~/.claude` 配下から、このリポジトリへ symlink を張って使う。

```text
init.lua / lua/ / lazy-lock.json / lazyvim.json   Neovim
.claude/settings.json                            Claude Code 本体の設定
.claude/skills/                                  スキル
.claude/agents/                                  サブエージェント定義
.claude/hooks/                                   hook スクリプト
.claude/bin/                                     エージェント一覧ダッシュボード
.claude/statusline.sh                            ステータスライン
```

## セットアップ

```bash
git clone <this-repo> ~/Work/dotfiles
cd ~/Work/dotfiles

# .claude/settings.json 用の filter（先に設定する。詳細は下の注記）
git config filter.strip-automode.clean "jq 'del(.autoMode)'"
git config filter.strip-automode.smudge cat
git config filter.strip-automode.required true

# Neovim
ln -sfn ~/Work/dotfiles ~/.config/nvim

# Claude Code
ln -sfn ~/Work/dotfiles/.claude/settings.json ~/.claude/settings.json
ln -sfn ~/Work/dotfiles/.claude/statusline.sh ~/.claude/statusline.sh
ln -sfn ~/Work/dotfiles/.claude/skills        ~/.claude/skills
ln -sfn ~/Work/dotfiles/.claude/agents        ~/.claude/agents
ln -sfn ~/Work/dotfiles/.claude/hooks         ~/.claude/hooks
ln -sfn ~/Work/dotfiles/.claude/bin           ~/.claude/bin
```

グリフ(`  🐍 ◉`)を出すのに Nerd Font が要る。ターミナルは Ghostty 前提。

`~/.claude/settings.json` はこのリポジトリへの symlink なので、Claude Code の
auto mode が集めた環境情報(`autoMode`)がそのまま public なここに書き込まれる。
内部システム名や本番 env のパスを載せられないため、`.gitattributes` の filter で
**コミット時にだけ `autoMode` を落とす**。手元のファイルには残るので auto mode は
そのまま動く。`jq` が要る。

filter の実体は git config なのでリポジトリには持ち込めず、**設定を忘れても git は
何も言わずに素通しする**(`required = true` は filter が定義済みで失敗したときに
効くもので、未定義には効かない)。clone したら真っ先に設定し、効いていることを
確かめる。

```bash
git config --get filter.strip-automode.clean   # jq 'del(.autoMode)' が出れば設定済み

# 実際に落ちるかの確認。false が出れば効いている
git add .claude/settings.json && git show :.claude/settings.json | jq 'has("autoMode")'
```

`gh skill` で入れた外部スキルは追跡していないので、新しいマシンでは入れ直す
(導入済みの一覧は [CLAUDE.md](CLAUDE.md#外部スキル-gh-skill))。

## Neovim

LazyVim のスターターに、Claude Code と Python(uv)まわりを足したもの。

| キー | 動作 |
| --- | --- |
| `<leader>ac` / `<leader>as` | Claude Code を開閉 / 選択範囲を送る |
| `<leader>ad` | エージェント一覧をサイドバーで開閉 |
| `<leader>tt` `<leader>tf` `<leader>tv` | ターミナル(横 / フロート / 縦) |
| `<leader>cu` / `<leader>cU` | ruff format + check (+ ty) をプロジェクト / 現在のファイルへ |
| `<leader>cx` | 現在のファイルを `uv run python` で実行 |
| `<leader>g*` | fugitive による git 操作。`<leader>gc` はコミットメッセージを Claude が書く |
| `<leader>mm` `<leader>mp` `<leader>mt` | markdown を Ghostty 上で描画 |

`:Docker` / `:Aws` / `:Cdk` は、その CLI をターミナルで走らせるコマンド。

## Claude Code

- **スキル** — DDD / クリーンアーキテクチャ / FSD / Web API / テストの設計指針を、
  自動起動する単位に切ったもの。書き方は `skill-authoring`、点検は `skill-review`。
- **サブエージェント** — 研修課題(ポーカー役判定 Web アプリ)のレビュー用 4 本。
- **エージェント一覧** — 起動中のセッションを一覧する常駐ダッシュボード。
  承認待ちのセッションが上に来る。

  ```bash
  ~/.claude/bin/agent-dashboard.sh          # 常駐
  ~/.claude/bin/agent-dashboard.sh --once   # 1 回だけ描画
  ```

- **ステータスライン** — `dir  branch  python` を Powerline 風に出す。
  Neovim の `:terminal` の中では、`$NVIM` 経由で nvim の cwd に追従する。
- **hook** — `SKILL.md` を編集しようとすると `skill-guard.sh` が上のスキルを案内し、
  `agent-state.sh` がセッションの状態をダッシュボード用に書き出す。

各パーツの詳しい作りは [CLAUDE.md](CLAUDE.md) にある。
