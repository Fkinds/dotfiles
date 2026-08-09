---
name: fsd-pages-layer
description: Feature-Sliced Design (FSD) の pages レイヤーの設計指針。URL と 1 対 1 で対応する画面の切り方、widgets / features を並べるだけに徹する責務、ルートパラメータと検索パラメータの検証、データ取得を先に始める起点(loader / prefetch)の置き場所、ルーティングライブラリのディレクトリと pages スライスの分離、共通レイアウトの扱い、ページが太ったときの切り出し先を扱う。pages にコードを置こうとしているとき、画面が肥大化してきたとき、URL の状態やルートパラメータの扱いに迷うとき、ルーティングと FSD の対応を決めるときに使う。
allowed-tools:
  - Read
  - Grep
  - Glob
---

# FSD: pages レイヤー

**URL 1 つに対応する画面。並べるだけに徹する。** レイヤーの選び方と依存ルールは
[fsd-layers](../fsd-layers/SKILL.md)。並べる対象は
[fsd-widgets-layer](../fsd-widgets-layer/SKILL.md) /
[fsd-features-layer](../fsd-features-layer/SKILL.md)、アプリ全体の初期化は
[fsd-app-layer](../fsd-app-layer/SKILL.md)。

---

## 1. スライスの単位

**ルート 1 つにつき 1 スライス。** 表示するデータが同じでも、URL が違えば別スライス。

```text
pages/
├── project-list/       # /projects
├── project-detail/     # /projects/$projectId
└── project-edit/       # /projects/$projectId/edit
```

```text
pages/project-detail/
├── ui/
│   ├── ProjectDetailPage.tsx
│   └── ProjectSummarySection.tsx   # このページ専用のブロック
├── model/                          # URL 状態の解釈など。薄く保つ
├── api/                            # 事前取得の定義(必要なら)
└── index.ts
```

- 一覧と詳細をタブで切り替えるだけなら 1 ページ。**URL が変わるかで判断する。**
- モーダルで開く画面は、URL を持つなら別ページ、持たないなら feature。

---

## 2. 責務は「並べる」ことだけ

ページの `ui` は、widget / feature / entity を配置し、**レイアウトを決める**。

```typescript
// pages/project-detail/ui/ProjectDetailPage.tsx
export function ProjectDetailPage() {
  const { projectId } = Route.useParams();
  const { data: project } = useQuery(projectQuery(projectId));

  return (
    <PageLayout title={project.name}>
      <ProjectSummary project={project} />
      <ProjectTable projectId={projectId} />
      <ArchiveProjectButton projectId={projectId} />
    </PageLayout>
  );
}
```

ページに置いてよいもの / いけないもの:

| 置く | 置かない |
| --- | --- |
| ブロックの配置、幅・余白などレイアウト | 業務ロジック(feature / entity へ) |
| URL 由来の値の取り出しと検証 | 汎用のバリデーション実装(`shared/lib` へ) |
| ブロック間の受け渡し(片方の結果を他方へ) | 再利用される表示部品(entity / widget へ) |
| 操作後の遷移・通知 | 通知の仕組みそのもの(`app` / `shared` へ) |

**幅・余白を決めるのはページ。** feature や widget が自分で固定していたら、
それは下位レイヤー側の誤り([fsd-widgets-layer](../fsd-widgets-layer/SKILL.md))。

---

## 3. URL の状態はページが解釈する

ルートパラメータ・検索パラメータは**ページの入口で一度だけ検証**し、
以降は型の付いた値として下に渡す。

```typescript
// 検索パラメータのスキーマ(ルート定義側で検証する)
const searchSchema = z.object({
  status: z.enum(["draft", "active", "archived"]).optional(),
  page: z.number().int().positive().default(1),
});
```

- 検証を通らない値は、**そのページのエラー表示**か既定値へのリダイレクトで扱う。
  下位レイヤーに不正な値を流さない。
- URL に載せる状態(フィルタ、ページ番号、タブ)と、載せない状態(モーダルの開閉)を
  区別する。**共有・リロードで復元されるべきものは URL に載せる。**
- ステータスの enum のような業務語彙は entity の型を使う。ページで再定義しない。

---

## 4. データ取得の起点

ページはその画面で必要なデータの**取得を始める場所**になれる。

- ルーティングライブラリの `loader` / `beforeLoad` で先に取得を始めると、
  描画とデータ取得が直列にならない。取得の**定義**は entity の `api`
  ([fsd-entities-layer](../fsd-entities-layer/SKILL.md))から借り、
  **いつ始めるか**だけをページ側で決める。
- ページが取ったデータを props で下に配る必要はない。widget が自分で取ってよい
  (キャッシュがあるのでリクエストは重複しない)。**バケツリレーを先回りして作らない。**
- 読み込み中・エラーの表示はページの責務。空状態の表示は、その空の一覧を持つ
  widget / entity 側に置く。

---

## 5. ルーティングディレクトリと分ける

`src/routes/`(TanStack Router)や Next.js の `app/` は **FSD レイヤーではない**。

```typescript
// src/routes/projects/$projectId.tsx — 薄く保つ
import { ProjectDetailPage } from "@/pages/project-detail";

export const Route = createFileRoute("/projects/$projectId")({
  component: ProjectDetailPage,
  validateSearch: searchSchema,
});
```

- ルートファイルに書くのは、**ルート定義・パラメータ検証・component の指定**まで。
- 画面の中身は必ず `pages` のスライスに置く。ルートファイルから
  `widgets` / `features` / `entities` を直接 import しない。
- 生成ファイル(`routeTree.gen.ts`)は編集しない。

---

## 6. 太ってきたときの切り出し先

上から順に検討する。

1. そのページ専用のブロック → `pages/<page>/ui/` にファイルを分ける(レイヤーは動かさない)。
2. **2 ページ目**で同じ塊を使う → `widgets/` へ引き上げる。
3. ユーザーの操作が混ざっている → `features/` へ抜く(動詞で名前が付く単位)。
4. 業務データの型・表示・取得 → `entities/` へ。

**1 を飛ばして先に widget を作らない。** 1 ページ専用のまま終わるブロックは多い。

---

## アンチパターン

| アンチパターン | なぜ悪いか |
| --- | --- |
| ページに業務ロジックを書く | 他の画面から再利用できず、テストもページ経由になる |
| ルートファイルに画面の中身を書く | ルーティングライブラリを替えられなくなる。FSD の外にロジックが出る |
| ルートファイルから features / entities を直接 import する | pages を飛ばした依存ができ、画面の入口が 2 つになる |
| URL パラメータを検証せず下位へ渡す | 不正な値が entity / feature まで届く |
| 復元されるべき状態を URL に載せない | リロード・共有で画面が再現できない |
| ページが取ったデータを props でバケツリレーする | 中間層が全部そのデータに依存する |
| ページ専用ブロックを最初から widget にする | 使われないスライスが増える |
| ページごとにステータスの enum を再定義する | entity の定義とずれる |
| 空状態の表示をページに書く | 一覧を持つ側と分かれ、表示の条件が二重になる |

---

## ルール(チェックリスト)

- [ ] スライスが **URL 1 つ**に対応しているか
- [ ] ページの ui が配置とレイアウトに徹し、業務ロジックを持っていないか
- [ ] ルートパラメータ・検索パラメータを**入口で検証**しているか
- [ ] 復元されるべき状態が URL に載っているか
- [ ] ステータス等の業務語彙を entity から借りているか(再定義していないか)
- [ ] データ取得の**定義**は entity 側、**開始のタイミング**だけページが決めているか
- [ ] 不要な props バケツリレーを作っていないか
- [ ] ルートファイルが薄く、`pages` のスライスだけを import しているか
- [ ] 生成ファイルを手で編集していないか
- [ ] 切り出し先を「ページ専用 → widget → feature / entity」の順で検討したか
