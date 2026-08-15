---
name: fsd-app-layer
description: Feature-Sliced Design (FSD) の app レイヤーの設計指針。app にコードを置こうとしているとき、Provider やルーターの設定を書くとき、グローバルなエラー処理や初期化処理の置き場所に迷うときに使う。扱う範囲はプロバイダの積む順序と依存関係、ルーターの組み立て、テーマとグローバルスタイル、環境変数の検証を含むエントリーポイント、全体を覆う Error Boundary と Suspense の境界、監視や i18n など初期化の副作用の閉じ込め、app が全レイヤーを import できる唯一の場所であること、app にロジックを置かないこと。
---

# FSD: app レイヤー

**アプリを起動し、全画面に効く設定を配る場所。** レイヤーの選び方と依存ルールは
[fsd-layers](../fsd-layers/SKILL.md)。配られる先は
[fsd-pages-layer](../fsd-pages-layer/SKILL.md)。

`app` は**全レイヤーを import できる唯一の場所**であり、**どこからも import されない**。

---

## 1. 構成

`shared` と同じくスライスを持たず、セグメント直下に置く。

```text
app/
├── providers/        # Provider の組み立て
│   └── AppProvider.tsx
├── router/           # ルーターの生成・設定
├── styles/           # リセット CSS、グローバルスタイル
├── config/           # テーマ定義、QueryClient の設定値
└── index.tsx         # ルート要素のマウント
```

置くもの: **アプリを 1 回起動するために必要なもの**だけ。
1 つでも画面が固有に必要とするものが混ざったら、それは `pages` 以下。

---

## 2. Provider の積み方

**依存の外側から順に積む。** 内側の Provider は外側のコンテキストを使える。

```typescript
// app/providers/AppProvider.tsx
export function AppProvider({ children }: { children: ReactNode }) {
  return (
    <ErrorBoundary fallback={<AppErrorScreen />}>
      <QueryClientProvider client={queryClient}>
        <ThemeProvider theme={theme}>
          <CssBaseline />
          {children}
        </ThemeProvider>
      </QueryClientProvider>
    </ErrorBoundary>
  );
}
```

順序の原則:

| 位置 | 入るもの | 理由 |
| --- | --- | --- |
| 最外 | Error Boundary | 内側すべての例外を受ける |
| 外 | データ取得(QueryClient)、認証 | 他の Provider から参照されうる |
| 内 | テーマ、i18n、トースト | 表示の都合。データ層に依存しない |
| 最内 | ルーター | 画面はすべての文脈を使える |

- **Provider を 1 つずつ `index.tsx` に並べない。** `AppProvider` にまとめると、
  テストや Storybook から同じ文脈を再現できる。
- `QueryClient` は**モジュールのトップレベルで 1 回だけ生成**する。
  コンポーネント内で作ると再レンダリングのたびにキャッシュが消える。

---

## 3. エントリーポイントと環境変数

```typescript
// app/index.tsx
import { env } from "@/shared/config";   // 読み込み時に検証される

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <AppProvider>
      <RouterProvider router={router} />
    </AppProvider>
  </StrictMode>,
);
```

- 環境変数を**読むのは `shared/config`**、それを使って初期化するのが `app`
  ([fsd-shared-layer](../fsd-shared-layer/SKILL.md))。`app` に
  `import.meta.env` を直接書かない。
- 起動時に検証して落とす。設定漏れは画面が出る前に分かる方がよい。

---

## 4. 初期化の副作用を閉じ込める

エラー監視、分析、モックサーバー、i18n の初期化は **`app` で 1 回だけ**呼ぶ。

```typescript
// app/index.tsx
if (import.meta.env.DEV) {
  const { worker } = await import("./mocks/browser");
  await worker.start();
}
```

- 各レイヤーが「使うときに初期化する」形にしない。呼ばれる回数と順序が読めなくなる。
- 開発時だけのものは動的 import にし、本番のバンドルに含めない。
- グローバルなイベント購読(オフライン検知、認証切れの検知)もここ。解除も同じ場所に書く。

---

## 5. エラーと待機の境界

**全体を覆う境界は `app`、画面ごとの境界は `pages`。** 2 段構えにする。

| 境界 | 置き場所 | 出すもの |
| --- | --- | --- |
| アプリ全体 | `app/providers` | 「問題が発生しました」+ 再読み込み。**白画面を出さない**ための最後の砦 |
| 画面ごと | `pages` / ルート定義 | その画面のエラー表示。他の画面へは遷移できる |
| ブロックごと | `widgets` | そのブロックだけ失敗表示。ページは生きたまま |

- `app` の fallback は**下位レイヤーに依存しない**もので書く。エラー画面自体が
  壊れると何も出せなくなる。
- 認証切れのような**全画面共通の分岐**は `app`。個々の API エラーの文言は
  各レイヤーの責務。

---

## 6. `app` に置かないもの

| 置きたくなるもの | 正しい置き場所 |
| --- | --- |
| 共通ヘッダー・サイドバーの実装 | `widgets/`(`app` はレイアウトに組み込むだけ) |
| ルートの一覧・パス定数 | `shared/config`(ルーティング用ディレクトリと `pages` が参照する) |
| HTTP クライアントの生成 | `shared/api` |
| 認証状態の型・取得ロジック | `entities/session` など |
| 「全画面で使うから」という理由の業務ロジック | 対応する entity / feature |

**「全画面で使う」は `app` に置く理由にならない。** `app` は初期化と配布の場所であって、
共有コードの置き場ではない(それは `shared`)。

---

## アンチパターン

| アンチパターン | なぜ悪いか |
| --- | --- |
| `app` に業務ロジックを書く | 再利用もテストもできない位置に固定される |
| ヘッダー・サイドバーの実装を `app` に置く | UI ブロックが最上位に閉じ込められ、差し替えられない |
| Provider を `index.tsx` に直接並べる | テスト・Storybook で同じ文脈を作れない |
| `QueryClient` をコンポーネント内で生成する | 再レンダリングのたびにキャッシュが消える |
| `app` で `import.meta.env` を直接読む | 必要な設定が `shared/config` に一覧されなくなる |
| Error Boundary を最上位にだけ置く | 1 か所の失敗で全画面が落ちる |
| `app` の fallback が下位レイヤーに依存する | エラー画面自体が壊れると何も出せない |
| 初期化を各レイヤーで都度呼ぶ | 呼ばれる回数と順序が読めなくなる |
| 開発用ツールを静的 import する | 本番バンドルに混入する |
| 何かが `app` を import する | 依存の逆流。`app` は誰からも参照されない |

---

## ルール(チェックリスト)

- [ ] `app` にあるのは**アプリを 1 回起動するために必要なもの**だけか
- [ ] スライスを作らず、セグメント直下に置いているか
- [ ] Provider が `AppProvider` にまとまり、**外側から依存順**に積まれているか
- [ ] `QueryClient` などの単一インスタンスがトップレベルで 1 回だけ生成されているか
- [ ] 環境変数の読み取りと検証が `shared/config` にあり、`app` は使うだけか
- [ ] 初期化の副作用が `app` で 1 回だけ呼ばれているか。開発用は動的 import か
- [ ] Error Boundary が**全体 / 画面 / ブロック**の複数段になっているか
- [ ] 全体の fallback が下位レイヤーに依存していないか
- [ ] 共通 UI ブロック・業務ロジック・HTTP クライアントを `app` に置いていないか
- [ ] `app` を import しているファイルが 1 つも無いか
