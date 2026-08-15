---
name: ddd-domain-events
description: ドメインイベントの設計指針。1 トランザクションで複数の集約を更新したくなったとき、副作用(通知・在庫引当・監査ログ)を切り離したいとき、既存イベントのフィールドや意味を変えたいときに使う。扱う範囲は「起きた事実」としてのイベント定義、集約ルートでの発生と収集、トランザクション確定後のディスパッチ、集約をまたぐ結果整合性、ハンドラの冪等性、outbox パターン、公開済みイベントのバージョニング(後方互換な変更の見分け、新しい型への移行、永続イベントの読み替え)。
---

# DDD: ドメインイベント (Domain Events)

**集約をまたぐ整合性**と**副作用の分離**を、結果整合性で扱う。

前提: Python 標準ライブラリの `dataclasses`。ドメイン層は **stdlib のみ**に依存する。

**Django の signals はドメインイベントの代わりにならない** —
[ddd-django-pitfalls](../ddd-django-pitfalls/SKILL.md)。

関連スキル:

- 集約内部のオブジェクト設計 → [ddd-domain-object-completeness](../ddd-domain-object-completeness/SKILL.md)
- イベントで読み取りモデルを更新する → [ddd-read-model-cqrs](../ddd-read-model-cqrs/SKILL.md)
- コンテキストをまたぐ統合としてのイベント → [ddd-bounded-context](../ddd-bounded-context/SKILL.md)
- どんなイベントがあるかを業務から洗い出す工程 → [ddd-modeling-discovery](../ddd-modeling-discovery/SKILL.md)

---

## 1. いつ使うか

**「1 トランザクション = 1 集約」を守りながら、複数の集約を整合させたいとき。**
これが第一の用途で、それ以外は後付けの理由になりやすい。

使う:

- 集約 A の変更をきっかけに、集約 B を変える必要がある(即時でなくてよい)。
- ドメインの振る舞いから副作用(通知、外部 API、監査ログ)を切り離したい。
- 「何が起きたか」自体がドメインの関心である(監査、履歴、分析)。

使わない:

- **同じトランザクションで確定しなければ不正になる** → 境界が間違っている。同じ集約にする。
- 単一集約の中で完結する処理 → メソッド呼び出しでよい。イベントにする必要はない。
- 呼び出し元が結果を必要とする → イベントは戻り値を返さない。それは通常の呼び出し。

---

## 2. イベントは「起きた事実」

イベントは**過去形で、不変で、すでに確定した事実**。命令でも要求でもない。

```python
import uuid
from dataclasses import dataclass, field
from datetime import UTC, datetime


@dataclass(frozen=True, kw_only=True)
class DomainEvent:
    """全ドメインイベントの共通スーパータイプ。"""

    event_id: uuid.UUID = field(default_factory=uuid.uuid4)
    occurred_at: datetime = field(default_factory=lambda: datetime.now(UTC))


@dataclass(frozen=True, kw_only=True)
class OrderPlaced(DomainEvent):
    order_id: OrderId          # 発生元の集約 id
    customer_id: CustomerId    # 他集約は id で参照
    total: Money
```

- **名前は過去形**: `OrderPlaced` / `PaymentCaptured` / `InventoryReserved`。
  `PlaceOrder`(命令)や `SendEmail`(指示)はイベントではない。
- **frozen**。起きた事実は書き換わらない。
- **発生元の集約 id を必ず持つ**。
- **他の集約はオブジェクトではなく id で持つ**。イベントは集約の外を渡り歩くので、
  オブジェクトを埋め込むと境界が漏れる。
- ハンドラが必要とする**値のスナップショット**は持ってよい(`total` など)。あとから
  DB を引き直すと、そのときの値と変わっている。
- **ドメインロジックをイベントに持たせない。** メソッドを生やしたくなったら、それは
  集約かドメインサービスの責務。

### CRUD イベントにしない

`OrderUpdated` / `EntityChanged` のような汎用イベントは、**何が起きたのかを伝えない**。
ハンドラ側が「今回は何が変わったのか」を判定する羽目になり、ドメインの意図が失われる。
`OrderCancelled` / `ShippingAddressChanged` のように、**業務上の出来事**を名前にする。

---

## 3. 発生させるのは集約ルート、記録も集約ルート

イベントは**ドメインの振る舞いの中で**発生する。usecase が「たぶんこれが起きたはず」と
外から作るのではない。

```python
from dataclasses import dataclass, field, replace


@dataclass(frozen=True, kw_only=True, eq=False)
class Order(Entity):
    status: OrderStatus
    events: tuple[DomainEvent, ...] = ()   # 未ディスパッチのイベント

    def cancel(self) -> "Order":
        if self.status is OrderStatus.SHIPPED:
            raise ValueError("出荷済みの注文は取り消せない")
        return replace(
            self,
            status=OrderStatus.CANCELLED,
            events=(*self.events, OrderCancelled(order_id=self.id)),
        )

    def pull_events(self) -> tuple["Order", tuple[DomainEvent, ...]]:
        """イベントを取り出し、空にした集約を返す。二重発行を防ぐ。"""
        return replace(self, events=()), self.events
```

- **不変条件を満たした後にだけイベントを積む。** 上の例では、取り消せない状態なら
  例外で抜けるのでイベントは発生しない。
- イベントは集約に**溜める**。振る舞いの中で直接ディスパッチしない
  (まだ確定していない変更を、外に知らせてしまう)。
- 取り出しは 1 回きり。`pull_events` の後は空になる。

---

## 4. ディスパッチはトランザクション確定**後**

**まだコミットされていない変更を通知しない。** ロールバックされたのに通知だけ飛ぶ、
という不整合が起きる。

```python
class CancelOrder:
    def __init__(self, orders: OrderRepository, bus: EventBus) -> None:
        self._orders = orders
        self._bus = bus

    def execute(self, order_id: OrderId) -> None:
        order = self._orders.find_by_id(order_id)
        if order is None:
            raise OrderNotFound(order_id)

        cancelled = order.cancel()                    # 1. ドメインの振る舞い
        drained, events = cancelled.pull_events()

        self._orders.save(drained)                    # 2. 集約を 1 つだけ確定

        for event in events:                          # 3. 確定後にディスパッチ
            self._bus.publish(event)
```

順序が要点:

| 順 | やること | 理由 |
| --- | --- | --- |
| 1 | 集約の振る舞いを呼ぶ | 不変条件を守りながらイベントが積まれる |
| 2 | 集約を保存(1 トランザクション、1 集約) | ここが唯一の「確定」点 |
| 3 | イベントを publish | コミット済みの事実だけを知らせる |

Django なら `transaction.on_commit()` にディスパッチを載せるのが素直。ただし
**トランザクション管理は usecase / インフラの責務**で、ドメイン層に `django.db` を
持ち込まない([ddd-application-layer](../ddd-application-layer/SKILL.md))。

### 配送を確実にするなら outbox

「コミットは成功したがディスパッチ前にプロセスが落ちた」場合、イベントは失われる。
確実性が要るなら **outbox パターン**: イベントを集約と**同じトランザクションで**
outbox テーブルに書き、別プロセスが outbox を読んで配送する。

- 配送保証は **at-least-once** になる(同じイベントが 2 回届きうる)。
- 失われて困らないイベント(統計、キャッシュ更新)に outbox は過剰。

---

## 5. ハンドラは冪等に書く

**同じイベントが 2 回届く前提で書く。** outbox でなくても、再送・リトライ・
リプレイで重複は起きる。

- 処理済みの `event_id` を記録して弾く、または結果が同じになる操作にする
  (「在庫を 3 減らす」ではなく「この注文の引当を 3 にする」)。
- ハンドラは**自分の集約だけ**を変更する。ハンドラ内で複数集約を触ると、同じ問題が再発する。
- ハンドラの失敗は発生元に伝播しない。発生元のトランザクションはすでに確定している。
  失敗はリトライか dead letter で扱う。
- **ハンドラの連鎖を深くしない。** イベント → ハンドラ → イベント → ハンドラ … が
  数段続くと、全体の整合がいつ取れるのか誰にも分からなくなる。**3 段を超えたら
  調整役(プロセスマネージャ)を立てる** —
  [ddd-long-running-process](../ddd-long-running-process/SKILL.md)。

---

## 6. イベントの置き場所

```text
domain/
├── events/
│   ├── base.py            # DomainEvent
│   └── order_events.py    # OrderPlaced, OrderCancelled ...
├── entities/order.py      # イベントを発生させる
└── repositories/
usecases/
└── cancel_order.py        # pull_events → save → publish
infrastructure/
└── events/
    ├── bus.py             # EventBus 実装
    └── handlers/          # 購読側
```

- イベント定義は**ドメイン層**(stdlib のみ)。
- `EventBus` の**抽象はドメインか application 層、実装はインフラ層**。リポジトリと同じ
  依存性逆転([ddd-aggregate-repository-boundary](../ddd-aggregate-repository-boundary/SKILL.md))。
- ハンドラはインフラ層 or application 層。ドメイン層はハンドラを知らない。

---

## 7. イベントの変更(バージョニング)

**イベントは公開契約。** 集約と違い、**自分だけの都合で形を変えられない**。

気にする必要があるのは、次のどちらかに当てはまるときだけ。

- **永続化している**(outbox テーブル、イベントログ)。古い行が残っている。
- **他コンテキスト / 他システムが購読している**。

どちらでもない(プロセス内で発行してその場で消費するだけ)なら、
**普通にリファクタリングしてよい。** 以下は不要。

後方互換な変更の見分け方、破壊的変更を新しい型として足す手順、永続イベントの読み替え、
保存形式の決め方は [versioning.md](versioning.md)。

---

## アンチパターン

| アンチパターン | なぜ悪いか |
| --- | --- |
| イベントで同期的に整合を取ろうとする | 結果整合の仕組みで即時整合は作れない。境界を見直す |
| 振る舞いの中で直接 publish する | 未確定の変更を通知してしまう |
| usecase がイベントを組み立てる | 「起きた事実」の判断がドメインの外に出る |
| `OrderUpdated` のような CRUD イベント | 何が起きたか伝わらない。意図が失われる |
| イベントに集約オブジェクトを埋め込む | 境界が漏れる。シリアライズもできない |
| イベントにメソッド・ロジックを持たせる | 事実ではなくなる。集約かドメインサービスへ |
| ハンドラが複数集約を更新する | 1 トランザクション 1 集約の違反が場所を変えて再発 |
| ハンドラが冪等でない | 再送・リトライで二重処理になる |
| ハンドラの失敗を発生元に伝播させる | 確定済みのトランザクションは取り消せない |
| 公開済みイベントのフィールドを改名・削除する | 購読側と永続化された行が壊れる。新しい型を足す |
| フィールドはそのままで**意味**を変える | 型が同じなので購読側が気付けない。最も危険 |
| イベントに `version` フィールドで分岐させる | 型を分ければ分岐漏れが型チェックで見つかる |
| 値オブジェクトをそのままシリアライズして保存 | クラス定義を変えた瞬間に読めなくなる |
| 古いイベントの変換に現在のドメインロジックを使う | ロジック変更で過去のイベントの解釈が変わる |

---

## ルール(チェックリスト)

- [ ] そのイベントは「集約をまたぐ整合」か「副作用の分離」のためか(即時整合が必要なら境界を直す)
- [ ] 名前が**過去形の業務上の出来事**。CRUD イベントになっていない
- [ ] `frozen` で、発生元の集約 id を持ち、他集約は id で参照している
- [ ] ドメインロジックを持っていない(メソッドが生えていない)
- [ ] **集約ルートの振る舞いの中で**、不変条件を満たした後に発生している
- [ ] 集約に溜めて `pull_events` で取り出す。振る舞いの中で publish していない
- [ ] ディスパッチは**保存が確定した後**(必要なら outbox で at-least-once を担保)
- [ ] ハンドラは**冪等**で、**自分の集約だけ**を変更し、失敗を発生元に伝播しない
- [ ] イベント定義はドメイン層(stdlib のみ)。`EventBus` は抽象に依存している
- [ ] 永続化 or 外部公開しているイベントを**破壊的に変更していない**(新しい型を足した)
- [ ] フィールドの**意味**を変えるときは必ず新しい型にした
- [ ] ペイロードを**プリミティブ**で保存している(値オブジェクトを直接保存していない)
- [ ] 古いイベントの読み替えを**当時の値でべた書き**している(現在のロジックを呼んでいない)
- [ ] 未知のイベント型を受け取ったときの挙動を決めている(黙って落としていない)
