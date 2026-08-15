---
name: ddd-read-model-cqrs
description: 読み取り側(クエリ)を書き込み側(集約)から分離する設計指針。一覧・検索・ダッシュボードを実装するとき、リポジトリに検索メソッドが増え始めたとき、表示都合で集約が肥大化しているとき、N+1 や JOIN の重さがドメイン層に染み出したときに使う。扱う範囲はリポジトリを検索メソッド置き場にしない判断、read model / query service の設計、DTO を返す読み取りパス、Django ORM を直接使ってよい範囲、CQRS をどこまでやるか、イベントによる投影と結果整合。
allowed-tools:
  - Read
  - Grep
  - Glob
---

# DDD: 読み取りモデルと CQRS (Read Model / CQRS)

**集約は書き込みのための構造であって、表示のための構造ではない。** 読み取りを
集約経由でやろうとすると、集約が画面の都合で肥大化する。

前提: Django + Django ORM。書き込み側のドメイン層は **stdlib のみ**に依存するが、
**読み取り側はその制約の外**にある(第 4 節)。

集約とリポジトリの責務は
[ddd-aggregate-repository-boundary](../ddd-aggregate-repository-boundary/SKILL.md)、
書き込み側のユースケースは
[ddd-application-layer](../ddd-application-layer/SKILL.md)、
投影の非同期化は
[ddd-domain-events](../ddd-domain-events/SKILL.md)。

---

## 1. 分ける理由

書き込みと読み取りは、**要求がまったく違う**。

| | 書き込み側 (Command) | 読み取り側 (Query) |
| --- | --- | --- |
| 目的 | 不変条件を守って状態を変える | 画面に必要な形で見せる |
| 単位 | 集約 1 つ | 画面 1 つ(複数集約をまたぐ) |
| 形 | ドメインが決める | **UI が決める** |
| 整合性 | 強整合(トランザクション) | 結果整合でよいことが多い |
| 最適化 | 正しさ優先 | 速度優先(非正規化・インデックス) |

同じモデルで両方を満たそうとすると、必ずどちらかが歪む。**歪むのはたいてい集約のほう**
— 一覧画面のために集約へ「表示用の派生フィールド」が生え、境界が崩れていく。

---

## 2. 読み取りはリポジトリを通さない

**リポジトリは集約まるごとの取得と保存だけ。** 検索・絞り込み・集計・一覧は
リポジトリの責務ではない。

```python
# NG: リポジトリが検索メソッド置き場になっている
class OrderRepository(ABC):
    def find_by_id(self, order_id: OrderId) -> Order | None: ...
    def find_by_status_and_date_range(self, ...) -> list[Order]: ...      # ← 読み取り
    def search_with_customer_name(self, keyword: str) -> list[Order]: ... # ← 読み取り
    def count_by_month(self) -> dict[str, int]: ...                       # ← 読み取り
```

これが悪い理由は 3 つ。

1. **無駄が大きい。** 一覧に 100 件表示するために、集約を 100 個構築し、不変条件を
   100 回検査し、そのあと DTO に詰め替える。表示に必要なのは 3 カラムなのに。
2. **集約の境界を引きずる。** 集約は境界の全体を一度に読む必要があるので、
   `prefetch_related` が膨らむ。
3. **集約をまたげない。** 「注文一覧に顧客名を出す」は 2 集約にまたがる。リポジトリで
   やろうとすると、`Order` に `customer_name` を持たせたくなる = 境界の破壊。

### 見分け方

**状態を変えないなら読み取りパス。** 例外はない。`find_by_id` が書き込み側に残るのは、
その戻り値を**変更して保存するため**であって、表示のためではない。

---

## 3. query service — 読み取り専用の入口

読み取りは、リポジトリと別の**クエリサービス**に置く。返すのは**DTO**であって
ドメインオブジェクトではない。

```python
from abc import ABC, abstractmethod
from dataclasses import dataclass
from datetime import datetime
from decimal import Decimal


@dataclass(frozen=True, kw_only=True)
class OrderListItem:
    """画面が必要とする形。集約の形ではない。"""

    order_id: str
    customer_name: str      # 別集約の値。読み取りなので持ってよい
    total: Decimal
    status: str
    placed_at: datetime


class OrderQueryService(ABC):
    @abstractmethod
    def list_recent(self, *, limit: int, status: str | None) -> list[OrderListItem]: ...
```

- **返すのは frozen dataclass の DTO**(または `TypedDict`)。エンティティ・値オブジェクトを
  返さない。返すと、呼び出し側がドメインの振る舞いを呼べてしまう。
- **DTO は画面単位で作る。** `OrderListItem` と `OrderDetail` を無理に共通化しない。
  読み取り DTO の重複は、正しいコストの払い方。
- **抽象を置くかは選択。** テストで差し替えたい / 実装を切り替える見込みがあるなら
  `ABC` を置く。そうでなければ具象クラス 1 つでよい —
  書き込み側のリポジトリ抽象(依存性逆転が必須)とは事情が違う。
- query service は**書き込まない**。`save` / `update` のメソッドを生やさない。

---

## 4. 読み取り側は Django ORM を直接使ってよい

読み取りに「stdlib のみ」の制約を持ち込むと、ORM の力を捨てることになる。
**読み取り側は素直に ORM を使う。**

```python
class DjangoOrderQueryService(OrderQueryService):
    def list_recent(self, *, limit: int, status: str | None) -> list[OrderListItem]:
        qs = (
            OrderModel.objects
            .select_related("customer")
            .order_by("-placed_at")
        )
        if status is not None:
            qs = qs.filter(status=status)

        rows = qs.values(
            "id", "customer__name", "total", "status", "placed_at",
        )[:limit]

        return [
            OrderListItem(
                order_id=str(r["id"]),
                customer_name=r["customer__name"],
                total=r["total"],
                status=r["status"],
                placed_at=r["placed_at"],
            )
            for r in rows
        ]
```

- **`.values()` / `.annotate()` / 生 SQL を使ってよい。** モデルインスタンスを作らない分速い。
- **集約の再構成をしない。** ここで `Order(...)` を組み立て始めたら、それは書き込み側の仕事。
- 重いレポートは**生 SQL / DB ビュー / マテリアライズドビュー**で構わない。
  ドメインの不変条件はここに一切関与しない。
- ただし **query service より上(view / serializer)に QuerySet を渡さない。**
  遅延評価がテンプレートまで漏れると、どこでクエリが走るのか追えなくなる。

### 置き場所

```text
domain/
└── repositories/order_repository.py        # 書き込み側の抽象
usecases/
├── cancel_order.py                         # 書き込み
└── queries/
    └── order_query_service.py              # 読み取りの抽象 + DTO
infrastructure/
├── repositories/django_order_repository.py
└── queries/django_order_query_service.py   # ORM を使う実装
```

読み取り DTO と query service の抽象は、**ドメイン層ではなくアプリケーション層**に置く。
ドメインの概念ではなく、アプリケーションの都合(画面)だから。

---

## 5. CQRS はどこまでやるか

「CQRS = 別 DB + イベントソーシング」ではない。**段階がある。**

| 段階 | 内容 | いつ |
| --- | --- | --- |
| **1. 読み書きの経路を分ける** | 同一 DB・同一テーブル。query service と repository を分けるだけ | **既定。ここから始める** |
| 2. 読み取り専用のテーブル/ビューを作る | 非正規化した投影テーブルを同じ DB に持つ | 集計が重い、JOIN が深い |
| 3. 読み取り用ストアを分ける | 別 DB / 検索エンジン。イベントで投影 | 読み取りの負荷特性が明確に違う |

**段階 1 で足りることがほとんど。** 段階 2 以降は結果整合を受け入れることになり、
「保存したのに一覧に出ない」という UX 上の問題を持ち込む。

先に進む条件は、**測った上で**遅いこと。「CQRS だから分ける」は理由にならない。

---

## 6. 投影 (Projection) と結果整合

段階 2 以降で読み取り用テーブルを持つ場合、その更新方法は 2 つ。

| 方式 | 整合性 | 使いどころ |
| --- | --- | --- |
| **同期投影**(同じトランザクションで更新) | 強整合 | 投影先が同じ DB にあり、更新が軽い |
| **イベント投影**(ドメインイベントのハンドラで更新) | 結果整合 | 投影が重い / 別ストア |

イベント投影の場合、ハンドラの制約は
[ddd-domain-events](../ddd-domain-events/SKILL.md) と同じ:

- **冪等に書く。** 同じイベントが 2 回届く前提(「+1 する」ではなく「この値にする」)。
- 投影ハンドラは**読み取りモデルだけ**を更新する。ここで集約を触らない。
- **投影は再構築可能にしておく。** イベントログか元テーブルから作り直せること。
  バグった投影を直す手段がないと、運用で詰む。
- 読み取りが遅れることを **UI 側で織り込む**(「反映まで数秒かかります」)。
  それが許されない画面は、段階 1 のままにする。

---

## アンチパターン

| アンチパターン | なぜ悪いか |
| --- | --- |
| リポジトリに検索・集計メソッドが増え続ける | 読み取りの関心が書き込み側に混入。query service へ |
| 一覧表示のために集約を N 件構築する | 不変条件の検査も prefetch も全部無駄。しかも遅い |
| 表示用の派生フィールドを集約に生やす | 画面都合で境界が壊れる。読み取り DTO に持たせる |
| query service がドメインオブジェクトを返す | 境界の外でドメインの振る舞いが呼べる |
| query service が書き込みメソッドを持つ | 分離の意味がなくなる。読み取り専用を守る |
| QuerySet を view / serializer まで返す | 遅延評価が漏れ、クエリの発生箇所が追えない |
| 読み取り DTO を書き込み側と共通化する | 画面の変更がドメインに波及する。重複させてよい |
| 測らずに読み取り用ストアを分ける | 結果整合の複雑さを対価なしに払う |
| 投影を再構築する手段がない | バグった投影を直せない |

---

## ルール(チェックリスト)

- [ ] **状態を変えない処理**をリポジトリ経由にしていない(query service へ分けた)
- [ ] リポジトリに検索・絞り込み・集計メソッドが残っていない
- [ ] query service が返すのは **DTO**。エンティティ・値オブジェクト・QuerySet を返していない
- [ ] 読み取り DTO は**画面単位**。書き込み側と無理に共通化していない
- [ ] 読み取り実装で**集約を再構成していない**(`.values()` 等で直接 DTO へ)
- [ ] 読み取り側の抽象 + DTO は**アプリケーション層**、ORM を使う実装はインフラ層にある
- [ ] CQRS は**段階 1(経路の分離)**から始めた。先に進む判断は測定に基づいている
- [ ] 投影を持つなら、ハンドラは**冪等**で、読み取りモデルだけを更新している
- [ ] 投影を**再構築できる**手段がある
- [ ] 結果整合による表示の遅れを UI が織り込んでいる(許されない画面は段階 1 のまま)
