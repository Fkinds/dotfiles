---
name: security-audit
description: リポジトリ全体のセキュリティ点検を security-auditor エージェントに任せ、洗い出した結果を一覧で見せ、承認を得てから origin のリポジトリに 1 件ずつ Issue として起票する。「脆弱性を洗い出して」「セキュリティ点検して」「脆弱性対応をしたい」「セキュリティの Issue を起票して」と言われたときに使う。PR やブランチの差分だけのレビューには security-review を使う。
---

# security-audit — 点検から起票まで

点検は `security-auditor` エージェントが受け持つ。このスキルが受け持つのは、任せ方、報告の
確かめ方、ユーザーへの確認、Issue の起票。

**修正はしない。** 修正に進むときは、方針を [grilling](../grilling/SKILL.md) で詰めてから
別の作業として行う。

## 守ること

| 決まり | 内容 |
| --- | --- |
| 書き込み先 | `origin` のリポジトリだけ。上流(fork 元、`upstream` リモート)には、push・Issue・Advisory を含めて何も書き込まない |
| 起票を止める条件 | `origin` が公開、Issue が無効、書き込み権限が無い、のどれかなら起票せずに止め、どうするかをユーザーに聞く。未修正の脆弱性を公開の Issue に書くと、それがそのまま開示になる |
| 確認 | 起票の前に一覧を見せ、どれを起票するか承認をもらう。「洗い出して」だけの依頼なら、一覧を見せて終える |
| `gh` | 常に `-R <owner>/<repo>` を付ける。`upstream` リモートがあると、既定のリポジトリが上流になりうる |

## 手順

### 1. 準備する

1. `git remote get-url origin` と
   `gh repo view <owner>/<repo> --json visibility,hasIssuesEnabled,viewerPermission,isFork,parent`
   で起票先を確かめる。
2. `git rev-parse HEAD` で対象コミットを決め、`git branch -r --contains HEAD` で origin に
   push 済みか確かめる。push されていなければ、Issue のリンクが切れることを伝え、どのコミットを
   対象にするか聞く。`git status --short` で未コミットの変更も見ておく。
3. `command -v cvss_calculator` で CVSS の計算コマンドがあるか確かめる。無ければ
   `uv tool install cvss` で導入してよいか聞く。断られたら、スコアは「未計算」で進める。
4. 作業用ディレクトリをスクラッチパッドの下に作る。

### 2. 点検を任せる

`security-auditor` に委譲する。メッセージには次を書く。

- 対象のパス、対象コミットの SHA、作業用ディレクトリの絶対パス、点検日
- 観点の絞り込み(依頼にあれば)
- ユーザーから聞いている前提(例: 社内向けのツールである、特定の機能は使っていない)

大きいリポジトリ(対象のコードが数万行を超える)では、観点ごと(コード / CI・依存・秘密情報・
実行環境)や、コードのディレクトリごとに分けて複数を並行に走らせ、報告を 1 つにまとめる。

### 3. 報告を確かめる

- 指摘ごとに「該当箇所」を `Read` し、報告の説明とコードが一致するかを確かめる。食い違えば、
  エージェントに聞き直すか、一覧で「要確認」とする。
- 既存の Issue と PR を検索し(`gh issue list -R <owner>/<repo> --state all --search <語>`、
  `gh pr list -R <owner>/<repo> --state all`)、重複や、既存の PR で解消済みのものを見つける。

### 4. 一覧を見せて承認をもらう

次の表に、「問題なしと判断したもの」と「確かめられなかったこと」を添えて見せる。

| # | 区分 | CVSS(スコアと定性評価) | タイトル | 再現 | 既存の Issue・PR との関係 |
| --- | --- | --- | --- | --- | --- |

既存の PR などで解消済みのものは、起票しない理由とともに示す。そのうえで、どれを起票するかを聞く。

### 5. 起票する

1. 起票先をもう一度判定する(上の「守ること」)。
2. `security` ラベルが無ければ作る:
   `gh label create security -R <owner>/<repo> --color B60205 --description "セキュリティ上の問題"`
3. 本文を [issue-template.md](issue-template.md) の書式で書き、作業用ディレクトリにファイルとして置く。
4. 相互に参照する Issue は、参照される側から順に起票する。参照先の番号は `{{A}}` のような
   プレースホルダで書いておき、1 件起票するたびに番号へ置き換える。起票の直前に、プレースホルダが
   残っていないことを確かめる。
5. `gh issue create -R <owner>/<repo> --title "<タイトル>" --body-file <ファイル> --label security`
6. 起票後に `gh issue list -R <owner>/<repo> --label security` で一覧を、各 Issue の本文で
   参照番号を確かめる。

### 6. 結果を伝える

- 作った Issue の表(番号とリンク、区分、CVSS、タイトル)
- 起票しなかったものと、その理由
- 次にできること(修正するなら、方針を grilling で詰めてから)

記録は Issue だけにし、別のファイルは作らない。
