---
name: agent-dashboard
description: 起動中の Claude Code セッションを一覧するダッシュボード(.claude/bin/agent-dashboard.sh)の仕様。ダッシュボードの表示を変えるとき、状態ファイルや hook の配線を直すとき、キャッシュの挙動を確かめるとき、Neovim のサイドバーで表示が崩れるときに使う。扱う範囲は 3 セクションの構成と 1 セッション 3 行の表示、グリフと色の使い分け、幅が足りないときに削る順序、agent-state.sh が書く状態ファイルの置き場、transcript の増分読みとキャッシュ。
---

# エージェント一覧ダッシュボード

起動中の Claude Code セッションを一覧する。Ghostty のタブを 1 枚使って常駐させる。
承認待ちで止まっているセッションが上に来る。Neovim では `<leader>ad`。

```bash
~/.claude/bin/agent-dashboard.sh          # 常駐(1秒ごとに再描画)
~/.claude/bin/agent-dashboard.sh --once   # 1回だけ描画
```

## 表示

**要対応 / 稼働中 / 待機** の 3 セクションに分け、1 セッションを最大 3 行で出す。

- 名前行: グリフ + リポジトリ名。状態によらず同じ明るさにする
- メタ行: 状態 / ブランチ / 経過 / セッション ID。状態の色が乗る
- 活動行: 使っているサブエージェントと `/スキル`(サブエージェント稼働中は色が変わる)。
  何も使っていなければ行ごと出さない

グリフは `◉` 要対応 / `●` 稼働中 / `○` 待機 で、色が出なくても状態が読める。

固定幅の列を持たないので、Ghostty の全幅でも nvim の 40 桁サイドバーでも折り返さない。
溢れたときは**セッション ID → ブランチ**の順に削る(状態と経過は残す)。24 桁まで縮む。

## データ源

上段の状態は `.claude/hooks/agent-state.sh` が hook から
`~/.claude/agent-state/<session_id>.json` に書く。`settings.json` の `SessionStart` /
`UserPromptSubmit` / `PermissionRequest` / `Notification` / `Stop` / `SessionEnd` に
割り当て済み。

下段はセッションの transcript(`~/.claude/projects/**/<session_id>.jsonl`)から `Agent` /
`Task` / `Skill` の tool_use を拾う。transcript は数 MB になるので、読んだ結果を
`~/.claude/cache/agent-dashboard.json` に持ち、次回は増えたバイトだけ読む。**このキャッシュ
は消しても支障ない**(次の描画で全部読み直す)。
