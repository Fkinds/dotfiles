---
name: creating-stacked-prs
description: gh-stack で依存関係のある PR を積み上げて作る手順。スタックの設計(依存順にレイヤを分ける)、非対話で実行するための必須フラグ、init/add/submit/sync/rebase の使い分け、レイヤ間の移動、マージ後の同期、draft と日本語本文と assignee のルールをスタックでも守る方法を扱う。大きな変更を小さな PR に分けたいとき、依存する PR を積みたいとき、gh stack を使うとき、スタックのレビュー後に rebase や sync が必要になったときに使う。
allowed-tools:
  - Read
  - Grep
  - Glob
  - Bash
---

# スタック PR の作成 (gh-stack)

大きな変更を、**下から順に積み上がる小さな PR の連なり**にする。各 PR の base は
1 つ下のブランチなので、レビュアーはそのレイヤの差分だけを見る。

```text
main (trunk)
 └── auth-layer      → PR #1 (base: main)          ← bottom(trunk に近い)
  └── api-endpoints  → PR #2 (base: auth-layer)
   └── frontend      → PR #3 (base: api-endpoints) ← top
```

`up` は trunk から**離れる**方向、`down` は trunk に**近づく**方向。

> **公式スキルがある。** `gh skill install github/gh-stack` で入る
> `github/gh-stack` の `gh-stack` スキルが、コマンドの詳細を網羅している。
> **本スキルはその上に乗せる運用ルール**(日本語・draft・assignee)を扱う。
> コマンドの詳細で迷ったら公式スキル、または `gh stack <cmd> --help`。

単発の PR を作るだけなら、このスキルは不要。プロジェクト側に
`creating-pull-requests` のようなスキルがあればそちらに従う。

---

## 1. 前提

```bash
gh extension install github/gh-stack     # 未インストールなら
git config rerere.enabled true           # 衝突解決を記憶(init のプロンプトを回避)
git config remote.pushDefault origin     # リモートが複数あるとき必須
```

`gh` は v2.0 以降。**`rerere` と `pushDefault` を先に設定する。**
未設定だと対話プロンプトで固まる。

---

## 2. 非対話で実行する(最重要)

**プロンプトが出るとハングして戻らない。** 次を必ず守る。

| コマンド | 必須 | 理由 |
| --- | --- | --- |
| `init` / `add` / `checkout` | **ブランチ名を位置引数で渡す** | 省略すると対話選択が出る |
| `submit` | **`--auto`** | 省略すると PR ごとにタイトルを聞かれる |
| `view` | **`--json`** | 省略すると TUI が起動し操作不能 |
| `push` / `submit` / `sync` / `rebase` / `link` | リモートが複数なら `--remote origin` | — |

- `checkout` / `modify` / `trunk` に **`--remote` はない**。`remote.pushDefault` に依存する。
- ブランチ名は**そのまま使われる**。`gh stack add refactor/foo` は `refactor/foo` を作る。
- **複数スタックに属するブランチは避ける。** 該当すると終了コード 6 で落ちる。

---

## 3. レイヤは依存順に設計してから始める

**コードを書く前に分割を決める。** 後から並べ替えると rebase が連鎖する。

- **下**(trunk 側): 基盤。モデル、マイグレーション、共通ユーティリティ、API 定義
- **上**: 依存する側。UI、呼び出し側、設定の反映

判定: 「**下のブランチだけをマージしても壊れないか**」。壊れるなら分け方が違う。

**1 レイヤ = 1 つの意味のある変更**にする。`git add -A` で雑に積まない。
どの変更をどのレイヤに入れるかを意図的に選ぶ。

---

## 4. 基本の流れ

```bash
# 1. スタックを開始(最初のレイヤ)
gh stack init auth-layer

# ... 実装 ...
git add <paths> && git commit -m "feat: 認証基盤を追加"

# 2. 次のレイヤを積む
gh stack add api-endpoints
git add <paths> && git commit -m "feat: API を追加"

# 3. 全レイヤを push して PR を作る(base は自動で連結される)
gh stack submit --auto

# 4. 状態を見る
gh stack view --json
```

**PR 作成後に本文とメタ情報を整える**(第 5 節)。

### レビュー後・マージ後

```bash
gh stack rebase            # 下のレイヤを直したら、上へ連鎖 rebase
gh stack sync              # fetch + rebase + push + PR 状態の同期
gh stack submit --auto     # 変更を PR へ反映
```

- **下のレイヤを直したら必ず `rebase` → `submit`。** 上のレイヤが古い base を
  指したままになる。
- **一番下がマージされたら `sync`。** trunk を取り込み、残りを詰める。

### 移動

```bash
gh stack down / up          # trunk 方向 / 離れる方向へ 1 つ
gh stack bottom / top
gh stack checkout <branch>  # 位置引数を必ず渡す
```

---

## 5. draft・日本語・assignee をスタックでも守る

`gh stack submit` のフラグは **`--auto` / `--open` / `--remote` の 3 つだけ**
(v0.1.0 で確認)。`--draft` も `--assignee` も**ない**。

| ルール | どう満たすか |
| --- | --- |
| **draft で作る** | **`--auto` を使えば自動的に draft になる。`--open` を渡さない** |
| 日本語のタイトル・本文 | submit 後に `gh pr edit` で直す |
| `--assignee @me` | submit 後に `gh pr edit --add-assignee` |

> **`--open` は「ready for review にする」フラグ。** 誤って付けると draft の
> ルールを外れる。**使わない。**
> (対話エディタでは新規 PR が既定で ready になるが、`--auto` では逆に draft が既定)

```bash
gh stack submit --auto                       # draft で作成される

# 各 PR に assignee と日本語のタイトル・本文を入れる
for n in $(gh stack view --json | jq -r '.branches[].pr.number'); do
  gh pr edit "$n" --add-assignee @me
done
gh pr edit <n> --title "feat: 認証基盤を追加" --body "$(cat <<'EOF'
## :rocket: 概要
このレイヤで何をしたか

## :sparkles: 変更点
- 変更点1
EOF
)"
```

- **`--auto` のタイトルは自動生成なので英語になりうる。** 上のように直す。
- **本文は日本語**。レイヤごとに「このレイヤで何をしたか」を書く。
  スタック全体の説明は**一番下の PR**に置き、上は差分だけ書く。
- **すべての PR を draft で作る。** 準備できたら**下から順に** `gh pr ready`。
  上だけ ready にしても、base が draft ではマージできない。
- ADR など**プロジェクト固有の同期ルール**があるなら、それも全レイヤに適用する
  (プロジェクト側のスキルを参照)。

---

## 6. スタックをやめる・作り直す

```bash
gh stack modify      # 対話 TUI。エージェントからは使わない
gh stack unstack     # スタックをローカルと GitHub 両方から削除する
gh stack link        # 既存の PR をスタックとして繋ぐ(ローカル追跡は作らない)
gh stack merge       # スタックをまとめてマージ
```

- **`unstack` は GitHub 側のスタックも消す。** 「ローカルの追跡だけ外す」ではない。
  実行前に本当に消してよいか確認する。
- **`modify` と `switch` は対話 TUI。** エージェントが使うとハングする。
  構成を変えるなら人間が実行するか、`unstack` → 作り直し。
  移動は `up` / `down` / `top` / `bottom` / `checkout <branch>` を使う。
- レイヤの並べ替えが必要になった時点で、**分割の設計が間違っていた**
  可能性が高い(第 3 節)。

---

## アンチパターン

| アンチパターン | なぜ悪いか |
| --- | --- |
| `gh stack submit` を `--auto` なしで実行 | タイトルを聞かれてハングする |
| `gh stack view` を `--json` なしで実行 | TUI が起動し操作不能になる |
| `init` / `add` / `checkout` を引数なしで実行 | 対話選択が出てハングする |
| `rerere` / `pushDefault` を設定せずに始める | プロンプトで止まる |
| `gh stack modify` / `switch` をエージェントが実行 | 対話 TUI。戻らない |
| `gh stack submit --open` を使う | ready for review になり、draft のルールを外れる |
| `unstack` を軽い気持ちで実行 | GitHub 側のスタックまで消える |
| 分割を決めずにコードを書き始める | 後からの並べ替えで rebase が連鎖する |
| 下のレイヤだけでは壊れる分け方 | 個別にマージできず、スタックの意味がない |
| `git add -A` で雑に積む | どのレイヤに何が入ったか説明できなくなる |
| 下のレイヤを直して `rebase` しない | 上の base が古いままになる |
| 上のレイヤだけ `ready` にする | base が draft のままではマージできない |
| `--auto` のタイトルを放置する | 英語のまま残り、日本語のルールを外れる |
| 複数スタックに属するブランチを使う | 終了コード 6 で落ちる |

---

## ルール(チェックリスト)

- [ ] `gh extension install github/gh-stack` 済み。`rerere` と `pushDefault` を設定した
- [ ] レイヤを**依存順**に設計してからコードを書き始めた
- [ ] 各レイヤが「**下だけマージしても壊れない**」単位になっている
- [ ] `init` / `add` / `checkout` に**ブランチ名を位置引数**で渡している
- [ ] `submit` に **`--auto`**、`view` に **`--json`** を付けている
- [ ] リモートが複数なら `--remote` か `pushDefault` を指定した
- [ ] **`--open` を渡していない**(`--auto` だけなら draft で作られる)
- [ ] 全 PR が **draft** で、ready にするのは**下から順**
- [ ] タイトルと本文が**日本語**(`--auto` の自動生成を直した)
- [ ] 全 PR に **assignee @me** が付いている
- [ ] 下のレイヤを直したら **`rebase` → `submit`** した
- [ ] 一番下がマージされたら **`sync`** した
- [ ] `modify` をエージェントから実行していない
- [ ] プロジェクト固有のルール(ADR 同期など)を全レイヤに適用した
