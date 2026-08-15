---
name: fsd-layers
description: Feature-Sliced Design (FSD) のレイヤー構成そのものを扱う。新しいコードをどのレイヤーに置くか迷ったとき、レイヤーをまたぐ import を書くとき、循環 import や逆流を直すとき、そもそも FSD を採用すべきか決めるとき、FSD を導入・レビューするときに使う。扱う範囲は app / pages / widgets / features / entities / shared の役割と選び方、下位レイヤーへの一方向依存、同一レイヤー間の cross-import 禁止と @x による例外、スライスと ui/model/api/lib/config セグメントの構成、index.ts による Public API、規模に応じた採用可否の判断と段階的な導入、機械的な依存検査。
---

# FSD: レイヤーとスライス (Layers)

**どのレイヤーに置くかと、どちら向きに依存してよいか。** レイヤー単体の中身は
[fsd-app-layer](../fsd-app-layer/SKILL.md) /
[fsd-pages-layer](../fsd-pages-layer/SKILL.md) /
[fsd-widgets-layer](../fsd-widgets-layer/SKILL.md) /
[fsd-features-layer](../fsd-features-layer/SKILL.md) /
[fsd-entities-layer](../fsd-entities-layer/SKILL.md) /
[fsd-shared-layer](../fsd-shared-layer/SKILL.md)。

モジュール間の依存を測る一般論は
[component-design](../component-design/SKILL.md)。

---

## 1. レイヤー

| レイヤー | 置くもの | 判断の問い |
| --- | --- | --- |
| `app/` | プロバイダ、ルーター設定、グローバルスタイル、エントリーポイント | 全画面に効く初期化か |
| `pages/` | ルートに対応する画面 | URL と 1 対 1 か |
| `widgets/` | 自己完結した複合 UI ブロック | 複数の feature / entity を束ねているか |
| `features/` | ユーザーの操作・ビジネスアクション | **動詞**で言えるか |
| `entities/` | 業務ドメインのオブジェクト | **名詞**で言えるか |
| `shared/` | ドメイン非依存の基盤 | 業務を何も知らずに再利用できるか |

上が上位。**上位ほどそのアプリ固有で、下位ほど再利用される。**

`processes/` は廃止されたレイヤー。新規に作らない。

---

## 2. 置き場所を決める

上から順に判定し、**最初に当たったところ**に置く。

1. 業務の語彙が 1 つも出てこない → `shared`
2. 業務の名詞そのもの(Project, User, Schedule)を表す → `entities`
3. ユーザーが起こす操作(作成する、絞り込む、ログインする)→ `features`
4. 複数の feature / entity を束ねた、どのページにも置ける塊 → `widgets`
5. URL と 1 対 1 で対応する画面 → `pages`
6. アプリ全体の起動・設定 → `app`

**迷ったら下位に置く。** 上位へ引き上げるのは import 元が少数なので簡単だが、
下位へ落とすときは利用者全員の import を直すことになる。

判定できないときは、そのコードが**何を知っているか**を見る。API のエンドポイントを
知っていれば shared ではない。ボタンの文言を知っていれば entities ではない。

---

## 3. 依存は下向きの一方向

```text
app → pages → widgets → features → entities → shared
```

- 下位レイヤーだけを import してよい。**飛ばしてよい**(`pages` → `shared` は正しい)。
- 逆流は禁止。`entities` が `features` を import したら、それは entity ではない。
- **同一レイヤーのスライス間 import は禁止**(cross-import)。
  `features/auth` → `features/cart` は違反。

違反を見つけたときの直し方は 3 つしかない。

| 状況 | 直し方 |
| --- | --- |
| 共通の部品を使い回したい | 共通部分を**下位レイヤーへ下ろす** |
| 2 つを組み合わせたい | **上位レイヤーで合成する**(props で渡す) |
| 片方が本質的に片方を含む | **同じスライスに統合する**(境界の引き直し) |

### cross-import が避けられないとき: `@x`

entity 同士の参照(Project が User を持つ)は現実に起きる。**このときだけ** `@x` を使う。

```text
entities/
├── user/
│   ├── @x/
│   │   └── project.ts   # project スライス「にだけ」公開する API
│   ├── model/
│   └── index.ts
└── project/
    └── model/types.ts   # import { UserPreview } from "@/entities/user/@x/project"
```

- 使ってよいのは **entities 同士**に限る。features 同士の `@x` は設計の誤り
  (上位レイヤーで合成する)。
- 誰に何を公開しているかがファイル名で分かるのが利点。乱発すると意味を失う。

---

## 4. スライスとセグメント

```text
features/create-project/     ← スライス(ドメイン語彙で名付ける)
├── ui/                      ← セグメント
│   └── CreateProjectForm.tsx
├── model/
│   ├── useCreateProject.ts
│   └── types.ts
├── api/
│   └── createProject.ts
├── lib/                     ← 必要な場合のみ
├── config/                  ← 必要な場合のみ
└── index.ts                 ← Public API(必須)
```

- **`shared` と `app` はスライスを持たない。** セグメントを直下に置く
  (`shared/ui/`, `shared/api/`)。
- スライス名はドメインの語彙。`utils` / `helpers` / `common` / `misc` は不可。
- セグメントは次の 5 つだけ。**増やさない。**

| セグメント | 中身 |
| --- | --- |
| `ui/` | コンポーネント、スタイル |
| `model/` | 型、スキーマ、状態、そのスライスのロジック |
| `api/` | サーバーとの通信 |
| `lib/` | **そのスライス専用**のユーティリティ |
| `config/` | 定数、設定値 |

全部作らない。実際に必要になったものだけ作る。`ui/` と `model/` で足りることが多い。

---

## 5. Public API は `index.ts`

スライスの外に見せてよいものだけを `index.ts` から export し、外部は必ずそこを通る。

```typescript
// features/create-project/index.ts
export { CreateProjectForm } from "./ui/CreateProjectForm";
export type { CreateProjectInput } from "./model/types";
```

```typescript
// OK
import { CreateProjectForm } from "@/features/create-project";

// NG — 内部セグメントへの直接アクセス
import { CreateProjectForm } from "@/features/create-project/ui/CreateProjectForm";
```

- `export *` で中身を全部出さない。Public API の意味がなくなり、内部の改名が
  そのまま破壊的変更になる。
- **スライス内部**では相対パスで直接 import してよい。自分の `index.ts` を
  経由すると循環 import になる。
- `shared` は 1 枚の `index.ts` にまとめず、**セグメント単位**で公開する
  (`@/shared/ui`, `@/shared/api`)。全体を 1 つのバレルにすると、どこか 1 つを
  import しただけで shared 全体が読み込まれる。

---

## 6. FSD の外に置くもの

- **ルーティングライブラリが要求するディレクトリ**(TanStack Router の `routes/`、
  Next.js の `app/`)は FSD レイヤーではない。中身は `pages` のスライスを
  呼ぶだけの薄い層にし、そこにロジックを書かない。
- **自動生成ファイル**(`routeTree.gen.ts`、OpenAPI やスキーマからの生成物)は
  手で編集しない。生成物を取り込む先は `shared/api`。
- テストと Storybook は対象と同じスライスに同居させる。別ツリーに切り出さない。

---

## 7. 採用するか、どこから入れるか

FSD は構造を保つコストを伴う。**入れない判断を先にする。**

| 向く | 向かない |
| --- | --- |
| 画面数・機能数が多い中〜大規模 | 画面が数枚の社内ツール |
| 複数人・複数チームで触る | 個人開発 |
| ライフサイクルが長く、改修が続く | 短期で作り切るプロトタイプ |
| DDD / クリーンアーキテクチャを採っている | 仕様が固まらず作り直しが前提 |

向かない側で入れると、スライス間の移動と Public API の維持だけが残る。
迷う規模なら `app` / `pages` / `shared` の 3 枚から始め、**必要になってから**増やす。

### 段階的に入れる

**6 レイヤー全部を最初から作らない。** 空のレイヤーディレクトリは置かない。

- 最初は `app` / `pages` / `shared` の 3 枚で足りる。
- `pages` が太ってきたら、そこから `features` と `entities` を切り出す。
- `widgets` は「同じ塊を 2 つ目のページでも使う」ときに初めて作る。

既存コードを移すときの順序:

1. ドメイン非依存のものを `shared` に集める(影響が小さく、効果が出やすい)。
2. 業務の名詞ごとに `entities` を切る。
3. 画面から操作単位で `features` を抜く。
4. **依存方向を機械的に検査する仕組みを入れる**。人力のレビューでは維持できない。

設定例は [enforcement.md](enforcement.md)(dependency-cruiser / steiger / ESLint)。

---

## アンチパターン

| アンチパターン | なぜ悪いか |
| --- | --- |
| 下位から上位を import する | 依存が双方向になり、下位レイヤーが単独で使えなくなる |
| 同一レイヤーのスライス同士を import する | スライスが独立して削除・移動できなくなる |
| `features` 同士を `@x` で繋ぐ | cross-import を追認しただけ。上位で合成する |
| `index.ts` を通さず内部セグメントを直接 import する | 内部構造が外部契約になり、改名できなくなる |
| `index.ts` に `export *` と書く | 公開範囲を選んでいない。Public API として機能しない |
| `utils` / `common` という名前のスライス | 何のスライスか判別できず、あらゆるものが集まる |
| 5 つ以外のセグメントを作る | 置き場所の判断が人によってぶれる |
| レイヤーを 6 枚とも最初に作る | 中身のないディレクトリを維持し続けることになる |
| `shared` を 1 枚のバレルで公開する | 1 つ import しただけで shared 全体が読み込まれる |
| 生成ファイルをレイヤーに合わせて手で直す | 次の生成で消える |

---

## ルール(チェックリスト)

- [ ] そもそも FSD を入れる規模か(向かない側で構造だけ抱えていないか)
- [ ] そのコードは**決定フローで最初に当たったレイヤー**に置かれているか(迷ったら下位)
- [ ] import は**下向き**だけか。逆流していないか
- [ ] **同一レイヤーのスライス間** import がないか
- [ ] `@x` を使っているのは entities 同士だけか
- [ ] スライス名がドメインの語彙になっているか(`utils` などになっていないか)
- [ ] セグメントは `ui` / `model` / `api` / `lib` / `config` の範囲に収まっているか
- [ ] 外部からの import が `index.ts` を経由しているか。`export *` になっていないか
- [ ] スライス内部が自分の `index.ts` を経由していないか(循環 import)
- [ ] `shared` はセグメント単位で公開されているか
- [ ] ルーティング用ディレクトリと生成物を FSD レイヤーに混ぜていないか
- [ ] 依存方向が機械的に検査されているか([enforcement.md](enforcement.md))
