---
name: fsd-features-layer
description: Feature-Sliced Design (FSD) の features レイヤーの設計指針。features にコードを置こうとしているとき、フォームや送信処理の置き場所に迷うとき、feature 同士が参照し合ったとき、feature が肥大化してきたときに使う。扱う範囲はユーザー操作を「動詞」でスライスに切る判断と粒度、ui にアクションの起点だけを置く構成、api での更新系とキャッシュ無効化、model でのフォーム状態と送信状態の一元管理、feature 同士の cross-import を上位での合成や下位への移動で解く方法、feature を作らない判断。
allowed-tools:
  - Read
  - Grep
  - Glob
---

# FSD: features レイヤー

**ユーザーが起こす「操作」1 つが 1 スライス。** レイヤーの選び方と依存ルールは
[fsd-layers](../fsd-layers/SKILL.md)。操作の対象となる名詞は
[fsd-entities-layer](../fsd-entities-layer/SKILL.md)、feature を束ねる先は
[fsd-widgets-layer](../fsd-widgets-layer/SKILL.md)。

---

## 1. スライスの単位

**動詞で言い切れるか。** 言い切れないなら feature ではない。

| feature になる | ならない |
| --- | --- |
| `create-project`(案件を作成する) | `project-management`(名詞。範囲が無限に広がる) |
| `filter-project-list`(一覧を絞り込む) | `project-form`(部品名。何をする操作か不明) |
| `auth-by-password`(パスワードで認証する) | `auth`(操作が複数入る。ログイン/ログアウト/更新) |

粒度は **1 操作 1 スライス**。`login` と `logout` は別のスライスにする。
同じ画面に出るという理由で 1 つにまとめない(それは widget の仕事)。

```text
features/create-project/
├── ui/
│   └── CreateProjectForm.tsx   # 操作の起点となる UI
├── model/
│   └── useCreateProject.ts     # 送信状態、入力の検証
├── api/
│   └── createProject.ts        # 更新リクエスト
└── index.ts
```

### 作らない判断

- **表示するだけ**なら feature は不要。entity の ui を page / widget に置けば済む。
- 画面遷移するだけのリンクは feature ではない。
- 1 つの page でしか使わず、今後も使い回さない操作は、その page の `ui/` に
  書いたままでよい。2 か所目が現れてから切り出す。

---

## 2. `ui` — 操作の起点だけ

feature の ui は「その操作を起こすための UI」。**対象データの表示は entity から借りる。**

```typescript
// features/create-project/ui/CreateProjectForm.tsx
import { Button, TextField } from "@/shared/ui";
import { useCreateProject } from "../model/useCreateProject";
```

- 入力欄・ボタン・確認ダイアログは feature の ui。
- 対象の一覧やカードの見た目は entity の ui を使う(自分で書き直さない)。
- **レイアウトの都合を持ち込まない。** 配置は置き場所(page / widget)が決める。
  feature は幅・余白・グリッドを固定しない。

---

## 3. `api` — 更新系とキャッシュ無効化

**作成・更新・削除は feature の `api`。** 読み取りは entity の `api`
([fsd-entities-layer](../fsd-entities-layer/SKILL.md))。

```typescript
// features/create-project/model/useCreateProject.ts
import { projectKeys } from "@/entities/project";

export function useCreateProject() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: createProject,
    onSuccess: () => queryClient.invalidateQueries({ queryKey: projectKeys.all }),
  });
}
```

- 無効化のキーは **entity が公開しているものを使う**。文字列を組み立て直さない。
- 成功後の画面遷移・トースト表示は **feature に書かない**。呼び出し側
  (page / widget)へ `onSuccess` として渡す。同じ操作が別の画面で別の後処理を
  必要とするため。

---

## 4. `model` — 状態は 1 本にまとめる

送信の状態を独立した複数の `useState` で持たない。**組み合わせで矛盾が作れる形にしない。**

```typescript
// NG — loading と error と result が同時に真になりうる
const [loading, setLoading] = useState(false);
const [error, setError] = useState<string | null>(null);
const [result, setResult] = useState<Project | null>(null);

// OK — 取りうる状態が型で閉じている
type SubmitState =
  | { status: "idle" }
  | { status: "submitting" }
  | { status: "success"; project: Project }
  | { status: "error"; message: string };
```

- サーバー由来の状態は自前の `useState` に写し取らない。データ取得ライブラリを
  使っているなら、その状態(`isPending` / `error` / `data`)をそのまま読む。
  **二重に持つと必ずずれる。**
- 入力中の検証は補助。**最終判断はサーバー**という前提を崩さない。
- 多重送信のガード(送信中はボタンを `disabled`)を入れる。
- エラーは握り潰さない。`catch` して `console.log` だけで終えると、
  ユーザーには何も起きていないように見える。

---

## 5. feature 同士は参照しない

`features/a` から `features/b` を import した時点で違反。直し方は 3 つ
([fsd-layers](../fsd-layers/SKILL.md) と同じ)。

| 状況 | 直し方 |
| --- | --- |
| 共通の入力部品・検証を使い回したい | `shared/ui` か対象 entity へ**下ろす** |
| 2 つの操作を並べたい・連続させたい | widget / page で**合成する**(片方の `onSuccess` でもう片方を呼ぶ) |
| 実は 1 つの操作だった | **1 スライスに統合する** |

**features 同士に `@x` は使わない。** `@x` は entities 専用。features で使いたく
なったのは、上位で合成すべきものを下位で繋ごうとしている合図。

---

## アンチパターン

| アンチパターン | なぜ悪いか |
| --- | --- |
| スライス名が名詞(`project-management`) | 範囲が定まらず、あらゆる操作が集まる |
| 1 スライスに複数の操作を入れる | 片方だけ使いたい画面で、要らない依存まで付いてくる |
| feature が対象データの表示を自前で書く | entity の ui と二重になり、見た目がずれていく |
| feature 内で画面遷移やトーストを実行する | 別の画面から使えなくなる。後処理は呼び出し側の関心 |
| `loading` / `error` / `result` を別々の `useState` で持つ | 矛盾した組み合わせが作れる。前回の結果が残る |
| サーバー状態を `useState` に写し取る | 二重管理でずれる。無効化しても画面が古いまま |
| 無効化のキーを feature 側で組み立てる | entity 側のキーとずれ、更新が反映されない |
| `catch` で `console.log` だけして終わる | 失敗がユーザーに伝わらない |
| feature 同士を import する / `@x` で繋ぐ | 独立して削除・移動できなくなる |
| feature がレイアウト(幅・余白)を固定する | 置き場所によって崩れ、上位が調整できない |

---

## ルール(チェックリスト)

- [ ] スライス名が**動詞**で、1 スライス 1 操作になっているか
- [ ] 表示するだけの機能を feature にしていないか
- [ ] 対象データの表示を entity の ui から借りているか
- [ ] 更新系が feature の `api`、読み取りが entity の `api` に分かれているか
- [ ] キャッシュ無効化のキーを entity から参照しているか
- [ ] 成功後の遷移・通知を呼び出し側に渡しているか
- [ ] 送信状態が**判別可能なユニオン 1 本**で、矛盾する組み合わせを作れないか
- [ ] サーバー状態を自前の `useState` に写していないか
- [ ] エラーがユーザーに伝わる形で扱われているか(握り潰していないか)
- [ ] 多重送信のガードがあるか
- [ ] 他の feature を import していないか(`@x` を使っていないか)
