---
name: fsd-shared-layer
description: Feature-Sliced Design (FSD) の shared レイヤーの設計指針。ドメイン知識を持たないという唯一の判断基準、スライスを持たないセグメント直下構成、UI キット(shared/ui)と外部 UI ライブラリのラップ範囲、MUI などライブラリのバレル import を避けてサブパスから読む方法、HTTP クライアントとエラー正規化(shared/api)、shared/lib の分類と shared/config での環境変数の扱い、セグメント単位の公開、shared がゴミ箱化するのを防ぐ方法を扱う。shared にコードを置こうとしているとき、共通化した部品の置き場所に迷うとき、shared が肥大化してきたとき、UI キットや API クライアントを設計するとき、import が重くビルドが遅いときに使う。
allowed-tools:
  - Read
  - Grep
  - Glob
---

# FSD: shared レイヤー

**業務を何も知らないコードだけが入る。** レイヤーの選び方と依存ルールは
[fsd-layers](../fsd-layers/SKILL.md)。すぐ上の
[fsd-entities-layer](../fsd-entities-layer/SKILL.md) との線引きが最も問われる。

`shared` は全レイヤーが依存する。**ここの変更はアプリ全体に効く。**

---

## 1. 入れてよいかの判断

**この 1 つだけで判定する。**

> このファイルを別のプロジェクトにそのままコピーして、意味が通るか。

通らないなら shared ではない。

| 判定 | 例 |
| --- | --- |
| shared に入る | `Button`, `formatDate`, `httpClient`, `useDebounce`, `ROUTES` |
| 入らない(entities へ) | `ProjectCard`, `projectSchema`, `fetchProjects`, `PROJECT_STATUS` |

境界にあるものの見分け方:

- 業務の**名詞**が型名・変数名・ファイル名に出てきたら shared ではない。
- 特定の API エンドポイントを知っていたら shared ではない
  (**エンドポイントを知らない HTTP クライアント**は shared)。
- 「今のところ 1 か所でしか使っていないが汎用に見える」ものは、**使う場所に置いたまま**にする。
  2 か所目が現れてから下ろす。

---

## 2. スライスを持たない

`shared` と `app` だけはスライスを持たず、**セグメントを直下に置く**。

```text
shared/
├── ui/          # UI キット
├── api/         # 通信基盤
├── lib/         # ユーティリティ
├── config/      # 定数、環境変数
└── types/       # 汎用型(必要なら)
```

`shared/user/` のようなドメイン名のディレクトリを作らない。それはスライスであり、
作りたくなった時点で entities に置くべきものが混ざっている。

---

## 3. 公開はセグメント単位

**`shared/index.ts` を作らない。** 1 枚のバレルにすると、どこか 1 つを import した
だけで shared 全体が読み込まれ、ビルドの分割も効かなくなる。

```typescript
// OK
import { Button } from "@/shared/ui";
import { httpClient } from "@/shared/api";

// NG
import { Button, httpClient } from "@/shared";
```

セグメント配下がさらに大きくなったら、その 1 段下で公開する
(`@/shared/ui/button`)。粒度を上げるのは後からでよい。

---

## 4. `shared/ui` — UI キット

**業務の語彙を持たない表示部品だけ。** `ProjectStatusBadge` は entities、
`Badge` は shared。

```text
shared/ui/
├── button/
│   ├── Button.tsx
│   └── index.ts
├── text-field/
└── index.ts
```

MUI などの UI ライブラリを使っている場合、**全部をラップしない。**

| ラップする | しない |
| --- | --- |
| プロジェクト既定値を毎回書いている(`variant` / `size` / `margin` の固定) | ライブラリのコンポーネントをそのまま使えば済むもの |
| 差し替えの可能性が現実にある | 「いつか差し替えるかも」だけのもの |
| ライブラリに無い組み合わせを作った(`ConfirmDialog` など) | 名前を変えただけの薄い再 export |

ラップしないものは各レイヤーからライブラリを直接 import してよい。
**中身のないラッパーは、追跡すべきファイルを増やすだけ。**

### 外部ライブラリはサブパスから import する

FSD の Public API はバレル(`index.ts`)を前提にするが、**外部ライブラリのバレルは
別問題**。`@mui/material` の入口経由は 2,000 を超えるモジュールを読み込み、
開発時のビルドと初回読み込みを数秒単位で遅くする。

```typescript
// NG — ライブラリのバレル経由
import { Button, TextField } from "@mui/material";

// OK — サブパスから直接
import Button from "@mui/material/Button";
import TextField from "@mui/material/TextField";
```

- Next.js の `optimizePackageImports` に相当する機構は **Vite には無い**。
  ビルド設定で消せないので、import の書き方で避ける。
- **自作スライスのバレルは維持する。** 数個から数十の re-export であり、
  ライブラリの数千 re-export とは桁が違う。Public API の利点が上回る。
- ラップした `shared/ui` の内部でも、ライブラリはサブパスから import する。

`shared/ui` のコンポーネントは:

- サーバーと通信しない(`shared/api` を import しない)。
- グローバル状態を読まない。props と自分の内部状態だけで動く。
- 業務のルールを持たない(「金額が 0 なら赤」は entities の仕事)。

---

## 5. `shared/api` — 通信基盤

置くのは**エンドポイントを知らない土台**。個々のリクエストは entities / features の
`api/` セグメントに置く。

```text
shared/api/
├── client.ts        # baseURL、共通ヘッダ、認証トークンの付与
├── error.ts         # 通信エラー / HTTP エラーを自分の型に正規化する
└── index.ts
```

- **エラーの正規化はここで 1 回だけ行う。** 各所で `res.ok` を判定し直さない。
  RFC 7807 のような形式を使っているなら、その解釈もここに閉じる。
- 認証トークンの付与・リフレッシュもここ。呼び出し側に漏らさない。
- 型生成物(OpenAPI / RPC クライアントの型)の取り込み先もここ。**生成物は編集しない。**
- キャッシュライブラリの `QueryClient` インスタンス生成は `shared/api`、
  Provider として配るのは `app`。

---

## 6. `shared/lib` — ユーティリティ

**`lib/` 直下にファイルを平置きしない。** 用途ごとにディレクトリを切る。

```text
shared/lib/
├── date/          # 日付の整形・比較
├── validation/    # 汎用バリデータ
├── hooks/         # useDebounce, useMediaQuery
└── index.ts
```

- `utils.ts` / `helpers.ts` / `misc.ts` は作らない。**何が入るか決まらない名前**は、
  結果としてあらゆるものを集める。
- 1 か所でしか使わない関数は `lib` に上げず、使う側のスライスの `lib/` に置く。
- 外部ライブラリで済むものを自作しない。

---

## 7. `shared/config` — 定数と環境変数

```typescript
// shared/config/env.ts
const rawApiUrl = import.meta.env.VITE_API_URL;
if (!rawApiUrl) {
  throw new Error("VITE_API_URL が設定されていません");
}
export const env = { apiUrl: rawApiUrl } as const;
```

- **環境変数を読むのはここだけ。** `import.meta.env` / `process.env` が
  他のレイヤーに散らばると、何が必要な設定なのか一覧できなくなる。
- 起動時に検証して落とす。undefined のまま実行時エラーになるより早く分かる。
- ルート定義、ページサイズ、日付フォーマットのような**業務に依らない定数**もここ。
  ステータスの表示名のような業務語彙は entities へ。

---

## アンチパターン

| アンチパターン | なぜ悪いか |
| --- | --- |
| `shared` に業務の名詞が出てくる | 全レイヤーがドメインの一部に依存する。entities の意味がなくなる |
| `shared/user/` のようなスライスを作る | shared はセグメント直下構成。ドメインの混入の始まり |
| `shared/index.ts` に全部まとめる | 1 つ import しただけで shared 全体が読み込まれる |
| UI ライブラリを全部ラップする | 中身のない層が増え、ライブラリのドキュメントが使えなくなる |
| `shared/ui` がデータを取得する | 表示部品が通信に依存し、単体で使えなくなる |
| 各所で `res.ok` を判定し直す | エラー処理の形が場所ごとにずれる。正規化は `shared/api` で 1 回 |
| `shared/lib/utils.ts` | 名前が何も決めていないので、あらゆるものが集まる |
| 1 か所でしか使わない関数を先に `shared` へ置く | 汎用に見えて汎用でない API が固定される |
| `import.meta.env` を各レイヤーで読む | 必要な設定が一覧できず、未設定に実行時まで気付かない |
| 生成された型定義を手で直す | 次の生成で消える |

---

## ルール(チェックリスト)

- [ ] **別プロジェクトにコピーして意味が通るか**。業務の名詞が出ていないか
- [ ] スライスを作らず、セグメント(`ui` / `api` / `lib` / `config`)直下に置いているか
- [ ] `shared/index.ts` を作らず、**セグメント単位**で公開しているか
- [ ] `shared/ui` が通信もグローバル状態の参照もしていないか
- [ ] UI ライブラリのラッパーに、既定値・組み合わせ・差し替えの**実際の理由**があるか
- [ ] 外部ライブラリを**サブパスから** import しているか(バレル経由になっていないか)
- [ ] エンドポイントを知る関数が `shared/api` に入っていないか
- [ ] エラーの正規化が `shared/api` の 1 か所に閉じているか
- [ ] `lib/` が用途別に分かれ、`utils` / `helpers` になっていないか
- [ ] 環境変数の読み取りと検証が `shared/config` だけで行われているか
- [ ] 2 か所目の利用者が現れてから下ろしているか(先回りしていないか)
