---
name: ddd-aggregate-repository-boundary
description: 集約(Aggregate)の境界の引き方と、リポジトリを介した永続化の設計指針。整合性境界としての集約、集約を小さく保つ判断、集約ルート単位のリポジトリ、ドメイン層に置くインターフェースとインフラ層の実装(依存性逆転)、永続化モデルとドメインオブジェクトのマッピング、復元時の不変条件、同時実行制御を扱う。集約の切り方に迷ったとき、リポジトリを設計・レビューするとき、1 トランザクションで複数の集約を更新したくなったとき、Django モデルとドメインオブジェクトの対応を決めるときに使う。
allowed-tools:
  - Read
  - Grep
  - Glob
---

# DDD: 集約とリポジトリの境界 (Aggregate & Repository Boundary)

集約を**どこで切るか**と、それを**どう永続化するか**。

前提: Python 標準ライブラリの `dataclasses`。ドメイン層は **stdlib のみ**に依存し、
フレームワーク(Django 等)にも外部ライブラリにも依存しない。

集約内部のオブジェクト設計(不変条件、値オブジェクト、エンティティ)は
[ddd-domain-object-completeness](../ddd-domain-object-completeness/SKILL.md)、
集約をまたぐ整合性は
[ddd-domain-events](../ddd-domain-events/SKILL.md)、
リポジトリを呼び出してトランザクションを張る側は
[ddd-application-layer](../ddd-application-layer/SKILL.md)、
検索・一覧などの読み取りは
[ddd-read-model-cqrs](../ddd-read-model-cqrs/SKILL.md)。
そもそもどのコンテキストに属する集約かは
[ddd-bounded-context](../ddd-bounded-context/SKILL.md)、
境界を引く材料(不変条件)を業務から引き出す工程は
[ddd-modeling-discovery](../ddd-modeling-discovery/SKILL.md)。
Django 固有の落とし穴は
[ddd-django-pitfalls](../ddd-django-pitfalls/SKILL.md)。

---

## 1. 集約の境界は整合性の境界

集約は、**同時に守られなければならない不変条件のまとまり**である。境界は
「一緒に変更されるもの」ではなく「**一緒でないと不正になるもの**」で引く。

判定の順序:

1. 守るべき不変条件を書き出す。
2. その不変条件を検査するのに**必ず読む必要があるオブジェクト**を列挙する。
3. それが 1 つの集約。それ以外は境界の外。

```python
# 不変条件: 「注文明細の合計は与信枠を超えない」
#   → 検査に Order と OrderLine が要る    → 同じ集約
#   → 検査に Customer の与信枠の「値」が要るが、Customer 自体の変更は不要
#     → Customer は別集約。値をコピーして持つか、id で参照する
```

**「一緒に表示される」は境界の理由にならない。** 画面都合の集約は肥大化する。
読み取り目的の結合はクエリ側(read model)で行う。

---

## 2. 集約は小さく保つ

大きい集約は、**ロック範囲が広がり、同時更新が衝突し、読み書きが重くなる**。
迷ったら小さいほうを選ぶ。

| 症状 | 意味 | 直し方 |
| --- | --- | --- |
| コレクションが際限なく伸びる(`orders: tuple[Order, ...]` が数千件) | 境界が広すぎる | 子を別集約にし、id で参照する |
| 更新の大半が集約の一部しか触らない | 不変条件を共有していない | その部分を切り出す |
| 同じ集約を別々のユースケースが同時更新して衝突する | 独立に変わるものが同居している | 変更頻度の違う軸で割る |
| 集約を読むだけで大量の JOIN が要る | 表示都合で結合している | read model へ逃がす |

**集約ルートだけが外部から参照される。** 内部メンバーへの参照を外に出さない。
出すなら値オブジェクトのコピーとして出す。

---

## 3. 1 トランザクション = 1 集約

**1 つのトランザクションで変更してよい集約は 1 つだけ。** これは集約設計の中核ルールで、
守れないなら境界が間違っている。

- 他の集約へは**同一性(id)経由**で到達する。オブジェクトグラフを埋め込まない。
- 複数の集約を同時に整合させたくなったら、選択肢は 2 つ:
  1. **境界が間違っている** — 本当に同時でなければ不正なら、同じ集約にする。
  2. **結果整合でよい** — 多くはこちら。ドメインイベントで非同期に整合させる
     ([ddd-domain-events](../ddd-domain-events/SKILL.md))。

```python
# NG: 1 つの usecase で 2 つの集約を更新している
order_repo.save(order)
inventory_repo.save(inventory)  # ← 別集約。ここで落ちたら不整合

# OK: 1 集約だけ確定し、残りはイベントで整合させる
order_repo.save(order)  # order.pull_events() に OrderPlaced が入っている
```

---

## 4. リポジトリは集約ルート単位でしか作らない

**リポジトリ 1 つ = 集約 1 つ。** 集約の内部メンバー用のリポジトリを作らない。
`OrderLineRepository` が存在する時点で、`OrderLine` は集約の内部ではない
(= 別集約であるべきか、そもそもリポジトリが不要)。

リポジトリが提供するのは、**集約まるごとの取得と保存**だけ。

```python
from abc import ABC, abstractmethod


class OrderRepository(ABC):
    """ドメイン層に置く。実装は知らない。"""

    @abstractmethod
    def find_by_id(self, order_id: OrderId) -> Order | None: ...

    @abstractmethod
    def save(self, order: Order) -> None: ...
```

- **部分取得・部分更新のメソッドを生やさない。** `update_status(order_id, status)` は
  ドメインの振る舞いをリポジトリに漏らしている。`order.cancel()` → `save(order)` にする。
- **クエリ集にしない。** 画面のための検索(絞り込み、集計、一覧)はリポジトリではなく
  **read model / query service** の責務([ddd-read-model-cqrs](../ddd-read-model-cqrs/SKILL.md))。
  リポジトリに `find_by_status_and_date_range_with_customer`
  のようなメソッドが増え始めたら、それは読み取りであって集約の再構成ではない。

---

## 5. インターフェースはドメイン層、実装はインフラ層(依存性逆転)

```text
domain/
├── entities/order.py
└── repositories/order_repository.py   # 抽象。stdlib(abc)のみ
infrastructure/
└── repositories/django_order_repository.py  # 実装。Django を知る
usecases/
└── place_order.py                     # 抽象に依存する
```

- ドメイン層は**永続化技術を一切知らない**。`OrderRepository` は `abc` だけに依存する。
- usecase は具象ではなく抽象を受け取る(コンストラクタ注入)。
- 具象の選択は composition root(Django なら `apps.py` / DI コンテナ)で 1 か所に閉じる。

```python
class PlaceOrder:
    def __init__(self, orders: OrderRepository) -> None:  # 抽象に依存
        self._orders = orders
```

---

## 6. 永続化モデルとドメインオブジェクトを分ける

**Django モデルはドメインオブジェクトではない。** テーブルの形であって、不変条件の
守り手ではない。両者を同一視すると、frozen も `__post_init__` も効かなくなる。

| | ドメインオブジェクト | 永続化モデル |
| --- | --- | --- |
| 置き場所 | `domain/` | `infrastructure/` (Django app) |
| 依存 | stdlib のみ | Django |
| 責務 | 不変条件と振る舞い | テーブルへの読み書き |
| 可変性 | frozen | ORM の都合に従う |

変換はリポジトリ実装の内側に閉じる。この 2 方向のマッピングが、リポジトリ実装の本体。

```python
class DjangoOrderRepository(OrderRepository):
    def find_by_id(self, order_id: OrderId) -> Order | None:
        row = OrderModel.objects.prefetch_related("lines").filter(pk=order_id.value).first()
        return None if row is None else self._to_domain(row)

    def save(self, order: Order) -> None:
        # 集約まるごと。子も含めて 1 トランザクションで確定する
        ...

    def _to_domain(self, row: OrderModel) -> Order:
        # ここで Order(...) を構築する = 不変条件が再検査される
        ...
```

- **遅延読み込みに依存しない。** 集約は境界の全体を一度に読む(`select_related` /
  `prefetch_related`)。ドメイン層が ORM のクエリを引き起こすと、層が壊れている。
- リポジトリ実装がトランザクションを張る範囲は、**集約 1 つ分**。

---

## 7. 復元(reconstitute)でも不変条件を通す

DB から読み戻した集約が不正でないことは、**保証されていない**。マイグレーション、
手作業の UPDATE、旧バージョンの書き込みで壊れうる。

- 復元は通常のコンストラクタを通す。**検証を迂回する専用の生成経路を作らない。**
- 復元で `ValueError` が出たら、それは握り潰さずに落とす。壊れたデータを黙って
  受け入れるより、その場で気付くほうが安い。
- 「復元時だけ検証を緩める」は、不変条件がその集約のものでない兆候。緩めたくなったら
  不変条件の置き場所を疑う。
- マッピングの誤りは**往復テスト**(保存 → 読み戻し → 一致)でしか出ない
  ([ddd-testing-strategy](../ddd-testing-strategy/SKILL.md))。

---

## 8. 同時実行制御

集約は整合性境界なので、**競合は集約単位で検出する**。

- **楽観的ロック**を既定にする。集約ルートにバージョンを持たせ、`save` 時に
  「読んだときのバージョンと一致するか」で更新する。不一致なら競合として失敗させる。
- バージョンは**永続化の関心**であってドメインの不変条件ではない。ドメインオブジェクトに
  持たせるか、リポジトリ側で持つかは選択だが、**ドメインの振る舞いがバージョンを
  読み書きしない**ようにする。
- 悲観的ロック(`select_for_update`)はリポジトリ実装の内側に閉じる。usecase から
  ロックの有無が見えてはいけない。

---

## アンチパターン

| アンチパターン | なぜ悪いか |
| --- | --- |
| 内部メンバーのリポジトリ(`OrderLineRepository`) | 集約ルートを迂回して不変条件が破れる |
| 1 トランザクションで複数集約を更新 | 境界の誤り。部分失敗で不整合になる |
| リポジトリが検索メソッド置き場になる | 読み取りの関心が混入。read model へ |
| リポジトリに `update_xxx(id, value)` | ドメインの振る舞いが永続化層に漏れている |
| Django モデルをそのままドメインで使う | 不変条件を守れない。層が消える |
| 集約が他集約のオブジェクトを保持 | 境界が消え、まとめて読み書きされる |
| 復元専用の検証なしコンストラクタ | 不正な状態が観測可能になる |

---

## ルール(チェックリスト)

- [ ] 集約の境界を**不変条件**から引いた(画面都合・「一緒に表示される」で引いていない)
- [ ] 集約は小さい。伸び続けるコレクションを内部に抱えていない
- [ ] 他の集約は **id で参照**している。オブジェクトを埋め込んでいない
- [ ] **1 トランザクション = 1 集約**。またぐ整合は結果整合(ドメインイベント)にした
- [ ] リポジトリは**集約ルート単位**。内部メンバーのリポジトリを作っていない
- [ ] リポジトリは集約まるごとの取得・保存だけ。部分更新も検索クエリ集もない
- [ ] リポジトリの**抽象はドメイン層**、実装はインフラ層。usecase は抽象に依存する
- [ ] ドメインオブジェクトと永続化モデルが分かれ、変換がリポジトリ実装に閉じている
- [ ] 集約は境界の全体を一度に読む。ドメイン層が遅延読み込みを引き起こさない
- [ ] 復元でも通常のコンストラクタを通り、不変条件が再検査される
- [ ] 競合は集約単位で検出する(楽観的ロック)。ロックの詳細が usecase に漏れていない
