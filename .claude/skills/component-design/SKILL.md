---
name: component-design
description: モジュール・パッケージ間の依存関係を設計する指針。循環 import が出たとき、モジュール分割やディレクトリ構成を決めるとき、どの app にコードを置くか迷うとき、変更のたびに無関係なモジュールが壊れるときに使う。扱う範囲は何を同じモジュールに入れるかの凝集性(再利用/変更理由/共倒れ)、循環依存の検出と 4 通りの解消法、安定度と抽象度の対応(依存は安定した方向へ)、Django app 間の依存とレイヤ違反の検出、依存グラフの測り方。
allowed-tools:
  - Read
  - Grep
  - Glob
---

# コンポーネント設計 (Component Design)

**クラスの中の設計ではなく、モジュール(パッケージ・Django app)の間の設計。**
[solid-principles](../solid-principles/SKILL.md) が個々のクラスを扱うのに対し、
ここは**依存グラフの形**を扱う。

層(domain / usecases / infrastructure)の分け方は
[ddd-application-layer](../ddd-application-layer/SKILL.md)、
業務上の境界(コンテキスト)は
[ddd-bounded-context](../ddd-bounded-context/SKILL.md)。
ここは**その内部で、どのモジュールに何を置くか**。

---

## 1. 何を同じモジュールに入れるか(凝集性)

3 つの基準があり、**同時には満たせない**。どれを優先するか決める。

| 基準 | 内容 | 効くとき |
| --- | --- | --- |
| **一緒に変わるものを一緒に** | 同じ理由で変更されるものを 1 モジュールに | **既定。これを優先する** |
| **一緒に使われるものを一緒に** | 片方だけ使う場面がないものを 1 つに | 利用者が外部にいるとき |
| 再利用の単位で切る | 独立して配布・バージョン管理できる単位 | ライブラリを作るとき |

**アプリケーション開発では 1 つ目が優先。** 「変更のたびに複数モジュールを触る」
状態が最も痛い。ライブラリ開発では 3 つ目が優先になる。

判定: **「この変更で触るファイルは何個か」**。1 つの業務変更で 5 モジュール触るなら、
凝集性が壊れている。

```text
NG: 技術種別で切る(変更のたびに全部触る)
  models/order.py, models/customer.py
  serializers/order.py, serializers/customer.py
  views/order.py, views/customer.py
  → 「注文に項目を1つ足す」で 3 ディレクトリを触る

OK: 関心で切り、その中で層を分ける
  sales/domain/order.py
  sales/usecases/place_order.py
  sales/interfaces/views.py
  → 注文の変更は sales/ に閉じる
```

**層(layer)で切るか関心(feature)で切るかは、上位で関心、下位で層**が扱いやすい。

---

## 2. 循環依存を作らない

**モジュール A → B → A の循環は、どこからも独立してテスト・変更できなくする。**
Python では実行時に `ImportError` として現れることもあるが、
**動いていても設計上は壊れている**。

### 検出

```bash
# 直接的な相互 import を探す
grep -rn "^from sales\|^import sales" src/billing/ | head
grep -rn "^from billing\|^import billing" src/sales/ | head
# 両方に出たら循環

# ツールを使うなら(いずれか)
pydeps src --show-cycles
python -m pylint --disable=all --enable=cyclic-import src/
```

**`TYPE_CHECKING` での回避は循環を消していない。** 型注釈のためだけなら妥当だが、
実行時の依存が残っているなら設計を直す。

```python
# これは「型のためだけ」なので許容
from typing import TYPE_CHECKING
if TYPE_CHECKING:
    from billing.models import Invoice
```

### 解消の 4 通り

| 方法 | やること | 使いどころ |
| --- | --- | --- |
| **依存性逆転** | 片方に抽象を置き、もう片方が実装する | **既定。最も汎用的** |
| **共通部分を第 3 のモジュールへ** | 両方が使うものを下位モジュールに抽出 | 共有される概念が実在するとき |
| **イベントで切る** | 直接呼び出しをドメインイベントに置き換える | 業務上「〜したら〜する」の関係 |
| **統合する** | そもそも分けるべきでなかった | 常に一緒に変更されるとき |

```python
# Before: sales → billing → sales の循環
# After(依存性逆転): sales が抽象を持ち、billing が実装する
# sales/domain/ports.py
class InvoiceIssuer(Protocol):
    def issue(self, order_id: OrderId) -> None: ...

# billing/adapters.py  (billing → sales の一方向だけになる)
class DjangoInvoiceIssuer(InvoiceIssuer): ...
```

3 つ目(イベント)は
[ddd-domain-events](../ddd-domain-events/SKILL.md)。
**コンテキストをまたぐ循環は、ほぼ常にイベントで切る。**

---

## 3. 依存は「安定した方向」へ向ける

**安定度 = 変えにくさ。** 多くのモジュールから依存されているものは、変えると
影響が広いので変えにくい = 安定している。

- **不安定なモジュール(よく変わる)が、安定したモジュールに依存する**のは正しい。
- **逆は危険。** 安定したモジュールが不安定なものに依存すると、変更が波及する。

```text
OK:  interfaces(よく変わる) → usecases → domain(安定)
NG:  domain → infrastructure(DB 都合でよく変わる)
```

**安定しているものは抽象的でなければならない。** 変えにくく、かつ具体的だと、
拡張の余地がなくなる。

| 状態 | 意味 | 対処 |
| --- | --- | --- |
| 安定 + 抽象 | 理想。多くが依存し、拡張で対応できる | ドメイン層はここを目指す |
| 不安定 + 具体 | 問題なし。末端の実装 | インフラ層はここでよい |
| **安定 + 具体** | **苦痛**。皆が依存しているのに変更しにくい | 抽象を切り出す |
| 不安定 + 抽象 | 無駄。誰も使わない抽象 | 削る |

**「安定 + 具体」の典型が Django モデル**。全モジュールが import しているのに、
テーブル定義そのものなので変更が重い。ドメインオブジェクトを挟んで
依存を受け止める([ddd-aggregate-repository-boundary](../ddd-aggregate-repository-boundary/SKILL.md))。

---

## 4. Django app 間の依存

**1 コンテキスト = 1 app** を既定にする
([ddd-bounded-context](../ddd-bounded-context/SKILL.md))。その上で:

- **app 間で `domain/` を直接 import しない。** 公開する窓口(usecase / イベント /
  query service)だけを外に見せる。
- **他 app のモデルに `ForeignKey` を張らない。** 張った時点で DB レベルの結合が
  でき、分離できなくなる。id を持つだけにする。
- **共通コードは `common` / `shared` app へ**。ただし**そこに業務ルールを入れない**。
  「どこにも属さないから共通へ」を続けると、`common` が第 2 の巨大モジュールになる。
- **`settings.INSTALLED_APPS` の順序に依存しない。**

### 依存方向の検証

```bash
# ドメイン層が外側を import していないか(レイヤ違反)
grep -rn "^from \(infrastructure\|interfaces\|usecases\)" --include="*.py" src/*/domain/ \
  && echo "レイヤ違反" || echo "OK"

# app 間で domain を直接触っていないか
grep -rn "^from sales\.domain" --include="*.py" src/billing/ \
  && echo "app 境界違反" || echo "OK"
```

CI に入れておくと、レビューで指摘し続ける必要がなくなる。

---

## 5. 分けるかどうかの判断

**モジュールを分けるにはコストがある。** 間接化、import の増加、全体像の把握。

分ける:

- **変更理由が違う**(別々の人・別々のタイミングで変わる)。
- **依存の向きを固定したい**(層、コンテキスト)。
- 片方だけをテスト・再利用したい実績がある。

分けない:

- 常に一緒に変更される。
- 「大きくなったから」だけが理由。
- **将来分けるかもしれない**という予測。

**モノリス内で境界を作ることから始める。** ディレクトリと import ルールで十分。
物理分離(別リポジトリ・別サービス)は、境界が安定してから。
**最初からマイクロサービスに割らない** — 境界を間違えたときの修正コストが跳ね上がる。

---

## アンチパターン

| アンチパターン | なぜ悪いか |
| --- | --- |
| 技術種別(models/ serializers/ views/)でトップレベルを切る | 1 つの業務変更で全ディレクトリを触る |
| 循環依存を `TYPE_CHECKING` や関数内 import で回避する | 実行時の依存が残り、設計は壊れたまま |
| 循環を「動いているから」放置する | 独立してテスト・変更できない |
| ドメイン層がインフラ層を import する | 安定したものが不安定なものに依存している |
| 他 app のモデルに `ForeignKey` | DB レベルで結合し、分離できなくなる |
| 他 app の `domain/` を直接 import | 内部実装への依存。窓口を通す |
| `common` / `utils` に業務ルールを溜める | 第 2 の巨大モジュールになる |
| 「大きいから」でモジュールを割る | 変更理由が同じなら、割ると触る箇所が増える |
| 将来の分割を見越して先に分ける | 起きていない変更にコストを払う |
| 最初からマイクロサービスに割る | 境界を間違えたときの修正コストが跳ね上がる |

---

## ルール(チェックリスト)

- [ ] **一緒に変わるものが同じモジュール**にある(技術種別で切っていない)
- [ ] 1 つの業務変更で触るモジュールが 1〜2 個に収まる
- [ ] **循環依存がない**。grep か pydeps / pylint で確認した
- [ ] 循環を `TYPE_CHECKING` や関数内 import で誤魔化していない
- [ ] 依存が**安定した方向**へ向いている(domain が infrastructure を知らない)
- [ ] 「**安定 + 具体**」のモジュールがない(Django モデルへの直接依存を受け止めている)
- [ ] app 間で他の `domain/` を直接 import していない
- [ ] 他 app のモデルに **`ForeignKey` を張っていない**(id 参照)
- [ ] `common` / `utils` に業務ルールが溜まっていない
- [ ] レイヤ違反・app 境界違反を **grep で検証**できる(できれば CI に入れた)
- [ ] 分割の理由が「変更理由の違い」か「依存の向きの固定」である
- [ ] 物理分離は境界が安定してから判断している
