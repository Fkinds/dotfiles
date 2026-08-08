---
name: skill-authoring
description: 新しい Claude スキル(SKILL.md)を作成する手順。Claude が正しく自動起動できる description の設計、frontmatter の選び方、本文の構成、補助ファイルへの分割、動作検証、このリポジトリへの提出までを扱う。「スキルを作りたい」「スラッシュコマンドを追加したい」「この手順をスキル化して」と言われたとき、あるいは同じ指示を繰り返し貼り付けている・CLAUDE.md の一節が手順に育ってしまったものを切り出すときに使う。
allowed-tools:
  - Read
  - Write
  - Edit
  - Grep
  - Glob
  - Bash
---

# skill-authoring

新しいスキルを 1 つ作り、動くことを確認して提出するまでの手順。

粒度の判断(1 スキルにするか複数に割るか)は [skill-scoping](../skill-scoping/SKILL.md)、
既存スキルの点検は [skill-review](../skill-review/SKILL.md) を使う。

## そもそもスキルにすべきか

スキルにする:

- 同じ指示・チェックリスト・多段の手順を繰り返し貼り付けている。
- CLAUDE.md の一節が「事実」ではなく「手順」に育っている。
- 参照はするが常時は要らない知識(規約集、ドメイン知識、API 詳細)がある。
  スキル本文は使われるまでロードされないので、長い参照資料でも普段のコストはほぼゼロ。

スキルにしない:

- プロジェクト全体の普遍的な事実(技術スタック、ビルド/テストコマンド)→ CLAUDE.md。
- その会話限りの指示 → そのまま書けばよい。

## ステップ1 — 置き場所と名前を決める

| 置き場所 | パス | 有効範囲 |
| --- | --- | --- |
| Personal | `~/.claude/skills/<skill-name>/SKILL.md` | 自分の全プロジェクト |
| Project | `.claude/skills/<skill-name>/SKILL.md` | そのプロジェクトのみ |
| Plugin | `<plugin>/skills/<skill-name>/SKILL.md` | プラグインが有効な場所 |

**このリポジトリでは** リポジトリ直下に `<skill-name>/SKILL.md` を置く(社内スキル集としての
配布元であり、`.claude/skills/` ではない)。利用者が personal / project の位置へ配置する。

命名:

- ディレクトリ名は kebab-case。**personal / project スキルではディレクトリ名がそのまま
  `/コマンド名`** になる(frontmatter の `name` は一覧上の表示名にすぎない)。
- 名詞句か動詞句で、何をするかが名前だけで分かるものにする(`helper` / `utils` は不可)。
- ファイル名は厳密に `SKILL.md`。`skill.md` は CI(`scripts/validate_skills.py`)で落ちる。

## ステップ2 — frontmatter を書く

`---` で挟んだ YAML。**このリポジトリでは `name` と `description` が必須**で、
`name` は kebab-case かつディレクトリ名と一致していなければならない(CI が検査する)。

```yaml
---
name: my-skill
description: 何をするか。そして、ユーザーが〇〇を求めたときに使う、というトリガー。
---
```

### description が最重要

Claude はスキル一覧に載った `description` だけを見て「今これを使うか」を判断する。
本文は判断材料にならない。

- **三人称で、What と When の両方を書く。** 「〜します」ではなく「〜する。〜のときに使う。」
- **ユーザーが実際に口にする語をトリガーとして入れる。** 語彙が合わないと起動しない。
- **主要ユースケースを先頭に置く。** `description` と `when_to_use` の合計は一覧上
  **1,536 文字**で切り詰められる(`skillListingMaxDescChars` で変更可)。
- スキル数が多いと、一覧全体の文字数予算(既定でモデルのコンテキストウィンドウの 1%、
  `skillListingBudgetFraction` で変更可)を超え、**使用頻度の低いスキルから description が
  丸ごと落とされる**。冗長な description は自分だけでなく他スキルの起動精度も下げる。
- 1 つの description に複数の目的を詰めない。曖昧になり起動が外れる → 分割する
  ([skill-scoping](../skill-scoping/SKILL.md))。

```yaml
# NG: 何をするかしか書いていない。トリガー語がない
description: コードレビューを行います。

# OK: What + When + トリガー語
description: 変更した Python コードをレビューし、複雑度・命名・エラー処理を指摘する。ユーザーがコードのレビュー・最適化・リファクタリングを求めたとき、あるいは PR を出す前に使う。
```

### よく使う任意フィールド

| フィールド | 用途 |
| --- | --- |
| `when_to_use` | トリガー語や例示リクエストを追記する。`description` に連結され、同じ 1,536 文字上限に含まれる |
| `allowed-tools` | そのスキルを起動したターンの間、許可を求めずに使えるツール。次のユーザーメッセージで失効する |
| `disallowed-tools` | スキルが有効な間、使わせないツール |
| `disable-model-invocation: true` | Claude の自動起動を禁じ、`/名前` の手動起動だけにする |
| `user-invocable: false` | `/` メニューから隠す。Claude だけが使う背景知識向け |
| `paths` | glob に一致するファイルを扱っているときだけ自動起動させる |
| `argument-hint` / `arguments` | 引数の補完ヒントと、`$名前` で本文に展開する名前付き引数 |
| `context: fork` / `agent` / `background` | サブエージェントとして隔離実行する |
| `model` / `effort` | そのスキルが有効な間のモデル・推論強度 |

起動制御の使い分け:

| 設定 | ユーザーが `/` で起動 | Claude が自動起動 |
| --- | --- | --- |
| 既定 | できる | できる |
| `disable-model-invocation: true` | できる | **できない**(description が context に載らない) |
| `user-invocable: false` | **できない** | できる |

`disable-model-invocation: true` は副作用のある手順(`/deploy`、`/commit`、通知送信)に付ける。
実行タイミングを Claude に決めさせないためのもの。

### 配布先による frontmatter の制約(重要)

Claude Code はここに挙げた全フィールドを受け付けるが、**claude.ai へのアップロード /
Skills API / `package_skill.py` で使えるのは 6 つだけ**:
`name` / `description` / `license` / `compatibility` / `metadata` / `allowed-tools`。

それ以外(`user-invocable`、`argument-hint` など)が 1 つでもあると、無視されるのではなく
**ハードエラーでアップロードに失敗する**。

```text
Unexpected key(s) in SKILL.md frontmatter: argument-hint. Allowed properties are: allowed-tools, compatibility, description, license, metadata, name
```

配布先が決まっていないなら、この 6 フィールドに収めておけばどちらでも通る。
`` !`cmd` `` の動的コンテキスト注入など Claude Code 固有の本文機能も、claude.ai や
API 経由では機能しない。

## ステップ3 — 本文を書く

**一度ロードされた本文は、そのセッションの間ずっと context に残り続ける。** Claude は後続の
ターンでファイルを読み直さない。つまり本文の 1 行 1 行が継続的なトークンコストであり、かつ
「タスク中ずっと有効な指示」として書く必要がある(一度きりの手順書ではない)。

- **やることを書く。なぜ・どうしてそうなったかは書かない。** CLAUDE.md と同じ簡潔さの基準。
- 手順は番号付きで、順序に意味がある形にする。判断が要る箇所は表かチェックリストにする。
- 具体例は 1 つに絞る。バリエーションの列挙は補助ファイルへ。
- **`SKILL.md` は 500 行以下**に収める。超えたら分割する([skill-scoping](../skill-scoping/SKILL.md))。

内容の型は 2 つ。混ぜてもよいが、どちらなのかを意識して書く。

- **参照型(reference)**: 規約・パターン・ドメイン知識。会話の文脈と併せて使うのでインラインで動かす。
- **タスク型(task)**: デプロイ・コミット・生成のような手順。`/名前` で明示起動させたいことが多い。

### 本文で使える置換

| 記法 | 展開されるもの |
| --- | --- |
| `` !`command` `` | 実行結果。Claude が本文を読む**前**に差し込まれる(動的コンテキスト注入) |
| `$ARGUMENTS` / `$0` / `$1` | 起動時に渡された引数(全体 / 位置指定) |
| `${CLAUDE_SKILL_DIR}` | その `SKILL.md` があるディレクトリ。同梱スクリプトの参照に使う |
| `${CLAUDE_PROJECT_DIR}` | プロジェクトルート |
| `${CLAUDE_SESSION_ID}` / `${CLAUDE_EFFORT}` | セッション ID / 現在の推論強度 |

`${CLAUDE_SKILL_DIR}` は本文と `allowed-tools` の Bash ルールの両方で展開されるので、
両方に同じ書き方をすれば同梱スクリプトを許可プロンプトなしで実行できる。

```yaml
---
name: render-chart
description: CSV からチャートを描画する
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/render.sh *)
---

`${CLAUDE_SKILL_DIR}/scripts/render.sh <csv-file>` を実行する。
```

## ステップ4 — 補助ファイルへ逃がす

詳細な参照資料、長い例、スクリプトは別ファイルにし、`SKILL.md` からは「何が書いてあって
いつ読むか」を示すリンクだけを置く。**リンクされたファイルは必要になったときだけ読まれる**。

```text
my-skill/
├── SKILL.md        # 必須。概要と手順、他ファイルへの案内
├── reference.md    # 詳細仕様。必要時に読む
├── examples.md     # 例集。必要時に読む
└── scripts/
    └── helper.py   # 実行するだけ。context には載らない
```

```markdown
## 参考資料

- 全フィールドの詳細は [reference.md](reference.md)
- 使用例は [examples.md](examples.md)
```

分割の判断基準は [skill-scoping](../skill-scoping/SKILL.md) を見る。

## ステップ5 — 検証する

起動したことは「見つけられた」ことしか意味しない。**起動精度**と**出力品質**を分けて確認する。

1. **静的検査**を通す。このリポジトリでは pre-commit。

   ```bash
   pre-commit run --all-files   # markdownlint-cli2 + validate_skills.py
   ```

2. **新しいセッション**で試す。スキルを書いた会話の残り文脈が、本文の指示不足を隠してしまう。
3. **自動起動を確認する。** description に合いそうな自然な言い方で頼み、起動するか見る。
   起動しなければ description のトリガー語を疑う。逆に無関係な場面で起動するなら
   description が広すぎる。
4. **ベースライン比較。** 同じプロンプトを「スキルあり」「スキルなし」で流し、差を見る。
   差が出ないなら、そのスキルは何も足していない。
5. 反復を自動化するなら `skill-creator` プラグイン
   (`/plugin install skill-creator@claude-plugins-official`)。テストケース、隔離実行、
   採点、あり/なしのベンチマーク、description のチューニングまでやる。

## ステップ6 — このリポジトリへ提出する

1. `main` を最新化し、作業ブランチを切る。種別は `feature/`(新スキル追加)。

   ```bash
   git switch main && git pull
   git switch -c feature/<skill-name>-skill
   ```

2. コミットは [Conventional Commits](https://www.conventionalcommits.org/)。
   例: `feat: skill-authoring スキルを追加`
3. Push して PR を作成する。`main` への直接 push は禁止。
4. レビュー指摘は fixup コミット(`git commit --fixup <hash>`)で対応し、マージ前に
   `git rebase -i --autosquash main` で畳み込む。

詳細はリポジトリの運用ルールに従う。**このリポジトリ(dotfiles)での読み替えは
ルートの `CLAUDE.md` を見る** — 配置先・pre-commit・提出手順が上記と異なる。

## チェックリスト

- [ ] スキルにすべき内容か(CLAUDE.md に属する「事実」ではないか)
- [ ] ディレクトリ名は kebab-case、ファイル名は厳密に `SKILL.md`、`name` は両者と一致
- [ ] `description` が三人称で What と When を含み、ユーザーが実際に使う語をトリガーに持つ
- [ ] `description` に目的が 1 つだけ入っている(複数混ざっていないか)
- [ ] 配布先が claude.ai / API なら frontmatter が spec の 6 フィールドに収まっている
- [ ] 本文は「常時有効な指示」として書かれ、500 行以下、冗長な説明がない
- [ ] 詳細は補助ファイルへ逃がし、`SKILL.md` から何をいつ読むか案内している
- [ ] pre-commit が通る
- [ ] 新しいセッションで、自然な言い方から自動起動することを確認した
- [ ] スキルなしとの差が出ることを確認した
