---
name: creating-stacked-prs
description: スタック PR をこの環境のルールで作るための上乗せ指針。gh stack submit で PR を作るとき、スタックの PR を ready for review にするとき、スタックの PR にタイトルや本文を入れるときに使う。gh-stack のコマンド自体は公式スキルに委ねる。扱う範囲は draft のまま作る方法(--open を渡さない)、自動生成された英語タイトルを日本語に直す手順、assignee の付与、下から順に ready にする理由。
allowed-tools:
  - Bash
---

# スタック PR の運用ルール

**コマンドの使い方は公式スキル `gh-stack` にある**(`gh skill install github/gh-stack`)。
init / add / submit / rebase / sync / merge の詳細、非対話フラグ、レイヤ設計は
そちらに従う。**ここはその上に乗せる、この環境固有のルールだけ。**

対象は `gh stack submit` で PR を作るとき。単発の PR には関係しない。

---

## 1. draft のまま作る

`gh stack submit` に `--draft` フラグは**ない**(v0.1.0)。代わりに:

```bash
gh stack submit --auto        # 新規 PR は draft で作られる
```

- **`--open` を渡さない。** これは "Mark new and existing PRs as ready for review"。
  付けると draft のルールを外れる。
- 対話エディタでは新規 PR が既定で **ready** になる。`--auto` とは逆なので、
  エディタを開かない(= 常に `--auto`)。

---

## 2. タイトルと本文を日本語にする

`--auto` は**タイトルを自動生成する**(英語になりうる)。submit 後に直す。

```bash
gh stack view --json | jq -r '.branches[].pr.number'    # PR 番号を取る

gh pr edit <n> --title "feat: 認証基盤を追加" --body "$(cat <<'EOF'
## :rocket: 概要
このレイヤで何をしたか

## :sparkles: 変更点
- 変更点1

## :white_check_mark: テスト
- [ ] ユニットテスト実行
EOF
)"
```

- **スタック全体の説明は一番下の PR に置く。** 上のレイヤは自分の差分だけを書く。
  同じ説明を全 PR に貼らない。
- レイヤ間の依存(「#12 の上に積んでいる」)は本文に書かなくてよい。
  GitHub のスタック表示が示す。

---

## 3. assignee を付ける

`--assignee` フラグも**ない**。submit 後にまとめて付ける。

```bash
for n in $(gh stack view --json | jq -r '.branches[].pr.number'); do
  gh pr edit "$n" --add-assignee @me
done
```

---

## 4. ready にするのは下から順

```bash
gh pr ready <bottom-pr>     # 一番下から
gh pr ready <next-pr>
```

**base が draft のままだと、その上の PR はマージできない。** 上だけ ready に
しても進まない。

- マージは `gh stack merge --yes`(`gh pr merge` はスタックで動かない — 公式スキル参照)。
- **プロジェクト固有の条件**(ADR とコードの同期など)があれば、
  ready にする前に**全レイヤ**で満たす。プロジェクト側のスキルに従う。

---

## チェックリスト

- [ ] `gh stack submit --auto` で作り、**`--open` を渡していない**
- [ ] 全 PR が draft になっている
- [ ] タイトルと本文が**日本語**(自動生成のまま放置していない)
- [ ] スタック全体の説明が**一番下の PR**にあり、上は差分だけ
- [ ] 全 PR に **assignee @me** が付いている
- [ ] ready にするのは**下から順**
- [ ] プロジェクト固有のマージ条件を**全レイヤ**で満たした
