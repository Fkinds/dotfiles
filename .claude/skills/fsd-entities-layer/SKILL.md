---
name: fsd-entities-layer
description: Feature-Sliced Design (FSD) の entities レイヤーの設計指針。entities にコードを置こうとしているとき、ドメインの型やスキーマの置き場所に迷うとき、entity 同士が参照し合って cross-import になったとき、entity が肥大化してきたときに使う。扱う範囲は業務ドメインの名詞をスライスにする判断、model セグメントでの型・スキーマ・ドメインロジックの持ち方、api セグメントに置く読み取りとキー設計、表示に徹する entity の ui、entity 同士の参照を @x で解く方法、操作(feature)との線引き、entity を作らない判断。
allowed-tools:
  - Read
  - Grep
  - Glob
---

# FSD: entities レイヤー

**業務ドメインの「名詞」を表すスライス。** レイヤーの選び方と依存ルールは
[fsd-layers](../fsd-layers/SKILL.md)。操作(動詞)は
[fsd-features-layer](../fsd-features-layer/SKILL.md)、ドメイン非依存の基盤は
[fsd-shared-layer](../fsd-shared-layer/SKILL.md)。

ドメインオブジェクトの中身の設計(不変条件、値オブジェクト)は
[ddd-domain-object-completeness](../ddd-domain-object-completeness/SKILL.md)。

---

## 1. スライスの単位

**業務の人が使う名詞 1 つにつき 1 スライス。** `project` / `user` / `schedule`。

```text
entities/project/
├── model/
│   ├── types.ts      # Project, ProjectStatus
│   ├── schema.ts     # 実行時検証(Zod 等)
│   └── selectors.ts  # 派生値の算出
├── api/
│   └── queries.ts    # 取得系
├── ui/
│   ├── ProjectCard.tsx
│   └── ProjectStatusBadge.tsx
└── index.ts
```

作る条件:

- **2 つ以上の feature / page から参照される**、または参照されることが確実。
- 型・表示・取得のうち 2 つ以上を持つ。型だけなら `model/` を持つだけの
  スライスでよく、無理に `ui/` を作らない。

作らない判断:

- 1 つの feature の中でしか出てこない名詞 → その feature の `model/` に置く。
- API のレスポンス形をそのまま写しただけのもの → **サーバーの都合であって
  ドメインではない**。使う側で必要な形に変換する。

---

## 2. `model` — 型・スキーマ・ドメインロジック

```typescript
// entities/project/model/types.ts
export type ProjectStatus = "draft" | "active" | "archived";

export type Project = {
  id: ProjectId;
  name: string;
  status: ProjectStatus;
  ownerId: UserId;      // 他 entity は id で持つ
  startsOn: string;
};
```

- **ステータスや区分は文字列リテラルのユニオン**にする。`string` のままだと
  タイプミスが型で止まらない。
- **他の entity はオブジェクトではなく id で持つ。** オブジェクトを埋め込むと
  entity 同士が構造的に癒着する(→ 5 章)。
- 実行時の検証スキーマ(Zod 等)は `model/schema.ts`。サーバーと共有している
  スキーマがあるなら**それを再定義せず import する**。
- 表示名の対応表(`draft` → 「下書き」)は entity の `model` か `config`。
  `shared` には置かない(業務語彙のため)。

置いてよいロジック / いけないロジック:

| 置く | 置かない |
| --- | --- |
| そのデータだけで決まる判定(`isArchived`) | 保存・送信を伴う操作(feature) |
| 派生値の算出(期間の日数、表示用の整形) | 複数 entity をまたぐ手続き(上位レイヤー) |
| 同種データの並び替え・絞り込み条件 | 画面遷移、通知、モーダルの開閉 |

---

## 3. `api` — 読み取り

**entity の `api` は取得(読み取り)まで。** 作成・更新・削除は、それを起こす
feature の `api` に置く。

```typescript
// entities/project/api/queries.ts
export const projectKeys = {
  all: ["projects"] as const,
  detail: (id: ProjectId) => [...projectKeys.all, id] as const,
};

export const projectQuery = (id: ProjectId) => ({
  queryKey: projectKeys.detail(id),
  queryFn: () => httpClient.get(`/projects/${id}`).then(parseProject),
});
```

- **キャッシュキーは entity 側で定義する。** feature 側でミューテーション後に
  無効化するとき、同じキーを参照できる。キー文字列を各所に散らさない。
- 返すのは `model` の型。サーバーのレスポンス形をそのまま外に出さない
  (変換は `api` セグメントの中で終える)。
- `useQuery` を呼ぶフックにするか、クエリ定義(オブジェクト)を export するかは
  どちらでもよいが、**プロジェクト内で片方に統一する**。

---

## 4. `ui` — 表示に徹する

entity の ui は「そのデータを見せる部品」。**操作を持たせない。**

```typescript
// entities/project/ui/ProjectCard.tsx
type Props = {
  project: Project;
  actions?: ReactNode;   // 操作は差し込ませる。自分では知らない
};
```

- ボタンの `onClick` に業務処理を書かない。押したら何が起きるかを知るのは feature。
- 操作を差し込ませたいときは `children` / `actions` のような **slot** を開ける。
  feature 側がそこに自分のボタンを入れる。
- データ取得を自分で行わない(props で受け取る)。取得込みの部品が要るなら、
  それは widget か feature。

---

## 5. entity 同士の参照は `@x`

「Project は User を持つ」は避けられない。**entities 同士に限り** `@x` で解く。

```text
entities/
├── user/
│   ├── @x/
│   │   └── project.ts    # export type { UserPreview } — project にだけ公開
│   └── index.ts
└── project/
    └── model/types.ts    # import type { UserPreview } from "@/entities/user/@x/project"
```

- 公開するのは**相手が必要とする最小の形**(`UserPreview` のような部分型)。
  `User` 全体を渡さない。
- `@x` が 3 つ以上に増えたら、境界の引き方を疑う。同じ集約なら 1 スライスに統合する。
- **代替案を先に検討する。** id だけ持ち、表示に必要な相手のデータは
  上位レイヤーで結合すれば `@x` は不要になることが多い。

---

## アンチパターン

| アンチパターン | なぜ悪いか |
| --- | --- |
| entity の ui にボタンの処理を書く | 表示部品が業務操作を知り、feature の責務を奪う |
| entity の api に作成・更新を置く | 誰がいつ実行するのかが entity 側から見えない |
| 他の entity をオブジェクトのまま埋め込む | 構造が癒着し、片方だけ変更できなくなる |
| API レスポンス型をそのまま `model` の型にする | サーバーの都合がドメインの語彙になる |
| ステータスを `string` で持つ | タイプミスが型で止まらない |
| キャッシュキーを feature 側で組み立てる | 無効化のキーがずれ、更新が画面に反映されない |
| entity が feature / widget を import する | 依存の逆流。entity が単独で使えなくなる |
| `@x` を features 同士で使う | cross-import の追認。上位レイヤーで合成する |
| 1 つの feature でしか使わない名詞を entity にする | 使われないスライスが増え、変更コストだけが残る |
| 表示名の対応表を `shared` に置く | 業務語彙が shared に漏れる |

---

## ルール(チェックリスト)

- [ ] そのスライスは**業務の人が使う名詞**か。2 か所以上から参照されるか
- [ ] ステータス・区分がリテラルユニオンになっているか
- [ ] 他の entity を **id で** 参照しているか
- [ ] `model` のロジックが、そのデータだけで決まる判定・派生値に収まっているか
- [ ] `api` が**読み取りだけ**か。更新系が混ざっていないか
- [ ] キャッシュキーが entity 側で定義され、feature から参照されているか
- [ ] サーバーのレスポンス形を `api` の外に漏らしていないか
- [ ] `ui` が props だけで動き、操作は slot で差し込ませているか
- [ ] `@x` は entities 同士に限られ、最小の部分型だけを公開しているか
- [ ] 上位レイヤー(features / widgets / pages)を import していないか
