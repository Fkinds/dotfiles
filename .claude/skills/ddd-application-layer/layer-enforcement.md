# 層の依存方向を機械的に検査する

[ddd-application-layer](SKILL.md) 第 7 節の実施手段。**「grep で確認する」で終わらせない**
— パターンも除外条件も毎回変わり、見落としても気付けない。同梱スクリプトを CI に入れる。

FSD(TypeScript)側の同じ仕組みは
[fsd-layers](../fsd-layers/SKILL.md) の `enforcement.md`。

## 使う

```bash
python3 scripts/check_layers.py src/                                    # 層だけ
python3 scripts/check_layers.py src/ --layer-root sales --layer-root shipping   # 層 + コンテキスト境界
```

違反があれば `file:line: 説明` を出し、**終了コード 1** で返す。そのまま CI に置ける。

```
src/sales/domain/order.py:1: domain が django.db を import している
src/sales/domain/rel.py:1: domain → usecases は許されていない依存
src/sales/usecases/batch.py:3: usecases → infrastructure は許されていない依存
src/sales/domain/cross.py:1: sales が shipping の domain を import している(コンテキスト境界)
```

`--layer-root` は層ディレクトリを探す親を限定する。付けないと `vendor/domain/` のような
無関係なディレクトリも層とみなし、コンテキスト境界の検査も働かない。**基本は付ける。**

## 何を検査するか

スクリプト冒頭の 2 つの辞書がすべて。**プロジェクトの層名に合わせて書き換える。**

```python
LAYERS = {
    "domain":         set(),                                    # 何も見ない
    "usecases":       {"domain"},
    "infrastructure": {"domain", "usecases"},                   # 抽象を実装するので内側を見てよい
    "interfaces":     {"domain", "usecases", "infrastructure"},
}
FORBIDDEN_PACKAGES = {
    "domain":   {"django", "rest_framework"},
    "usecases": {"rest_framework"},   # django.db.transaction は境界のため許す
}
```

**`--layer-root` を渡すと、コンテキスト境界も検査する。** 渡した名前をコンテキスト(app)と
みなし、`sales/domain` が `shipping/domain` を import していたら落とす
([ddd-bounded-context](../ddd-bounded-context/SKILL.md))。禁じるのは domain 同士だけで、
`sales/interfaces` から `shipping/usecases` を呼ぶのは通す。**渡さないとこの検査は働かない。**

`FORBIDDEN_PACKAGES` は前方一致。`domain` に `django` を入れると `django.db` も
`django.conf` も落ちる。`usecases` から `django` を外してあるのは、トランザクション境界が
usecase にあるため(第 3 節)。`UnitOfWork` 抽象で包むなら、ここに `django` を足して
締めきれる。

## CI に入れる

```yaml
- name: 層の依存方向
  run: python3 scripts/check_layers.py src/ --layer-root sales
```

依存パッケージなし(標準ライブラリのみ、Python 3.10+)。`pip install` も設定ファイルも要らない。

## 検出できないこと

機械検査は**構文上の import** しか見ない。以下は素通りするので、レビューで見る。

| 抜け道 | 例 |
| --- | --- |
| 動的 import | `importlib.import_module("infrastructure.repo")` |
| 文字列越しの参照 | Django の `"sales.infrastructure.RepoModel"` のような設定値 |
| 引数で渡された具象 | composition root が内側へ具象を渡していても import は出ない |


**逆に、`TYPE_CHECKING` 下の import も違反として出る。** 実行時に評価されなくても、
型がその層を知っている時点で依存なので、これは仕様。外したいなら
`imported_names()` で `ast.If` の中を除外する。

## 本格的にやるなら

契約をもっと細かく書きたくなったら、Python には `import-linter` という専用ツールがある
(層の順序や禁止関係を宣言的に書ける)。**まず同梱スクリプトを CI に入れてから**、
足りなくなった時点で移る。設定ファイルを 1 つ増やす前に、検査が回っている状態を作る方が先。
