---
name: asana-tasks
description: Claude Code から Asana のタスクを、許可された 1 つのプロジェクトの中だけで作成・参照・更新する。Asana にタスクを作る・起票する・チケットを切る、Asana のタスクを探す・見る・更新する・コメントする、と頼まれたときに使う。範囲外の呼び出しを止めるフック(asana-scope-guard)に deny されたとき、Asana がつながらないとき、接続や設定をやり直すときにも使う。
---

# asana-tasks

claude.ai の Asana コネクタ(`mcp__claude_ai_Asana__*`)で、許可された 1 つのプロジェクト(以下、対象プロジェクト)のタスクだけを扱う。

## 範囲

- 見てよい・書いてよいのは対象プロジェクトだけ。ワークスペース全体の検索、他のプロジェクトのタスク、ユーザーやチームの一覧は見ない
- フック `~/.claude/hooks/asana-scope-guard.py` が範囲外の呼び出しを止める。deny されたら理由の文面に従って呼び方を直す。フックを外す・設定を書き換える・別の経路で取りに行く、はしない
- 範囲外が必要そうなら、呼ぶ前にユーザーに聞く

## 準備

1. `~/.claude/asana-scope.json` を読み、対象プロジェクトの GID(`project_gid`)と名前(`project_name`)を知る。以下の「GID」はこの値
2. Asana のツールは名前だけ渡されている。使う分を ToolSearch の `select:` で読み込む
   (例: `select:mcp__claude_ai_Asana__create_tasks,mcp__claude_ai_Asana__get_project`)
3. 設定ファイルが無い、ツールが見つからない、`Not Authorized` が返る、などのときは「トラブル対応」を見る

## 使えるツール

| ツール                                                                                      | 条件                                                                                       |
| ------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| `get_me`                                                                                    | なし                                                                                       |
| `get_project`                                                                               | `project_id` = GID。セクション一覧は `include_sections: true`                              |
| `get_tasks`                                                                                 | `project` = GID。`section` / `tag` / `assignee` / `user_task_list` は不可                  |
| `search_tasks`                                                                              | `projects_any` = GID(1つだけ)。他の絞り込みは自由                                         |
| `create_tasks`                                                                              | 全タスクの `project_id` か `default_project` が GID。`parent` は確認済みタスクだけ         |
| `create_task_from_template`                                                                 | `project_id` = GID                                                                         |
| `get_task`                                                                                  | `opt_fields` を指定するなら `projects` を含める。結果に GID が無ければ結果が隠される       |
| `add_comment` / `update_tasks` / `delete_task` / `get_task_stories` / `get_attachments` | 確認済みタスクだけ。`update_tasks` の `add_projects` は GID だけ、`remove_projects` は不可 |

これ以外(`search_objects`、`get_projects`、`get_my_tasks`、`get_users`、`get_teams`、`get_portfolios`、
`update_project`、`create_project` など)はフックが止める。

確認済みタスクとは、`get_task` で開いて結果に GID が出たタスクのこと。記録は
`~/.claude/state/asana-scope-guard.json` に残り、セッションをまたいで使える。

## タスクを作る

1. 中身を決める: タイトル、本文、担当者、期限、セクション
   - ユーザーが中身を指定していれば、そのまま使う。Claude が文面を起こした場合は、チームから見えるので作る前に提示して承認を取る
   - セクションに入れるなら `get_project`(`include_sections: true`)で `section_id` を調べる
   - 担当者は `"me"` かメールアドレスで指定する(`get_users` は使えない)
2. `create_tasks` を `default_project` = GID で呼ぶ。複数件は `tasks` に並べて 1 回で作る
3. 作ったタスクの名前と URL をユーザーに返す

## タスクを探す・見る

- 一覧: `get_tasks`(`project` = GID)。未完了だけなら `completed_since: "now"`
- 条件で探す: `search_tasks`(`projects_any` = GID に `text` / `assignee_any` / `due_on_before` などを足す)
- 1 件の詳細: `get_task`

## 既存のタスクを更新する・コメントする・削除する

1. 対象を `get_task` で開き、確認済みにする。URL を渡されたら `/task/<数字>` の数字がタスク GID
   (旧形式 `/0/<プロジェクト>/<タスク>` なら末尾の数字)
2. `update_tasks` / `add_comment` / `delete_task` を呼ぶ。削除と、担当者・期限の変更は、ユーザーの指示があるときだけ行う
3. 何を変えたかをユーザーに返す

## deny されたとき

理由の文面の「〇〇」には `project_name` が入る。

| 理由の文面                                          | 直し方                                                                      |
| --------------------------------------------------- | --------------------------------------------------------------------------- |
| 〜 に 〇〇 (GID) 以外が指定されています             | `project` / `projects_any` / `project_id` / `default_project` を GID にする |
| 〜 は 〇〇 のタスクと確認できていません             | `get_task` で開いてからやり直す                                             |
| get_tasks では 〜 を使えません                      | `search_tasks` に `projects_any` = GID を付けて絞る                        |
| opt_fields を指定するときは projects を含めてください | `opt_fields` に `projects` を足す                                           |
| 〜 は 〇〇 以外も扱うツールなので使えません         | 使わない。必要ならユーザーに聞く                                            |
| 〜 asana-scope.json に project_gid が設定されていません | 「対象プロジェクトを設定する」をユーザーに案内する                          |

## 接続と設定

### 構成

| もの                   | 場所                                                                         |
| ---------------------- | ---------------------------------------------------------------------------- |
| 接続経路               | claude.ai の Asana コネクタ。Claude Code には `claude.ai Asana` として届く    |
| 範囲を絞るフック       | `~/.claude/hooks/asana-scope-guard.py`(実体は dotfiles の `.claude/hooks/`)  |
| フックの登録           | `~/.claude/settings.json`(実体は dotfiles)の `PreToolUse` / `PostToolUse`   |
| 対象プロジェクト       | `~/.claude/asana-scope.json`(dotfiles の外。公開リポジトリに載せない)        |
| 確認済みタスクの記録   | `~/.claude/state/asana-scope-guard.json`                                     |
| フックの判定のテスト   | このスキルの `scripts/test_scope_guard.py`                                   |

Asana 側では範囲をプロジェクト単位に絞れない。コネクタはユーザー本人の権限で動き、認可したワークスペース全体が見える。
そのため Claude Code 側のフックで引数と結果を検査している。

Asana 側で MCP app を作り `claude mcp add` で `https://mcp.asana.com/v2/mcp` を直接追加する方法もある。
コネクタが組織で使えないときの代替。フックの matcher はその場合のツール名(`mcp__asana__*`)も拾う。

### 1. コネクタをつなぐ

1. claude.ai の画面左下の名前をクリックし、青いチェックが Claude Code と同じ組織に付いているか確かめる。
   Claude Code 側の組織は `claude auth status` の `orgName`。違えば、クリックして切り替える
2. https://claude.ai/customize/connectors (Customize → Connectors)で Asana を追加し、Connect を押す
3. Asana の画面で "Allow access" を押す。ワークスペースを選ぶ画面では、対象プロジェクトがあるワークスペースを選ぶ
4. `claude mcp list` に `claude.ai Asana: https://mcp.asana.com/v2/mcp - ✔ Connected` が出れば届いている
5. ツールはセッションの起動時に読み込まれる。接続前から開いていたセッションでは使えないので、新しいセッションを開く

### 2. フックを登録する

`~/.claude/settings.json` の `hooks` に次を足す。

```json
"PreToolUse": [
  {
    "matcher": "mcp__.*[Aa]sana.*",
    "hooks": [
      { "type": "command", "command": "/usr/bin/python3 ~/.claude/hooks/asana-scope-guard.py pre", "timeout": 5 }
    ]
  }
],
"PostToolUse": [
  {
    "matcher": "mcp__.*[Aa]sana.*",
    "hooks": [
      { "type": "command", "command": "/usr/bin/python3 ~/.claude/hooks/asana-scope-guard.py post", "timeout": 5 }
    ]
  }
]
```

- `python3` ではなく `/usr/bin/python3` を使う。pyenv の shim は作業ディレクトリの Python 指定で解決先が変わり、リポジトリによっては起動しない
- pre は範囲外の呼び出しを deny する。問題がなければ何も返さず、通常の権限確認に任せる(自動で許可はしない)
- post は `get_task` の結果に GID が無ければ結果を差し替え、あればそのタスクを確認済みとして記録する

### 3. 対象プロジェクトを設定する

1. 対象プロジェクトを Asana で開き、URL をコピーする
   - `https://app.asana.com/1/<ワークスペース>/project/<プロジェクト>/...` なら `<プロジェクト>` の数字が GID
   - 旧形式 `https://app.asana.com/0/<プロジェクト>/...` なら最初の数字
2. URL の `<ワークスペース>` が、`get_me` の結果の `workspaces[].gid` に含まれているか確かめる。含まれないと `Not Authorized` になる
3. `~/.claude/asana-scope.json` に書く。ファイルが無い・`project_gid` が空の間は、Asana の呼び出しが全部止まる

   ```json
   { "project_gid": "<GID>", "project_name": "<プロジェクト名>" }
   ```

4. GID を変えると、確認済みタスクの記録は自動で無効になる(記録に GID を持っているため)

### 4. 動作を確かめる

1. 判定のテストを流す。架空の GID と一時ディレクトリで動くので、本物の設定と記録には触らない。`ALL OK` が出ればよい

   ```bash
   /usr/bin/python3 ${CLAUDE_SKILL_DIR}/scripts/test_scope_guard.py
   ```

2. 実物で確かめる。新しいセッションで次を順に頼む
   - `get_project`(`project_id` = GID)→ プロジェクト名が `project_name` と一致する
   - `get_tasks`(`project` = GID, `limit` = 1)→ 返ったタスクを `get_task` で開く → 結果が `[asana-scope-guard]` の文面に差し替えられていない
   - `search_objects` を頼む → フックに deny される

   対話できないセッションから確かめるときは、読み取りのツールだけを許可した子セッションを使う。
   既定の権限モードが auto なので、`--permission-mode default` を必ず付ける。

   ```bash
   claude -p "<上の手順>" --permission-mode default --max-turns 8 \
     --allowedTools "mcp__claude_ai_Asana__get_project" "mcp__claude_ai_Asana__get_tasks" "mcp__claude_ai_Asana__get_task" \
     --disallowedTools "Bash" "Edit" "Write" < /dev/null
   ```

### トラブル対応

| 症状                                                      | 原因と対応                                                                                                                                                                                                                                                           |
| --------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `claude mcp list` に Asana が出ない                       | claude.ai で選んでいる組織が Claude Code と違う。または認可が終わっていない(Connectors の Asana が Connect のまま)。1 をやり直す                                                                                                                                        |
| セッションに Asana のツールが無い                         | 接続前に開いたセッション。開き直す                                                                                                                                                                                                                                   |
| `get_me` は通るが、対象プロジェクトで `Not Authorized`    | 認可は生きている。対象プロジェクトが、認可したワークスペースに無いか、権限が無い。URL のワークスペース GID と `get_me` の `workspaces` を比べる。違えば claude.ai でコネクタを切ってつなぎ直し、正しいワークスペースを選ぶ。Asana アカウント自体が違うこともある |
| `get_me` も `Not Authorized`                              | 認可が切れている。claude.ai の Connectors で Asana を Disconnect して Connect し直す                                                                                                                                                                                 |
| 全部「asana-scope.json に project_gid が設定されていません」 | 3 を行う                                                                                                                                                                                                                                                             |
| 対象プロジェクトのタスクなのに `get_task` の結果が隠される | `get_task` の既定の結果に所属プロジェクトが入っていない可能性がある。`opt_fields` に `projects` を含めて呼ぶ                                                                                                                                                          |

`claude --debug mcp list` は確認に使わない。`--debug` が `mcp` をフィルタ引数として取り、`list` をプロンプトにした別のセッションが起動する。
接続状態は `claude mcp list` と `claude mcp get "claude.ai Asana"` で見る。

### 既知の制限

- 範囲外のタスクでも、本文などに GID が書かれていると `get_task` が通る。結果の文字列に GID があるかで判定しているため
- `get_task` の既定の結果に所属プロジェクトが含まれるかは未確認(2026-10-13 時点。`Not Authorized` で確かめられていない)
- `create_tasks` の `section_id` が対象プロジェクトのセクションかどうかは検査していない
