---
name: aube
description: |
  Use when working with the Node.js package manager `aube` (replaces pnpm/npm/yarn).
  Triggers: invocation of `aube`, `aubr`, `aubx`; presence of `aube-lock.yaml`; user mentions "aube"
  or migrating from pnpm/npm/yarn to aube; editing Dockerfiles, CI workflows, or scripts that install
  Node dependencies in this project. Skip for repos using pnpm/npm/yarn directly with no aube intent.
---

# aube — 運用ルール

aube は Node.js のパッケージマネージャ。既存の `pnpm-lock.yaml` / `yarn.lock` /
`package-lock.json` をその場で読み書きするので、ロックファイル形式を変えずに導入できる。

**コマンド一覧・インストール手順・設定項目の網羅は公式に委ねる**(末尾の References)。
ここには、公式を読んでも分からない**この環境の決めごとと落とし穴**だけを置く。

## 落とし穴: `aubr` は自動インストールする

`aubr <script>`(= `aube run`)は、`package.json` かロックファイルが前回の install から
変わっているときだけ自動で install してから走る。

```sh
# NG: pnpm の手順をそのまま翻訳した
aube install && aube run build

# OK: aubr が必要なときだけ install する
aubr build
```

`pnpm install && pnpm run X` を機械的に `aube install && aube run X` に置き換えない。

## セキュリティ設定

`paranoid=true` が主要なゲートを一括で有効にする。**それでも覆われない項目**があるので、
この環境では以下も明示的に有効にする。

| 設定 | 値 | なぜ paranoid だけでは足りないか |
|---|---|---|
| `advisoryCheckOnInstall` | `required` | paranoid は新規解決しか見ない。素の再インストールも OSV に当てる |
| `advisoryCheckEveryInstall` | `true` | frozen な再インストールでも実際に OSV API を叩く |
| `advisoryBloomCheck` | `required` | 全 install 経路に bloom filter の前段チェックを入れる |
| `lowDownloadThreshold` | `10000`+ | ロングテール / typosquat をより広く弾く |
| `strictPeerDependencies` | `true` | peer の欠落・不整合で install を失敗させる |
| `dangerouslyAllowAllBuilds` | `false` | build script を自動承認させない |
| `strictSsl` | `true` | TLS 検証を飛ばさせない |

プロジェクト直下の `.npmrc`:

```
paranoid=true
advisoryCheck=required
advisoryCheckOnInstall=required
advisoryCheckEveryInstall=true
advisoryBloomCheck=required
lowDownloadThreshold=10000
blockExoticSubdeps=true
strictStoreIntegrity=true
verifyStoreIntegrity=true
strictStorePkgContentCheck=true
trustPolicy=no-downgrade
preferFrozenLockfile=true
strictPeerDependencies=true
strictSsl=true
dangerouslyAllowAllBuilds=false
```

### build script の承認はコミットする

`strictDepBuilds=true` の下では、lifecycle script を持つ依存があると install が失敗する。
中身を確認してから明示的に承認する。

```sh
aube approve-builds              # 対話で選ぶ
aube approve-builds esbuild      # 個別に承認
```

承認は `aube-workspace.yaml`(なければ `pnpm-workspace.yaml`)の `allowBuilds:` に書かれる。
**このファイルをコミットする** — CI と他の開発者が同じ許可リストを使うため。

jail された build に個別の権限を足す場合も同じファイルに書く:

```yaml
jailBuildPermissions:
  sharp:
    env: [SHARP_DIST_BASE_URL]
    read: [~/.cache/node-gyp]
    write: [~/.cache/sharp]
    network: true
```

## CI での固定

- **`endevco/aube-action` は `@v1` ではなくコミット SHA で固定する。** タグは動く。
- **`version:` も `latest` ではなく厳密なリリース**(例 `1.16.0`)を指定する。
- **Dockerfile で `@endevco/aube` をグローバル導入するときは非 root ユーザーで。**
  postinstall がプラットフォーム別バイナリを取りに行くため、root だとそのまま root で走る。

## このリポジトリでの決めごと

- フロントエンドは `client/vue-workspace/sample-vue/`。
- ロックファイルは `pnpm-lock.yaml` のまま(aube がその場で読み書きする)。
  `aube-lock.yaml` へは移行しない — pnpm に慣れたレビュアーが差分を読めるようにするため。
- CI の依存インストールは `endevco/aube-action@v1`
  (`.github/actions/setup-frontend/action.yml`)。
- Docker イメージは npm で aube をグローバル導入してから `aube install`。
- `package.json` から呼ぶスクリプトは `aubr <script>` の形。

## References

- Guide: https://aube.en.dev/guide/
- pnpm からの対応表: https://aube.en.dev/pnpm-users
- CLI リファレンス: https://aube.en.dev/cli/
- ロックファイル: https://aube.en.dev/package-manager/lockfiles
- セキュリティ: https://aube.en.dev/security
- Repo: https://github.com/endevco/aube
