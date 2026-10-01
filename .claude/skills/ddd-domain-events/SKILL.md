---
name: ddd-domain-events
description: 集約で起きた事実を、別の集約や後続の処理へ伝える経路を設計する。1 つのトランザクションで複数の集約を更新したくなったとき、通知・外部 API・Celery タスクを集約の振る舞いから切り離したいとき、Django の signals でつなごうとしているとき、コミット後の通知が失われたり二重に届いたりするとき、outbox・統合イベント・公開済みイベントのスキーマ変更を検討するときに使う。
---

# DDD: ドメインイベント (Domain Events)

ドメインイベントは、ドメインで起きた事実を明示し、その事実に反応する処理を発生元から
切り離す。設計では、集約内で使うドメインイベントと、境界の外へ送る統合イベントを分けて
考える。

前提: Python 標準ライブラリの `dataclasses`。ドメイン層は **stdlib のみ**に依存する。

**Django の signals はドメインイベントの代わりにならない** —
[ddd-django-pitfalls](../ddd-django-pitfalls/SKILL.md)。

関連スキル:

- 集約内部のオブジェクト設計 → [ddd-domain-object-completeness](../ddd-domain-object-completeness/SKILL.md)
- イベントで読み取りモデルを更新する → [ddd-read-model-cqrs](../ddd-read-model-cqrs/SKILL.md)
- コンテキストをまたぐ統合としてのイベント → [ddd-bounded-context](../ddd-bounded-context/SKILL.md)
- どんなイベントがあるかを業務から洗い出す工程 → [ddd-modeling-discovery](../ddd-modeling-discovery/SKILL.md)

---

## 1. 使う場面

次の場面でドメインイベントを検討する。

- 集約の状態変化を受けて、別の集約や境界づけられたコンテキストが処理を始める。
- 通知、外部 API、読み取りモデル更新などを、集約の振る舞いから切り離す。
- 「何が起きたか」という事実を、後続処理や監査で参照する。

次の処理には使わない。

- 同じ集約の中で完結する処理。通常のメソッド呼び出しで表せる。
- 呼び出し元がその場で結果を必要とする処理。戻り値のある呼び出しとして設計する。
- 技術上の更新通知。`EntityUpdated` ではなく、業務上の出来事があるかを先に確認する。

1 回のトランザクションで 1 集約だけを更新すると、境界と競合を局所化しやすい。複数集約を
同じ DB トランザクションで更新する設計も選べる。即時整合が必要なら集約境界を見直し、
それでも集約を分ける場合は Unit of Work の範囲と競合時の挙動を明示する。

## 2. イベントは起きた事実

イベント名は過去形にし、発生後に内容を書き換えない。

```python
import uuid
from dataclasses import dataclass
from datetime import datetime


@dataclass(frozen=True, kw_only=True)
class DomainEvent:
    event_id: uuid.UUID
    occurred_at: datetime

    def __post_init__(self) -> None:
        if self.occurred_at.tzinfo is None:
            msg = "occurred_at はタイムゾーン付きの datetime にする"
            raise ValueError(msg)


@dataclass(frozen=True, kw_only=True)
class OrderCancelled(DomainEvent):
    order_id: OrderId
    reason: CancellationReason
```

- `OrderCancelled` や `PaymentCaptured` は事実を表す。`CancelOrder` や `SendEmail` は
  コマンドであり、イベントではない。
- 発生元の集約 ID を含める。他の集約はオブジェクトではなく ID で参照する。
- 後続処理が発生時点の値を必要とするなら、その値をスナップショットとして含める。
  後から DB を引き直すと、別の時点の値を読むおそれがある。
- イベントにドメインロジックを持たせない。判断は集約かドメインサービスに置く。
- `event_id` とタイムゾーン付きの `occurred_at` は Usecase から渡す。ID と現在時刻を返す
  port を Usecase 側に置き、その実装が `uuid.uuid4()` と `datetime.now(UTC)` を呼ぶ。
  テストでは固定値を返す実装に差し替える。イベント自身も `__post_init__` で naive な
  `datetime` を弾く。ドメイン層で `datetime.now()` を呼ばない。

`OrderUpdated` や `EntityChanged` のような CRUD イベントでは、購読側が差分を解釈しなければ
ならない。`ShippingAddressChanged` のように、後続処理が判断できる業務上の出来事を名前にする。

## 3. ドメイン判断と同時に記録する

Usecase が状態差分からイベントを推測せず、集約が不変条件を確認した直後にイベントを記録する。
集約内部のエンティティが出来事を検出する場合も、集約ルートから回収できる形に集約する。

```python
import uuid
from dataclasses import dataclass, field, replace
from datetime import datetime


@dataclass(frozen=True, kw_only=True, eq=False)
class Order(Entity):
    status: OrderStatus
    events: tuple[DomainEvent, ...] = field(
        default=(),
        repr=False,
        metadata={"persist": False},
    )

    def cancel(
        self,
        *,
        event_id: uuid.UUID,
        occurred_at: datetime,
        reason: CancellationReason,
    ) -> "Order":
        if self.status is OrderStatus.SHIPPED:
            msg = "出荷済みの注文は取り消せない"
            raise OrderNotCancellableError(msg)

        event = OrderCancelled(
            event_id=event_id,
            occurred_at=occurred_at,
            order_id=self.id,
            reason=reason,
        )
        return replace(
            self,
            status=OrderStatus.CANCELLED,
            events=(*self.events, event),
        )

    def pull_events(self) -> tuple["Order", tuple[DomainEvent, ...]]:
        return replace(self, events=()), self.events
```

不変条件を満たせなければ、状態もイベントも作らない。不変条件違反は素の `ValueError` ではなく
ドメインの例外階層で表す([exception-design](../exception-design/SKILL.md))。

イベントを振る舞いの中から直接配送すると、永続化前の事実が外へ漏れるため、集約には未配送
イベントだけを保持させる。通常の状態保存を使う場合、リポジトリはこの一時的なコレクションを
永続属性として扱わない。ただし `dataclasses.asdict()` のように全フィールドを走査するリポジトリ
では自動では外れず、未配送イベントが保存ペイロードへ紛れ込む。`metadata` を見るフィルタで
明示的に除外するか、未配送イベントを永続エンティティに載せず Usecase の戻り値として運ぶ。

## 4. ドメインイベントと統合イベントを分ける

| 種類             | 範囲                               | 契約の扱い                                                 |
| ---------------- | ---------------------------------- | ---------------------------------------------------------- |
| ドメインイベント | 同じ境界づけられたコンテキスト内部 | 同期消費かつ配送待ちがなければ、利用箇所と同時に変更できる |
| 統合イベント     | 他コンテキスト、他システム         | 購読側と共有するバージョン付きの公開契約                   |

ドメインイベントの Python クラスを、そのまま外部メッセージとして公開しない。Usecase 層で
必要な値を選び、安定したペイロードを持つ統合イベントへ変換する。この変換により、内部モデルの
変更を外部契約から切り離せる。

## 5. トランザクションと配送保証を決める

配送方法は、必要な整合性と許容できる障害から選ぶ。

| 目的                                           | 配送方法                                           | 障害時の挙動                                     |
| ---------------------------------------------- | -------------------------------------------------- | ------------------------------------------------ |
| 同じ DB トランザクションで内部更新も確定させる | コミット前に同期 `dispatch`                        | 同じトランザクションの更新をまとめてロールバック |
| 消失を許容できるコミット後の軽い処理           | インフラ層で `transaction.on_commit()` に登録      | コミット後、コールバック実行前の停止で失われる   |
| 外部配信や再送が必要                           | 状態更新と `outbox` 行を同じトランザクションで保存 | relay が再送する。配送は `at-least-once`         |

集約の読み込み、遷移、イベントの取り出し、保存を一つのトランザクションに入れ、集約は
トランザクション内でロックして読み直す。

```python
with transaction_manager():
    order = order_repository.get_for_update(order_id)
    order = order.cancel(
        event_id=event_id,
        occurred_at=occurred_at,
        reason=reason,
    )
    order, events = order.pull_events()
    integration_events = event_mapper.to_integration_events(events)

    order_repository.save(order)
    domain_event_dispatcher.dispatch(events)
    outbox.add_all(integration_events)
```

内部ハンドラだけでよければ `outbox.add_all()` の行を、外部配送だけでよければ `dispatch()` の
行を落とす。両方必要なら、この例のように同じトランザクションへ並べる。

トランザクションの外で集約を読んで中で保存すると、同じ不変条件を通過した二つのリクエストが
互いの更新を上書きし、一つの事実に対して同じイベントが二度配送される。

コミット前のハンドラでは、同じトランザクションに参加しない外部 API、メール送信、ブローカーへの
送信、Celery task の登録を行わない。これらはロールバックできず、後続の失敗時に外部だけ処理済み
になる。確実な外部配送が必要なら、ハンドラは送信内容を `outbox` へ保存する。コミット後に
ブローカーを直接呼ばず、`outbox` を別の relay が配送する。

relay は送信成功後に停止すると同じメッセージを再送する。そのため、`event_id` は再送しても
変えず、購読側を冪等にする。`on_commit()` は relay を早く起こす通知には使えるが、`outbox` を
回収する定期処理の代わりにはならない。

配送基盤全体での順序は前提にしない。同じ集約のイベントだけ順序が必要なら、集約 ID と
`sequence` を outbox とメッセージに持たせる。

「`N` が来ていないから待つ」と判断できるのは、その購読側から見て `sequence` が連続している
場合だけである。単調増加なだけでは足りない。DB シーケンスはロールバックで欠番を残し、購読側が
イベント種別を絞って購読していれば欠番は設計上の正常な状態になる。どちらの場合も、購読側は
永遠に来ない `N` を待ち、待機期限まで後続を保留したうえで誤検知の再同期や隔離に落ちる。

- 購読側から見える系列ごとに、トランザクション内で連続番号を採番する。
- 連続番号にできないなら、欠番を明示するスキップマーカーを配送するか、「`N+1` 以降が届いてから
  一定時間で `N` を欠番とみなす」といった前進規則を契約に書く。

そのうえで購読側は重複、次の連番、連番の欠落を区別する。`N` が未適用のまま `N+1` が届いたら
後続を保留し、`N` の適用後に再評価する。待機期限を超えた場合に、正本との再同期、隔離、
アラートのどれを行うかも決めておく。

トランザクション管理は Usecase / インフラの責務で、ドメイン層に `django.db` を持ち込まない
([ddd-application-layer](../ddd-application-layer/SKILL.md))。例の `transaction_manager()` は、
Usecase 層に置いたトランザクションの port を指す。既にトランザクションの port があるなら、新しく
Unit of Work を作る前にそれで足りるかを確認する。`on_commit()` のような Django 固有のコールバックが
必要な場合も、Usecase に直接 import せず同じ形で adapter の契約として公開する。

## 6. 非同期ハンドラは冪等にする

at-least-once 配送では、同じメッセージが複数回届くことがある。次のいずれかで、同じ
`event_id` を再処理しても業務結果が変わらないようにする。

- 処理済み ID の登録と業務更新を同じトランザクションで行う。
- 「在庫を 3 減らす」ではなく、「この注文の引当数を 3 にする」のような操作にする。
- 業務上の一意制約や外部 API の idempotency key を使う。

再送された同一メッセージと、内容が同じ別の依頼は区別する。失敗は再試行上限と
`dead letter`、運用アラートで扱い、無限リトライや無言の破棄を避ける。

ハンドラは購読側コンテキストの Usecase を呼び、そのコンテキストのトランザクション内で
不変条件を守る。複数メッセージにまたがる順序、分岐、補償をハンドラの連鎖で表し始めたら、
調整役を検討する —
[ddd-long-running-process](../ddd-long-running-process/SKILL.md)。

## 7. 置き場所

```text
domain/
├── events/
│   ├── base.py             # DomainEvent
│   └── order_events.py     # OrderPlaced, OrderCancelled ...
└── entities/order.py       # イベントを記録する
usecases/
├── cancel_order.py          # 回収、保存、dispatch / outbox の調整
├── adapters/
│   └── event_dispatcher.py  # dispatcher の port
└── events/
    ├── handlers.py          # 内部ハンドラ
    └── mapper.py            # ドメインイベントから公開 DTO への変換
interface/
├── repositories/outbox.py # outbox リポジトリの実装
└── serializers/events.py  # 公開 DTO から配送形式への変換
infrastructure/
├── tasks/publish_outbox.py # relay の定期実行と再試行の入口
└── containers/events.py   # ハンドラ、リポジトリ、relay の DI
```

- イベント定義はドメイン層(stdlib のみ)に置き、Django や Celery に依存させない。
- `DomainEventDispatcher` の port は Usecase 層に置く。トランザクション、現在時刻、ID 採番
  などの port と同じ場所(例では `usecases/adapters/`)に並べる。内部ハンドラと公開 DTO への
  変換も Usecase 層に置く。
- リポジトリのインターフェースはドメイン層に置くことが多い
  ([ddd-aggregate-repository-boundary](../ddd-aggregate-repository-boundary/SKILL.md))が、
  dispatcher はドメイン層から呼ばないので Usecase 層の port でよい。
- 配送形式へのシリアライズと outbox リポジトリの実装は interface 層に置く。outbox を配送する
  task と DI は infrastructure 層に置き、ブローカーや外部 API の詳細を内側へ漏らさない。

## 8. イベントを変更する

バージョニングの要否は、イベントが内部用か公開用かだけでは決まらない。ペイロードがコードの
デプロイをまたいで永続化・配送待ちになる場合、または発行側と購読側を原子的に更新できない場合は、
互換性を設計する。ローリングデプロイや独立デプロイでは、同じコンテキスト内でも旧版と新版が
同時に動く。

同一プロセス内で同期消費し、発行側とすべての利用箇所を同時に変更でき、古いペイロードも残らない
場合だけ、通常のリファクタリングとして扱う。

互換性の見分け方、破壊的変更の移行手順、永続ペイロードの読み方、保存形式は
[versioning.md](versioning.md) を参照する。

## アンチパターン

| アンチパターン                                     | 問題                                                     |
| -------------------------------------------------- | -------------------------------------------------------- |
| `OrderUpdated` のような CRUD イベント              | 購読側が差分を推測することになり、業務上の意図が消える   |
| 集約の振る舞いから直接 publish する                | 未確定の変更を外へ通知する                               |
| Usecase が状態差分からイベントを組み立てる         | 出来事を判断する責務がドメインから漏れる                 |
| ドメインイベントのクラスを外部へそのまま公開する   | 内部モデルの変更が外部契約を壊す                         |
| コミット後にブローカーを直接呼ぶ                   | コミットと送信の間で停止するとメッセージを失う           |
| 再送時に新しい `event_id` を発行する               | 購読側が重複を判定できない                               |
| イベントに集約オブジェクトを埋め込む               | 境界が漏れ、安定したシリアライズもできない               |
| 公開済みフィールドの意味だけを変える               | 購読側が契約変更を検出できない                           |
| 集約をトランザクション外で読んで中で保存する       | 併走した更新が互いを上書きし、同じ事実が二度配送される   |
| 単調増加なだけの `sequence` で欠番待ちをする       | 正常な欠番で購読側が止まり、誤検知の再同期や隔離が起きる |
| 未配送イベントを永続エンティティに載せたままにする | 全フィールドを走査するシリアライザが保存対象に含める     |
