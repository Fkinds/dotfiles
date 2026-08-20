# FSD の依存ルールを機械的に検査する

人力のレビューでは維持できない。CI で落ちる仕組みにする。

3 つのうち、**まず 1 つ**入れる。全部は要らない。

| ツール | 検査できること | 向き |
| --- | --- | --- |
| steiger | FSD 固有の規約全般(レイヤー、Public API、命名、未使用スライス) | FSD 専用。導入が最も速い |
| dependency-cruiser | import の方向を正規表現で任意に定義 | 既に使っている / server 側と同じ仕組みにしたい |
| eslint-plugin-boundaries | 同上を ESLint 上で。エディタ上に即出る | 開発中に気付かせたい |

各ツールの設定例をこの順で載せ、最後に**どれを選んでも要る「生成物とルーティング
ディレクトリの除外」**(末尾)を扱う。

---

## steiger(FSD 公式の linter)

```bash
pnpm add -D steiger @feature-sliced/steiger-plugin
```

```javascript
// steiger.config.js
import { defineConfig } from "steiger";
import fsd from "@feature-sliced/steiger-plugin";

export default defineConfig([
  ...fsd.configs.recommended,
  {
    files: ["./src/shared/**"],
    rules: {
      // shared は Public API を持たないセグメント構成なので除外する
      "fsd/public-api": "off",
    },
  },
  {
    ignores: ["./src/routes/**", "**/*.gen.ts"],
  },
]);
```

```bash
pnpm steiger ./src          # 検査
pnpm steiger ./src --watch  # 開発中
```

主なルール: `fsd/forbidden-imports`(依存方向・cross-import) /
`fsd/public-api`(index.ts の有無) / `fsd/no-segmentless-slices` /
`fsd/no-reserved-folder-names` / `fsd/insignificant-slice`(1 か所からしか
使われないスライス) / `fsd/repetitive-naming`。

導入直後は既存違反が大量に出る。すぐ直せないルールは値を `"warn"` に落として
件数を記録し、**増やさない**運用から始める。

```javascript
{
  rules: {
    "fsd/insignificant-slice": "warn",
    "fsd/repetitive-naming": "off",
  },
}
```

---

## dependency-cruiser

レイヤーに順位を振り、3 つのルールに分ける。**逆流**・**cross-import**・
**Public API の迂回**は条件が違うので、1 つのルールにまとめない。

```javascript
// .dependency-cruiser.js
const SRC = "^client/src";
const LAYERS = ["app", "pages", "widgets", "features", "entities", "shared"];
const SLICED = "pages|widgets|features|entities"; // スライスを持つレイヤー

export default {
  forbidden: [
    // 1. 逆流 — 自分より上位のレイヤーを参照しない(app は最上位なので対象外)
    ...LAYERS.slice(1).map((layer, i) => ({
      name: `fsd-no-upward-from-${layer}`,
      severity: "error",
      comment: `${layer} は自分より下位のレイヤーだけを参照できる`,
      from: { path: `${SRC}/${layer}/` },
      to: { path: `${SRC}/(${LAYERS.slice(0, i + 1).join("|")})/` },
    })),

    // 2. cross-import — 同一レイヤーの「別」スライスを参照しない
    {
      name: "fsd-no-cross-import",
      severity: "error",
      comment: "同一レイヤーのスライス間 import は禁止。下位へ下ろすか上位で合成する",
      from: { path: `${SRC}/(?<layer>${SLICED})/(?<slice>[^/]+)/` },
      to: {
        path: `${SRC}/$<layer>/[^/]+/`,
        pathNot: [
          `${SRC}/$<layer>/$<slice>/`, // 自分自身のスライスは可
          `${SRC}/entities/[^/]+/@x/`, // entities の @x は例外
        ],
      },
    },

    // 3. Public API の迂回 — 他スライスの内部セグメントを直接参照しない
    {
      name: "fsd-no-deep-import",
      severity: "error",
      comment: "スライスの index.ts を経由すること",
      from: { path: `${SRC}/(?<layer>${SLICED})/(?<slice>[^/]+)/` },
      to: {
        path: `${SRC}/(${SLICED})/[^/]+/(ui|model|api|lib|config)/`,
        pathNot: `${SRC}/$<layer>/$<slice>/`,
      },
    },
  ],
  options: {
    doNotFollow: { path: "node_modules" },
    exclude: { path: "(\\.gen\\.ts$|^client/src/routes/)" },
    tsConfig: { fileName: "client/tsconfig.json" },
  },
};
```

要点は 2 つ。

- 逆流ルールの `to` に**自分のレイヤーを含めない**(`slice(0, i + 1)` は自分より
  上位まで)。含めると同一スライス内の import が全部違反になる。
- cross-import と deep-import は、名前付きキャプチャ(`$<layer>` / `$<slice>`)を
  `pathNot` で参照して**自分自身のスライスを除外**する。dependency-cruiser は
  `to` 側で `from` のキャプチャを後方参照できる。

```bash
pnpm depcruise client/src --config .dependency-cruiser.js
```

---

## eslint-plugin-boundaries

```javascript
// eslint.config.js
import boundaries from "eslint-plugin-boundaries";

const LAYERS = ["app", "pages", "widgets", "features", "entities", "shared"];
const FLAT = ["app", "shared"]; // スライスを持たない。レイヤー全体で 1 要素

export default [
  {
    files: ["client/src/**/*.{ts,tsx}"],
    plugins: { boundaries },
    settings: {
      "boundaries/elements": LAYERS.map((type) => ({
        type,
        // スライスを持つレイヤーはスライス 1 つが 1 要素
        pattern: FLAT.includes(type)
          ? `client/src/${type}`
          : `client/src/${type}/*`,
        mode: "folder",
      })),
    },
    rules: {
      "boundaries/element-types": [
        "error",
        {
          default: "disallow",
          rules: LAYERS.map((from, i) => ({
            from,
            allow: LAYERS.slice(i + 1), // 自分より下位のみ
          })),
        },
      ],
    },
  },
];
```

`pattern` の切り方が要点。`app` / `shared` を `*` 付きにすると
`shared/ui` と `shared/lib` が別要素として扱われ、**同一レイヤー内の正当な
import が違反になる**。同一要素の中は検査対象外なので、スライスを持つ
レイヤーだけ `*` を付ける。

エディタ上で即座に出るのが利点。CI では steiger か dependency-cruiser の
どちらかと併用する。

---

## 生成物とルーティングディレクトリの除外

3 ツールとも、次を検査対象から外す。

- `**/*.gen.ts`(routeTree.gen.ts、OpenAPI 生成物)
- ルーティングライブラリ用のディレクトリ(`src/routes/`)

除外したことで「routes から features を直接叩く」抜け道ができる。routes 側は
`pages` のスライスだけを import する規約にし、そこは別ルールで縛る。

```javascript
{
  name: "routes-only-imports-pages",
  severity: "error",
  from: { path: "^client/src/routes/" },
  to: { path: "^client/src/(widgets|features|entities)/" },
}
```
